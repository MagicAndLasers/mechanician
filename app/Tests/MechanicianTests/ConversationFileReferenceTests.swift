import AppKit
import Foundation
import XCTest
@testable import Mechanician

final class ConversationFileReferenceTests: XCTestCase {
    func testTokenRoundTripPreservesTypedNameWithoutPersistingAnExternalPath() throws {
        let reference = ConversationFileReference(
            storageName: "\(UUID().uuidString).pdf",
            displayName: "Quarterly plan <final>.pdf",
            typeIdentifier: "com.adobe.pdf",
            byteCount: 42)

        let token = reference.promptToken
        let match = try XCTUnwrap(ConversationFileReference.matches(in: "before \(token) after").first)

        XCTAssertEqual(match.reference, reference)
        XCTAssertFalse(token.contains("/Users/david/Desktop"))
        XCTAssertFalse(token.contains("</mechanician-file-reference></mechanician-file-reference>"))
        XCTAssertEqual(
            ("before \(token) after" as NSString).substring(with: match.range),
            token)
    }

    func testMalformedOrTraversalTokensRemainInert() throws {
        let invalid = ConversationFileReference(
            storageName: "../secret.txt",
            displayName: "secret.txt",
            typeIdentifier: "public.plain-text",
            byteCount: 5)
        let data = try JSONEncoder().encode(invalid)
        let token = ConversationFileReference.openingTag
            + String(decoding: data, as: UTF8.self)
            + ConversationFileReference.closingTag

        XCTAssertTrue(ConversationFileReference.matches(in: token).isEmpty)
        XCTAssertFalse(ConversationFileReference(
            storageName: "report.pdf",
            displayName: "report.pdf",
            typeIdentifier: "com.adobe.pdf",
            byteCount: 4).isValid)
    }

