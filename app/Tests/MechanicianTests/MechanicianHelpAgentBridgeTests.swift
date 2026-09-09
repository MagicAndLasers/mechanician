import Foundation
import XCTest
@testable import Mechanician

@MainActor
final class MechanicianHelpAgentBridgeTests: XCTestCase {
    func testHelpRequestsAndAcknowledgementsRequireOwnedTurnRoutes() throws {
        XCTAssertTrue(AgentBridge.turnScopedEventTypes.contains("help_search_request"))
        XCTAssertTrue(AgentBridge.turnScopedEventTypes.contains("help_search_ack"))
        XCTAssertTrue(AgentBridge.providerWorkEvidenceEventTypes.contains(
            "help_search_request"))
        XCTAssertTrue(AgentBridge.providerWorkEvidenceEventTypes.contains(
            "help_search_ack"))
        XCTAssertTrue(AgentBridge.turnScopedEventTypes.contains("show_mechanician_request"))
        XCTAssertTrue(AgentBridge.turnScopedEventTypes.contains("show_mechanician_ack"))
        XCTAssertTrue(AgentBridge.providerWorkEvidenceEventTypes.contains(
            "show_mechanician_request"))
        XCTAssertTrue(AgentBridge.providerWorkEvidenceEventTypes.contains(
            "show_mechanician_ack"))
        XCTAssertTrue(AgentBridge.turnScopedEventTypes.contains("operate_mechanician_request"))
        XCTAssertTrue(AgentBridge.providerWorkEvidenceEventTypes.contains(
            "operate_mechanician_request"))

        let source = try bridgeSource()
        XCTAssertTrue(source.contains(
            "applyHelpSearchRequest(event, turnID: turnID, route: turnRoute)"))
        XCTAssertTrue(source.contains(
            "applyHelpSearchAcknowledgement(event, turnID: turnID, route: turnRoute)"))
    }

    func testForgedPlanOperateRequestFailsClosedAtInitialAndAsyncAdmissions() throws {
        let source = try bridgeSource()
        let start = try XCTUnwrap(source.range(of:
            "private func applyOperateMechanicianRequest("))
        let rest = source[start.lowerBound...]
        let end = try XCTUnwrap(rest.range(of:
            "\n    /// Consume only the acknowledgement for the exact started session."))
        let body = String(rest[..<end.lowerBound])

        XCTAssertTrue(body.contains("route.permissionMode != \"plan\""))
        XCTAssertTrue(body.contains("current.permissionMode != \"plan\""))
        XCTAssertTrue(body.contains("self.routesMatch(current, route)"))
        XCTAssertTrue(body.contains("MechanicianOperationRefusal.sourceInvalidated.text"))
    }

    func testWorkflowAdviceIsExactTurnStandardOnlyProviderEvidence() throws {
        XCTAssertTrue(AgentBridge.turnScopedEventTypes.contains("workflow_advice_request"))
        XCTAssertTrue(AgentBridge.turnScopedEventTypes.contains("workflow_advice_ack"))
        XCTAssertTrue(AgentBridge.providerWorkEvidenceEventTypes.contains(
            "workflow_advice_request"))
        XCTAssertTrue(AgentBridge.providerWorkEvidenceEventTypes.contains(
            "workflow_advice_ack"))

        let source = try bridgeSource()
        let start = try XCTUnwrap(source.range(of: "private func applyWorkflowAdviceRequest("))
        let rest = source[start.lowerBound...]
        let end = try XCTUnwrap(rest.range(of:
            "\n    /// Commit a signed-Help audit row only after the exact workflow result"))
        let body = String(rest[..<end.lowerBound])

        XCTAssertTrue(body.contains(
            "let baseKeys: Set<String> = [\"type\", \"id\", \"reqId\", \"goal\"]"))
        XCTAssertTrue(body.contains("baseKeys.union([\"demonstrationID\"])"))
        XCTAssertTrue(body.contains("let demonstrationID = event[\"demonstrationID\"] as? String"))
        XCTAssertTrue(body.contains("requestID.utf8.prefix(257).count <= 256"))
        XCTAssertTrue(body.contains("goal.utf8.prefix(4 * 1_024 + 1).count <= 4 * 1_024"))
        XCTAssertTrue(body.contains("demonstrationID?.utf8.prefix(97).count"))
        XCTAssertTrue(body.contains("route.purpose == .conversation"))
        XCTAssertTrue(body.contains("route.toolProfile == .standard"))
        XCTAssertTrue(body.contains("let surfaceIdentity = route.toolSurfaceRoute"))
        XCTAssertTrue(body.contains("MechanicianHelpProviderRetrieval.shared.workflowMatches("))
        XCTAssertTrue(body.contains("demonstrationID: demonstrationID"))
        XCTAssertTrue(body.contains("current.toolSurfaceRoute == surfaceIdentity"))
        XCTAssertTrue(body.contains("snapshot.route == surfaceIdentity"))
        XCTAssertTrue(body.contains("snapshot.isActiveEvidence"))
        XCTAssertTrue(body.contains("pendingWorkflowAdviceReceipts.stage("))
        XCTAssertFalse(body.contains("currentConversation"))
        XCTAssertFalse(body.contains("currentID"))
    }

