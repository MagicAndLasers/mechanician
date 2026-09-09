import XCTest
@testable import Mechanician

final class ConversationControlPickerTests: XCTestCase {
    func testAcceptedModelSelectionExclusivelyOwnsDismissalInterval() {
        XCTAssertTrue(DeferredModelSelectionOwnership.canAccept(
            hasPendingSelection: false,
            hasDeferredTask: false,
            isPresented: true))
        XCTAssertFalse(DeferredModelSelectionOwnership.canAccept(
            hasPendingSelection: true,
            hasDeferredTask: true,
            isPresented: false))
        XCTAssertFalse(DeferredModelSelectionOwnership.canAccept(
            hasPendingSelection: true,
            hasDeferredTask: true,
            isPresented: true))
        XCTAssertFalse(DeferredModelSelectionOwnership.canAccept(
            hasPendingSelection: false,
            hasDeferredTask: false,
            isPresented: false))
    }

    func testDeferredModelSelectionStaysBoundToItsOriginatingContext() {
        let bridgeID = UUID()
        let conversationID = UUID()
        let workspace = NSObject()
        let otherWorkspace = NSObject()
        let context = DeferredModelSelectionContext(
            bridgeID: bridgeID,
            conversationID: conversationID,
            workspaceWindowID: ObjectIdentifier(workspace))

        XCTAssertTrue(context.matches(
            bridgeID: bridgeID,
            conversationID: conversationID,
            workspaceWindowID: ObjectIdentifier(workspace)))
        XCTAssertFalse(context.matches(
            bridgeID: bridgeID,
            conversationID: UUID(),
            workspaceWindowID: ObjectIdentifier(workspace)))
        XCTAssertFalse(context.matches(
            bridgeID: bridgeID,
            conversationID: conversationID,
            workspaceWindowID: ObjectIdentifier(otherWorkspace)))
        XCTAssertFalse(context.matches(
            bridgeID: UUID(),
            conversationID: conversationID,
            workspaceWindowID: ObjectIdentifier(workspace)))

        let emptyWorkspaceContext = DeferredModelSelectionContext(
            bridgeID: bridgeID,
            conversationID: nil,
            workspaceWindowID: ObjectIdentifier(workspace))
        XCTAssertTrue(emptyWorkspaceContext.matches(
            bridgeID: bridgeID,
            conversationID: nil,
            workspaceWindowID: ObjectIdentifier(workspace)))
        XCTAssertFalse(emptyWorkspaceContext.matches(
            bridgeID: bridgeID,
            conversationID: conversationID,
            workspaceWindowID: ObjectIdentifier(workspace)))
    }

    func testAccessChangeBlockerProjectionIsConversationWorkFirst() {
        XCTAssertEqual(
            ConversationAccessChangeBlocker.project(
                hasReservedTurn: true,
                delegatedWorkCount: 2,
                hasProviderAccessRequest: true,
                queuedPromptCount: 3,
                hasArmedWait: true),
            .reservedTurn)
        XCTAssertEqual(
            ConversationAccessChangeBlocker.project(
                hasReservedTurn: false,
                delegatedWorkCount: 2,
                hasProviderAccessRequest: true,
                queuedPromptCount: 3,
                hasArmedWait: true),
            .delegatedWork(count: 2))
        XCTAssertEqual(
            ConversationAccessChangeBlocker.project(
                hasReservedTurn: false,
                delegatedWorkCount: 0,
                hasProviderAccessRequest: false,
                queuedPromptCount: 3,
                hasArmedWait: true),
            .queuedPrompts(count: 3))
    }

    func testDelegatedWorkBlockerIsActionableAndUsesAgentCount() {
        let one = ConversationAccessChangeBlocker.delegatedWork(count: 1)
        let many = ConversationAccessChangeBlocker.delegatedWork(count: 4)

        XCTAssertEqual(one.pickerTitle, "1 active agent")
        XCTAssertEqual(many.pickerTitle, "4 active agents")
        XCTAssertTrue(one.canStopActiveWork)
        XCTAssertFalse(ConversationAccessChangeBlocker.armedWait.canStopActiveWork)
    }

