import XCTest
@testable import Mechanician

final class ProviderHistoryIsolationTests: XCTestCase {
    private func entry(
        _ kind: TranscriptEntry.Kind,
        _ text: String,
        ordinal: UInt64?
    ) -> TranscriptEntry {
        var entry = TranscriptEntry(kind: kind, text: text)
        entry.captureOrdinal = ordinal
        return entry
    }

    func testSameAccessRetargetLeavesReplayIntact() {
        let messages = [
            entry(.user, "Question", ordinal: 1),
            entry(.assistant, "Answer", ordinal: 2),
        ]
        var conversation = Conversation(
            title: "Same access",
            cwd: "",
            sdkSessionId: nil,
            modelSelection: .init(access: .claudeSubscription, modelID: "claude"),
            messages: messages,
            updatedAt: Date(),
            captureOrdinalHighWatermark: 2)

        AgentBridge.advanceProviderHistoryReplayBoundary(
            on: &conversation,
            from: .claudeSubscription,
            to: .claudeSubscription)

        XCTAssertNil(conversation.providerHistoryReplayCutoffOrdinal)
        XCTAssertEqual(
            AgentBridge.providerHistoryEntriesForReplay(
                conversation.messages,
                cutoffOrdinal: conversation.providerHistoryReplayCutoffOrdinal),
            messages)
    }

    func testCrossAccessReplayKeepsUserWordsAndExcludesPriorProviderReplyAndToolData() {
        var tool = entry(.tool, "RecallMemory", ordinal: 3)
        tool.toolResult = "anthropic-only memory"
        let messages = [
            entry(.user, "What do you remember?", ordinal: 1),
            entry(.assistant, "Anthropic-only memory", ordinal: 2),
            tool,
            entry(.user, "Continue", ordinal: 4),
            // Legacy provider output without an ordinal is ambiguous after a boundary and must not
            // regain replay merely because it predates capture ordinals.
            entry(.assistant, "Legacy provider reply", ordinal: nil),
        ]
        var conversation = Conversation(
            title: "Cross access",
            cwd: "",
            sdkSessionId: nil,
            modelSelection: .init(access: .claudeSubscription, modelID: "claude"),
            messages: messages,
            updatedAt: Date(),
            captureOrdinalHighWatermark: 4)

        AgentBridge.advanceProviderHistoryReplayBoundary(
            on: &conversation,
            from: .claudeSubscription,
            to: .codexSubscription)
        let retained = AgentBridge.providerHistoryEntriesForReplay(
            conversation.messages,
            cutoffOrdinal: conversation.providerHistoryReplayCutoffOrdinal)
        let payload = ReplayFidelityPlanner.plan(
            for: conversation,
            replaying: retained).providerPayload

        XCTAssertEqual(conversation.providerHistoryReplayCutoffOrdinal, 4)
        XCTAssertEqual(payload, [
            ["role": "user", "text": "What do you remember?"],
            ["role": "user", "text": "Continue"],
        ])
        XCTAssertFalse(payload.description.contains("Anthropic-only memory"))
        XCTAssertFalse(payload.description.contains("Legacy provider reply"))
    }

    func testBoundaryPersistsAndLaterDestinationReplyRemainsReplayable() throws {
        var conversation = Conversation(
            title: "Persistent boundary",
            cwd: "",
            sdkSessionId: nil,
            modelSelection: .init(access: .claudeSubscription, modelID: "claude"),
            messages: [
                entry(.user, "Original question", ordinal: 7),
                entry(.assistant, "Old provider answer", ordinal: 8),
            ],
            updatedAt: Date(),
            captureOrdinalHighWatermark: 8)
        AgentBridge.advanceProviderHistoryReplayBoundary(
            on: &conversation,
            from: .claudeSubscription,
            to: .anthropicAPI)
        conversation.messages.append(
            entry(.assistant, "New access answer", ordinal: 9))

        let relaunched = try JSONDecoder().decode(
            Conversation.self,
            from: JSONEncoder().encode(conversation))
        let payload = ReplayFidelityPlanner.plan(
            for: relaunched,
            replaying: AgentBridge.providerHistoryEntriesForReplay(
                relaunched.messages,
                cutoffOrdinal: relaunched.providerHistoryReplayCutoffOrdinal)
        ).providerPayload

        XCTAssertEqual(relaunched.providerHistoryReplayCutoffOrdinal, 8)
        XCTAssertEqual(payload, [
            ["role": "user", "text": "Original question"],
            ["role": "assistant", "text": "New access answer"],
        ])
    }
}
