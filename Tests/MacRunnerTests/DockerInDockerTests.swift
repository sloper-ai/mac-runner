import XCTest
@testable import MacRunner

/// Docker-in-Docker for Docker-engine runners: model, CLI, config, launcher,
/// display, and the startup script's daemon handling with stand-ins.
final class DockerInDockerTests: XCTestCase {
    private let runnerID = UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E")!

    private func scratch(_ name: String) throws -> URL {
        // No spaces: the script's runner candidates are a word list.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dind-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func executable(_ url: URL, _ contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - Model, CLI, config

    func testTheOptionRoundTripsAndOldConfigsHaveItOff() throws {
        let runner = Runner(name: "linux", repo: "o/r", isolationMode: .container, containerEngine: .docker, dockerInDocker: true)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(runner)) as? [String: Any]
        XCTAssertEqual(json?["dockerInDocker"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(Runner.self, from: JSONEncoder().encode(runner)), runner)
        XCTAssertTrue(runner.usesDockerInDocker(global: IsolationMode.none))

        let plain = Runner(name: "p", repo: "o/r", isolationMode: .container, containerEngine: .docker, dockerInDocker: false)
        XCTAssertNil(plain.dockerInDocker, "off is stored as nothing")
        let plainJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any]
        XCTAssertNil(plainJSON?["dockerInDocker"])
        XCTAssertFalse(Runner(name: "a", repo: "o/r", isolationMode: .container, dockerInDocker: true).usesDockerInDocker(global: .container),
                       "Apple's engine doesn't run it")
    }

    func testCLIOption() throws {
        func parse(_ args: [String]) throws -> AddCommand { try AddCommand.parse(args, hostCores: 8).get() }
        let command = try parse(["o/r", "--isolation", "container", "--engine", "docker", "--docker", "--jit"])
        XCTAssertTrue(command.docker)
        XCTAssertNil(command.validationError(globalIsolation: IsolationMode.none))
        XCTAssertFalse(try parse(["o/r", "--isolation", "container", "--engine", "docker"]).docker, "off by default")

        XCTAssertEqual(try parse(["o/r", "--docker"]).validationError(globalIsolation: IsolationMode.none)?.text,
                       "--docker only applies to container isolation (--isolation container)")
        XCTAssertEqual(try parse(["o/r", "--isolation", "user", "--docker"]).validationError(globalIsolation: .container)?.text,
                       "--docker only applies to container isolation (--isolation container)")
        XCTAssertEqual(try parse(["o/r", "--isolation", "container", "--docker"]).validationError(globalIsolation: IsolationMode.none)?.text,
                       "--docker needs the Docker engine (--engine docker)")
        XCTAssertEqual(try parse(["o/r", "--isolation", "container", "--engine", "apple", "--docker"]).validationError(globalIsolation: IsolationMode.none)?.text,
                       "--docker needs the Docker engine (--engine docker)")
        XCTAssertNil(try parse(["o/r", "--engine", "docker", "--docker"]).validationError(globalIsolation: .container))
    }

    func testConfigKey() throws {
        let runners = try DeclarativeConfig.parse("""
        runners:
          - name: dind
            repo: o/r
            isolation: container
            engine: docker
            docker: true
          - name: plain
            repo: o/r
            isolation: container
            engine: docker
            docker: false
        """).desiredRunners(hostCores: 8)
        XCTAssertEqual(runners.map(\.dockerInDocker), [true, false])

        let invalid: [(String, String)] = [
            ("runners:\n  - name: r\n    repo: o/r\n    docker: true\n", "r: docker requires container isolation"),
            ("runners:\n  - name: r\n    repo: o/r\n    isolation: container\n    docker: true\n", "r: docker requires the Docker engine (engine: docker)"),
            ("runners:\n  - name: r\n    repo: o/r\n    isolation: container\n    engine: apple\n    docker: true\n", "requires the Docker engine"),
        ]
        for (yaml, expected) in invalid {
            XCTAssertThrowsError(try DeclarativeConfig.parse(yaml).desiredRunners(hostCores: 8), yaml) { error in
                XCTAssertTrue(error.localizedDescription.contains(expected), "\(error.localizedDescription) should mention \(expected)")
            }
        }
        XCTAssertNoThrow(try DeclarativeConfig.parse("runners:\n  - name: r\n    repo: o/r\n    docker: false\n").desiredRunners(hostCores: 8),
                         "off needs nothing")
    }