    @MainActor
    func testRepeatedBlockedSelectionNoticeDoesNotDuplicateAdjacentSystemRow() {
        let message = ConversationAccessChangeBlocker.delegatedWork(count: 1).notice
        let previous = TranscriptEntry(kind: .system, text: message)

        XCTAssertFalse(AgentBridge.shouldAppendSystemNotice(message, after: previous))
        XCTAssertTrue(AgentBridge.shouldAppendSystemNotice(
            message,
            after: TranscriptEntry(kind: .assistant, text: "Different row")))
        XCTAssertTrue(AgentBridge.shouldAppendSystemNotice(
            "A different notice",
            after: previous))
    }

    func testPopoverPinsTriggerTitleUntilDismissalCleanup() {
        var state = ConversationControlPopoverState()

        XCTAssertEqual(state.triggerTitle(current: "Extra High", compact: false), "Extra High")
        let generation = state.present(title: "Extra High")

        // Catalog/loading or selection publication may change the current label. The visible
        // trigger remains the same width until AppKit has dismissed the anchored popover.
        XCTAssertEqual(state.triggerTitle(current: "Effort", compact: false), "Extra High")
        XCTAssertEqual(state.triggerTitle(current: "Low", compact: true), "")

        XCTAssertEqual(state.dismiss(), generation)
        XCTAssertTrue(state.clearPin(for: generation))
        XCTAssertEqual(state.triggerTitle(current: "Low", compact: false), "Low")
    }

    func testDelayedCleanupCannotClearANewerPresentation() {
        var state = ConversationControlPopoverState()
        let first = state.present(title: "High")
        _ = state.dismiss()
        let second = state.present(title: "Max")

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(state.clearPin(for: first))
        XCTAssertEqual(state.triggerTitle(current: "Low", compact: false), "Max")
        XCTAssertTrue(state.isPresented)
    }

    func testModelTitleStaysPinnedAcrossDeferredProviderSelection() {
        var state = ConversationControlPopoverState()
        let generation = state.present(title: "Claude Opus 4.8")

        XCTAssertEqual(state.dismiss(), generation)

        // A provider change publishes a different model title before AppKit has necessarily
        // finished dismissing the old popover. Keep the old anchor geometry until cleanup.
        XCTAssertEqual(
            state.triggerTitle(current: "GPT-5.6", compact: false),
            "Claude Opus 4.8")
        XCTAssertTrue(state.clearPin(for: generation))
        XCTAssertEqual(state.triggerTitle(current: "GPT-5.6", compact: false), "GPT-5.6")
    }

    func testModelSelectionRetiresPopoverBeforeProviderPublication() {
        var state = ConversationControlPopoverState()
        let generation = state.present(title: "Claude Opus 4.8")
        var wasPresentedWhenProviderPublished: Bool?

        XCTAssertEqual(state.retireBeforeWindowOrderSensitiveMutation(), generation)
        wasPresentedWhenProviderPublished = state.isPresented

        XCTAssertEqual(wasPresentedWhenProviderPublished, false)
        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(
            state.triggerTitle(current: "GPT-5.6", compact: false),
            "Claude Opus 4.8")
        XCTAssertTrue(state.clearPin(for: generation))
    }

    func testDeclarationOnlyEffortCatalogRequestsProviderRefresh() {
        XCTAssertTrue(ConversationEffortCatalogPolicy.shouldRequestProviderRefresh(
            reportedEfforts: [],
            hasProviderCatalog: false))
    }

    func testReportedEffortChoicesDoNotRequestProviderRefresh() {
        XCTAssertFalse(ConversationEffortCatalogPolicy.shouldRequestProviderRefresh(
            reportedEfforts: ["low", "medium", "high"],
            hasProviderCatalog: false))
    }

    func testAuthoritativeProviderCatalogWithoutEffortsDoesNotRefreshAgain() {
        XCTAssertFalse(ConversationEffortCatalogPolicy.shouldRequestProviderRefresh(
            reportedEfforts: [],
            hasProviderCatalog: true))
    }

    @MainActor
    func testEveryEffortLevelHasUsefulPickerCopy() {
        let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        for effort in efforts {
            let detail = AgentBridge.effortDescription(effort, access: .codexSubscription)
            XCTAssertFalse(detail.isEmpty, "Missing description for \(effort)")
            XCTAssertFalse(detail.contains("reported by"), "Fallback description used for \(effort)")
        }
        XCTAssertTrue(
            AgentBridge.effortDescription("ultra", access: .codexSubscription).contains("Ultra"))
        XCTAssertTrue(
            AgentBridge.effortDescription("low", access: .codexSubscription).contains("Light"))
    }
}
