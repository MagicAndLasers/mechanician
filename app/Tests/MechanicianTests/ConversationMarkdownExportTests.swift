import Foundation
import XCTest
@testable import Mechanician

final class ConversationMarkdownExportTests: XCTestCase {
    func testFilenameIsFinderSafeAndDoesNotDuplicateMarkdownExtension() {
        XCTAssertEqual(
            ConversationMarkdownDocument.filename(for: " Road / plan: Q3.md "),
            "Road-plan-Q3.md")
        XCTAssertEqual(
            ConversationMarkdownDocument.filename(for: ":/\n\t"),
            "Conversation.md")

        let unicodeHeavy = String(repeating: "🪄e\u{301}", count: 120)
        let bounded = ConversationMarkdownDocument.filename(for: unicodeHeavy)
        XCTAssertTrue(bounded.hasSuffix(".md"))
        XCTAssertLessThanOrEqual(
            bounded.utf8.count,
            ConversationMarkdownDocument.maximumFilenameUTF8Bytes)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(bounded)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNoThrow(try Data().write(to: url))
    }

    func testDocumentAddsConversationTitleAndTranscript() {
        let conversation = Conversation(
            title: "Launch brief",
            cwd: "",
            sdkSessionId: nil,
            messages: [
                TranscriptEntry(kind: .user, text: "Sketch the launch."),
                TranscriptEntry(kind: .assistant, text: "Here is the plan."),
            ],
            updatedAt: Date())

        let document = ConversationMarkdownDocument(conversation: conversation)

        XCTAssertEqual(document.filename, "Launch brief.md")
        XCTAssertTrue(document.contents.hasPrefix("# Launch brief\n\n**You:**"))
        XCTAssertTrue(document.contents.contains("Sketch the launch."))
        XCTAssertTrue(document.contents.contains("Here is the plan."))
        XCTAssertTrue(document.contents.hasSuffix("\n"))
    }

    func testDocumentIncludesTheProviderContinuitySummaryWithoutReplacingHistory() {
        var boundary = TranscriptEntry(
            kind: .compaction,
            text: "Summarized earlier messages")
        boundary.compactionSummary = "Continue the migration.\nKeep the storage invariant."
        boundary.compactionSummarySource = "claude_post_compact"
        boundary.compactionSummaryTruncated = true
        let conversation = Conversation(
            title: "Compacted conversation",
            cwd: "",
            sdkSessionId: nil,
            messages: [
                TranscriptEntry(kind: .user, text: "Preserve this full message."),
                boundary,
                TranscriptEntry(kind: .assistant, text: "Continuing after compaction."),
            ],
            updatedAt: Date())

        let document = ConversationMarkdownDocument(conversation: conversation)

        XCTAssertTrue(document.contents.contains("Preserve this full message."))
        XCTAssertTrue(document.contents.contains("**Claude continuity summary:**"))
        XCTAssertTrue(document.contents.contains("> Continue the migration."))
        XCTAssertTrue(document.contents.contains("> Keep the storage invariant."))
        XCTAssertTrue(document.contents.contains("Summary truncated"))
        XCTAssertTrue(document.contents.contains("Continuing after compaction."))
    }

    func testTemporaryFileContainsTheSameDocument() throws {
        let conversation = Conversation(
            title: "Finder export",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Keep this conversation.")],
            updatedAt: Date())
        let expected = ConversationMarkdownDocument(conversation: conversation)

        let url = try ConversationMarkdownExport.temporaryFile(
            for: expected,
            conversationID: conversation.id)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertEqual(url.lastPathComponent, expected.filename)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expected.contents)
    }
}