    func testWorkflowReceiptRegistryAndAcknowledgementCannotCrossReleaseSearch() throws {
        let source = try bridgeSource()
        XCTAssertTrue(source.contains(
            "PendingAcknowledgementRegistry<PendingWorkflowAdviceReceipt>()"))
        XCTAssertTrue(source.contains(
            "let toolSurfaceRoute: AgentToolSurfaceRoute"))
        let start = try XCTUnwrap(source.range(of:
            "private func applyWorkflowAdviceAcknowledgement("))
        let body = String(source[start.lowerBound...].prefix(2_400))
        XCTAssertTrue(body.contains("pendingWorkflowAdviceReceipts.take("))
        XCTAssertTrue(body.contains("requestID.utf8.prefix(257).count <= 256"))
        XCTAssertTrue(body.contains("pending.toolSurfaceRoute == route.toolSurfaceRoute"))
        XCTAssertTrue(body.contains("current.toolSurfaceRoute == pending.toolSurfaceRoute"))
        XCTAssertFalse(body.contains("pendingHelpConsultationReceipts.take("))
        XCTAssertTrue(source.contains("pendingWorkflowAdviceReceipts.removeAll()"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy:
                "pendingWorkflowAdviceReceipts.discard(turnID:").count - 1,
            3)
    }

    func testHelpSchemaBumpsOpaqueProviderSessions() throws {
        let source = try bridgeSource()
        XCTAssertTrue(source.contains("mechanician-anthropic-tools-v5-plan-help-surface"))
        XCTAssertTrue(source.contains("mechanician-codex-tools-v4-show-mechanician"))
        XCTAssertFalse(source.contains("mechanician-anthropic-tools-v4-show-mechanician"))
        XCTAssertFalse(source.contains("mechanician-anthropic-tools-v3-workflow-advice"))
        XCTAssertFalse(source.contains("mechanician-codex-tools-v3-workflow-advice"))
        XCTAssertFalse(source.contains("mechanician-anthropic-tools-v2-help-search"))
        XCTAssertFalse(source.contains("mechanician-codex-tools-v2-help-search"))
    }

    func testShowMechanicianStopAndTeardownCancelOnlyUnacknowledgedExactSessions() throws {
        let source = try bridgeSource()
        let requestStart = try XCTUnwrap(source.range(of:
            "private func applyShowMechanicianRequest("))
        let requestRest = source[requestStart.lowerBound...]
        let requestEnd = try XCTUnwrap(requestRest.range(of:
            "\n    /// Consume only the acknowledgement for the exact started session."))
        let requestBody = String(requestRest[..<requestEnd.lowerBound])
        XCTAssertTrue(requestBody.contains("!stopRequestedTurnIDs.contains(turnID)"))
        XCTAssertTrue(requestBody.contains("!self.stopRequestedTurnIDs.contains(turnID)"))
        XCTAssertTrue(requestBody.contains("Task { [weak self, source] in"))
        XCTAssertTrue(requestBody.contains("pendingShowMechanicianSessionTokens["))
        XCTAssertTrue(requestBody.contains("discardPendingShowMechanician("))

        let stopStart = try XCTUnwrap(source.range(of:
            "private func requestStop(turnID: String, route requestedRoute: TurnRoute)"))
        let stopBody = String(source[stopStart.lowerBound...].prefix(2_000))
        XCTAssertTrue(stopBody.contains("stopRequestedTurnIDs.insert(turnID).inserted"))
        XCTAssertTrue(stopBody.contains("discardPendingShowMechanician(turnID: turnID)"))

        let discardStart = try XCTUnwrap(source.range(of:
            "private func discardPendingShowMechanician("))
        let discardBody = String(source[discardStart.lowerBound...].prefix(2_100))
        XCTAssertTrue(discardBody.contains("key.turnID == turnID"))
        XCTAssertTrue(discardBody.contains("key.requestID == requestID"))
        XCTAssertTrue(discardBody.contains(
            "MechanicianGuidanceRouter.shared.cancel(sessionToken: $0)"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy:
                "discardPendingShowMechanician(turnID: turnID)").count - 1,
            3,
            "Stop, terminal completion, and lane teardown must share exact cancellation")
        XCTAssertTrue(source.contains("discardAllPendingShowMechanician()"))
    }

