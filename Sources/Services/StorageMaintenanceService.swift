import Foundation

/// All callers hold admissionLock through cleanup and publication of the next
/// runner PID. A second GUI or CLI therefore cannot launch into shared cleanup.
struct StorageMaintenanceService: Sendable {
    typealias Execute = @Sendable (String, [String], TimeInterval) async -> ProcessExecutor.ProcessResult?
    var execute: Execute = { executable, arguments, timeout in
        await DockerRunnerEngine.run(executable, arguments, timeout: timeout)
    }
    var home = FileManager.default.homeDirectoryForCurrentUser
    var hostAvailableBytes: @Sendable (URL) -> Int64? = { DiskCleanupService(homeDirectory: $0).availableDiskBytes() }

    static func admissionLock() -> RunnerStartLock? {
        guard let pid = try? PIDFileManager().pidFilePath(for: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!) else { return nil }
        return RunnerStartLock.tryAcquire(path: (pid as NSString).deletingLastPathComponent + "/storage-maintenance.lock")
    }

    static func acquireAdmissionLock() async -> RunnerStartLock? {
        let deadline = Date().addingTimeInterval(300)
        repeat {
            if let lock = admissionLock() { return lock }
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline
        return nil
    }

    /// A status field is not evidence that a process has stopped. Inspect the
    /// actual PIDs as well; an idle listener can accept a job at any instant.
    static func canCleanSharedCaches(runners: [Runner], isolation: IsolationMode, isAlive: (UUID) -> Bool) -> Bool {
        !runners.contains { runner in
            runner.effectiveIsolationMode(global: isolation) != .container && isAlive(runner.id)
        }
    }

    func prepare(runner: Runner, runners: [Runner], settings: AppSettings, canCleanShared: Bool) async throws -> [String] {
        guard settings.automaticDiskCleanupEnabled else { return [] }
        var messages: [String] = []
        let initialHost = hostAvailableBytes(home)
        let pressure = initialHost.map { $0 < StorageMaintenanceSettings.bytes(settings.minimumFreeDiskSpaceGB) } ?? false
        let isolation = runner.effectiveIsolationMode(global: settings.isolationMode)
        if isolation == .none {
            if canCleanShared {
                let home = home
                let policy = settings.storageMaintenance
                let report = try await Task.detached(priority: .utility) {
                    try DisposableCache.maintain(
                        home: home, maxBytes: pressure ? 0 : StorageMaintenanceSettings.bytes(policy.maxCacheSizeGB),
                        maxAgeDays: policy.cacheMaxAgeDays
                    )
                }.value
                messages.append("Package caches: discarded \(report.reclaimedBytes) bytes; \(report.remainingBytes) bytes retained.")
            } else {
                messages.append("Shared cache cleanup deferred: another native runner is alive.")
            }
        } else if case .dedicatedUser = isolation {
            // Never assume the current user's home is the service user's cache.
            messages.append("Shared cache cleanup skipped for dedicated-user isolation.")
        }
        if runner.runsInDocker(global: settings.isolationMode) {
            messages += try await prepareDocker(runner: runner, settings: settings, pressure: pressure)
        }
        // Cleanup may have returned guest blocks to the VM; TRIM can return them to APFS.
        messages += await trimIfDue(settings: settings, hasDockerRunners: runners.contains { $0.runsInDocker(global: settings.isolationMode) })
        let host = hostAvailableBytes(home)
        try StorageAdmission.check(bytes: host, minimumGB: settings.minimumFreeDiskSpaceGB, filesystem: "Mac filesystem")
        messages.append("Mac free space: \(host ?? 0) bytes.")
        return messages
    }

    private func require(_ executable: String, _ args: [String], timeout: TimeInterval = 120) async throws -> String {
        guard let result = await execute(executable, args, timeout) else {
            throw StorageMaintenanceError(message: "Storage command timed out or could not start: \(args.prefix(2).joined(separator: " ")).")
        }
        guard result.succeeded else {
            throw StorageMaintenanceError(message: "Storage check failed: \(args.prefix(2).joined(separator: " ")). \(result.output.suffix(1500))")
        }
        return result.output
    }

    private func helper(_ docker: String, _ arguments: [String]) async throws -> String {
        let name = "mac-runner-maintenance-" + UUID().uuidString
        var arguments = arguments
        arguments.insert(contentsOf: ["--name", name], at: 1)
        do { return try await require(docker, arguments, timeout: 300) }
        catch {
            // Killing a timed-out Docker client need not kill its container. This
            // unique name belongs to this call, never to a job or another helper.
            _ = await execute(docker, ["rm", "-f", name], 30)
            throw error
        }
    }

    func prepareDocker(runner: Runner, settings: AppSettings, pressure: Bool, docker: String? = nil) async throws -> [String] {
        guard let docker = docker ?? DockerRunnerEngine.executablePath() else {
            throw StorageMaintenanceError(message: "Docker is unavailable for the guest storage check.")
        }
        let policy = settings.storageMaintenance
        let work = DockerRunnerEngine.workVolumeName(for: runner.id)
        let mounts = DockerRunnerEngine.cacheMounts(for: runner.id, paths: runner.containerCachePaths ?? [])
        let dockerData = DockerRunnerEngine.dockerVolumeName(for: runner.id)
        let volumes = [work] + mounts.map(\.volume) + (runner.dockerInDocker == true ? [dockerData] : [])
        // Check references, including stopped containers and unmanaged users of a
        // runner volume. Never remove or mutate a volume another container uses.
        for volume in volumes {
            let users = try await require(docker, ["ps", "-aq", "--filter", "volume=\(volume)"])
            guard users.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StorageMaintenanceError(message: "Runner storage is still attached to a container; waiting for it to exit.")
            }
        }
        if runner.isJIT {
            _ = try await require(docker, ["volume", "rm", "-f", work])
        }
        let image = runner.containerImage ?? ContainerRunnerConfiguration.defaultRunnerImage
        var args = ["run", "--rm", "--pull=never", "--network=none", "--read-only", "--user=0", "--cap-drop=ALL", "--cap-add=DAC_OVERRIDE", "--cap-add=FOWNER",
                    "--security-opt=no-new-privileges", "--pids-limit=128", "--memory=256m",
                    "--mount", "type=volume,src=\(work),dst=/storage-work,volume-nocopy"]
        var roots: [String] = []
        for (index, mount) in mounts.enumerated() {
            let allowed = DisposableCache.paths(inMount: mount.path)
            guard !allowed.isEmpty else { continue }
            let target = "/storage-cache-\(index)"
            args += ["--mount", "type=volume,src=\(mount.volume),dst=\(target),volume-nocopy"]
            roots += allowed.map { $0 == "." ? target : target + "/" + $0 }
        }
        if runner.dockerInDocker == true {
            args += ["--mount", "type=volume,src=\(dockerData),dst=/storage-docker,readonly,volume-nocopy"]
        }
        args += ["-e", "MR_CACHE_AGE=\(policy.cacheMaxAgeDays)", "-e", "MR_CACHE_BYTES=\(StorageMaintenanceSettings.bytes(policy.maxCacheSizeGB))",
                 "-e", "MR_GUEST_BYTES=\(StorageMaintenanceSettings.bytes(policy.minimumGuestFreeDiskSpaceGB))",
                 "-e", "MR_PRESSURE=\(pressure ? 1 : 0)", "--entrypoint", "/bin/bash", image,
                 "-c", StorageMaintenanceScript.script, "storage-maintenance"] + roots
        let output = try await helper(docker, args)
        var messages = ["Docker package caches: \(StorageMaintenanceScript.value("MR_CACHE_REMAINING", in: output) ?? 0) bytes retained."]
        var free = StorageMaintenanceScript.value("MR_GUEST_AVAILABLE", in: output)
        if runner.dockerInDocker == true {
            guard let size = StorageMaintenanceScript.value("MR_DOCKER_BYTES", in: output) else {
                throw StorageMaintenanceError(message: "Cannot measure the runner's private Docker data.")
            }
            let stamp = stateDirectory.appendingPathComponent("docker-\(runner.id.uuidString).date")
            let lastReset = readDate(stamp)
            if Self.resetDockerData(bytes: size, lastReset: lastReset, policy: policy, pressure: pressure || (free ?? 0) < StorageMaintenanceSettings.bytes(policy.minimumGuestFreeDiskSpaceGB)) {
                // No -f: Docker also enforces that the volume is unused.
                _ = try await require(docker, ["volume", "rm", dockerData])
                try writeDate(Date(), to: stamp)
                messages.append("Reset private Docker cache (\(size) bytes); configured runner image preserved.")
                let probe = try await helper(docker, ["run", "--rm", "--pull=never", "--network=none", "--read-only",
                    "--mount", "type=volume,src=\(work),dst=/storage-work,readonly,volume-nocopy", "--entrypoint", "/bin/sh", image,
                    "-c", "df -Pk /storage-work | awk 'NR==2 {printf \"MR_GUEST_AVAILABLE=%.0f\\n\", $4 * 1024}'"])
                free = StorageMaintenanceScript.value("MR_GUEST_AVAILABLE", in: probe)
            }
        }
        try StorageAdmission.check(bytes: free, minimumGB: policy.minimumGuestFreeDiskSpaceGB, filesystem: "Docker guest filesystem")
        messages.append("Docker guest free space: \(free ?? 0) bytes.")
        return messages
    }

