import Foundation

/// The Actions runner's action archive cache, shared by a Mac's runners.
///
/// Since 2.310, when `ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE` names a directory, the
/// runner's worker looks there for `<owner>_<repo>/<commit SHA>.tar.gz` (the
/// repository's tarball at the commit the action resolved to) before downloading
/// an action, and copies and extracts that instead. The runner only reads the
/// cache: it never adds to it, and it deletes each archive it downloads once it's
/// extracted. And it empties `_work/_actions` at the start of every job, so
/// without a cache every job downloads every action again.
///
/// So Mac Runner fills it. The worker logs each archive it looked for in
/// `_diag/Worker_*.log`; the menu bar app reads new lines there, fetches the
/// archives that are missing once per Mac, checks each is a whole tarball with a
/// single top-level directory (which the runner requires, and fails the job
/// without), and moves it into place in one rename, so a runner never sees part of
/// one. Archives come from `codeload.github.com` without credentials, so only
/// public repositories' are kept: a job can write its own `_diag`, and a forged
/// line must not be able to put a private repository where later jobs can read it.
///
/// Native runners read the directory itself; Docker runners get it read-only at
/// `containerMount`, so their jobs can't change what later jobs run. It's kept
/// under its budget, least recently used first, and archives no job has asked for
/// in `cacheMaxAgeDays` go.
enum ActionArchiveCache {
    /// The runner reads the cache's location from this.
    static let variable = "ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE"
    /// Where Docker runners see the cache, read-only.
    static let containerMount = "/mac-runner/action-archives"
    /// Where archives wait in the cache to be checked and renamed into place.
    static let incomingDirectoryName = ".incoming"
    /// Larger downloads aren't kept.
    static let maxArchiveBytes: Int64 = 512_000_000
    /// How many missing archives one refresh fetches.
    static let maxFetchesPerRefresh = 16

