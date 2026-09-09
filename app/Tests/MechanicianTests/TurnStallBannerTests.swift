import XCTest
@testable import Mechanician

/// The "Turn appears stalled" banner reports that the provider lane has gone quiet and offers
/// "Stop and recover". Neither is true while the app is holding a permission card the person has
/// not answered: nothing is wrong, and stopping would abort the turn being asked about.
@MainActor
final class TurnStallBannerTests: XCTestCase {
    private func bridge() -> AgentBridge {
        AgentBridge(
            settingsBaseOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("mechanician-turn-stall-\(UUID().uuidString)"),
            environmentOverride: [:])
    }

    private var selection: ModelSelection {
        ModelSelection(access: .claudeSubscription, modelID: "claude-opus-5")
    }

    func testAQuietTurnWithNothingOutstandingIsStillReportedStalled() {
        let bridge = bridge()
        let conversationID = UUID()
        bridge.beginTurnForStallTesting(
            turnID: "turn", conversationID: conversationID, selection: selection)

        bridge.fireTurnStallWatchdogForStallTesting(turnID: "turn")

        XCTAssertTrue(
            bridge.stalledConvs.contains(conversationID),
            "a genuinely wedged lane must still be reported")
    }

    func testATurnWaitingOnAnUnansweredPermissionIsNotStalled() {
        let bridge = bridge()
        let conversationID = UUID()
        bridge.beginTurnForStallTesting(
            turnID: "turn", conversationID: conversationID, selection: selection)
        bridge.holdPermissionForStallTesting("perm-1", turnID: "turn")

        bridge.fireTurnStallWatchdogForStallTesting(turnID: "turn")

        XCTAssertFalse(
            bridge.stalledConvs.contains(conversationID),
            "the person is being waited on, not the provider")
        XCTAssertNotEqual(bridge.statusLabel, "Turn appears stalled")
    }

    func testTheWatchdogKeepsWatchingWhileTheCardIsOpen() {
        let bridge = bridge()
        bridge.beginTurnForStallTesting(
            turnID: "turn", conversationID: UUID(), selection: selection)
        bridge.holdPermissionForStallTesting("perm-1", turnID: "turn")

        bridge.fireTurnStallWatchdogForStallTesting(turnID: "turn")

        // Deferring is not the same as giving up: a lane that wedges after they answer must still
        // be caught, so the watchdog has to be re-armed rather than dropped.
        XCTAssertTrue(bridge.turnStallWatchdogIsArmedForStallTesting(turnID: "turn"))
    }

    func testAnsweringTheCardRestoresOrdinaryStallDetection() {
        let bridge = bridge()
        let conversationID = UUID()
        bridge.beginTurnForStallTesting(
            turnID: "turn", conversationID: conversationID, selection: selection)
        bridge.holdPermissionForStallTesting("perm-1", turnID: "turn")
        bridge.fireTurnStallWatchdogForStallTesting(turnID: "turn")
        XCTAssertFalse(bridge.stalledConvs.contains(conversationID))

        bridge.answerPermissionForStallTesting("perm-1")
        bridge.fireTurnStallWatchdogForStallTesting(turnID: "turn")

        XCTAssertTrue(
            bridge.stalledConvs.contains(conversationID),
            "once the card is answered a quiet turn is a real stall again")
    }

    func testAnUnrelatedTurnsPermissionDoesNotSuppressThisOne() {
        let bridge = bridge()
        let conversationID = UUID()
        bridge.beginTurnForStallTesting(
            turnID: "quiet", conversationID: conversationID, selection: selection)
        bridge.beginTurnForStallTesting(
            turnID: "asking", conversationID: UUID(), selection: selection)
        bridge.holdPermissionForStallTesting("perm-1", turnID: "asking")

        bridge.fireTurnStallWatchdogForStallTesting(turnID: "quiet")

        XCTAssertTrue(
            bridge.stalledConvs.contains(conversationID),
            "suppression is per turn, not global")
    }
}