    static func resetDockerData(bytes: Int64, lastReset: Date?, policy: StorageMaintenanceSettings, pressure: Bool, now: Date = Date()) -> Bool {
        pressure || bytes > StorageMaintenanceSettings.bytes(policy.maxDockerDataSizeGB)
            || (lastReset.map { now.timeIntervalSince($0) >= Double(policy.cacheMaxAgeDays) * 86400 } ?? true)
    }

    var stateDirectory: URL { home.appendingPathComponent(".mac-runner/maintenance") }

    private func readDate(_ url: URL) -> Date? {
        guard let value = try? String(contentsOf: url, encoding: .utf8), let seconds = Double(value) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private func writeDate(_ date: Date, to url: URL) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        guard DisposableCache.safeDirectory(stateDirectory, under: home.resolvingSymlinksInPath()) else {
            throw StorageMaintenanceError(message: "Maintenance state directory must not be a symlink.")
        }
        try String(date.timeIntervalSince1970).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Read-only checks also run during long jobs. They report pressure without
    /// deleting anything or interrupting the job; admission blocks the next one.
    func monitor(runners: [Runner], settings: AppSettings) async -> String? {
        guard settings.automaticDiskCleanupEnabled else { return nil }
        var issues: [String] = []
        do {
            try StorageAdmission.check(bytes: hostAvailableBytes(home), minimumGB: settings.minimumFreeDiskSpaceGB, filesystem: "Mac filesystem")
        } catch { issues.append(error.localizedDescription) }
        if let runner = runners.first(where: { $0.status == .running && $0.runsInDocker(global: settings.isolationMode) }),
           let docker = DockerRunnerEngine.executablePath() {
            let result = await execute(docker, ["exec", DockerRunnerEngine.containerName(for: runner.id), "/bin/sh", "-c",
                "df -Pk /mac-runner/_work | awk 'NR==2 {printf \"MR_GUEST_AVAILABLE=%.0f\\n\", $4 * 1024}'"], 20)
            if let result, result.succeeded {
                do {
                    try StorageAdmission.check(bytes: StorageMaintenanceScript.value("MR_GUEST_AVAILABLE", in: result.output),
                                               minimumGB: settings.storageMaintenance.minimumGuestFreeDiskSpaceGB, filesystem: "Docker guest filesystem")
                } catch { issues.append(error.localizedDescription) }
            }
            // A JIT container can disappear between the snapshot and exec; its
            // next preflight measures capacity before it can register again.
        }
        return issues.isEmpty ? nil : issues.joined(separator: " ")
    }

    /// Only a local Colima profile whose status agrees with the selected Docker
    /// endpoint is supported. A remote Docker host must never trigger local TRIM.
    static func colimaProfile(endpoint: String, home: URL) -> String? {
        let prefix = "unix://" + home.path + "/.colima/"
        guard endpoint.hasPrefix(prefix), endpoint.hasSuffix("/docker.sock") else { return nil }
        let profile = String(endpoint.dropFirst(prefix.count).dropLast("/docker.sock".count))
        guard !profile.isEmpty, profile != ".", profile != "..",
              profile.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return profile
    }

    func trimIfDue(settings: AppSettings, hasDockerRunners: Bool, now: Date = Date(), environment: [String: String] = ProcessInfo.processInfo.environment) async -> [String] {
        guard settings.automaticDiskCleanupEnabled, settings.storageMaintenance.dailyVMTrimEnabled, hasDockerRunners,
              let docker = DockerRunnerEngine.executablePath(environment: environment, home: home) else { return [] }
        let attempt = stateDirectory.appendingPathComponent("trim-attempt.date")
        if let last = readDate(attempt), now.timeIntervalSince(last) < 3600 { return [] }
        do { try writeDate(now, to: attempt) } catch { return ["VM TRIM state error: \(error.localizedDescription)"] }
        let endpoint: String
        if environment["DOCKER_CONTEXT"]?.isEmpty != false, let host = environment["DOCKER_HOST"], !host.isEmpty {
            endpoint = host
        } else {
            guard let result = await execute(docker, ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], 20), result.succeeded else {
                return ["VM TRIM deferred: cannot resolve Docker endpoint."]
            }
            endpoint = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let profile = Self.colimaProfile(endpoint: endpoint, home: home) else {
            return ["VM TRIM unsupported for this Docker endpoint; free-space admission checks remain enabled."]
        }
        let success = stateDirectory.appendingPathComponent("trim-\(profile).date")
        if let last = readDate(success), now.timeIntervalSince(last) < 86400 { return [] }
        let paths = RunnerEnvironment.normalizedPath(environment["PATH"]).split(separator: ":").map { "\($0)/colima" }
        guard let colima = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let status = await execute(colima, ["--profile", profile, "status", "--json"], 20), status.succeeded,
              let data = status.output.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["runtime"] as? String == "docker", json["docker_socket"] as? String == endpoint else {
            return ["VM TRIM deferred: local Colima status does not match the Docker endpoint."]
        }
        // fstrim only discards free filesystem blocks. It is safe with live jobs;
        // never compact, resize, stop, or rewrite a VM disk image from the host.
        guard let result = await execute(colima, ["--profile", profile, "ssh", "--", "sudo", "-n", "env", "LC_ALL=C", "fstrim", "-av"], 120), result.succeeded else {
            return ["VM TRIM failed or is unsupported by the guest; retrying in an hour."]
        }
        guard result.output.contains(" bytes) trimmed") else {
            return ["VM TRIM reported no discard-capable filesystem; retrying in an hour."]
        }
        do { try writeDate(now, to: success) } catch { return ["VM TRIM succeeded, but saving its date failed: \(error.localizedDescription)"] }
        return ["Daily VM TRIM succeeded: " + result.output.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
}
