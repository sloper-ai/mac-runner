import XCTest
@testable import MacRunner

final class DiskCleanupServiceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        let root = ProcessInfo.processInfo.environment["TMPDIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        temporaryDirectory = root
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testCapacityChangesBlockAdmissionAndAllowRecoveryWithSameService() throws {
        let fileManager = CapacityFileManager()
        let service = DiskCleanupService(fileManager: fileManager, homeDirectory: temporaryDirectory)
        fileManager.freeBytes = 120_000_000_000
        XCTAssertEqual(service.availableDiskBytes(), 120_000_000_000)

        fileManager.freeBytes = 20_000_000_000
        XCTAssertThrowsError(try StorageAdmission.check(
            bytes: service.availableDiskBytes(), minimumGB: 40, filesystem: "Mac filesystem"
        ))

        fileManager.freeBytes = 70_000_000_000
        XCTAssertEqual(service.availableDiskBytes(), 70_000_000_000)
        XCTAssertNoThrow(try StorageAdmission.check(
            bytes: service.availableDiskBytes(), minimumGB: 40, filesystem: "Mac filesystem"
        ))

        fileManager.freeBytes = nil
        XCTAssertNil(service.availableDiskBytes())
        XCTAssertThrowsError(try StorageAdmission.check(
            bytes: service.availableDiskBytes(), minimumGB: 40, filesystem: "Mac filesystem"
        ))
    }

    func testMissingHomeCannotReuseCachedCapacity() throws {
        let directory = temporaryDirectory!
        let service = DiskCleanupService(homeDirectory: directory)
        XCTAssertNotNil(service.availableDiskBytes())
        try FileManager.default.removeItem(at: directory)

        XCTAssertNil(service.availableDiskBytes())
    }

    func testDryRunReportsSharedCacheWithoutRemovingIt() throws {
        let cacheFile = temporaryDirectory.appendingPathComponent(".cache/pip/artifact.bin")
        try FileManager.default.createDirectory(
            at: cacheFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: 4096).write(to: cacheFile)

        let report = try DiskCleanupService(homeDirectory: temporaryDirectory).cleanup(
            runners: [],
            globalIsolationMode: .none,
            includeSharedCaches: true,
            dryRun: true
        )

        XCTAssertGreaterThan(report.reclaimedBytes, 0)
        XCTAssertEqual(report.removedPaths.count, 1)
        XCTAssertTrue(report.removedPaths[0].hasSuffix("/.cache/pip/artifact.bin"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    func testCleanupRemovesSharedCacheContentsButKeepsCacheRoot() throws {
        let cacheRoot = temporaryDirectory.appendingPathComponent(".npm/_npx", isDirectory: true)
        let cacheFile = cacheRoot.appendingPathComponent("package/index.js")
        try FileManager.default.createDirectory(
            at: cacheFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("cached".utf8).write(to: cacheFile)

        let report = try DiskCleanupService(homeDirectory: temporaryDirectory).cleanup(
            runners: [],
            globalIsolationMode: .none,
            includeSharedCaches: true,
            dryRun: false
        )

        XCTAssertEqual(report.removedPaths.count, 1)
        XCTAssertTrue(report.removedPaths[0].hasSuffix("/.npm/_npx/package"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    func testActiveRunnerPreservesSharedCaches() throws {
        let cacheFile = temporaryDirectory.appendingPathComponent(".cache/pip/artifact.bin")
        try FileManager.default.createDirectory(
            at: cacheFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("cached".utf8).write(to: cacheFile)
        let runner = Runner(name: "busy-runner", repo: "owner/repo", status: .running, busy: true)

        let report = try DiskCleanupService(homeDirectory: temporaryDirectory).cleanup(
            runners: [runner],
            globalIsolationMode: .none,
            includeSharedCaches: true,
            dryRun: false
        )

        XCTAssertEqual(report.skippedRunnerNames, ["busy-runner"])
        XCTAssertTrue(report.removedPaths.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))
    }
}

private final class CapacityFileManager: FileManager, @unchecked Sendable {
    var freeBytes: Int64?

    override func attributesOfFileSystem(forPath path: String) throws -> [FileAttributeKey: Any] {
        freeBytes.map { [.systemFreeSize: NSNumber(value: $0)] } ?? [:]
    }
}
