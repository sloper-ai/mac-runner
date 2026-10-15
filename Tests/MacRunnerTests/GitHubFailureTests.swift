import XCTest
@testable import MacRunner

/// Telling a GitHub outage from a login GitHub refuses, and how a JIT runner
/// retries each. The gh output here is what gh 2.x prints.
final class GitHubFailureTests: XCTestCase {
    /// What `gh api` printed on a Mac Runner host while GitHub refused connections.
    private let refusedConnection = #"Delete "https://api.github.com/orgs/octo-org/actions/runners/4494": dial tcp 172.182.252.137:443: connect: connection refused"#
    /// What `gh auth status` printed then: the same as for a token GitHub refuses.
    private let authStatusDuringOutage = """
    github.com
      X Failed to log in to github.com account octocat (keyring)
      - Active account: true
      - The token in keyring is invalid.
      - To re-authenticate, run: gh auth refresh -h github.com
      - To forget about this account, run: gh auth logout -h github.com -u octocat
    """

    // MARK: - Classification

    func testNetworkErrorsAreTransient() {
        let outputs = [
            refusedConnection,
            #"Get "https://api.github.com/rate_limit": proxyconnect tcp: dial tcp 127.0.0.1:9: connect: connection refused"#,
            "error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com",
            #"Post "https://api.github.com/orgs/o/actions/runners/generate-jitconfig": net/http: TLS handshake timeout"#,
            #"Post "https://api.github.com/orgs/o/actions/runners/generate-jitconfig": context deadline exceeded (Client.Timeout exceeded while awaiting headers)"#,
            #"Post "https://api.github.com/orgs/o/actions/runners/generate-jitconfig": EOF"#,
            #"Post "https://api.github.com/orgs/o/actions/runners/generate-jitconfig": read tcp 10.0.0.2:50000->140.82.112.6:443: read: connection reset by peer"#,
            #"Get "https://api.github.com/rate_limit": dial tcp: lookup api.github.com: no such host"#,
        ]
        for output in outputs {
            XCTAssertEqual(GitHubFailure.classify(exitCode: 1, stderr: output), .transient, output)
        }
    }

    func testServerErrorsAndRateLimitsAreTransient() {
        let outputs = [
            "gh: Server Error (HTTP 500)",
            "gh: HTTP 502",
            "gh: Service Unavailable (HTTP 503)",
            "gh: API rate limit exceeded for user ID 1. (HTTP 403)",
            "gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)",
            "gh: HTTP 429",
        ]
        for output in outputs {
            XCTAssertEqual(GitHubFailure.classify(exitCode: 1, stderr: output), .transient, output)
        }
    }

    func testARefusedTokenOrNoLoginIsUnauthorized() {
        XCTAssertEqual(GitHubFailure.classify(exitCode: 1, stderr: "gh: Bad credentials (HTTP 401)"), .unauthorized)
        XCTAssertEqual(GitHubFailure.classify(exitCode: 1, stderr: "gh: HTTP 401"), .unauthorized)
        // gh exits 4 when it has no token at all.
        XCTAssertEqual(GitHubFailure.classify(
            exitCode: 4,
            stderr: "To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token."
        ), .unauthorized)
    }

    func testOtherRefusalsAreNeither() {
        let outputs = [
            "gh: Resource not accessible by integration (HTTP 403)",
            "gh: Not Found (HTTP 404)",
            "gh: Validation Failed (HTTP 422)",
            """
            gh: You must be an org admin or have the runners and runner groups fine-grained permission. (HTTP 403)
            This API operation needs the "admin:org" scope.
            """,
            "",
        ]
        for output in outputs {
            XCTAssertEqual(GitHubFailure.classify(exitCode: 1, stderr: output), .other, output)
        }
    }

    // MARK: - The auth check

    func testAnOutageIsNotAnExpiredLogin() async throws {
        let stub = try standInGH(auth: (1, authStatusDuringOutage), api: (1, refusedConnection))
        defer { try? FileManager.default.removeItem(at: stub.root) }

        let state = await stub.gh.validateAuth()
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(state.failure, .transient)
        XCTAssertTrue(state.recoveryMessage.contains("connection refused"), state.recoveryMessage)
        XCTAssertFalse(state.recoveryMessage.contains("gh auth login"), "no login to fix: \(state.recoveryMessage)")
        XCTAssertEqual(try stub.calls(), ["auth status", "api rate_limit --silent"])
    }

    func testATokenGitHubRefusesNeedsALogin() async throws {
        let stub = try standInGH(auth: (1, authStatusDuringOutage), api: (1, "gh: Bad credentials (HTTP 401)"))
        defer { try? FileManager.default.removeItem(at: stub.root) }

        let state = await stub.gh.validateAuth()
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(state.failure, .unauthorized)
        XCTAssertTrue(state.recoveryMessage.hasPrefix(GitHubAuthState.loginRecoveryMessage), state.recoveryMessage)
        XCTAssertTrue(state.recoveryMessage.contains("Bad credentials (HTTP 401)"), state.recoveryMessage)
    }

    func testNoLoginNeedsALogin() async throws {
        let stub = try standInGH(
            auth: (1, "You are not logged into any GitHub hosts. To log in, run: gh auth login"),
            api: (4, "To get started with GitHub CLI, please run:  gh auth login")
        )
        defer { try? FileManager.default.removeItem(at: stub.root) }

        let state = await stub.gh.validateAuth()
        XCTAssertEqual(state.failure, .unauthorized)
        XCTAssertTrue(state.recoveryMessage.hasPrefix(GitHubAuthState.loginRecoveryMessage), state.recoveryMessage)
    }

