import XCTest
@testable import Mechanician

final class ProviderFailureTests: XCTestCase {
    func testCodexCapacityFailureNamesCauseModelAndSafeRecovery() throws {
        let message = "Selected model is at capacity. Please try a different model."
        let entry = AgentBridge.errorEntry(from: [
            "type": "error",
            "errorKind": "server",
            "provider": "codex",
            "access": "codex_subscription",
            "message": message,
            "providerError": ["codexErrorTag": "serverOverloaded"],
        ], access: .codexSubscription, attemptedModelID: "  gpt-5.6-sol  ")
        let failure = try XCTUnwrap(entry.providerFailure)

        XCTAssertTrue(failure.isModelCapacityFailure)
        XCTAssertEqual(failure.attemptedModelID, "gpt-5.6-sol")
        XCTAssertEqual(failure.title, "Selected model is at capacity")
        XCTAssertEqual(failure.userFacingMessage, message)
        XCTAssertEqual(
            failure.modelCapacityPresentation,
            .init(
                title: "Selected model is at capacity",
                guidance: "Codex can’t serve gpt-5.6-sol right now. Choose another model, or try this model again later. This turn may already have completed work, so review the transcript before sending the prompt again.",
                diagnostic: "Codex error: serverOverloaded"))
        XCTAssertFalse(
            failure.allowsRetry,
            "missing proof of zero provider work must not offer a side-effecting replay")

        let restored = try JSONDecoder().decode(
            TranscriptEntry.self,
            from: JSONEncoder().encode(entry))
        XCTAssertEqual(restored.providerFailure, failure)
        XCTAssertEqual(restored.providerFailure?.modelCapacityPresentation,
                       failure.modelCapacityPresentation)
    }

