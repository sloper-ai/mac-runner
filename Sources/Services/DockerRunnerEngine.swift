import CryptoKit
import Foundation

/// Runs container runners in Docker instead of Apple's Containerization.
///
/// A Docker runner is an ordinary background process, like a runner without
/// isolation: `docker-run.sh` in its directory execs `docker run` in the
/// foreground, so the runner lives exactly as long as that process, which
/// outlives the Mac Runner process that started it. The container runs
/// `ContainerRunnerScript`, as Apple's engine does. Its work directory is a
/// Docker volume, a real Linux filesystem (the Apple engine's virtio-fs share
/// refuses the mode-0 files GNU tar creates while extracting some archives);
/// `runner.log` and `_diag` stay in the runner's directory.
enum DockerRunnerEngine {
    /// Label on each runner's container; its value is the runner's ID.
    static let runnerIDLabel = "ai.omniaura.mac-runner.id"
    /// In the runner's directory: the launcher, and the startup script it mounts.
    static let launcherFileName = "docker-run.sh"
    static let scriptFileName = "container-runner.sh"
    /// Where the startup script is mounted in the container.
    static let scriptMount = "/mac-runner/run-runner.sh"
    /// How long a stopping runner gets to sign off before its container is removed.
    static let stopGracePeriod: TimeInterval = 10

    /// What Docker containers get on top of the startup script's inputs. With
    /// it, the runner's `run.sh` turns a stop signal into an interrupt for the
    /// listener, which then signs off from GitHub before it exits.
    static let engineVariables: [(name: String, value: String)] = [("RUNNER_MANUALLY_TRAP_SIG", "1")]

    static func containerName(for id: UUID) -> String {
        "mac-runner-\(id.uuidString)"
    }

    static func workVolumeName(for id: UUID) -> String {
        "mac-runner-\(id.uuidString)-work"
    }

    /// Docker-in-Docker: the volume holding the runner's own Docker daemon's
    /// data (images, layers), kept across containers.
    static func dockerVolumeName(for id: UUID) -> String {
        "mac-runner-\(id.uuidString)-docker"
    }

    /// Where the runner's own Docker daemon keeps its data in the container.
    static let dockerDataMount = "/var/lib/docker"

    // MARK: - Cache Volumes

    /// Every cache volume of the runner starts with this.
    static func cacheVolumePrefix(for id: UUID) -> String {
        "mac-runner-\(id.uuidString)-cache-"
    }

