import XCTest
@testable import MacRunner

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "UpdateCheckerTests")
        defaults.removePersistentDomain(forName: "UpdateCheckerTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "UpdateCheckerTests")
        defaults = nil
        super.tearDown()
    }

    func testSemanticVersionComparisonUsesNumericOrdering() throws {
        let lowerVersion = try XCTUnwrap(SemanticVersion("1.9.0"))
        let higherVersion = try XCTUnwrap(SemanticVersion("1.10.0"))
        let normalizedVersion = try XCTUnwrap(SemanticVersion("v1.2.0"))
        let shorthandVersion = try XCTUnwrap(SemanticVersion("1.2"))

        XCTAssertLessThan(lowerVersion, higherVersion)
        XCTAssertEqual(normalizedVersion, shorthandVersion)
    }

    func testAutomaticCheckReusesStoredReleaseWithinDailyWindow() async throws {
        var currentDate = Date(timeIntervalSince1970: 1_000)
        var fetchCount = 0
        let checker = UpdateChecker(
            userDefaults: defaults,
            now: { currentDate },
            fetchLatestRelease: { _ in
                fetchCount += 1
                return HTTPResponse(data: Self.latestReleaseData(tag: "v1.2.0"), statusCode: 200)
            }
        )

        _ = try await checker.checkForUpdates(
            currentVersion: "1.0.0",
            bundlePath: "/Applications/MacRunner.app",
            allowsAutomaticChecks: true
        )

        currentDate = currentDate.addingTimeInterval(10 * 60)

        let result = try await checker.checkForUpdates(
            currentVersion: "1.0.0",
            bundlePath: "/Applications/MacRunner.app",
            allowsAutomaticChecks: true
        )

        XCTAssertEqual(fetchCount, 1)
        guard case .skipped(let cachedUpdate) = result else {
            return XCTFail("Expected cached update result")
        }
        XCTAssertEqual(cachedUpdate?.latestVersion, "v1.2.0")
    }

    func testForcedCheckUsesFiveMinuteResponseCache() async throws {
        var currentDate = Date(timeIntervalSince1970: 2_000)
        var fetchCount = 0
        let checker = UpdateChecker(
            userDefaults: defaults,
            now: { currentDate },
            fetchLatestRelease: { _ in
                fetchCount += 1
                return HTTPResponse(data: Self.latestReleaseData(tag: "v1.3.0"), statusCode: 200)
            }
        )

        _ = try await checker.checkForUpdates(
            currentVersion: "1.0.0",
            bundlePath: "/Applications/MacRunner.app",
            allowsAutomaticChecks: true,
            force: true
        )

        currentDate = currentDate.addingTimeInterval(2 * 60)

        let result = try await checker.checkForUpdates(
            currentVersion: "1.0.0",
            bundlePath: "/Applications/MacRunner.app",
            allowsAutomaticChecks: true,
            force: true
        )

        XCTAssertEqual(fetchCount, 1)
        guard case .updateAvailable(let update) = result else {
            return XCTFail("Expected cached update result")
        }
        XCTAssertEqual(update.latestVersion, "v1.3.0")
    }

    func testHomebrewInstallDetectionUsesCellarPaths() {
        XCTAssertEqual(UpdateChecker.installSource(for: "/opt/homebrew/Cellar/mac-runner/1.2.3/Mac Runner.app"), .homebrewFormula)
        XCTAssertEqual(
            UpdateChecker.installSource(
                for: "/Applications/MacRunner.app",
                fileExists: { _ in false }
            ),
            .directDownload
        )
    }

    func testHomebrewInstallDetectionUsesCaskReceipt() {
        // The cask installs MacRunner.app; "Mac Runner.app" is the display name.
        for bundlePath in ["/Applications/MacRunner.app", "/Applications/Mac Runner.app"] {
            XCTAssertEqual(
                UpdateChecker.installSource(
                    for: bundlePath,
                    fileExists: { $0 == "/opt/homebrew/Caskroom/mac-runner" }
                ),
                .homebrewCask,
                bundlePath
            )
        }
        XCTAssertEqual(
            UpdateChecker.installSource(
                for: "/Applications/Other.app",
                fileExists: { $0 == "/opt/homebrew/Caskroom/mac-runner" }
            ),
            .directDownload
        )
    }

    func testCheckQueriesTheForksLatestRelease() async throws {
        var requestedURL: URL?
        let checker = UpdateChecker(
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 4_000) },
            fetchLatestRelease: { request in
                requestedURL = request.url
                return HTTPResponse(data: Self.latestReleaseData(tag: "v1.26.0"), statusCode: 200)
            }
        )

        let result = try await checker.checkForUpdates(
            currentVersion: "1.25.1",
            bundlePath: "/Applications/MacRunner.app",
            allowsAutomaticChecks: true,
            force: true
        )

        XCTAssertEqual(requestedURL?.absoluteString, "https://api.github.com/repos/sloper-ai/mac-runner/releases/latest")
        guard case .updateAvailable(let update) = result else {
            return XCTFail("Expected an available update")
        }
        XCTAssertEqual(update.releaseURL.absoluteString, "https://github.com/sloper-ai/mac-runner/releases/tag/v1.26.0")
    }

    func testCaskUpdatesUpgradeThroughTheForksTap() {
        let caskUpdate = Self.availableUpdate(installSource: .homebrewCask)
        XCTAssertEqual(caskUpdate.upgradeCommand, "brew upgrade --cask sloper-ai/mac-runner/mac-runner")
        XCTAssertEqual(caskUpdate.detailText, "Runs brew upgrade --cask sloper-ai/mac-runner/mac-runner")
        XCTAssertEqual(caskUpdate.actionTitle, "Install Update")

        let directUpdate = Self.availableUpdate(installSource: .directDownload)
        XCTAssertNil(directUpdate.upgradeCommand)
        XCTAssertEqual(directUpdate.detailText, "Download the latest release from GitHub")
        XCTAssertEqual(directUpdate.actionTitle, "Download Update")
    }

    func testFailedAutomaticCheckStillAppliesDailyBackoff() async throws {
        var currentDate = Date(timeIntervalSince1970: 3_000)
        var fetchCount = 0
        let checker = UpdateChecker(
            userDefaults: defaults,
            now: { currentDate },
            fetchLatestRelease: { _ in
                fetchCount += 1
                struct TestError: Error {}
                throw TestError()
            }
        )

        await XCTAssertThrowsErrorAsync {
            try await checker.checkForUpdates(
                currentVersion: "1.0.0",
                bundlePath: "/Applications/MacRunner.app",
                allowsAutomaticChecks: true
            )
        }

        currentDate = currentDate.addingTimeInterval(10 * 60)

        let result = try await checker.checkForUpdates(
            currentVersion: "1.0.0",
            bundlePath: "/Applications/MacRunner.app",
            allowsAutomaticChecks: true
        )

        XCTAssertEqual(fetchCount, 1)
        guard case .skipped(let cachedUpdate) = result else {
            return XCTFail("Expected a skipped result after failed backoff")
        }
        XCTAssertNil(cachedUpdate)
    }

    private static func latestReleaseData(tag: String) -> Data {
        """
        {
            "tag_name": "\(tag)",
            "html_url": "https://github.com/sloper-ai/mac-runner/releases/tag/\(tag)"
        }
        """.data(using: .utf8)!
    }

    private static func availableUpdate(installSource: UpdateInstallSource) -> AvailableUpdate {
        AvailableUpdate(
            currentVersion: "1.25.1",
            latestVersion: "v1.26.0",
            releaseURL: URL(string: "https://github.com/sloper-ai/mac-runner/releases/tag/v1.26.0")!,
            installSource: installSource
        )
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @escaping () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        // Expected.
    }
}