    func testHistoricalCodexCapacityFailureGainsPresentationWithoutModelMigration() throws {
        let failure = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "server",
            "provider": "codex",
            "access": "codex_subscription",
            "message": "Selected model is at capacity. Please try a different model.",
            "providerError": ["codexErrorTag": "server_overloaded"],
        ], authoritativeAccess: .codexSubscription))

        let encoded = try JSONEncoder().encode(failure)
        let restored = try JSONDecoder().decode(ProviderFailure.self, from: encoded)
        XCTAssertNil(restored.attemptedModelID)
        XCTAssertTrue(restored.isModelCapacityFailure)
        XCTAssertEqual(restored.title, "Selected model is at capacity")
        XCTAssertEqual(
            restored.modelCapacityPresentation?.guidance,
            "Codex can’t serve the selected model right now. Choose another model, or try again later. This turn may already have completed work, so review the transcript before sending the prompt again.")
        XCTAssertEqual(
            restored.modelCapacityPresentation?.diagnostic,
            "Codex error: server_overloaded")
        XCTAssertFalse(restored.allowsRetry)
    }

    func testCodexSubscriptionBackend404UsesSafeServicePresentationForNewAndLegacyCards() throws {
        let rawMessage = """
        unexpected status 404 Not Found: Unknown error, url: \
        https://chatgpt.com/backend-api/codex/responses, cf-ray: private-edge-id
        """
        let expectedMessage =
            "The Codex subscription connection received HTTP 404 for an internal service request. Your prompt was not rejected. Retry in a moment; if it persists, check OpenAI status or Codex Help."
        let current = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "server",
            "provider": "codex",
            "access": "codex_subscription",
            "message": rawMessage,
            "providerError": [
                "status": 404,
                "diagnosticCode": "codex_subscription_backend_404",
            ],
        ], authoritativeAccess: .codexSubscription))

        XCTAssertEqual(current.title, "Codex service connection failed")
        XCTAssertEqual(current.userFacingMessage, expectedMessage)
        XCTAssertFalse(current.userFacingMessage.contains("chatgpt.com"))
        XCTAssertFalse(current.userFacingMessage.contains("private-edge-id"))
        XCTAssertEqual(current.diagnosticSummary, "HTTP 404")
        XCTAssertTrue(current.allowsRetry)
        XCTAssertEqual(current.resourceLinks.map(\.id), ["openai-status", "codex-help"])

        let legacy = ProviderFailure(
            kind: .unknown,
            provider: .codex,
            access: .codexSubscription,
            message: rawMessage)
        let restored = try JSONDecoder().decode(
            ProviderFailure.self,
            from: JSONEncoder().encode(legacy))

        XCTAssertEqual(restored.title, "Codex service connection failed")
        XCTAssertEqual(restored.userFacingMessage, expectedMessage)
        XCTAssertEqual(restored.resourceLinks.map(\.id), ["openai-status", "codex-help"])
        XCTAssertTrue(restored.allowsRetry)

        let unrelated = ProviderFailure(
            kind: .unknown,
            provider: .codex,
            access: .codexSubscription,
            message: "unexpected status 404 Not Found, url: https://example.com/backend-api/codex/responses")
        XCTAssertEqual(unrelated.title, "Codex request failed")
    }

    func testDiagnosticSummaryDoesNotRepeatAnIdenticalTerminalReason() {
        let failure = ProviderFailure(
            kind: .server,
            provider: .anthropic,
            access: .claudeSubscription,
            message: "The service is overloaded.",
            details: .init(code: "api_error", status: 529, terminalReason: "api_error"))

        XCTAssertEqual(failure.diagnosticSummary, "HTTP 529 · Code api_error")
    }

    func testResumedNoOutputFailureRequiresEveryStructuralSafetyFact() throws {
        let event: [String: Any] = [
            "type": "error",
            "errorKind": "network",
            "provider": "anthropic",
            "access": "claude_vertex",
            "message": "The provider produced no response.",
            "providerError": [
                "providerType": "provider_no_output",
                "code": "no_output_after_fresh_replay",
                "diagnosticCode": "claude_no_output_after_fresh_replay",
                "resumed": true,
                "noProviderWork": true,
                "freshReplayAttempted": true,
            ],
        ]
        let failure = try XCTUnwrap(ProviderFailure.from(
            event: event, authoritativeAccess: .claudeVertex))

        XCTAssertTrue(failure.isResumedNoOutputFailure)
        XCTAssertTrue(failure.allowsRetry)
        XCTAssertEqual(failure.details?.diagnosticCode, "claude_no_output_after_fresh_replay")
        XCTAssertEqual(failure.details?.resumed, true)
        XCTAssertEqual(failure.details?.noProviderWork, true)
        XCTAssertEqual(failure.details?.freshReplayAttempted, true)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ProviderFailure.self,
                from: JSONEncoder().encode(failure)),
            failure,
            "the fresh-retry contract must survive transcript persistence")

        for missing in ["resumed", "noProviderWork", "freshReplayAttempted"] {
            var changed = event
            var details = try XCTUnwrap(changed["providerError"] as? [String: Any])
            details[missing] = nil
            changed["providerError"] = details
            XCTAssertFalse(
                try XCTUnwrap(ProviderFailure.from(
                    event: changed, authoritativeAccess: .claudeVertex))
                    .isResumedNoOutputFailure,
                "missing \(missing) must fail closed")
        }
        for missing in ["code", "diagnosticCode"] {
            var changed = event
            var details = try XCTUnwrap(changed["providerError"] as? [String: Any])
            details[missing] = nil
            changed["providerError"] = details
            XCTAssertFalse(
                try XCTUnwrap(ProviderFailure.from(
                    event: changed, authoritativeAccess: .claudeVertex))
                    .isResumedNoOutputFailure,
                "missing \(missing) must fail closed")
        }
    }

    func testNoOutputMessageAloneNeverAuthorizesFreshRetry() throws {
        let failure = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "network",
            "provider": "anthropic",
            "access": "claude_vertex",
            "message": "no_output_after_fresh_replay resumed with no provider work",
            "providerError": ["providerType": "stream_idle_timeout"],
        ], authoritativeAccess: .claudeVertex))

        XCTAssertFalse(failure.isResumedNoOutputFailure)
    }

    func testClaudeAuthenticationFailureAlwaysOffersReconnect() {
        let historical = ProviderFailure(
            kind: .authentication,
            provider: .anthropic,
            access: .claudeSubscription,
            message: "Failed to authenticate. API Error: 401 Invalid authentication credentials",
            details: .init(status: 401)
        )

        XCTAssertTrue(historical.requiresReconnect)
        XCTAssertFalse(historical.allowsRetry)
        XCTAssertEqual(
            historical.accountRecoveryAction(accountRequiresReconnect: false),
            .automatic)
        let vertex = ProviderFailure(
            kind: .authentication,
            provider: .anthropic,
            access: .claudeVertex,
            message: "Application Default Credentials are invalid")
        XCTAssertTrue(vertex.requiresReconnect)
        XCTAssertEqual(vertex.providerName, "Google Vertex")
        XCTAssertFalse(ProviderFailure(
            kind: .authentication,
            provider: .anthropic,
            access: .anthropicAPI,
            message: "Invalid API key"
        ).requiresReconnect)
    }

    func testClaudeStatusUnavailablePreflightOffersForcedReconnectWithoutDisconnectingAccount() throws {
        let failure = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "unknown",
            "provider": "anthropic",
            "access": "claude_subscription",
            "message": "Claude credentials could not be verified before the request started.",
            "providerError": [
                "providerType": "credential_unknown",
                "code": "status_unavailable",
            ],
        ], authoritativeAccess: .claudeSubscription))

        XCTAssertEqual(failure.title, "Claude request failed")
        XCTAssertEqual(
            failure.userFacingMessage,
            "Claude credentials could not be verified before the request started.")
        XCTAssertEqual(failure.details?.providerType, "credential_unknown")
        XCTAssertEqual(failure.details?.code, "status_unavailable")
        XCTAssertNil(failure.reconnectRequired)
        XCTAssertFalse(failure.requiresReconnect)
        XCTAssertTrue(failure.allowsRetry)
        XCTAssertFalse(failure.requiresGoogleReauthentication)
        XCTAssertNil(failure.reauthenticationActionLabel)
        XCTAssertEqual(
            failure.accountRecoveryAction(accountRequiresReconnect: false),
            .forceReconnect)
        XCTAssertEqual(
            failure.accountRecoveryPresentation(
                accountRequiresReconnect: false,
                automaticActionLabel: "Connect"),
            .init(
                action: .forceReconnect,
                label: "Reconnect",
                help: "Sign in to Claude subscription again"))
    }

    func testPersistedClaudeStatusUnavailableKeepsReconnectPresentation() throws {
        let failure = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "unknown",
            "provider": "anthropic",
            "access": "claude_subscription",
            "message": "Claude credentials could not be verified before the request started.",
            "providerError": [
                "providerType": "credential_unknown",
                "code": "status_unavailable",
            ],
        ], authoritativeAccess: .claudeSubscription))
        var entry = TranscriptEntry(kind: .system, text: "error: \(failure.message)")
        entry.providerFailure = failure
        entry.providerFailurePromptID = UUID()

        let encoded = try JSONEncoder().encode(entry)
        let restored = try JSONDecoder().decode(TranscriptEntry.self, from: encoded)
        let restoredFailure = try XCTUnwrap(restored.providerFailure)

        XCTAssertEqual(restoredFailure, failure)
        XCTAssertEqual(restored.providerFailurePromptID, entry.providerFailurePromptID)
        XCTAssertEqual(
            restoredFailure.accountRecoveryPresentation(
                accountRequiresReconnect: false,
                automaticActionLabel: "Connect"),
            .init(
                action: .forceReconnect,
                label: "Reconnect",
                help: "Sign in to Claude subscription again"))
    }

    func testClaudeCredentialNetworkPreflightOffersRetryAndForcedReconnect() throws {
        let failure = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "network",
            "provider": "anthropic",
            "access": "claude_subscription",
            "message": "Couldn’t verify Claude credentials.",
            "providerError": [
                "providerType": "credential_network",
            ],
        ], authoritativeAccess: .claudeSubscription))

        XCTAssertFalse(failure.requiresReconnect)
        XCTAssertTrue(failure.allowsRetry)
        XCTAssertEqual(
            failure.accountRecoveryAction(accountRequiresReconnect: false),
            .forceReconnect)
    }

    func testOrdinaryClaudeNetworkFailureDoesNotOfferCredentialReconnect() throws {
        let failure = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "network",
            "provider": "anthropic",
            "access": "claude_subscription",
            "message": "Couldn’t reach Claude.",
            "providerError": [
                "providerType": "provider_start_timeout",
            ],
        ], authoritativeAccess: .claudeSubscription))

        XCTAssertTrue(failure.allowsRetry)
        XCTAssertNil(failure.accountRecoveryAction(accountRequiresReconnect: false))
    }

    func testVertexPreflightFailuresUseExistingReconnectAndRetryUIContracts() throws {
        let authentication = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "authentication",
            "provider": "anthropic",
            "access": "claude_vertex",
            "message": "Google requires a fresh sign-in.",
            "providerError": [
                "providerType": "credential_reauth_required",
                "code": "invalid_rapt",
                "status": 400,
            ],
            "reconnectRequired": true,
        ], authoritativeAccess: .claudeVertex))
        XCTAssertTrue(authentication.requiresReconnect)
        XCTAssertFalse(authentication.allowsRetry)
        XCTAssertEqual(authentication.details?.providerType, "credential_reauth_required")
        XCTAssertEqual(authentication.details?.code, "invalid_rapt")
        XCTAssertEqual(authentication.details?.status, 400)
        XCTAssertEqual(authentication.resourceLinks.map(\.id), ["google-cloud-reauth"])
        XCTAssertEqual(authentication.title, "Google reauthentication required")
        XCTAssertTrue(authentication.requiresGoogleReauthentication)
        XCTAssertEqual(authentication.reauthenticationActionLabel, "Reauthenticate with Google")
        XCTAssertEqual(
            authentication.accountRecoveryAction(accountRequiresReconnect: false),
            .forceReconnect)
        XCTAssertEqual(
            authentication.accountRecoveryPresentation(
                accountRequiresReconnect: false,
                automaticActionLabel: "Connect"),
            .init(
                action: .forceReconnect,
                label: "Reauthenticate with Google",
                help: "Open Google sign-in to reauthenticate"))

        let network = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "network",
            "provider": "anthropic",
            "access": "claude_vertex",
            "message": "Couldn’t verify Google Vertex credentials.",
            "providerError": [
                "providerType": "credential_network",
            ],
        ], authoritativeAccess: .claudeVertex))
        XCTAssertFalse(network.requiresReconnect)
        XCTAssertTrue(network.allowsRetry)
        XCTAssertEqual(network.title, "Couldn’t reach Google Vertex")
        XCTAssertNil(network.accountRecoveryAction(accountRequiresReconnect: false))
        XCTAssertEqual(
            network.accountRecoveryAction(accountRequiresReconnect: true),
            .forceReconnect)
    }

    func testMissingVertexCredentialKeepsTheFirstTimeConnectLanguage() throws {
        let missing = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "authentication",
            "provider": "anthropic",
            "access": "claude_vertex",
            "message": "Google credentials are missing. Connect Google Vertex and try again.",
            "providerError": [
                "providerType": "credential_no_credentials",
            ],
            "reconnectRequired": true,
        ], authoritativeAccess: .claudeVertex))

        XCTAssertFalse(missing.requiresGoogleReauthentication)
        XCTAssertNil(missing.reauthenticationActionLabel)
        XCTAssertEqual(missing.title, "Claude (Vertex) sign-in required")
    }

    func testPersistedUnknownRaptFailureGainsReauthenticationCopyAndAction() {
        let historical = ProviderFailure(
            kind: .unknown,
            provider: .anthropic,
            access: .claudeVertex,
            message: """
            Google Vertex request failed: {"error":"invalid_grant",\
            "error_description":"reauth related error (invalid_rapt)"}
            """,
            details: .init(
                code: "api_error",
                providerType: "error_during_execution",
                terminalReason: "api_error")
        )

        XCTAssertTrue(historical.requiresGoogleReauthentication)
        XCTAssertTrue(historical.requiresReconnect)
        XCTAssertFalse(historical.allowsRetry)
        XCTAssertEqual(historical.title, "Google reauthentication required")
        XCTAssertEqual(historical.reauthenticationActionLabel, "Reauthenticate with Google")
        XCTAssertEqual(historical.resourceLinks.map(\.id), ["google-cloud-reauth"])
        XCTAssertTrue(historical.userFacingMessage.contains("Reauthenticate with Google"))
        XCTAssertFalse(historical.userFacingMessage.contains("invalid_rapt"))
        XCTAssertEqual(
            historical.accountRecoveryAction(accountRequiresReconnect: false),
            .forceReconnect)
    }

    func testContextLimitOffersFreshConversationRecoveryInsteadOfRetryOrReconnect() throws {
        let failure = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "context_limit",
            "provider": "anthropic",
            "access": "claude_vertex",
            "message": "Prompt is too long: 226413 tokens is greater than the blocking limit.",
            "providerError": [
                "providerType": "invalid_request_error",
                "code": "blocking_limit",
                "status": 400,
            ],
        ], authoritativeAccess: .claudeVertex))

        XCTAssertEqual(failure.title, "Conversation exceeds the model context")
        XCTAssertEqual(
            failure.userFacingMessage,
            "The conversation history and this request no longer fit in the model’s context window.")
        XCTAssertFalse(failure.allowsRetry)
        XCTAssertFalse(failure.requiresReconnect)
        XCTAssertNil(failure.accountRecoveryAction(accountRequiresReconnect: false))
        XCTAssertNil(
            failure.accountRecoveryAction(accountRequiresReconnect: true),
            "A later account-state change must not turn a context card into a Reconnect action.")
        XCTAssertEqual(
            failure.conversationRecoveryPresentation,
            .init(
                editLabel: "Edit Prompt",
                editHelp: "Remove the rejected turn and restore its prompt for editing",
                startFreshLabel: "Start Fresh with Prompt",
                startFreshHelp: "Open a new conversation with the failed prompt ready to edit",
                startFreshEmptyLabel: "Start Fresh",
                startFreshEmptyHelp: "Open a new empty conversation without replaying this history",
                guidance: "This request is larger than the model can accept. Shorten or split large pasted text and attachments, or start fresh to drop earlier history. Reconnecting won’t help."))
    }

    func testSinglePromptPreflightLimitPrioritizesEditingLargeContent() throws {
        let failure = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "context_limit",
            "provider": "anthropic",
            "access": "claude_vertex",
            "message": "This prompt is too large to send.",
            "providerError": [
                "providerType": "input_too_large",
                "code": "prompt_preflight_limit",
                "terminalReason": "prompt_too_long",
            ],
        ], authoritativeAccess: .claudeVertex))

        XCTAssertTrue(failure.isPromptPreflightLimit)
        XCTAssertEqual(failure.title, "Prompt is too large")
        XCTAssertEqual(
            failure.userFacingMessage,
            "The prompt itself is larger than the model can accept in one request.")
        XCTAssertEqual(
            failure.conversationRecoveryPresentation?.guidance,
            "This prompt is too large even without earlier conversation history. Edit it to remove or split large pasted text and attachments before sending again. Reconnecting or starting fresh with it unchanged won’t help.")
    }

    /// The card used to print the provider's internal identifier under a monospaced "Code:" label,
    /// which reads as something to act on and is not. It belongs in the log.
    func testCompactionFailureCopyNeverShowsTheEngineIdentifier() {
        for raw in ["automatic context compaction failed: too_few_groups",
                    "UNIQUE constraint failed: conversation_events.conversation_id",
                    "blocking_limit exceeded"] {
            let shown = CompactionFailurePresentation.from(raw)
            XCTAssertNil(shown.diagnostic, "no engine text may reach the card")
            XCTAssertFalse(shown.message.contains("_"), "no identifier in the sentence: \(shown.message)")
        }
    }

    func testTooFewGroupsCompactionCopyExplainsLikelyOversizedSingleContent() {
        XCTAssertEqual(
            CompactionFailurePresentation.from(
                "automatic context compaction failed: too_few_groups"),
            .init(
                message: "One message is too large to summarize around. Sending a shorter message, "
                    + "or starting a new conversation, will get things moving again.",
                diagnostic: nil))
    }

    func testAdjacentCompactionAndContextLimitProjectAsOneFailureCard() {
        var compaction = TranscriptEntry(kind: .compaction, text: "Context compaction failed")
        compaction.compactionError = "too_few_groups"
        let user = TranscriptEntry(kind: .user, text: "Analyze this large attachment")
        var terminal = TranscriptEntry(kind: .system, text: "error: Prompt is too long")
        terminal.providerFailure = ProviderFailure(
            kind: .contextLimit,
            provider: .anthropic,
            access: .claudeVertex,
            message: "Prompt is too long")
        let adjacent = [user, compaction, terminal]

        XCTAssertTrue(
            ContextLimitFailureProjection.subsumesCompactionFailure(
                compaction,
                in: adjacent))
        XCTAssertEqual(
            ContextLimitFailureProjection.precedingCompactionFailure(
                for: terminal,
                in: adjacent),
            .init(
                message: "One message is too large to summarize around. Sending a shorter message, "
                    + "or starting a new conversation, will get things moving again.",
                diagnostic: nil))

        let unrelated = TranscriptEntry(kind: .system, text: "An unrelated notice")
        XCTAssertFalse(
            ContextLimitFailureProjection.subsumesCompactionFailure(
                compaction,
                in: [user, compaction, unrelated, terminal]))
        XCTAssertNil(
            ContextLimitFailureProjection.precedingCompactionFailure(
                for: terminal,
                in: [user, compaction, unrelated, terminal]))
    }

    @MainActor
    func testOnlyConversationTurnAttributesExactRecoveryPrompt() {
        let rootPromptID = UUID()
        let entry = TranscriptEntry(kind: .system, text: "error: Prompt is too long")

        XCTAssertEqual(
            AgentBridge.attributingFailurePrompt(
                entry,
                isConversationTurn: true,
                rootPromptEntryID: rootPromptID).providerFailurePromptID,
            rootPromptID)
        XCTAssertNil(
            AgentBridge.attributingFailurePrompt(
                entry,
                isConversationTurn: false,
                rootPromptEntryID: rootPromptID).providerFailurePromptID,
            "Provider-native review failures must remain prompt-less even before a review row exists.")
    }

    func testSuccessfulTurnClearsOnlyItsProvisionalCompactionFailure() {
        var recovered = TranscriptEntry(kind: .compaction, text: "Context compaction failed")
        recovered.compactionError = "too_few_groups"
        recovered.compactionTurnID = "recovered-turn"
        var otherTurn = TranscriptEntry(kind: .compaction, text: "Context compaction failed")
        otherTurn.compactionError = "too_few_groups"
        otherTurn.compactionTurnID = "terminal-turn"
        var successfulBoundary = TranscriptEntry(kind: .compaction, text: "Context compacted")
        successfulBoundary.compactionTurnID = "recovered-turn"
        let user = TranscriptEntry(kind: .user, text: "Keep me")
        var entries = [user, recovered, otherTurn, successfulBoundary]

        XCTAssertEqual(
            AgentBridge.removeRecoveredCompactionFailures(
                turnID: "recovered-turn",
                from: &entries),
            1)
        XCTAssertEqual(entries.map(\.id), [user.id, otherTurn.id, successfulBoundary.id])
        XCTAssertEqual(entries[1].compactionError, "too_few_groups",
                       "A different terminal turn must retain its compaction audit.")
    }

    @MainActor
    func testStartFreshConversationPreservesFailedPromptAsEditableDraft() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mechanician-context-recovery-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let failedPrompt = "Analyze /private/tmp/large-report.txt, but focus on the final section."
        let rejectedPrompt = TranscriptEntry(kind: .user, text: failedPrompt)
        var failureEntry = TranscriptEntry(kind: .system, text: "error: Prompt is too long")
        failureEntry.providerFailure = ProviderFailure(
            kind: .contextLimit,
            provider: .anthropic,
            access: .claudeVertex,
            message: "Prompt is too long")
        failureEntry.providerFailurePromptID = rejectedPrompt.id
        let previousMessages = [
            rejectedPrompt,
            failureEntry,
        ]
        let previous = Conversation(
            title: "Large report",
            cwd: "",
            sdkSessionId: "oversized-session",
            modelSelection: ModelSelection(access: .claudeVertex, modelID: "test-model"),
            messages: previousMessages,
            updatedAt: Date())
        ConversationStore.shared.upsert(previous)
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        bridge.currentID = previous.id
        bridge.entries = previousMessages
        var freshID: UUID?
        defer {
            bridge.shutdown()
            ConversationStore.shared.remove(previous.id, permanently: true)
            if let freshID { ConversationStore.shared.remove(freshID, permanently: true) }
            ConversationStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        XCTAssertTrue(bridge.startFreshConversation(recovering: failureEntry))
        let createdID = try XCTUnwrap(bridge.currentID)
        freshID = createdID

        XCTAssertNotEqual(createdID, previous.id)
        XCTAssertTrue(bridge.entries.isEmpty)
        XCTAssertEqual(ConversationStore.shared.conversation(createdID)?.draft, failedPrompt)
        XCTAssertNil(ConversationStore.shared.conversation(createdID)?.sdkSessionId)
        XCTAssertEqual(
            ConversationStore.shared.conversation(createdID)?.modelSelection,
            previous.modelSelection,
            "Recovery must not silently switch to the app or workspace’s newer default route.")
        let countAfterRecovery = ConversationStore.shared.conversations.count
        XCTAssertFalse(
            bridge.startFreshConversation(recovering: failureEntry),
            "A stale failure-card action must not create another conversation.")
        XCTAssertEqual(ConversationStore.shared.conversations.count, countAfterRecovery)
        let retained = try XCTUnwrap(ConversationStore.shared.conversation(previous.id)?.messages)
        XCTAssertEqual(retained.count, previousMessages.count)
        XCTAssertEqual(retained.map(\.id), previousMessages.map(\.id))
        XCTAssertEqual(retained.map(\.text), previousMessages.map(\.text),
                       "Recovery must leave the failed transcript intact for reference.")
    }

    @MainActor
    func testStartFreshPreservesPromptlessErrorOnlySourceTranscript() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mechanician-context-empty-recovery-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        var failureEntry = TranscriptEntry(kind: .system, text: "error: Prompt is too long")
        failureEntry.providerFailure = ProviderFailure(
            kind: .contextLimit,
            provider: .anthropic,
            access: .claudeVertex,
            message: "Prompt is too long")
        let source = Conversation(
            title: "Review",
            cwd: "",
            sdkSessionId: nil,
            modelSelection: ModelSelection(access: .claudeVertex, modelID: "test-model"),
            messages: [failureEntry],
            updatedAt: Date())
        XCTAssertTrue(source.hasDurableContent,
                      "A terminal error is durable history even without a user or review row.")
        ConversationStore.shared.upsert(source)
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        bridge.currentID = source.id
        bridge.entries = source.messages
        var freshID: UUID?
        defer {
            bridge.shutdown()
            ConversationStore.shared.remove(source.id, permanently: true)
            if let freshID { ConversationStore.shared.remove(freshID, permanently: true) }
            ConversationStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        XCTAssertTrue(bridge.startFreshConversation(recovering: failureEntry))
        let createdID = try XCTUnwrap(bridge.currentID)
        freshID = createdID
        XCTAssertNotNil(ConversationStore.shared.conversation(source.id))
        XCTAssertEqual(
            ConversationStore.shared.conversation(source.id)?.messages.map(\.id),
            [failureEntry.id])
        XCTAssertEqual(
            ConversationStore.shared.conversation(createdID)?.draft,
            "")
    }

    @MainActor
    func testEditContextLimitPromptRewindsOnlyARejectedSideEffectFreeTurn() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mechanician-context-edit-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let earlier = [
            TranscriptEntry(kind: .user, text: "What is in this report?"),
            TranscriptEntry(kind: .assistant, text: "It contains several sections."),
        ]
        let failedPrompt = "Now analyze this very large pasted section."
        let rejected = TranscriptEntry(kind: .user, text: failedPrompt)
        var compaction = TranscriptEntry(kind: .compaction, text: "Context compaction failed")
        compaction.compactionError = "too_few_groups"
        var failureEntry = TranscriptEntry(kind: .system, text: "error: Prompt is too long")
        failureEntry.providerFailure = ProviderFailure(
            kind: .contextLimit,
            provider: .anthropic,
            access: .claudeVertex,
            message: "Prompt is too long")
        failureEntry.providerFailurePromptID = rejected.id
        let messages = earlier + [rejected, compaction, failureEntry]
        let conversation = Conversation(
            title: "Large report",
            cwd: "",
            sdkSessionId: "oversized-session",
            modelSelection: ModelSelection(access: .claudeVertex, modelID: "test-model"),
            messages: messages,
            updatedAt: Date())
        ConversationStore.shared.upsert(conversation)
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        bridge.currentID = conversation.id
        bridge.entries = messages
        defer {
            bridge.shutdown()
            ConversationStore.shared.remove(conversation.id, permanently: true)
            ConversationStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        var promptlessReviewFailure = failureEntry
        promptlessReviewFailure.id = UUID()
        promptlessReviewFailure.providerFailurePromptID = nil
        bridge.entries = earlier + [promptlessReviewFailure]
        XCTAssertFalse(bridge.canEditContextLimitPrompt(promptlessReviewFailure))
        XCTAssertNil(bridge.contextLimitRecoveryPrompt(promptlessReviewFailure),
                     "A pre-ack provider review failure must not borrow a historical user prompt.")
        bridge.entries = messages

        XCTAssertTrue(bridge.canEditContextLimitPrompt(failureEntry))
        var tool = TranscriptEntry(kind: .tool, text: "A command that may have side effects")
        tool.toolName = "Bash"
        bridge.entries.insert(tool, at: bridge.entries.count - 1)
        XCTAssertFalse(
            bridge.canEditContextLimitPrompt(failureEntry),
            "A recovery action must never erase tool audit evidence.")
        XCTAssertEqual(
            bridge.contextLimitRecoveryPrompt(failureEntry),
            failedPrompt,
            "Starting fresh may carry the exact route-owned prompt without erasing old audit rows.")
        var successfulCompactionMessages = messages
        successfulCompactionMessages[successfulCompactionMessages.count - 2].compactionError = nil
        bridge.entries = successfulCompactionMessages
        XCTAssertFalse(
            bridge.canEditContextLimitPrompt(failureEntry),
            "A successful compaction boundary must not be discarded and replayed as raw history.")
        var recoveryInfo = TranscriptEntry(
            kind: .system,
            text: "Mechanician is retrying in a fresh session with bounded history.")
        recoveryInfo.providerFailure = nil
        let messagesWithRecoveryInfo = earlier + [
            rejected,
            compaction,
            recoveryInfo,
            failureEntry,
        ]
        bridge.entries = messagesWithRecoveryInfo
        XCTAssertTrue(
            bridge.canEditContextLimitPrompt(failureEntry),
            "A side-effect-free auto-recovery info row must not strand the rejected prompt.")

        XCTAssertEqual(
            bridge.prepareContextLimitPromptForEditing(failureEntry),
            failedPrompt)
        XCTAssertEqual(bridge.entries.map(\.id), earlier.map(\.id))
        let stored = try XCTUnwrap(
            ConversationStore.shared.conversation(conversation.id))
        XCTAssertEqual(stored.messages.map(\.id), earlier.map(\.id))
        XCTAssertEqual(stored.draft, failedPrompt)
        XCTAssertNil(stored.sdkSessionId)
        XCTAssertFalse(stored.errored)
    }

    func testFreshNoOutputRetryPlanRewindsPromptAndTerminalWithoutDuplicatingUserRow() throws {
        let prior = [
            TranscriptEntry(kind: .user, text: "Earlier question"),
            TranscriptEntry(kind: .assistant, text: "Earlier answer"),
        ]
        let attachment = ConversationFileReference(
            storageName: "40000000-0000-0000-0000-000000000004.png",
            displayName: "evidence.png",
            typeIdentifier: "public.png",
            byteCount: 123)
        let prompt = TranscriptEntry(
            kind: .user,
            text: "Continue the analysis\n\(attachment.promptToken)")
        var notice = TranscriptEntry(
            kind: .system,
            text: "Mechanician retried this provider session with bounded history.")
        notice.providerFailure = nil
        var failure = TranscriptEntry(kind: .system, text: "error: No response")
        failure.providerFailure = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "network",
            "provider": "anthropic",
            "access": "claude_vertex",
            "message": "No response",
            "providerError": [
                "providerType": "provider_no_output",
                "code": "no_output_after_fresh_replay",
                "diagnosticCode": "claude_no_output_after_fresh_replay",
                "resumed": true,
                "noProviderWork": true,
                "freshReplayAttempted": true,
            ],
        ], authoritativeAccess: .claudeVertex))
        failure.providerFailurePromptID = prompt.id

        let plan = try XCTUnwrap(AgentBridge.freshSessionProviderFailureRetryPlan(
            for: failure,
            in: prior + [prompt, notice, failure]))
        XCTAssertEqual(plan.prior.map(\.id), prior.map(\.id))
        XCTAssertEqual(plan.prompt, prompt.text)
        XCTAssertFalse(plan.prior.contains { $0.id == prompt.id },
                       "send must recreate the retried user row exactly once")

        var tool = TranscriptEntry(kind: .tool, text: "side effect")
        tool.toolName = "Bash"
        XCTAssertNil(AgentBridge.freshSessionProviderFailureRetryPlan(
            for: failure,
            in: prior + [prompt, tool, failure]),
            "local tool evidence must override an inconsistent noProviderWork claim")

        var refusal = TranscriptEntry(kind: .system, text: "Provider refused the request")
        refusal.refusal = ClaudeRefusalRecord(
            outcome: .noFallback,
            explanation: "Provider refused the request")
        XCTAssertNil(AgentBridge.freshSessionProviderFailureRetryPlan(
            for: failure,
            in: prior + [prompt, refusal, failure]),
            "provider-authored refusal evidence must override an inconsistent noProviderWork claim")

        let selection = ModelSelection(
            access: .claudeVertex,
            modelID: "claude-opus-4-8[1m]")
        var durable = Conversation(
            title: "Crash-safe retry",
            cwd: "/tmp",
            sdkSessionId: "wedged-session",
            sdkSessionRouteIdentity: "route",
            sdkSessionExtensionRevision: UUID(),
            sdkSessionWorkspaceInstructionsRevision: "instructions",
            modelSelection: selection,
            messages: prior + [prompt, notice, failure],
            updatedAt: Date(),
            queuedPrompts: ["leave this queued"],
            draft: "leave this draft",
            contextTokens: 118_927,
            contextWindow: 1_000_000,
            contextModel: selection.modelID)
        durable.claudeEffectiveModel = selection.modelID

        let staged = try XCTUnwrap(AgentBridge.stageFreshSessionProviderFailureRetry(
            for: failure,
            selection: selection,
            in: &durable))
        XCTAssertEqual(staged.prior.map(\.id), prior.map(\.id))
        XCTAssertEqual(staged.prompt, prompt.text)
        XCTAssertEqual(durable.messages.map(\.id), prior.map(\.id))
        XCTAssertEqual(durable.pendingTurnPrompt, prompt.text)
        XCTAssertEqual(durable.queuedPrompts, ["leave this queued"])
        XCTAssertEqual(durable.draft, "leave this draft")
        XCTAssertNil(durable.sdkSessionId)
        XCTAssertNil(durable.sdkSessionRouteIdentity)
        XCTAssertNil(durable.sdkSessionExtensionRevision)
        XCTAssertNil(durable.sdkSessionWorkspaceInstructionsRevision)
        XCTAssertNil(durable.claudeEffectiveModel)
        XCTAssertNil(durable.contextTokens)
        XCTAssertNil(durable.contextWindow)
        XCTAssertNil(durable.contextModel)

        let retained = LibraryRetainedByteReferenceExtractor.extract(
            from: durable,
            supportRoot: FileManager.default.temporaryDirectory)
        XCTAssertEqual(
            retained.managedReferences.first { $0.storageName == attachment.storageName }?.owner,
            .localState(.pendingTurnPrompt),
            "rewinding the failed user row must transfer its attachment authority to the pending prompt")

        XCTAssertTrue(AgentBridge.retainCommittedFreshRetryPrompt(
            prompt.text,
            in: &durable))
        XCTAssertFalse(AgentBridge.retainCommittedFreshRetryPrompt(
            prompt.text,
            in: &durable))
        XCTAssertNil(durable.pendingTurnPrompt)
        XCTAssertEqual(durable.queuedPrompts, [prompt.text, "leave this queued"])
        XCTAssertEqual(
            LibraryRetainedByteReferenceExtractor.extract(
                from: durable,
                supportRoot: FileManager.default.temporaryDirectory)
                .managedReferences.first { $0.storageName == attachment.storageName }?.owner,
            .localState(.queuedPrompt(index: 0)),
            "a failed provider start must retain one visible queued attachment owner")

        var duplicate = durable
        duplicate.pendingTurnPrompt = prompt.text
        XCTAssertTrue(AgentBridge.retainCommittedFreshRetryPrompt(
            prompt.text,
            in: &duplicate))
        XCTAssertEqual(
            duplicate.queuedPrompts.prefix(2),
            [prompt.text, prompt.text],
            "identical text can name two deliberate actions; consuming the pending slot preserves both")
    }
}

