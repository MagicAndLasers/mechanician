import XCTest
@testable import Mechanician

/// Every window runs its OWN agentd per lane, so a background-process report is identified by the
/// reporting DAEMON, not by the lane. Keying on the lane alone made two windows overwrite each
/// other and left rows alive after the daemon that could stop them had died (FR-117).
@MainActor
final class BackgroundProcessStoreTests: XCTestCase {
    private let windowA = UUID()
    private let windowB = UUID()

    private func source(_ bridge: UUID, _ access: ModelAccess = .claudeSubscription)
    -> BackgroundProcessSource {
        BackgroundProcessSource(bridgeID: bridge, access: access)
    }

    private func process(
        _ pid: Int, age: Double = 60, from source: BackgroundProcessSource,
        conversation: UUID? = nil
    ) -> BackgroundProcess {
        BackgroundProcess(
            pid: pid, label: "bash", command: "bash -c watch \(pid)",
            ageSeconds: age, detached: true, adopted: true, source: source,
            conversationID: conversation)
    }

    private func makeStore() -> BackgroundProcessStore { BackgroundProcessStore() }

    func testTwoWindowsOnTheSameLaneDoNotOverwriteEachOther() {
        let store = makeStore()
        store.replace([process(100, from: source(windowA))], for: source(windowA))
        store.replace([process(200, from: source(windowB))], for: source(windowB))
        XCTAssertEqual(Set(store.processes.map(\.pid)), [100, 200],
                       "each window's daemon reports its own set; neither may erase the other")
    }

    func testTheSameOrphanAdoptedByTwoDaemonsIsListedOnce() {
        // Two windows open on one workspace will both adopt the same detached process. The user
        // should see one row for one process.
        let store = makeStore()
        store.replace([process(100, from: source(windowA))], for: source(windowA))
        store.replace([process(100, from: source(windowB))], for: source(windowB))
        XCTAssertEqual(store.processes.map(\.pid), [100])
    }

    func testAReportedSetReplacesRatherThanMergesSoEndedWorkDisappears() {
        let store = makeStore()
        let a = source(windowA)
        store.replace([process(100, from: a), process(101, from: a)], for: a)
        store.replace([process(101, from: a)], for: a)
        XCTAssertEqual(store.processes.map(\.pid), [101],
                       "a process the daemon no longer reports has ended")
    }

    func testClearingOneDaemonLeavesTheOtherIntact() {
        let store = makeStore()
        store.replace([process(100, from: source(windowA))], for: source(windowA))
        store.replace([process(200, from: source(windowB))], for: source(windowB))
        store.clear(source(windowA))
        XCTAssertEqual(store.processes.map(\.pid), [200])
    }

    func testSuccessfulStopRemovesTheAcknowledgedPidImmediately() {
        let store = makeStore()
        let a = source(windowA)
        store.replace([process(100, from: a), process(101, from: a)], for: a)

        XCTAssertTrue(store.acknowledgeStop(pid: 100, from: a))

        XCTAssertEqual(store.processes.map(\.pid), [101],
                       "an accepted Stop must not leave its stale row visible")
    }

    func testSuccessfulStopKeepsAnotherDaemonsCopyUntilItsSnapshotSettles() {
        let store = makeStore()
        let a = source(windowA)
        let b = source(windowB)
        store.replace([process(100, from: a), process(101, from: a)], for: a)
        store.replace([process(100, from: b), process(200, from: b)], for: b)

        XCTAssertTrue(store.acknowledgeStop(pid: 100, from: a))

        XCTAssertEqual(Set(store.processes.map(\.pid)), [100, 101, 200],
                       "another daemon must keep a SIGTERM-resistant orphan stoppable")
        XCTAssertEqual(store.processes.first(where: { $0.pid == 100 })?.source, b)
    }

    func testAcknowledgementAfterAnEmptySourceSnapshotCannotEraseAnotherDaemon() {
        let store = makeStore()
        let a = source(windowA)
        let b = source(windowB)
        store.replace([process(100, from: a)], for: a)
        store.replace([process(100, from: b)], for: b)
        store.replace([], for: a)

        XCTAssertFalse(store.acknowledgeStop(pid: 100, from: a))

        XCTAssertEqual(store.processes.map(\.pid), [100])
        XCTAssertEqual(store.processes.first?.source, b,
                       "wire ordering cannot revoke another daemon's stop authority")
    }

