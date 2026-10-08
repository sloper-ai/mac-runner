import Foundation

/// Parsed `mac-runner add` arguments.
struct AddCommand: Equatable {
    var target: String
    var name: String?
    var labels: [String]?
    var scope: RunnerScope = .repo
    var isolationMode: IsolationMode?
    var enableGUI = false
    var openFileLimit: Int?
    var image: String?
    var engine: ContainerEngine?
    var cpus: Int?
    var memoryMB: Int?
    /// Register a single-use runner for each job.
    var jit = false
    /// Install no tools when the container starts.
    var noTools = false
    /// Container paths kept in Docker cache volumes, normalized.
    var cachePaths: [String] = []
    /// Give jobs their own Docker daemon (Docker-in-Docker).
    var docker = false

    /// Parses the target and its options. Options it doesn't know are skipped.
    static func parse(
        _ args: [String],
        hostCores: Int = ProcessInfo.processInfo.processorCount
    ) -> Result<AddCommand, CLIParseError> {
        guard let target = args.first else {
            return .failure(.message("repository or organization required"))
        }
        var command = AddCommand(target: target)

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--org":
                command.scope = .org
                i += 1
            case "--repo":
                command.scope = .repo
                i += 1
            case "--name" where i + 1 < args.count:
                command.name = args[i + 1]
                i += 2
            case "--labels" where i + 1 < args.count:
                command.labels = args[i + 1].split(separator: ",").map(String.init)
                i += 2
            case "--isolation" where i + 1 < args.count:
                let mode = args[i + 1].lowercased()
                switch mode {
                case "none":
                    command.isolationMode = IsolationMode.none  // not `.none`, which would be Optional.none (use global)
                case "user":
                    command.isolationMode = .dedicatedUser(username: IsolationMode.defaultUsername)
                case "container":
                    command.isolationMode = .container
                default:
                    return .failure(.message("invalid isolation mode '\(mode)'. Valid options: none, user, container"))
                }
                i += 2
            case "--enable-gui":
                command.enableGUI = true
                i += 1
            case "--image" where i + 1 < args.count:
                command.image = args[i + 1]
                i += 2
            case "--engine" where i + 1 < args.count:
                let engine = args[i + 1].lowercased()
                guard let parsed = ContainerEngine(rawValue: engine) else {
                    return .failure(.message("invalid engine '\(engine)'. Valid options: apple, docker"))
                }
                command.engine = parsed
                i += 2
            case "--cpus" where i + 1 < args.count:
                guard let cpus = Int(args[i + 1]) else {
                    return .failure(.message("--cpus must be a whole number of CPUs"))
                }
                if let problem = ResourceLimits.containerCPUsProblem(cpus, hostCores: hostCores) {
                    return .failure(.message("--cpus \(problem)"))
                }
                command.cpus = cpus
                i += 2
            case "--memory" where i + 1 < args.count:
                guard let memory = ResourceLimits.containerMemoryMB(from: args[i + 1]) else {
                    return .failure(.message("invalid --memory '\(args[i + 1])'. Use e.g. 8g, 8192m, or 8192 (MB)"))
                }
                if let problem = ResourceLimits.containerMemoryProblem(memory) {
                    return .failure(.message("--memory \(problem)"))
                }
                command.memoryMB = memory
                i += 2
            case "--open-files" where i + 1 < args.count:
                guard let parsed = Int(args[i + 1]), parsed > 0 else {
                    return .failure(.message("--open-files must be a positive integer"))
                }
                command.openFileLimit = parsed
                i += 2
            case "--jit":
                command.jit = true
                i += 1
            case "--no-tools":
                command.noTools = true
                i += 1
            case "--docker":
                command.docker = true
                i += 1
            case "--cache":
                guard i + 1 < args.count else {
                    return .failure(.message("--cache requires a container path"))
                }
                switch DockerRunnerEngine.cachePaths(command.cachePaths + [args[i + 1]]) {
                case .success(let paths): command.cachePaths = paths
                case .failure(let error): return .failure(.message("--cache: \(error.text)"))
                }
                i += 2
            default:
                i += 1
            }
        }

        // Validate the identifier shape against the chosen scope.
        switch command.scope {
        case .repo:
            guard target.contains("/") else {
                return .failure(.message("repository required in owner/repo format (or pass --org to register an organization runner)"))
            }
        case .org:
            guard !target.contains("/") else {
                return .failure(.message("--org expects an organization login only (no slashes)"))
            }
        }
        return .success(command)
    }

    /// Container options are only valid for a runner that will use container
    /// isolation, its own or the global mode; cache volumes need Docker; and a
    /// JIT runner needs a label, since it gets only the labels it's given.
    func validationError(globalIsolation: IsolationMode) -> CLIParseError? {
        if jit, labels?.isEmpty == true {
            return .message("--jit needs at least one label: GitHub gives a JIT runner only the labels it's registered with")
        }
        guard (isolationMode ?? globalIsolation) == .container else {
            let containerOptions = [
                ("--image", image != nil), ("--engine", engine != nil), ("--cpus", cpus != nil), ("--memory", memoryMB != nil),
                ("--no-tools", noTools), ("--cache", !cachePaths.isEmpty), ("--docker", docker),
            ]
            guard let option = containerOptions.first(where: { $0.1 })?.0 else { return nil }
            return .message("\(option) only applies to container isolation (--isolation container)")
        }
        if !cachePaths.isEmpty && engine != .docker {
            return .message("--cache needs the Docker engine (--engine docker)")
        }
        if docker && engine != .docker {
            return .message("--docker needs the Docker engine (--engine docker)")
        }
        return nil
    }

    /// The tools to install at each container start instead of detected ones: none with --no-tools.
    var containerToolsOverride: [String]? {
        noTools ? [] : nil
    }
}