extension ProviderFailureTests {

    /// FR-218. Throttling was refused a Retry button on the reasoning that it "could immediately
    /// fail again". When the provider states its reset, that objection is answerable with data the
    /// app already parses and previously used only for display.
    func testRateLimitIsRetryableOnlyWhenTheProviderNamedItsReset() {
        let withoutReset = ProviderFailure(
            kind: .rateLimit,
            provider: .anthropic,
            access: .claudeSubscription,
            message: "Rate limit reached")
        XCTAssertFalse(withoutReset.allowsRetry, "no reset means no honest offer to retry")
        XCTAssertNil(withoutReset.retryAvailableAt)

        let resetsAt = Date(timeIntervalSince1970: 1_800_000_000)
        let withReset = ProviderFailure(
            kind: .rateLimit,
            provider: .anthropic,
            access: .claudeSubscription,
            message: "Rate limit reached",
            details: .init(retryAfterSeconds: 60, resetsAt: resetsAt))
        XCTAssertTrue(withReset.allowsRetry)
        XCTAssertEqual(withReset.retryAvailableAt, resetsAt)

        // `retryAfterSeconds` alone is not enough: it is relative to a response whose arrival time
        // the failure does not record, so converting it would invent a base time.
        let relativeOnly = ProviderFailure(
            kind: .rateLimit,
            provider: .anthropic,
            access: .claudeSubscription,
            message: "Rate limit reached",
            details: .init(retryAfterSeconds: 60))
        XCTAssertFalse(relativeOnly.allowsRetry)

        // The other six refusals are unchanged; retrying cannot repair any of them.
        for kind in [ProviderFailure.Kind.authentication, .quota, .modelAccess,
                     .contextLimit, .outputLimit, .invalidRequest] {
            let failure = ProviderFailure(
                kind: kind, provider: .anthropic, access: .claudeSubscription, message: "x")
            XCTAssertFalse(failure.allowsRetry, "\(kind) must stay action-only")
            XCTAssertNil(failure.retryAvailableAt, "\(kind) carries no retry instant")
        }
    }
}
