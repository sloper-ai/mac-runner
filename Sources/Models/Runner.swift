import Foundation

/// Whether a runner is registered against a single repository or an entire
/// organization. Org-level runners can be picked up by any repository in the
/// organization that the runner group grants access to.
enum RunnerScope: String, Codable, Sendable {
    case repo
    case org

    var displayName: String {
        switch self {
        case .repo: return "Repository"
        case .org: return "Organization"
        }
    }
}

struct Runner: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var name: String
    /// Target identifier. For `.repo` scope this is "owner/repo"; for `.org` scope this is the org login.
    var repo: String
    /// Whether this runner is registered to a single repository or an entire organization.
    /// Defaults to `.repo` for backward compatibility with pre-v1.11 configs.
    var scope: RunnerScope
    var labels: [String]
    var enabled: Bool
    var status: RunnerStatus
    var githubRunnerId: Int?
    var busy: Bool  // Whether runner is currently executing a job
    var isolationMode: IsolationMode?  // Per-runner isolation override (nil = use global setting)
    var enableGUI: Bool  // Whether to enable GUI access for this runner (default: false, headless)
    var lastRestartEvent: String?
    var openFileLimit: Int?  // Per-runner override for max open files (nil = use global setting)
    var quietHours: QuietHours?  // Per-runner pause schedule (nil = use global setting)
    var autoPauseReason: AutoPauseReason?  // Set while Mac Runner has paused this runner automatically
    /// Set when the runner was started by hand while paused for this reason; it
    /// keeps running until that condition clears. Persisted so a CLI start holds too.
    var autoPauseOverride: AutoPauseReason?
    /// Container isolation: OCI image to run (nil = the default runner image).
    var containerImage: String?
    /// Container isolation: tools chosen when the runner was created, installed
    /// each time its container starts.
    var containerTools: [String]?
    /// Container isolation: the engine that runs the container (nil = `.apple`).
    var containerEngine: ContainerEngine?
    /// Container isolation: CPUs and memory (in MB) for the container
    /// (nil = `ResourceLimits.defaultContainerCPUs` and `defaultContainerMemoryMB`).
    var containerCPUs: Int?
    var containerMemoryMB: Int?
    /// Just-in-time (single-use) registration: each start registers a new
    /// runner for one job from a JIT config, with a fresh workspace, and that
    /// registration is deleted when it exits. nil = false: one long-lived
    /// registration, as before JIT runners existed.
    var jit: Bool?
    /// A JIT runner's current registration on GitHub, while it has one. Its
    /// ID is also `githubRunnerId`.
    var jitRegistration: JITRegistration?
    /// Container isolation: the tools to install each time the container
    /// starts, in place of those detected when the runner was created
    /// (`containerTools`). [] installs nothing (`--no-tools`); nil uses the
    /// detected ones.
    var containerToolsOverride: [String]?
    /// Docker engine: container paths backed by named volumes that outlive
    /// each container (package caches, say), so they survive across jobs.
    var containerCachePaths: [String]?

    init(
        id: UUID = UUID(),
        name: String,
        repo: String,
        scope: RunnerScope = .repo,
        labels: [String] = Runner.defaultLabels,
        enabled: Bool = true,
        status: RunnerStatus = .stopped,
        githubRunnerId: Int? = nil,
        busy: Bool = false,
        isolationMode: IsolationMode? = nil,
        enableGUI: Bool = false,
        lastRestartEvent: String? = nil,
        openFileLimit: Int? = nil,
        quietHours: QuietHours? = nil,
        autoPauseReason: AutoPauseReason? = nil,
        containerEngine: ContainerEngine? = nil,
        containerCPUs: Int? = nil,
        containerMemoryMB: Int? = nil,
        jit: Bool? = nil,
        containerToolsOverride: [String]? = nil,
        containerCachePaths: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.repo = repo
        self.scope = scope
        self.labels = labels
        self.enabled = enabled
        self.status = status
        self.githubRunnerId = githubRunnerId
        self.busy = busy
        self.isolationMode = isolationMode
        self.enableGUI = enableGUI
        self.lastRestartEvent = lastRestartEvent
        self.openFileLimit = ResourceLimits.normalizedOpenFileLimit(openFileLimit)
        self.quietHours = quietHours
        self.autoPauseReason = autoPauseReason
        self.containerEngine = containerEngine
        self.containerCPUs = containerCPUs
        self.containerMemoryMB = containerMemoryMB
        self.jit = jit == true ? true : nil
        self.containerToolsOverride = containerToolsOverride
        self.containerCachePaths = containerCachePaths.flatMap { $0.isEmpty ? nil : $0 }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        repo = try container.decode(String.self, forKey: .repo)
        // Default to .repo for configs written before scope was introduced.
        scope = try container.decodeIfPresent(RunnerScope.self, forKey: .scope) ?? .repo
        labels = try container.decode([String].self, forKey: .labels)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        status = try container.decode(RunnerStatus.self, forKey: .status)
        githubRunnerId = try container.decodeIfPresent(Int.self, forKey: .githubRunnerId)
        // Default busy to false for backward compatibility
        busy = try container.decodeIfPresent(Bool.self, forKey: .busy) ?? false
        // Per-runner isolation mode (added in v1.5.0)
        isolationMode = try container.decodeIfPresent(IsolationMode.self, forKey: .isolationMode)
        // Default GUI access to false (headless) for backward compatibility
        enableGUI = try container.decodeIfPresent(Bool.self, forKey: .enableGUI) ?? false
        // Default restart event to nil for backward compatibility
        lastRestartEvent = try container.decodeIfPresent(String.self, forKey: .lastRestartEvent)
        openFileLimit = ResourceLimits.normalizedOpenFileLimit(
            try container.decodeIfPresent(Int.self, forKey: .openFileLimit)
        )
        quietHours = try container.decodeIfPresent(QuietHours.self, forKey: .quietHours)
        autoPauseReason = try container.decodeIfPresent(AutoPauseReason.self, forKey: .autoPauseReason)
        autoPauseOverride = try container.decodeIfPresent(AutoPauseReason.self, forKey: .autoPauseOverride)
        containerImage = try container.decodeIfPresent(String.self, forKey: .containerImage)
        containerTools = try container.decodeIfPresent([String].self, forKey: .containerTools)
        // Configs written before the Docker engine existed have Apple's (nil).
        containerEngine = try container.decodeIfPresent(ContainerEngine.self, forKey: .containerEngine)
        containerCPUs = try container.decodeIfPresent(Int.self, forKey: .containerCPUs)
        containerMemoryMB = try container.decodeIfPresent(Int.self, forKey: .containerMemoryMB)
        // Configs written before JIT runners existed have long-lived ones (nil).
        jit = try container.decodeIfPresent(Bool.self, forKey: .jit) == true ? true : nil
        jitRegistration = try container.decodeIfPresent(JITRegistration.self, forKey: .jitRegistration)
        containerToolsOverride = try container.decodeIfPresent([String].self, forKey: .containerToolsOverride)
        containerCachePaths = try container.decodeIfPresent([String].self, forKey: .containerCachePaths)
    }

    /// User-editable settings, compared when reconciling concurrent config edits.
    struct Configuration: Equatable {
        var name: String
        var repo: String
        var scope: RunnerScope
        var labels: [String]
        var enabled: Bool
        var githubRunnerId: Int?
        var isolationMode: IsolationMode?
        var enableGUI: Bool
        var openFileLimit: Int?
        var quietHours: QuietHours?
        var containerImage: String?
        var containerTools: [String]?
        var containerEngine: ContainerEngine?
        var containerCPUs: Int?
        var containerMemoryMB: Int?
        var jit: Bool?
        /// Changes with `githubRunnerId` (each JIT start), so the two travel together.
        var jitRegistration: JITRegistration?
        var containerToolsOverride: [String]?
        var containerCachePaths: [String]?
    }

    var configuration: Configuration {
        get {
            Configuration(
                name: name, repo: repo, scope: scope, labels: labels, enabled: enabled,
                githubRunnerId: githubRunnerId, isolationMode: isolationMode, enableGUI: enableGUI,
                openFileLimit: openFileLimit, quietHours: quietHours,
                containerImage: containerImage, containerTools: containerTools,
                containerEngine: containerEngine,
                containerCPUs: containerCPUs, containerMemoryMB: containerMemoryMB,
                jit: jit, jitRegistration: jitRegistration,
                containerToolsOverride: containerToolsOverride, containerCachePaths: containerCachePaths
            )
        }
        set {
            name = newValue.name
            repo = newValue.repo
            scope = newValue.scope
            labels = newValue.labels
            enabled = newValue.enabled
            githubRunnerId = newValue.githubRunnerId
            isolationMode = newValue.isolationMode
            enableGUI = newValue.enableGUI
            openFileLimit = newValue.openFileLimit
            quietHours = newValue.quietHours
            containerImage = newValue.containerImage
            containerTools = newValue.containerTools
            containerEngine = newValue.containerEngine
            containerCPUs = newValue.containerCPUs
            containerMemoryMB = newValue.containerMemoryMB
            jit = newValue.jit
            jitRegistration = newValue.jitRegistration
            containerToolsOverride = newValue.containerToolsOverride
            containerCachePaths = newValue.containerCachePaths
        }
    }

    /// Persisted run state, compared when reconciling concurrent config edits.
    struct PersistedState: Equatable {
        var status: RunnerStatus
        var autoPauseReason: AutoPauseReason?
        var autoPauseOverride: AutoPauseReason?
    }

    var persistedState: PersistedState {
        get { PersistedState(status: status, autoPauseReason: autoPauseReason, autoPauseOverride: autoPauseOverride) }
        set {
            status = newValue.status
            autoPauseReason = newValue.autoPauseReason
            autoPauseOverride = newValue.autoPauseOverride
        }
    }

    static let defaultLabels = ["macos", "mac-runner"]

    /// Container runners are Linux, so they shouldn't advertise `macos`.
    static func defaultLabels(for isolation: IsolationMode) -> [String] {
        isolation == .container ? ["linux", "mac-runner"] : defaultLabels
    }

    /// Convenience target descriptor pairing this runner's scope and identifier.
    var target: RunnerTarget {
        RunnerTarget(scope: scope, identifier: repo)
    }

    /// Returns the effective isolation mode for this runner.
    ///
    /// If the runner has a specific isolation mode set, that is returned.
    /// Otherwise, falls back to the global app settings isolation mode.
    ///
    /// - Parameter globalMode: The global isolation mode from app settings.
    /// - Returns: The isolation mode to use for this runner.
    func effectiveIsolationMode(global globalMode: IsolationMode) -> IsolationMode {
        return isolationMode ?? globalMode
    }

    /// The engine that runs this runner's container: its own, else Apple's.
    var effectiveContainerEngine: ContainerEngine {
        containerEngine ?? .apple
    }

    /// Whether this runner runs in Docker: container isolation on the Docker engine.
    func runsInDocker(global globalMode: IsolationMode) -> Bool {
        effectiveIsolationMode(global: globalMode) == .container && effectiveContainerEngine == .docker
    }

    /// `isolation`'s name as shown for this runner: container runners on
    /// Docker name their engine, e.g. "Container (Docker)".
    func isolationDisplayName(for isolation: IsolationMode) -> String {
        guard isolation == .container, effectiveContainerEngine == .docker else { return isolation.displayName }
        return "\(isolation.displayName) (\(ContainerEngine.docker.displayName))"
    }

    /// CPUs the runner's container gets: its own count, else the default.
    var effectiveContainerCPUs: Int {
        containerCPUs ?? ResourceLimits.defaultContainerCPUs
    }

    /// Memory the runner's container gets, in MB: its own, else the default.
    var effectiveContainerMemoryMB: Int {
        containerMemoryMB ?? ResourceLimits.defaultContainerMemoryMB
    }

    /// The container's CPUs and memory, e.g. "4 CPUs, 8 GB".
    var containerResourcesDescription: String {
        let cpus = effectiveContainerCPUs == 1 ? "1 CPU" : "\(effectiveContainerCPUs) CPUs"
        return "\(cpus), \(ResourceLimits.memoryDescription(megabytes: effectiveContainerMemoryMB))"
    }

    /// `containerResourcesDescription` when either differs from the default;
    /// nil otherwise.
    var containerResourcesSummary: String? {
        guard effectiveContainerCPUs != ResourceLimits.defaultContainerCPUs
                || effectiveContainerMemoryMB != ResourceLimits.defaultContainerMemoryMB else { return nil }
        return containerResourcesDescription
    }

    /// Whether each start registers a single-use (JIT) runner.
    var isJIT: Bool {
        jit == true
    }

    /// The name GitHub knows the running runner by: a JIT runner's current
    /// registration (`<name>-<6 hex>`), else the runner's own name.
    var registeredName: String {
        jitRegistration?.name ?? name
    }

    /// Container isolation: the tools installed each time its container starts.
    var effectiveContainerTools: [String] {
        containerToolsOverride ?? containerTools ?? []
    }

    func effectiveOpenFileLimit(global globalLimit: Int) -> Int {
        openFileLimit ?? globalLimit
    }

    /// The pause schedule that applies to this runner: its own, or the global one.
    func effectiveQuietHours(global globalQuietHours: QuietHours?) -> QuietHours? {
        quietHours ?? globalQuietHours
    }
}

