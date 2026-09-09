import XCTest
@testable import Mechanician

final class SpotlightIndexTests: XCTestCase {
    func testIncrementalSnippetExcludesSupersededRows() {
        var withdrawnUser = TranscriptEntry(kind: .user, text: "WITHDRAWN-USER")
        withdrawnUser.supersessionEventID = UUID()
        var retainedTool = TranscriptEntry(kind: .tool, text: "retained fallback")
        retainedTool.toolName = "Read"
        let conversation = Conversation(
            title: "Spotlight", cwd: "", sdkSessionId: nil,
            messages: [withdrawnUser, retainedTool], updatedAt: Date())

        XCTAssertEqual(
            ConversationStore.spotlightSnippet(for: conversation),
            "retained fallback")
    }

    func testFullReindexSnippetExcludesLocalAndLegacySupersessionMarkers() {
        let messages: [[String: Any]] = [
            ["kind": "user", "text": "WITHDRAWN-EVENT", "supersessionEventID": UUID().uuidString],
            ["kind": "user", "text": "WITHDRAWN-LINK", "supersededByEntryID": UUID().uuidString],
            ["kind": "tool", "text": "WITHDRAWN-LEGACY", "supersededByFrameUUID": "frame"],
            ["kind": "assistant", "text": "retained fallback"],
        ]

        XCTAssertEqual(ConversationIndex.snippet(from: messages), "retained fallback")
        XCTAssertFalse(ConversationIndex.snippet(from: messages).contains("WITHDRAWN"))
    }
}