    /// The Mac's cache: `~/.mac-runner/action-archives`.
    static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".mac-runner", isDirectory: true)
            .appendingPathComponent("action-archives", isDirectory: true)
    }

    /// The cache, created if needed, readable by everyone (a dedicated user's
    /// runner and containers read it) and writable only by this user. A symlink
    /// in its path is refused.
    static func prepareDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let home = home.resolvingSymlinksInPath()
        let url = directory(home: home)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        guard DisposableCache.safeDirectory(url, under: home) else {
            throw StorageMaintenanceError(message: "The action cache \(url.path) must be a directory, not a symlink or under one.")
        }
        return url
    }

    // MARK: - Keys

    /// One action archive: a repository at a commit, as the runner resolved it.
    struct Key: Hashable, Sendable, CustomStringConvertible {
        let owner: String
        let repo: String
        let sha: String

        /// nil unless `nameWithOwner` is `owner/repo` with GitHub's characters
        /// and `sha` is a full lowercase commit SHA, so a key never names a path
        /// outside its own directory.
        init?(nameWithOwner: String, sha: String) {
            let parts = nameWithOwner.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let owner = String(parts[0]), repo = String(parts[1])
            let ownerCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
            let repoCharacters = ownerCharacters.union(["."])
            guard !owner.isEmpty, owner.allSatisfy(ownerCharacters.contains),
                  !repo.isEmpty, repo != ".", repo != "..", repo.allSatisfy(repoCharacters.contains),
                  Self.isCommitSHA(sha) else { return nil }
            self.owner = owner
            self.repo = repo
            self.sha = sha
        }

        /// The runner's directory for the repository: its name with `/` as `_`.
        var directoryName: String { "\(owner)_\(repo)" }
        var fileName: String { "\(sha).tar.gz" }
        var relativePath: String { "\(directoryName)/\(fileName)" }

        /// The repository's tarball at the commit, as the runner downloads it.
        var downloadURL: URL {
            URL(string: "https://codeload.github.com/\(owner)/\(repo)/tar.gz/\(sha)")!
        }

        var description: String { "\(owner)/\(repo)@\(sha.prefix(12))" }

        /// A full commit SHA, in lowercase hex as the runner writes it.
        static func isCommitSHA(_ text: some StringProtocol) -> Bool {
            text.count == 40 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        }
    }

    // MARK: - Worker logs

    /// What new lines of a worker log say about the cache.
    struct LogFindings: Equatable {
        /// Archives the runner looked for, in order, each once.
        var looked: [Key] = []
        /// Archives the runner took from the cache and then couldn't extract.
        var unusable: Set<Key> = []

        mutating func merge(_ other: LogFindings) {
            for key in other.looked where !looked.contains(key) { looked.append(key) }
            unusable.formUnion(other.unusable)
        }
    }

    // The runner's own trace lines (ActionManager.DownloadRepositoryActionAsync).
    static let lookMarker = "Check if action archive '"
    static let hitMarker = "Found action archive '"
    static let extractFailureMarker = "Can't use 'tar -xzf' extract archive file"

    /// The archives the runner looked for in `lines`, and those it took from the
    /// cache but couldn't extract. Actions are downloaded one at a time, so an
    /// extraction failure belongs to the archive looked for last.
    static func findings(in lines: [Substring]) -> LogFindings {
        var findings = LogFindings()
        var current: Key?
        var currentFromCache = false
        for line in lines {
            if let range = line.range(of: lookMarker) {
                let rest = line[range.upperBound...]
                guard let end = rest.firstIndex(of: "'"), let at = rest[..<end].lastIndex(of: "@"),
                      let key = Key(nameWithOwner: String(rest[..<at]), sha: String(rest[rest.index(after: at)..<end])) else {
                    current = nil
                    continue
                }
                current = key
                currentFromCache = false
                if !findings.looked.contains(key) { findings.looked.append(key) }
            } else if line.contains(hitMarker) {
                currentFromCache = current != nil
            } else if line.contains(extractFailureMarker), currentFromCache, let key = current {
                findings.unusable.insert(key)
                currentFromCache = false
            }
        }
        return findings
    }

    // MARK: - Archives

    /// Why `file` can't go in the cache, or nil when it can: it must be a whole
    /// gzipped tarball (listing reads all of it) with exactly one top-level
    /// directory, as the runner requires of the archives it extracts.
    static func archiveProblem(_ file: URL) -> String? {
        guard let listing = try? ProcessExecutor.run("/usr/bin/tar", arguments: ["-tzf", file.path], timeout: 300) else {
            return "tar couldn't list it"
        }
        guard listing.succeeded else { return "it isn't a whole .tar.gz archive" }
        var directories = Set<Substring>()
        for line in listing.output.split(separator: "\n") where !line.hasPrefix("tar: ") {
            // Top-level files (a pax header, say) are ignored, as the runner ignores them.
            let parts = line.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { directories.insert(parts[0]) }
        }
        guard directories.count == 1 else {
            return "it has \(directories.count) top-level directories, and the runner needs exactly one"
        }
        return nil
    }

    /// Check `downloaded` and move it into the cache as `key`, replacing any
    /// archive there in one rename. `downloaded` is moved or deleted either way.
    static func install(_ downloaded: URL, as key: Key, in directory: URL) throws {
        let fileManager = FileManager.default
        let incoming = directory.appendingPathComponent(incomingDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: incoming, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let staged = incoming.appendingPathComponent(UUID().uuidString + ".tar.gz")
        do {
            try fileManager.moveItem(at: downloaded, to: staged)
        } catch {
            try? fileManager.removeItem(at: downloaded)
            throw error
        }
        // Gone already once it's renamed into place.
        defer { try? fileManager.removeItem(at: staged) }

        if let problem = archiveProblem(staged) {
            throw StorageMaintenanceError(message: "\(key) wasn't kept: \(problem).")
        }
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: staged.path)
        let parent = directory.appendingPathComponent(key.directoryName, isDirectory: true)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let destination = parent.appendingPathComponent(key.fileName)
        guard rename(staged.path, destination.path) == 0 else {
            throw StorageMaintenanceError(message: "\(key) wasn't kept: \(String(cString: strerror(errno))).")
        }
    }

    /// Mark `key`'s archive as used now: pruning goes by modification time.
    /// Returns whether it's in the cache.
    @discardableResult
    static func markUsed(_ key: Key, in directory: URL, now: Date = Date()) -> Bool {
        let path = directory.appendingPathComponent(key.relativePath).path
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: path)
        return true
    }

    /// How many archives the cache holds, and their size on disk.
    static func contents(of directory: URL) -> (archives: Int, bytes: Int64) {
        var archives = 0
        var bytes: Int64 = 0
        let fileManager = FileManager.default
        for repository in (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where repository.lastPathComponent != incomingDirectoryName {
            for file in (try? fileManager.contentsOfDirectory(at: repository, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent.hasSuffix(".tar.gz") {
                var info = stat()
                guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
                archives += 1
                bytes += Int64(info.st_blocks) * 512
            }
        }
        return (archives, bytes)
    }

    // MARK: - Pruning

    struct PruneReport: Equatable {
        var removed: [String] = []
        var removedBytes: Int64 = 0
        var keptBytes: Int64 = 0
    }

    /// Delete archives not used in `maxAgeDays`, then the least recently used
    /// until the rest fit in `maxBytes`, along with emptied directories and
    /// staged downloads over an hour old. Only `<owner>_<repo>/<SHA>.tar.gz`
    /// files are counted or deleted; symlinks are never followed. A runner
    /// copying an archive as it goes downloads the action instead.
    static func prune(directory: URL, maxBytes: Int64, maxAgeDays: Int, now: Date = Date()) throws -> PruneReport {
        let fileManager = FileManager.default
        var report = PruneReport()
        let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 86400)
        var archives: [(url: URL, modified: Date, bytes: Int64)] = []
        var repositories: [URL] = []

        func entry(_ url: URL) -> (isDirectory: Bool, isFile: Bool, modified: Date, bytes: Int64)? {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            let type = info.st_mode & S_IFMT
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            return (type == S_IFDIR, type == S_IFREG, modified, Int64(info.st_blocks) * 512)
        }

        for child in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard let attributes = entry(child), attributes.isDirectory else { continue }
            if child.lastPathComponent == incomingDirectoryName {
                for staged in (try? fileManager.contentsOfDirectory(at: child, includingPropertiesForKeys: nil)) ?? [] {
                    if let staged = entry(staged).map({ (staged, $0) }), staged.1.isFile,
                       now.timeIntervalSince(staged.1.modified) > 3600 {
                        try? fileManager.removeItem(at: staged.0)
                    }
                }
                continue
            }
            repositories.append(child)
            for file in try fileManager.contentsOfDirectory(at: child, includingPropertiesForKeys: nil) {
                let name = file.lastPathComponent
                guard name.hasSuffix(".tar.gz"), Key.isCommitSHA(name.dropLast(".tar.gz".count)),
                      let attributes = entry(file), attributes.isFile else { continue }
                archives.append((file, attributes.modified, attributes.bytes))
            }
        }

        var kept: Int64 = 0
        var full = false
        for archive in archives.sorted(by: { $0.modified > $1.modified }) {
            full = full || archive.modified < cutoff || kept + archive.bytes > maxBytes
            if !full {
                kept += archive.bytes
                continue
            }
            try fileManager.removeItem(at: archive.url)
            report.removed.append(archive.url.path)
            report.removedBytes += archive.bytes
        }
        report.keptBytes = kept
        for repository in repositories where ((try? fileManager.contentsOfDirectory(atPath: repository.path)) ?? ["?"]).isEmpty {
            try? fileManager.removeItem(at: repository)
        }
        return report
    }
}

