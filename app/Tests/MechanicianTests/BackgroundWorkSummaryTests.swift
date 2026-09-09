import XCTest
@testable import Mechanician

/// The control bar reports kinds of background activity, not a sum of incomparable units.
///
/// One dev server can appear as several OS processes, and an armed wait is deliberately idle. A
/// single "5 running" total therefore reads like five agents or tasks while describing neither — so
/// counts are never summed across kinds.
///
/// The chip does now carry a per-kind count. The earlier category-only "Background work" was
/// indistinguishable from a stale indicator: it looked the same whether something was genuinely
/// running or the chip had failed to clear, which is exactly how it was reported. Naming the unit
/// ("3 processes") keeps the original guarantee — no invented total, no process count masquerading
/// as a task count — while making the chip answerable at a glance.
final class BackgroundWorkSummaryTests: XCTestCase {
    func testAnArmedWaitIsNeverCountedAsRunning() {
        let summary = BackgroundWorkSummary(
            backgroundTurns: 0, ambientTasksRunning: 0, trackedProcesses: 0, armedWaits: 3)

        XCTAssertEqual(summary.waiting, 3)
        XCTAssertFalse(summary.hasManagedBackgroundWork)
        XCTAssertFalse(summary.isEmpty, "it must still be visible — that is the whole point")
    }

    func testProcessesAreCountedAsProcessesAndNeverAsTasks() {
        let summary = BackgroundWorkSummary(
            backgroundTurns: 0, ambientTasksRunning: 0, trackedProcesses: 5, armedWaits: 0)

        XCTAssertTrue(summary.hasManagedBackgroundWork)
        XCTAssertEqual(summary.managedBackgroundLabel, "5 processes running")
        XCTAssertEqual(summary.managedBackgroundAccessibilityLabel,
                       "agent-started background processes")
    }

    func testOneProcessReadsAsOneProcess() {
        let summary = BackgroundWorkSummary(
            backgroundTurns: 0, ambientTasksRunning: 0, trackedProcesses: 1, armedWaits: 0)

        XCTAssertEqual(summary.managedBackgroundLabel, "1 process running")
    }

    func testAmbientTasksKeepAMeaningfulTaskCountWhenNoProcessesAreMixedIn() {
        let summary = BackgroundWorkSummary(
            backgroundTurns: 0, ambientTasksRunning: 2, trackedProcesses: 0, armedWaits: 0)

        XCTAssertEqual(summary.managedBackgroundLabel, "2 tasks running")
        XCTAssertEqual(summary.managedBackgroundAccessibilityLabel, "2 ambient tasks running")
    }

    func testEveryKindRemainsSeparatelyInspectable() {
        let summary = BackgroundWorkSummary(
            backgroundTurns: 2, ambientTasksRunning: 1, trackedProcesses: 3, armedWaits: 4)

        XCTAssertEqual(summary.backgroundTurns, 2)
        XCTAssertEqual(summary.ambientTasksRunning, 1)
        XCTAssertEqual(summary.trackedProcesses, 3)
        XCTAssertEqual(summary.waiting, 4)
        // Two kinds, two counts, no invented total: 1 + 3 must never render as "4 running".
        XCTAssertEqual(summary.managedBackgroundLabel, "1 task, 3 processes")
        XCTAssertFalse(summary.managedBackgroundLabel.contains("4"))
        XCTAssertEqual(
            summary.managedBackgroundAccessibilityLabel,
            "1 ambient task running, agent-started background processes")
    }

    /// Nothing happening must render nothing — the chip is peripheral awareness, not chrome.
    func testNothingHappeningIsEmpty() {
        XCTAssertTrue(BackgroundWorkSummary(
            backgroundTurns: 0, ambientTasksRunning: 0, trackedProcesses: 0, armedWaits: 0).isEmpty)
    }
}

/// The ⏳ banner prefixes "Waiting ", and a note written naturally begins "waiting for …" — which
/// rendered as "Waiting waiting for the check to finish".
final class ArmedTriggerSummaryTests: XCTestCase {
    func testALeadingWaitingIsNotRepeated() {
        XCTAssertEqual(
            ArmedTrigger.withoutLeadingWaiting("waiting for the FR-129 check to finish"),
            "for the FR-129 check to finish")
        XCTAssertEqual(ArmedTrigger.withoutLeadingWaiting("Waiting on CI"), "on CI")
    }

    /// Only a LEADING occurrence is stripped; a note that merely mentions waiting keeps its words.
    func testWaitingElsewhereInTheNoteIsUntouched() {
        let note = "the deploy, which is worth waiting for"
        XCTAssertEqual(ArmedTrigger.withoutLeadingWaiting(note), note)
    }

    func testANoteThatIsOnlyTheWordWaitingIsLeftAlone() {
        XCTAssertEqual(ArmedTrigger.withoutLeadingWaiting("waiting"), "waiting")
        XCTAssertEqual(ArmedTrigger.withoutLeadingWaiting("Waiting  "), "Waiting")
    }
}
