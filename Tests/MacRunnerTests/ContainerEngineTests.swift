import XCTest
@testable import MacRunner

/// The per-runner container engine and container CPUs/memory: model, display, and CLI parsing.
final class ContainerEngineTests: XCTestCase {
    private let legacyContainerRunner = """
    {
        "id": "00000000-0000-0000-0000-000000000001",
        "name": "ctr",
        "repo": "owner/repo",
        "labels": ["linux", "mac-runner"],
        "enabled": true,
        "status": "stopped",
        "isolationMode": { "type": "container" }
    }
    """

    // MARK: - Model

    func testEngineAndResourcesRoundTrip() throws {
        let runner = Runner(name: "d", repo: "o/r", isolationMode: .container, containerEngine: .docker,
                            containerCPUs: 4, containerMemoryMB: 8192)
        let data = try JSONEncoder().encode(runner)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["containerEngine"] as? String, "docker")
        XCTAssertEqual(json?["containerCPUs"] as? Int, 4)
        XCTAssertEqual(json?["containerMemoryMB"] as? Int, 8192)

        let decoded = try JSONDecoder().decode(Runner.self, from: data)
        XCTAssertEqual(decoded, runner)
        XCTAssertEqual(decoded.effectiveContainerEngine, .docker)
    }

    func testConfigsWithoutTheKeysUseAppleAndTheDefaults() throws {
        let runner = try JSONDecoder().decode(Runner.self, from: Data(legacyContainerRunner.utf8))
        XCTAssertNil(runner.containerEngine)
        XCTAssertEqual(runner.effectiveContainerEngine, .apple)
        XCTAssertFalse(runner.runsInDocker(global: IsolationMode.none))
        XCTAssertNil(runner.containerCPUs)
        XCTAssertNil(runner.containerMemoryMB)
        XCTAssertEqual(runner.effectiveContainerCPUs, 2)
        XCTAssertEqual(runner.effectiveContainerMemoryMB, 4096)

        // Nothing new is written back for such a runner.
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(runner)) as? [String: Any]
        XCTAssertNil(json?["containerEngine"])
        XCTAssertNil(json?["containerCPUs"])
        XCTAssertNil(json?["containerMemoryMB"])
    }

    func testUnknownEnginesAreRejected() {
        XCTAssertEqual(ContainerEngine.allCases, [.apple, .docker])
        XCTAssertEqual(ContainerEngine(rawValue: "docker"), .docker)
        XCTAssertNil(ContainerEngine(rawValue: "podman"))
    }

    func testDockerNeedsContainerIsolation() {
        let pinned = Runner(name: "p", repo: "o/r", isolationMode: .container, containerEngine: .docker)
        XCTAssertTrue(pinned.runsInDocker(global: IsolationMode.none))
        let inherited = Runner(name: "i", repo: "o/r", containerEngine: .docker)
        XCTAssertTrue(inherited.runsInDocker(global: .container))
        XCTAssertFalse(inherited.runsInDocker(global: IsolationMode.none))
        XCTAssertFalse(Runner(name: "a", repo: "o/r", isolationMode: .container).runsInDocker(global: .container))
    }

    func testEngineAndResourcesAreUserSettingsForConfigReconciling() {
        let base = Runner(name: "r", repo: "o/r", isolationMode: .container)
        var cli = base
        cli.containerEngine = .docker
        cli.containerCPUs = 4
        cli.containerMemoryMB = 8192

        let taken = RunnerManager.mergeRunner(disk: cli, memory: base, base: base, ownsRuntime: false)
        XCTAssertEqual(taken.containerEngine, .docker, "another process's change is taken when we changed nothing")
        XCTAssertEqual(taken.containerCPUs, 4)
        XCTAssertEqual(taken.containerMemoryMB, 8192)

        let kept = RunnerManager.mergeRunner(disk: base, memory: cli, base: base, ownsRuntime: false)
        XCTAssertEqual(kept.containerEngine, .docker, "our unsaved change survives a concurrent save")
        XCTAssertEqual(kept.containerCPUs, 4)
    }

    // MARK: - Display

    func testListShowsDockerAndNonDefaultResources() {
        let docker = Runner(name: "d", repo: "o/r", isolationMode: .container, containerEngine: .docker)
        let sized = Runner(name: "s", repo: "o/r", containerEngine: .docker, containerCPUs: 4, containerMemoryMB: 8192)
        let apple = Runner(name: "a", repo: "o/r", isolationMode: .container, containerEngine: .apple)
        let plain = Runner(name: "p", repo: "o/r", isolationMode: IsolationMode.none, containerCPUs: 4)

        XCTAssertEqual(docker.isolationDisplayName(for: .container), "Container (Docker)")
        XCTAssertEqual(apple.isolationDisplayName(for: .container), "Container")
        XCTAssertEqual(CLIHandler.isolationText(for: docker, global: IsolationMode.none), "📦 Container (Docker)")
        XCTAssertEqual(CLIHandler.isolationText(for: apple, global: IsolationMode.none), "📦 Container")
        XCTAssertEqual(CLIHandler.isolationText(for: sized, global: .container), "📦 Container (Docker) (global) · 4 CPUs, 8 GB")
        XCTAssertEqual(CLIHandler.isolationText(for: plain, global: .container), "🔓 None", "resources only apply to containers")
    }

    func testResourcesAreSummarizedOnlyWhenNotTheDefaults() {
        XCTAssertNil(Runner(name: "r", repo: "o/r").containerResourcesSummary)
        XCTAssertNil(Runner(name: "r", repo: "o/r", containerCPUs: 2, containerMemoryMB: 4096).containerResourcesSummary)
        XCTAssertEqual(Runner(name: "r", repo: "o/r", containerCPUs: 4).containerResourcesSummary, "4 CPUs, 4 GB")
        XCTAssertEqual(Runner(name: "r", repo: "o/r", containerCPUs: 1, containerMemoryMB: 1536).containerResourcesSummary, "1 CPU, 1536 MB")
        XCTAssertEqual(Runner(name: "r", repo: "o/r").containerResourcesDescription, "2 CPUs, 4 GB")
    }

    func testStatusListsDockerAndResizedContainerRunners() {
        let runners = [
            Runner(name: "linux", repo: "o/r", isolationMode: .container, containerEngine: .docker, containerCPUs: 4, containerMemoryMB: 8192),
            Runner(name: "apple-default", repo: "o/r", isolationMode: .container),
            Runner(name: "apple-big", repo: "o/r", isolationMode: .container, containerMemoryMB: 16384),
            Runner(name: "mac", repo: "o/r", isolationMode: IsolationMode.none, containerEngine: .docker),
            Runner(name: "inherits", repo: "o/r", containerEngine: .docker),
        ]
        XCTAssertEqual(CLIHandler.containerStatusLines(runners: runners, global: IsolationMode.none), [
            "apple-big: Container · 2 CPUs, 16 GB",
            "linux: Container (Docker) · 4 CPUs, 8 GB",
        ])
        XCTAssertEqual(CLIHandler.containerStatusLines(runners: runners, global: .container).count, 3)
    }

    // MARK: - Apple engine

    func testAppleVMResourcesDefaultToTwoCPUsAndFourGiB() {
        let defaults = ContainerRunnerConfiguration.resources(for: Runner(name: "r", repo: "o/r", isolationMode: .container))
        XCTAssertEqual(defaults.cpuCount, 2)
        XCTAssertEqual(defaults.memoryInBytes, 4 * 1024 * 1024 * 1024)

        let sized = ContainerRunnerConfiguration.resources(
            for: Runner(name: "r", repo: "o/r", isolationMode: .container, containerCPUs: 4, containerMemoryMB: 8192)
        )
        XCTAssertEqual(sized.cpuCount, 4)
        XCTAssertEqual(sized.memoryInBytes, 8 * 1024 * 1024 * 1024)
    }

    // MARK: - Sizes

    func testMemorySizesParse() {
        let valid: [(String, Int)] = [
            ("8g", 8192), ("8G", 8192), ("8gb", 8192), ("8192m", 8192), ("8192MB", 8192), ("8192", 8192), (" 4g ", 4096),
        ]
        for (text, megabytes) in valid {
            XCTAssertEqual(ResourceLimits.containerMemoryMB(from: text), megabytes, text)
        }
        for text in ["", "g", "8x", "1.5g", "-1g", "+8g", "8 g", "eight", "99999999999999999999", "9999999999999999g"] {
            XCTAssertNil(ResourceLimits.containerMemoryMB(from: text), text)
        }
        XCTAssertEqual(ResourceLimits.containerMemoryText(megabytes: 8192), "8g")
        XCTAssertEqual(ResourceLimits.containerMemoryText(megabytes: 1536), "1536m")
    }

    func testResourceRanges() {
        XCTAssertNil(ResourceLimits.containerCPUsProblem(1, hostCores: 8))
        XCTAssertNil(ResourceLimits.containerCPUsProblem(8, hostCores: 8))
        XCTAssertEqual(ResourceLimits.containerCPUsProblem(9, hostCores: 8), "must be between 1 and 8 (this Mac's cores)")
        XCTAssertNotNil(ResourceLimits.containerCPUsProblem(0, hostCores: 8))
        XCTAssertNil(ResourceLimits.containerMemoryProblem(1024))
        XCTAssertEqual(ResourceLimits.containerMemoryProblem(1023), "must be at least 1g (1024 MB)")
    }
}

