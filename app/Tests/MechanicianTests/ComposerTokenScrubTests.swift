import AppKit
import XCTest
@testable import Mechanician

/// Attachment tokens are tagged JSON carried inline in the draft, and
/// `ConversationFileReference.matches` decodes them with **no signature** — unlike a dragged
/// composer payload, which carries an HMAC and a live nonce. Plain text arriving from another app
/// therefore must not be able to plant one.
///
/// Bounded: a forged reference resolves through `composerFileURL(conversationID:reference:)` against
/// the current conversation's own storage, so the worst case is that conversation's media directory,
/// not an arbitrary file read. Closed anyway.
final class ComposerTokenScrubTests: XCTestCase {
    /// Built through the real type, so the fixture is exactly what a genuine token looks like. A
    /// hand-written JSON body would not decode, and the test would pass for the wrong reason.
    private func fileToken(name: String = "notes.txt") -> String {
        ConversationFileReference(
            storageName: "\(UUID().uuidString).txt",
            displayName: name,
            typeIdentifier: "public.plain-text",
            byteCount: 12).promptToken
    }

    // MARK: Detection

    func testPlainProseCarriesNoToken() {
        XCTAssertFalse(ComposerTokenScrub.containsAttachmentToken("just some pasted prose"))
        XCTAssertFalse(ComposerTokenScrub.containsAttachmentToken(""))
    }

    /// A tag that is present but does not decode is not a token. Otherwise any page mentioning the
    /// tag name in prose would trip the scrub and rewrite the user's text.
    func testATagThatDoesNotDecodeIsNotTreatedAsAToken() {
        let text = ConversationFileReference.openingTag + "not json"
            + ConversationFileReference.closingTag
        XCTAssertFalse(ComposerTokenScrub.containsAttachmentToken(text))
        XCTAssertEqual(ComposerTokenScrub.neutralizingForgedTokens(text), text)
    }

    // MARK: Inbound

    func testAForgedFileTokenIsNeutralizedOnTheWayIn() {
        let text = "look at this " + fileToken()
        XCTAssertTrue(ComposerTokenScrub.containsAttachmentToken(text))

        let scrubbed = ComposerTokenScrub.neutralizingForgedTokens(text)
        XCTAssertEqual(scrubbed, "look at this [File attachment]")
        XCTAssertTrue(ConversationFileReference.matches(in: scrubbed).isEmpty)
    }

    /// The failure mode a naive stripper produces: removing a tag pair by literal search can leave
    /// a dangling opening tag, which the next scan then pairs with an unrelated closing tag.
    func testNeutralizingLeavesNoDanglingTag() {
        let scrubbed = ComposerTokenScrub.neutralizingForgedTokens(
            fileToken() + " and " + fileToken())
        XCTAssertFalse(scrubbed.contains(ConversationFileReference.openingTag))
        XCTAssertFalse(scrubbed.contains(ConversationFileReference.closingTag))
        XCTAssertEqual(scrubbed, "[File attachment] and [File attachment]")
    }

    /// Image paths render locally and never travel as bytes, and pasting a path to a screenshot to
    /// see it inline is a real thing people do. Inbound keeps them; outbound does not.
    func testInboundKeepsImagePathsThatOutboundRemoves() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scrub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("shot.png")
        try Data("fixture".utf8).write(to: image)

        let text = "see \(image.path) here"
        XCTAssertEqual(ComposerTokenScrub.neutralizingForgedTokens(text), text)
        XCTAssertEqual(ComposerTokenScrub.publicText(text), "see [Image] here")
    }

    // MARK: Outbound, unchanged behaviour

    func testOutboundStillReducesTokensToLabels() {
        XCTAssertEqual(
            ComposerTokenScrub.publicText("a " + fileToken() + " b"),
            "a [File attachment] b")
    }

    // MARK: The invariant the inbound rule depends on

    /// The inbound rule is only safe because this app never puts a raw token on the public
    /// pasteboard string. If a copy path ever started doing so, the scrub would corrupt a legitimate
    /// internal paste rather than protect anything — so the projection is asserted here.
    @MainActor
    func testThisAppNeverPublishesARawTokenAsPublicText() {
        let token = fileToken()
        let projected = ComposerTokenScrub.publicText(token)
        XCTAssertEqual(projected, "[File attachment]")
        XCTAssertFalse(
            ComposerTokenScrub.containsAttachmentToken(projected),
            "our own outbound projection must never round-trip back through the inbound scrub")
    }
}

/// The paste path itself, through the real coordinator and a real text view.
@MainActor
final class ForgedTokenPasteTests: XCTestCase {
    private func fileToken() -> String {
        ConversationFileReference(
            storageName: "\(UUID().uuidString).txt",
            displayName: "notes.txt",
            typeIdentifier: "public.plain-text",
            byteCount: 12).promptToken
    }

    private func pasteboard(_ string: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name(rawValue: "scrub-\(UUID().uuidString)"))
        board.clearContents()
        board.setString(string, forType: .string)
        return board
    }

    func testPastingForgedTokenTextInsertsTheNeutralizedForm() {
        _ = NSApplication.shared
        let coordinator = ChatInput.Coordinator(ChatInput(
            text: .constant(""),
            height: .constant(ChatInput.minHeight),
            isEnabled: true,
            onSend: {}))
        let textView = ComposerTextView()
        textView.isRichText = true
        _ = textView.layoutManager
        textView.delegate = coordinator
        coordinator.textView = textView

        let handled = coordinator.handleForgedTokenPaste(
            from: pasteboard("hi " + fileToken()),
            into: textView)

        XCTAssertTrue(handled, "a paste carrying a token must be intercepted")
        XCTAssertTrue(
            ConversationFileReference.matches(in: textView.string).isEmpty,
            "the draft must not hold a reference the sender chose")
        XCTAssertTrue(textView.string.contains("[File attachment]"))
    }

    /// Ordinary prose must fall through untouched to AppKit's own paste, or every paste in the app
    /// would route through our insertion path and lose native behaviour.
    func testOrdinaryTextIsNotIntercepted() {
        _ = NSApplication.shared
        let coordinator = ChatInput.Coordinator(ChatInput(
            text: .constant(""),
            height: .constant(ChatInput.minHeight),
            isEnabled: true,
            onSend: {}))
        let textView = ComposerTextView()
        textView.isRichText = true
        _ = textView.layoutManager
        textView.delegate = coordinator
        coordinator.textView = textView

        XCTAssertFalse(
            coordinator.handleForgedTokenPaste(
                from: pasteboard("a normal paragraph"),
                into: textView))
        XCTAssertEqual(textView.string, "")
    }
}