/// One start's single-use (JIT) runner registration on GitHub.
struct JITRegistration: Codable, Sendable, Equatable {
    /// GitHub's runner ID, deleted when the runner exits or is stopped.
    var id: Int
    /// The name it's registered under: the runner's name and 6 random hex digits.
    var name: String
    /// When it was registered; the runner was launched right after.
    var createdAt: Date
}

/// A scope-aware identifier for GitHub Actions runner registration targets.
///
/// Encapsulates the dual nature of GitHub's runner API: repository-level
/// runners live under `repos/{owner}/{repo}/...` while organization-level
/// runners live under `orgs/{org}/...`. Both share the same registration
/// download URL — `https://github.com/{identifier}` — which `config.sh`
/// uses to phone home.
struct RunnerTarget: Sendable, Equatable, Hashable {
    let scope: RunnerScope
    let identifier: String  // "owner/repo" for .repo, "org" for .org

    /// REST API path prefix used by `gh api` calls (no leading slash).
    var apiPath: String {
        switch scope {
        case .repo: return "repos/\(identifier)"
        case .org:  return "orgs/\(identifier)"
        }
    }

    /// URL passed to `config.sh --url` when registering the runner.
    var registrationURL: String {
        "https://github.com/\(identifier)"
    }

    /// Human-readable description suitable for log lines and CLI output.
    var displayName: String {
        switch scope {
        case .repo: return identifier
        case .org:  return "\(identifier) (org)"
        }
    }
}

