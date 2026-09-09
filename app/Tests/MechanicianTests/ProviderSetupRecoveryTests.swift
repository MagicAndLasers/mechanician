import XCTest
@testable import Mechanician

final class ProviderSetupRecoveryTests: XCTestCase {
    private let originID = UUID()
    private let original = ModelSelection(access: .anthropicAPI, modelID: "claude-opus-4-8")
    private let destination = ModelAccess.claudeSubscription

    private func conversation(
        id: UUID? = nil,
        selection: ModelSelection? = nil,
        hasDraft: Bool = true,
        hasSession: Bool = false,
        hasTranscript: Bool = false,
        queuedPromptCount: Int = 0,
        delegatedWorkCount: Int = 0,
        hasProviderAccessRequest: Bool = false,
        hasReservedTurn: Bool = false,
        hasArmedWait: Bool = false
    ) -> ProviderSetupRecovery.ConversationState {
        ProviderSetupRecovery.ConversationState(
            conversationID: id ?? originID,
            selection: selection ?? original,
            hasDraft: hasDraft,
            hasSession: hasSession,
            hasUserOrAssistantTranscript: hasTranscript,
            queuedPromptCount: queuedPromptCount,
            delegatedWorkCount: delegatedWorkCount,
            hasProviderAccessRequest: hasProviderAccessRequest,
            hasReservedTurn: hasReservedTurn,
            hasArmedWait: hasArmedWait)
    }

    private func entry(
        _ modelID: String,
        access: ModelAccess? = nil,
        isDefault: Bool = false
    ) -> ModelCatalogEntry {
        let access = access ?? destination
        return ModelCatalogEntry(
            selection: ModelSelection(access: access, modelID: modelID),
            displayName: modelID,
            description: "",
            resolvedModelID: nil,
            isDefault: isDefault,
            supportedEfforts: [],
            capabilities: [])
    }

    private func catalog(
        phase: ModelCatalogSnapshot.Phase = .ready,
        epoch: Int = 7,
        currentEpoch: Int = 7,
        access: ModelAccess? = nil,
        entries: [ModelCatalogEntry]? = nil
    ) -> ProviderSetupRecovery.CatalogEvidence {
        ProviderSetupRecovery.CatalogEvidence(
            access: access ?? destination,
            snapshot: ModelCatalogSnapshot(
                phase: phase,
                entries: entries ?? [
                    entry("claude-sonnet-4-8"),
                    entry("claude-opus-4-8", isDefault: true),
                ],
                credentialEpoch: epoch,
                updatedAt: Date()),
            currentCredentialEpoch: currentEpoch)
    }

    private func verifiedRecovery(epoch: Int = 7) -> ProviderSetupRecovery {
        var recovery = ProviderSetupRecovery()
        recovery.begin(originConversationID: originID, originalSelection: original)
        XCTAssertTrue(recovery.bind(destination: destination))
        XCTAssertTrue(recovery.markVerifiedSuccess(for: destination, credentialEpoch: epoch))
        return recovery
    }

    func testRuntimeEvidenceDistinguishesWaitingVerifiedAndTerminalRejection() {
        XCTAssertEqual(
            ProviderSetupRecovery.runtimeEvidence(
                accountOperationInFlight: true,
                runtimeIsReady: true,
                runtimeIsUsable: false),
            .waiting)
        XCTAssertEqual(
            ProviderSetupRecovery.runtimeEvidence(
                accountOperationInFlight: false,
                runtimeIsReady: false,
                runtimeIsUsable: false),
            .waiting)
        XCTAssertEqual(
            ProviderSetupRecovery.runtimeEvidence(
                accountOperationInFlight: false,
                runtimeIsReady: true,
                runtimeIsUsable: true),
            .verified)
        XCTAssertEqual(
            ProviderSetupRecovery.runtimeEvidence(
                accountOperationInFlight: false,
                runtimeIsReady: true,
                runtimeIsUsable: false),
            .rejected)
    }

    func testGenericProvidersWithoutBannerIntentHasNoRoutingAuthority() {
        var recovery = ProviderSetupRecovery()

        XCTAssertFalse(recovery.bind(destination: destination))
        XCTAssertFalse(recovery.markVerifiedSuccess(for: destination, credentialEpoch: 7))
        XCTAssertNil(recovery.resolveIfReady(current: conversation(), catalog: catalog()))
        XCTAssertFalse(recovery.isPending)
    }

    func testVerifiedSuccessAndCurrentAuthoritativeCatalogResolveOnceToDefault() {
        var recovery = verifiedRecovery()

        XCTAssertEqual(
            recovery.resolveIfReady(current: conversation(), catalog: catalog()),
            ModelSelection(access: destination, modelID: "claude-opus-4-8"))
        XCTAssertFalse(recovery.isPending)
        XCTAssertNil(recovery.resolveIfReady(current: conversation(), catalog: catalog()))
    }

    func testDraftAndEstablishedIdleHistoryDoNotBlockExplicitRecovery() {
        for state in [
            conversation(hasDraft: true),
            conversation(hasSession: true),
            conversation(hasTranscript: true),
            conversation(hasDraft: true, hasSession: true, hasTranscript: true),
        ] {
            var recovery = verifiedRecovery()
            XCTAssertNotNil(recovery.resolveIfReady(current: state, catalog: catalog()))
        }
    }

