import XCTest
@testable import Mechanician

final class ProviderAccessRequestTests: XCTestCase {
    private func conversation(
        request: ProviderAccessRequest? = nil,
        modelSelection: ModelSelection? = ModelSelection(
            access: .claudeSubscription,
            modelID: "claude-existing"),
        queuedPrompts: [String] = ["already queued"]
    ) -> Conversation {
        Conversation(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            title: "Provider request fixture",
            cwd: "/tmp/provider-request-fixture",
            sdkSessionId: "existing-session",
            modelSelection: modelSelection,
            messages: [
                TranscriptEntry(kind: .user, text: "Original request"),
                TranscriptEntry(kind: .assistant, text: "Original response"),
            ],
            updatedAt: Date(timeIntervalSinceReferenceDate: 1234),
            queuedPrompts: queuedPrompts,
            draft: "Unsent draft",
            favorite: true,
            sortIndex: 4,
            unread: true,
            errored: true,
            projectID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
            contextTokens: 1200,
            contextWindow: 200_000,
            contextModel: "claude-existing",
            providerAccessRequest: request)
    }

    private func request(
        id: UUID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
        maker: ModelMaker = .openAI,
        selectedAccess: ModelAccess? = nil,
        recoveryAccess: ModelAccess? = nil,
        recoveryPromptEntryID: UUID? = nil
    ) -> ProviderAccessRequest {
        ProviderAccessRequest(
            id: id,
            maker: maker,
            reason: "Use the requested provider for a bounded task.",
            resumePrompts: ["First resumed task", "Second resumed task"],
            requestedAt: Date(timeIntervalSinceReferenceDate: 5678),
            selectedAccess: selectedAccess,
            recoveryAccess: recoveryAccess,
            recoveryPromptEntryID: recoveryPromptEntryID)
    }

    func testBlockedVertexQueueExplainsGoogleReauthentication() {
        XCTAssertEqual(
            ProviderAccessRequest.blockedQueueReason(
                for: .claudeVertex,
                requiresReconnect: true),
            "Reauthenticate with Google before Mechanician can send this preserved work through Google Vertex.")
        XCTAssertEqual(
            ProviderAccessRequest.blockedQueueReason(
                for: .claudeVertex,
                requiresReconnect: false),
            "Continue work waiting for \(ModelAccess.claudeVertex.displayName).")
    }