/// Parsed `mac-runner schedule` arguments.
enum ScheduleCommand: Equatable {
    case show
    case setGlobal(QuietHours)
    case disableGlobal
    case setRunner(name: String, QuietHours?)

    static let usage = """
    Usage:
      mac-runner schedule                                   Show quiet hours
      mac-runner schedule --start HH:mm --end HH:mm         Pause all runners daily in this window
      mac-runner schedule --off                             Turn global quiet hours off
      mac-runner schedule --runner <name> --start HH:mm --end HH:mm
      mac-runner schedule --runner <name> --never           Never pause this runner for quiet hours
      mac-runner schedule --runner <name> --global          Follow the global schedule
    """

    static func parse(_ args: [String]) -> Result<ScheduleCommand, CLIParseError> {
        var runner: String?
        var start: String?
        var end: String?
        var off = false
        var never = false
        var global = false

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--runner", "--start", "--end":
                guard i + 1 < args.count else { return .failure(.message("\(arg) requires a value")) }
                let value = args[i + 1]
                if arg == "--runner" {
                    runner = value
                } else {
                    guard let time = QuietHours.normalizedTime(value) else {
                        return .failure(.message("Invalid time '\(value)'. Use 24-hour HH:mm, e.g. 22:00"))
                    }
                    if arg == "--start" { start = time } else { end = time }
                }
                i += 2
            case "--off": off = true; i += 1
            case "--never": never = true; i += 1
            case "--global": global = true; i += 1
            default:
                return .failure(.message("Unknown option '\(arg)'"))
            }
        }

        let window: QuietHours?
        switch (start, end) {
        case let (start?, end?): window = QuietHours(enabled: true, start: start, end: end)
        case (nil, nil): window = nil
        default: return .failure(.message("--start and --end must be given together"))
        }

        let modes = [window != nil, off, never, global].filter { $0 }.count
        guard modes <= 1 else {
            return .failure(.message("Choose one of --start/--end, --off, --never, --global"))
        }

        if let runner {
            if let window { return .success(.setRunner(name: runner, window)) }
            if never { return .success(.setRunner(name: runner, QuietHours(enabled: false, start: "00:00", end: "00:00"))) }
            if global { return .success(.setRunner(name: runner, nil)) }
            return .failure(.message("--runner needs --start/--end, --never, or --global"))
        }

        if never || global { return .failure(.message("--never and --global apply to a single --runner")) }
        if let window { return .success(.setGlobal(window)) }
        if off { return .success(.disableGlobal) }
        return .success(.show)
    }
}

/// Parsed `mac-runner battery` arguments.
enum BatteryCommand: Equatable {
    case show
    case set(enabled: Bool?, threshold: Int?)

    static let usage = """
    Usage:
      mac-runner battery                          Show the low-battery pause setting
      mac-runner battery on|off [--threshold N]   Pause runners on battery below N% (default 20)
    """

    static func parse(_ args: [String]) -> Result<BatteryCommand, CLIParseError> {
        var enabled: Bool?
        var threshold: Int?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "on": enabled = true; i += 1
            case "off": enabled = false; i += 1
            case "--threshold":
                guard i + 1 < args.count, let value = Int(args[i + 1].trimmingCharacters(in: CharacterSet(charactersIn: "%"))) else {
                    return .failure(.message("--threshold requires a percentage"))
                }
                guard AppSettings.batteryPauseThresholdRange.contains(value) else {
                    let range = AppSettings.batteryPauseThresholdRange
                    return .failure(.message("Threshold must be between \(range.lowerBound) and \(range.upperBound)"))
                }
                threshold = value
                i += 2
            default:
                return .failure(.message("Unknown option '\(args[i])'"))
            }
        }

        if enabled == nil && threshold == nil { return .success(.show) }
        return .success(.set(enabled: enabled, threshold: threshold))
    }
}

enum CLIParseError: LocalizedError, Equatable {
    case message(String)

    var text: String {
        switch self {
        case .message(let text): return text
        }
    }

    var errorDescription: String? { text }
}

/// Parsed `mac-runner logs` arguments.
struct LogsCommand: Equatable {
    static let defaultLines = 50

    var runnerName: String
    var lines = LogsCommand.defaultLines
    var follow = false
    var source: RunnerLogs.Source = .output

    static let usage = """
    Usage: mac-runner logs <name> [--lines N] [--follow] [--diag | --job]
      -n, --lines N   Show the last N lines (default 50)
      -f, --follow    Keep printing new lines as they're written (Ctrl-C to stop)
      --diag          Show the runner's diagnostics log (_diag/Runner_*) instead of its output
      --job           Show the newest job's diagnostics log (_diag/Worker_*)
    """

    static func parse(_ args: [String]) -> Result<LogsCommand, CLIParseError> {
        var name: String?
        var command = LogsCommand(runnerName: "")

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-n", "--lines":
                guard i + 1 < args.count, let count = Int(args[i + 1]), count > 0 else {
                    return .failure(.message("\(arg) requires a positive number"))
                }
                command.lines = count
                i += 2
            case "-f", "--follow":
                command.follow = true
                i += 1
            case "--diag", "--job":
                let source: RunnerLogs.Source = arg == "--diag" ? .diagnostics : .jobDiagnostics
                guard command.source == .output || command.source == source else {
                    return .failure(.message("--diag and --job can't be combined"))
                }
                command.source = source
                i += 1
            default:
                guard !arg.hasPrefix("-"), name == nil else {
                    return .failure(.message("Unknown option '\(arg)'"))
                }
                name = arg
                i += 1
            }
        }

        guard let name else { return .failure(.message("runner name required")) }
        command.runnerName = name
        return .success(command)
    }
}