enum RunnerStatus: String, Codable, Sendable {
    case running
    case stopped
    case paused
    case error

    var icon: String {
        switch self {
        case .running: return "●"
        case .stopped: return "○"
        case .paused: return "⏸"
        case .error: return "⚠️"
        }
    }

    var color: String {
        switch self {
        case .running: return "green"
        case .stopped: return "gray"
        case .paused: return "orange"
        case .error: return "red"
        }
    }
}

struct RunnerConfig: Codable, Sendable, Equatable {
    var runners: [Runner]
    var settings: AppSettings

    static let `default` = RunnerConfig(
        runners: [],
        settings: .default
    )
}

enum IsolationMode: Codable, Sendable, Equatable {
    case none
    case dedicatedUser(username: String)
    case container  // Linux container isolation; each runner's `ContainerEngine` runs it

    static let defaultUsername = "_macrunner"

    private enum CodingKeys: String, CodingKey {
        case type, username
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode("none", forKey: .type)
        case .dedicatedUser(let username):
            try container.encode("dedicatedUser", forKey: .type)
            try container.encode(username, forKey: .username)
        case .container:
            try container.encode("container", forKey: .type)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "dedicatedUser":
            let username = try container.decode(String.self, forKey: .username)
            self = .dedicatedUser(username: username)
        case "container":
            self = .container
        default:
            self = .none
        }
    }

    /// Returns a human-readable description of the isolation mode.
    var displayName: String {
        switch self {
        case .none:
            return "None"
        case .dedicatedUser(let username):
            return "User (\(username))"
        case .container:
            return "Container"
        }
    }

    /// Returns an icon representing the isolation mode.
    var icon: String {
        switch self {
        case .none:
            return "🔓"
        case .dedicatedUser:
            return "👤"
        case .container:
            return "📦"
        }
    }
}

