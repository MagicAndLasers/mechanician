import Foundation
import XCTest
@testable import Mechanician

/// Machinery that exists, is tested, and is CALLED.
///
/// A sweep for production functions whose only callers are tests turned up four. Their own doc
/// comments each name a failure they were written to prevent, and none of them was reached, so none
/// of those failures was prevented. Their unit tests passed throughout, which is what made it
/// invisible — so these tests are about the WIRING, which is the half nothing was checking.
final class DarkMachineryWiringTests: XCTestCase {

    private func source(_ file: String) throws -> String {
        try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/MechanicianTests/DarkMachineryWiringTests.swift",
                with: "Sources/Mechanician/\(file)"),
            encoding: .utf8)
    }

    /// *"How long has it been on the step it is on — the only figure that distinguishes healthy slow
    /// work from a stall."* The agent lanes showed a phase, which is the same word for a healthy
    /// minute and a wedged hour.
    func testTheAgentLaneUsesTheRetainedIndexForItsStepAndStallState() throws {
        let panel = try source("AppKitAgentsPanel.swift")
        let helper = try XCTUnwrap(panel.range(of: "private func laneStep("))
        let body = panel[helper.lowerBound...].prefix(800)
        XCTAssertTrue(
            body.contains("renderModel.currentStep("),
            "the lane must ask the render model's retained ledger index what step it is on")
        XCTAssertTrue(
            body.contains("renderModel.stepIsStalled("),
            "and whether that step is unusual for THIS agent")
        XCTAssertFalse(
            body.contains("agentCurrentStep("),
            "drawing a lane must not reconstruct and sort a ledger index")
        XCTAssertFalse(
            body.contains("agentStepIsStalled("),
            "stall detection must reuse the same retained index")
    }

    /// The shared mode constant and manual tick test do not prove that the live Timer is installed
    /// with that mode. Pin the production wiring so menu tracking cannot silently regain a common-
    /// mode one-second invalidation source.
    func testTheAgentsTickerUsesThePresentationRunLoopMode() throws {
        let panel = try source("AppKitAgentsPanel.swift")
        XCTAssertTrue(
            panel.contains("RunLoop.main.add(timer, forMode: Self.presentationRunLoopMode)"),
            "the installed ticker must pause while AppKit owns a menu or drag tracking loop")
    }

    /// Only for a live lane: a finished agent's last step is history, and saying how long it sat
    /// there reads as a complaint about work that is already done.
    func testTheStepReadoutIsOnlyForALiveLane() throws {
        let panel = try source("AppKitAgentsPanel.swift")
        let helper = try XCTUnwrap(panel.range(of: "private func laneStep("))
        let body = panel[helper.lowerBound...].prefix(700)
        XCTAssertTrue(body.contains("guard lane.isActive"))
        XCTAssertTrue(body.contains("!step.isTerminal"))
    }

    /// *"A task that looks correct, runs on schedule, and quietly does nothing useful — the failure
    /// the user has no way to foresee."* The rules are the app's and were invisible.
    func testEveryScheduledTaskIsJudgedBeforeItRuns() throws {
        let ambient = try source("AmbientView.swift")
        XCTAssertTrue(ambient.contains("TaskReadiness.evaluate("), "nothing was calling it")
        XCTAssertTrue(
            ambient.contains("credentialReady:") && ambient.contains("workspaceResolved:"),
            "both preconditions must be answered, not defaulted")
    }

    /// The `info` tier stays off the row. A card with three grey notes on it teaches people to stop
    /// reading the notes, and then the blocking one goes unread too.
    func testOnlyFindingsThatWillActuallyBiteAreShown() throws {
        let ambient = try source("AmbientView.swift")
        XCTAssertTrue(ambient.contains("$0.severity > .info"))
    }

    /// The severities are ordered, which is what `> .info` rests on.
    func testSeverityOrderingIsWhatTheFilterAssumes() {
        XCTAssertLessThan(TaskReadiness.Severity.info, .warning)
        XCTAssertLessThan(TaskReadiness.Severity.warning, .blocking)
    }

    /// And the backup, from the same sweep: its two callers lived inside the migration and were
    /// retired with it, so nothing copied the library for fifteen days.
    func testTheDailyBackupStillHasACaller() throws {
        XCTAssertTrue(
            try source("MechanicianApp.swift").contains("LibraryBackupLauncher.runAfterLaunch"))
    }
}

/// A receipt's payload must be a function of its contents and nothing else.
///
/// Receipts are compared for idempotency — scanning the same envelope twice must produce the same
/// receipt — and the payload was encoded with a bare `JSONEncoder()` while the deterministic one
/// sat two hundred lines below, `private` to a different type in the same file. Unsorted keys made
/// those bytes only accidentally stable: the test that caught it passed alone and failed in the
/// full suite.
final class LibraryOperationPayloadDeterminismTests: XCTestCase {

    func testTheSameDetailsAlwaysEncodeToTheSameBytes() throws {
        let encoder = LibraryOperationCoding.encoder()
        XCTAssertTrue(
            encoder.outputFormatting.contains(.sortedKeys),
            "unsorted keys make a compared payload depend on dictionary ordering")
    }

    /// And nothing in this file may reach for a bare encoder again, which is the mistake itself
    /// rather than its symptom.
    func testNothingInThisFileEncodesWithoutTheSharedEncoder() throws {
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/MechanicianTests/DarkMachineryWiringTests.swift",
                with: "Sources/Mechanician/LibraryOperationAuthority.swift"),
            encoding: .utf8)
        // Comments stripped first. A doc comment naming the mistake is not the mistake, and
        // counting it is the same trap the localization ratchet fell into over a helper's name.
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.components(separatedBy: "//").first ?? "" }
            .joined(separator: "\n")
        let bare = code.components(separatedBy: "JSONEncoder()").count - 1
        XCTAssertEqual(
            bare, 1,
            "exactly one JSONEncoder() in this file, and it is the shared deterministic one")
    }
}
