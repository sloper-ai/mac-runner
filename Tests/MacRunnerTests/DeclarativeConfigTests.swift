import XCTest
@testable import MacRunner

final class DeclarativeConfigTests: XCTestCase {
    private let sample = """
    version: 1
    settings:
      isolation: user
      quiet-hours: { start: "22:00", end: "6:00" }
      pause-on-battery: true
      battery-threshold: 30
    runners:
      - name: mac-runner-ci
        repo: omniaura/mac-runner
        labels: [macos, swift]
        count: 2
      - name: org-builder
        org: omniaura
        isolation: container
        enable-gui: true
        open-files: 4096
        quiet-hours: never
    """

    func testParsesAndExpandsTheDocumentedExample() throws {
        let config = try DeclarativeConfig.parse(sample)
        let runners = try config.desiredRunners()

        XCTAssertEqual(runners.map(\.name), ["mac-runner-ci-1", "mac-runner-ci-2", "org-builder"])
        XCTAssertEqual(runners[0].target, RunnerTarget(scope: .repo, identifier: "omniaura/mac-runner"))
        XCTAssertEqual(runners[0].labels, ["macos", "swift"])
        XCTAssertNil(runners[0].isolation)
        XCTAssertEqual(runners[2].target, RunnerTarget(scope: .org, identifier: "omniaura"))
        XCTAssertEqual(runners[2].isolation, .container)
        XCTAssertTrue(runners[2].enableGUI)
        XCTAssertEqual(runners[2].openFileLimit, 4096)
        XCTAssertEqual(runners[2].quietHours?.enabled, false)

        let settings = try config.resolvedSettings(AppSettings())
        XCTAssertEqual(settings.isolationMode, .dedicatedUser(username: "_macrunner"))
        XCTAssertEqual(settings.quietHours, QuietHours(enabled: true, start: "22:00", end: "06:00"))
        XCTAssertTrue(settings.pauseOnBattery)
        XCTAssertEqual(settings.batteryPauseThreshold, 30)
    }

    func testDefaultsWhenFieldsAreOmitted() throws {
        let runners = try DeclarativeConfig.parse("runners:\n  - name: r\n    repo: o/r\n").desiredRunners()
        XCTAssertEqual(runners, [DesiredRunner(
            name: "r", target: RunnerTarget(scope: .repo, identifier: "o/r"), labels: Runner.defaultLabels,
            isolation: nil, enableGUI: false, openFileLimit: nil, quietHours: nil
        )])
        let settings = AppSettings(batteryPauseThreshold: 40)
        XCTAssertEqual(try DeclarativeConfig.parse("runners: []").resolvedSettings(settings), settings)
    }