    func testBridgeUsesOnlyTheAppAuthorityAndStagesBeforeReturning() throws {
        let source = try bridgeSource()
        let start = try XCTUnwrap(source.range(of: "private func applyHelpSearchRequest("))
        let rest = source[start.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    /// Commit a concise audit row"))
        let body = String(rest[..<end.lowerBound])

        XCTAssertTrue(body.contains("route.toolProfile.permitsHelpSearch"))
        XCTAssertTrue(body.contains("currentRoute.toolProfile.permitsHelpSearch"))
        XCTAssertTrue(body.contains(
            "let baseKeys: Set<String> = [\"type\", \"id\", \"reqId\", \"query\"]"))
        XCTAssertTrue(body.contains("baseKeys.union([\"includeHistory\"])"))
        XCTAssertTrue(body.contains("requestID.utf8.prefix(257).count <= 256"))
        XCTAssertTrue(body.contains("MechanicianHelpProviderRetrieval.shared.search("))
        XCTAssertTrue(body.contains("pendingHelpConsultationReceipts.stage("))
        XCTAssertTrue(body.contains("guideAdmission: answer.guideAdmission"))
        XCTAssertTrue(body.contains("\"empty\": answer.empty"))
        XCTAssertTrue(body.contains("if !self.write(response, to: interaction)"))
        XCTAssertFalse(body.contains("MechanicianHelpStore("),
                       "the bridge must use the one strict provider retrieval authority")
        XCTAssertFalse(body.contains("discloseHelpConsultation("),
                       "a socket response is not provider acknowledgement")
    }

    func testOnlyTheExactAcknowledgementCommitsAndCleanupDiscardsTheRest() throws {
        let source = try bridgeSource()
        let start = try XCTUnwrap(source.range(of: "private func applyHelpSearchAcknowledgement("))
        let rest = source[start.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    /// Take a turn's offer"))
        let body = String(rest[..<end.lowerBound])

        XCTAssertTrue(body.contains("pendingHelpConsultationReceipts.take("))
        XCTAssertTrue(body.contains("pending.conversationID == route.conversationID"))
        XCTAssertTrue(body.contains("pending.selection == route.selection"))
        XCTAssertTrue(body.contains("pending.toolProfile == route.toolProfile"))
        XCTAssertTrue(body.contains("current.phase.isActive"))
        XCTAssertTrue(body.contains("!stopRequestedTurnIDs.contains(turnID)"))
        XCTAssertTrue(body.contains("routesMatch(current, route)"))
        XCTAssertTrue(body.contains("showMechanicianGuideAdmissions.acknowledge("))
        XCTAssertTrue(body.contains("discloseHelpConsultation("))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy:
                "pendingHelpConsultationReceipts.discard(turnID:").count - 1,
            3)
        XCTAssertTrue(source.contains(
            "self.pendingHelpConsultationReceipts.discard("),
            "a failed response write must discard its exact request")
        XCTAssertTrue(source.contains("pendingHelpConsultationReceipts.removeAll()"))
    }

