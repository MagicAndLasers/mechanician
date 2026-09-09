import XCTest
@testable import Mechanician

final class SuggestedPromptPersistenceUpgradeTests: XCTestCase {
    func testLegacyLowQualityOnDeviceSuggestionsNormalizeOutOfConversationDecode() throws {
        let root = TranscriptEntry(
            kind: .user,
            text: "Improve the suggested-prompt quality.")
        let assistant = TranscriptEntry(
            kind: .assistant,
            text: "Next, disable suggested prompts while their replacement is generated.")

        for legacyText in [
            "Would you like me to continue?",
            "Can you explain how to integrate the debounce pattern with a timeout for follow-ups?",
            "Integrate the debounce pattern with a timeout for follow-ups in the sample repo.",
        ] {
            let conversation = conversation(
                root: root,
                assistant: assistant,
                suggestionText: legacyText)
            let legacyData = try removingQualityPolicy(
                fromConversationData: ConversationStore.makeEncoder().encode(conversation))
            let decoded = try ConversationStore.makeDecoder().decode(
                Conversation.self, from: legacyData)

            XCTAssertNil(decoded.suggestedPrompt, "Restored legacy suggestion: \(legacyText)")
            XCTAssertTrue(decoded.needsStaleStatePersistence)
            XCTAssertTrue(decoded.decodeNormalizations.contains(.suggestedPrompt))

            let source = try JSONSerialization.jsonObject(with: legacyData)
            let pruned = ConversationDecodeNormalization.prune(
                source: source,
                applying: decoded.decodeNormalizations)
            XCTAssertNil((pruned as? [String: Any])?["suggestedPrompt"])
        }
    }

    func testLegacyProviderSuggestionSurvivesWithoutLocalQualityPolicy() throws {
        let root = TranscriptEntry(
            kind: .user,
            text: "Show Claude's suggested prompt.")
        let assistant = TranscriptEntry(
            kind: .assistant,
            text: "Claude supplied a native suggestion.")
        let native = "Would you like me to continue?"
        let conversation = conversation(
            root: root,
            assistant: assistant,
            suggestionText: native,
            source: .provider)
        let legacyData = try removingQualityPolicy(
            fromConversationData: ConversationStore.makeEncoder().encode(conversation))

        let decoded = try ConversationStore.makeDecoder().decode(
            Conversation.self, from: legacyData)

        XCTAssertEqual(decoded.suggestedPrompt?.text, native)
        XCTAssertEqual(decoded.suggestedPrompt?.source, .provider)
        XCTAssertFalse(decoded.needsStaleStatePersistence)
        XCTAssertFalse(decoded.decodeNormalizations.contains(.suggestedPrompt))
    }

    func testCurrentDirectPrescribedSuggestionSurvivesConversationDecode() throws {
        let root = TranscriptEntry(
            kind: .user,
            text: "Improve the suggested-prompt quality.")
        let assistant = TranscriptEntry(
            kind: .assistant,
            text: "Next, disable suggested prompts while their replacement is generated.")
        let conversation = conversation(
            root: root,
            assistant: assistant,
            suggestionText: "Disable suggested prompts while their replacement is generated.")
        let data = try ConversationStore.makeEncoder().encode(conversation)

        let decoded = try ConversationStore.makeDecoder().decode(Conversation.self, from: data)

        XCTAssertEqual(decoded.suggestedPrompt, conversation.suggestedPrompt)
        XCTAssertFalse(decoded.needsStaleStatePersistence)
        XCTAssertFalse(decoded.decodeNormalizations.contains(.suggestedPrompt))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let suggestion = try XCTUnwrap(object["suggestedPrompt"] as? [String: Any])
        XCTAssertEqual(
            suggestion["qualityPolicyVersion"] as? Int,
            ConversationSuggestedPrompt.currentQualityPolicyVersion)
    }