    func testExportAndPlan() throws {
        let dind = Runner(name: "dind", repo: "o/r", status: .running, isolationMode: .container, containerEngine: .docker, dockerInDocker: true)
        let config = DeclarativeConfig.export(runners: [dind], settings: AppSettings())
        XCTAssertEqual(config.runners.first?.docker, true)
        let text = try config.yaml()
        XCTAssertTrue(text.contains("docker: true"), text)
        let parsed = try DeclarativeConfig.parse(text)
        XCTAssertEqual(ConfigPlanner.plan(desired: try parsed.desiredRunners(hostCores: 8), desiredSettings: AppSettings(),
                                          current: [dind], currentSettings: AppSettings()), [])

        var off = try parsed.desiredRunners(hostCores: 8)[0]
        off.dockerInDocker = false
        let plan = ConfigPlanner.plan(desired: [off], desiredSettings: AppSettings(), current: [dind], currentSettings: AppSettings())
        guard plan.count == 1, case .update(_, _, let changes, let restart) = plan[0] else { return XCTFail("\(plan)") }
        XCTAssertEqual(changes, ["docker off"])
        XCTAssertTrue(restart, "a running runner restarts")
    }

    func testListAndStatusSayDockerInDocker() {
        let dind = Runner(name: "linux-mbp-1", repo: "o/r", isolationMode: .container, containerEngine: .docker,
                          containerCPUs: 4, containerMemoryMB: 8192, jit: true, dockerInDocker: true)
        XCTAssertEqual(CLIHandler.isolationText(for: dind, global: IsolationMode.none),
                       "📦 Container (Docker) · 4 CPUs, 8 GB · JIT · Docker-in-Docker")
        XCTAssertEqual(CLIHandler.containerStatusLines(runners: [dind], global: IsolationMode.none),
                       ["linux-mbp-1: Container (Docker) · 4 CPUs, 8 GB · Docker-in-Docker"])
        let plain = Runner(name: "p", repo: "o/r", isolationMode: .container, containerEngine: .docker)
        XCTAssertEqual(CLIHandler.isolationText(for: plain, global: IsolationMode.none), "📦 Container (Docker)")
    }

    // MARK: - Launcher

    func testLauncherRunsPrivilegedWithTheDockerVolume() throws {
        let root = try scratch("launcher")
        defer { try? FileManager.default.removeItem(at: root) }
        let runnerDirectory = root.appendingPathComponent("runner", isDirectory: true)
        try FileManager.default.createDirectory(at: runnerDirectory.appendingPathComponent("_diag"), withIntermediateDirectories: true)
        let docker = root.appendingPathComponent("docker")
        try executable(docker, """
        #!/bin/bash
        { echo "-- call"; printf '%s\\n' "$@"; } >> "$STUB_LOG"
        """)

        func runArguments(dockerInDocker: Bool) throws -> [String] {
            let variables = ContainerRunnerScript.variables(
                registrationURL: "https://github.com/o/r", registration: .jitConfig("config"), runnerName: "linux",
                labels: ["self-hosted"], runnerDownloadURL: "https://example.com/r.tar.gz", openFileLimit: 4096,
                tools: [], enableGUI: false, dockerInDocker: dockerInDocker
            )
            XCTAssertEqual(variables.contains { $0 == ("MR_DOCKER", "1") }, dockerInDocker)
            let launcher = try DockerRunnerEngine.writeLaunchFiles(
                docker: docker.path, runnerID: runnerID, runnerName: "linux", runnerDirectory: runnerDirectory.path,
                image: "ci:latest", cpus: 4, memoryMB: 8192, openFileLimit: 4096,
                environmentNames: variables.map(\.name), resetWorkVolume: true, dockerInDocker: dockerInDocker
            )
            let log = root.appendingPathComponent("calls-\(dockerInDocker)").path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [launcher]
            process.environment = ["PATH": "/usr/bin:/bin", "STUB_LOG": log]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let calls = try String(contentsOfFile: log, encoding: .utf8)
                .components(separatedBy: "-- call\n").filter { !$0.isEmpty }
                .map { $0.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init) }
            return try XCTUnwrap(calls.last { $0.first == "run" })
        }