/// `mac-runner add` argument parsing.
final class AddCommandTests: XCTestCase {
    private func parse(_ args: [String]) -> Result<AddCommand, CLIParseError> {
        AddCommand.parse(args, hostCores: 8)
    }

    func testParsesDockerEngineAndResources() throws {
        let command = try parse([
            "o/r", "--isolation", "container", "--engine", "Docker", "--image", "ci-linux:latest",
            "--cpus", "4", "--memory", "8g", "--name", "linux", "--labels", "linux,arm64",
        ]).get()
        XCTAssertEqual(command, AddCommand(
            target: "o/r", name: "linux", labels: ["linux", "arm64"], isolationMode: .container,
            image: "ci-linux:latest", engine: .docker, cpus: 4, memoryMB: 8192
        ))
        XCTAssertNil(command.validationError(globalIsolation: IsolationMode.none))
    }

    func testEngineIsOptionalAndAppleByDefault() throws {
        let command = try parse(["o/r", "--isolation", "container"]).get()
        XCTAssertNil(command.engine)
        XCTAssertEqual(try parse(["o/r", "--isolation", "container", "--engine", "apple"]).get().engine, .apple)
        XCTAssertEqual(Runner(name: "r", repo: "o/r", isolationMode: .container, containerEngine: command.engine).effectiveContainerEngine, .apple)
        XCTAssertEqual(try parse(["o/r", "--memory", "8192m"]).get().memoryMB, 8192)
        XCTAssertEqual(try parse(["o/r", "--memory", "6144"]).get().memoryMB, 6144)
    }