/// What runs a container-isolated runner's Linux container.
enum ContainerEngine: String, Codable, Sendable, CaseIterable {
    /// Apple's Containerization framework: a lightweight VM per runner, hosted
    /// by the Mac Runner process that started it (macOS 26+, Apple Silicon).
    case apple
    /// A Docker container (Docker Desktop, OrbStack, Colima, …), run by a
    /// background `docker run` that outlives the process that started it. The
    /// work directory is a Docker volume, and images can be local.
    case docker

    var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .docker: return "Docker"
        }
    }
}

struct AppSettings: Codable, Sendable, Equatable {
    var startOnLogin: Bool
    var pauseOnBattery: Bool
    /// Battery percentage below which runners pause when `pauseOnBattery` is on.
    var batteryPauseThreshold: Int
    var quietHours: QuietHours?
    var isolationMode: IsolationMode
    var tools: ToolProvisioningSettings
    var notificationsEnabled: Bool
    var autoCheckForUpdates: Bool
    var autoRestartEnabled: Bool
    var autoRestartMaxRetries: Int
    var automaticDiskCleanupEnabled: Bool
    var minimumFreeDiskSpaceGB: Int
    var openFileLimit: Int
    var resourceAlerts: ResourceAlertSettings

    static let `default` = AppSettings(
        startOnLogin: false,
        pauseOnBattery: false,
        batteryPauseThreshold: AppSettings.defaultBatteryPauseThreshold,
        quietHours: nil,
        isolationMode: .none,
        tools: .default,
        notificationsEnabled: true,
        autoCheckForUpdates: true,
        autoRestartEnabled: true,
        autoRestartMaxRetries: 5,
        automaticDiskCleanupEnabled: false,
        minimumFreeDiskSpaceGB: 100,
        openFileLimit: ResourceLimits.defaultOpenFileLimit,
        resourceAlerts: .default
    )