        let dind = try runArguments(dockerInDocker: true)
        XCTAssertEqual(Array(dind.prefix(4)), ["run", "--rm", "--init", "--privileged"])
        let volume = "mac-runner-\(runnerID.uuidString)-docker:/var/lib/docker"
        XCTAssertTrue(zip(dind, dind.dropFirst()).contains { $0 == ("-v", volume) }, "\(dind)")
        XCTAssertTrue(zip(dind, dind.dropFirst()).contains { $0 == ("-e", "MR_DOCKER") })
        XCTAssertTrue(zip(dind, dind.dropFirst()).contains { $0 == ("-v", "mac-runner-\(runnerID.uuidString)-work:/mac-runner/_work") },
                      "the work volume is still there (and reset)")

        let plain = try runArguments(dockerInDocker: false)
        XCTAssertFalse(plain.contains("--privileged"))
        XCTAssertFalse(plain.contains { $0.contains("/var/lib/docker") })
        XCTAssertFalse(plain.contains("MR_DOCKER"))
        XCTAssertEqual(DockerRunnerEngine.dockerVolumeName(for: runnerID), "mac-runner-\(runnerID.uuidString)-docker")
    }

    // MARK: - Startup script

    private struct ScriptRun {
        let status: Int32
        let output: String
        let calls: [String]
        let ranRunner: Bool
        let socketMode: Int?
    }

    /// Runs the startup script with Docker-in-Docker on, stand-in `dockerd`
    /// and `docker`, and a stand-in runner, as the current user (no sudo).
    private func runScript(dockerd: String?, jit: Bool = true, wait: Int = 30, socketMode: Int = 0o444) throws -> ScriptRun {
        let root = try scratch("script")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let runnerHome = root.appendingPathComponent("runner", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        for directory in [bin, runnerHome, home] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let calls = root.appendingPathComponent("calls").path
        let ran = root.appendingPathComponent("ran").path
        let up = root.appendingPathComponent("up").path
        let socket = root.appendingPathComponent("docker.sock")
        try "".write(to: socket, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: socketMode], ofItemAtPath: socket.path)

        if let dockerd {
            try executable(bin.appendingPathComponent("dockerd"), dockerd)
        }
        try executable(bin.appendingPathComponent("docker"), """
        #!/bin/bash
        echo "docker $*" >> "$STUB_CALLS"
        case "$1" in
          info) [ -e "$STUB_UP" ] || exit 1 ;;
          ps) printf 'c0ffee\\nbeef42\\n' ;;
          version) echo 27.3.1 ;;
        esac
        exit 0
        """)
        // config.sh (long-lived runners) and run.sh both check Docker was up first.
        try executable(runnerHome.appendingPathComponent("config.sh"), """
        #!/bin/bash
        [ -e "$STUB_UP" ] && echo "config.sh after docker" >> "$STUB_CALLS"
        """)
        try executable(runnerHome.appendingPathComponent("run.sh"), """
        #!/bin/bash
        [ -e "$STUB_UP" ] && echo "run.sh after docker" >> "$STUB_CALLS"
        touch "$STUB_RAN"
        """)

        var environment = Dictionary(ContainerRunnerScript.variables(
            registrationURL: "https://github.com/o/r",
            registration: jit ? .jitConfig("config") : .token("token"),
            runnerName: "linux", labels: ["self-hosted"], runnerDownloadURL: "https://example.com/r.tar.gz",
            openFileLimit: 4096, tools: [], enableGUI: false, dockerInDocker: true
        ).map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
        environment["MR_RUNNER_CANDIDATES"] = runnerHome.path
        environment["MR_WORK_DIR"] = root.appendingPathComponent("work").path
        environment["MR_DIAG_DIR"] = root.appendingPathComponent("diag").path
        environment["MR_SUDO"] = ""
        environment["MR_DOCKER_SOCKET"] = socket.path
        environment["MR_DOCKER_LOG"] = root.appendingPathComponent("dockerd.log").path
        environment["MR_DOCKER_WAIT"] = String(wait)
        environment["HOME"] = home.path
        environment["PATH"] = "\(bin.path):/usr/bin:/bin"
        environment["STUB_CALLS"] = calls
        environment["STUB_UP"] = up
        environment["STUB_RAN"] = ran

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", ContainerRunnerScript.script]
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return ScriptRun(
            status: process.terminationStatus,
            output: output,
            calls: ((try? String(contentsOfFile: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init),
            ranRunner: FileManager.default.fileExists(atPath: ran),
            socketMode: (try? FileManager.default.attributesOfItem(atPath: socket.path))?[.posixPermissions] as? Int
        )
    }

    /// A stand-in dockerd: answers once it's "up", and stays up a little.
    private let workingDockerd = """
    #!/bin/bash
    echo "dockerd $*" >> "$STUB_CALLS"
    echo 'level=info msg="API listen on /var/run/docker.sock"'
    touch "$STUB_UP"
    sleep 3
    """

    func testStartsDockerBeforeTheRunnerAndClearsThePreviousJobsContainers() throws {
        let result = try runScript(dockerd: workingDockerd)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.ranRunner, result.output)
        XCTAssertTrue(result.calls.contains("dockerd "), "\(result.calls)")
        XCTAssertTrue(result.calls.contains("docker rm -f -v c0ffee beef42"), "running ones too, with their anonymous volumes: \(result.calls)")
        XCTAssertTrue(result.calls.contains("docker container prune -f"), "\(result.calls)")
        XCTAssertFalse(result.calls.contains { $0.contains("image") || $0.contains("system prune") }, "images stay cached")
        XCTAssertEqual(result.calls.last, "run.sh after docker")
        XCTAssertEqual(result.socketMode, 0o666, "usable by the runner's user")
        XCTAssertTrue(result.output.contains("Docker 27.3.1 is up for this runner's jobs"), result.output)
    }

    func testALongLivedRunnerRegistersOnceDockerIsUp() throws {
        let result = try runScript(dockerd: workingDockerd, jit: false)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.calls.contains("config.sh after docker"), "\(result.calls)")
        XCTAssertEqual(result.calls.last, "run.sh after docker")
    }

    func testAnUsableSocketIsLeftAlone() throws {
        let result = try runScript(dockerd: workingDockerd, socketMode: 0o660)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.socketMode, 0o660, "its owner and group can use it already")
    }

    func testWithoutDockerdTheRunnerDoesntStart() throws {
        let result = try runScript(dockerd: nil)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Docker-in-Docker needs dockerd and the docker CLI in the image"), result.output)
        XCTAssertTrue(result.output.contains("Not starting the runner so jobs don't run without Docker"), result.output)
        XCTAssertFalse(result.ranRunner)
    }

    func testADaemonThatExitsStopsTheStart() throws {
        let result = try runScript(dockerd: """
        #!/bin/bash
        echo 'failed to start daemon: Error initializing network controller: iptables failed: permission denied' >&2
        exit 1
        """)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("[dockerd] failed to start daemon"), "its log is shown: \(result.output)")
        XCTAssertTrue(result.output.contains("the Docker daemon exited"), result.output)
        XCTAssertFalse(result.ranRunner)
    }

    func testADaemonThatNeverAnswersStopsTheStart() throws {
        let start = Date()
        let result = try runScript(dockerd: "#!/bin/bash\nsleep 6\n", wait: 2)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("the Docker daemon didn't answer within 2s"), result.output)
        XCTAssertFalse(result.ranRunner)
        XCTAssertLessThan(Date().timeIntervalSince(start), 6, "gives up after its wait")
    }

    // MARK: - Real Docker

    /// Docker-in-Docker against real Docker, through the real startup script with
    /// a stand-in runner: two starts of a JIT runner. Its jobs' containers run,
    /// images stay cached in the Docker volume, the previous job's containers
    /// are gone, and the work volume is empty each time. Opt in with
    /// MAC_RUNNER_DOCKER_TESTS=1 and MAC_RUNNER_DIND_TEST_IMAGE, an image with
    /// dockerd, the docker CLI, and busybox, whose user is root or has
    /// passwordless sudo, for example:
    ///
    ///     FROM ubuntu:24.04
    ///     RUN apt-get update && apt-get install -y --no-install-recommends docker.io busybox-static sudo \
    ///         && rm -rf /var/lib/apt/lists/*
    ///     RUN useradd -m -s /bin/bash runner && echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner
    ///     USER runner
    ///     WORKDIR /home/runner
    func testDockerInDockerInRealDocker() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MAC_RUNNER_DOCKER_TESTS"] == "1" else {
            throw XCTSkip("Set MAC_RUNNER_DOCKER_TESTS=1 to run against Docker")
        }
        guard let image = environment["MAC_RUNNER_DIND_TEST_IMAGE"] else {
            throw XCTSkip("Set MAC_RUNNER_DIND_TEST_IMAGE to an image with dockerd, the docker CLI, and busybox")
        }
        guard let docker = DockerRunnerEngine.executablePath() else {
            throw XCTSkip("Docker isn't installed")
        }

        let id = UUID()
        let root = try scratch("real")
        let runnerDirectory = root.appendingPathComponent("runner", isDirectory: true)
        try FileManager.default.createDirectory(at: runnerDirectory.appendingPathComponent("_diag"), withIntermediateDirectories: true)
        defer {
            _ = try? ProcessExecutor.run(docker, arguments: ["rm", "-f", DockerRunnerEngine.containerName(for: id)], timeout: 60)
            _ = try? ProcessExecutor.run(docker, arguments: [
                "volume", "rm", DockerRunnerEngine.workVolumeName(for: id), DockerRunnerEngine.dockerVolumeName(for: id),
            ], timeout: 60)
            try? FileManager.default.removeItem(at: root)
        }

        // The real script, after a prologue that puts a stand-in runner in place.
        let job = """
        set -e
        echo "containers=$(docker ps -aq | wc -l | tr -d ' ') work=[$(ls -A /mac-runner/_work | tr '\\n' ' ')]"
        if docker image inspect mr-dind-probe >/dev/null 2>&1; then
          echo "image=cached"
        else
          mkdir -p /tmp/rootfs/bin && cp "$(command -v busybox)" /tmp/rootfs/bin/busybox
          tar -C /tmp/rootfs -c . | docker import - mr-dind-probe >/dev/null
          echo "image=imported"
        fi
        docker run --rm --network none mr-dind-probe /bin/busybox echo "hello from a job container"
        docker create mr-dind-probe /bin/busybox true >/dev/null
        touch /mac-runner/_work/left-by-the-last-job
        """
        let script = """
        mkdir -p /tmp/stub-runner
        cat > /tmp/stub-runner/run.sh <<'STUB'
        #!/bin/bash
        \(job)
        STUB
        chmod +x /tmp/stub-runner/run.sh
        export MR_RUNNER_CANDIDATES=/tmp/stub-runner
        \(ContainerRunnerScript.script)
        """

        let variables = ContainerRunnerScript.variables(
            registrationURL: "https://github.com/o/r", registration: .jitConfig("not-a-real-config"), runnerName: "dind test",
            labels: ["self-hosted"], runnerDownloadURL: "https://example.com/r.tar.gz", openFileLimit: 65536,
            tools: [], enableGUI: false, dockerInDocker: true
        ) + DockerRunnerEngine.engineVariables

        func start() throws -> String {
            let launcher = try DockerRunnerEngine.writeLaunchFiles(
                docker: docker, runnerID: id, runnerName: "dind test", runnerDirectory: runnerDirectory.path,
                image: image, cpus: 2, memoryMB: 2048, openFileLimit: 65536,
                environmentNames: variables.map(\.name), resetWorkVolume: true, dockerInDocker: true
            )
            try ("#!/bin/bash\n" + script + "\n").write(
                to: runnerDirectory.appendingPathComponent(DockerRunnerEngine.scriptFileName), atomically: true, encoding: .utf8
            )
            var launchEnvironment = RunnerEnvironment.environment(enableGUI: false)
            launchEnvironment.merge(Dictionary(variables.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })) { _, new in new }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [launcher]
            process.environment = launchEnvironment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, output)
            return output
        }

        let first = try start()
        XCTAssertTrue(first.contains("is up for this runner's jobs"), first)
        XCTAssertTrue(first.contains("containers=0 work=[]"), first)
        XCTAssertTrue(first.contains("image=imported"), first)
        XCTAssertTrue(first.contains("hello from a job container"), first)

        let second = try start()
        XCTAssertTrue(second.contains("containers=0 work=[]"), "the last job's container and workspace are gone: \(second)")
        XCTAssertTrue(second.contains("image=cached"), "images outlive the container: \(second)")
        XCTAssertTrue(second.contains("hello from a job container"), second)
    }
}