    func testShowConsumesOnlyAnAcknowledgedExactTurnGuideAndBindsItsCorpus() throws {
        let source = try bridgeSource()
        let start = try XCTUnwrap(source.range(of: "private func applyShowMechanicianRequest("))
        let rest = source[start.lowerBound...]
        let end = try XCTUnwrap(rest.range(of:
            "\n    private func applyOperateMechanicianRequest("))
        let body = String(rest[..<end.lowerBound])

        XCTAssertTrue(body.contains("reserveShowMechanicianGuide("))
        XCTAssertTrue(body.contains("guideID: guideReservation.guideID"))
        XCTAssertTrue(body.contains(
            "corpusContentSHA256: guideReservation.corpusContentSHA256"))
        XCTAssertTrue(body.contains(
            "showMechanicianGuideAdmissions.isCurrent(guideReservation)"))
        XCTAssertTrue(body.contains("pending.guideReservation == guideReservation"))
        XCTAssertTrue(body.contains("showMechanicianGuideAdmissions.restore(guideReservation)"))
        XCTAssertFalse(body.contains("route.permissionMode != \"plan\""),
            "signed ShowMechanician presentation remains available in Plan")
        XCTAssertTrue(source.contains("showMechanicianGuideAdmissions.remove(turnID: turnID)"))
        XCTAssertTrue(source.contains("showMechanicianGuideAdmissions.remove(turnIDs: turnIDs)"))
        XCTAssertTrue(source.contains("showMechanicianGuideAdmissions.removeAll()"))
    }

    func testExactRegistryNeverCrossReleasesHelpReceipts() {
        let receipt = MechanicianHelpConsultationReceipt(
            corpusID: "mechanician.public",
            articleTitles: ["History"],
            claimCount: 1)
        var registry = PendingAcknowledgementRegistry<MechanicianHelpConsultationReceipt>()
        XCTAssertTrue(registry.stage(receipt, turnID: "turn-a", requestID: "help-1"))

        XCTAssertNil(registry.take(turnID: "turn-b", requestID: "help-1"))
        XCTAssertNil(registry.take(turnID: "turn-a", requestID: "help-2"))
        XCTAssertEqual(registry.take(turnID: "turn-a", requestID: "help-1"), receipt)
        XCTAssertNil(registry.take(turnID: "turn-a", requestID: "help-1"))
    }

    func testReceiptStaysAnOldCompatibleDurableSystemRow() throws {
        var receipt = TranscriptEntry(
            kind: .system,
            text: "Consulted Mechanician Help: History (1 signed claim).")
        receipt.helpConsultationReceipt = true
        receipt.helpConsultationCorpusID = "mechanician.public"
        receipt.helpConsultationClaimCount = 1
        receipt.helpConsultationTurnID = "turn-a"

        XCTAssertTrue(Conversation.isDurableMessage(receipt))
        XCTAssertTrue(AgentBridge.isDurableSystemTranscriptEntry(receipt))
        let decoded = try JSONDecoder().decode(
            TranscriptEntry.self,
            from: JSONEncoder().encode(receipt))
        XCTAssertEqual(decoded.kind, .system)
        XCTAssertEqual(decoded.helpConsultationCorpusID, "mechanician.public")

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt))
                as? [String: Any])
        for key in [
            "helpConsultationReceipt", "helpConsultationCorpusID",
            "helpConsultationClaimCount", "helpConsultationTurnID",
        ] {
            legacyObject.removeValue(forKey: key)
        }
        let legacy = try JSONDecoder().decode(
            TranscriptEntry.self,
            from: JSONSerialization.data(withJSONObject: legacyObject))
        XCTAssertNil(legacy.helpConsultationReceipt)
        XCTAssertEqual(legacy.kind, .system)
    }

    func testHelpReceiptDoesNotClaimProviderSystemContextWasOmitted() {
        var receipt = TranscriptEntry(
            kind: .system,
            text: "Consulted Mechanician Help: History (1 signed claim).")
        receipt.helpConsultationReceipt = true
        let helpOnly = conversation(messages: [receipt])
        let ordinarySystem = conversation(messages: [
            TranscriptEntry(kind: .system, text: "Provider context"),
        ])

        XCTAssertFalse(
            ReplayFidelityPlanner.plan(for: helpOnly).degradationCategories.contains(
                .systemContext))
        XCTAssertTrue(
            ReplayFidelityPlanner.plan(for: ordinarySystem).degradationCategories.contains(
                .systemContext))
    }

    private func bridgeSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Mechanician/AgentBridge.swift"),
            encoding: .utf8)
    }

    private func conversation(messages: [TranscriptEntry]) -> Conversation {
        Conversation(
            title: "Help receipt",
            cwd: "",
            sdkSessionId: nil,
            messages: messages,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100))
    }
}