    /// The volume behind a cache path: `mac-runner-<id>-cache-<8 hex of its SHA-256>`.
    static func cacheVolumeName(for id: UUID, path: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedCachePath(path).utf8))
        return cacheVolumePrefix(for: id) + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The runner's cache volumes and where each is mounted, in the order given.
    static func cacheMounts(for id: UUID, paths: [String]) -> [(volume: String, path: String)] {
        paths.map { (cacheVolumeName(for: id, path: $0), normalizedCachePath($0)) }
    }

    /// A container path with repeated and trailing slashes removed.
    static func normalizedCachePath(_ path: String) -> String {
        "/" + path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    /// Container paths to back with cache volumes, normalized and without
    /// duplicates; or why one can't be: each must be absolute, not `/`, outside
    /// the runner's own mounts (`/mac-runner`), free of `.`/`..` parts, and free
    /// of `:` and `,` (which `docker run -v` would split on).
    static func cachePaths(_ raw: [String]) -> Result<[String], CLIParseError> {
        var paths: [String] = []
        for entry in raw {
            let path = entry.trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/") else {
                return .failure(.message("cache path '\(entry)' must be an absolute path in the container"))
            }
            guard !path.contains(":"), !path.contains(","), !path.contains(where: { $0.isNewline || $0 == "\0" }) else {
                return .failure(.message("cache path '\(entry)' can't contain ':' or ','"))
            }
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            guard !parts.isEmpty else {
                return .failure(.message("cache path '\(entry)' can't be the container's root"))
            }
            guard !parts.contains(where: { $0 == "." || $0 == ".." }) else {
                return .failure(.message("cache path '\(entry)' can't contain '.' or '..'"))
            }
            let normalized = normalizedCachePath(path)
            guard normalized != "/mac-runner", !normalized.hasPrefix("/mac-runner/") else {
                return .failure(.message("cache path '\(entry)' is inside /mac-runner, where Mac Runner mounts the runner's own directories"))
            }
            if !paths.contains(normalized) {
                paths.append(normalized)
            }
        }
        return .success(paths)
    }

    // MARK: - Launcher

    /// The launcher. It frees the runner's container name (a crash can leave
    /// the previous container behind), then execs `docker run` in the
    /// foreground. The startup script's variables are passed by name only
    /// (`-e NAME`): their values, the registration token or a JIT config among
    /// them, come from the environment the launcher is started with and are
    /// never written here.
    /// - Parameters:
    ///   - resetWorkVolume: Delete the work volume first, so the container starts
    ///     with an empty one (JIT runners: a fresh workspace for every job). The
    ///     launch fails if it can't be deleted.
    ///   - cacheMounts: Volumes mounted at these container paths, kept across containers.
    ///   - dockerInDocker: Run the container privileged, with the volume for its
    ///     own Docker daemon's data at /var/lib/docker (kept across containers).
    static func launcherScript(
        docker: String,
        runnerID: UUID,
        runnerName: String,
        runnerDirectory: String,
        image: String,
        cpus: Int,
        memoryMB: Int,
        openFileLimit: Int,
        environmentNames: [String],
        resetWorkVolume: Bool = false,
        cacheMounts: [(volume: String, path: String)] = [],
        dockerInDocker: Bool = false
    ) -> String {
        let container = containerName(for: runnerID)
        let workVolume = workVolumeName(for: runnerID)
        let lines: [[String]] = [
            [docker, "run", "--rm", "--init"],
            // A Docker daemon in the container needs it (mounts, cgroups, iptables).
            dockerInDocker ? ["--privileged"] : [],
            ["--name", container],
            ["--hostname", ContainerRunnerScript.hostname(for: runnerName)],
            ["--label", "\(runnerIDLabel)=\(runnerID.uuidString)"],
            ["-v", "\(workVolume):\(ContainerRunnerScript.workMount)"],
            cacheMounts.flatMap { ["-v", "\($0.volume):\($0.path)"] },
            dockerInDocker ? ["-v", "\(dockerVolumeName(for: runnerID)):\(dockerDataMount)"] : [],
            ["-v", "\(runnerDirectory)/_diag:\(ContainerRunnerScript.diagnosticsMount)"],
            ["-v", "\(runnerDirectory)/\(scriptFileName):\(scriptMount):ro"],
            ["--cpus", "\(cpus)", "--memory", "\(memoryMB)m"],
            ["--ulimit", "nofile=\(openFileLimit):\(openFileLimit)"],
            environmentNames.flatMap { ["-e", $0] },
            // Like Apple's engine, run the script whatever the image's entrypoint is.
            ["--entrypoint", "bash", image, scriptMount],
        ]
        let command = lines
            .filter { !$0.isEmpty }
            .map { $0.map(shellQuoted).joined(separator: " ") }
            .joined(separator: " \\\n  ")
        let dockerDirectory = (docker as NSString).deletingLastPathComponent
        // After the container is gone; `volume rm -f` succeeds when there's no volume.
        let reset = resetWorkVolume ? """
        # A fresh workspace for every job: an empty work volume.
        if ! \(shellQuoted(docker)) volume rm -f \(shellQuoted(workVolume)) >/dev/null; then
          echo "[mac-runner] ERROR: could not delete the work volume \(workVolume) to give this job a fresh workspace; not starting the runner." >&2
          exit 1
        fi

        """ : ""

        return """
        #!/bin/bash
        # Written by Mac Runner each time this runner starts. The container's
        # variables are named here; their values come from Mac Runner.
        # docker finds its credential helpers next to itself.
        export PATH=\(shellQuoted(dockerDirectory)):"$PATH"
        \(shellQuoted(docker)) rm -f \(shellQuoted(container)) >/dev/null 2>&1 || true
        \(reset)exec \(command)

        """
    }

    /// Write the startup script and the launcher into the runner's directory,
    /// returning the launcher's path. The script stays readable by the
    /// container's user; the launcher is the host user's own.
    static func writeLaunchFiles(
        docker: String,
        runnerID: UUID,
        runnerName: String,
        runnerDirectory: String,
        image: String,
        cpus: Int,
        memoryMB: Int,
        openFileLimit: Int,
        environmentNames: [String],
        resetWorkVolume: Bool = false,
        cacheMounts: [(volume: String, path: String)] = [],
        dockerInDocker: Bool = false
    ) throws -> String {
        let directory = URL(fileURLWithPath: runnerDirectory, isDirectory: true)

        let script = directory.appendingPathComponent(scriptFileName)
        try ("#!/bin/bash\n" + ContainerRunnerScript.script + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)

        let launcher = directory.appendingPathComponent(launcherFileName)
        let contents = launcherScript(
            docker: docker,
            runnerID: runnerID,
            runnerName: runnerName,
            runnerDirectory: runnerDirectory,
            image: image,
            cpus: cpus,
            memoryMB: memoryMB,
            openFileLimit: openFileLimit,
            environmentNames: environmentNames,
            resetWorkVolume: resetWorkVolume,
            cacheMounts: cacheMounts,
            dockerInDocker: dockerInDocker
        )
        try contents.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        return launcher.path
    }

    /// `value` as one shell word: as it is when that's safe, else single-quoted.
    static func shellQuoted(_ value: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        if !value.isEmpty, value.unicodeScalars.allSatisfy(plain.contains) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Docker CLI

    /// The docker CLI: the first on the runner PATH (which adds Homebrew's and
    /// /usr/local/bin), else where Docker Desktop, OrbStack, or Rancher Desktop
    /// install it for one user. nil when Docker isn't installed.
    static func executablePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let onPath = RunnerEnvironment.normalizedPath(environment["PATH"])
            .split(separator: ":")
            .filter { $0.hasPrefix("/") }
            .map { "\($0)/docker" }
        let perUser = [".docker/bin/docker", ".orbstack/bin/docker", ".rd/bin/docker"]
            .map { home.appendingPathComponent($0).path }
        return (onPath + perUser + ["/Applications/Docker.app/Contents/Resources/bin/docker"])
            .first(where: isExecutable)
    }

    /// Run docker off the main actor; nil if it couldn't start or timed out.
    static func run(_ docker: String, _ arguments: [String], timeout: TimeInterval = 30) async -> ProcessExecutor.ProcessResult? {
        await Task.detached(priority: .utility) {
            try? ProcessExecutor.run(docker, arguments: arguments, timeout: timeout)
        }.value
    }

    /// What the Docker daemon reports about itself.
    struct DaemonInfo: Equatable, Sendable {
        /// CPUs Docker can give a container (on a Mac, its VM's); nil if unreadable.
        var cpuCount: Int?
    }

    /// What the daemon reports, or nil when it doesn't answer.
    static func daemonInfo(docker: String) async -> DaemonInfo? {
        guard let result = await run(docker, ["info", "--format", "{{.NCPU}}"], timeout: 20), result.succeeded else {
            return nil
        }
        // Warnings, if any, come on lines of their own.
        let cpuCount = result.output.split(separator: "\n")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .last
        return DaemonInfo(cpuCount: cpuCount)
    }

    /// The docker CLI to start a runner with, once its daemon answers.
    static func requireRunningDaemon() async throws -> (docker: String, info: DaemonInfo) {
        guard let docker = executablePath() else { throw RunnerError.dockerNotFound }
        guard let info = await daemonInfo(docker: docker) else { throw RunnerError.dockerNotRunning }
        return (docker, info)
    }

    /// Wait up to `timeout` for the daemon to answer: at login, Docker Desktop
    /// can take longer to start than Mac Runner.
    static func waitForDaemon(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let docker = executablePath(), await daemonInfo(docker: docker) != nil {
                return true
            }
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// CPUs for `runner`'s container. A count the runner sets must fit in what
    /// Docker has (`docker run` refuses more); the default is capped at it.
    static func cpus(for runner: Runner, dockerCPUs: Int?) throws -> Int {
        guard let dockerCPUs else { return runner.effectiveContainerCPUs }
        guard let requested = runner.containerCPUs else {
            return min(ResourceLimits.defaultContainerCPUs, dockerCPUs)
        }
        guard requested <= dockerCPUs else {
            throw RunnerError.dockerHasTooFewCPUs(requested: requested, available: dockerCPUs)
        }
        return requested
    }

    // MARK: - Cleanup

    /// Remove the runner's container, if any. Errors are ignored: it may be
    /// gone already, or Docker may not be running.
    static func removeContainer(for id: UUID) async {
        guard let docker = executablePath() else { return }
        _ = await run(docker, ["rm", "-f", containerName(for: id)])
    }

    /// Remove the runner's container and its work volume (errors ignored).
    /// Returns whether a volume was removed.
    @discardableResult
    static func removeContainerAndWorkVolume(for id: UUID) async -> Bool {
        guard let docker = executablePath() else { return false }
        _ = await run(docker, ["rm", "-f", containerName(for: id)])
        return await run(docker, ["volume", "rm", workVolumeName(for: id)])?.succeeded ?? false
    }

    /// Remove the runner's container, its work volume, its Docker-in-Docker
    /// volume, and all its cache volumes, including ones for paths it no
    /// longer lists (errors ignored). Returns how many volumes were removed.
    @discardableResult
    static func removeContainerAndVolumes(for id: UUID) async -> Int {
        guard let docker = executablePath() else { return 0 }
        let removedWork = await removeContainerAndWorkVolume(for: id)
        let removedDocker = await run(docker, ["volume", "rm", dockerVolumeName(for: id)])?.succeeded ?? false
        let removedCaches = await removeCacheVolumes(for: id, docker: docker)
        return (removedWork ? 1 : 0) + (removedDocker ? 1 : 0) + removedCaches
    }

    /// Remove the runner's Docker-in-Docker volume, its images with it (errors
    /// ignored; one a container still uses stays).
    static func removeDockerVolume(for id: UUID) async {
        guard let docker = executablePath() else { return }
        _ = await run(docker, ["volume", "rm", dockerVolumeName(for: id)])
    }

    /// Remove the runner's cache volumes except those for `keeping` (errors
    /// ignored; one a container still uses stays). Returns how many went.
    @discardableResult
    static func removeCacheVolumes(for id: UUID, keeping paths: [String] = [], docker: String? = nil) async -> Int {
        guard let docker = docker ?? executablePath(),
              let listed = await run(docker, ["volume", "ls", "-q", "--filter", "name=\(cacheVolumePrefix(for: id))"]),
              listed.succeeded else { return 0 }
        let kept = Set(paths.map { cacheVolumeName(for: id, path: $0) })
        let stale = cacheVolumes(for: id, in: listed.output).filter { !kept.contains($0) }
        var removed = 0
        for volume in stale {
            if await run(docker, ["volume", "rm", volume])?.succeeded == true {
                removed += 1
            }
        }
        return removed
    }

    /// The runner's cache volumes among `docker volume ls -q` output (whose
    /// name filter matches anywhere in a name, not just its start).
    static func cacheVolumes(for id: UUID, in output: String) -> [String] {
        let prefix = cacheVolumePrefix(for: id)
        return output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(prefix) }
    }
}
