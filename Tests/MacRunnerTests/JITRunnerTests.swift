import XCTest
@testable import MacRunner

/// Shared scratch helpers for the JIT tests.
private enum Scratch {
    /// A scratch directory; with `runnerDirectory`, shaped like a runner's
    /// (`…/.mac-runner/runners/<id>`), which the JIT commands insist on.
    static func directory(_ name: String, runnerDirectory: Bool = false, plain: Bool = false) throws -> URL {
        // A space and a quote in the path, which must survive shell quoting
        // (`plain` for the container script, whose runner candidates are a word list).
        var url = FileManager.default.temporaryDirectory
            .appendingPathComponent(plain ? "jit-\(name)-\(UUID().uuidString)" : "jit \(name) it's \(UUID().uuidString)", isDirectory: true)
        if runnerDirectory {
            url = url.appendingPathComponent(".mac-runner/runners/\(UUID().uuidString)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func executable(_ url: URL, _ contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static func run(_ shell: String, _ command: String, environment: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}

/// The JIT config stands in for the real thing: a secret that must never land in argv, scripts, or logs.
private let jitConfig = "eyJydW5uZXIiOiJzM2NyZXQgJ3F1b3RlZCcgJHZhbHVlIn0=-jit-config-secret"

// MARK: - Model

final class JITRunnerModelTests: XCTestCase {
    private let legacyRunner = """
    {
        "id": "00000000-0000-0000-0000-000000000002",
        "name": "old",
        "repo": "owner/repo",
        "labels": ["linux"],
        "enabled": true,
        "status": "running",
        "githubRunnerId": 7,
        "isolationMode": { "type": "container" },
        "containerTools": ["gh", "node"]
    }
    """

    func testJITSettingsRoundTrip() throws {
        var runner = Runner(
            name: "linux-mbp-1", repo: "o/r", isolationMode: .container, containerEngine: .docker,
            jit: true, containerToolsOverride: [], containerCachePaths: ["/home/runner/.cargo/registry"]
        )
        runner.jitRegistration = JITRegistration(id: 42, name: "linux-mbp-1-3fa29c", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        runner.githubRunnerId = 42
        let data = try JSONEncoder().encode(runner)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["jit"] as? Bool, true)
        XCTAssertEqual(json?["containerToolsOverride"] as? [String], [])
        XCTAssertEqual(json?["containerCachePaths"] as? [String], ["/home/runner/.cargo/registry"])
        let registration = json?["jitRegistration"] as? [String: Any]
        XCTAssertEqual(registration?["id"] as? Int, 42)
        XCTAssertEqual(registration?["name"] as? String, "linux-mbp-1-3fa29c")

        let decoded = try JSONDecoder().decode(Runner.self, from: data)
        XCTAssertEqual(decoded, runner)
        XCTAssertTrue(decoded.isJIT)
        XCTAssertEqual(decoded.registeredName, "linux-mbp-1-3fa29c")
    }

    func testConfigsWithoutTheKeysKeepLongLivedRunners() throws {
        let runner = try JSONDecoder().decode(Runner.self, from: Data(legacyRunner.utf8))
        XCTAssertNil(runner.jit)
        XCTAssertFalse(runner.isJIT)
        XCTAssertNil(runner.jitRegistration)
        XCTAssertNil(runner.containerToolsOverride)
        XCTAssertNil(runner.containerCachePaths)
        XCTAssertEqual(runner.effectiveContainerTools, ["gh", "node"], "detected tools, as before")
        XCTAssertEqual(runner.registeredName, "old")

        // Nothing new is written back for such a runner.
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(runner)) as? [String: Any]
        for key in ["jit", "jitRegistration", "containerToolsOverride", "containerCachePaths"] {
            XCTAssertNil(json?[key], key)
        }
    }

    func testOnlyJITOnIsStored() throws {
        XCTAssertNil(Runner(name: "r", repo: "o/r", jit: false).jit)
        XCTAssertEqual(Runner(name: "r", repo: "o/r", jit: true).jit, true)
        let explicitFalse = legacyRunner.replacingOccurrences(of: "\"enabled\": true,", with: "\"enabled\": true, \"jit\": false,")
        XCTAssertNil(try JSONDecoder().decode(Runner.self, from: Data(explicitFalse.utf8)).jit)
        XCTAssertNil(Runner(name: "r", repo: "o/r", containerCachePaths: []).containerCachePaths, "no caches is nil")
    }

    func testToolOverride() {
        var runner = Runner(name: "r", repo: "o/r", isolationMode: .container)
        runner.containerTools = ["gh", "rust"]
        XCTAssertEqual(runner.effectiveContainerTools, ["gh", "rust"])
        runner.containerToolsOverride = []
        XCTAssertEqual(runner.effectiveContainerTools, [], "--no-tools installs nothing")
        runner.containerToolsOverride = ["jq"]
        XCTAssertEqual(runner.effectiveContainerTools, ["jq"])
    }

    func testTheRegistrationTravelsWithTheConfiguration() {
        let base = Runner(name: "r", repo: "o/r", status: .running, jit: true)
        var registeredByCLI = base
        registeredByCLI.jitRegistration = JITRegistration(id: 9, name: "r-00000a", createdAt: Date())
        registeredByCLI.githubRunnerId = 9

        let taken = RunnerManager.mergeRunner(disk: registeredByCLI, memory: base, base: base, ownsRuntime: false)
        XCTAssertEqual(taken.jitRegistration?.id, 9, "another process's new registration is what we delete later")
        XCTAssertEqual(taken.githubRunnerId, 9)

        let kept = RunnerManager.mergeRunner(disk: base, memory: registeredByCLI, base: base, ownsRuntime: true)
        XCTAssertEqual(kept.jitRegistration?.id, 9, "ours survives a concurrent save")
    }
}

// MARK: - Registration

final class JITRegistrationTests: XCTestCase {
    func testRegistrationNamesAreUniquePerStart() {
        XCTAssertEqual(JITRunner.registrationName(for: "linux-mbp-1", suffix: 0xABC), "linux-mbp-1-000abc")
        XCTAssertEqual(JITRunner.registrationName(for: "r", suffix: 0xFFFF_FFFF), "r-ffffff")
        let random = JITRunner.registrationName(for: "linux-mbp-1")
        XCTAssertTrue(JITRunner.isRegistrationName(random, of: "linux-mbp-1"), random)
        XCTAssertTrue(random.range(of: #"^linux-mbp-1-[0-9a-f]{6}$"#, options: .regularExpression) != nil, random)

        XCTAssertFalse(JITRunner.isRegistrationName("linux-mbp-1", of: "linux-mbp-1"))
        XCTAssertFalse(JITRunner.isRegistrationName("linux-mbp-10-abcdef", of: "linux-mbp-1"))
        XCTAssertFalse(JITRunner.isRegistrationName("linux-mbp-1-ABCDEF", of: "linux-mbp-1"))
        XCTAssertFalse(JITRunner.isRegistrationName("linux-mbp-1-abcdefa", of: "linux-mbp-1"))
        XCTAssertFalse(JITRunner.isRegistrationName("linux-mbp-1-a1b2c3", of: "linux-mbp"))
    }

    func testOnlyOfflineLeftoversOfThisRunnerAreCleanedUp() {
        let remote = [
            RemoteRunner(id: 1, name: "linux-mbp-1-a1b2c3", status: "offline", busy: false, labels: []),
            RemoteRunner(id: 2, name: "linux-mbp-1-d4e5f6", status: "online", busy: true, labels: []),
            RemoteRunner(id: 3, name: "linux-mbp-1", status: "offline", busy: false, labels: []),
            RemoteRunner(id: 4, name: "linux-mbp-2-a1b2c3", status: "offline", busy: false, labels: []),
        ]
        XCTAssertEqual(JITRunner.leftoverRegistrations(of: "linux-mbp-1", in: remote).map(\.id), [1], "never a live one")
    }

    func testGenerateJITConfigRequest() {
        let repo = GHCLIService.generateJITConfigArguments(
            for: RunnerTarget(scope: .repo, identifier: "sloper-ai/sloper-new"),
            name: "linux-mbp-1-3fa29c",
            labels: ["self-hosted", "Linux", "ARM64", "local"],
            workFolder: "/mac-runner/_work"
        )
        XCTAssertEqual(repo, [
            "api", "-X", "POST", "repos/sloper-ai/sloper-new/actions/runners/generate-jitconfig",
            "-f", "name=linux-mbp-1-3fa29c",
            "-F", "runner_group_id=1",
            "-f", "work_folder=/mac-runner/_work",
            "-f", "labels[]=self-hosted", "-f", "labels[]=Linux", "-f", "labels[]=ARM64", "-f", "labels[]=local",
        ])
        let org = GHCLIService.generateJITConfigArguments(
            for: RunnerTarget(scope: .org, identifier: "sloper-ai"), name: "n-000001", labels: ["x"], workFolder: "_work"
        )
        XCTAssertEqual(org[3], "orgs/sloper-ai/actions/runners/generate-jitconfig")
    }

    /// A stand-in gh: records its arguments and answers as `gh api` would.
    private func standInGH(stdout: String = "", stderr: String = "", status: Int32 = 0) throws -> (gh: GHCLIService, calls: URL, root: URL) {
        let root = try Scratch.directory("gh")
        let calls = root.appendingPathComponent("calls")
        let response = root.appendingPathComponent("response")
        let errors = root.appendingPathComponent("errors")
        try stdout.write(to: response, atomically: true, encoding: .utf8)
        try stderr.write(to: errors, atomically: true, encoding: .utf8)
        let gh = root.appendingPathComponent("gh")
        try Scratch.executable(gh, """
        #!/bin/bash
        printf '%s\\n' "$@" > '\(calls.path.replacingOccurrences(of: "'", with: "'\\''"))'
        cat '\(response.path.replacingOccurrences(of: "'", with: "'\\''"))'
        cat '\(errors.path.replacingOccurrences(of: "'", with: "'\\''"))' >&2
        exit \(status)
        """)
        return (GHCLIService(ghPath: gh.path), calls, root)
    }

    func testRegistersAJITRunnerWithGH() async throws {
        let response = #"{"runner":{"id":23,"name":"linux-mbp-1-3fa29c","os":"unknown","status":"offline","busy":false,"labels":[]},"encoded_jit_config":"\#(jitConfig)"}"#
        let stub = try standInGH(stdout: response)
        defer { try? FileManager.default.removeItem(at: stub.root) }

        let config = try await stub.gh.generateJITConfig(
            for: RunnerTarget(scope: .repo, identifier: "o/r"), name: "linux-mbp-1-3fa29c", labels: ["self-hosted"], workFolder: "_work"
        )
        XCTAssertEqual(config.runnerID, 23)
        XCTAssertEqual(config.runnerName, "linux-mbp-1-3fa29c")
        XCTAssertEqual(config.encodedJITConfig, jitConfig)
        let calls = try String(contentsOf: stub.calls, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(calls, GHCLIService.generateJITConfigArguments(
            for: RunnerTarget(scope: .repo, identifier: "o/r"), name: "linux-mbp-1-3fa29c", labels: ["self-hosted"], workFolder: "_work"
        ))
    }

    func testABadResponseIsNeverQuoted() async throws {
        // A response without the runner: the error must not echo the config.
        let stub = try standInGH(stdout: #"{"encoded_jit_config":"\#(jitConfig)"}"#)
        defer { try? FileManager.default.removeItem(at: stub.root) }
        do {
            _ = try await stub.gh.generateJITConfig(for: RunnerTarget(scope: .repo, identifier: "o/r"), name: "n", labels: ["x"], workFolder: "_work")
            XCTFail("expected a failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(jitConfig), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("no runner or JIT config"), error.localizedDescription)
        }

        let refused = try standInGH(stderr: "gh: Resource not accessible by integration (HTTP 403)", status: 1)
        defer { try? FileManager.default.removeItem(at: refused.root) }
        do {
            _ = try await refused.gh.generateJITConfig(for: RunnerTarget(scope: .org, identifier: "o"), name: "n", labels: ["x"], workFolder: "_work")
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 403"), error.localizedDescription)
        }
    }

    /// The deletion stopping and exiting both use: 404 means GitHub already deleted it.
    func testDeletingARegistrationTreats404AsDone() async throws {
        let target = RunnerTarget(scope: .repo, identifier: "sloper-ai/sloper-new")

        let deleted = try standInGH()
        defer { try? FileManager.default.removeItem(at: deleted.root) }
        let outcome = try await deleted.gh.deleteRunnerIfPresent(target: target, githubRunnerId: 23)
        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(
            try String(contentsOf: deleted.calls, encoding: .utf8).split(separator: "\n").map(String.init),
            ["api", "-X", "DELETE", "repos/sloper-ai/sloper-new/actions/runners/23"]
        )

        let gone = try standInGH(stderr: "gh: Not Found (HTTP 404)", status: 1)
        defer { try? FileManager.default.removeItem(at: gone.root) }
        let goneOutcome = try await gone.gh.deleteRunnerIfPresent(target: target, githubRunnerId: 23)
        XCTAssertEqual(goneOutcome, .alreadyGone)

        let busy = try standInGH(stderr: "gh: Bad request - Runner \"x\" is still running a job (HTTP 422)", status: 1)
        defer { try? FileManager.default.removeItem(at: busy.root) }
        do {
            _ = try await busy.gh.deleteRunnerIfPresent(target: target, githubRunnerId: 23)
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 422"), error.localizedDescription)
        }
    }

    func testTheRunnerVersionIsLookedUpAtMostHourly() {
        let cache = ResolvedVersionCache()
        let then = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(cache.value(maxAge: 3600, now: then))
        cache.store("2.338.0", at: then)
        XCTAssertEqual(cache.value(maxAge: 3600, now: then.addingTimeInterval(3599)), "2.338.0", "every JIT start within the hour")
        XCTAssertNil(cache.value(maxAge: 3600, now: then.addingTimeInterval(3600)))
    }

    func testAStartHoldsTheStartLock() throws {
        let root = try Scratch.directory("lock")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("runner.start-lock").path

        let held = try XCTUnwrap(RunnerStartLock.tryAcquire(path: path))
        XCTAssertNil(RunnerStartLock.tryAcquire(path: path), "a second start (another process) waits")
        held.unlock()
        let again = RunnerStartLock.tryAcquire(path: path)
        XCTAssertNotNil(again, "free once the start is done")
        again?.unlock()
    }
}

// MARK: - Exits

final class JITExitTests: XCTestCase {
    private func action(wanted: Bool = true, clean: Bool = true, ranJob: Bool = false, uptime: TimeInterval) -> JITRunner.ExitAction {
        JITRunner.exitAction(stillWanted: wanted, cleanExit: clean, exitDescription: "process exit, code 1", ranJob: ranJob, uptime: uptime)
    }

    func testACleanExitAfterAJobStartsTheNextRunnerNow() {
        XCTAssertEqual(action(ranJob: true, uptime: 8), .startNext, "a quick job is still a job")
        XCTAssertEqual(action(ranJob: true, uptime: 3600), .startNext)
        XCTAssertEqual(action(uptime: 30), .startNext, "up long enough without a job (deleted on GitHub, say)")
        XCTAssertEqual(action(uptime: 7200), .startNext)
    }

    func testCrashesAndQuickExitsKeepTheBackoff() {
        XCTAssertEqual(action(clean: false, ranJob: true, uptime: 600), .crash(reason: "process exit, code 1"))
        XCTAssertEqual(action(clean: false, uptime: 2), .crash(reason: "process exit, code 1"))
        XCTAssertEqual(action(uptime: 4.7), .crash(reason: "exited after 4s without running a job"))
        XCTAssertEqual(action(uptime: -1), .crash(reason: "exited after 0s without running a job"))
    }

    func testAStopOnPurposeStartsNothing() {
        XCTAssertEqual(action(wanted: false, ranJob: true, uptime: 600), .stopped)
        XCTAssertEqual(action(wanted: false, clean: false, uptime: 1), .stopped)
    }

    func testTheLogTellsWhetherThisStartRanAJob() {
        let registration = JITRegistration(id: 23, name: "linux-mbp-1-3fa29c", createdAt: Date())
        let marker = "[2026-10-08T10:00:00Z] [mac-runner] " + JITRunner.startMessage(for: registration)
        let previous = "[2026-10-08T09:00:00Z] [mac-runner] " + JITRunner.startMessage(
            for: JITRegistration(id: 22, name: "linux-mbp-1-000001", createdAt: Date())
        )
        let job = "2026-10-08 10:00:09Z: Running job: build"

        XCTAssertEqual(JITRunner.ranJob(in: [previous, job, marker, "2026-10-08 10:00:05Z: Listening for Jobs", job], since: registration), true)
        XCTAssertEqual(JITRunner.ranJob(in: [previous, job, marker, "2026-10-08 10:00:05Z: Listening for Jobs"], since: registration), false,
                       "the previous start's job doesn't count")
        XCTAssertNil(JITRunner.ranJob(in: [previous, job], since: registration), "can't tell once its start has rotated away")
        XCTAssertEqual(marker.hasSuffix(JITRunner.startMessage(for: registration)), true)
        XCTAssertEqual(JITRunner.startMessage(for: registration), "Registered single-use runner linux-mbp-1-3fa29c (GitHub ID 23) for one job.")
    }
}

// MARK: - Launch commands

final class JITLaunchTests: XCTestCase {
    private let runnerID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    private func jitVariables(cacheDirectories: [String] = []) -> [(name: String, value: String)] {
        ContainerRunnerScript.variables(
            registrationURL: "https://github.com/sloper-ai/sloper-new",
            registration: .jitConfig(jitConfig),
            runnerName: "linux-mbp-1",
            labels: ["self-hosted", "Linux", "ARM64", "local"],
            runnerDownloadURL: RunnerInstaller.linuxDownloadURL(version: "2.338.0"),
            openFileLimit: 4096,
            tools: [],
            enableGUI: false,
            cacheDirectories: cacheDirectories
        ) + DockerRunnerEngine.engineVariables
    }

    // MARK: Containers

    func testContainerEnvironmentCarriesTheConfigInsteadOfAToken() {
        let names = jitVariables().map(\.name)
        XCTAssertTrue(names.contains("ACTIONS_RUNNER_INPUT_JITCONFIG"))
        XCTAssertFalse(names.contains("MR_TOKEN"))
        XCTAssertEqual(jitVariables().first { $0.name == "MR_APT_PACKAGES" }?.value, "", "--no-tools: nothing to install")
        XCTAssertEqual(jitVariables().first { $0.name == "MR_INSTALL_GH" }?.value, "0")
        XCTAssertFalse(names.contains("MR_CACHE_DIRS"), "only listed when there are caches")
        XCTAssertEqual(
            jitVariables(cacheDirectories: ["/home/runner/.cargo/registry", "/home/runner/.cache/uv"]).first { $0.name == "MR_CACHE_DIRS" }?.value,
            "/home/runner/.cargo/registry:/home/runner/.cache/uv"
        )

        // Apple's engine: the VM process's environment.
        var apple = ContainerRunnerConfiguration(
            containerImage: nil,
            workspaceURL: URL(fileURLWithPath: "/tmp/w"),
            repositoryURL: "https://github.com/o/r",
            registrationToken: "",
            runnerName: "n",
            labels: ["self-hosted"],
            runnerDownloadURL: "https://example.com/runner.tar.gz"
        )
        apple.jitConfig = jitConfig
        let environment = ContainerRunnerScript.environment(for: apple)
        XCTAssertTrue(environment.contains("ACTIONS_RUNNER_INPUT_JITCONFIG=\(jitConfig)"))
        XCTAssertFalse(environment.contains { $0.hasPrefix("MR_TOKEN=") })
    }

    func testDockerLauncherNamesTheConfigAndResetsTheWorkVolume() throws {
        let cachePaths = ["/home/runner/.cargo/registry", "/home/runner/.cache/uv"]
        let launcher = DockerRunnerEngine.launcherScript(
            docker: "/usr/local/bin/docker",
            runnerID: runnerID,
            runnerName: "linux-mbp-1",
            runnerDirectory: "/Users/me/.mac-runner/runners/\(runnerID.uuidString)",
            image: "sloper-ci-linux:latest",
            cpus: 4,
            memoryMB: 8192,
            openFileLimit: 65536,
            environmentNames: jitVariables(cacheDirectories: cachePaths).map(\.name),
            resetWorkVolume: true,
            cacheMounts: DockerRunnerEngine.cacheMounts(for: runnerID, paths: cachePaths)
        )
        XCTAssertFalse(launcher.contains(jitConfig), "names only: the value comes from the launcher's environment")
        XCTAssertTrue(launcher.contains("-e ACTIONS_RUNNER_INPUT_JITCONFIG"))
        XCTAssertFalse(launcher.contains("MR_TOKEN"))
        XCTAssertTrue(launcher.contains("/usr/local/bin/docker volume rm -f mac-runner-\(runnerID.uuidString)-work >/dev/null"), launcher)
        let cargo = DockerRunnerEngine.cacheVolumeName(for: runnerID, path: "/home/runner/.cargo/registry")
        XCTAssertTrue(launcher.contains("-v \(cargo):/home/runner/.cargo/registry"), launcher)

        let longLived = DockerRunnerEngine.launcherScript(
            docker: "/usr/local/bin/docker", runnerID: runnerID, runnerName: "r", runnerDirectory: "/d", image: "i",
            cpus: 2, memoryMB: 4096, openFileLimit: 4096, environmentNames: ["MR_TOKEN"]
        )
        XCTAssertFalse(longLived.contains("volume rm"), "a long-lived runner keeps its work volume")
    }

    /// Runs the written launcher with a stand-in docker that records each call.
    private func runLauncher(dockerStub: String, cachePaths: [String]) throws -> (status: Int32, output: String, calls: [[String]], environment: String) {
        let root = try Scratch.directory("docker")
        defer { try? FileManager.default.removeItem(at: root) }
        let runnerDirectory = root.appendingPathComponent("runner", isDirectory: true)
        try FileManager.default.createDirectory(at: runnerDirectory.appendingPathComponent("_diag"), withIntermediateDirectories: true)
        let docker = root.appendingPathComponent("docker")
        try Scratch.executable(docker, dockerStub)

        let variables = jitVariables(cacheDirectories: cachePaths)
        let launcher = try DockerRunnerEngine.writeLaunchFiles(
            docker: docker.path, runnerID: runnerID, runnerName: "linux-mbp-1", runnerDirectory: runnerDirectory.path,
            image: "sloper-ci-linux:latest", cpus: 4, memoryMB: 8192, openFileLimit: 4096,
            environmentNames: variables.map(\.name),
            resetWorkVolume: true,
            cacheMounts: DockerRunnerEngine.cacheMounts(for: runnerID, paths: cachePaths)
        )
        XCTAssertFalse(try String(contentsOfFile: launcher, encoding: .utf8).contains(jitConfig))

        var environment = RunnerEnvironment.environment(from: ["PATH": "/usr/bin:/bin"], enableGUI: false)
        environment.merge(Dictionary(variables.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })) { _, new in new }
        let log = root.appendingPathComponent("calls").path
        let envFile = root.appendingPathComponent("env").path
        environment["STUB_LOG"] = log
        environment["STUB_ENV"] = envFile
        let result = try runFile(launcher, environment: environment)
        let calls = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "")
            .components(separatedBy: "-- call\n")
            .filter { !$0.isEmpty }
            .map { $0.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init) }
        return (result.status, result.output, calls, (try? String(contentsOfFile: envFile, encoding: .utf8)) ?? "")
    }

    private func runFile(_ path: String, environment: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [path]
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    private let recordingDocker = """
    #!/bin/bash
    { echo "-- call"; printf '%s\\n' "$@"; } >> "$STUB_LOG"
    if [ "$1" = run ]; then env > "$STUB_ENV"; fi
    """

    func testDockerLauncherRunsWithAFreshVolumeCachesAndTheConfigInItsEnvironment() throws {
        let caches = ["/home/runner/.cargo/registry", "/home/runner/go/pkg/mod"]
        let result = try runLauncher(dockerStub: recordingDocker, cachePaths: caches)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.calls.count, 3, "\(result.calls)")
        XCTAssertEqual(result.calls[0], ["rm", "-f", "mac-runner-\(runnerID.uuidString)"])
        XCTAssertEqual(result.calls[1], ["volume", "rm", "-f", "mac-runner-\(runnerID.uuidString)-work"], "the job's workspace starts empty")
        let run = result.calls[2]
        XCTAssertEqual(Array(run.prefix(3)), ["run", "--rm", "--init"])
        for path in caches {
            let mount = "\(DockerRunnerEngine.cacheVolumeName(for: runnerID, path: path)):\(path)"
            XCTAssertTrue(zip(run, run.dropFirst()).contains { $0 == ("-v", mount) }, "\(mount) in \(run)")
        }
        XCTAssertTrue(zip(run, run.dropFirst()).contains { $0 == ("-e", "ACTIONS_RUNNER_INPUT_JITCONFIG") })
        XCTAssertFalse(run.contains { $0.contains(jitConfig) }, "never in argv")
        XCTAssertTrue(result.environment.contains("ACTIONS_RUNNER_INPUT_JITCONFIG=\(jitConfig)\n"), "docker passes it on from its environment")
    }

    func testDockerLauncherWontStartWithoutAFreshWorkVolume() throws {
        let failingVolumeRemoval = recordingDocker + """

        if [ "$1" = volume ]; then echo "volume is in use" >&2; exit 1; fi
        """
        let result = try runLauncher(dockerStub: failingVolumeRemoval, cachePaths: [])
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertTrue(result.output.contains("could not delete the work volume"), result.output)
        XCTAssertFalse(result.calls.contains { $0.first == "run" }, "no container without a fresh workspace")
    }

    func testContainerScriptRunsTheJITRunnerWithoutConfigSh() throws {
        let root = try Scratch.directory("script", plain: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runnerHome = root.appendingPathComponent("home-runner", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: runnerHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let configured = root.appendingPathComponent("configured").path
        try Scratch.executable(runnerHome.appendingPathComponent("config.sh"), "#!/bin/bash\ntouch '\(configured.replacingOccurrences(of: "'", with: "'\\''"))'\n")
        try Scratch.executable(runnerHome.appendingPathComponent("run.sh"), """
        #!/bin/bash
        echo "run.sh jit=${ACTIONS_RUNNER_INPUT_JITCONFIG:-unset} token=${MR_TOKEN:-unset}"
        for dir in "$HOME/.cargo/registry" "$HOME/.cache/uv"; do [ -d "$dir" ] && [ -w "$dir" ] && echo "cache ok $dir"; done
        """)

        var environment = Dictionary(
            jitVariables(cacheDirectories: [home.path + "/.cargo/registry", home.path + "/.cache/uv"]).map { ($0.name, $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        environment["MR_RUNNER_CANDIDATES"] = runnerHome.path
        environment["MR_WORK_DIR"] = root.appendingPathComponent("work").path
        environment["MR_DIAG_DIR"] = root.appendingPathComponent("diag").path
        environment["MR_SUDO"] = ""
        environment["HOME"] = home.path
        environment["PATH"] = "/usr/bin:/bin"

        let result = try Scratch.run("/bin/bash", ContainerRunnerScript.script, environment: environment)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Starting a single-use (JIT) runner"), result.output)
        XCTAssertTrue(result.output.contains("run.sh jit=\(jitConfig) token=unset"), "the runner reads the config from its environment: \(result.output)")
        XCTAssertTrue(result.output.contains("cache ok \(home.path)/.cargo/registry"), result.output)
        XCTAssertTrue(result.output.contains("cache ok \(home.path)/.cache/uv"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configured), "config.sh isn't run: the JIT config registers it")
    }

    // MARK: Process isolation

    private func standInRunner(in directory: URL) throws {
        try Scratch.executable(directory.appendingPathComponent("run.sh"), """
        #!/bin/bash
        echo "run.sh jit=${ACTIONS_RUNNER_INPUT_JITCONFIG:-unset} ci=${CI:-unset}"
        [ -e "$(dirname "$0")/_work" ] && echo "stale workspace" || echo "fresh workspace"
        for file in .runner .credentials .credentials_rsaparams .jitconfig; do [ -e "$(dirname "$0")/$file" ] && echo "left: $file"; done
        exit 0
        """)
        // What the last job and registration left behind, a read-only directory
        // (like Go's module cache) among them.
        let work = directory.appendingPathComponent("_work/repo/repo", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "checkout".write(to: work.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        let readOnly = directory.appendingPathComponent("_work/go/pkg/mod/example.com@v1", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try "module".write(to: readOnly.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        for file in JITRunner.credentialFileNames {
            try "{}".write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
    }

    /// Remove a scratch tree even if a test failed with read-only directories left in it.
    private func removeScratch(_ runnerDirectory: URL) {
        let root = runnerDirectory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        _ = try? ProcessExecutor.run("/bin/chmod", arguments: ["-R", "u+w", root.path], silent: true)
        try? FileManager.default.removeItem(at: root)
    }

    /// No isolation: no sudo, so the config is in run.sh's environment.
    func testProcessLaunchWithoutIsolationResetsTheWorkspace() throws {
        let directory = try Scratch.directory("none", runnerDirectory: true)
        defer { removeScratch(directory) }
        try standInRunner(in: directory)

        let command = try ProcessManager.launchCommand(executable: directory.appendingPathComponent("run.sh").path, runnerDirectory: directory.path, jit: true)
        XCTAssertFalse(command.contains(jitConfig))
        XCTAssertTrue(command.contains("rm -rf '\(directory.path.replacingOccurrences(of: "'", with: "'\\''"))/_work'"), command)
        XCTAssertEqual(
            try ProcessManager.launchCommand(executable: "/x/run.sh", runnerDirectory: directory.path, jit: false),
            "exec '/x/run.sh'",
            "a long-lived runner's launch is unchanged"
        )
        XCTAssertThrowsError(try ProcessManager.launchCommand(executable: "/x/run.sh", runnerDirectory: "/Users/me", jit: true),
                             "wipes only a runner's own directory")

        var environment = RunnerEnvironment.environment(from: ["PATH": "/usr/bin:/bin"], enableGUI: false)
        environment[JITRunner.configVariable] = jitConfig
        let result = try Scratch.run("/bin/bash", ResourceLimits.shellCommand(command, openFileLimit: 4096), environment: environment)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("run.sh jit=\(jitConfig) ci=true"), result.output)
        XCTAssertTrue(result.output.contains("fresh workspace"), result.output)
        XCTAssertFalse(result.output.contains("left:"), "the previous registration's files are gone: \(result.output)")
    }

    /// A dedicated user: sudo resets the environment, so the config waits in a
    /// 0600 file that the launch command reads into the variable and deletes.
    func testProcessLaunchAsAServiceUserTakesTheConfigFromItsFile() throws {
        let directory = try Scratch.directory("user", runnerDirectory: true)
        defer { removeScratch(directory) }
        try standInRunner(in: directory)
        let configFile = directory.appendingPathComponent(JITRunner.configFileName).path

        // Written from stdin (as the service user, through sudo), never from argv.
        let write = JITRunner.writeConfigCommand(path: configFile)
        XCTAssertFalse(write.contains(jitConfig))
        let sudoArguments = UserIsolationService.sudoShellArguments(username: "_macrunner", shell: "/bin/bash", command: write)
        XCTAssertFalse(sudoArguments.contains { $0.contains(jitConfig) })
        let written = try ProcessExecutor.run("/bin/bash", arguments: ["-c", write], input: Data(jitConfig.utf8))
        XCTAssertTrue(written.succeeded, written.output)
        XCTAssertEqual(try String(contentsOfFile: configFile, encoding: .utf8), jitConfig)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: configFile)[.posixPermissions] as? Int, 0o600, "readable by its owner only")

        let command = ResourceLimits.shellCommand(
            UserIsolationService.launchCommand(
                directory: directory.path,
                executable: directory.appendingPathComponent("run.sh").path,
                enableGUI: false,
                jitConfigFile: configFile
            ),
            openFileLimit: 4096
        )
        XCTAssertFalse(command.contains(jitConfig))
        // The service user's login shell is zsh.
        let result = try Scratch.run("/bin/zsh", command, environment: ["PATH": "/usr/bin:/bin", "HOME": directory.path])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("run.sh jit=\(jitConfig) ci=true"), "the variable reaches run.sh: \(result.output)")
        XCTAssertTrue(result.output.contains("fresh workspace"), result.output)
        XCTAssertFalse(result.output.contains("left:"), "config file and old credentials are gone: \(result.output)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configFile))

        // Without its config, it doesn't start a runner that can't register.
        let missing = try Scratch.run("/bin/zsh", command, environment: ["PATH": "/usr/bin:/bin", "HOME": directory.path])
        XCTAssertNotEqual(missing.status, 0)
        XCTAssertFalse(missing.output.contains("run.sh"), missing.output)
    }

    /// Apple's engine: the host `_work` its VM mounts is emptied before each start.
    func testWorkspaceResetEmptiesItReadOnlyDirectoriesIncluded() async throws {
        let directory = try Scratch.directory("apple", runnerDirectory: true)
        defer { removeScratch(directory) }
        try standInRunner(in: directory)
        let work = directory.appendingPathComponent("_work", isDirectory: true)

        try await RunnerManager.resetDirectory(work)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [], "an empty _work for the next job")
        try await RunnerManager.resetDirectory(directory.appendingPathComponent("never-made", isDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("never-made").path))
    }

    func testCredentialCleanupRemovesWhatAJITRunLeaves() throws {
        let directory = try Scratch.directory("cleanup", runnerDirectory: true)
        defer { removeScratch(directory) }
        for file in JITRunner.credentialFileNames + [JITRunner.configFileName, "run.sh", ".path"] {
            try "x".write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        JITRunner.removeCredentials(runnerDirectory: directory.path, serviceUser: nil)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(left, [".path", "run.sh"])
    }
}

// MARK: - Cache volumes

final class CacheVolumeTests: XCTestCase {
    private let runnerID = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

    func testCacheVolumeNames() {
        let cargo = DockerRunnerEngine.cacheVolumeName(for: runnerID, path: "/home/runner/.cargo/registry")
        XCTAssertTrue(cargo.range(of: #"^mac-runner-E621E1F8-C36C-495A-93FC-0C247A3E6E5F-cache-[0-9a-f]{8}$"#, options: .regularExpression) != nil, cargo)
        XCTAssertEqual(DockerRunnerEngine.cacheVolumeName(for: runnerID, path: "/home/runner//.cargo/registry/"), cargo, "the same path")
        XCTAssertNotEqual(DockerRunnerEngine.cacheVolumeName(for: runnerID, path: "/home/runner/.cargo/git"), cargo)
        XCTAssertNotEqual(DockerRunnerEngine.cacheVolumeName(for: UUID(), path: "/home/runner/.cargo/registry"), cargo, "per runner")
        XCTAssertTrue(cargo.hasPrefix(DockerRunnerEngine.cacheVolumePrefix(for: runnerID)))
    }

    func testCachePathsAreValidatedAndNormalized() {
        XCTAssertEqual(
            try DockerRunnerEngine.cachePaths(["/home/runner/.cargo/registry/", " /home/runner/.cache/uv", "/home/runner/.cargo/registry"]).get(),
            ["/home/runner/.cargo/registry", "/home/runner/.cache/uv"]
        )
        let invalid: [(String, String)] = [
            ("relative/path", "must be an absolute path"),
            ("/", "can't be the container's root"),
            ("/a:b", "can't contain ':' or ','"),
            ("/a,b", "can't contain ':' or ','"),
            ("/home/runner/../etc", "can't contain '.' or '..'"),
            ("/mac-runner/_work/cache", "inside /mac-runner"),
            ("/mac-runner", "inside /mac-runner"),
        ]
        for (path, expected) in invalid {
            guard case .failure(let error) = DockerRunnerEngine.cachePaths([path]) else {
                XCTFail("expected \(path) to be refused")
                continue
            }
            XCTAssertTrue(error.text.contains(expected), "\(path): \(error.text)")
        }
    }

    func testOnlyThisRunnersCacheVolumesAreRemoved() {
        let mine = DockerRunnerEngine.cacheVolumeName(for: runnerID, path: "/a")
        let output = """
        \(mine)
        x-mac-runner-\(runnerID.uuidString)-cache-12345678
        mac-runner-\(runnerID.uuidString)-work
        mac-runner-\(UUID().uuidString)-cache-12345678
        """
        XCTAssertEqual(DockerRunnerEngine.cacheVolumes(for: runnerID, in: output), [mine])
    }
}

// MARK: - CLI

final class JITCommandTests: XCTestCase {
    private func parse(_ args: [String]) -> Result<AddCommand, CLIParseError> {
        AddCommand.parse(args, hostCores: 8)
    }

    func testParsesJITToolsAndCaches() throws {
        let command = try parse([
            "sloper-ai/sloper-new", "--name", "linux-mbp-1", "--isolation", "container", "--engine", "docker",
            "--image", "sloper-ci-linux:latest", "--cpus", "4", "--memory", "8g", "--labels", "self-hosted,Linux,ARM64,local",
            "--jit", "--no-tools", "--cache", "/home/runner/.cargo/registry", "--cache", "/home/runner/.cache/uv/",
            "--cache", "/home/runner/.cargo/registry",
        ]).get()
        XCTAssertTrue(command.jit)
        XCTAssertTrue(command.noTools)
        XCTAssertEqual(command.containerToolsOverride, [])
        XCTAssertEqual(command.cachePaths, ["/home/runner/.cargo/registry", "/home/runner/.cache/uv"], "normalized, once each")
        XCTAssertNil(command.validationError(globalIsolation: IsolationMode.none))

        let plain = try parse(["o/r", "--isolation", "user"]).get()
        XCTAssertFalse(plain.jit)
        XCTAssertNil(plain.containerToolsOverride, "tools are detected unless --no-tools")
        XCTAssertEqual(try parse(["o/r", "--isolation", "user", "--jit"]).get().jit, true, "JIT works for every isolation")
    }

    func testRejectsMisusedOptions() throws {
        func error(_ args: [String], global: IsolationMode = IsolationMode.none) throws -> String? {
            try parse(args).get().validationError(globalIsolation: global)?.text
        }
        XCTAssertEqual(try error(["o/r", "--no-tools"]), "--no-tools only applies to container isolation (--isolation container)")
        XCTAssertEqual(try error(["o/r", "--isolation", "user", "--cache", "/x"]), "--cache only applies to container isolation (--isolation container)")
        XCTAssertEqual(try error(["o/r", "--isolation", "container", "--cache", "/x"]), "--cache needs the Docker engine (--engine docker)")
        XCTAssertNil(try error(["o/r", "--engine", "docker", "--cache", "/x"], global: .container))
        XCTAssertEqual(
            try error(["o/r", "--jit", "--labels", ""]),
            "--jit needs at least one label: GitHub gives a JIT runner only the labels it's registered with"
        )
        XCTAssertEqual(parse(["o/r", "--cache"]), .failure(.message("--cache requires a container path")))
        XCTAssertEqual(
            parse(["o/r", "--cache", "relative"]),
            .failure(.message("--cache: cache path 'relative' must be an absolute path in the container"))
        )
    }

    func testListAndStatusShowJIT() {
        var docker = Runner(name: "linux-mbp-1", repo: "o/r", status: .running, isolationMode: .container,
                            containerEngine: .docker, containerCPUs: 4, containerMemoryMB: 8192, jit: true)
        let user = Runner(name: "macos-mbp-1", repo: "o/r", status: .running,
                          isolationMode: .dedicatedUser(username: "_macrunner"), jit: true)
        let classic = Runner(name: "classic", repo: "o/r", isolationMode: IsolationMode.none)
        XCTAssertEqual(CLIHandler.isolationText(for: docker, global: IsolationMode.none), "📦 Container (Docker) · 4 CPUs, 8 GB · JIT")
        XCTAssertEqual(CLIHandler.isolationText(for: user, global: IsolationMode.none), "👤 User (_macrunner) · JIT")
        XCTAssertEqual(CLIHandler.isolationText(for: classic, global: IsolationMode.none), "🔓 None")

        docker.jitRegistration = JITRegistration(id: 42, name: "linux-mbp-1-3fa29c", createdAt: Date())
        var stopped = user
        stopped.status = .stopped
        XCTAssertEqual(CLIHandler.jitStatusLines(runners: [user, classic, docker]), [
            "linux-mbp-1: JIT, registered as linux-mbp-1-3fa29c (GitHub ID 42)",
            "macos-mbp-1: JIT, between jobs, registering the next",
        ])
        XCTAssertEqual(CLIHandler.jitStatusLines(runners: [stopped]), ["macos-mbp-1: JIT, not registered (stopped)"])
    }

    func testNotesForAJITRunnerStartedFromTheCLI() {
        let labelled = Runner(name: "r", repo: "o/r", labels: ["self-hosted", "macOS"], jit: true)
        XCTAssertEqual(CLIHandler.jitNotes(for: labelled, appIsRunning: true), [])
        let bare = Runner(name: "r", repo: "o/r", labels: ["macos"], jit: true)
        let notes = CLIHandler.jitNotes(for: bare, appIsRunning: false)
        XCTAssertEqual(notes.count, 2)
        XCTAssertTrue(notes[0].contains("only the labels it's registered with (macos)"), notes[0])
        XCTAssertTrue(notes[1].contains("menu bar app registers and starts the next one"), notes[1])
    }
}

// MARK: - Config files

final class JITConfigFileTests: XCTestCase {
    private let yaml = """
    runners:
      - name: linux-mbp-1
        repo: sloper-ai/sloper-new
        labels: [self-hosted, Linux, ARM64, local]
        isolation: container
        engine: docker
        image: sloper-ci-linux:latest
        cpus: 4
        memory: 8g
        jit: true
        tools: []
        cache: [/home/runner/.cargo/registry, "/home/runner/.cargo/git/"]
      - name: macos-mbp-1
        repo: sloper-ai/sloper-new
        labels: [self-hosted, macOS, ARM64, local]
        isolation: user
        jit: true
      - name: picky
        repo: o/r
        isolation: container
        tools: [GH, jq, gh]
    """

    func testParsesJITToolsAndCacheKeys() throws {
        let runners = try DeclarativeConfig.parse(yaml).desiredRunners(hostCores: 8)
        XCTAssertTrue(runners[0].jit)
        XCTAssertEqual(runners[0].containerToolsOverride, [])
        XCTAssertEqual(runners[0].containerCachePaths, ["/home/runner/.cargo/registry", "/home/runner/.cargo/git"])
        XCTAssertTrue(runners[1].jit)
        XCTAssertNil(runners[1].containerToolsOverride)
        XCTAssertNil(runners[1].containerCachePaths)
        XCTAssertFalse(runners[2].jit, "no key: long-lived")
        XCTAssertEqual(runners[2].containerToolsOverride, ["gh", "jq"])
    }

    func testRejectsInvalidJITToolsAndCacheKeys() {
        let container = "runners:\n  - name: r\n    repo: o/r\n    isolation: container\n"
        let invalid: [(String, String)] = [
            ("runners:\n  - name: r\n    repo: o/r\n    tools: []\n", "r: tools requires container isolation"),
            ("runners:\n  - name: r\n    repo: o/r\n    cache: [/x]\n", "r: cache requires container isolation"),
            (container + "    cache: [/x]\n", "r: cache requires the Docker engine (engine: docker)"),
            (container + "    engine: docker\n    cache: [relative]\n", "r: cache path 'relative' must be an absolute path"),
            (container + "    tools: ['bad tool']\n", "r: tool 'bad tool' must be a tool or apt package name"),
            ("runners:\n  - name: r\n    repo: o/r\n    jit: true\n    labels: []\n", "r: a jit runner needs at least one label"),
            ("runners:\n  - name: r\n    repo: o/r\n    jit: maybe\n", "jit"),
            ("runners:\n  - name: r\n    repo: o/r\n    jitt: true\n", "unknown key 'jitt' in runner 'r'"),
        ]
        for (yaml, expected) in invalid {
            do {
                _ = try DeclarativeConfig.parse(yaml).desiredRunners(hostCores: 8)
                XCTFail("expected failure for:\n\(yaml)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(expected), "\(error.localizedDescription) should mention \(expected)")
            }
        }
    }

    func testExportRoundTripsJITToolsAndCaches() throws {
        let docker = Runner(name: "linux-mbp-1", repo: "o/r", labels: ["self-hosted"], isolationMode: .container, containerEngine: .docker,
                            jit: true, containerToolsOverride: [], containerCachePaths: ["/home/runner/.cargo/registry"])
        let user = Runner(name: "macos-mbp-1", repo: "o/r", labels: ["self-hosted"], isolationMode: .dedicatedUser(username: "_macrunner"), jit: true)
        let classic = Runner(name: "plain", repo: "o/r", isolationMode: .container)

        let config = DeclarativeConfig.export(runners: [docker, user, classic], settings: AppSettings())
        XCTAssertEqual(config.runners.map(\.jit), [true, true, nil])
        XCTAssertEqual(config.runners.map(\.tools), [[], nil, nil])
        XCTAssertEqual(config.runners.map(\.cache), [["/home/runner/.cargo/registry"], nil, nil])

        let text = try config.yaml()
        XCTAssertTrue(text.contains("jit: true"), text)
        XCTAssertTrue(text.contains("tools: []"), text)
        let parsed = try DeclarativeConfig.parse(text)
        let plan = ConfigPlanner.plan(
            desired: try parsed.desiredRunners(hostCores: 8),
            desiredSettings: try parsed.resolvedSettings(AppSettings()),
            current: [docker, user, classic],
            currentSettings: AppSettings()
        )
        XCTAssertEqual(plan, [], "exporting then applying changes nothing:\n\(text)")
    }

    func testJITToolsAndCacheChangesRestartTheRunner() {
        let running = Runner(name: "r", repo: "o/r", status: .running, isolationMode: .container, containerEngine: .docker)
        func want(_ runner: Runner) -> DesiredRunner {
            DesiredRunner(name: runner.name, target: runner.target, labels: runner.labels, isolation: runner.isolationMode,
                          enableGUI: runner.enableGUI, openFileLimit: runner.openFileLimit, quietHours: runner.quietHours,
                          containerImage: runner.containerImage, containerEngine: runner.containerEngine,
                          containerCPUs: runner.containerCPUs, containerMemoryMB: runner.containerMemoryMB,
                          jit: runner.isJIT, containerToolsOverride: runner.containerToolsOverride,
                          containerCachePaths: runner.containerCachePaths)
        }
        func update(_ desired: DesiredRunner, from runner: Runner) -> (changes: [String], restart: Bool)? {
            let plan = ConfigPlanner.plan(desired: [desired], desiredSettings: AppSettings(), current: [runner], currentSettings: AppSettings())
            guard plan.count == 1, case .update(_, _, let changes, let restart) = plan[0] else { return nil }
            return (changes, restart)
        }

        var jit = want(running)
        jit.jit = true
        jit.containerToolsOverride = []
        jit.containerCachePaths = ["/home/runner/.cargo/registry"]
        XCTAssertEqual(update(jit, from: running)?.changes, ["jit on", "tools detected → none", "cache none → [/home/runner/.cargo/registry]"])
        XCTAssertEqual(update(jit, from: running)?.restart, true, "an in-place update that restarts it, not a re-registration")

        var stopped = running
        stopped.status = .stopped
        XCTAssertEqual(update(jit, from: stopped)?.restart, false)

        var jitRunner = running
        jitRunner.jit = true
        XCTAssertEqual(update(want(running), from: jitRunner)?.changes, ["jit off"])
        var tools = want(running)
        tools.containerToolsOverride = ["jq"]
        XCTAssertEqual(update(tools, from: running)?.changes, ["tools detected → [jq]"])
    }
}
