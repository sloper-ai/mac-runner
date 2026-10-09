import Foundation

struct DiskCleanupReport: Equatable {
    let reclaimedBytes: Int64
    let removedPaths: [String]
    let skippedRunnerNames: [String]
    let dryRun: Bool
}

struct DiskCleanupService {
    private let fileManager: FileManager
    private let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    func availableDiskBytes() -> Int64? {
        // Use available blocks, excluding speculative purgeable capacity.
        // Query the filesystem directly: a long-lived URL can cache capacity
        // from before a job consumed space, even across admission checks.
        let attributes = try? fileManager.attributesOfFileSystem(forPath: homeDirectory.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    func cleanup(
        runners: [Runner],
        globalIsolationMode: IsolationMode,
        includeSharedCaches: Bool,
        dryRun: Bool
    ) throws -> DiskCleanupReport {
        var candidates: [URL] = []
        var skipped: [String] = []

        for runner in runners {
            guard runner.status != .running && !runner.busy && !PIDFileManager().isRunnerProcessAlive(runner.id) else {
                skipped.append(runner.name)
                continue
            }

            let isolation = runner.effectiveIsolationMode(global: globalIsolationMode)
            // Container runners are left alone. (On Docker, _work is a volume,
            // not part of the runner's directory; it's removed with the runner.)
            guard isolation != .container,
                  let runnerDirectory = try? RunnerDirectory.path(for: runner.id, isolation: isolation) else {
                continue
            }
            candidates.append(URL(fileURLWithPath: runnerDirectory).appendingPathComponent("_work", isDirectory: true))
        }

        // Shared caches can be in use by any job, so only touch them when every
        // configured runner is stopped and idle.
        if includeSharedCaches && skipped.isEmpty {
            candidates.append(contentsOf: sharedCICacheDirectories())
        }

        var reclaimedBytes: Int64 = 0
        var removedPaths: [String] = []
        for directory in candidates where DisposableCache.safeDirectory(directory, under: homeDirectory.resolvingSymlinksInPath()) {
            let children = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []

            for child in children {
                reclaimedBytes += allocatedSize(of: child)
                removedPaths.append(child.path)
                if !dryRun {
                    try fileManager.removeItem(at: child)
                }
            }
        }

        return DiskCleanupReport(
            reclaimedBytes: reclaimedBytes,
            removedPaths: removedPaths.sorted(),
            skippedRunnerNames: skipped.sorted(),
            dryRun: dryRun
        )
    }

    private func sharedCICacheDirectories() -> [URL] {
        DisposableCache.relativePaths.map { homeDirectory.appendingPathComponent($0, isDirectory: true) }
    }

    private func allocatedSize(of url: URL) -> Int64 {
        let type = (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        if type == .typeSymbolicLink { return 0 }
        if type == .typeRegular {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }

        var total: Int64 = 0
        while let item = enumerator.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