    func testRejectsInvalidConfigs() {
        let invalid: [(String, String)] = [
            ("runners:\n  - name: r\n", "one of repo or org"),
            ("runners:\n  - name: r\n    repo: o/r\n    org: o\n", "one of repo or org"),
            ("runners:\n  - name: r\n    repo: just-a-name\n", "owner/name"),
            ("runners:\n  - name: 'bad name'\n    repo: o/r\n", "may only contain"),
            ("runners:\n  - name: r\n    repo: o/r\n    isolation: vm\n", "isolation 'vm'"),
            ("runners:\n  - name: r\n    repo: o/r\n    count: 0\n", "count"),
            ("runners:\n  - name: r\n    repo: o/r\n  - name: r\n    repo: o/s\n", "duplicate"),
            ("runners:\n  - name: r\n    repo: o/r\n    quiet-hours: { start: '25:00', end: '01:00' }\n", "HH:mm"),
            ("runners:\n  - name: r\n    repo: o/r\n    quiet-hours: sometimes\n", "never"),
            ("runners:\n  - repo: o/r\n", "missing 'name'"),
            ("version: 2\nrunners: []\n", "version 2 isn't supported"),
            ("runner:\n  - name: r\n    repo: o/r\n", "unknown key 'runner'"),
            ("runners:\n  - name: r\n    repo: o/r\n    labls: [x]\n", "unknown key 'labls' in runner 'r'"),
            ("settings:\n  isolaton: user\nrunners: []\n", "unknown key 'isolaton' in settings"),
            ("runners:\n  - name: r\n    org: team/sub\n", "no slashes"),
            ("runners:\n  - name: r\n    repo: owner/\n", "owner/name"),
        ]
        for (yaml, expected) in invalid {
            do {
                _ = try DeclarativeConfig.parse(yaml).desiredRunners()
                XCTFail("expected failure for:\n\(yaml)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(expected), "\(error.localizedDescription) should mention \(expected)")
            }
        }
        XCTAssertThrowsError(try DeclarativeConfig.parse("runners: []\nsettings:\n  battery-threshold: 99\n").resolvedSettings(AppSettings()))
    }

    func testExportRoundTripsToTheSameRunners() throws {
        var own = Runner(name: "b", repo: "o/r", labels: ["x"], isolationMode: .container, enableGUI: true, openFileLimit: 1024)
        own.quietHours = QuietHours(enabled: true, start: "01:00", end: "02:00")
        let org = Runner(name: "a", repo: "o", scope: .org)
        let settings = AppSettings(quietHours: QuietHours(enabled: false, start: "09:00", end: "17:00"), isolationMode: .none)

        let yaml = try DeclarativeConfig.export(runners: [own, org], settings: settings).yaml()
        let parsed = try DeclarativeConfig.parse(yaml)
        let plan = ConfigPlanner.plan(
            desired: try parsed.desiredRunners(),
            desiredSettings: try parsed.resolvedSettings(settings),
            current: [own, org],
            currentSettings: settings
        )
        XCTAssertEqual(plan, [], "exporting then applying changes nothing:\n\(yaml)")
    }

    func testPlanCoversEveryKindOfChange() {
        let keep = Runner(name: "keep", repo: "o/r")
        var tweak = Runner(name: "tweak", repo: "o/r", status: .running)
        tweak.quietHours = nil
        let relabel = Runner(name: "relabel", repo: "o/r", labels: ["old"])
        let stale = Runner(name: "stale", repo: "o/r")

        func want(_ runner: Runner) -> DesiredRunner {
            DesiredRunner(name: runner.name, target: runner.target, labels: runner.labels, isolation: runner.isolationMode,
                          enableGUI: runner.enableGUI, openFileLimit: runner.openFileLimit, quietHours: runner.quietHours)
        }
        var tweaked = want(tweak)
        tweaked.openFileLimit = 2048
        tweaked.quietHours = QuietHours(enabled: false, start: "00:00", end: "00:00")
        var relabeled = want(relabel)
        relabeled.labels = ["new"]
        let added = DesiredRunner(name: "new", target: RunnerTarget(scope: .org, identifier: "o"), labels: ["macos"],
                                  isolation: nil, enableGUI: false, openFileLimit: nil, quietHours: nil)
        var newSettings = AppSettings()
        newSettings.pauseOnBattery = true

        let plan = ConfigPlanner.plan(
            desired: [want(keep), tweaked, relabeled, added],
            desiredSettings: newSettings,
            current: [keep, tweak, relabel, stale],
            currentSettings: AppSettings()
        )

        XCTAssertEqual(plan.count, 5)
        XCTAssertEqual(plan[0], .settings(changes: ["pause-on-battery → true"]))
        guard case .update(let updated, _, let changes, let restart) = plan[1] else { return XCTFail("\(plan[1])") }
        XCTAssertEqual(updated.name, "tweak")
        XCTAssertEqual(changes, ["open-files default → 2048", "quiet-hours global → never"])
        XCTAssertTrue(restart, "running runner restarts for a new open-files limit")
        guard case .recreate(let recreated, _, let reasons) = plan[2] else { return XCTFail("\(plan[2])") }
        XCTAssertEqual(recreated.name, "relabel")
        XCTAssertEqual(reasons, ["labels [old] → [new]"])
        XCTAssertEqual(plan[3], .add(added))
        XCTAssertEqual(plan[4], .remove(stale))
        XCTAssertEqual(plan.filter(\.isDestructive).count, 2)

        let noPrune = ConfigPlanner.plan(desired: [want(keep)], desiredSettings: AppSettings(), current: [keep, stale],
                                         currentSettings: AppSettings(), prune: false)
        XCTAssertEqual(noPrune, [])
    }

    func testGlobalIsolationChangeReregistersInheritingRunners() {
        let inherits = Runner(name: "inherits", repo: "o/r")
        let pinned = Runner(name: "pinned", repo: "o/r", isolationMode: IsolationMode.none)
        func want(_ runner: Runner, isolation: IsolationMode?) -> DesiredRunner {
            DesiredRunner(name: runner.name, target: runner.target, labels: runner.labels, isolation: isolation,
                          enableGUI: false, openFileLimit: nil, quietHours: nil)
        }
        var userGlobal = AppSettings()
        userGlobal.isolationMode = .dedicatedUser(username: "_macrunner")

        let plan = ConfigPlanner.plan(
            desired: [want(inherits, isolation: nil), want(pinned, isolation: IsolationMode.none)],
            desiredSettings: userGlobal,
            current: [inherits, pinned],
            currentSettings: AppSettings()
        )
        XCTAssertEqual(plan.count, 2)
        guard case .recreate(let recreated, _, let reasons) = plan[1] else { return XCTFail("\(plan)") }
        XCTAssertEqual(recreated.name, "inherits")
        XCTAssertEqual(reasons, ["isolation none → user"])

        // Pinning to the mode it already inherits changes nothing effective: update only.
        let pinOnly = ConfigPlanner.plan(
            desired: [want(inherits, isolation: IsolationMode.none)],
            desiredSettings: AppSettings(), current: [inherits], currentSettings: AppSettings()
        )
        guard case .update(_, _, let changes, let restart) = pinOnly.first else { return XCTFail("\(pinOnly)") }
        XCTAssertEqual(changes, ["isolation global → none"])
        XCTAssertFalse(restart)
    }

    func testScheduleOnlyChangeDoesNotRestart() {
        let runner = Runner(name: "r", repo: "o/r", status: .running)
        let desired = DesiredRunner(name: "r", target: runner.target, labels: runner.labels, isolation: nil, enableGUI: false,
                                    openFileLimit: nil, quietHours: QuietHours(enabled: true, start: "01:00", end: "02:00"))
        let plan = ConfigPlanner.plan(desired: [desired], desiredSettings: AppSettings(), current: [runner], currentSettings: AppSettings())
        guard case .update(_, _, _, let restart) = plan.first else { return XCTFail("\(plan)") }
        XCTAssertFalse(restart)
    }

    // MARK: - Container engine and resources

    func testEngineCPUsAndMemoryKeys() throws {
        let yaml = """
        runners:
          - name: linux
            repo: o/r
            isolation: container
            engine: docker
            cpus: 4
            memory: 8g
          - name: plain
            repo: o/r
            isolation: container
            memory: 6144
          - name: pinned
            repo: o/r
            isolation: container
            engine: Apple
            memory: 2048m
        """
        let runners = try DeclarativeConfig.parse(yaml).desiredRunners(hostCores: 8)
        XCTAssertEqual(runners[0].containerEngine, .docker)
        XCTAssertEqual(runners[0].containerCPUs, 4)
        XCTAssertEqual(runners[0].containerMemoryMB, 8192)
        XCTAssertNil(runners[1].containerEngine, "no key means Apple's engine")
        XCTAssertNil(runners[1].containerCPUs)
        XCTAssertEqual(runners[1].containerMemoryMB, 6144, "a plain number is megabytes")
        XCTAssertEqual(runners[2].containerEngine, .apple)
        XCTAssertEqual(runners[2].containerMemoryMB, 2048)

        let inherited = try DeclarativeConfig.parse("runners:\n  - name: c\n    repo: o/r\n    engine: docker\n    cpus: 2\n")
            .desiredRunners(globalIsolation: .container, hostCores: 8)
        XCTAssertEqual(inherited.first?.containerEngine, .docker, "the global container mode counts")
    }

    func testRejectsInvalidEngineCPUsAndMemory() {
        let container = "runners:\n  - name: r\n    repo: o/r\n    isolation: container\n"
        let invalid: [(String, String)] = [
            ("runners:\n  - name: r\n    repo: o/r\n    engine: docker\n", "r: engine requires container isolation"),
            ("runners:\n  - name: r\n    repo: o/r\n    cpus: 2\n", "r: cpus requires container isolation"),
            ("runners:\n  - name: r\n    repo: o/r\n    memory: 4g\n", "r: memory requires container isolation"),
            ("runners:\n  - name: r\n    repo: o/r\n    isolation: none\n    engine: docker\n", "engine requires container isolation"),
            (container + "    engine: podman\n", "r: engine 'podman' must be apple or docker"),
            (container + "    cpus: 9\n", "r: cpus must be between 1 and 8"),
            (container + "    cpus: 0\n", "r: cpus must be between 1 and 8"),
            (container + "    memory: 512m\n", "r: memory must be at least 1g"),
            (container + "    memory: plenty\n", "r: memory 'plenty' must be a size"),
            (container + "    engin: docker\n", "unknown key 'engin' in runner 'r'"),
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

    func testExportWritesEngineAndResourcesOnlyWhenSet() throws {
        let docker = Runner(name: "d", repo: "o/r", isolationMode: .container, containerEngine: .docker,
                            containerCPUs: 4, containerMemoryMB: 8192)
        let apple = Runner(name: "a", repo: "o/r", isolationMode: .container, containerEngine: .apple, containerMemoryMB: 1536)
        let plain = Runner(name: "p", repo: "o/r", isolationMode: .container)

        let config = DeclarativeConfig.export(runners: [docker, apple, plain], settings: AppSettings())
        XCTAssertEqual(config.runners.map(\.engine), [nil, "docker", nil], "Apple's engine isn't written")
        XCTAssertEqual(config.runners.map(\.cpus), [nil, 4, nil])
        XCTAssertEqual(config.runners.map(\.memory), [DeclarativeConfig.MemorySpec("1536m"), DeclarativeConfig.MemorySpec("8g"), nil])

        let yaml = try config.yaml()
        XCTAssertTrue(yaml.contains("engine: docker"), yaml)
        XCTAssertTrue(yaml.contains("cpus: 4"), yaml)
        XCTAssertTrue(yaml.contains("memory: 8g"), yaml)

        let parsed = try DeclarativeConfig.parse(yaml)
        let plan = ConfigPlanner.plan(
            desired: try parsed.desiredRunners(hostCores: 8),
            desiredSettings: try parsed.resolvedSettings(AppSettings()),
            current: [docker, apple, plain],
            currentSettings: AppSettings()
        )
        XCTAssertEqual(plan, [], "exporting then applying changes nothing:\n\(yaml)")
    }

    func testEngineAndResourceChangesUpdateInPlace() {
        let running = Runner(name: "r", repo: "o/r", status: .running, isolationMode: .container)
        func want(_ runner: Runner) -> DesiredRunner {
            DesiredRunner(name: runner.name, target: runner.target, labels: runner.labels, isolation: runner.isolationMode,
                          enableGUI: runner.enableGUI, openFileLimit: runner.openFileLimit, quietHours: runner.quietHours,
                          containerImage: runner.containerImage, containerEngine: runner.containerEngine,
                          containerCPUs: runner.containerCPUs, containerMemoryMB: runner.containerMemoryMB)
        }
        func update(_ desired: DesiredRunner, from runner: Runner) -> (changes: [String], restart: Bool)? {
            let plan = ConfigPlanner.plan(desired: [desired], desiredSettings: AppSettings(), current: [runner], currentSettings: AppSettings())
            guard plan.count == 1, case .update(_, _, let changes, let restart) = plan[0] else { return nil }
            return (changes, restart)
        }

        var docker = want(running)
        docker.containerEngine = .docker
        XCTAssertEqual(update(docker, from: running)?.changes, ["engine apple → docker"])
        XCTAssertEqual(update(docker, from: running)?.restart, true, "a running runner restarts on its new engine")

        var stopped = running
        stopped.status = .stopped
        XCTAssertEqual(update(docker, from: stopped)?.restart, false)

        var sized = want(running)
        sized.containerCPUs = 4
        sized.containerMemoryMB = 8192
        XCTAssertEqual(update(sized, from: running)?.changes, ["cpus default → 4", "memory default → 8g"])
        XCTAssertEqual(update(sized, from: running)?.restart, true)

        var pinned = want(running)
        pinned.containerCPUs = 2
        pinned.containerMemoryMB = 4096
        XCTAssertEqual(update(pinned, from: running)?.changes, ["cpus default → 2", "memory default → 4g"])
        XCTAssertEqual(update(pinned, from: running)?.restart, false, "pinning the defaults changes nothing that's running")

        var explicitApple = want(running)
        explicitApple.containerEngine = .apple
        XCTAssertEqual(ConfigPlanner.plan(desired: [explicitApple], desiredSettings: AppSettings(), current: [running], currentSettings: AppSettings()), [])
    }
}
