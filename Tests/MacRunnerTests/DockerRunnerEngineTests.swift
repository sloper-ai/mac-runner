import XCTest
@testable import MacRunner

final class DockerRunnerEngineTests: XCTestCase {
    private let runnerID = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
    private let secret = "registration-token-that-must-stay-out-of-files"

    private func makeScratchDirectory() throws -> URL {
        // A space in the path, like a runner directory under a home with one.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("docker engine \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func variables(name: String = "linux 1") -> [(name: String, value: String)] {
        ContainerRunnerScript.variables(
            registrationURL: "https://github.com/o/r",
            registration: .token(secret),
            runnerName: name,
            labels: ["linux", "mac-runner"],
            runnerDownloadURL: RunnerInstaller.linuxDownloadURL(version: "2.337.0"),
            openFileLimit: 4096,
            tools: ["gh", "node"],
            enableGUI: false
        ) + DockerRunnerEngine.engineVariables
    }

    func testNamesAreDerivedFromTheRunnerID() {
        XCTAssertEqual(DockerRunnerEngine.containerName(for: runnerID), "mac-runner-E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
        XCTAssertEqual(DockerRunnerEngine.workVolumeName(for: runnerID), "mac-runner-E621E1F8-C36C-495A-93FC-0C247A3E6E5F-work")
    }

    func testBothEnginesGiveTheScriptTheSameInputs() {
        let shared = ContainerRunnerScript.variables(
            registrationURL: "https://github.com/o/r",
            registration: .token("t"),
            runnerName: "n",
            labels: ["linux"],
            runnerDownloadURL: "https://example.com/runner.tar.gz",
            openFileLimit: 1024,
            tools: [],
            enableGUI: true
        )
        let config = ContainerRunnerConfiguration(
            containerImage: nil,
            workspaceURL: URL(fileURLWithPath: "/tmp/w"),
            repositoryURL: "https://github.com/o/r",
            registrationToken: "t",
            runnerName: "n",
            labels: ["linux"],
            enableGUI: true,
            runnerDownloadURL: "https://example.com/runner.tar.gz",
            openFileLimit: 1024
        )
        XCTAssertEqual(shared.map { "\($0.name)=\($0.value)" }, ContainerRunnerScript.environment(for: config))
        XCTAssertEqual(shared.map(\.name), [
            "RUNNER_ALLOW_RUNASROOT", "MR_URL", "MR_TOKEN", "MR_NAME", "MR_LABELS", "MR_RUNNER_URL", "MR_OPEN_FILES",
            "MR_WORK_DIR", "MR_DIAG_DIR", "MR_APT_PACKAGES", "MR_INSTALL_GH", "MR_ENABLE_GUI", "MR_DISPLAY",
        ])
        XCTAssertEqual(DockerRunnerEngine.engineVariables.map(\.name), ["RUNNER_MANUALLY_TRAP_SIG"])
    }

    func testLauncherNamesVariablesWithoutValues() {
        let launcher = DockerRunnerEngine.launcherScript(
            docker: "/usr/local/bin/docker",
            runnerID: runnerID,
            runnerName: "linux 1",
            runnerDirectory: "/Users/me/.mac-runner/runners/\(runnerID.uuidString)",
            image: "ghcr.io/actions/actions-runner:latest",
            cpus: 2,
            memoryMB: 4096,
            openFileLimit: 4096,
            environmentNames: variables().map(\.name)
        )
        XCTAssertFalse(launcher.contains(secret), "the token is passed through the environment only")
        XCTAssertFalse(launcher.contains("MR_TOKEN="))
        XCTAssertTrue(launcher.contains("-e MR_TOKEN"))
        XCTAssertTrue(launcher.contains("-e RUNNER_MANUALLY_TRAP_SIG"))
        XCTAssertTrue(launcher.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(launcher.contains("/usr/local/bin/docker rm -f mac-runner-\(runnerID.uuidString) >/dev/null 2>&1 || true\n"))
        XCTAssertTrue(launcher.contains("exec /usr/local/bin/docker run --rm --init \\\n  --name mac-runner-\(runnerID.uuidString) \\\n"), launcher)
    }

    func testShellQuoting() {
        XCTAssertEqual(DockerRunnerEngine.shellQuoted("ghcr.io/actions/actions-runner:latest"), "ghcr.io/actions/actions-runner:latest")
        XCTAssertEqual(DockerRunnerEngine.shellQuoted("/Users/me/My Runners/_diag:/mac-runner/_diag"), "'/Users/me/My Runners/_diag:/mac-runner/_diag'")
        XCTAssertEqual(DockerRunnerEngine.shellQuoted("it's"), "'it'\\''s'")
        XCTAssertEqual(DockerRunnerEngine.shellQuoted("$HOME"), "'$HOME'")
        XCTAssertEqual(DockerRunnerEngine.shellQuoted(""), "''")
    }

    /// Runs the written launcher with a stand-in docker that records what it was given.
    func testLauncherRunsDockerWithTheseArgumentsAndEnvironment() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runnerDirectory = root.appendingPathComponent("runner \(runnerID.uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("docker bin", isDirectory: true)
        try FileManager.default.createDirectory(at: runnerDirectory.appendingPathComponent("_diag"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        // Records each call's arguments, one per line, and the environment of `run`.
        let docker = bin.appendingPathComponent("docker")
        try """
        #!/bin/bash
        { echo "-- call"; printf '%s\\n' "$@"; } >> "$STUB_LOG"
        if [ "$1" = run ]; then env > "$STUB_ENV"; fi
        """.write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)

        let variables = variables(name: "it's linux")
        let image = "my registry/ci image's:latest"  // not a valid reference, but it must arrive as one argument
        let launcher = try DockerRunnerEngine.writeLaunchFiles(
            docker: docker.path,
            runnerID: runnerID,
            runnerName: "it's linux",
            runnerDirectory: runnerDirectory.path,
            image: image,
            cpus: 4,
            memoryMB: 8192,
            openFileLimit: 4096,
            environmentNames: variables.map(\.name)
        )

        XCTAssertEqual(launcher, runnerDirectory.appendingPathComponent("docker-run.sh").path)
        let launcherMode = try FileManager.default.attributesOfItem(atPath: launcher)[.posixPermissions] as? Int
        XCTAssertEqual(launcherMode, 0o700)
        let scriptPath = runnerDirectory.appendingPathComponent("container-runner.sh").path
        let scriptMode = try FileManager.default.attributesOfItem(atPath: scriptPath)[.posixPermissions] as? Int
        XCTAssertEqual(scriptMode, 0o644, "readable by the container's user")
        XCTAssertTrue(try String(contentsOfFile: scriptPath, encoding: .utf8).contains(ContainerRunnerScript.script))
        XCTAssertFalse(try String(contentsOfFile: launcher, encoding: .utf8).contains(secret))

        // The environment Mac Runner starts the launcher with, as ProcessManager builds it.
        let log = root.appendingPathComponent("calls").path
        let envFile = root.appendingPathComponent("env").path
        var environment = RunnerEnvironment.environment(from: ["PATH": "/usr/bin:/bin"], enableGUI: false)
        environment.merge(Dictionary(variables.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })) { _, new in new }
        environment["STUB_LOG"] = log
        environment["STUB_ENV"] = envFile

        let result = try runLauncher(launcher, environment: environment)
        XCTAssertEqual(result.status, 0, result.output)

        let calls = try String(contentsOfFile: log, encoding: .utf8)
            .components(separatedBy: "-- call\n")
            .filter { !$0.isEmpty }
            .map { $0.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init) }
        XCTAssertEqual(calls.count, 2, "\(calls)")
        XCTAssertEqual(calls.first, ["rm", "-f", "mac-runner-\(runnerID.uuidString)"], "a leftover container is removed first")
        XCTAssertEqual(calls.last, [
            "run", "--rm", "--init",
            "--name", "mac-runner-\(runnerID.uuidString)",
            "--hostname", "it-s-linux",
            "--label", "ai.omniaura.mac-runner.id=\(runnerID.uuidString)",
            "-v", "mac-runner-\(runnerID.uuidString)-work:/mac-runner/_work",
            "-v", "\(runnerDirectory.path)/_diag:/mac-runner/_diag",
            "-v", "\(runnerDirectory.path)/container-runner.sh:/mac-runner/run-runner.sh:ro",
            "--cpus", "4", "--memory", "8192m",
            "--ulimit", "nofile=4096:4096",
        ] + variables.flatMap { ["-e", $0.name] } + [
            "--entrypoint", "bash", image, "/mac-runner/run-runner.sh",
        ])

        // Values reach docker through its environment (and from there the container).
        let seen = try String(contentsOfFile: envFile, encoding: .utf8)
        XCTAssertTrue(seen.contains("MR_TOKEN=\(secret)\n"), seen)
        XCTAssertTrue(seen.contains("MR_NAME=it's linux\n"))
        XCTAssertTrue(seen.contains("RUNNER_MANUALLY_TRAP_SIG=1\n"))
        XCTAssertTrue(seen.contains("PATH=\(bin.path):/opt/homebrew/bin:"), "docker's own directory comes first: \(seen)")
    }

    func testPathSnapshotHoldsOnlyPATH() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        var environment = RunnerEnvironment.environment(from: ["PATH": "/usr/bin:/bin"], enableGUI: false)
        environment["MR_TOKEN"] = secret
        try RunnerEnvironment.writePathSnapshot(in: root.path, environment: environment)

        let snapshot = try String(contentsOf: root.appendingPathComponent(".path"), encoding: .utf8)
        XCTAssertEqual(snapshot, "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin\n")
    }

