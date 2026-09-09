import AppKit
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Mechanician

final class RFC822MessageTests: XCTestCase {
    func testMultipartMessagePrefersPlainTextAndKeepsAttachmentOutOfDerivedText() throws {
        let message = Data("""
        From: Example Sender <sender@example.test>\r
        Date: Wed, 30 Jul 2026 10:00:00 -0400\r
        Subject: =?UTF-8?Q?Quarterly_=E2=9C=93_Update?=\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="outer-boundary"\r
        \r
        --outer-boundary\r
        Content-Type: multipart/alternative; boundary="inner-boundary"\r
        \r
        --inner-boundary\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Plain body with a checkmark: =E2=9C=93\r
        --inner-boundary\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>HTML fallback</p>\r
        --inner-boundary--\r
        --outer-boundary\r
        Content-Type: application/pdf; name="private.pdf"\r
        Content-Disposition: attachment; filename="private.pdf"\r
        Content-Transfer-Encoding: base64\r
        \r
        U0VDUkVUX0FUVEFDSE1FTlRfQllURVM=\r
        --outer-boundary--\r
        """.utf8)

        let context = try XCTUnwrap(RFC822MessageParser.readableContext(from: message))

        XCTAssertEqual(context.subject, "Quarterly ✓ Update")
        XCTAssertEqual(context.sender, "Example Sender <sender@example.test>")
        XCTAssertEqual(context.readableText, "Plain body with a checkmark: ✓")
        XCTAssertFalse(context.readableText?.contains("SECRET_ATTACHMENT_BYTES") == true)
        XCTAssertTrue(context.canonicalContentNote.contains("retains MIME attachments"))
    }

    func testHTMLFallbackRemovesActiveMarkupAndNormalizesReadableText() throws {
        let message = Data("""
        Subject: HTML only
        Content-Type: text/html; charset=utf-8

        <style>.hidden { display: none }</style>
        <script>stealCredentials()</script>
        <h1>Hello &amp; welcome</h1><p>Safe body<br>Second line</p>
        """.utf8)

        let context = try XCTUnwrap(RFC822MessageParser.readableContext(from: message))

        XCTAssertEqual(context.readableText, "Hello & welcome\nSafe body\nSecond line")
        XCTAssertFalse(context.readableText?.contains("stealCredentials") == true)
        XCTAssertFalse(context.readableText?.contains("display: none") == true)
    }

    func testSafeSubjectFilenameRejectsPathAndControlCharacters() {
        let metadata = RFC822MessageParser.Metadata(
            subject: "../Q3: Plan\u{0}\nFinal",
            sender: nil,
            date: nil)

        let displayName = metadata.safeDisplayName(fallback: "message.eml")

        XCTAssertEqual(displayName, "Q3 Plan Final.eml")
        XCTAssertFalse(displayName.contains("/"))
        XCTAssertFalse(displayName.contains(":"))
        XCTAssertFalse(displayName.contains("\n"))
    }

    @MainActor
    func testMailReferencePresentationNamesItsMessageRoleInsteadOfLookingLikeGenericText() {
        let mail = ConversationFileReference(
            storageName: "\(UUID().uuidString).eml",
            displayName: "Release readiness.eml",
            typeIdentifier: UTType.emailMessage.identifier,
            byteCount: 4_096)
        let legacyMail = ConversationFileReference(
            storageName: "\(UUID().uuidString).eml",
            displayName: "Legacy message.eml",
            typeIdentifier: UTType.data.identifier,
            byteCount: 512)
        let text = ConversationFileReference(
            storageName: "\(UUID().uuidString).txt",
            displayName: "notes.txt",
            typeIdentifier: UTType.plainText.identifier,
            byteCount: 1_024)

        XCTAssertTrue(mail.isMailMessage)
        XCTAssertTrue(legacyMail.isMailMessage)
        XCTAssertFalse(text.isMailMessage)
        XCTAssertEqual(mail.attachmentDisplayTitle, "Release readiness")
        XCTAssertEqual(text.attachmentDisplayTitle, "notes.txt")
        XCTAssertTrue(ConversationFilePreview.composerDetail(for: mail)
            .hasPrefix("MAIL MESSAGE · "))
        XCTAssertFalse(ConversationFilePreview.composerDetail(for: text)
            .contains("MAIL MESSAGE"))

        let card = ConversationFilePreview.composerCard(
            reference: mail,
            url: URL(fileURLWithPath: "/tmp/Release readiness.eml"),
            preview: nil,
            fontSize: 13,
            appearance: NSAppearance(named: .aqua)!)
        XCTAssertGreaterThan(card.size.width, 150)
        XCTAssertGreaterThanOrEqual(card.size.height, 44)
    }

    @MainActor
    func testCanonicalEMLBytesAndSubjectNameSurviveConversationIntake() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MechanicianRFC822Intake-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Dragged Message.eml")
        let bytes = Data("""
        From: sender@example.test\r
        Subject: Release readiness\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Please review the release.
        """.utf8)
        try bytes.write(to: source)
        let store = ConversationStore(
            appSupportBaseOverride: base.appendingPathComponent("support", isDirectory: true),
            watchesDirectory: false)
        let conversationID = UUID()

        let intake = ConversationAttachmentIntake.ingest(
            source,
            conversationID: conversationID,
            store: store)
        guard case .file(let reference, let ownedURL) = intake else {
            return XCTFail("An .eml file must use the generic conversation-owned attachment path.")
        }

        XCTAssertEqual(reference.displayName, "Release readiness.eml")
        XCTAssertEqual(reference.typeIdentifier, UTType.emailMessage.identifier)
        XCTAssertEqual(try Data(contentsOf: ownedURL), bytes)
        let expanded = store.providerPrompt(
            from: reference.promptToken,
            conversationID: conversationID)
        let contextJSON = try XCTUnwrap(
            expanded.components(separatedBy: "<mechanician-file-context>").last?
                .components(separatedBy: "</mechanician-file-context>").first)
        let context = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contextJSON.utf8)) as? [String: Any])
        let readableMail = try XCTUnwrap(context["readableMail"] as? [String: Any])
        XCTAssertEqual(readableMail["subject"] as? String, "Release readiness")
        XCTAssertEqual(
            readableMail["readableText"] as? String,
            "Please review the release.")
        XCTAssertEqual(context["path"] as? String, ownedURL.path)
        XCTAssertEqual(try Data(contentsOf: ownedURL), bytes)
    }

    func testOversizedOrHeaderlessDataDoesNotBecomeMailContext() {
        XCTAssertNil(RFC822MessageParser.readableContext(from: Data("no headers".utf8)))
        XCTAssertNil(RFC822MessageParser.readableContext(
            from: Data(repeating: 0x41, count: RFC822MessageParser.maximumProviderInputBytes + 1)))
    }
}