    func testAuthorityReconstructionRetiresLegacySuggestionWithoutPayloadVersionBump() throws {
        let root = TranscriptEntry(
            kind: .user,
            text: "Improve the suggested-prompt quality.")
        let assistant = TranscriptEntry(
            kind: .assistant,
            text: "Next, disable suggested prompts while their replacement is generated.")
        let conversation = conversation(
            root: root,
            assistant: assistant,
            suggestionText: "Disable suggested prompts while their replacement is generated.")
        let current = try LibraryConversationAdapter.capture(
            conversation,
            source: ShadowLibrarySourceFingerprint(
                identity: "suggested-prompt-upgrade.json",
                revision: "1",
                sourceBytes: Data()))

        XCTAssertEqual(
            try LibraryConversationAdapter.reconstruct(from: current).suggestedPrompt,
            conversation.suggestedPrompt)

        let legacyPayload = try removingQualityPolicy(
            fromLocalStateData: current.localStatePayload)
        let legacy = ShadowLibraryConversationSnapshot(
            id: current.id,
            title: current.title,
            titleSource: current.titleSource,
            cwd: current.cwd,
            workspaceID: current.workspaceID,
            updatedAt: current.updatedAt,
            favorite: current.favorite,
            sortIndex: current.sortIndex,
            unread: current.unread,
            errored: current.errored,
            revision: current.revision,
            tombstoned: current.tombstoned,
            localStateVersion: current.localStateVersion,
            localStatePayload: legacyPayload,
            source: current.source,
            events: current.events,
            nestedArtifacts: current.nestedArtifacts)

        XCTAssertNil(try LibraryConversationAdapter.reconstruct(from: legacy).suggestedPrompt)
        XCTAssertEqual(
            legacy.localStateVersion,
            LibraryConversationLocalStatePayload.currentVersion)
        XCTAssertEqual(LibraryConversationLocalStatePayload.currentVersion, 1)
    }

    func testAuthorityReconstructionKeepsLegacyProviderSuggestion() throws {
        let root = TranscriptEntry(
            kind: .user,
            text: "Show Claude's suggested prompt.")
        let assistant = TranscriptEntry(
            kind: .assistant,
            text: "Claude supplied a native suggestion.")
        let native = "Would you like me to continue?"
        let conversation = conversation(
            root: root,
            assistant: assistant,
            suggestionText: native,
            source: .provider)
        let current = try LibraryConversationAdapter.capture(
            conversation,
            source: ShadowLibrarySourceFingerprint(
                identity: "provider-suggested-prompt-upgrade.json",
                revision: "1",
                sourceBytes: Data()))
        let legacyPayload = try removingQualityPolicy(
            fromLocalStateData: current.localStatePayload)
        let legacy = ShadowLibraryConversationSnapshot(
            id: current.id,
            title: current.title,
            titleSource: current.titleSource,
            cwd: current.cwd,
            workspaceID: current.workspaceID,
            updatedAt: current.updatedAt,
            favorite: current.favorite,
            sortIndex: current.sortIndex,
            unread: current.unread,
            errored: current.errored,
            revision: current.revision,
            tombstoned: current.tombstoned,
            localStateVersion: current.localStateVersion,
            localStatePayload: legacyPayload,
            source: current.source,
            events: current.events,
            nestedArtifacts: current.nestedArtifacts)

        let restored = try LibraryConversationAdapter.reconstruct(from: legacy)

        XCTAssertEqual(restored.suggestedPrompt?.text, native)
        XCTAssertEqual(restored.suggestedPrompt?.source, .provider)
    }

    private func conversation(
        root: TranscriptEntry,
        assistant: TranscriptEntry,
        suggestionText: String,
        source: ConversationSuggestedPromptSource = .onDevice
    ) -> Conversation {
        let suggestion = ConversationSuggestedPrompt(
            text: suggestionText,
            source: source,
            rootPromptEntryID: root.id,
            assistantEntryID: assistant.id)
        return Conversation(
            title: "Suggested prompt policy",
            cwd: "/tmp/suggested-prompt-policy",
            sdkSessionId: nil,
            messages: [root, assistant],
            updatedAt: Date(timeIntervalSinceReferenceDate: 42),
            suggestedPrompt: suggestion)
    }

    private func removingQualityPolicy(fromConversationData data: Data) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        var suggestion = try XCTUnwrap(object["suggestedPrompt"] as? [String: Any])
        suggestion.removeValue(forKey: "qualityPolicyVersion")
        object["suggestedPrompt"] = suggestion
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func removingQualityPolicy(fromLocalStateData data: Data) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        var suggestion = try XCTUnwrap(object["suggestedPrompt"] as? [String: Any])
        suggestion.removeValue(forKey: "qualityPolicyVersion")
        object["suggestedPrompt"] = suggestion
        return try JSONSerialization.data(withJSONObject: object)
    }
}