    @MainActor
    func testGenericFileCopyIsConversationOwnedAndProviderExpansionRequiresExactOwner() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MechanicianFileReferenceTests-\(UUID().uuidString)",
                                    isDirectory: true)
        let sourceDirectory = base.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = sourceDirectory.appendingPathComponent("Project brief.pdf")
        let bytes = Data("%PDF-1.7\nattached".utf8)
        try bytes.write(to: source)

        let store = ConversationStore(
            appSupportBaseOverride: base.appendingPathComponent("support", isDirectory: true),
            watchesDirectory: false)
        let ownerID = UUID()
        let otherID = UUID()
        let reference = try XCTUnwrap(store.persistComposerFile(
            at: source,
            conversationID: ownerID))
        XCTAssertEqual(reference.displayName, "Project brief.pdf")
        XCTAssertEqual(reference.typeIdentifier, "com.adobe.pdf")
        XCTAssertEqual(reference.byteCount, bytes.count)

        let ownedURL = try XCTUnwrap(store.composerFileURL(
            conversationID: ownerID,
            reference: reference))
        XCTAssertNotEqual(ownedURL, source)
        XCTAssertTrue(ownedURL.path.contains("/\(ownerID.uuidString)/"))
        XCTAssertEqual(try Data(contentsOf: ownedURL), bytes)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: ownedURL), bytes)

        let prompt = "Review \(reference.promptToken)"
        let expanded = store.providerPrompt(from: prompt, conversationID: ownerID)
        XCTAssertTrue(expanded.contains("<mechanician-file-context>"))
        XCTAssertTrue(expanded.contains("Project brief.pdf"))
        XCTAssertFalse(expanded.contains(ConversationFileReference.openingTag))
        let contextJSON = try XCTUnwrap(
            expanded.components(separatedBy: "<mechanician-file-context>").last?
                .components(separatedBy: "</mechanician-file-context>").first)
        let context = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contextJSON.utf8)) as? [String: Any])
        XCTAssertEqual(context["path"] as? String, ownedURL.path)

        XCTAssertEqual(
            store.providerPrompt(from: prompt, conversationID: otherID),
            prompt,
            "A reference cannot expose another conversation's path.")

        let wrongSize = ConversationFileReference(
            storageName: reference.storageName,
            displayName: reference.displayName,
            typeIdentifier: reference.typeIdentifier,
            byteCount: reference.byteCount + 1)
        XCTAssertEqual(
            store.providerPrompt(from: wrongSize.promptToken, conversationID: ownerID),
            wrongSize.promptToken,
            "A token whose metadata does not match the owned bytes must stay inert.")
    }

    func testGenericFileCopyRejectsSymlinksAndOversizedInputsWithoutPartialFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MechanicianFileCopySafety-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ConversationMediaStorage(
            root: root.appendingPathComponent("media", isDirectory: true))
        let ownerID = UUID()
        let target = root.appendingPathComponent("target.bin")
        try Data(repeating: 0xAB, count: 8).write(to: target)
        let symlink = root.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        XCTAssertNil(try storage.persistComposerFile(
            at: symlink,
            conversationID: ownerID))
        XCTAssertNil(try storage.persistComposerFile(
            at: target,
            conversationID: ownerID,
            maximumBytes: 7))

        let ownerDirectory = storage.root.appendingPathComponent(
            ownerID.uuidString,
            isDirectory: true)
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: ownerDirectory.path)) ?? [],
            [],
            "Rejected descriptor copies must not leave partial conversation media.")
    }

    @MainActor
    func testProviderExpansionPreservesAuthoredAttachmentOrder() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MechanicianFileOrderTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let firstURL = base.appendingPathComponent("First notes.txt")
        let secondURL = base.appendingPathComponent("Second table.csv")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let store = ConversationStore(
            appSupportBaseOverride: base.appendingPathComponent("support", isDirectory: true),
            watchesDirectory: false)
        let ownerID = UUID()
        let first = try XCTUnwrap(store.persistComposerFile(
            at: firstURL,
            conversationID: ownerID))
        let second = try XCTUnwrap(store.persistComposerFile(
            at: secondURL,
            conversationID: ownerID))
        let prompt = "before \(first.promptToken) between \(second.promptToken) after"

        let expanded = store.providerPrompt(from: prompt, conversationID: ownerID)

        let firstIndex = try XCTUnwrap(expanded.range(of: "First notes.txt")?.lowerBound)
        let secondIndex = try XCTUnwrap(expanded.range(of: "Second table.csv")?.lowerBound)
        XCTAssertLessThan(firstIndex, secondIndex)
        XCTAssertTrue(expanded.hasPrefix("before "))
        XCTAssertTrue(expanded.hasSuffix(" after"))
        XCTAssertEqual(
            userMessagePresentationSegments(text: prompt, imagePaths: nil),
            [
                .text(0, "before "),
                .file(1, first),
                .text(2, " between "),
                .file(3, second),
                .text(4, " after"),
            ])
    }

    @MainActor
    func testRecoveredDraftClonesGenericFileIntoTheDestinationConversation() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MechanicianFileCloneTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("notes.rtf")
        let bytes = Data("{\\rtf1 Durable attachment}".utf8)
        try bytes.write(to: source)
        let store = ConversationStore(
            appSupportBaseOverride: base.appendingPathComponent("support", isDirectory: true),
            watchesDirectory: false)
        let sourceID = UUID()
        let destinationID = UUID()
        let reference = try XCTUnwrap(store.persistComposerFile(
            at: source,
            conversationID: sourceID))
        let prompt = "Use \(reference.promptToken) twice \(reference.promptToken)"

        let recovered = store.cloneComposerMediaPaths(
            in: prompt,
            from: sourceID,
            to: destinationID)
        let recoveredReferences = ConversationFileReference.matches(in: recovered).map(\.reference)

        XCTAssertEqual(recoveredReferences.count, 2)
        XCTAssertEqual(Set(recoveredReferences).count, 1)
        XCTAssertNotEqual(recoveredReferences[0].storageName, reference.storageName)
        let destinationURL = try XCTUnwrap(store.composerFileURL(
            conversationID: destinationID,
            reference: recoveredReferences[0]))
        XCTAssertEqual(try Data(contentsOf: destinationURL), bytes)
    }

    @MainActor
    func testComposerAndTranscriptRestoreFileTokenAtItsAuthoredPosition() throws {
        _ = NSApplication.shared
        let reference = ConversationFileReference(
            storageName: "\(UUID().uuidString).docx",
            displayName: "Named attachment.docx",
            typeIdentifier: "org.openxmlformats.wordprocessingml.document",
            byteCount: 1234)
        let serialized = "before \(reference.promptToken) after"
        let input = ChatInput(
            text: .constant(""),
            height: .constant(ChatInput.minHeight),
            isEnabled: true,
            onSend: {})
        let coordinator = ChatInput.Coordinator(input)
        let textView = ComposerTextView()
        textView.isRichText = true
        _ = textView.layoutManager
        textView.delegate = coordinator
        coordinator.textView = textView

        coordinator.restoreSerializedContent(serialized, into: textView)

        XCTAssertEqual(coordinator.serialize(textView), serialized)
        XCTAssertEqual(textView.textStorage?.string, "before \u{fffc} after")
        let attachment = textView.textStorage?.attribute(
            .attachment,
            at: 7,
            effectiveRange: nil) as? NSTextAttachment
        XCTAssertNotNil(attachment)
        XCTAssertNotNil(attachment?.image, "The composer must synchronously show a file-icon fallback.")
        XCTAssertGreaterThan(attachment?.image?.size.width ?? 0, 100)
        XCTAssertEqual(
            userMessagePresentationSegments(text: serialized, imagePaths: nil),
            [
                .text(0, "before "),
                .file(1, reference),
                .text(2, " after"),
            ])
    }

    @MainActor
    func testComposerFileCardRerendersForTargetEffectiveAppearance() throws {
        _ = NSApplication.shared
        let reference = ConversationFileReference(
            storageName: "\(UUID().uuidString).pdf",
            displayName: "Appearance.pdf",
            typeIdentifier: "com.adobe.pdf",
            byteCount: 42)
        let input = ChatInput(
            text: .constant(""),
            height: .constant(ChatInput.minHeight),
            isEnabled: true,
            onSend: {})
        let coordinator = ChatInput.Coordinator(input)
        let textView = ComposerTextView()
        textView.isRichText = true
        _ = textView.layoutManager
        textView.delegate = coordinator
        coordinator.textView = textView
        textView.appearance = NSAppearance(named: .aqua)
        coordinator.restoreSerializedContent(reference.promptToken, into: textView)
        let attachment = try XCTUnwrap(textView.textStorage?.attribute(
            .attachment,
            at: 0,
            effectiveRange: nil) as? NSTextAttachment)
        let lightLuminance = try cardBackgroundLuminance(
            try XCTUnwrap(attachment.image))

        textView.appearance = NSAppearance(named: .darkAqua)
        coordinator.refreshFileAttachmentAppearance(in: textView)
        let darkLuminance = try cardBackgroundLuminance(
            try XCTUnwrap(attachment.image))

        XCTAssertGreaterThan(
            lightLuminance,
            darkLuminance + 0.25,
            "The card bitmap must be redrawn under its text view's effective appearance.")
    }

    private func cardBackgroundLuminance(_ image: NSImage) throws -> CGFloat {
        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let color = try XCTUnwrap(bitmap.colorAt(
            x: max(1, bitmap.pixelsWide - 12),
            y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        return 0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
    }
}