    static let defaultBatteryPauseThreshold = 20
    static let batteryPauseThresholdRange = 5...95

    static func normalizedBatteryPauseThreshold(_ value: Int) -> Int {
        min(max(value, batteryPauseThresholdRange.lowerBound), batteryPauseThresholdRange.upperBound)
    }

    init(
        startOnLogin: Bool = false,
        pauseOnBattery: Bool = false,
        batteryPauseThreshold: Int = AppSettings.defaultBatteryPauseThreshold,
        quietHours: QuietHours? = nil,
        isolationMode: IsolationMode = .none,
        tools: ToolProvisioningSettings = .default,
        notificationsEnabled: Bool = true,
        autoCheckForUpdates: Bool = true,
        autoRestartEnabled: Bool = true,
        autoRestartMaxRetries: Int = 5,
        automaticDiskCleanupEnabled: Bool = false,
        minimumFreeDiskSpaceGB: Int = 100,
        openFileLimit: Int = ResourceLimits.defaultOpenFileLimit,
        resourceAlerts: ResourceAlertSettings = .default
    ) {
        self.startOnLogin = startOnLogin
        self.pauseOnBattery = pauseOnBattery
        self.batteryPauseThreshold = Self.normalizedBatteryPauseThreshold(batteryPauseThreshold)
        self.quietHours = quietHours
        self.isolationMode = isolationMode
        self.tools = tools
        self.notificationsEnabled = notificationsEnabled
        self.autoCheckForUpdates = autoCheckForUpdates
        self.autoRestartEnabled = autoRestartEnabled
        self.autoRestartMaxRetries = max(1, autoRestartMaxRetries)
        self.automaticDiskCleanupEnabled = automaticDiskCleanupEnabled
        self.minimumFreeDiskSpaceGB = max(1, minimumFreeDiskSpaceGB)
        self.openFileLimit = ResourceLimits.normalizedOpenFileLimit(openFileLimit) ?? ResourceLimits.defaultOpenFileLimit
        self.resourceAlerts = resourceAlerts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startOnLogin = try container.decodeIfPresent(Bool.self, forKey: .startOnLogin) ?? false
        pauseOnBattery = try container.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? false
        batteryPauseThreshold = Self.normalizedBatteryPauseThreshold(
            try container.decodeIfPresent(Int.self, forKey: .batteryPauseThreshold) ?? Self.defaultBatteryPauseThreshold
        )
        quietHours = try container.decodeIfPresent(QuietHours.self, forKey: .quietHours)
        isolationMode = try container.decodeIfPresent(IsolationMode.self, forKey: .isolationMode) ?? .none
        tools = try container.decodeIfPresent(ToolProvisioningSettings.self, forKey: .tools) ?? .default
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        autoCheckForUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoCheckForUpdates) ?? true
        autoRestartEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoRestartEnabled) ?? true
        autoRestartMaxRetries = max(1, try container.decodeIfPresent(Int.self, forKey: .autoRestartMaxRetries) ?? 5)
        automaticDiskCleanupEnabled = try container.decodeIfPresent(Bool.self, forKey: .automaticDiskCleanupEnabled) ?? false
        minimumFreeDiskSpaceGB = max(1, try container.decodeIfPresent(Int.self, forKey: .minimumFreeDiskSpaceGB) ?? 100)
        openFileLimit = ResourceLimits.normalizedOpenFileLimit(
            try container.decodeIfPresent(Int.self, forKey: .openFileLimit)
        ) ?? ResourceLimits.defaultOpenFileLimit
        resourceAlerts = try container.decodeIfPresent(ResourceAlertSettings.self, forKey: .resourceAlerts) ?? .default
    }
}

