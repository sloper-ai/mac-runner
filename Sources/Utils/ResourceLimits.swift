import Foundation

enum ResourceLimits {
    static let defaultOpenFileLimit = 65_536

    /// What a container runner's container gets unless the runner sets its
    /// own (`--cpus`, `--memory`), on either engine.
    static let defaultContainerCPUs = 2
    static let defaultContainerMemoryMB = 4096
    static let minimumContainerMemoryMB = 1024

    static func normalizedOpenFileLimit(_ limit: Int?) -> Int? {
        guard let limit, limit > 0 else { return nil }
        return limit
    }

    static func shellPrefix(openFileLimit: Int?) -> String {
        guard let limit = normalizedOpenFileLimit(openFileLimit) else {
            return ""
        }

        return "ulimit -n \(limit) 2>/dev/null || ulimit -n \"$(ulimit -Hn)\" 2>/dev/null || true && "
    }

    static func shellCommand(_ command: String, openFileLimit: Int?) -> String {
        shellPrefix(openFileLimit: openFileLimit) + command
    }

    // MARK: - Container CPUs and Memory

    /// Megabytes in a memory size: "8g" (or "8gb"), "8192m" (or "8192mb"), or
    /// a plain number of megabytes. nil if it isn't one.
    static func containerMemoryMB(from text: String) -> Int? {
        var number = text.trimmingCharacters(in: .whitespaces).lowercased()
        var scale = 1
        for (suffix, megabytes) in [("gb", 1024), ("g", 1024), ("mb", 1), ("m", 1)] where number.hasSuffix(suffix) {
            number.removeLast(suffix.count)
            scale = megabytes
            break
        }
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(number) else {
            return nil
        }
        let (megabytes, overflow) = value.multipliedReportingOverflow(by: scale)
        return overflow ? nil : megabytes
    }

    /// Why a container can't have `cpus` CPUs, or nil if it can: from 1 to
    /// the Mac's core count.
    static func containerCPUsProblem(_ cpus: Int, hostCores: Int = ProcessInfo.processInfo.processorCount) -> String? {
        (1...max(1, hostCores)).contains(cpus) ? nil : "must be between 1 and \(max(1, hostCores)) (this Mac's cores)"
    }

    /// Why a container can't have `megabytes` of memory, or nil if it can.
    static func containerMemoryProblem(_ megabytes: Int) -> String? {
        megabytes >= minimumContainerMemoryMB ? nil : "must be at least 1g (1024 MB)"
    }

    /// A memory size as `--memory` and config files take it: "8g", or "1536m".
    static func containerMemoryText(megabytes: Int) -> String {
        megabytes % 1024 == 0 ? "\(megabytes / 1024)g" : "\(megabytes)m"
    }

    /// A memory size for people: "8 GB", or "1536 MB".
    static func memoryDescription(megabytes: Int) -> String {
        megabytes % 1024 == 0 ? "\(megabytes / 1024) GB" : "\(megabytes) MB"
    }
}