/// Fills the action archive cache from runners' worker logs, and keeps it
/// within its budget. The menu bar app runs one, every 30 seconds.
actor ActionArchiveCacheFiller {
    /// Fetch a URL to a temporary file, returning it and the HTTP status. The
    /// caller moves or deletes the file.
    typealias Fetch = @Sendable (URL) async throws -> (file: URL, status: Int)

    private let home: URL
    private let fetch: Fetch
    /// Bytes of each worker log already read.
    private var offsets: [String: UInt64] = [:]
    /// Archives that couldn't be fetched, and when to try again (once a job asks for them again).
    private var failures: [ActionArchiveCache.Key: (count: Int, retryAt: Date)] = [:]

    /// Worker logs last written longer ago than this when first seen are skipped:
    /// their archives were dealt with before the app restarted, or never will be needed.
    static let firstScanWindow: TimeInterval = 86400
    /// At most this much of a log is read at a time.
    static let maxReadBytes = 32 * 1024 * 1024

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, fetch: @escaping Fetch = ActionArchiveCacheFiller.download) {
        self.home = home
        self.fetch = fetch
    }

    /// Read new worker log lines in `diagnosticsDirectories` (the `_diag` of each
    /// runner that uses the cache), fetch the archives they looked for and didn't
    /// find, drop those a runner couldn't extract, and prune. Returns what
    /// happened, for the app's log.
    func refresh(diagnosticsDirectories: [URL], maxBytes: Int64, maxAgeDays: Int, now: Date = Date()) async -> [String] {
        let cacheDirectory = ActionArchiveCache.directory(home: home)
        guard !diagnosticsDirectories.isEmpty || FileManager.default.fileExists(atPath: cacheDirectory.path) else { return [] }
        let directory: URL
        do {
            directory = try ActionArchiveCache.prepareDirectory(home: home)
        } catch {
            return [error.localizedDescription]
        }

        var findings = ActionArchiveCache.LogFindings()
        for diagnostics in diagnosticsDirectories {
            findings.merge(readNewLines(in: diagnostics, now: now))
        }

        var messages: [String] = []
        for key in findings.unusable {
            let path = directory.appendingPathComponent(key.relativePath)
            if (try? FileManager.default.removeItem(at: path)) != nil {
                messages.append("Dropped \(key): a runner couldn't extract it, so jobs will download it until it's fetched again.")
            }
        }

        var missing: [ActionArchiveCache.Key] = []
        for key in findings.looked where !findings.unusable.contains(key) {
            if ActionArchiveCache.markUsed(key, in: directory, now: now) {
                failures.removeValue(forKey: key)
            } else if failures[key].map({ $0.retryAt <= now }) ?? true {
                missing.append(key)
            }
        }
        for key in missing.prefix(ActionArchiveCache.maxFetchesPerRefresh) {
            messages.append(await save(key, in: directory, now: now))
        }

        do {
            let report = try ActionArchiveCache.prune(directory: directory, maxBytes: maxBytes, maxAgeDays: maxAgeDays, now: now)
            if !report.removed.isEmpty {
                messages.append("Removed \(report.removed.count) archive(s), \(report.removedBytes) bytes, unused for \(maxAgeDays) days or over the \(maxBytes) byte budget; \(report.keptBytes) bytes kept.")
            }
        } catch {
            messages.append("Couldn't prune \(directory.path): \(error.localizedDescription)")
        }
        return messages
    }

    /// Fetch `key` into the cache. On failure, a job asking for it again retries
    /// after a wait: a minute, doubling to an hour; a day when GitHub has no such
    /// public repository.
    private func save(_ key: ActionArchiveCache.Key, in directory: URL, now: Date) async -> String {
        func failed(_ reason: String, retryIn delay: TimeInterval? = nil) -> String {
            let count = (failures[key]?.count ?? 0) + 1
            let wait = delay ?? min(60 * pow(2, Double(min(count - 1, 6))), 3600)
            failures[key] = (count, now.addingTimeInterval(wait))
            return "Couldn't save \(key): \(reason). Jobs download it meanwhile; trying again in \(Int(wait / 60)) min or more."
        }
        let file: URL, status: Int
        do {
            (file, status) = try await fetch(key.downloadURL)
        } catch {
            return failed(error.localizedDescription)
        }
        guard status == 200 else {
            try? FileManager.default.removeItem(at: file)
            // Private repositories answer 404 without credentials, which a cache must not use.
            return status == 404 || status == 403 || status == 451
                ? failed("GitHub answered \(status) (not a public repository?)", retryIn: 86400)
                : failed("GitHub answered \(status)")
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= ActionArchiveCache.maxArchiveBytes else {
            try? FileManager.default.removeItem(at: file)
            return failed("it's \(size) bytes, over the \(ActionArchiveCache.maxArchiveBytes) byte limit", retryIn: 86400)
        }
        do {
            try ActionArchiveCache.install(file, as: key, in: directory)
        } catch {
            return failed(error.localizedDescription)
        }
        failures.removeValue(forKey: key)
        return "Saved \(key) (\(size) bytes) for later jobs."
    }

    /// Complete lines added to `diagnostics`' worker logs since the last read,
    /// as findings. Logs that have gone are forgotten.
    private func readNewLines(in diagnostics: URL, now: Date) -> ActionArchiveCache.LogFindings {
        var findings = ActionArchiveCache.LogFindings()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: diagnostics.path)) ?? [])
            .filter { $0.hasPrefix("Worker_") && $0.hasSuffix(".log") }
            .sorted()
        let prefix = diagnostics.path + "/"
        let present = Set(names.map { prefix + $0 })
        for path in offsets.keys where path.hasPrefix(prefix) && !present.contains(path) {
            offsets.removeValue(forKey: path)
        }
        for name in names {
            let path = prefix + name
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let size = UInt64(info.st_size)
            var offset = offsets[path] ?? {
                let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                return now.timeIntervalSince(modified) > Self.firstScanWindow ? size : 0
            }()
            if size < offset { offset = 0 }  // rewritten
            guard size > offset, let handle = FileHandle(forReadingAtPath: path) else {
                offsets[path] = offset
                continue
            }
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            let data = (try? handle.read(upToCount: Self.maxReadBytes)) ?? Data()
            // Only complete lines; the rest is read once it's finished.
            guard let lastNewline = data.lastIndex(of: 0x0A) else {
                // A line longer than a whole read isn't one the runner writes about the cache.
                offsets[path] = data.count >= Self.maxReadBytes ? offset + UInt64(data.count) : offset
                continue
            }
            let complete = data[data.startIndex...lastNewline]
            offsets[path] = offset + UInt64(complete.count)
            let lines = String(decoding: complete, as: UTF8.self).split(separator: "\n")
            findings.merge(ActionArchiveCache.findings(in: lines))
        }
        return findings
    }

    /// GET `url` without credentials or cookies.
    static func download(_ url: URL) async throws -> (file: URL, status: Int) {
        let (file, response) = try await session.download(from: url)
        return (file, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.httpAdditionalHeaders = ["User-Agent": "mac-runner"]
        return URLSession(configuration: configuration)
    }()
}
