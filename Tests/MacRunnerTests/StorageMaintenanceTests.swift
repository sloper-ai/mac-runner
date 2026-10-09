import XCTest
@testable import MacRunner

final class StorageMaintenanceTests: XCTestCase, @unchecked Sendable {
    private func scratch() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("maintenance-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home.resolvingSymlinksInPath()
    }

    @discardableResult
    private func file(_ path: String, in home: URL, bytes: Int = 100, age: TimeInterval = 0) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    func testCacheAgeAndBudgetPreserveBrowsersToolsAndCredentials() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let old = try file(".npm/_cacache/stale", in: home, age: 9 * 86400)
        let fresh = try file(".cache/pip/fresh", in: home, bytes: 300)
        let protected = try [".cache/ms-playwright/chromium/browser", "Library/Caches/ms-playwright/firefox/browser",
            ".cache/unknown/toolchain", ".rustup/toolchains/stable/rustc", ".cargo/bin/cargo", ".ssh/key",
            "Library/Keychains/login.keychain-db", ".gradle/jdks/java/bin/java"].map { try file($0, in: home, age: 90 * 86400) }
        let report = try DisposableCache.maintain(home: home, maxBytes: 100_000, maxAgeDays: 7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertGreaterThanOrEqual(report.remainingBytes, 300)
        _ = try DisposableCache.maintain(home: home, maxBytes: 200, maxAgeDays: 7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
        for path in protected { XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), path.path) }
    }

    func testSymlinkRootsParentsAndDescendantsCannotDeleteOutsideCache() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let sentinel = try file("valuable/keep", in: home, age: 30 * 86400)
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent(".cache/pip"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appendingPathComponent(".npm"), withDestinationURL: home.appendingPathComponent("valuable"))
        try fm.createSymbolicLink(at: home.appendingPathComponent(".cache/uv"), withDestinationURL: home.appendingPathComponent("valuable"))
        try fm.createSymbolicLink(at: home.appendingPathComponent(".cache/pip/link"), withDestinationURL: home.appendingPathComponent("valuable"))
        try file(".cache/pip/large", in: home, bytes: 1000)
        _ = try DisposableCache.maintain(home: home, maxBytes: 1, maxAgeDays: 1)
        XCTAssertTrue(fm.fileExists(atPath: sentinel.path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".cache/uv").path), home.appendingPathComponent("valuable").path)
    }

    func testCacheDryRunIsNonMutating() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let old = try file(".npm/_logs/old", in: home, age: 9 * 86400)
        let result = try DisposableCache.maintain(home: home, maxBytes: 1, maxAgeDays: 7, dryRun: true)
        XCTAssertGreaterThan(result.reclaimedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func testActualNativeLivenessDefersSharedCleanupEvenWithStaleStatus() async throws {
        let native = Runner(name: "native", repo: "o/r", status: .stopped)
        let docker = Runner(name: "linux", repo: "o/r", status: .running, isolationMode: .container, containerEngine: .docker)
        XCTAssertFalse(StorageMaintenanceService.canCleanSharedCaches(runners: [native, docker], isolation: .none, isAlive: { $0 == native.id }))
        XCTAssertTrue(StorageMaintenanceService.canCleanSharedCaches(runners: [native, docker], isolation: .none, isAlive: { $0 == docker.id }))
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = try file(".npm/_logs/old", in: home, age: 20 * 86400)
        var service = StorageMaintenanceService(home: home)
        service.hostAvailableBytes = { _ in 500_000_000_000 }
        let settings = AppSettings(automaticDiskCleanupEnabled: true)
        _ = try await service.prepare(runner: native, runners: [native], settings: settings, canCleanShared: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        _ = try await service.prepare(runner: native, runners: [native], settings: settings, canCleanShared: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testHostLowAndUnknownCapacityBlockThenRecover() async throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = Runner(name: "native", repo: "o/r")
        let settings = AppSettings(automaticDiskCleanupEnabled: true, minimumFreeDiskSpaceGB: 40)
        for capacity: Int64? in [nil, 39_999_999_999] {
            var service = StorageMaintenanceService(home: home)
            service.hostAvailableBytes = { _ in capacity }
            do {
                _ = try await service.prepare(runner: runner, runners: [runner], settings: settings, canCleanShared: true)
                XCTFail("must block before registration")
            } catch { XCTAssertTrue(error is StorageMaintenanceError) }
        }
        var service = StorageMaintenanceService(home: home)
        service.hostAvailableBytes = { _ in 40_000_000_000 }
        _ = try await service.prepare(runner: runner, runners: [runner], settings: settings, canCleanShared: true)
    }

    actor DockerStub {
        var calls: [[String]] = []
        var attached: Bool
        var guest: Int64?
        init(attached: Bool = false, guest: Int64? = 20_000_000_000) { self.attached = attached; self.guest = guest }
        func run(_ executable: String, _ args: [String], _ timeout: TimeInterval) -> ProcessExecutor.ProcessResult? {
            calls.append(args)
            if args.first == "ps" { return .init(terminationStatus: 0, output: attached ? "active-container\n" : "") }
            if args.first == "run" {
                return .init(terminationStatus: 0, output: "MR_CACHE_REMAINING=100\nMR_DOCKER_BYTES=16000000000\n" + (guest.map { "MR_GUEST_AVAILABLE=\($0)\n" } ?? ""))
            }
            return .init(terminationStatus: 0, output: "")
        }
    }

    private var dockerRunner: Runner {
        var runner = Runner(name: "linux", repo: "o/r", isolationMode: .container, containerEngine: .docker,
                            jit: true, containerCachePaths: ["/root/.cache", "/root/.npm"], dockerInDocker: true)
        runner.containerImage = "configured:keep"
        return runner
    }

    func testAttachedDockerVolumeRefusesAllMutation() async throws {
        let stub = DockerStub(attached: true)
        var service = StorageMaintenanceService()
        service.execute = { await stub.run($0, $1, $2) }
        do {
            _ = try await service.prepareDocker(runner: dockerRunner, settings: .default, pressure: false, docker: "/test/docker")
            XCTFail("must leave attached resources alone")
        } catch { XCTAssertTrue(error.localizedDescription.contains("attached")) }
        let calls = await stub.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.first, "ps")
    }

    func testDockerBudgetsRemoveOnlyOwnedUnusedDataAndPreserveConfiguredImage() async throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let stub = DockerStub()
        var service = StorageMaintenanceService(home: home)
        service.execute = { await stub.run($0, $1, $2) }
        let runner = dockerRunner
        _ = try await service.prepareDocker(runner: runner, settings: .default, pressure: false, docker: "/test/docker")
        let calls = await stub.calls
        XCTAssertTrue(calls.contains(["volume", "rm", DockerRunnerEngine.dockerVolumeName(for: runner.id)]))
        XCTAssertTrue(calls.filter { $0.first == "run" }.allSatisfy { $0.contains("configured:keep") && $0.contains("--pull=never") })
        XCTAssertFalse(calls.contains { $0.contains("prune") || $0.first == "image" || $0.first == "system" })
        let helper = try XCTUnwrap(calls.first { $0.contains(StorageMaintenanceScript.script) })
        XCTAssertFalse(helper.contains { $0.contains("ms-playwright") })
        XCTAssertTrue(helper.contains("/storage-cache-0/pip"))
        XCTAssertTrue(helper.contains("/storage-cache-1/_cacache"))
    }

    func testGuestLowAndUnreadableCapacityFailIndependently() async throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        for available: Int64? in [nil, 9_000_000_000] {
            let stub = DockerStub(guest: available)
            var service = StorageMaintenanceService(home: home)
            service.execute = { await stub.run($0, $1, $2) }
            do {
                _ = try await service.prepareDocker(runner: dockerRunner, settings: .default, pressure: false, docker: "/test/docker")
                XCTFail("guest reserve must block independently of host")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Docker guest")) }
        }
    }

    func testDockerRetentionExpiresAndOversizedDataResets() {
        let now = Date()
        let policy = StorageMaintenanceSettings.default
        XCTAssertTrue(StorageMaintenanceService.resetDockerData(bytes: 0, lastReset: nil, policy: policy, pressure: false, now: now))
        XCTAssertTrue(StorageMaintenanceService.resetDockerData(bytes: 0, lastReset: now.addingTimeInterval(-7 * 86400), policy: policy, pressure: false, now: now))
        XCTAssertFalse(StorageMaintenanceService.resetDockerData(bytes: 100, lastReset: now, policy: policy, pressure: false, now: now))
        XCTAssertTrue(StorageMaintenanceService.resetDockerData(bytes: 15_000_000_001, lastReset: now, policy: policy, pressure: false, now: now))
    }

    func testOnlyKnownCacheSubpathsAndLocalColimaEndpointsAreAccepted() {
        XCTAssertEqual(DisposableCache.paths(inMount: "/root/.npm"), ["_cacache", "_logs", "_npx"])
        XCTAssertEqual(DisposableCache.paths(inMount: "/home/runner/.cargo/registry"), ["cache"])
        XCTAssertTrue(DisposableCache.paths(inMount: "/root/.cache/ms-playwright").isEmpty)
        XCTAssertTrue(DisposableCache.paths(inMount: "/root/unknown").isEmpty)
        let home = URL(fileURLWithPath: "/Users/ci")
        XCTAssertEqual(StorageMaintenanceService.colimaProfile(endpoint: "unix:///Users/ci/.colima/default/docker.sock", home: home), "default")
        for endpoint in ["ssh://host", "tcp://host:2375", "unix:///var/run/docker.sock", "unix:///Users/other/.colima/default/docker.sock", "unix:///Users/ci/.colima/../docker.sock"] {
            XCTAssertNil(StorageMaintenanceService.colimaProfile(endpoint: endpoint, home: home))
        }
    }

    func testLocksExcludeOtherProcessAndRefuseSymlinkLockFiles() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("lock").path
        let first = try XCTUnwrap(RunnerStartLock.tryAcquire(path: path))
        XCTAssertNil(RunnerStartLock.tryAcquire(path: path))
        first.unlock()
        XCTAssertNotNil(RunnerStartLock.tryAcquire(path: path))
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent("link").path, withDestinationPath: path)
        XCTAssertNil(RunnerStartLock.tryAcquire(path: home.appendingPathComponent("link").path))
    }

    func testSettingsBackwardCompatibilityValidationAndExport() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"automaticDiskCleanupEnabled":false,"minimumFreeDiskSpaceGB":40}"#.utf8))
        XCTAssertFalse(old.automaticDiskCleanupEnabled)
        XCTAssertEqual(old.minimumFreeDiskSpaceGB, 40)
        XCTAssertEqual(old.storageMaintenance, .default)
        let partial = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"storageMaintenance":{"maxCacheSizeGB":5}}"#.utf8))
        XCTAssertEqual(partial.storageMaintenance.maxCacheSizeGB, 5)
        XCTAssertEqual(partial.storageMaintenance.minimumGuestFreeDiskSpaceGB, 10)
        let yaml = """
        settings:
          automatic-disk-cleanup: true
          minimum-free-disk-space-gb: 40
          minimum-guest-free-disk-space-gb: 12
          cache-max-age-days: 3
          max-cache-size-gb: 6
          max-docker-data-size-gb: 9
          daily-vm-trim: false
        runners: []
        """
        let settings = try DeclarativeConfig.parse(yaml).resolvedSettings(old)
        XCTAssertTrue(settings.automaticDiskCleanupEnabled)
        XCTAssertEqual(settings.storageMaintenance.minimumGuestFreeDiskSpaceGB, 12)
        let exported = try DeclarativeConfig.export(runners: [], settings: settings).yaml()
        XCTAssertEqual(try DeclarativeConfig.parse(exported).resolvedSettings(.default), settings)
        for pair in ["cache-max-age-days: 0", "max-cache-size-gb: -1", "minimum-guest-free-disk-space-gb: 0", "max-docker-data-size-gb: 100001"] {
            XCTAssertThrowsError(try DeclarativeConfig.parse("settings:\n  \(pair)\nrunners: []\n").resolvedSettings(.default))
        }
        var blocked = Runner(name: "waiting", repo: "o/r", status: .paused)
        blocked.storageBlockedReason = "Mac filesystem below reserve"
        XCTAssertEqual(try JSONDecoder().decode(Runner.self, from: JSONEncoder().encode(blocked)).persistedState, blocked.persistedState)
    }
    actor TrimStub {
        var calls: [[String]] = []
        let endpoint: String
        let succeeds: Bool
        init(endpoint: String, succeeds: Bool = true) { self.endpoint = endpoint; self.succeeds = succeeds }
        func run(_ executable: String, _ args: [String], _ timeout: TimeInterval) -> ProcessExecutor.ProcessResult? {
            calls.append(args)
            if args.contains("status") {
                return .init(terminationStatus: 0, output: "{\"runtime\":\"docker\",\"docker_socket\":\"\(endpoint)\"}")
            }
            return .init(terminationStatus: succeeds ? 0 : 1, output: succeeds ? "/var/lib/docker: 123 bytes trimmed" : "unsupported")
        }
    }

    func testTrimMatchesBackendAndPersistsDailySuccessAcrossServiceInstances() async throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        for name in ["docker", "colima"] {
            let url = try file("bin/" + name, in: home)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let endpoint = "unix://" + home.path + "/.colima/default/docker.sock"
        let env = ["PATH": home.appendingPathComponent("bin").path, "DOCKER_HOST": endpoint]
        let stub = TrimStub(endpoint: endpoint)
        let settings = AppSettings(automaticDiskCleanupEnabled: true)
        let now = Date()
        var first = StorageMaintenanceService(home: home)
        first.execute = { await stub.run($0, $1, $2) }
        let result = await first.trimIfDue(settings: settings, hasDockerRunners: true, now: now, environment: env)
        XCTAssertTrue(result.joined().contains("succeeded"))
        var second = StorageMaintenanceService(home: home)
        second.execute = first.execute
        _ = await second.trimIfDue(settings: settings, hasDockerRunners: true, now: now.addingTimeInterval(7200), environment: env)
        var calls = await stub.calls
        XCTAssertEqual(calls.filter { $0.contains("fstrim") }.count, 1)
        _ = await second.trimIfDue(settings: settings, hasDockerRunners: true, now: now.addingTimeInterval(90000), environment: env)
        calls = await stub.calls
        XCTAssertEqual(calls.filter { $0.contains("fstrim") }.count, 2)
    }

    func testRemoteDockerEndpointNeverTrimsLocalColima() async throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let docker = try file("bin/docker", in: home)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)
        let stub = TrimStub(endpoint: "ssh://remote")
        var service = StorageMaintenanceService(home: home)
        service.execute = { await stub.run($0, $1, $2) }
        let result = await service.trimIfDue(settings: AppSettings(automaticDiskCleanupEnabled: true), hasDockerRunners: true,
            environment: ["PATH": home.appendingPathComponent("bin").path, "DOCKER_HOST": "ssh://remote"])
        XCTAssertTrue(result.joined().contains("unsupported"))
        let calls = await stub.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testWorkspaceSymlinkResetPreservesTargetAndItsPermissions() async throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let sentinel = try file("tools/keep", in: home)
        let tools = sentinel.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tools.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tools.path) }
        let workspace = home.appendingPathComponent("_work")
        try FileManager.default.createSymbolicLink(at: workspace, withDestinationURL: tools)
        try await RunnerManager.resetDirectory(workspace)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: tools.path)[.posixPermissions] as? NSNumber)?.intValue, 0o500)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workspace.path), [])
    }

}