    func testFindsTheDockerCLI() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        func find(_ executables: Set<String>, path: String? = "/usr/bin:/bin") -> String? {
            DockerRunnerEngine.executablePath(
                environment: path.map { ["PATH": $0] } ?? [:],
                home: home,
                isExecutable: { executables.contains($0) }
            )
        }
        XCTAssertEqual(find(["/usr/local/bin/docker"]), "/usr/local/bin/docker", "Docker Desktop's link, even without it on PATH")
        XCTAssertEqual(find(["/opt/homebrew/bin/docker", "/usr/local/bin/docker"]), "/opt/homebrew/bin/docker")
        XCTAssertEqual(find(["/Users/someone/bin/docker"], path: "/Users/someone/bin:/usr/bin"), "/Users/someone/bin/docker")
        XCTAssertEqual(find(["/Users/someone/.orbstack/bin/docker"], path: nil), "/Users/someone/.orbstack/bin/docker")
        XCTAssertEqual(find(["/Applications/Docker.app/Contents/Resources/bin/docker"]), "/Applications/Docker.app/Contents/Resources/bin/docker")
        XCTAssertNil(find([]))
    }

    func testCPUsMustFitWhatDockerHas() throws {
        let defaults = Runner(name: "r", repo: "o/r", isolationMode: .container, containerEngine: .docker)
        XCTAssertEqual(try DockerRunnerEngine.cpus(for: defaults, dockerCPUs: 8), 2)
        XCTAssertEqual(try DockerRunnerEngine.cpus(for: defaults, dockerCPUs: 1), 1, "the default fits a one-CPU Docker VM")
        XCTAssertEqual(try DockerRunnerEngine.cpus(for: defaults, dockerCPUs: nil), 2)

        var four = defaults
        four.containerCPUs = 4
        XCTAssertEqual(try DockerRunnerEngine.cpus(for: four, dockerCPUs: 4), 4)
        XCTAssertThrowsError(try DockerRunnerEngine.cpus(for: four, dockerCPUs: 2)) { error in
            XCTAssertTrue(error.localizedDescription.contains("asks for 4 CPUs, but Docker has 2"), error.localizedDescription)
        }
    }

    func testParsesDockerStats() {
        let output = """
        mac-runner-A\t12.50%\t1.5GiB / 7.653GiB\t42
        other\t0.00%\t0B / 0B\t0
        starting\t--\t-- / --\t--
        WARNING: some daemon warning
        """
        let usage = ResourceMonitor.parseDockerStats(output)
        XCTAssertEqual(usage["mac-runner-A"], RunnerResourceUsage(cpuPercent: 12.5, memoryBytes: 1_610_612_736, processCount: 42, diskBytes: nil))
        XCTAssertEqual(usage["other"]?.memoryBytes, 0)
        XCTAssertNil(usage["starting"], "no numbers until the container is up")
        XCTAssertEqual(usage.count, 2)
    }

    func testParsesDockerSizes() {
        XCTAssertEqual(ResourceMonitor.parseDockerByteCount("474.2MB"), 474_200_000)
        XCTAssertEqual(ResourceMonitor.parseDockerByteCount("1.5GiB"), 1_610_612_736)
        XCTAssertEqual(ResourceMonitor.parseDockerByteCount(" 12kB "), 12_000)
        XCTAssertEqual(ResourceMonitor.parseDockerByteCount("0B"), 0)
        for text in ["N/A", "12", "12XB", "", "--"] {
            XCTAssertNil(ResourceMonitor.parseDockerByteCount(text), text)
        }

        let volumes = #"[{"Driver":"local","Links":"1","Name":"mac-runner-A-work","Size":"2.5GB"},{"Name":"other","Size":"N/A"}]"#
        let sizes = ResourceMonitor.parseDockerVolumeSizes("WARNING: something\n\(volumes)\n")
        XCTAssertEqual(sizes, ["mac-runner-A-work": 2_500_000_000])
        XCTAssertEqual(ResourceMonitor.parseDockerVolumeSizes("Cannot connect to the Docker daemon"), [:])
    }

    /// The launcher against real Docker, with a stand-in startup script that
    /// reports what the container sees. Opt in with MAC_RUNNER_DOCKER_TESTS=1;
    /// it uses `ubuntu:24.04` unless MAC_RUNNER_DOCKER_TEST_IMAGE names another
    /// image with bash and GNU tar (and, if its user isn't root, passwordless sudo).
    func testLauncherRunsTheContainerInDocker() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MAC_RUNNER_DOCKER_TESTS"] == "1" else {
            throw XCTSkip("Set MAC_RUNNER_DOCKER_TESTS=1 to run against Docker")
        }
        guard let docker = DockerRunnerEngine.executablePath() else {
            throw XCTSkip("Docker isn't installed")
        }

        let id = UUID()
        let root = try makeScratchDirectory()
        let runnerDirectory = root.appendingPathComponent("runner dir", isDirectory: true)
        try FileManager.default.createDirectory(at: runnerDirectory.appendingPathComponent("_diag"), withIntermediateDirectories: true)
        defer {
            _ = try? ProcessExecutor.run(docker, arguments: ["rm", "-f", DockerRunnerEngine.containerName(for: id)], timeout: 30)
            _ = try? ProcessExecutor.run(docker, arguments: ["volume", "rm", DockerRunnerEngine.workVolumeName(for: id)], timeout: 30)
            try? FileManager.default.removeItem(at: root)
        }

        let launcher = try DockerRunnerEngine.writeLaunchFiles(
            docker: docker,
            runnerID: id,
            runnerName: "it's a test",
            runnerDirectory: runnerDirectory.path,
            image: environment["MAC_RUNNER_DOCKER_TEST_IMAGE"] ?? "ubuntu:24.04",
            cpus: 1,
            memoryMB: 1024,
            openFileLimit: 4096,
            environmentNames: ["MR_TOKEN", "MR_NAME"]
        )
        try """
        set -euo pipefail
        echo "token=$MR_TOKEN name=$MR_NAME host=$(hostname) nofile=$(ulimit -n) init=$(cat /proc/1/comm)"
        # Like the startup script: take over the mounts if this user can't write them.
        if [ "$(id -u)" -ne 0 ]; then SUDO=sudo; else SUDO=""; fi
        for dir in /mac-runner/_work /mac-runner/_diag; do
          [ -w "$dir" ] || $SUDO chown "$(id -u):$(id -g)" "$dir"
        done
        cd /mac-runner/_work
        # GNU tar extracts a symlink whose target has `..` via a mode-0 placeholder file.
        mkdir -p src/lib/node && ln -s ../lib/node src/link && tar -cf archive.tar -C src .
        mkdir extracted && tar -xf archive.tar -C extracted && [ -L extracted/link ] && echo tar-extracts
        echo diagnostics > /mac-runner/_diag/probe
        echo "cpu=$(cat /sys/fs/cgroup/cpu.max) memory=$(cat /sys/fs/cgroup/memory.max)"
        """.write(to: runnerDirectory.appendingPathComponent("container-runner.sh"), atomically: true, encoding: .utf8)

        var launchEnvironment = RunnerEnvironment.environment(enableGUI: false)
        launchEnvironment["MR_TOKEN"] = "s3cret 'quoted' $value"
        launchEnvironment["MR_NAME"] = "it's a test"
        let result = try runLauncher(launcher, environment: launchEnvironment)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(
            result.output.contains("token=s3cret 'quoted' $value name=it's a test host=it-s-a-test nofile=4096 init=docker-init"),
            result.output
        )
        XCTAssertTrue(result.output.contains("tar-extracts"), "the work volume takes what virtio-fs refuses: \(result.output)")
        XCTAssertTrue(result.output.contains("cpu=100000 100000 memory=1073741824"), result.output)
        XCTAssertEqual(
            try String(contentsOf: runnerDirectory.appendingPathComponent("_diag/probe"), encoding: .utf8),
            "diagnostics\n"
        )
        let volume = try ProcessExecutor.run(docker, arguments: ["volume", "inspect", DockerRunnerEngine.workVolumeName(for: id)], timeout: 30)
        XCTAssertEqual(volume?.succeeded, true, "the work directory is a volume that outlives the container")
    }

    /// Two starts of a JIT runner against real Docker, with a stand-in startup
    /// script: each gets an empty work volume, a cache volume keeps what the
    /// first left, and the JIT config arrives through the environment. Opt in
    /// with MAC_RUNNER_DOCKER_TESTS=1 (image as for the test above).
    func testJITStartsGetAFreshWorkVolumeAndKeepTheirCaches() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MAC_RUNNER_DOCKER_TESTS"] == "1" else {
            throw XCTSkip("Set MAC_RUNNER_DOCKER_TESTS=1 to run against Docker")
        }
        guard let docker = DockerRunnerEngine.executablePath() else {
            throw XCTSkip("Docker isn't installed")
        }

        let id = UUID()
        let cachePath = "/var/cache/mac-runner-test"
        let cacheVolume = DockerRunnerEngine.cacheVolumeName(for: id, path: cachePath)
        let root = try makeScratchDirectory()
        let runnerDirectory = root.appendingPathComponent("runner dir", isDirectory: true)
        try FileManager.default.createDirectory(at: runnerDirectory.appendingPathComponent("_diag"), withIntermediateDirectories: true)
        defer {
            _ = try? ProcessExecutor.run(docker, arguments: ["rm", "-f", DockerRunnerEngine.containerName(for: id)], timeout: 30)
            _ = try? ProcessExecutor.run(docker, arguments: ["volume", "rm", DockerRunnerEngine.workVolumeName(for: id), cacheVolume], timeout: 30)
            try? FileManager.default.removeItem(at: root)
        }

        func start() throws -> String {
            // As startRunner does at every start: write the launch files, then run the launcher.
            let launcher = try DockerRunnerEngine.writeLaunchFiles(
                docker: docker,
                runnerID: id,
                runnerName: "jit test",
                runnerDirectory: runnerDirectory.path,
                image: environment["MAC_RUNNER_DOCKER_TEST_IMAGE"] ?? "ubuntu:24.04",
                cpus: 1,
                memoryMB: 1024,
                openFileLimit: 4096,
                environmentNames: [JITRunner.configVariable],
                resetWorkVolume: true,
                cacheMounts: DockerRunnerEngine.cacheMounts(for: id, paths: [cachePath])
            )
            try """
            set -euo pipefail
            if [ "$(id -u)" -ne 0 ]; then SUDO=sudo; else SUDO=""; fi
            for dir in /mac-runner/_work /mac-runner/_diag \(cachePath); do
              [ -w "$dir" ] || $SUDO chown "$(id -u):$(id -g)" "$dir"
            done
            echo "jit=${\(JITRunner.configVariable):-unset}"
            echo "work=[$(ls -A /mac-runner/_work | tr '\\n' ' ')]"
            echo "cache=$(cat \(cachePath)/marker 2>/dev/null || echo none)"
            touch /mac-runner/_work/left-by-the-last-job
            echo kept > \(cachePath)/marker
            """.write(to: runnerDirectory.appendingPathComponent("container-runner.sh"), atomically: true, encoding: .utf8)

            var launchEnvironment = RunnerEnvironment.environment(enableGUI: false)
            launchEnvironment[JITRunner.configVariable] = "jit 'config' $value"
            let result = try runLauncher(launcher, environment: launchEnvironment)
            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertFalse(try String(contentsOfFile: launcher, encoding: .utf8).contains("jit 'config'"))
            return result.output
        }

        let first = try start()
        XCTAssertTrue(first.contains("jit=jit 'config' $value"), first)
        XCTAssertTrue(first.contains("work=[]"), first)
        XCTAssertTrue(first.contains("cache=none"), first)

        let second = try start()
        XCTAssertTrue(second.contains("work=[]"), "the next job's workspace starts empty: \(second)")
        XCTAssertTrue(second.contains("cache=kept"), "the cache volume outlives the container: \(second)")
    }

    private func runLauncher(_ launcher: String, environment: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [launcher]
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
