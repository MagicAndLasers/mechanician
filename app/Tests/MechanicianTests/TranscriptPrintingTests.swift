import AppKit
import PDFKit
import XCTest
@testable import Mechanician

final class TranscriptPrintDocumentTests: XCTestCase {
    private func entry(_ kind: TranscriptEntry.Kind, _ text: String) -> TranscriptEntry {
        TranscriptEntry(kind: kind, text: text)
    }

    /// Policy, not formatting. A superseded row stays on screen as audit evidence, but the provider
    /// withdrew it and a document is a record of what was said. `transcriptMarkdown` already refuses
    /// to export these; print has to refuse for the same reason, in its own code path.
    func testRetractedContentIsNeverPrintable() {
        var retracted = entry(.assistant, "the withdrawn answer")
        retracted.supersessionEventID = UUID()
        let entries = [entry(.user, "ask"), retracted, entry(.assistant, "the real answer")]

        let printable = TranscriptPrintDocument.printableEntries(entries)
        XCTAssertEqual(printable.map(\.text), ["ask", "the real answer"])
    }

    /// The plan asked for this one by name: `permission` and `question` are transient prompts the
    /// app raised, not conversation, and they must stay dropped.
    func testPermissionAndQuestionAreDropped() {
        let entries = [
            entry(.user, "run the thing"),
            entry(.permission, "Allow Bash to run rm -rf?"),
            entry(.question, "Which file did you mean?"),
            entry(.assistant, "done"),
        ]
        let printable = TranscriptPrintDocument.printableEntries(entries)
        XCTAssertEqual(printable.map(\.kind), [.user, .assistant])
    }

    /// `TranscriptEntry.Kind` has eight cases. This asserts every one is classified deliberately —
    /// the switch in `printableEntries` is exhaustive by name, so a ninth case is a compile error
    /// rather than something that silently starts printing.
    func testEveryKindIsClassifiedExplicitly() {
        let all: [TranscriptEntry.Kind] = [
            .user, .assistant, .system, .tool, .permission, .question, .compaction, .review,
        ]
        XCTAssertEqual(all.count, 8, "a Kind case was added or removed; print must decide about it")
        let printable = TranscriptPrintDocument.printableEntries(all.map { entry($0, "text") })
        XCTAssertEqual(Set(printable.map(\.kind)), [.user, .assistant, .system, .tool, .compaction, .review])
    }

    func testEmptyEntriesAreDroppedButToolCallsSurvive() {
        var toolOnly = entry(.tool, "")
        toolOnly.toolName = "Read"
        let entries = [entry(.assistant, "   \n "), toolOnly, entry(.user, "real")]
        XCTAssertEqual(TranscriptPrintDocument.printableEntries(entries).count, 2)
    }

    /// Deliberately not "Claude": this app drives more than one provider, and a Codex conversation
    /// printed under Claude's name is wrong. The clipboard export still says Claude; that is a
    /// defect there, not a convention to copy.
    func testSpeakerLabelsAreProviderNeutral() {
        XCTAssertEqual(TranscriptPrintDocument.speakerLabel(for: entry(.user, "x")), "You")
        XCTAssertEqual(TranscriptPrintDocument.speakerLabel(for: entry(.assistant, "x")), "Assistant")
        XCTAssertNil(TranscriptPrintDocument.speakerLabel(for: entry(.tool, "x")))
        XCTAssertNil(TranscriptPrintDocument.speakerLabel(for: entry(.system, "x")))
    }

    @MainActor
    func testTheDocumentCarriesTitleAndProseAndOmitsRetracted() {
        var retracted = entry(.assistant, "WITHDRAWN-SENTINEL")
        retracted.supersededByFrameUUID = "f"
        let text = TranscriptPrintDocument.attributedDocument(
            title: "Pin controller notes",
            entries: [entry(.user, "where is the pin"), retracted, entry(.assistant, "one controller")]
        ).string

        XCTAssertTrue(text.contains("Pin controller notes"))
        XCTAssertTrue(text.contains("where is the pin"))
        XCTAssertTrue(text.contains("one controller"))
        XCTAssertFalse(text.contains("WITHDRAWN-SENTINEL"), "retracted content reached the page")
    }

    @MainActor
    func testClaudeContinuitySummaryIsPrintableAndExplicitlyLabeled() {
        var boundary = entry(.compaction, "")
        boundary.compactionSummary = "Retain the storage invariant and resume the migration."
        boundary.compactionSummarySource = "claude_post_compact"
        boundary.compactionSummaryTruncated = true

        XCTAssertEqual(TranscriptPrintDocument.printableEntries([boundary]).count, 1)
        let text = TranscriptPrintDocument.attributedDocument(
            title: "Compacted conversation",
            entries: [boundary]
        ).string
        XCTAssertTrue(text.contains("Claude continuity summary (truncated)"))
        XCTAssertTrue(text.contains("Retain the storage invariant and resume the migration."))
    }

    /// A conversation with nothing worth printing must not open a print panel over a blank page.
    @MainActor
    func testAConversationWithNothingPrintableProducesNoOperation() {
        let entries = [entry(.permission, "Allow?"), entry(.question, "Which one?")]
        XCTAssertTrue(TranscriptPrintDocument.printableEntries(entries).isEmpty)
    }
}

/// The print operation itself, exercised to PDF so pagination and the AppKit header/footer are
/// checked rather than assumed. Both were open questions before this shipped: whether a view that
/// has never been in a window can drive `NSPrintOperation`, and whether `NSPrintHeaderAndFooter` is
/// honored.
final class TranscriptPrintOperationTests: XCTestCase {
    @MainActor
    func testAnOffscreenViewPrintsAMultiPageDocumentWithHeaderAndFooter() throws {
        let entries = (1...40).map {
            TranscriptEntry(
                kind: $0.isMultiple(of: 2) ? .assistant : .user,
                text: "Paragraph \($0). " + String(repeating: "The quick brown fox. ", count: 12))
        }
        let view = TranscriptPrinting.makePrintView(title: "Printing Spike", entries: entries)
        XCTAssertNil(view.window, "the print view must never need a window")
        XCTAssertGreaterThan(view.frame.height, 0, "the view laid out no content")

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-print-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }

        let info = TranscriptPrinting.makePrintInfo()
        info.jobDisposition = NSPrintInfo.JobDisposition(rawValue: "NSPrintSaveJob")
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.jobTitle = "Printing Spike"
        XCTAssertTrue(operation.run(), "the print operation refused to run")

        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertGreaterThan(document.pageCount, 1, "40 paragraphs produced a single page")

        let firstPage = try XCTUnwrap(document.page(at: 0)?.string)
        XCTAssertTrue(firstPage.contains("Printing Spike"), "the AppKit header was not drawn")
        XCTAssertTrue(firstPage.contains("Page 1 of \(document.pageCount)"),
                      "the AppKit page footer was not drawn")
        XCTAssertTrue(firstPage.contains("Paragraph 1"))
    }
}