struct ToolProvisioningSettings: Codable, Sendable, Equatable {
    var extraPackages: [String]

    static let `default` = ToolProvisioningSettings(extraPackages: [])

    init(extraPackages: [String] = []) {
        self.extraPackages = Self.normalize(extraPackages)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        extraPackages = Self.normalize(
            try container.decodeIfPresent([String].self, forKey: .extraPackages) ?? []
        )
    }

    private static func normalize(_ packages: [String]) -> [String] {
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789@+._-")

        return Array(
            Set(
                packages.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                }
                .filter {
                    !$0.isEmpty && $0.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
                }
            )
        )
        .sorted()
    }
}

/// A daily window during which runners are paused. Windows may wrap past
/// midnight (e.g. 22:00-06:00). `start == end` means the whole day.
struct QuietHours: Codable, Sendable, Equatable {
    var enabled: Bool
    var start: String  // HH:mm format
    var end: String    // HH:mm format

    /// Minutes after midnight for an "HH:mm" string, or nil if malformed.
    static func minutes(from time: String) -> Int? {
        let parts = time.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else {
            return nil
        }
        return hour * 60 + minute
    }

    /// Normalizes a user-entered time ("7:5", "07:05") to "HH:mm", or nil if invalid.
    static func normalizedTime(_ time: String) -> String? {
        guard let minutes = minutes(from: time) else { return nil }
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    var isValid: Bool {
        Self.minutes(from: start) != nil && Self.minutes(from: end) != nil
    }

    /// Whether `date` falls inside this window (ignores `enabled`).
    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard let startMinutes = Self.minutes(from: start), let endMinutes = Self.minutes(from: end) else {
            return false
        }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let now = (components.hour ?? 0) * 60 + (components.minute ?? 0)

        if startMinutes == endMinutes {
            return true
        }
        if startMinutes < endMinutes {
            return now >= startMinutes && now < endMinutes
        }
        return now >= startMinutes || now < endMinutes
    }

    /// Whether the window is enabled, well-formed, and covers `date`.
    func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        enabled && isValid && contains(date, calendar: calendar)
    }

    var displayRange: String {
        "\(start)–\(end)"
    }

    /// Same effect on pausing: disabled windows match regardless of their times.
    static func equivalent(_ lhs: QuietHours?, _ rhs: QuietHours?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs == rhs || (!lhs.enabled && !rhs.enabled)
        default: return false
        }
    }
}

/// Why Mac Runner paused a runner on its own.
enum AutoPauseReason: String, Codable, Sendable, Equatable {
    case lowBattery
    case quietHours

    var displayName: String {
        switch self {
        case .lowBattery: return "low battery"
        case .quietHours: return "quiet hours"
        }
    }
}

/// Battery state relevant to auto-pause. nil power state means no battery (desktop Mac).
struct PowerState: Sendable, Equatable {
    var isOnBattery: Bool
    /// Charge percentage 0-100.
    var batteryLevel: Int
}

enum AutoPausePolicy {
    /// Why `runner` should be paused right now, or nil if it may run.
    static func reason(
        for runner: Runner,
        settings: AppSettings,
        power: PowerState?,
        now: Date,
        calendar: Calendar = .current
    ) -> AutoPauseReason? {
        if isBatteryLow(settings: settings, power: power) {
            return .lowBattery
        }
        if runner.effectiveQuietHours(global: settings.quietHours)?.isActive(at: now, calendar: calendar) == true {
            return .quietHours
        }
        return nil
    }

    static func isBatteryLow(settings: AppSettings, power: PowerState?) -> Bool {
        guard settings.pauseOnBattery, let power, power.isOnBattery else { return false }
        return power.batteryLevel < settings.batteryPauseThreshold
    }
}
