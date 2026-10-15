import XCTest
@testable import MacRunner

/// The action archive cache: keys, the worker log lines it's filled from,
/// archive checks, pruning, the filler, how runners get it, and its option.
final class ActionArchiveCacheTests: XCTestCase, @unchecked Sendable {
    private let sha1 = String(repeating: "a", count: 40)
    private let sha2 = String(repeating: "b", count: 40)
    private let sha3 = String(repeating: "c", count: 40)

    private func scratch(_ name: String = "cache") throws -> URL {
        // No spaces: the container script's runner candidates are a word list.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("action-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func key(_ name: String, _ sha: String) -> ActionArchiveCache.Key {
        ActionArchiveCache.Key(nameWithOwner: name, sha: sha)!
    }

    /// A gzipped tarball with these top-level directories (each holding an
    /// action.yml) and top-level files, as `tar -czf` writes it.
    @discardableResult
    private func tarball(at url: URL, directories: [String] = ["actions-checkout-aaaaaaa"], files: [String] = []) throws -> URL {
        let source = try scratch("source")
        defer { try? FileManager.default.removeItem(at: source) }
        for directory in directories {
            let folder = source.appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("dist"), withIntermediateDirectories: true)
            try "name: test\nruns:\n  using: node24\n  main: dist/index.js\n".write(to: folder.appendingPathComponent("action.yml"), atomically: true, encoding: .utf8)
            try "console.log('hi')\n".write(to: folder.appendingPathComponent("dist/index.js"), atomically: true, encoding: .utf8)
        }
        for file in files {
            try "x".write(to: source.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = try ProcessExecutor.run("/usr/bin/tar", arguments: ["-czf", url.path, "-C", source.path] + directories + files)
        XCTAssertTrue(result.succeeded, result.output)
        return url
    }

    /// The worker's trace line for an archive it looks for in the cache.
    private func look(_ name: String, _ sha: String) -> String {
        "[2026-10-15 09:00:01Z INFO ActionManager] Check if action archive '\(name)@\(sha)' already exists in cache directory '/mac-runner/action-archives'"
    }

    private func hit(_ name: String, _ sha: String) -> String {
        "[2026-10-15 09:00:01Z INFO ActionManager] Found action archive '/mac-runner/action-archives/\(name.replacingOccurrences(of: "/", with: "_"))/\(sha).tar.gz' in cache directory '/mac-runner/action-archives'"
    }

    private func append(_ lines: [String], to log: URL, newline: Bool = true) throws {
        if !FileManager.default.fileExists(atPath: log.path) {
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + (newline ? "\n" : "")).utf8))
    }

    private func modified(_ url: URL) throws -> Date {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    private func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func allocated(_ url: URL) -> Int64 {
        var info = stat()
        return lstat(url.path, &info) == 0 ? Int64(info.st_blocks) * 512 : 0
    }

    /// A fetch that serves tarballs from a table of codeload paths, recording requests.
    final class FakeGitHub: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [String] = []
        private var responses: [String: [Int]] = [:]
        let files: URL

        init(files: URL) { self.files = files }

        var requests: [String] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }

        /// Answer `path` with these statuses in turn (200 serves a tarball; the last repeats).
        func answer(_ path: String, _ statuses: [Int]) {
            lock.lock(); defer { lock.unlock() }
            responses[path] = statuses
        }

        func fetch(_ url: URL) throws -> (file: URL, status: Int) {
            lock.lock()
            _requests.append(url.path)
            var statuses = responses[url.path] ?? [200]
            let status = statuses.first ?? 200
            if statuses.count > 1 { statuses.removeFirst() }
            responses[url.path] = statuses
            lock.unlock()
            let file = files.appendingPathComponent(UUID().uuidString)
            if status == 200 {
                return (try Self.makeTarball(at: file.appendingPathExtension("tar.gz")), status)
            }
            try Data("Not Found".utf8).write(to: file)
            return (file, status)
        }

        static func makeTarball(at url: URL) throws -> URL {
            let source = url.deletingPathExtension().deletingPathExtension().appendingPathExtension("src")
            let folder = source.appendingPathComponent("owner-repo-1234567", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "name: fake\n".write(to: folder.appendingPathComponent("action.yml"), atomically: true, encoding: .utf8)
            _ = try ProcessExecutor.run("/usr/bin/tar", arguments: ["-czf", url.path, "-C", source.path, "owner-repo-1234567"])
            try? FileManager.default.removeItem(at: source)
            return url
        }
    }

    private func filler(home: URL) throws -> (ActionArchiveCacheFiller, FakeGitHub) {
        let files = home.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let github = FakeGitHub(files: files)
        return (ActionArchiveCacheFiller(home: home, fetch: { url in try github.fetch(url) }), github)
    }

    // MARK: - Keys

    func testKeysAreTheRunnersPathsAndNeverLeaveTheCache() throws {
        let checkout = key("actions/checkout", sha1)
        XCTAssertEqual(checkout.relativePath, "actions_checkout/\(sha1).tar.gz", "the runner's layout: <owner>_<repo>/<sha>.tar.gz")
        XCTAssertEqual(checkout.downloadURL.absoluteString, "https://codeload.github.com/actions/checkout/tar.gz/\(sha1)")
        XCTAssertEqual(checkout.description, "actions/checkout@aaaaaaaaaaaa")
        XCTAssertNotNil(ActionArchiveCache.Key(nameWithOwner: "my-org/.github", sha: sha1), "a repository can start with a dot")
        XCTAssertNotNil(ActionArchiveCache.Key(nameWithOwner: "emu_user/repo.name", sha: sha1))

        for (name, sha) in [
            ("actions", sha1), ("a/b/c", sha1), ("../etc", sha1), ("a/..", sha1), ("a/.", sha1), ("/repo", sha1), ("owner/", sha1),
            ("a b/c", sha1), ("a/c", "abc123"), ("a/c", sha1.uppercased()), ("a/c", String(repeating: "g", count: 40)),
            ("a/c", sha1 + "0"), ("o.wner/repo", sha1),
        ] {
            XCTAssertNil(ActionArchiveCache.Key(nameWithOwner: name, sha: sha), "\(name)@\(sha)")
        }
    }

    // MARK: - Worker logs

    func testFindingsAreTheArchivesTheRunnerLookedForAndTheOnesItCouldntExtract() {
        let lines: [String] = [
            "[2026-10-15 09:00:00Z INFO ActionManager] Getting action download info",
            look("actions/checkout", sha1),
            "[2026-10-15 09:00:01Z INFO ActionManager] Save archive 'https://codeload.github.com/actions/checkout/tar.gz/\(sha1)' into /x.",
            look("dtolnay/rust-toolchain", sha2),
            hit("dtolnay/rust-toolchain", sha2),
            "[2026-10-15 09:00:02Z ERR  ActionManager] Caught exception from PrepareActionsAsync Initialization: Can't use 'tar -xzf' extract archive file: /x/y.tar.gz (SHA256 'z')",
            look("actions/checkout", sha1),
            look("pnpm/action-setup", sha3),
            "[2026-10-15 09:00:03Z ERR  ActionManager] Can't use 'tar -xzf' extract archive file: /x/z.tar.gz",
            "Check if action archive 'not a key' already exists in cache directory '/x'",
            "Check if action archive '../../etc@\(sha1)' already exists in cache directory '/x'",
            "[mac-runner] something else entirely",
        ]
        let findings = ActionArchiveCache.findings(in: lines.map { Substring($0) })
        XCTAssertEqual(findings.looked, [key("actions/checkout", sha1), key("dtolnay/rust-toolchain", sha2), key("pnpm/action-setup", sha3)],
                       "each once, in order; lines that aren't keys are skipped")
        XCTAssertEqual(findings.unusable, [key("dtolnay/rust-toolchain", sha2)],
                       "only an archive taken from the cache is blamed for an extraction failure, not a download")
    }

    // MARK: - Archives

    func testOnlyAWholeTarballWithOneTopLevelDirectoryIsKept() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let good = try tarball(at: root.appendingPathComponent("good.tar.gz"))
        XCTAssertNil(ActionArchiveCache.archiveProblem(good))
        let withHeaderFile = try tarball(at: root.appendingPathComponent("header.tar.gz"), files: ["pax_global_header"])
        XCTAssertNil(ActionArchiveCache.archiveProblem(withHeaderFile), "top-level files are ignored, as the runner ignores them")

        let two = try tarball(at: root.appendingPathComponent("two.tar.gz"), directories: ["a", "b"])
        XCTAssertEqual(ActionArchiveCache.archiveProblem(two), "it has 2 top-level directories, and the runner needs exactly one")
        let none = try tarball(at: root.appendingPathComponent("none.tar.gz"), directories: [], files: ["README"])
        XCTAssertNotNil(ActionArchiveCache.archiveProblem(none))

        let html = root.appendingPathComponent("html.tar.gz")
        try Data("<html>rate limited</html>".utf8).write(to: html)
        XCTAssertEqual(ActionArchiveCache.archiveProblem(html), "it isn't a whole .tar.gz archive")

        let data = try Data(contentsOf: good)
        let truncated = root.appendingPathComponent("truncated.tar.gz")
        try data.prefix(data.count / 2).write(to: truncated)
        XCTAssertEqual(ActionArchiveCache.archiveProblem(truncated), "it isn't a whole .tar.gz archive")
    }

    func testAGitArchiveLikeCodeloadsPasses() throws {
        // codeload serves `git archive` output: a pax global header, then one directory.
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try "name: x\n".write(to: repository.appendingPathComponent("action.yml"), atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("archive.tar.gz")
        let script = """
        set -e
        cd "$1"
        git init -q . && git add action.yml
        git -c user.name=t -c user.email=t@example.com commit -qm init
        git archive --format=tar.gz --prefix=actions-checkout-1234567/ -o "$2" HEAD
        """
        let result = try ProcessExecutor.run("/bin/bash", arguments: ["-c", script, "bash", repository.path, archive.path])
        guard result.succeeded else { throw XCTSkip("git isn't usable here: \(result.output)") }
        XCTAssertNil(ActionArchiveCache.archiveProblem(archive))
    }

    func testInstallRenamesACheckedArchiveIntoPlaceReadableByEveryone() throws {
        let home = try scratch("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = try ActionArchiveCache.prepareDirectory(home: home)
        XCTAssertEqual(directory, home.appendingPathComponent(".mac-runner/action-archives", isDirectory: true))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)

        let download = try tarball(at: home.appendingPathComponent("download.tar.gz"))
        try ActionArchiveCache.install(download, as: key("actions/checkout", sha1), in: directory)
        let installed = directory.appendingPathComponent("actions_checkout/\(sha1).tar.gz")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.path))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: installed.path)[.posixPermissions] as? NSNumber)?.intValue, 0o644)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(".incoming").path), [])
        XCTAssertTrue(ActionArchiveCache.markUsed(key("actions/checkout", sha1), in: directory))
        XCTAssertFalse(ActionArchiveCache.markUsed(key("actions/checkout", sha2), in: directory))
        XCTAssertEqual(ActionArchiveCache.contents(of: directory).archives, 1)

        let bad = home.appendingPathComponent("bad.tar.gz")
        try Data("nope".utf8).write(to: bad)
        XCTAssertThrowsError(try ActionArchiveCache.install(bad, as: key("actions/setup-node", sha1), in: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("actions_setup-node/\(sha1).tar.gz").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path), "a rejected download is deleted")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(".incoming").path), [])
    }

    func testTheCacheIsRefusedThroughASymlink() throws {
        let home = try scratch("home")
        let elsewhere = try scratch("elsewhere")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".mac-runner"), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try ActionArchiveCache.prepareDirectory(home: home))
    }

    // MARK: - Pruning

    func testPruningDropsOldArchivesThenTheLeastRecentlyUsedOverBudget() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        func archive(_ repository: String, _ sha: String, age: TimeInterval, bytes: Int = 20_000) throws -> URL {
            let url = directory.appendingPathComponent("\(repository)/\(sha).tar.gz")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: url)
            try setModified(url, now.addingTimeInterval(-age))
            return url
        }
        let newest = try archive("actions_checkout", sha1, age: 60)
        let middle = try archive("actions_setup-node", sha2, age: 2 * 86400)
        let small = try archive("actions_setup-node", sha3, age: 3 * 86400, bytes: 100)
        let expired = try archive("old_action", sha1, age: 8 * 86400)
        let unknown = directory.appendingPathComponent("actions_checkout/notes.txt")
        try Data("keep".utf8).write(to: unknown)
        let notASHA = try archive("actions_checkout", "abc", age: 30 * 86400)

        // TMPDIR is under /var, a symlink to /private/var: compare paths within the cache.
        var report = try ActionArchiveCache.prune(directory: directory, maxBytes: 10_000_000, maxAgeDays: 7, now: now)
        XCTAssertEqual(report.removed.map { URL(fileURLWithPath: $0).lastPathComponent }, [expired.lastPathComponent])
        XCTAssertTrue(report.removed[0].hasSuffix("/old_action/\(sha1).tar.gz"), "\(report.removed)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.deletingLastPathComponent().path), "emptied directories go")
        for url in [newest, middle, small, unknown, notASHA] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }

        // Room for the newest only: everything older goes, even what would fit.
        report = try ActionArchiveCache.prune(directory: directory, maxBytes: allocated(newest) + allocated(middle) - 1, maxAgeDays: 7, now: now)
        XCTAssertEqual(Set(report.removed.map { $0.split(separator: "/").suffix(2).joined(separator: "/") }),
                       ["actions_setup-node/\(sha2).tar.gz", "actions_setup-node/\(sha3).tar.gz"])
        XCTAssertEqual(report.keptBytes, allocated(newest))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path), "only archives are counted or deleted")
    }

    func testPruningClearsStaleDownloadsAndNeverFollowsSymlinks() throws {
        let directory = try scratch()
        let outside = try scratch("outside")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let now = Date()
        let incoming = directory.appendingPathComponent(".incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let stale = incoming.appendingPathComponent("stale.tar.gz")
        let current = incoming.appendingPathComponent("current.tar.gz")
        try Data("x".utf8).write(to: stale)
        try Data("x".utf8).write(to: current)
        try setModified(stale, now.addingTimeInterval(-7200))

        let valuable = outside.appendingPathComponent("\(sha1).tar.gz")
        try Data(repeating: 1, count: 10_000).write(to: valuable)
        try setModified(valuable, now.addingTimeInterval(-30 * 86400))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("evil_repo"), withDestinationURL: outside)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("o_r"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("o_r/\(sha2).tar.gz"), withDestinationURL: valuable)

        let report = try ActionArchiveCache.prune(directory: directory, maxBytes: 0, maxAgeDays: 1, now: now)
        XCTAssertEqual(report.removed, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path), "a download being checked stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: valuable.path))
    }

    // MARK: - Filler

    func testTheFillerSavesWhatJobsLookedForOnceAndMarksWhatTheyUsed() async throws {
        let home = try scratch("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let (filler, github) = try filler(home: home)
        let diagnostics = home.appendingPathComponent(".mac-runner/runners/r1/_diag", isDirectory: true)
        let log = diagnostics.appendingPathComponent("Worker_20261015-090000-utc.log")
        try append([look("actions/checkout", sha1), "[x] Save archive 'https://codeload…' into /tmp/x.", look("dtolnay/rust-toolchain", sha2)], to: log)
        let now = Date()

        var messages = await filler.refresh(diagnosticsDirectories: [diagnostics], maxBytes: 1_000_000_000, maxAgeDays: 7, now: now)
        XCTAssertEqual(github.requests, ["/actions/checkout/tar.gz/\(sha1)", "/dtolnay/rust-toolchain/tar.gz/\(sha2)"])
        XCTAssertEqual(messages.filter { $0.hasPrefix("Saved ") }.count, 2, "\(messages)")
        let directory = ActionArchiveCache.directory(home: home)
        let checkout = directory.appendingPathComponent("actions_checkout/\(sha1).tar.gz")
        XCTAssertNil(ActionArchiveCache.archiveProblem(checkout))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("dtolnay_rust-toolchain/\(sha2).tar.gz").path))

        // Nothing new: nothing fetched.
        messages = await filler.refresh(diagnosticsDirectories: [diagnostics], maxBytes: 1_000_000_000, maxAgeDays: 7, now: now)
        XCTAssertEqual(messages, [])
        XCTAssertEqual(github.requests.count, 2)

        // The next job takes it from the cache: it's marked used, not fetched again.
        try setModified(checkout, now.addingTimeInterval(-3 * 86400))
        let nextLog = diagnostics.appendingPathComponent("Worker_20261015-091000-utc.log")
        try append([look("actions/checkout", sha1), hit("actions/checkout", sha1)], to: nextLog)
        let later = now.addingTimeInterval(600)
        messages = await filler.refresh(diagnosticsDirectories: [diagnostics], maxBytes: 1_000_000_000, maxAgeDays: 7, now: later)
        XCTAssertEqual(messages, [])
        XCTAssertEqual(github.requests.count, 2)
        XCTAssertEqual(try modified(checkout).timeIntervalSince1970, later.timeIntervalSince1970, accuracy: 1)

        // A line still being written is read once it's whole.
        try append([look("pnpm/action-setup", sha3)], to: nextLog, newline: false)
        _ = await filler.refresh(diagnosticsDirectories: [diagnostics], maxBytes: 1_000_000_000, maxAgeDays: 7, now: later)
        XCTAssertEqual(github.requests.count, 2)
        try append([""], to: nextLog)
        _ = await filler.refresh(diagnosticsDirectories: [diagnostics], maxBytes: 1_000_000_000, maxAgeDays: 7, now: later)
        XCTAssertEqual(github.requests.last, "/pnpm/action-setup/tar.gz/\(sha3)")
        XCTAssertEqual(ActionArchiveCache.contents(of: directory).archives, 3)
    }

    func testTheFillerWaitsAfterFailuresAndLongestForRepositoriesItCantRead() async throws {
        let home = try scratch("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let (filler, github) = try filler(home: home)
        github.answer("/acme/private/tar.gz/\(sha1)", [404])
        github.answer("/actions/checkout/tar.gz/\(sha1)", [429, 200])
        let diagnostics = home.appendingPathComponent("_diag", isDirectory: true)
        let log = diagnostics.appendingPathComponent("Worker_20261015-090000-utc.log")
        try append([look("acme/private", sha1), look("actions/checkout", sha1)], to: log)
        let now = Date()

        var messages = await filler.refresh(diagnosticsDirectories: [diagnostics], maxBytes: 1_000_000_000, maxAgeDays: 7, now: now)
        XCTAssertEqual(messages.filter { $0.hasPrefix("Couldn't save") }.count, 2, "\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("acme/private") && $0.contains("404") && $0.contains("1440 min") }, "\(messages)")
        XCTAssertEqual(ActionArchiveCache.contents(of: ActionArchiveCache.directory(home: home)).archives, 0)
        let statusPage = home.appendingPathComponent("downloads")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: statusPage.path), [], "failed downloads are deleted")

        // Two minutes later another job asks for both: only the rate-limited one is tried again.
        try append([look("acme/private", sha1), look("actions/checkout", sha1)], to: log)
        messages = await filler.refresh(diagnosticsDirectories: [diagnostics], maxBytes: 1_000_000_000, maxAgeDays: 7, now: now.addingTimeInterval(120))
        XCTAssertEqual(messages.filter { $0.hasPrefix("Saved ") }.count, 1, "\(messages)")
        XCTAssertEqual(github.requests.filter { $0.contains("private") }.count, 1)

        // A day on, it's tried again.
        try append([look("acme/private", sha1)], to: log)
        _ = await filler.refresh(diagnosticsDirectories: [diagnostics], maxBytes: 1_000_000_000, maxAgeDays: 7, now: now.addingTimeInterval(86400 + 60))
        XCTAssertEqual(github.requests.filter { $0.contains("private") }.count, 2)
    }

    func testTheFillerDropsAnArchiveARunnerCouldntExtract() async throws {
        let home = try scratch("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let (filler, github) = try filler(home: home)
        let directory = try ActionArchiveCache.prepareDirectory(home: home)
        try ActionArchiveCache.install(try tarball(at: home.appendingPathComponent("d.tar.gz")), as: key("actions/checkout", sha1), in: directory)
        let diagnostics = home.appendingPathComponent("_diag", isDirectory: true)
        try append([
            look("actions/checkout", sha1), hit("actions/checkout", sha1),
            "[x ERR  ActionManager] Can't use 'tar -xzf' extract archive file: /w/_actions/_temp_1/2.tar.gz",
        ], to: diagnostics.appendingPathComponent("Worker_20261015-090000-utc.log"))

        let messages = await filler.refresh(diagnosticsDirectories: [diagnostics], maxBytes: 1_000_000_000, maxAgeDays: 7)
        XCTAssertTrue(messages.contains { $0.hasPrefix("Dropped actions/checkout@") }, "\(messages)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("actions_checkout/\(sha1).tar.gz").path))
        XCTAssertEqual(github.requests, [], "not fetched again in the same pass")
    }

    func testTheFillerSkipsOldLogsAndDoesNothingWithoutRunners() async throws {
        let home = try scratch("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let (filler, github) = try filler(home: home)
        let diagnostics = home.appendingPathComponent("_diag", isDirectory: true)
        let nothing = await filler.refresh(diagnosticsDirectories: [], maxBytes: 1, maxAgeDays: 7)
        XCTAssertEqual(nothing, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ActionArchiveCache.directory(home: home).path),
                       "nothing uses it, so it isn't made")

        let old = diagnostics.appendingPathComponent("Worker_20261012-090000-utc.log")
        try append([look("actions/checkout", sha1)], to: old)
        try setModified(old, Date().addingTimeInterval(-2 * 86400))
        _ = await filler.refresh(diagnosticsDirectories: [diagnostics], maxBytes: 1_000_000_000, maxAgeDays: 7)
        XCTAssertEqual(github.requests, [], "logs from before the app started are left alone")

        // A log it skipped is read from where it stood if it grows.
        try append([look("actions/setup-node", sha2)], to: old)
        _ = await filler.refresh(diagnosticsDirectories: [diagnostics], maxBytes: 1_000_000_000, maxAgeDays: 7)
        XCTAssertEqual(github.requests, ["/actions/setup-node/tar.gz/\(sha2)"])
    }

    func testTheFillerKeepsTheCacheInItsBudget() async throws {
        let home = try scratch("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let (filler, _) = try filler(home: home)
        let diagnostics = home.appendingPathComponent("_diag", isDirectory: true)
        try append([look("actions/checkout", sha1)], to: diagnostics.appendingPathComponent("Worker_20261015-090000-utc.log"))
        let messages = await filler.refresh(diagnosticsDirectories: [diagnostics], maxBytes: 0, maxAgeDays: 7)
        XCTAssertTrue(messages.contains { $0.hasPrefix("Removed 1 archive(s)") }, "\(messages)")
        XCTAssertEqual(ActionArchiveCache.contents(of: ActionArchiveCache.directory(home: home)).archives, 0)
    }

    // MARK: - How runners get it

    func testDockerRunnersGetTheCacheReadOnlyWithTheVariable() {
        let on = ContainerRunnerScript.variables(
            registrationURL: "https://github.com/o/r", registration: .jitConfig("c"), runnerName: "linux", labels: ["self-hosted"],
            runnerDownloadURL: "https://example.com/r.tar.gz", openFileLimit: 4096, tools: [], enableGUI: false, actionArchiveCache: true
        )
        XCTAssertTrue(on.contains { $0 == ("ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE", "/mac-runner/action-archives") })
        let off = ContainerRunnerScript.variables(
            registrationURL: "https://github.com/o/r", registration: .jitConfig("c"), runnerName: "linux", labels: ["self-hosted"],
            runnerDownloadURL: "https://example.com/r.tar.gz", openFileLimit: 4096, tools: [], enableGUI: false
        )
        XCTAssertFalse(off.contains { $0.name == ActionArchiveCache.variable })

        let id = UUID()
        func launcher(_ directory: String?) -> String {
            DockerRunnerEngine.launcherScript(
                docker: "/usr/local/bin/docker", runnerID: id, runnerName: "linux", runnerDirectory: "/Users/ci/.mac-runner/runners/x",
                image: "ci:latest", cpus: 2, memoryMB: 4096, openFileLimit: 4096, environmentNames: on.map(\.name),
                actionCacheDirectory: directory
            )
        }
        XCTAssertTrue(launcher("/Users/ci/.mac-runner/action-archives")
            .contains("-v /Users/ci/.mac-runner/action-archives:/mac-runner/action-archives:ro"))
        XCTAssertTrue(launcher("/Users/ci/.mac-runner/action-archives").contains("-e ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE"))
        XCTAssertFalse(launcher(nil).contains("action-archives:"))
    }

    func testADedicatedUsersRunnerGetsTheVariableThroughSudosResetEnvironment() throws {
        let root = try scratch("launch")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = root.appendingPathComponent("run.sh")
        try "#!/bin/bash\necho \"cache=$ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE ci=${CI:-}\"\n".write(to: probe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)

        let headless = UserIsolationService.launchCommand(directory: root.path, executable: probe.path, enableGUI: false,
                                                          actionArchiveCache: "/Users/me/.mac-runner/action-archives")
        XCTAssertTrue(headless.contains("env -u DISPLAY"), headless)
        var result = try ProcessExecutor.run("/usr/bin/env", arguments: ["-i", "/bin/bash", "-c", headless])
        XCTAssertEqual(result.output, "cache=/Users/me/.mac-runner/action-archives ci=true\n")

        let gui = UserIsolationService.launchCommand(directory: root.path, executable: probe.path, enableGUI: true,
                                                     actionArchiveCache: "/Users/it's/.mac-runner/action-archives")
        result = try ProcessExecutor.run("/usr/bin/env", arguments: ["-i", "/bin/bash", "-c", gui])
        XCTAssertEqual(result.output, "cache=/Users/it's/.mac-runner/action-archives ci=\n")

        XCTAssertEqual(UserIsolationService.launchCommand(directory: "/d", executable: "/d/run.sh", enableGUI: true), "cd '/d' && '/d/run.sh'",
                       "unchanged without a cache")
    }

    // MARK: - The option

    func testItsOnForJITRunnersByDefaultWhereItCanBe() throws {
        XCTAssertTrue(Runner(name: "gui", repo: "o", jit: true).usesActionCache(global: IsolationMode.none))
        XCTAssertFalse(Runner(name: "long", repo: "o").usesActionCache(global: IsolationMode.none), "long-lived runners opt in")
        XCTAssertTrue(Runner(name: "long", repo: "o", actionCache: true).usesActionCache(global: IsolationMode.none))
        XCTAssertFalse(Runner(name: "jit", repo: "o", jit: true, actionCache: false).usesActionCache(global: IsolationMode.none))
        XCTAssertTrue(Runner(name: "user", repo: "o", isolationMode: .dedicatedUser(username: "_macrunner"), jit: true)
            .usesActionCache(global: IsolationMode.none))
        XCTAssertTrue(Runner(name: "linux", repo: "o", isolationMode: .container, containerEngine: .docker, jit: true)
            .usesActionCache(global: IsolationMode.none))
        let apple = Runner(name: "apple", repo: "o", isolationMode: .container, jit: true, actionCache: true)
        XCTAssertFalse(apple.supportsActionCache(global: IsolationMode.none))
        XCTAssertFalse(apple.usesActionCache(global: IsolationMode.none), "Apple's engine can't mount it")

        // nil isn't written; an explicit off is kept.
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Runner(name: "p", repo: "o/r", jit: true))) as? [String: Any]
        XCTAssertNil(plain?["actionCache"])
        let off = Runner(name: "p", repo: "o/r", jit: true, actionCache: false)
        XCTAssertEqual(try JSONDecoder().decode(Runner.self, from: JSONEncoder().encode(off)).actionCache, false)
        XCTAssertEqual(try JSONDecoder().decode(Runner.self, from: JSONEncoder().encode(off)), off)
    }

    func testCLIOptions() throws {
        func parse(_ args: [String]) throws -> AddCommand { try AddCommand.parse(args, hostCores: 8).get() }
        XCTAssertNil(try parse(["o/r"]).actionCache)
        XCTAssertEqual(try parse(["o/r", "--action-cache"]).actionCache, true)
        XCTAssertEqual(try parse(["o/r", "--jit", "--no-action-cache"]).actionCache, false)
        XCTAssertNil(try parse(["o/r", "--action-cache"]).validationError(globalIsolation: IsolationMode.none))
        XCTAssertNil(try parse(["o/r", "--isolation", "container", "--engine", "docker", "--action-cache"]).validationError(globalIsolation: IsolationMode.none))
        XCTAssertEqual(try parse(["o/r", "--isolation", "container", "--action-cache"]).validationError(globalIsolation: IsolationMode.none)?.text,
                       "--action-cache needs the Docker engine (--engine docker) with container isolation: Apple's engine can't mount it")
        XCTAssertNil(try parse(["o/r", "--isolation", "container", "--no-action-cache"]).validationError(globalIsolation: IsolationMode.none))
    }

    func testConfigFileKeysExportAndPlan() throws {
        let config = try DeclarativeConfig.parse("""
        settings:
          max-action-cache-size-gb: 3
        runners:
          - name: gui
            repo: o/r
            jit: true
          - name: off
            repo: o/r
            jit: true
            action-cache: false
          - name: long
            repo: o/r
            action-cache: true
        """)
        let desired = try config.desiredRunners(hostCores: 8)
        XCTAssertEqual(desired.map(\.actionCache), [nil, false, true])
        XCTAssertEqual(desired.map { $0.usesActionCache(global: IsolationMode.none) }, [true, false, true])
        XCTAssertEqual(try config.resolvedSettings(AppSettings()).storageMaintenance.maxActionCacheSizeGB, 3)
        XCTAssertThrowsError(try DeclarativeConfig.parse("settings:\n  max-action-cache-size-gb: 0\nrunners: []\n").resolvedSettings(AppSettings()))
        XCTAssertThrowsError(try DeclarativeConfig.parse(
            "runners:\n  - name: r\n    repo: o/r\n    isolation: container\n    action-cache: true\n").desiredRunners(hostCores: 8)) { error in
            XCTAssertTrue(error.localizedDescription.contains("action-cache requires the Docker engine"), error.localizedDescription)
        }

        // Export and re-apply: nothing to do.
        var settings = AppSettings()
        settings.storageMaintenance.maxActionCacheSizeGB = 3
        let current = [Runner(name: "gui", repo: "o/r", status: .running, jit: true),
                       Runner(name: "long", repo: "o/r", status: .running, actionCache: true)]
        let exported = DeclarativeConfig.export(runners: current, settings: settings)
        let text = try exported.yaml()
        XCTAssertTrue(text.contains("action-cache: true") && text.contains("max-action-cache-size-gb: 3"), text)
        let reparsed = try DeclarativeConfig.parse(text)
        XCTAssertEqual(ConfigPlanner.plan(desired: try reparsed.desiredRunners(hostCores: 8), desiredSettings: try reparsed.resolvedSettings(settings),
                                          current: current, currentSettings: settings), [])

        // Pinning what a runner does already restarts nothing; turning it off restarts.
        var pinned = try reparsed.desiredRunners(hostCores: 8)
        pinned[0].actionCache = true
        pinned[1].actionCache = false
        let plan = ConfigPlanner.plan(desired: pinned, desiredSettings: settings, current: current, currentSettings: settings)
        XCTAssertEqual(plan.count, 2)
        guard case .update(_, _, let gui, let guiRestarts) = plan[0], case .update(_, _, let long, let longRestarts) = plan[1] else {
            return XCTFail("\(plan)")
        }
        XCTAssertEqual(gui, ["action-cache default → on"])
        XCTAssertFalse(guiRestarts)
        XCTAssertEqual(long, ["action-cache on → off"])
        XCTAssertTrue(longRestarts)
    }

    func testTheBudgetSettingDefaultsToOneGB() throws {
        XCTAssertEqual(StorageMaintenanceSettings().maxActionCacheSizeGB, 1)
        let decoded = try JSONDecoder().decode(StorageMaintenanceSettings.self, from: Data(#"{"maxCacheSizeGB":5}"#.utf8))
        XCTAssertEqual(decoded.maxActionCacheSizeGB, 1, "older settings get the default")
        let clamped = try JSONDecoder().decode(StorageMaintenanceSettings.self, from: Data(#"{"maxActionCacheSizeGB":0}"#.utf8))
        XCTAssertEqual(clamped.maxActionCacheSizeGB, 1)
    }

    func testStatusSaysWhatTheCacheHoldsAndWhoUsesIt() throws {
        let home = try scratch("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = ActionArchiveCache.directory(home: home)
        let long = Runner(name: "long", repo: "o/r")
        XCTAssertNil(CLIHandler.actionCacheStatusLine(runners: [long], global: IsolationMode.none, budgetGB: 1, directory: directory))

        let line = try XCTUnwrap(CLIHandler.actionCacheStatusLine(
            runners: [long, Runner(name: "gui", repo: "o/r", jit: true)], global: IsolationMode.none, budgetGB: 1, directory: directory))
        XCTAssertTrue(line.hasPrefix("Action cache: \(directory.path), 0 archive(s), "), line)
        XCTAssertTrue(line.hasSuffix("of 1 GB; used by gui"), line)
    }

    func testUninstallRemovesTheCache() throws {
        let home = try scratch("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = try ActionArchiveCache.prepareDirectory(home: home)
        try ActionArchiveCache.install(try tarball(at: home.appendingPathComponent("d.tar.gz")), as: key("actions/checkout", sha1), in: directory)
        let service = UninstallService(homeDirectory: home, applicationsDirectory: home.appendingPathComponent("Applications"),
                                       cliSymlinkDirectories: [], usersRoot: home.appendingPathComponent("Users"))
        let plan = service.plan(runners: [], globalIsolationMode: IsolationMode.none, includeApplication: false)
        let item = try XCTUnwrap(plan.items.first { $0.path == directory.path })
        XCTAssertEqual(item.category, .cache)
        XCTAssertGreaterThan(item.bytes, 0)
    }

    // MARK: - Real Docker

    /// A container started by the real launcher and startup script sees the
    /// cache read-only at /mac-runner/action-archives, with the variable set, and
    /// its worker log lands where the app reads it. Opt in with
    /// MAC_RUNNER_DOCKER_TESTS=1 and MAC_RUNNER_TEST_IMAGE, an image with bash,
    /// tar, and gzip that's already pulled (e.g. ubuntu:24.04).
    func testDockerRunnersReadTheCacheInRealDocker() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MAC_RUNNER_DOCKER_TESTS"] == "1" else {
            throw XCTSkip("Set MAC_RUNNER_DOCKER_TESTS=1 to run against Docker")
        }
        guard let image = environment["MAC_RUNNER_TEST_IMAGE"] else {
            throw XCTSkip("Set MAC_RUNNER_TEST_IMAGE to a pulled image with bash, tar, and gzip")
        }
        guard let docker = DockerRunnerEngine.executablePath() else { throw XCTSkip("Docker isn't installed") }

        let id = UUID()
        let home = try scratch("docker")
        let runnerDirectory = home.appendingPathComponent(".mac-runner/runners/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runnerDirectory.appendingPathComponent("_diag"), withIntermediateDirectories: true)
        defer {
            _ = try? ProcessExecutor.run(docker, arguments: ["rm", "-f", DockerRunnerEngine.containerName(for: id)], timeout: 60)
            _ = try? ProcessExecutor.run(docker, arguments: ["volume", "rm", DockerRunnerEngine.workVolumeName(for: id)], timeout: 60)
            try? FileManager.default.removeItem(at: home)
        }
        let cache = try ActionArchiveCache.prepareDirectory(home: home)
        try ActionArchiveCache.install(try tarball(at: home.appendingPathComponent("d.tar.gz"), directories: ["actions-checkout-aaaaaaa"]),
                                       as: key("actions/checkout", sha1), in: cache)

        // What the worker does with the cache, then the trace line it writes for an archive that isn't there.
        let job = """
        set -e
        echo "variable=$ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE"
        archive="$ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE/actions_checkout/\(sha1).tar.gz"
        mkdir -p /tmp/staging && cp "$archive" /tmp/a.tar.gz && tar -xzf /tmp/a.tar.gz -C /tmp/staging
        echo "extracted=$(ls /tmp/staging)"
        if touch "$ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE/planted" 2>/dev/null; then echo "cache=writable"; else echo "cache=read-only"; fi
        echo "[2026-10-15 09:00:01Z INFO ActionManager] Check if action archive 'actions/setup-node@\(sha2)' already exists in cache directory '$ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE'" >> _diag/Worker_20261015-090000-utc.log
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
            registrationURL: "https://github.com/o/r", registration: .jitConfig("not-a-real-config"), runnerName: "cache test",
            labels: ["self-hosted"], runnerDownloadURL: "https://example.com/r.tar.gz", openFileLimit: 65536,
            tools: [], enableGUI: false, actionArchiveCache: true
        ) + DockerRunnerEngine.engineVariables
        let launcher = try DockerRunnerEngine.writeLaunchFiles(
            docker: docker, runnerID: id, runnerName: "cache test", runnerDirectory: runnerDirectory.path,
            image: image, cpus: 1, memoryMB: 1024, openFileLimit: 65536,
            environmentNames: variables.map(\.name), resetWorkVolume: true, actionCacheDirectory: cache.path
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
        XCTAssertTrue(output.contains("variable=/mac-runner/action-archives"), output)
        XCTAssertTrue(output.contains("extracted=actions-checkout-aaaaaaa"), output)
        XCTAssertTrue(output.contains("cache=read-only"), output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("planted").path))

        // The app reads the container's worker log on the Mac, and saves what it looked for.
        let (filler, github) = try filler(home: home)
        let messages = await filler.refresh(diagnosticsDirectories: [runnerDirectory.appendingPathComponent("_diag")],
                                            maxBytes: 1_000_000_000, maxAgeDays: 7)
        XCTAssertEqual(github.requests, ["/actions/setup-node/tar.gz/\(sha2)"], "\(messages)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("actions_setup-node/\(sha2).tar.gz").path))
    }
}