    func testACompleteSnapshotCanRestoreAProcessThatSurvivedStop() {
        let store = makeStore()
        let a = source(windowA)
        let survivor = process(100, from: a)
        store.replace([survivor], for: a)
        XCTAssertTrue(store.acknowledgeStop(pid: 100, from: a))
        XCTAssertTrue(store.processes.isEmpty)

        store.replace([survivor], for: a)

        XCTAssertEqual(store.processes.map(\.pid), [100],
                       "the next daemon snapshot remains authoritative after SIGTERM")
    }

    func testUnknownStopAcknowledgementDoesNotChangeAnotherDaemonsRows() {
        let store = makeStore()
        let a = source(windowA)
        store.replace([process(100, from: a)], for: a)

        XCTAssertFalse(store.acknowledgeStop(pid: 100, from: source(windowB)))
        XCTAssertFalse(store.acknowledgeStop(pid: 999, from: a))

        XCTAssertEqual(store.processes.map(\.pid), [100])
    }

    func testClosingAWindowDropsEveryLaneItOwned() {
        let store = makeStore()
        store.replace([process(100, from: source(windowA, .claudeSubscription))],
                      for: source(windowA, .claudeSubscription))
        store.replace([process(101, from: source(windowA, .codexSubscription))],
                      for: source(windowA, .codexSubscription))
        store.replace([process(200, from: source(windowB))], for: source(windowB))
        store.clearBridge(windowA)
        XCTAssertEqual(store.processes.map(\.pid), [200],
                       "a closed window's daemons are gone; its rows cannot be stopped")
    }

    func testLanesWithinOneWindowAreTrackedSeparately() {
        // The Claude and Codex daemons in one window each run their own tracker.
        let store = makeStore()
        store.replace([process(100, from: source(windowA, .claudeSubscription))],
                      for: source(windowA, .claudeSubscription))
        store.replace([process(200, from: source(windowA, .codexSubscription))],
                      for: source(windowA, .codexSubscription))
        XCTAssertEqual(Set(store.processes.map(\.pid)), [100, 200])
    }

    func testOldestWorkSortsFirst() {
        let store = makeStore()
        let a = source(windowA)
        store.replace([process(100, age: 30, from: a), process(101, age: 900, from: a)], for: a)
        XCTAssertEqual(store.processes.map(\.pid), [101, 100])
    }

    func testTheKillTargetCarriesTheReportingDaemon() {
        // The kill has to reach the one daemon tracking the pid; every other daemon answers
        // control_error, which surfaces as a spurious system message.
        let store = makeStore()
        store.replace([process(100, from: source(windowB, .codexSubscription))],
                      for: source(windowB, .codexSubscription))
        XCTAssertEqual(store.processes.first?.source.bridgeID, windowB)
        XCTAssertEqual(store.processes.first?.access, .codexSubscription)
    }

    func testAnEmptyReportFromAnUnknownDaemonIsNotAChange() {
        let store = makeStore()
        store.replace([process(100, from: source(windowA))], for: source(windowA))
        store.replace([], for: source(windowB))
        XCTAssertEqual(store.processes.map(\.pid), [100])
    }

    /// The control bar reads one conversation, so it must count that conversation's work. One daemon
    /// serves every conversation on its lane, so the process-wide total showed a conversation every
    /// process the window had ever adopted — including work it never started.
    func testProcessesAreScopedToTheConversationThatStartedThem() {
        let store = makeStore()
        let mine = UUID()
        let theirs = UUID()
        store.replace([
            process(100, from: source(windowA), conversation: mine),
            process(200, from: source(windowA), conversation: theirs),
            process(300, from: source(windowA)),   // unattributed
        ], for: source(windowA))

        XCTAssertEqual(store.processes(for: mine).map(\.pid), [100])
        XCTAssertEqual(store.processes(for: theirs).map(\.pid), [200])
        // Everything stays visible process-wide, so nothing an agent left running is unreachable.
        XCTAssertEqual(Set(store.processes.map(\.pid)), [100, 200, 300])
    }

    func testUnattributedWorkIsNeverChargedToWhicheverConversationIsOpen() {
        let store = makeStore()
        store.replace([process(300, from: source(windowA))], for: source(windowA))

        XCTAssertTrue(store.processes(for: UUID()).isEmpty)
        XCTAssertTrue(store.processes(for: nil).isEmpty, "no conversation means nothing to attribute")
    }
}
