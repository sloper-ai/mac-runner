import Foundation

/// Just-in-time (single-use) runners: each start registers a new runner from a
/// JIT config (`GHCLIService.generateJITConfig`), with a fresh workspace, and
/// that registration is deleted once the runner exits.
///
/// The JIT config is a secret (the runner's credentials). It reaches the runner
/// in the `ACTIONS_RUNNER_INPUT_JITCONFIG` environment variable, which the
/// runner reads like the `--jitconfig` argument (and then removes from its own
/// environment), so it never appears in argv or `ps`:
/// - Docker: the launcher names it (`-e ACTIONS_RUNNER_INPUT_JITCONFIG`); its
///   value comes from the launcher's environment.
/// - Apple's engine: it's in the container process's environment.
/// - No isolation: it's in run.sh's environment.
/// - A dedicated user: sudo resets the environment, so it's written to a 0600
///   file owned by that user (from stdin), which the launch command reads into
///   the variable and deletes before starting run.sh.
enum JITRunner {
    /// The environment variable the runner reads its JIT config from.
    static let configVariable = "ACTIONS_RUNNER_INPUT_JITCONFIG"
    /// Process isolation with a dedicated user: where the config waits for the
    /// launch command, in the runner's directory.
    static let configFileName = ".jitconfig"
    /// What the runner writes from its JIT config into its directory.
    static let credentialFileNames = [".runner", ".credentials", ".credentials_rsaparams"]
    /// GitHub's default runner group, which JIT runners join.
    static let runnerGroupID = 1
    /// A clean exit sooner than this, without running a job, is treated like a
    /// crash (backoff), so a runner that can't take jobs doesn't spin.
    static let minimumHealthyRun: TimeInterval = 30

    /// A name for one start's registration: `<runner name>-<6 hex>`. Names must
    /// be unique, and the previous start's registration may not be deleted yet.
    static func registrationName(for runnerName: String, suffix: UInt32 = UInt32.random(in: 0..<0x100_0000)) -> String {
        "\(runnerName)-\(String(format: "%06x", suffix & 0xFF_FFFF))"
    }