    func testATokenGitHubTakesIsAuthenticatedWhateverAuthStatusSays() async throws {
        // gh auth status can fail over another host or account.
        let stub = try standInGH(auth: (1, authStatusDuringOutage), api: (0, ""))
        defer { try? FileManager.default.removeItem(at: stub.root) }

        let state = await stub.gh.validateAuth()
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertNil(state.failure)
    }

    func testAPassingAuthStatusNeedsNoProbe() async throws {
        let stub = try standInGH(auth: (0, "github.com\n  ✓ Logged in to github.com account octocat (keyring)"), api: (1, refusedConnection))
        defer { try? FileManager.default.removeItem(at: stub.root) }

        let state = await stub.gh.validateAuth()
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(try stub.calls(), ["auth status"])
    }

    // MARK: - JIT registration

    func testARegistrationFailureSaysWhetherToRetry() async throws {
        let target = RunnerTarget(scope: .org, identifier: "octo-org")
        let cases: [(stderr: String, failure: GitHubFailure, retry: JITRunner.StartRetry)] = [
            (#"Post "https://api.github.com/orgs/octo-org/actions/runners/generate-jitconfig": dial tcp 172.182.252.137:443: connect: connection refused"#,
             .transient, .retry(seconds: 10)),
            ("gh: Service Unavailable (HTTP 503)", .transient, .retry(seconds: 10)),
            ("gh: Bad credentials (HTTP 401)", .unauthorized, .waitForLogin(seconds: 300)),
            ("gh: Resource not accessible by integration (HTTP 403)", .other, .crashBackoff),
        ]
        for expected in cases {
            let stub = try standInGH(auth: (0, ""), api: (1, expected.stderr))
            defer { try? FileManager.default.removeItem(at: stub.root) }
            do {
                _ = try await stub.gh.generateJITConfig(for: target, name: "n-000001", labels: ["x"], workFolder: "_work")
                XCTFail("expected a failure for \(expected.stderr)")
            } catch {
                XCTAssertEqual((error as? GHError)?.failure, expected.failure, expected.stderr)
                XCTAssertEqual(JITRunner.startRetry(after: error, attempt: 1), expected.retry, expected.stderr)
                XCTAssertTrue(error.localizedDescription.contains("Failed to register a JIT runner"), error.localizedDescription)
                if expected.failure == .unauthorized {
                    XCTAssertTrue(error.localizedDescription.contains("Run: gh auth login"), error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Retrying

    func testRetriesBackOffFrom10SecondsTo5Minutes() {
        XCTAssertEqual((1...8).map(JITRunner.gitHubRetryDelay(forAttempt:)), [10, 20, 40, 80, 160, 300, 300, 300])
    }

    func testAnOutageIsRetriedForAsLongAsItLasts() {
        // The crash backoff gave up after its 10 retries in 10 minutes; these never do.
        let outage = GHError.unavailable("Couldn't reach GitHub to check the GitHub CLI login: \(refusedConnection)")
        var waited = 0
        for attempt in 1...1_000 {
            guard case .retry(let seconds) = JITRunner.startRetry(after: outage, attempt: attempt) else {
                return XCTFail("attempt \(attempt) stopped retrying")
            }
            XCTAssertLessThanOrEqual(seconds, JITRunner.gitHubRetryMaxDelay)
            waited += seconds
        }
        XCTAssertGreaterThan(waited, 24 * 3600, "a thousand retries cover a day-long outage")
        XCTAssertEqual(JITRunner.startRetry(after: outage, attempt: .max), .retry(seconds: 300), "no overflow")
    }

    func testARefusedLoginStopsTheRunnerAndIsCheckedAgain() {
        let refused = GHError.authFailed(GitHubAuthState.loginRecoveryMessage)
        XCTAssertEqual(JITRunner.startRetry(after: refused, attempt: 1), .waitForLogin(seconds: 300))
        XCTAssertEqual(JITRunner.startRetry(after: refused, attempt: 7), .waitForLogin(seconds: 300))
    }

    func testFailuresGitHubDidntCauseKeepTheCrashBackoff() {
        XCTAssertEqual(JITRunner.startRetry(after: GHError.apiFailed("gh: Not Found (HTTP 404)"), attempt: 1), .crashBackoff)
        XCTAssertEqual(JITRunner.startRetry(after: GHError.processLaunchFailed("no gh"), attempt: 1), .crashBackoff)
        XCTAssertEqual(JITRunner.startRetry(after: RunnerError.containerServiceNotAvailable, attempt: 1), .crashBackoff)
    }

    // MARK: - Stand-in gh

    /// A gh that answers `gh auth status` and `gh api` as given, and records
    /// each call's arguments.
    private func standInGH(
        auth: (status: Int32, output: String),
        api: (status: Int32, output: String)
    ) throws -> (gh: GHCLIService, root: URL, calls: () throws -> [String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gh failures it's \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let calls = root.appendingPathComponent("calls")
        let authOutput = root.appendingPathComponent("auth")
        let apiOutput = root.appendingPathComponent("api")
        try auth.output.write(to: authOutput, atomically: true, encoding: .utf8)
        try api.output.write(to: apiOutput, atomically: true, encoding: .utf8)
        let gh = root.appendingPathComponent("gh")
        try """
        #!/bin/bash
        printf '%s\\n' "$*" >> \(quoted(calls.path))
        if [ "$1" = auth ]; then cat \(quoted(authOutput.path)) >&2; exit \(auth.status); fi
        cat \(quoted(apiOutput.path)) >&2
        exit \(api.status)
        """.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        return (GHCLIService(ghPath: gh.path), root, {
            try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").map(String.init)
        })
    }

    private func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
