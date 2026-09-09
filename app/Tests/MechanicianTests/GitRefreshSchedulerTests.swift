import XCTest
@testable import Mechanician

final class GitRefreshSchedulerTests: XCTestCase {
    func testRapidRequestsCoalesceToLatestAction() {
        let scheduler = GitRefreshScheduler(delay: .seconds(60))
        var calls: [Int] = []

        scheduler.schedule { calls.append(1) }
        scheduler.schedule { calls.append(2) }

        XCTAssertTrue(scheduler.hasPendingRefresh)
        scheduler.flush()
        XCTAssertEqual(calls, [2])
        XCTAssertFalse(scheduler.hasPendingRefresh)

        scheduler.flush()
        XCTAssertEqual(calls, [2])
    }

    func testCancelDropsPendingRefresh() {
        let scheduler = GitRefreshScheduler(delay: .seconds(60))
        var calls = 0
        scheduler.schedule { calls += 1 }

        scheduler.cancel()
        scheduler.flush()

        XCTAssertEqual(calls, 0)
        XCTAssertFalse(scheduler.hasPendingRefresh)
    }

    func testOnlySuccessfulEditToolsInVisibleWorkspaceInvalidateGit() {
        XCTAssertTrue(GitRefreshScheduler.shouldRefreshAfterSuccessfulTool(
            name: "Edit", toolWorkspace: "/tmp/project/./", visibleWorkspace: "/tmp/project"))
        XCTAssertTrue(GitRefreshScheduler.shouldRefreshAfterSuccessfulTool(
            name: "Write", toolWorkspace: "/tmp/project", visibleWorkspace: "/tmp/project"))
        XCTAssertFalse(GitRefreshScheduler.shouldRefreshAfterSuccessfulTool(
            name: "Read", toolWorkspace: "/tmp/project", visibleWorkspace: "/tmp/project"))
        XCTAssertFalse(GitRefreshScheduler.shouldRefreshAfterSuccessfulTool(
            name: "Edit", toolWorkspace: "/tmp/other", visibleWorkspace: "/tmp/project"))
        XCTAssertFalse(GitRefreshScheduler.shouldRefreshAfterSuccessfulTool(
            name: "Edit", toolWorkspace: "/tmp/project", visibleWorkspace: ""))
    }

    func testBackgroundTerminalRefreshRequiresSameVisibleWorkspace() {
        XCTAssertTrue(GitRefreshScheduler.workspacesMatch(
            "/tmp/project/Sources/..", "/tmp/project"))
        XCTAssertFalse(GitRefreshScheduler.workspacesMatch("/tmp/background", "/tmp/visible"))
        XCTAssertFalse(GitRefreshScheduler.workspacesMatch("", "/tmp/visible"))
    }

    func testSilentPanelRefreshDoesNotSupersedeAnInFlightRequest() {
        XCTAssertFalse(GitRefreshScheduler.shouldBeginRefresh(
            silently: true, statusRequestInFlight: true))
        XCTAssertTrue(GitRefreshScheduler.shouldBeginRefresh(
            silently: true, statusRequestInFlight: false))
        XCTAssertTrue(GitRefreshScheduler.shouldBeginRefresh(
            silently: false, statusRequestInFlight: true))
    }

    func testSilentPanelRefreshKeepsCurrentSnapshotVisible() {
        XCTAssertFalse(GitRefreshScheduler.shouldReplaceVisibleSnapshot(
            silently: true, hasCurrentSnapshot: true))
        XCTAssertTrue(GitRefreshScheduler.shouldReplaceVisibleSnapshot(
            silently: true, hasCurrentSnapshot: false))
        XCTAssertTrue(GitRefreshScheduler.shouldReplaceVisibleSnapshot(
            silently: false, hasCurrentSnapshot: true))
    }
}