    /// Whether `registration` is one of `runnerName`'s JIT registrations.
    static func isRegistrationName(_ registration: String, of runnerName: String) -> Bool {
        let prefix = runnerName + "-"
        guard registration.hasPrefix(prefix) else { return false }
        let suffix = registration.dropFirst(prefix.count)
        return suffix.count == 6 && suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Offline registrations left by `runnerName`'s earlier starts (Mac Runner
    /// was killed before it could delete one, say). A live one is never included.
    static func leftoverRegistrations(of runnerName: String, in remote: [RemoteRunner]) -> [RemoteRunner] {
        remote.filter { $0.status == "offline" && isRegistrationName($0.name, of: runnerName) }
    }

    // MARK: - Exits

    /// What to do once a JIT runner's process or container has exited.
    enum ExitAction: Equatable {
        /// It was stopped, paused, or removed on purpose; whoever did that
        /// deletes the registration.
        case stopped
        /// Its job is done (or it was up long enough to be healthy): delete the
        /// spent registration and start the next one right away. Not a crash.
        case startNext
        /// Delete the registration, then the usual crash backoff and retry limit apply.
        case crash(reason: String)
    }

    /// - Parameters:
    ///   - stillWanted: Its status still says running, and no stop was requested.
    ///   - cleanExit: It exited with status 0 (unknown exits count as clean).
    ///   - exitDescription: The exit, as the crash message gives it.
    ///   - ranJob: Its log shows it started a job, or GitHub had already deleted it.
    ///   - uptime: How long it ran.
    static func exitAction(
        stillWanted: Bool,
        cleanExit: Bool,
        exitDescription: String,
        ranJob: Bool,
        uptime: TimeInterval
    ) -> ExitAction {
        guard stillWanted else { return .stopped }
        guard cleanExit else { return .crash(reason: exitDescription) }
        if ranJob || uptime >= minimumHealthyRun {
            return .startNext
        }
        return .crash(reason: "exited after \(max(0, Int(uptime)))s without running a job")
    }

    /// The line Mac Runner writes to runner.log when a registration starts.
    static func startMessage(for registration: JITRegistration) -> String {
        "Registered single-use runner \(registration.name) (GitHub ID \(registration.id)) for one job."
    }

    /// Whether the runner started a job after `registration` was started, going by
    /// runner.log's `lines`; nil when the start isn't in them (rotated away, say).
    static func ranJob(in lines: [String], since registration: JITRegistration) -> Bool? {
        let marker = "[mac-runner] " + startMessage(for: registration)
        guard let start = lines.lastIndex(where: { $0.hasSuffix(marker) }) else { return nil }
        return lines[lines.index(after: start)...].contains { line in
            if case .jobStarted? = RunnerLogEvent.parse(line) { return true }
            return false
        }
    }

    // MARK: - Process isolation

    /// Shell command, run before run.sh in the runner's directory, that gives
    /// each job a fresh workspace: it deletes `_work` and the previous
    /// registration's files. With `configFile` (a dedicated user), it first reads
    /// the JIT config from that file into `ACTIONS_RUNNER_INPUT_JITCONFIG` and
    /// deletes the file; it fails if the file was empty or missing.
    static func launchPrelude(runnerDirectory: String, configFile: String?) -> String {
        let directory = runnerDirectory.hasSuffix("/") ? String(runnerDirectory.dropLast()) : runnerDirectory
        let work = quoted(directory + "/_work")
        // Jobs can leave read-only directories (Go's module cache, say), which rm can't empty.
        let reset = "{ chmod -R -P u+w \(work) 2>/dev/null || true; } && rm -rf \(work) && rm -f "
            + credentialFileNames.map { quoted(directory + "/" + $0) }.joined(separator: " ")
        guard let configFile else { return reset }
        let file = quoted(configFile)
        // Only builtins see the value: an assignment, `[`, and export.
        return "{ \(configVariable)=\"$(cat \(file))\"; rm -f \(file); [ -n \"$\(configVariable)\" ]; } "
            + "&& export \(configVariable) && \(reset)"
    }

    /// Shell command, run as the dedicated user with the JIT config on stdin,
    /// that writes it to `path` readable by that user alone.
    static func writeConfigCommand(path: String) -> String {
        "umask 077 && rm -f \(quoted(path)) && cat > \(quoted(path))"
    }

    /// Shell command deleting what a JIT run leaves in the runner's directory:
    /// the registration's credentials and any config file not yet read.
    static func credentialCleanupCommand(runnerDirectory: String) -> String {
        let directory = runnerDirectory.hasSuffix("/") ? String(runnerDirectory.dropLast()) : runnerDirectory
        return "rm -f " + (credentialFileNames + [configFileName])
            .map { quoted(directory + "/" + $0) }
            .joined(separator: " ")
    }

    /// Write `config` to the runner directory's config file as `serviceUser`,
    /// passing it on stdin so it's never in an argument list. Returns its path.
    static func writeConfigFile(_ config: String, runnerDirectory: String, serviceUser: String) throws -> String {
        try requireRunnerDirectory(runnerDirectory)
        let path = (runnerDirectory as NSString).appendingPathComponent(configFileName)
        let result = try ProcessExecutor.run(
            "/usr/bin/sudo",
            arguments: UserIsolationService.sudoShellArguments(
                username: serviceUser,
                shell: "/bin/bash",
                command: writeConfigCommand(path: path)
            ),
            input: Data(config.utf8)
        )
        guard result.succeeded else {
            throw ProcessExecutorError.executionFailed("Failed to hand the JIT config to \(serviceUser): \(result.output)")
        }
        return path
    }

    /// Delete a JIT run's credentials (and an unread config) from the runner's
    /// directory: as `serviceUser` when it owns the directory. Errors are ignored.
    static func removeCredentials(runnerDirectory: String, serviceUser: String?) {
        guard (try? requireRunnerDirectory(runnerDirectory)) != nil else { return }
        let command = credentialCleanupCommand(runnerDirectory: runnerDirectory)
        if let serviceUser {
            _ = try? ProcessExecutor.run(
                "/usr/bin/sudo",
                arguments: UserIsolationService.sudoShellArguments(username: serviceUser, shell: "/bin/bash", command: command)
            )
        } else {
            _ = try? ProcessExecutor.run("/bin/bash", arguments: ["-c", command])
        }
    }

    /// Commands above delete things in `directory`: make sure it's a runner's.
    static func requireRunnerDirectory(_ directory: String) throws {
        guard directory.hasPrefix("/"), directory.contains("/.mac-runner/runners/") else {
            throw RunnerDirectoryError.refusedUnsafeRemoval(directory)
        }
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Held while a process starts a JIT runner, and by a stop waiting for that
/// start, so two Mac Runner processes (the app and a CLI) never start the same
/// runner at once, and a stop always sees the registration a start made. An
/// advisory lock (flock) on a file next to the runner's PID file; the system
/// releases it if its process dies.
final class RunnerStartLock {
    private var fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    static func path(for id: UUID) throws -> String {
        let pidFile = try PIDFileManager().pidFilePath(for: id)
        return (pidFile as NSString).deletingPathExtension + ".start-lock"
    }

    /// The lock, or nil when another holder has it (or it can't be opened).
    static func tryAcquire(for id: UUID) -> RunnerStartLock? {
        guard let path = try? path(for: id) else { return nil }
        return tryAcquire(path: path)
    }

    static func tryAcquire(path: String) -> RunnerStartLock? {
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return RunnerStartLock(fd: fd)
    }

    /// The lock once it's free, or nil after `timeout`.
    static func acquire(for id: UUID, waitingUpTo timeout: TimeInterval) async -> RunnerStartLock? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let lock = tryAcquire(for: id) { return lock }
            guard Date() < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Whether someone holds it right now (or it can't be checked).
    static func isHeld(for id: UUID) -> Bool {
        guard let lock = tryAcquire(for: id) else { return true }
        lock.unlock()
        return false
    }

    static func removeFile(for id: UUID) {
        if let path = try? path(for: id) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    func unlock() {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit {
        unlock()
    }
}