    func testContainerOptionsRequireContainerIsolation() throws {
        for option in [["--engine", "docker"], ["--cpus", "2"], ["--memory", "4g"], ["--image", "ubuntu:24.04"]] {
            let unset = try parse(["o/r"] + option).get()
            XCTAssertEqual(
                unset.validationError(globalIsolation: IsolationMode.none),
                .message("\(option[0]) only applies to container isolation (--isolation container)")
            )
            XCTAssertNil(unset.validationError(globalIsolation: .container), "\(option[0]) with a global container mode")

            let none = try parse(["o/r", "--isolation", "none"] + option).get()
            XCTAssertNotNil(none.validationError(globalIsolation: .container), "\(option[0]) with --isolation none")
            XCTAssertNil(try parse(["o/r", "--isolation", "container"] + option).get().validationError(globalIsolation: IsolationMode.none))
        }
    }

    func testRejectsBadValues() {
        let invalid: [([String], String)] = [
            (["--engine", "podman"], "invalid engine 'podman'. Valid options: apple, docker"),
            (["--cpus", "0"], "--cpus must be between 1 and 8 (this Mac's cores)"),
            (["--cpus", "9"], "--cpus must be between 1 and 8 (this Mac's cores)"),
            (["--cpus", "2.5"], "--cpus must be a whole number of CPUs"),
            (["--memory", "512m"], "--memory must be at least 1g (1024 MB)"),
            (["--memory", "lots"], "invalid --memory 'lots'. Use e.g. 8g, 8192m, or 8192 (MB)"),
            (["--isolation", "vm"], "invalid isolation mode 'vm'. Valid options: none, user, container"),
            (["--open-files", "0"], "--open-files must be a positive integer"),
        ]
        for (args, expected) in invalid {
            XCTAssertEqual(parse(["o/r", "--isolation", "container"] + args), .failure(.message(expected)), "\(args)")
        }
    }

    func testKeepsTheExistingParsing() throws {
        XCTAssertEqual(parse([]), .failure(.message("repository or organization required")))
        XCTAssertEqual(
            parse(["just-a-name"]),
            .failure(.message("repository required in owner/repo format (or pass --org to register an organization runner)"))
        )
        XCTAssertEqual(parse(["o/r", "--org"]), .failure(.message("--org expects an organization login only (no slashes)")))
        let org = try parse(["my-org", "--org", "--enable-gui", "--open-files", "4096", "--bogus", "--name"]).get()
        XCTAssertEqual(org, AddCommand(target: "my-org", scope: .org, enableGUI: true, openFileLimit: 4096))
        XCTAssertEqual(try parse(["o/r", "--isolation", "user"]).get().isolationMode, .dedicatedUser(username: "_macrunner"))
        XCTAssertEqual(try parse(["o/r", "--isolation", "none"]).get().isolationMode, IsolationMode.none)
    }
}
