import AppKit
import Foundation

enum CLIHandler {
    /// Process exit status for the command that ran; commands set it on failure.
    @MainActor static var exitCode: Int32 = 0

    static var version: String {
        version(executablePath: CommandLine.arguments.first)
    }

    static func version(executablePath: String?, mainBundle: Bundle = .main) -> String {
        if let bundledVersion = bundleVersion(from: mainBundle) {
            return bundledVersion
        }

        guard let executablePath else {
            return "dev"
        }

        let resolvedPath: String
        if !executablePath.contains("/"),
           let pathResolved = resolveFromPATH(executablePath) {
            resolvedPath = pathResolved
        } else {
            resolvedPath = executablePath
        }

        let executableURL = URL(fileURLWithPath: resolvedPath).resolvingSymlinksInPath()

        if let appBundleURL = enclosingAppBundleURL(for: executableURL),
           let appBundle = Bundle(url: appBundleURL),
           let bundledVersion = bundleVersion(from: appBundle) {
            return bundledVersion
        }

        return "dev"
    }

    private static func resolveFromPATH(_ name: String) -> String? {
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func bundleVersion(from bundle: Bundle) -> String? {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static func enclosingAppBundleURL(for executableURL: URL) -> URL? {
        var currentURL = executableURL.deletingLastPathComponent()

        while currentURL.path != "/" {
            if currentURL.pathExtension == "app" {
                return currentURL
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL == currentURL {
                break
            }

            currentURL = parentURL
        }

        return nil
    }

    @MainActor
    static func handle(arguments: [String]) async -> Bool {
        // arguments[0] is the binary path; real args start at [1]
        let args = Array(arguments.dropFirst())

        guard let command = args.first else {
            return false // no CLI args → launch GUI
        }

        switch command {
        case "help", "--help", "-h":
            printUsage()
        case "version", "--version", "-v":
            print("mac-runner \(version)")
        case "auth":
            await handleAuth()
        case "list":
            await handleList()
        case "add":
            await handleAdd(args: Array(args.dropFirst()))
        case "remove":
            await handleRemove(args: Array(args.dropFirst()))
        case "start":
            await handleStart(args: Array(args.dropFirst()))
        case "stop":
            await handleStop(args: Array(args.dropFirst()))
        case "status":
            await handleStatus(args: Array(args.dropFirst()))
        case "setup":
            await handleSetup(args: Array(args.dropFirst()))
        case "uninstall":
            await handleUninstall(args: Array(args.dropFirst()))
        case "cleanup":
            await handleCleanup(args: Array(args.dropFirst()))
        case "apply":
            await handleApply(args: Array(args.dropFirst()))
        case "export":
            await handleExport(args: Array(args.dropFirst()))
        case "logs":
            await handleLogs(args: Array(args.dropFirst()))
        case "schedule":
            await handleSchedule(args: Array(args.dropFirst()))
        case "battery":
            await handleBattery(args: Array(args.dropFirst()))
        default:
            print("Unknown command: \(command)")
            printUsage()
        }

        return true // handled as CLI
    }

    // MARK: - Commands

    private static func printUsage() {
        print("""
        mac-runner - GitHub Actions self-hosted runner manager

        USAGE:
          mac-runner                     Launch GUI (menu bar app)
          mac-runner <command> [options]  Run CLI command

        COMMANDS:
          auth              Show GitHub authentication status
          list              List configured runners
          add <target>      Add a new runner (repo by default; pass --org for org-level)
          remove <name>     Remove a runner
          start <name>      Start a runner
          stop <name>       Stop a runner
          status            Show runner status summary (--resources for CPU/memory/disk)
          setup             Set up dedicated user isolation
          cleanup           Remove idle runner workspaces and CI caches
          apply             Create/update/remove runners to match a config file
          export            Write the current runners as a config file
          logs <name>       Show a runner's logs (--follow to stream, --diag for diagnostics)
          schedule          Show or set quiet hours (daily pause window)
          battery           Show or set pausing on low battery
          uninstall         Remove all runners and every file Mac Runner created
          help              Show this help message
          version           Show version

        ADD OPTIONS:
          --org                Register an organization-level runner (target is the org login)
          --repo               Register a repository-level runner (default)
          --name <name>        Runner name (default: auto-generated)
          --labels <l1,l2>     Comma-separated labels (default: macos)
          --isolation <mode>   Isolation mode: none|user|container (default: global)
          --enable-gui         Enable GUI access (default: headless)
          --image <ref>        Container image for --isolation container (default: ghcr.io/actions/actions-runner:latest)
          --engine <engine>    Container engine for --isolation container: apple|docker (default: apple)
          --cpus <n>           CPUs for --isolation container (default: 2)
          --memory <size>      Memory for --isolation container: 8g, 8192m, or MB (default: 4g)
          --jit                Single-use runners: register a new one, with a fresh workspace, for each job
          --no-tools           Container isolation: install no tools when the container starts
          --cache <path>       Docker engine: keep this container path in a volume across jobs (repeatable)
          --docker             Docker engine: give jobs Docker of their own (Docker-in-Docker; privileged container)

        SETUP OPTIONS:
          --teardown        Remove isolation (delete user, sudoers, reset config)

        APPLY OPTIONS:
          -f, --file <path>           Config file (default ./.mac-runner.yml, then ~/.mac-runner/config.yml)
          --dry-run                   Show the plan without changing anything
          --yes, -y                   Don't ask before removing or re-registering runners
          --no-prune                  Keep runners that aren't in the file

        EXPORT OPTIONS:
          -o, --output <path>         Write to a file instead of stdout

        LOGS OPTIONS:
          -n, --lines <N>             Show the last N lines (default 50)
          -f, --follow                Keep printing new lines (Ctrl-C to stop)
          --diag                      Show the runner's diagnostics log (_diag/Runner_*)
          --job                       Show the newest job's diagnostics log (_diag/Worker_*)

        SCHEDULE OPTIONS:
          --start HH:mm --end HH:mm   Pause runners daily in this window (may cross midnight)
          --off                       Turn global quiet hours off
          --runner <name>             Apply to one runner; also accepts --never or --global

        BATTERY OPTIONS:
          on|off                      Pause runners when on battery below the threshold
          --threshold <percent>       Battery threshold (5-95, default 20)

        CLEANUP OPTIONS:
          --dry-run         Show what would be removed
          --workspaces-only Keep shared language, Homebrew, and Xcode caches

        UNINSTALL OPTIONS:
          --dry-run         Show what would be removed without deleting anything
          --yes, -y         Skip the confirmation prompt
          --include-app     Also delete MacRunner.app and the mac-runner symlink
          --keep-runners    Leave runners registered on GitHub (delete local files only)

        EXAMPLES:
          mac-runner auth
          mac-runner add owner/repo --name my-runner --labels macos,arm64
          mac-runner add my-org --org --labels macos,arm64
          mac-runner add owner/repo --isolation container
          mac-runner add owner/repo --isolation container --image ghcr.io/myorg/runner:latest
          mac-runner add owner/repo --isolation container --engine docker --image my-ci-image:latest --cpus 4 --memory 8g
          mac-runner add owner/repo --isolation container --engine docker --image my-ci-image:latest --jit --no-tools \\
            --labels self-hosted,linux,arm64 --cache /home/runner/.cargo/registry
          mac-runner add owner/repo --isolation container --engine docker --image my-ci-image:latest --docker
          mac-runner add owner/repo --isolation user --jit --labels self-hosted,macos,arm64
          mac-runner add owner/repo --isolation user
          mac-runner add owner/repo --enable-gui
          mac-runner list
          mac-runner start my-runner
          mac-runner stop my-runner
          mac-runner remove my-runner
          sudo mac-runner setup
          sudo mac-runner setup --teardown
          mac-runner cleanup --dry-run
          mac-runner export -o .mac-runner.yml
          mac-runner apply --dry-run
          mac-runner logs my-runner --follow
          mac-runner status --resources
          mac-runner schedule --start 22:00 --end 06:00
          mac-runner battery on --threshold 25
        """)
    }

    @MainActor
    private static func handleAuth() async {
        let status = await GHCLIService.shared.authStatus()
        print(status)
    }

    @MainActor
    private static func handleList() async {
        let manager = RunnerManager()
        let runners = manager.runners

        if runners.isEmpty {
            print("No runners configured.")
            return
        }

        let globalMode = manager.currentSettings.isolationMode

        // Pre-compute isolation text for column sizing
        let isolationTexts = runners.map { runner -> String in
            isolationText(for: runner, global: globalMode)
        }

        // Display the scope alongside the identifier so org-level runners are
        // visually distinguishable from repo-level runners with similar names.
        let targets = runners.map { runner -> String in
            runner.scope == .org ? "\(runner.repo) (org)" : runner.repo
        }

        // Table header
        let nameW = max(runners.map(\.name.count).max() ?? 4, 4)
        let repoW = max(targets.map(\.count).max() ?? 4, 6)
        let isoW = max(isolationTexts.map(\.count).max() ?? 9, 9)

        let header = "  \("NAME".padding(toLength: nameW, withPad: " ", startingAt: 0))  \("TARGET".padding(toLength: repoW, withPad: " ", startingAt: 0))  STATUS      \("ISOLATION".padding(toLength: isoW, withPad: " ", startingAt: 0))  GUI       LABELS"
        print(header)

        for ((runner, isolationText), target) in zip(zip(runners, isolationTexts), targets) {
            let status = "\(runner.status.icon) \(runner.status.rawValue)"
            let labels = runner.labels.joined(separator: ",")
            let guiStatus = runner.enableGUI ? "enabled " : "headless"
            let line = "  \(runner.name.padding(toLength: nameW, withPad: " ", startingAt: 0))  \(target.padding(toLength: repoW, withPad: " ", startingAt: 0))  \(status.padding(toLength: 10, withPad: " ", startingAt: 0))  \(isolationText.padding(toLength: isoW, withPad: " ", startingAt: 0))  \(guiStatus)  \(labels)"
            print(line)
        }
    }

    /// A runner's isolation for `list`, e.g. "📦 Container (Docker) · 4 CPUs, 8 GB · JIT · Docker-in-Docker":
    /// container runners show their engine when it's Docker, and their CPUs and
    /// memory when those aren't the defaults; single-use runners say JIT, and
    /// runners whose jobs get their own Docker say Docker-in-Docker.
    static func isolationText(for runner: Runner, global globalMode: IsolationMode) -> String {
        let effective = runner.effectiveIsolationMode(global: globalMode)
        var text = "\(effective.icon) \(runner.isolationDisplayName(for: effective))"
        if runner.isolationMode == nil {
            text += " (global)"
        }
        if effective == .container, let resources = runner.containerResourcesSummary {
            text += " · \(resources)"
        }
        if runner.isJIT {
            text += " · JIT"
        }
        if runner.usesDockerInDocker(global: globalMode) {
            text += " · Docker-in-Docker"
        }
        return text
    }

    @MainActor
    private static func handleAdd(args: [String]) async {
        guard !args.isEmpty else {
            print("Error: repository or organization required")
            print("Usage: mac-runner add <owner/repo> [--name <name>] [--labels <l1,l2>] [--isolation <mode>] [--enable-gui] [--open-files <limit>] [--jit]")
            print("       mac-runner add <org> --org [--name <name>] [--labels <l1,l2>] [--isolation <mode>] [--enable-gui] [--open-files <limit>] [--jit]")
            return
        }

        let command: AddCommand
        switch AddCommand.parse(args) {
        case .success(let parsed): command = parsed
        case .failure(let error):
            print("Error: \(error.text)")
            return
        }
        let target = command.target
        let scope = command.scope
        let isolationMode = command.isolationMode
        let enableGUI = command.enableGUI
        let openFileLimit = command.openFileLimit
        let name = command.name ?? "mac-runner-\(ProcessInfo.processInfo.hostName.prefix(8))-\(Int.random(in: 1000...9999))"

        // Check auth first
        let authState = await GHCLIService.shared.validateAuth()
        guard authState.isAuthenticated else {
            print("Error: \(authState.recoveryMessage)")
            return
        }

        let manager = RunnerManager()
        let effectiveIsolation = isolationMode ?? manager.currentSettings.isolationMode
        if let error = command.validationError(globalIsolation: manager.currentSettings.isolationMode) {
            print("Error: \(error.text)")
            return
        }

        let scopeLabel = scope == .org ? "\(target) (org)" : target
        print("Adding runner '\(name)' for \(scopeLabel)...")
        do {
            try await manager.addRunner(
                name: name,
                repo: target,
                scope: scope,
                labels: command.labels ?? Runner.defaultLabels(for: effectiveIsolation),
                isolationMode: isolationMode,
                enableGUI: enableGUI,
                openFileLimit: openFileLimit,
                containerImage: command.image,
                containerEngine: command.engine,
                containerCPUs: command.cpus,
                containerMemoryMB: command.memoryMB,
                jit: command.jit,
                containerToolsOverride: command.containerToolsOverride,
                containerCachePaths: command.cachePaths.isEmpty ? nil : command.cachePaths,
                dockerInDocker: command.docker
            )
            let added = manager.runner(named: name)
            var message = "Runner '\(name)' added"
            if let mode = isolationMode {
                message += " with \(added?.isolationDisplayName(for: mode) ?? mode.displayName) isolation"
            } else {
                message += " (using global isolation mode)"
            }
            if let resources = added?.containerResourcesSummary {
                message += " (\(resources))"
            }
            if command.jit {
                message += " as a single-use (JIT) runner"
            }
            if command.docker {
                message += " with Docker-in-Docker"
            }
            message += enableGUI ? " with GUI access" : " (headless)"
            if let openFileLimit {
                message += " and open file limit \(openFileLimit)"
            }
            message += " and started successfully!"
            print(message)
            if let added, added.isJIT {
                for note in jitNotes(for: added, appIsRunning: menuBarAppIsRunning()) {
                    print(note)
                }
            }
            await hostContainerRunnersInForeground(manager: manager)
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }

    /// A container runner's Linux VM lives inside the process that started it,
    /// so a CLI that started any stays in the foreground, streaming their output,
    /// until Ctrl-C stops them. It also stays up through crash auto-restarts.
    @MainActor
    static func hostContainerRunnersInForeground(manager: RunnerManager) async {
        let hosted = manager.hostedContainerRunnerIDs
        guard !hosted.isEmpty else { return }
        let names = hosted.compactMap { id in manager.runners.first { $0.id == id }?.name }.sorted()
        print("Container runners run inside this process (\(names.joined(separator: ", "))). Leave it open; press Ctrl-C to stop them.")
        print("(Start them from the Mac Runner menu bar app to keep them running in the background.)")

        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        var stopRequested = false
        interrupt.setEventHandler { stopRequested = true }
        interrupt.resume()
        defer {
            interrupt.cancel()
            signal(SIGINT, SIG_DFL)
        }

        var followers: [UUID: LogFollower] = [:]
        for id in hosted {
            if let runner = manager.runners.first(where: { $0.id == id }),
               let path = manager.logPath(for: runner, source: .output) {
                // Only new output: earlier runs' lines are already in the log.
                followers[id] = LogFollower(path: path, startAtEnd: true)
            }
        }
        func isAlive(_ id: UUID) -> Bool {
            manager.runners.first(where: { $0.id == id })?.status == .running || manager.hasPendingRestart(id)
        }

        while hosted.contains(where: isAlive) {
            if stopRequested {
                for id in hosted where isAlive(id) {
                    let name = manager.runners.first { $0.id == id }?.name ?? id.uuidString
                    print("\nStopping '\(name)'...")
                    try? await manager.stopRunner(id)
                }
                break
            }
            for id in hosted {
                let prefix = hosted.count > 1 ? "[\(manager.runners.first { $0.id == id }?.name ?? "")] " : ""
                for line in followers[id]?.readNewLines() ?? [] {
                    print(prefix + line)
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        print(names.count == 1 ? "Runner '\(names[0])' stopped." : "Runners stopped: \(names.joined(separator: ", ")).")
    }

    @MainActor
    private static func handleRemove(args: [String]) async {
        guard let name = args.first else {
            print("Error: runner name required")
            print("Usage: mac-runner remove <name>")
            return
        }

        let manager = RunnerManager()
        guard let runner = manager.runner(named: name) else {
            print("Error: runner '\(name)' not found")
            return
        }

        print("Removing runner '\(name)'...")
        do {
            try await manager.removeRunner(runner.id)
            print("Runner '\(name)' removed.")
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func handleStart(args: [String]) async {
        guard let name = args.first else {
            print("Error: runner name required")
            print("Usage: mac-runner start <name>")
            return
        }

        let manager = RunnerManager()
        guard let runner = manager.runner(named: name) else {
            print("Error: runner '\(name)' not found")
            return
        }

        print("Starting runner '\(name)'...")
        do {
            try await manager.startRunner(runner.id)
            if let reason = manager.runner(named: name)?.storageBlockedReason {
                print("Runner '\(name)' is waiting for storage: \(reason) The app will retry every minute.")
                return
            }
            print("Runner '\(name)' started.")
            if let started = manager.runner(named: name), started.isJIT {
                for note in jitNotes(for: started, appIsRunning: menuBarAppIsRunning()) {
                    print(note)
                }
            }
            await hostContainerRunnersInForeground(manager: manager)
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func handleStop(args: [String]) async {
        guard let name = args.first else {
            print("Error: runner name required")
            print("Usage: mac-runner stop <name>")
            return
        }

        let manager = RunnerManager()
        guard let runner = manager.runner(named: name) else {
            print("Error: runner '\(name)' not found")
            return
        }

        print("Stopping runner '\(name)'...")
        do {
            try await manager.stopRunner(runner.id)
            print("Runner '\(name)' stopped.")
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func handleStatus(args: [String]) async {
        let manager = RunnerManager()
        let runners = manager.runners

        if args.contains("--resources") {
            await manager.refreshResourceUsage(measureDisk: true)
            print(resourceTable(runners: runners, usage: manager.resourceUsage))
            return
        }

        let running = runners.filter { $0.status == .running }.count
        let stopped = runners.filter { $0.status == .stopped }.count
        let paused = runners.filter { $0.status == .paused }.count
        let errored = runners.filter { $0.status == .error }.count

        print("mac-runner Status")
        print("  Total runners: \(runners.count)")
        print("  Running: \(running)")
        print("  Stopped: \(stopped)")
        if paused > 0 { print("  Paused: \(paused)") }
        if errored > 0 { print("  Errors: \(errored)") }

        let authenticated = await GHCLIService.shared.checkAuth()
        print("  GitHub auth: \(authenticated ? "authenticated" : "not authenticated")")

        for runner in manager.runners where runner.storageBlockedReason != nil {
            print("\(runner.name): waiting for storage — \(runner.storageBlockedReason ?? "")")
        }
        for line in autoPauseStatusLines(manager: manager) {
            print("  \(line)")
        }

        switch manager.currentSettings.isolationMode {
        case .none:
            print("  Global isolation: disabled")
        case .dedicatedUser(let username):
            print("  Global isolation: user (\(username))")
        case .container:
            print("  Global isolation: container")
        }

        let globalMode = manager.currentSettings.isolationMode
        let containerLines = containerStatusLines(runners: runners, global: globalMode)
        if !containerLines.isEmpty {
            print("  Container runners:")
            for line in containerLines {
                print("    \(line)")
            }
        }
        let jitLines = jitStatusLines(runners: runners)
        if !jitLines.isEmpty {
            print("  JIT runners (single-use, one registration per job):")
            for line in jitLines {
                print("    \(line)")
            }
        }
        if runners.contains(where: { $0.runsInDocker(global: globalMode) }) {
            let docker = DockerRunnerEngine.executablePath()
            let state: String
            if let docker {
                state = await DockerRunnerEngine.daemonInfo(docker: docker) != nil ? "running" : "not running"
            } else {
                state = "not installed"
            }
            print("  Docker: \(state)")
        }
    }

    /// `status` lines for container runners on Docker or without the default
    /// CPUs and memory, e.g. "linux-1: Container (Docker) · 4 CPUs, 8 GB · Docker-in-Docker".
    static func containerStatusLines(runners: [Runner], global globalMode: IsolationMode) -> [String] {
        runners.sorted { $0.name < $1.name }.compactMap { runner in
            let isolation = runner.effectiveIsolationMode(global: globalMode)
            guard isolation == .container else { return nil }
            let resources = runner.containerResourcesSummary
            guard runner.effectiveContainerEngine == .docker || resources != nil else { return nil }
            return "\(runner.name): \(runner.isolationDisplayName(for: isolation))" + (resources.map { " · \($0)" } ?? "")
                + (runner.usesDockerInDocker(global: globalMode) ? " · Docker-in-Docker" : "")
        }
    }

    /// `status` lines for JIT runners, e.g. "linux-1: JIT, registered as linux-1-3fa29c (GitHub ID 42)".
    static func jitStatusLines(runners: [Runner]) -> [String] {
        runners.filter(\.isJIT).sorted { $0.name < $1.name }.map { runner in
            let state: String
            if let registration = runner.jitRegistration {
                state = "registered as \(registration.name) (GitHub ID \(registration.id))"
            } else {
                state = runner.status == .running ? "between jobs, registering the next" : "not registered (\(runner.status.rawValue))"
            }
            return "\(runner.name): JIT, \(state)"
        }
    }

    /// What to tell someone who just started a JIT runner from the CLI.
    static func jitNotes(for runner: Runner, appIsRunning: Bool) -> [String] {
        var notes: [String] = []
        let wanted = ["self-hosted"]
        if !runner.labels.contains(where: { wanted.contains($0.lowercased()) }) {
            notes.append("Note: a JIT runner gets only the labels it's registered with (\(runner.labels.joined(separator: ","))); add self-hosted, the OS, and the architecture to --labels if your workflows ask for them.")
        }
        if !appIsRunning {
            notes.append("Note: this JIT runner exits after its job, and the Mac Runner menu bar app registers and starts the next one. It isn't running: open it (open -a MacRunner) to keep this runner taking jobs.")
        }
        return notes
    }

    /// Whether the Mac Runner menu bar app is running (it supervises JIT runners).
    static func menuBarAppIsRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.omniaura.mac-runner")
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
    }

    /// `mac-runner status --resources` output.
    static func resourceTable(runners: [Runner], usage: [UUID: RunnerResourceUsage]) -> String {
        let running = runners.filter { $0.status == .running || usage[$0.id] != nil }.sorted { $0.name < $1.name }
        guard !running.isEmpty else { return "No running runners." }

        var rows = [["NAME", "CPU", "MEMORY", "DISK", "PROCS"]]
        for runner in running {
            guard let item = usage[runner.id] else {
                // e.g. a container runner whose VM lives in another Mac Runner process.
                rows.append([runner.name, "-", "-", "-", "-"])
                continue
            }
            rows.append([runner.name, item.cpuText, item.memoryText, item.diskText ?? "-", "\(item.processCount)"])
        }
        let total = RunnerResourceUsage.total(running.compactMap { usage[$0.id] })
        rows.append(["TOTAL", total.cpuText, total.memoryText, total.diskText ?? "-", "\(total.processCount)"])

        let widths = (0..<rows[0].count).map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { column, value in
                column == 0 ? value.padding(toLength: widths[column], withPad: " ", startingAt: 0)
                    : String(repeating: " ", count: widths[column] - value.count) + value
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    @MainActor
    static func autoPauseStatusLines(manager: RunnerManager, now: Date = Date()) -> [String] {
        let settings = manager.currentSettings
        var lines: [String] = []

        if let quietHours = settings.quietHours, quietHours.enabled {
            let state = quietHours.isActive(at: now) ? "active now" : "inactive"
            lines.append("Quiet hours: \(quietHours.displayRange) (\(state))")
        } else {
            lines.append("Quiet hours: off")
        }

        if settings.pauseOnBattery {
            lines.append("Low-battery pause: below \(settings.batteryPauseThreshold)%")
        } else {
            lines.append("Low-battery pause: off")
        }

        for runner in manager.runners.sorted(by: { $0.name < $1.name }) {
            if let quietHours = runner.quietHours {
                lines.append("  \(runner.name): \(quietHours.enabled ? "quiet hours \(quietHours.displayRange)" : "never pauses for quiet hours")")
            }
            if runner.status == .paused, let reason = runner.autoPauseReason {
                lines.append("  \(runner.name): paused for \(reason.displayName)")
            }
        }
        return lines
    }

    @MainActor
    private static func handleApply(args: [String]) async {
        var path: String?
        var dryRun = false
        var assumeYes = false
        var prune = true
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-f", "--file":
                guard i + 1 < args.count else {
                    print("Error: \(args[i]) requires a path")
                    exitCode = 1
                    return
                }
                path = args[i + 1]
                i += 2
            case "--dry-run": dryRun = true; i += 1
            case "--yes", "-y": assumeYes = true; i += 1
            case "--no-prune": prune = false; i += 1
            default:
                print("Error: unknown option '\(args[i])'")
                exitCode = 1
                return
            }
        }

        let file = path ?? DeclarativeConfig.defaultPath()
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            print("Error: can't read \(file). Create one with: mac-runner export -o .mac-runner.yml")
            exitCode = 1
            return
        }

        let manager = RunnerManager()
        let desired: [DesiredRunner]
        let desiredSettings: AppSettings
        do {
            let config = try DeclarativeConfig.parse(text)
            desiredSettings = try config.resolvedSettings(manager.currentSettings)
            desired = try config.desiredRunners(globalIsolation: desiredSettings.isolationMode)
        } catch {
            print("Error: \(error.localizedDescription)")
            exitCode = 1
            return
        }

        let changes = ConfigPlanner.plan(
            desired: desired,
            desiredSettings: desiredSettings,
            current: manager.runners,
            currentSettings: manager.currentSettings,
            prune: prune
        )
        print("Plan for \(file):")
        guard !changes.isEmpty else {
            print("  No changes; runners already match.")
            return
        }
        for change in changes {
            print("  \(change.summary)")
        }
        guard !dryRun else { return }

        if changes.contains(where: \.isDestructive) && !assumeYes {
            print("\nThis removes or re-registers runners. Continue? [y/N] ", terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print("Cancelled.")
                exitCode = 1
                return
            }
        }

        let failures = await manager.apply(changes, settings: desiredSettings) { change, outcome in
            switch outcome {
            case .applied(let note):
                print("✓ \(change.summary)\(note.map { " — \($0)" } ?? "")")
            case .failed(let error):
                print("✗ \(change.summary): \(error.localizedDescription)")
            }
        }
        print(failures == 0 ? "Applied \(changes.count) change(s)." : "\(failures) of \(changes.count) change(s) failed.")
        if failures > 0 { exitCode = 1 }
        if manager.runners.contains(where: { $0.isJIT && $0.status == .running }), !menuBarAppIsRunning() {
            print("Note: JIT runners exit after each job, and the Mac Runner menu bar app registers and starts the next one. It isn't running: open it (open -a MacRunner) to keep them taking jobs.")
        }
        await hostContainerRunnersInForeground(manager: manager)
    }

    @MainActor
    private static func handleExport(args: [String]) async {
        var output: String?
        if let index = args.firstIndex(where: { $0 == "-o" || $0 == "--output" }) {
            guard index + 1 < args.count else {
                print("Error: \(args[index]) requires a path")
                exitCode = 1
                return
            }
            output = args[index + 1]
        }

        let manager = RunnerManager()
        do {
            let yaml = try DeclarativeConfig.export(runners: manager.runners, settings: manager.currentSettings).yaml()
            if let output {
                try yaml.write(toFile: output, atomically: true, encoding: .utf8)
                print("Wrote \(manager.runners.count) runner(s) to \(output)")
            } else {
                print(yaml, terminator: "")
            }
        } catch {
            print("Error: \(error.localizedDescription)")
            exitCode = 1
        }
    }

    @MainActor
    private static func handleLogs(args: [String]) async {
        let command: LogsCommand
        switch LogsCommand.parse(args) {
        case .success(let parsed): command = parsed
        case .failure(let error):
            print("Error: \(error.text)")
            print(LogsCommand.usage)
            return
        }

        let manager = RunnerManager()
        guard let runner = manager.runner(named: command.runnerName) else {
            print("Error: runner '\(command.runnerName)' not found")
            return
        }

        let what = command.source == .output ? "logs" : command.source.displayName.lowercased() + " logs"
        var follower: LogFollower?

        if let current = manager.logPath(for: runner, source: command.source),
           FileManager.default.fileExists(atPath: current) {
            let tail = RunnerLogs.tail(of: current, count: command.lines)
            for line in tail.lines {
                print(line)
            }
            follower = LogFollower(path: current, offset: tail.endOffset)
        } else if command.follow {
            print("No \(what) yet for '\(runner.name)'; waiting for them…")
        } else {
            print("No \(what) yet for '\(runner.name)'.")
            return
        }
        guard command.follow else { return }

        setvbuf(stdout, nil, _IOLBF, 0)
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            // Diagnostics start a new file each time the runner restarts or runs a job.
            if let latest = manager.logPath(for: runner, source: command.source),
               latest != follower?.path,
               FileManager.default.fileExists(atPath: latest) {
                if follower != nil {
                    print("==> \((latest as NSString).lastPathComponent) <==")
                }
                follower = LogFollower(path: latest, offset: 0)
            }
            for line in follower?.readNewLines() ?? [] {
                print(line)
            }
        }
    }

    @MainActor
    private static func handleSchedule(args: [String]) async {
        let command: ScheduleCommand
        switch ScheduleCommand.parse(args) {
        case .success(let parsed): command = parsed
        case .failure(let error):
            print("Error: \(error.text)")
            print(ScheduleCommand.usage)
            return
        }

        let manager = RunnerManager()
        var settings = manager.currentSettings

        switch command {
        case .show:
            break
        case .setGlobal(let window):
            settings.quietHours = window
            manager.updateSettings(settings)
            print("Quiet hours set to \(window.displayRange) for all runners.")
        case .disableGlobal:
            if let current = settings.quietHours {
                settings.quietHours = QuietHours(enabled: false, start: current.start, end: current.end)
                manager.updateSettings(settings)
            }
            print("Global quiet hours turned off.")
        case .setRunner(let name, let window):
            guard let runner = manager.runner(named: name) else {
                print("Error: runner '\(name)' not found")
                return
            }
            manager.setQuietHours(window, for: runner.id)
            switch window {
            case nil: print("'\(name)' now follows the global schedule.")
            case let window? where window.enabled: print("'\(name)' quiet hours set to \(window.displayRange).")
            default: print("'\(name)' will not pause for quiet hours.")
            }
        }

        for runner in manager.runners where runner.storageBlockedReason != nil {
            print("\(runner.name): waiting for storage — \(runner.storageBlockedReason ?? "")")
        }
        for line in autoPauseStatusLines(manager: manager) {
            print(line)
        }
        if command != .show {
            print("A running Mac Runner app applies this within a few seconds.")
        }
    }

    @MainActor
    private static func handleBattery(args: [String]) async {
        let command: BatteryCommand
        switch BatteryCommand.parse(args) {
        case .success(let parsed): command = parsed
        case .failure(let error):
            print("Error: \(error.text)")
            print(BatteryCommand.usage)
            return
        }

        let manager = RunnerManager()
        if case .set(let enabled, let threshold) = command {
            var settings = manager.currentSettings
            if let enabled { settings.pauseOnBattery = enabled }
            if let threshold { settings.batteryPauseThreshold = threshold }
            manager.updateSettings(settings)
        }

        let settings = manager.currentSettings
        print("Low-battery pause: \(settings.pauseOnBattery ? "on" : "off") (threshold \(settings.batteryPauseThreshold)%)")
        if let power = PowerSourceMonitor().currentState() {
            print("Battery: \(power.batteryLevel)% \(power.isOnBattery ? "(on battery)" : "(on AC power)")")
        } else {
            print("Battery: none detected on this Mac")
        }
    }

    @MainActor
    private static func handleSetup(args: [String]) async {
        if args.contains("--teardown") {
            await SetupWizard.runTeardown()
        } else {
            await SetupWizard.runSetup()
        }
    }

    @MainActor
    private static func handleUninstall(args: [String]) async {
        let dryRun = args.contains("--dry-run")
        let assumeYes = args.contains("--yes") || args.contains("-y")
        let includeApplication = args.contains("--include-app")
        let keepRunners = args.contains("--keep-runners")

        let config: RunnerConfig
        do {
            config = try ConfigService().loadConfig()
        } catch {
            print("Error: failed to load config: \(error.localizedDescription)")
            return
        }

        let service = UninstallService()
        let plan = service.plan(
            runners: config.runners,
            globalIsolationMode: config.settings.isolationMode,
            includeApplication: includeApplication
        )
        // A Docker runner's work directory and caches are volumes, not files.
        let dockerVolumes = config.runners
            .filter { $0.runsInDocker(global: config.settings.isolationMode) }
            .flatMap { runner in
                [DockerRunnerEngine.workVolumeName(for: runner.id)]
                    + DockerRunnerEngine.cacheMounts(for: runner.id, paths: runner.containerCachePaths ?? []).map(\.volume)
                    + (runner.dockerInDocker == true ? [DockerRunnerEngine.dockerVolumeName(for: runner.id)] : [])
            }

        guard !plan.isEmpty || !dockerVolumes.isEmpty else {
            print("Nothing to uninstall - no Mac Runner files found.")
            return
        }

        printPlan(plan, keepRunners: keepRunners, dockerVolumes: dockerVolumes)

        if dryRun {
            let size = ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file)
            print("")
            print("Dry run: nothing was deleted. \(plan.items.count) item(s), \(size) would be freed.")
            return
        }

        if !assumeYes {
            print("")
            print("This cannot be undone. Continue? [y/N] ", terminator: "")
            guard let response = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(),
                  response == "y" || response == "yes" else {
                print("Uninstall cancelled.")
                return
            }
        }

        // Stop anything still running so its workspace is not deleted mid-job.
        //
        // RunnerManager is built only when there is something to stop: constructing it
        // pulls in UNUserNotificationCenter, which traps when the CLI runs outside an app
        // bundle - the exact state a user is in when uninstalling after deleting the app.
        let runningRunners = config.runners.filter { $0.status == .running }
        if !runningRunners.isEmpty {
            let manager = RunnerManager()
            for runner in runningRunners {
                print("Stopping '\(runner.name)'...")
                try? await manager.stopRunner(runner.id)
            }
        }

        // Deregister from GitHub before the credentials are deleted, otherwise the
        // runners linger in repository settings as permanently offline entries.
        var deregistered: [String] = []
        var failedDeregistrations: [String] = []
        if !keepRunners {
            for runner in plan.runnersToDeregister {
                guard let ghId = runner.githubRunnerId else { continue }
                do {
                    // Already gone counts: stopping a JIT runner above deleted its registration.
                    try await GHCLIService.shared.deleteRunnerIfPresent(target: runner.target, githubRunnerId: ghId)
                    deregistered.append(runner.name)
                } catch {
                    failedDeregistrations.append("\(runner.name) (\(runner.repo))")
                }
            }
            // Offline registrations left by JIT runners' earlier starts.
            for runner in config.runners where runner.isJIT {
                guard let remote = try? await GHCLIService.shared.listRemoteRunners(for: runner.target) else { continue }
                for leftover in JITRunner.leftoverRegistrations(of: runner.name, in: remote) {
                    _ = try? await GHCLIService.shared.deleteRunnerIfPresent(target: runner.target, githubRunnerId: leftover.id)
                }
            }
        }

        // Containers, work and cache volumes, for any container runner that ever used Docker.
        var removedVolumes = 0
        for runner in config.runners where runner.effectiveIsolationMode(global: config.settings.isolationMode) == .container {
            removedVolumes += await DockerRunnerEngine.removeContainerAndVolumes(for: runner.id)
        }

        let report = service.execute(
            plan: plan,
            dryRun: false,
            deregistered: deregistered,
            failedDeregistrations: failedDeregistrations
        )

        printReport(report, service: service, includedApplication: includeApplication, keepRunners: keepRunners)
        if removedVolumes > 0 {
            print("Removed \(removedVolumes) Docker volume(s).")
        }
    }

    private static func printPlan(_ plan: UninstallPlan, keepRunners: Bool, dockerVolumes: [String] = []) {
        print("Mac Runner uninstall")
        print("")

        if !plan.activeRunnerNames.isEmpty {
            print("Running runners (will be stopped): \(plan.activeRunnerNames.joined(separator: ", "))")
            print("")
        }

        if !keepRunners && !plan.runnersToDeregister.isEmpty {
            print("Will deregister from GitHub:")
            for runner in plan.runnersToDeregister {
                print("  \(runner.name)  (\(runner.repo))")
            }
            print("")
        }

        print("Will delete:")
        let pathWidth = min(plan.items.map(\.path.count).max() ?? 0, 72)
        for item in plan.items {
            let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
            let path = abbreviate(item.path)
            let padded = path.padding(toLength: max(pathWidth, path.count), withPad: " ", startingAt: 0)
            print("  \(padded)  \(size.padding(toLength: 10, withPad: " ", startingAt: 0))  \(item.category.rawValue)")
        }

        let total = ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file)
        print("")
        print("Total: \(plan.items.count) item(s), \(total)")

        if !dockerVolumes.isEmpty {
            print("")
            print("Will remove Docker volumes (runner work directories, caches, and Docker-in-Docker images):")
            for volume in dockerVolumes {
                print("  \(volume)")
            }
        }
    }

    private static func printReport(
        _ report: UninstallReport,
        service: UninstallService,
        includedApplication: Bool,
        keepRunners: Bool
    ) {
        let size = ByteCountFormatter.string(fromByteCount: report.reclaimedBytes, countStyle: .file)
        print("")
        print("Removed \(report.removedPaths.count) item(s), freed \(size).")

        if !report.deregisteredRunners.isEmpty {
            print("Deregistered from GitHub: \(report.deregisteredRunners.joined(separator: ", "))")
        }

        if !report.failedDeregistrations.isEmpty {
            print("")
            print("Could not deregister: \(report.failedDeregistrations.joined(separator: ", "))")
            print("These remain listed as offline runners. Remove them from the repository's")
            print("Settings > Actions > Runners page.")
        }

        if !report.failedPaths.isEmpty {
            print("")
            print("Could not remove:")
            for path in report.failedPaths {
                print("  \(abbreviate(path))")
            }
        }

        if keepRunners {
            print("")
            print("Runners were left registered on GitHub (--keep-runners).")
        }

        if !includedApplication {
            print("")
            if service.isHomebrewManaged() {
                print("Local data is gone. To remove the app itself, run:")
                print("  brew uninstall --cask mac-runner")
            } else {
                print("Local data is gone. To remove the app itself, re-run with --include-app")
                print("or delete /Applications/MacRunner.app manually.")
            }
        }
    }

    /// Render a home-relative path as `~/...` so plan output stays readable.
    ///
    /// Matching must land on a path boundary: a bare prefix test rewrites
    /// `/Users/bobby/data` as `~by/data` for home `/Users/bob`. This list is what a user
    /// reads before confirming a destructive action, so every path shown must be exact.
    static func abbreviate(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static func handleCleanup(args: [String]) async {
        let dryRun = args.contains("--dry-run")
        let includeSharedCaches = !args.contains("--workspaces-only")
        do {
            guard let lock = await StorageMaintenanceService.acquireAdmissionLock() else {
                throw StorageMaintenanceError(message: "A runner start or maintenance is still in progress. Retry later.")
            }
            defer { lock.unlock() }
            let config = try ConfigService().loadConfig()
            let report = try DiskCleanupService().cleanup(
                runners: config.runners,
                globalIsolationMode: config.settings.isolationMode,
                includeSharedCaches: includeSharedCaches,
                dryRun: dryRun
            )
            let size = ByteCountFormatter.string(fromByteCount: report.reclaimedBytes, countStyle: .file)
            print("\(dryRun ? "Would reclaim" : "Reclaimed") \(size) from \(report.removedPaths.count) item(s).")
            if !report.skippedRunnerNames.isEmpty {
                print("Skipped active runners: \(report.skippedRunnerNames.joined(separator: ", "))")
                if includeSharedCaches {
                    print("Shared CI caches were preserved while runners are active.")
                }
            }
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }
}