    func testOnlyAccountDisconnectingAuthenticationFailurePreselectsRecoveryRoute() throws {
        let vertex = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "authentication",
            "provider": "anthropic",
            "access": "claude_vertex",
            "message": "Google requires a fresh sign-in.",
            "reconnectRequired": true,
        ], authoritativeAccess: .claudeVertex))
        let api = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "authentication",
            "provider": "anthropic",
            "access": "anthropic_api",
            "message": "The API credential was rejected.",
        ], authoritativeAccess: .anthropicAPI))

        XCTAssertEqual(
            ProviderAccessRequest.automaticRecoverySelection(
                for: vertex,
                failedAccess: .claudeVertex),
            .claudeVertex)
        XCTAssertNil(ProviderAccessRequest.automaticRecoverySelection(
            for: api,
            failedAccess: .anthropicAPI))
        XCTAssertNil(ProviderAccessRequest.automaticRecoverySelection(
            for: vertex,
            failedAccess: .claudeSubscription))
    }

    func testRejectedVertexQueueMovesIntoDurableRequestExactlyOnce() throws {
        var value = conversation(
            modelSelection: ModelSelection(
                access: .claudeVertex,
                modelID: "claude-managed"),
            queuedPrompts: ["First preserved prompt", "First preserved prompt"])

        XCTAssertTrue(value.preserveQueuedPromptsForProviderAccess(
            access: .claudeVertex,
            requiresReconnect: true))
        let parked = try XCTUnwrap(value.providerAccessRequest)
        XCTAssertEqual(parked.maker, .anthropic)
        XCTAssertEqual(
            parked.reason,
            "Reauthenticate with Google before Mechanician can send this preserved work through Google Vertex.")
        XCTAssertEqual(
            parked.resumePrompts,
            ["First preserved prompt", "First preserved prompt"],
            "equal queue items remain two intentional submissions")
        XCTAssertEqual(
            parked.selectedAccess,
            .claudeVertex,
            "work rejected on a user-selected lane must remain bound to that exact recovery route")
        XCTAssertTrue(value.queuedPrompts.isEmpty)

        XCTAssertFalse(value.preserveQueuedPromptsForProviderAccess(
            access: .claudeVertex,
            requiresReconnect: true))
        XCTAssertEqual(value.providerAccessRequest, parked)
    }

    func testNewQueueAppendsOnceToMatchingProviderRequest() {
        let existing = ProviderAccessRequest(
            maker: .anthropic,
            reason: "Existing Anthropic access request",
            resumePrompts: ["Earlier work"])
        var value = conversation(
            request: existing,
            queuedPrompts: ["New work", "New work"])

        XCTAssertTrue(value.preserveQueuedPromptsForProviderAccess(
            access: .claudeVertex,
            requiresReconnect: true))
        XCTAssertEqual(
            value.providerAccessRequest?.resumePrompts,
            ["Earlier work", "New work", "New work"])
        XCTAssertNil(
            value.providerAccessRequest?.selectedAccess,
            "parking lane work must not choose credentials for an earlier agent-owned request")
        XCTAssertTrue(value.queuedPrompts.isEmpty)
        XCTAssertFalse(value.preserveQueuedPromptsForProviderAccess(
            access: .claudeVertex,
            requiresReconnect: true))
    }

    func testAuthenticationRecoveryDoesNotMergeIntoExistingGenericRequest() {
        let existing = ProviderAccessRequest(
            maker: .anthropic,
            reason: "Earlier agent-owned Anthropic request",
            resumePrompts: ["Earlier work"])
        var value = conversation(request: existing, queuedPrompts: [])
        let rejectedEntryID = UUID()

        XCTAssertNil(value.stageProviderAccessRequest(
            maker: .anthropic,
            reason: "Google sign-in is required.",
            resumePrompts: ["Do not merge this failed turn"],
            selectedAccess: .claudeVertex,
            recoveryAccess: .claudeVertex,
            recoveryPromptEntryID: rejectedEntryID))
        XCTAssertEqual(value.providerAccessRequest, existing)
        XCTAssertFalse(
            value.providerAccessRequest?.resumePrompts.contains(
                "Do not merge this failed turn") == true)
        XCTAssertNil(value.providerAccessRequest?.selectedAccess)
        XCTAssertNil(value.providerAccessRequest?.recoveryPromptEntryID)
    }

    func testCrossFamilyProviderRequestLeavesQueueUntouched() {
        let existing = request(maker: .openAI)
        var value = conversation(request: existing, queuedPrompts: ["Anthropic work"])

        XCTAssertFalse(value.preserveQueuedPromptsForProviderAccess(
            access: .claudeVertex,
            requiresReconnect: true))
        XCTAssertEqual(value.providerAccessRequest, existing)
        XCTAssertEqual(value.queuedPrompts, ["Anthropic work"])
    }

    func testLegacyConversationJSONWithoutProviderRequestDecodes() throws {
        let encoder = JSONEncoder()
        var encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(conversation(
                request: request()))) as? [String: Any])
        XCTAssertNotNil(encoded.removeValue(forKey: "providerAccessRequest"))

        let legacyData = try JSONSerialization.data(withJSONObject: encoded)
        let decoded = try JSONDecoder().decode(Conversation.self, from: legacyData)

        XCTAssertNil(decoded.providerAccessRequest)
        XCTAssertEqual(decoded.modelSelection, ModelSelection(
            access: .claudeSubscription,
            modelID: "claude-existing"))
        XCTAssertEqual(decoded.queuedPrompts, ["already queued"])
        XCTAssertEqual(decoded.messages.map(\.text), ["Original request", "Original response"])
    }

    func testProviderRequestAndSelectedRouteRoundTripAcrossRelaunch() throws {
        let recoveryPromptEntryID = UUID(
            uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!
        let expectedRequest = request(
            selectedAccess: .codexSubscription,
            recoveryAccess: .codexSubscription,
            recoveryPromptEntryID: recoveryPromptEntryID)
        let original = conversation(request: expectedRequest)

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Conversation.self, from: data)

        XCTAssertEqual(restored.providerAccessRequest, expectedRequest)
        XCTAssertEqual(restored.providerAccessRequest?.selectedAccess, .codexSubscription)
        XCTAssertEqual(
            restored.providerAccessRequest?.recoveryPromptEntryID,
            recoveryPromptEntryID)
        XCTAssertEqual(restored.modelSelection, original.modelSelection)
        XCTAssertEqual(restored.sdkSessionId, original.sdkSessionId)
        XCTAssertEqual(restored.queuedPrompts, original.queuedPrompts)
    }

    func testValidRouteSelectionPersistsIntentWithoutMovingWork() {
        let expectedRequest = request(maker: .anthropic)
        for access in [ModelAccess.claudeSubscription, .anthropicAPI] {
            var value = conversation(request: expectedRequest)

            XCTAssertTrue(value.selectProviderAccess(access, requestID: expectedRequest.id))
            XCTAssertEqual(value.providerAccessRequest?.selectedAccess, access)
            XCTAssertEqual(value.providerAccessRequest?.resumePrompts, expectedRequest.resumePrompts)
            XCTAssertEqual(value.queuedPrompts, ["already queued"])
            XCTAssertEqual(value.modelSelection?.access, .claudeSubscription)
            XCTAssertEqual(value.sdkSessionId, "existing-session")
        }
        XCTAssertEqual(expectedRequest.eligibleAccesses, [.claudeSubscription, .anthropicAPI])
    }

    func testCrossFamilyAndWrongIDSelectionFailClosed() {
        let expectedRequest = request(maker: .openAI)
        var value = conversation(request: expectedRequest)

        XCTAssertFalse(value.selectProviderAccess(
            .claudeSubscription,
            requestID: expectedRequest.id))
        XCTAssertFalse(value.selectProviderAccess(
            .codexSubscription,
            requestID: UUID()))

        XCTAssertEqual(value.providerAccessRequest, expectedRequest)
        XCTAssertEqual(value.modelSelection?.access, .claudeSubscription)
        XCTAssertEqual(value.sdkSessionId, "existing-session")
        XCTAssertEqual(value.queuedPrompts, ["already queued"])
    }

    func testFulfillmentTransfersPromptsExactlyOnce() {
        let expectedRequest = request(selectedAccess: .codexSubscription)
        var value = conversation(request: expectedRequest)
        value.sdkSessionRouteIdentity = "old-route"
        value.sdkSessionExtensionRevision = UUID()
        value.sdkSessionToolProfile = .helpExpert
        value.sdkSessionWorkspaceInstructionsRevision = "old-instructions"
        value.claudeEffectiveModel = "claude-old-effective"

        XCTAssertFalse(value.fulfillProviderAccess(
            requestID: expectedRequest.id,
            access: .codexSubscription,
            modelID: "gpt-selected"),
            "Messages already queued for the old route must run before provider transfer")
        XCTAssertEqual(value.queuedPrompts, ["already queued"])
        XCTAssertEqual(value.providerAccessRequest, expectedRequest)
        XCTAssertNotNil(value.sdkSessionExtensionRevision)
        XCTAssertEqual(value.sdkSessionToolProfile, .helpExpert)

        value.queuedPrompts.removeAll()
        XCTAssertTrue(value.fulfillProviderAccess(
            requestID: expectedRequest.id,
            access: .codexSubscription,
            modelID: "gpt-selected"))
        XCTAssertNil(value.providerAccessRequest)
        XCTAssertEqual(value.modelSelection, ModelSelection(
            access: .codexSubscription,
            modelID: "gpt-selected"))
        XCTAssertNil(value.sdkSessionId)
        XCTAssertNil(value.sdkSessionRouteIdentity)
        XCTAssertNil(value.sdkSessionExtensionRevision)
        XCTAssertNil(value.sdkSessionToolProfile)
        XCTAssertNil(value.sdkSessionWorkspaceInstructionsRevision)
        XCTAssertNil(value.claudeEffectiveModel)
        XCTAssertNil(value.contextTokens)
        XCTAssertNil(value.contextWindow)
        XCTAssertNil(value.contextModel)
        XCTAssertEqual(value.queuedPrompts, ["First resumed task", "Second resumed task"])
        XCTAssertFalse(value.errored)

        XCTAssertFalse(value.fulfillProviderAccess(
            requestID: expectedRequest.id,
            access: .codexSubscription,
            modelID: "gpt-selected"))
        XCTAssertEqual(value.queuedPrompts, ["First resumed task", "Second resumed task"])
    }

    func testAuthenticationRecoveryRewindsRejectedRootBeforeQueueingItOnce() throws {
        let priorUser = TranscriptEntry(kind: .user, text: "Earlier request")
        let priorAssistant = TranscriptEntry(kind: .assistant, text: "Earlier response")
        let rejected = TranscriptEntry(kind: .user, text: "Preserve this authentication prompt")
        var notice = TranscriptEntry(kind: .system, text: "Checking account credentials.")
        notice.providerFailure = nil
        var failure = TranscriptEntry(kind: .system, text: "Sign-in required")
        failure.providerFailure = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "authentication",
            "provider": "anthropic",
            "access": "claude_subscription",
            "message": "Claude requires a fresh sign-in.",
            "reconnectRequired": true,
        ], authoritativeAccess: .claudeSubscription))
        failure.providerFailurePromptID = rejected.id
        let accessRequest = ProviderAccessRequest(
            maker: .anthropic,
            reason: "Claude requires a fresh sign-in.",
            resumePrompts: [rejected.text],
            selectedAccess: .claudeSubscription,
            recoveryAccess: .claudeSubscription,
            recoveryPromptEntryID: rejected.id)
        XCTAssertEqual(failure.kind, .system)
        XCTAssertEqual(failure.providerFailure?.kind, .authentication)
        XCTAssertEqual(failure.providerFailure?.access, .claudeSubscription)
        XCTAssertEqual(failure.providerFailurePromptID, rejected.id)
        XCTAssertEqual(notice.kind, .system)
        XCTAssertNil(notice.providerFailure)
        XCTAssertNil(notice.refusal)
        XCTAssertNil(notice.usageLimit)
        var value = conversation(
            request: accessRequest,
            modelSelection: ModelSelection(
                access: .claudeSubscription,
                modelID: "claude-managed"),
            queuedPrompts: [])
        value.messages = [priorUser, priorAssistant, rejected, notice, failure]

        XCTAssertTrue(value.fulfillProviderAccess(
            requestID: accessRequest.id,
            access: .claudeSubscription,
            modelID: "claude-managed"))
        XCTAssertEqual(value.messages.map(\.id), [priorUser.id, priorAssistant.id])
        XCTAssertEqual(value.queuedPrompts, [rejected.text])
        XCTAssertNil(value.providerAccessRequest)
        XCTAssertFalse(value.errored)

        XCTAssertFalse(value.fulfillProviderAccess(
            requestID: accessRequest.id,
            access: .claudeSubscription,
            modelID: "claude-managed"))
        XCTAssertEqual(value.queuedPrompts, [rejected.text])
    }

    func testAuthenticationRecoveryRequestStaysBoundToRejectedRoute() {
        let rejectedEntryID = UUID()
        let accessRequest = ProviderAccessRequest(
            maker: .anthropic,
            reason: "Google sign-in is required.",
            resumePrompts: ["Retry this on Vertex"],
            selectedAccess: .claudeVertex,
            recoveryAccess: .claudeVertex,
            recoveryPromptEntryID: rejectedEntryID)
        var value = conversation(request: accessRequest, queuedPrompts: [])

        XCTAssertEqual(accessRequest.eligibleAccesses, [.claudeVertex])
        XCTAssertTrue(accessRequest.accepts(.claudeVertex))
        XCTAssertFalse(accessRequest.accepts(.anthropicAPI))
        XCTAssertFalse(value.selectProviderAccess(
            .anthropicAPI,
            requestID: accessRequest.id))
        XCTAssertEqual(value.providerAccessRequest, accessRequest)
        XCTAssertFalse(value.fulfillProviderAccess(
            requestID: accessRequest.id,
            access: .anthropicAPI,
            modelID: "claude-api"))
        XCTAssertEqual(value.providerAccessRequest, accessRequest)
    }

    func testUnselectedAPIRecoveryCanChooseAnotherRouteAndRewindFailedLane() throws {
        var priorUser = TranscriptEntry(kind: .user, text: "Earlier user context")
        priorUser.captureOrdinal = 1
        var priorAssistant = TranscriptEntry(kind: .assistant, text: "API-only provider reply")
        priorAssistant.captureOrdinal = 2
        let rejected = TranscriptEntry(kind: .user, text: "Retry this API prompt once")
        var failure = TranscriptEntry(kind: .system, text: "API authentication failed")
        failure.providerFailure = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "authentication",
            "provider": "anthropic",
            "access": "anthropic_api",
            "message": "The API credential was rejected.",
        ], authoritativeAccess: .anthropicAPI))
        failure.providerFailurePromptID = rejected.id
        let accessRequest = ProviderAccessRequest(
            maker: .anthropic,
            reason: "Choose a working Anthropic route.",
            resumePrompts: [rejected.text],
            selectedAccess: nil,
            recoveryAccess: .anthropicAPI,
            recoveryPromptEntryID: rejected.id)
        var value = conversation(request: accessRequest, queuedPrompts: ["Run this second"])
        value.messages = [priorUser, priorAssistant, rejected, failure]
        value.modelSelection = ModelSelection(
            access: .anthropicAPI,
            modelID: "claude-api")
        value.captureOrdinalHighWatermark = 4

        XCTAssertEqual(
            accessRequest.eligibleAccesses,
            [.claudeSubscription, .anthropicAPI])
        XCTAssertTrue(accessRequest.hasAuthenticationRecovery)
        XCTAssertTrue(value.selectProviderAccess(
            .claudeSubscription,
            requestID: accessRequest.id))
        XCTAssertTrue(value.fulfillProviderAccess(
            requestID: accessRequest.id,
            access: .claudeSubscription,
            modelID: "claude-subscription"))
        XCTAssertEqual(value.messages.map(\.id), [priorUser.id, priorAssistant.id])
        XCTAssertEqual(value.queuedPrompts, [rejected.text, "Run this second"])
        XCTAssertNil(value.providerAccessRequest)
        XCTAssertEqual(value.providerHistoryReplayCutoffOrdinal, 4)
        XCTAssertEqual(
            AgentBridge.providerHistoryEntriesForReplay(
                value.messages,
                cutoffOrdinal: value.providerHistoryReplayCutoffOrdinal).map(\.id),
            [priorUser.id])
    }

    func testAuthenticationRecoveryRefusesToRewindProviderWork() throws {
        let rejected = TranscriptEntry(kind: .user, text: "Do this once")
        let assistant = TranscriptEntry(kind: .assistant, text: "Provider output")
        var failure = TranscriptEntry(kind: .system, text: "Google sign-in required")
        failure.providerFailure = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "authentication",
            "provider": "anthropic",
            "access": "claude_subscription",
            "message": "Claude requires a fresh sign-in.",
            "reconnectRequired": true,
        ], authoritativeAccess: .claudeSubscription))
        failure.providerFailurePromptID = rejected.id
        let accessRequest = ProviderAccessRequest(
            maker: .anthropic,
            reason: "Claude requires a fresh sign-in.",
            resumePrompts: [rejected.text],
            selectedAccess: .claudeSubscription,
            recoveryAccess: .claudeSubscription,
            recoveryPromptEntryID: rejected.id)
        var value = conversation(
            request: accessRequest,
            modelSelection: ModelSelection(
                access: .claudeSubscription,
                modelID: "claude-managed"),
            queuedPrompts: [])
        value.messages = [rejected, assistant, failure]
        let originalMessages = value.messages

        XCTAssertFalse(value.fulfillProviderAccess(
            requestID: accessRequest.id,
            access: .claudeSubscription,
            modelID: "claude-managed"))
        XCTAssertEqual(value.providerAccessRequest, accessRequest)
        XCTAssertEqual(value.messages, originalMessages)
        XCTAssertTrue(value.queuedPrompts.isEmpty)
    }

    func testLegacyProviderRequestWithoutRecoveryPromptIdentityDecodes() throws {
        let promptEntryID = UUID(
            uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!
        let original = conversation(request: request(
            selectedAccess: .codexSubscription,
            recoveryAccess: .codexSubscription,
            recoveryPromptEntryID: promptEntryID))
        var encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var encodedRequest = try XCTUnwrap(
            encoded["providerAccessRequest"] as? [String: Any])
        XCTAssertNotNil(encodedRequest.removeValue(forKey: "recoveryPromptEntryID"))
        XCTAssertNotNil(encodedRequest.removeValue(forKey: "recoveryAccess"))
        encoded["providerAccessRequest"] = encodedRequest

        let restored = try JSONDecoder().decode(
            Conversation.self,
            from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertNil(restored.providerAccessRequest?.recoveryPromptEntryID)
        XCTAssertNil(restored.providerAccessRequest?.recoveryAccess)
        XCTAssertEqual(restored.providerAccessRequest?.selectedAccess, .codexSubscription)
        XCTAssertEqual(restored.providerAccessRequest?.resumePrompts, [
            "First resumed task", "Second resumed task",
        ])
    }

    func testFulfillmentRejectsUnselectedAndCrossFamilyRoutes() {
        let unselectedRequest = request(maker: .openAI)
        var unselected = conversation(request: unselectedRequest)
        XCTAssertFalse(unselected.fulfillProviderAccess(
            requestID: unselectedRequest.id,
            access: .codexSubscription,
            modelID: "gpt-selected"))

        let selectedRequest = request(
            maker: .openAI,
            selectedAccess: .codexSubscription)
        var crossFamily = conversation(request: selectedRequest)
        XCTAssertFalse(crossFamily.fulfillProviderAccess(
            requestID: selectedRequest.id,
            access: .claudeSubscription,
            modelID: "claude-other"))

        XCTAssertEqual(unselected.providerAccessRequest, unselectedRequest)
        XCTAssertEqual(crossFamily.providerAccessRequest, selectedRequest)
        XCTAssertEqual(unselected.queuedPrompts, ["already queued"])
        XCTAssertEqual(crossFamily.queuedPrompts, ["already queued"])

        var missingModel = conversation(request: selectedRequest)
        missingModel.queuedPrompts.removeAll()
        XCTAssertFalse(missingModel.fulfillProviderAccess(
            requestID: selectedRequest.id,
            access: .codexSubscription,
            modelID: ""))
        XCTAssertEqual(missingModel.providerAccessRequest, selectedRequest)
    }

    func testCancelRemovesOnlyNamedRequestAndPreservesUnrelatedState() {
        let expectedRequest = request(selectedAccess: .openAIAPI)
        var value = conversation(request: expectedRequest)
        let messageIDs = value.messages.map(\.id)
        let messageTexts = value.messages.map(\.text)
        let originalSelection = value.modelSelection
        let originalQueue = value.queuedPrompts
        let originalProjectID = value.projectID

        XCTAssertFalse(value.cancelProviderAccess(requestID: UUID()))
        XCTAssertEqual(value.providerAccessRequest, expectedRequest)
        XCTAssertTrue(value.cancelProviderAccess(requestID: expectedRequest.id))

        XCTAssertNil(value.providerAccessRequest)
        XCTAssertEqual(value.messages.map(\.id), messageIDs)
        XCTAssertEqual(value.messages.map(\.text), messageTexts)
        XCTAssertEqual(value.modelSelection, originalSelection)
        XCTAssertEqual(value.sdkSessionId, "existing-session")
        XCTAssertEqual(value.queuedPrompts, originalQueue)
        XCTAssertEqual(value.draft, "Unsent draft")
        XCTAssertEqual(value.projectID, originalProjectID)
        XCTAssertEqual(value.contextTokens, 1200)
        XCTAssertEqual(value.contextWindow, 200_000)
        XCTAssertEqual(value.contextModel, "claude-existing")
        XCTAssertTrue(value.favorite)
        XCTAssertTrue(value.unread)
        XCTAssertTrue(value.errored)
    }
}
