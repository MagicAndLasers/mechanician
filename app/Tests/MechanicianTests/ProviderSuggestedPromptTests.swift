import XCTest
@testable import Mechanician

final class ProviderSuggestedPromptTests: XCTestCase {
    func testNativeProviderSuggestionKeepsProviderTextAndTurnProvenance() throws {
        let user = TranscriptEntry(
            kind: .user,
            text: "Show me an example of the improved suggested prompts.")
        let assistant = TranscriptEntry(
            kind: .assistant,
            text: "Here is the example you requested.")
        let messages = [user, assistant]
        let native = "Can you explain how to integrate this in the sample repo?"

        let suggestion = try XCTUnwrap(AgentBridge.providerSuggestedPromptCandidate(
            native,
            turnID: "turn-1",
            rootPromptEntryID: user.id,
            messages: messages))

        XCTAssertEqual(suggestion.text, native)
        XCTAssertEqual(suggestion.source, .provider)
        XCTAssertEqual(suggestion.rootPromptEntryID, user.id)
        XCTAssertEqual(suggestion.assistantEntryID, assistant.id)
        XCTAssertEqual(suggestion.validated(in: messages), suggestion)
    }

    func testNativeProviderSuggestionBypassesTheLocalActionPolicy() throws {
        let olderUser = TranscriptEntry(
            kind: .user,
            text: "Implement durable prompt persistence.")
        let olderAssistant = TranscriptEntry(
            kind: .assistant,
            text: "Durable prompt persistence is complete.")
        let currentUser = TranscriptEntry(
            kind: .user,
            text: "Show the provider's own follow-up.")
        let currentAssistant = TranscriptEntry(
            kind: .assistant,
            text: "Claude has supplied its own follow-up suggestion.")
        let messages = [olderUser, olderAssistant, currentUser, currentAssistant]
        let nativeSuggestions = [
            "Implement durable prompt persistence.",
            "Continue with build 0f27118.",
            "Would you like me to continue?",
            "Compare the two options.\nThen choose one.",
        ]

        for native in nativeSuggestions {
            let suggestion = try XCTUnwrap(AgentBridge.providerSuggestedPromptCandidate(
                native,
                turnID: "turn-2",
                rootPromptEntryID: currentUser.id,
                messages: messages))
            XCTAssertEqual(suggestion.text, native)
        }
    }

    func testNativeProviderSuggestionStillRequiresCompletedTurnEndpoints() {
        let user = TranscriptEntry(kind: .user, text: "Continue the work.")
        let assistant = TranscriptEntry(kind: .assistant, text: "The reply is complete.")

        XCTAssertNil(AgentBridge.providerSuggestedPromptCandidate(
            "   ",
            turnID: "turn-1",
            rootPromptEntryID: user.id,
            messages: [user, assistant]))
        XCTAssertNil(AgentBridge.providerSuggestedPromptCandidate(
            "Continue.",
            turnID: "turn-1",
            rootPromptEntryID: UUID(),
            messages: [user, assistant]))
        XCTAssertNil(AgentBridge.providerSuggestedPromptCandidate(
            "Continue.",
            turnID: "turn-1",
            rootPromptEntryID: user.id,
            messages: [user]))
    }

    func testOnDeviceSuggestionFallbackRunsOnlyForCodex() {
        let unavailableLanes: [ModelAccess] = [
            .claudeSubscription,
            .anthropicAPI,
            .claudeVertex,
            .claudeBedrock,
            .openAIAPI,
        ]
        for access in unavailableLanes {
            XCTAssertFalse(mayGenerate(for: access), access.rawValue)
        }
        XCTAssertTrue(mayGenerate(for: .codexSubscription))
        XCTAssertFalse(mayGenerate(for: .codexSubscription, hasNativeSuggestion: true))
    }

    private func mayGenerate(
        for access: ModelAccess,
        hasNativeSuggestion: Bool = false
    ) -> Bool {
        SuggestedPromptFallback.mayGenerate(
            access: access,
            isConversationTurn: true,
            wasInterrupted: false,
            isConversationAvailable: true,
            isWorking: false,
            isStreaming: false,
            hasNativeSuggestion: hasNativeSuggestion,
            modelIsAvailable: true)
    }
}