    func testAccountSuccessAndCatalogMayArriveInEitherOrder() {
        var catalogFirst = ProviderSetupRecovery()
        catalogFirst.begin(originConversationID: originID, originalSelection: original)
        XCTAssertTrue(catalogFirst.bind(destination: destination))
        XCTAssertNil(catalogFirst.resolveIfReady(current: conversation(), catalog: catalog()))
        XCTAssertTrue(catalogFirst.isPending)
        XCTAssertTrue(catalogFirst.markVerifiedSuccess(for: destination, credentialEpoch: 7))
        XCTAssertNotNil(catalogFirst.resolveIfReady(current: conversation(), catalog: catalog()))

        var successFirst = verifiedRecovery()
        XCTAssertNil(successFirst.resolveIfReady(current: conversation(), catalog: nil))
        XCTAssertTrue(successFirst.isPending)
        XCTAssertNotNil(successFirst.resolveIfReady(current: conversation(), catalog: catalog()))
    }

    func testRecoveredOriginalRouteCompletesWithoutChangingItsModelOrWaitingForCatalog() {
        var recovery = ProviderSetupRecovery()
        recovery.begin(originConversationID: originID, originalSelection: original)
        XCTAssertTrue(recovery.bind(destination: original.access))
        XCTAssertTrue(recovery.markVerifiedSuccess(
            for: original.access,
            credentialEpoch: 7))

        XCTAssertTrue(recovery.completeOriginalRouteIfReady(
            current: conversation(hasSession: true, hasTranscript: true),
            usableAccess: original.access,
            currentCredentialEpoch: 7))
        XCTAssertFalse(recovery.isPending)
    }

    func testOriginalRouteCompletionRejectsWrongEpochAndUnsafeWork() {
        for (state, epoch) in [
            (conversation(), 8),
            (conversation(queuedPromptCount: 1), 7),
        ] {
            var recovery = ProviderSetupRecovery()
            recovery.begin(originConversationID: originID, originalSelection: original)
            XCTAssertTrue(recovery.bind(destination: original.access))
            XCTAssertTrue(recovery.markVerifiedSuccess(
                for: original.access,
                credentialEpoch: 7))

            XCTAssertFalse(recovery.completeOriginalRouteIfReady(
                current: state,
                usableAccess: original.access,
                currentCredentialEpoch: epoch))
        }
    }

    func testNonAuthoritativeOrWrongEpochCatalogCannotResolve() {
        for evidence in [
            catalog(phase: .loading),
            catalog(phase: .failed("offline")),
            catalog(epoch: 6, currentEpoch: 7),
            catalog(epoch: 7, currentEpoch: 8),
        ] {
            var recovery = verifiedRecovery()
            XCTAssertNil(recovery.resolveIfReady(
                current: conversation(),
                catalog: evidence))
            XCTAssertTrue(recovery.isPending)
        }
    }

    func testWrongDestinationEvidenceCannotResolve() {
        var recovery = verifiedRecovery()

        XCTAssertFalse(recovery.markVerifiedSuccess(for: .codexSubscription, credentialEpoch: 7))
        XCTAssertNil(recovery.resolveIfReady(
            current: conversation(),
            catalog: catalog(
                access: .codexSubscription,
                entries: [entry(
                    "gpt-5.6",
                    access: .codexSubscription,
                    isDefault: true)])))
        XCTAssertTrue(recovery.isPending)
    }

    func testUnsafeConversationWorkStatesCancelRecovery() {
        let blockedStates = [
            conversation(queuedPromptCount: 1),
            conversation(delegatedWorkCount: 1),
            conversation(hasProviderAccessRequest: true),
            conversation(hasReservedTurn: true),
            conversation(hasArmedWait: true),
        ]

        for state in blockedStates {
            var recovery = verifiedRecovery()
            XCTAssertNil(recovery.resolveIfReady(current: state, catalog: catalog()))
            XCTAssertFalse(recovery.isPending)
        }
    }

    func testManualConversationOrRouteChangeCancelsRecovery() {
        let changedStates = [
            conversation(id: UUID()),
            conversation(selection: ModelSelection(
                access: .claudeSubscription,
                modelID: "claude-opus-4-8")),
        ]

        for state in changedStates {
            var recovery = verifiedRecovery()
            XCTAssertNil(recovery.resolveIfReady(current: state, catalog: catalog()))
            XCTAssertFalse(recovery.isPending)
        }
    }

    func testCatalogUsesOnlyDestinationRowsAndFallsBackToFirstWhenNoDefaultExists() {
        var recovery = verifiedRecovery()
        let evidence = catalog(entries: [
            entry("gpt-5.6", access: .codexSubscription, isDefault: true),
            entry("claude-sonnet-4-8"),
            entry("claude-opus-4-8"),
        ])

        XCTAssertEqual(
            recovery.resolveIfReady(current: conversation(), catalog: evidence),
            ModelSelection(access: destination, modelID: "claude-sonnet-4-8"))
    }
}
