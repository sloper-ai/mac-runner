import XCTest
@testable import MacRunner

@MainActor
final class StartupRecoveryTests: XCTestCase {
    func testRunnerStartedElsewhereKeepsItsLiveState() async {
        var runner = Runner(name: "jit", repo: "example", scope: .org, status: .running, jit: true)
        let failure = await RunnerStartupRecovery.failure {
            // The CLI publishes its registration between the launch snapshot
            // and the app checking the live PID in startRunner.
            runner.githubRunnerId = 42
            runner.busy = true
            throw RunnerError.alreadyRunning
        }
        if failure != nil { runner.status = .error }

        XCTAssertNil(failure)
        XCTAssertEqual(runner.status, .running)
        XCTAssertTrue(runner.busy)
        XCTAssertEqual(runner.githubRunnerId, 42)
    }

    func testStartOwnedByAnotherProcessRemainsWanted() async {
        var runner = Runner(name: "jit", repo: "example", status: .running, jit: true)
        let failure = await RunnerStartupRecovery.failure {
            throw RunnerError.startInProgress
        }
        if failure != nil { runner.status = .error }

        XCTAssertNil(failure)
        XCTAssertEqual(runner.status, .running)
    }

    func testGenuineLaunchFailureStillReachesErrorHandling() async {
        let failure = await RunnerStartupRecovery.failure {
            throw RunnerError.startFailed
        }

        guard case .startFailed = failure as? RunnerError else {
            return XCTFail("The original launch failure must be reported")
        }
    }
}
