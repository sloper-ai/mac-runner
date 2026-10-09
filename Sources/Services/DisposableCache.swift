import Foundation

/// Only download/build caches. Never enumerate a general .cache, Library/Caches,
/// .cargo, .gradle, or tool installation directory: browsers and SDKs live there too.
enum DisposableCache {
    static let relativePaths = [
        ".npm/_cacache", ".npm/_npx", ".npm/_logs",
        ".cache/pip", ".cache/uv", ".cache/go-build", ".cache/sccache",
        ".cargo/registry/cache", ".cargo/git/db", ".cargo/git/checkouts",
        ".gradle/caches", "Library/Caches/Homebrew", "Library/Caches/go-build",
        "Library/Caches/org.swift.swiftpm", "Library/Caches/pip", "Library/Caches/uv",
        "Library/Developer/Xcode/DerivedData"
    ]

    struct Report: Equatable, Sendable {
        var removed: [String] = []
        var reclaimedBytes: Int64 = 0
        var remainingBytes: Int64 = 0
    }

    /// Refuse a symlink in any component below the trusted home. Descendant
    /// symlinks are unlinked as entries; neither traversal nor sizing follows them.
    static func safeDirectory(_ url: URL, under home: URL) -> Bool {
        let base = home.resolvingSymlinksInPath().standardizedFileURL
        let target = url.standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else { return false }
        var current = base
        for part in target.path.dropFirst(base.path.count + 1).split(separator: "/") {
            current.appendPathComponent(String(part))
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory else { return false }
        }
        return true
    }

    static func maintain(home: URL, maxBytes: Int64, maxAgeDays: Int, now: Date = Date(), dryRun: Bool = false) throws -> Report {
        let home = home.resolvingSymlinksInPath()
        let roots = relativePaths.map { home.appendingPathComponent($0) }.filter { safeDirectory($0, under: home) }
        return try maintain(roots: roots, maxBytes: maxBytes, maxAgeDays: maxAgeDays, now: now, dryRun: dryRun)
    }

    /// Caller has excluded live users and holds the admission lock until launch.
    static func maintain(roots: [URL], maxBytes: Int64, maxAgeDays: Int, now: Date, dryRun: Bool) throws -> Report {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 86400)
        var report = Report()
        var retained: [(URL, Int64)] = []
        for root in roots {
            guard let items = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            var size: Int64 = 0
            var newestFile: Date?
            for case let item as URL in items {
                let attributes = try fm.attributesOfItem(atPath: item.path)
                let type = attributes[.type] as? FileAttributeType
                if type == .typeSymbolicLink { items.skipDescendants(); continue }
                guard type == .typeRegular else { continue }
                size += (attributes[.size] as? NSNumber)?.int64Value ?? 0
                let modified = attributes[.modificationDate] as? Date ?? now
                newestFile = max(newestFile ?? modified, modified)
            }
            // Evict a whole cache, never isolated files from its package indexes
            // or npx installations. Mtime describes writes, not cache hits.
            if newestFile.map({ $0 < cutoff }) ?? true {
                for child in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                    if !dryRun { try fm.removeItem(at: child) }
                    report.removed.append(child.path)
                }
                report.reclaimedBytes += size
            } else {
                retained.append((root, size))
            }
        }
        let remaining = retained.reduce(Int64(0)) { $0 + $1.1 }
        if remaining > maxBytes {
            for (root, _) in retained {
                for child in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                    if !dryRun { try fm.removeItem(at: child) }
                    report.removed.append(child.path)
                }
            }
            report.reclaimedBytes += remaining
        } else {
            report.remainingBytes = remaining
        }
        return report
    }

    /// Map a Docker cache mount to only the allowlisted paths inside that volume.
    /// The mount may be .cache itself or an individual allowed subtree.
    static func paths(inMount raw: String) -> [String] {
        let mount = DockerRunnerEngine.normalizedCachePath(raw)
        // Match a home-relative suffix with a path boundary, not arbitrary substrings.
        var result: [String] = []
        for path in relativePaths {
            let parts = path.split(separator: "/")
            for count in 1...parts.count {
                let prefix = "/" + parts.prefix(count).joined(separator: "/")
                if mount.hasSuffix(prefix) {
                    let suffix = parts.dropFirst(count).joined(separator: "/")
                    result.append(suffix.isEmpty ? "." : suffix)
                }
            }
        }
        return Array(Set(result)).sorted()
    }
}
