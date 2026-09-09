import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

private final class ComposerPasteboardDataProbe:
    NSObject,
    NSPasteboardItemDataProvider
{
    let data: Data
    private(set) var requestCount = 0

    init(data: Data) {
        self.data = data
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        requestCount += 1
        item.setData(data, forType: type)
    }
}

@MainActor
final class ComposerAttachmentReorderingTests: XCTestCase {
    private func attachment(_ payload: String) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: 20, height: 12))
        let attributed = NSMutableAttributedString(attachment: attachment)
        attributed.addAttributes(
            [
                ChatInput.payloadKey: payload,
                NSAttributedString.Key("test-preserved"): "yes",
            ],
            range: NSRange(location: 0, length: attributed.length))
        return attributed
    }

    private func content(
        _ segments: [Either<String, String>]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for segment in segments {
            switch segment {
            case .left(let text):
                result.append(NSAttributedString(string: text))
            case .right(let payload):
                result.append(attachment(payload))
            }
        }
        return result
    }

    private func range(
        ofPayload payload: String,
        in content: NSAttributedString
    ) -> NSRange? {
        guard content.length > 0 else { return nil }
        var result: NSRange?
        content.enumerateAttributes(
            in: NSRange(location: 0, length: content.length)
        ) { attributes, range, stop in
            guard attributes[.attachment] != nil,
                  attributes[ChatInput.payloadKey] as? String == payload else { return }
            result = range
            stop.pointee = true
        }
        return result
    }

    func testForwardRangeMoveAdjustsForDeletionAndPreservesEveryAttachmentAttribute() throws {
        let original = content([
            .left("before"),
            .right("payload-a"),
            .left("after"),
        ])
        let source = try XCTUnwrap(range(ofPayload: "payload-a", in: original))

        let move = try XCTUnwrap(ComposerAttachmentReordering.move(
            in: original,
            attachmentRange: source,
            to: original.length))

        XCTAssertEqual(original.string, "before\u{fffc}after", "the source snapshot is immutable")
        XCTAssertEqual(move.content.string, "beforeafter\u{fffc}")
        XCTAssertEqual(move.insertionIndex, original.length - source.length)
        XCTAssertEqual(move.selection, NSRange(location: move.content.length, length: 0))
        let movedRange = try XCTUnwrap(range(ofPayload: "payload-a", in: move.content))
        XCTAssertEqual(
            move.content.attribute(
                NSAttributedString.Key("test-preserved"),
                at: movedRange.location,
                effectiveRange: nil) as? String,
            "yes")
        XCTAssertNotNil(move.content.attribute(
            .attachment,
            at: movedRange.location,
            effectiveRange: nil))
    }

    func testAttachmentCanMoveBeforeBetweenAndAfterTextWithoutConsumingText() throws {
        let base = content([
            .left("left"),
            .right("a"),
            .left("middle"),
            .right("b"),
            .left("right"),
        ])

        let before = try XCTUnwrap(ComposerAttachmentReordering.move(
            in: base,
            attachmentRange: try XCTUnwrap(range(ofPayload: "b", in: base)),
            to: 0))
        XCTAssertEqual(before.content.string, "\u{fffc}left\u{fffc}middleright")
        XCTAssertEqual(
            ComposerAttachmentReordering.payloads(in: before.content),
            ["b", "a"])

        let between = try XCTUnwrap(ComposerAttachmentReordering.move(
            in: base,
            attachmentRange: try XCTUnwrap(range(ofPayload: "a", in: base)),
            to: 2))
        XCTAssertEqual(between.content.string, "le\u{fffc}ftmiddle\u{fffc}right")
        XCTAssertEqual(
            ComposerAttachmentReordering.payloads(in: between.content),
            ["a", "b"])

        let after = try XCTUnwrap(ComposerAttachmentReordering.move(
            in: base,
            attachmentRange: try XCTUnwrap(range(ofPayload: "a", in: base)),
            to: base.length))
        XCTAssertEqual(after.content.string, "leftmiddle\u{fffc}right\u{fffc}")
        XCTAssertEqual(
            ComposerAttachmentReordering.payloads(in: after.content),
            ["b", "a"])

        for moved in [before.content, between.content, after.content] {
            XCTAssertEqual(moved.string.filter { $0 != "\u{fffc}" }, "leftmiddleright")
            XCTAssertEqual(ComposerAttachmentReordering.payloads(in: moved).count, 2)
        }
    }

    func testInvalidOrSelfIntersectingRangesAreNoOps() throws {
        let original = content([.left("x"), .right("a"), .left("y")])
        let source = try XCTUnwrap(range(ofPayload: "a", in: original))

        XCTAssertNil(ComposerAttachmentReordering.move(
            in: original,
            attachmentRange: source,
            to: source.location))
        XCTAssertNil(ComposerAttachmentReordering.move(
            in: original,
            attachmentRange: source,
            to: NSMaxRange(source)))
        XCTAssertNil(ComposerAttachmentReordering.move(
            in: original,
            attachmentRange: NSRange(location: 0, length: 1),
            to: original.length))
        XCTAssertNil(ComposerAttachmentReordering.move(
            in: original,
            attachmentRange: source,
            to: original.length + 1))
    }

    func testMixedImageFileAndArtifactPayloadsMoveWithoutDuplicationOrLoss() throws {
        let file = ConversationFileReference(
            storageName: "\(UUID().uuidString).pdf",
            displayName: "Plan.pdf",
            typeIdentifier: "com.adobe.pdf",
            byteCount: 42)
        let artifact = ArtifactDragReference(
            artifactID: UUID(),
            title: "Dashboard",
            type: "html",
            currentSourcePath: "/tmp/Dashboard.html")
        let imagePath = "/tmp/Pasted image.png"
        let original = content([
            .right(imagePath),
            .left(" then "),
            .right(file.promptToken),
            .left(" then "),
            .right(artifact.promptToken),
        ])

        let moved = try XCTUnwrap(ComposerAttachmentReordering.move(
            in: original,
            attachmentRange: try XCTUnwrap(
                range(ofPayload: artifact.promptToken, in: original)),
            to: 0))

        XCTAssertEqual(
            ComposerAttachmentReordering.payloads(in: moved.content),
            [artifact.promptToken, imagePath, file.promptToken])
        XCTAssertEqual(
            Set(ComposerAttachmentReordering.payloads(in: moved.content)),
            Set([imagePath, file.promptToken, artifact.promptToken]))
    }

    func testReorderedDraftRestoresAndProviderExpansionFollowsVisualOrder() throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MechanicianAttachmentReorder-\(UUID().uuidString)",
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
        let conversationID = UUID()
        let first = try XCTUnwrap(store.persistComposerFile(
            at: firstURL,
            conversationID: conversationID))
        let second = try XCTUnwrap(store.persistComposerFile(
            at: secondURL,
            conversationID: conversationID))
        let serialized = "Start \(first.promptToken) middle \(second.promptToken) end"
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
        let attributed = try XCTUnwrap(textView.textStorage)
        let secondRange = try XCTUnwrap(
            range(ofPayload: second.promptToken, in: attributed))
        let firstRange = try XCTUnwrap(
            range(ofPayload: first.promptToken, in: attributed))
        let moved = try XCTUnwrap(ComposerAttachmentReordering.move(
            in: attributed,
            attachmentRange: secondRange,
            to: firstRange.location))
        attributed.setAttributedString(moved.content)

        let reordered = coordinator.serialize(textView)
        XCTAssertEqual(
            ConversationFileReference.matches(in: reordered).map(\.reference),
            [second, first])
        let expanded = store.providerPrompt(
            from: reordered,
            conversationID: conversationID)
        let secondIndex = try XCTUnwrap(expanded.range(of: second.displayName)?.lowerBound)
        let firstIndex = try XCTUnwrap(expanded.range(of: first.displayName)?.lowerBound)
        XCTAssertLessThan(secondIndex, firstIndex)

        let restoredView = ComposerTextView()
        restoredView.isRichText = true
        _ = restoredView.layoutManager
        restoredView.delegate = coordinator
        coordinator.textView = restoredView
        coordinator.restoreSerializedContent(reordered, into: restoredView)
        XCTAssertEqual(coordinator.serialize(restoredView), reordered)
        XCTAssertEqual(
            ComposerAttachmentReordering.payloads(
                in: try XCTUnwrap(restoredView.textStorage)),
            [second.promptToken, first.promptToken])
    }

    func testCoordinatorMovePublishesDraftAndSupportsUndoRedoWithoutLosingPayloads() throws {
        _ = NSApplication.shared
        let original = content([
            .left("first "),
            .right("image-path"),
            .left(" between "),
            .right("file-token"),
            .left(" last"),
        ])
        var draft = ""
        var height = ChatInput.minHeight
        let input = ChatInput(
            text: Binding(
                get: { draft },
                set: { draft = $0 }),
            height: Binding(
                get: { height },
                set: { height = $0 }),
            isEnabled: true,
            onSend: {})
        let coordinator = ChatInput.Coordinator(input)
        let textView = ComposerTextView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 80))
        textView.isRichText = true
        textView.isEditable = true
        textView.allowsUndo = true
        _ = textView.layoutManager
        textView.delegate = coordinator
        coordinator.textView = textView
        textView.textStorage?.setAttributedString(original)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 80),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.contentView = textView
        window.makeFirstResponder(textView)

        let originalSerialized = coordinator.serialize(textView)
        draft = originalSerialized
        coordinator.lastSerialized = originalSerialized
        let source = try XCTUnwrap(range(ofPayload: "file-token", in: original))
        XCTAssertTrue(coordinator.moveAttachment(
            in: textView,
            attachmentRange: source,
            to: 0))

        let movedSerialized = coordinator.serialize(textView)
        XCTAssertEqual(draft, movedSerialized)
        XCTAssertEqual(
            ComposerAttachmentReordering.payloads(
                in: try XCTUnwrap(textView.textStorage)),
            ["file-token", "image-path"])
        XCTAssertTrue(textView.undoManager?.canUndo == true)

        textView.undoManager?.undo()
        XCTAssertEqual(coordinator.serialize(textView), originalSerialized)
        XCTAssertEqual(draft, originalSerialized)
        XCTAssertEqual(
            ComposerAttachmentReordering.payloads(
                in: try XCTUnwrap(textView.textStorage)),
            ["image-path", "file-token"])
        XCTAssertTrue(textView.undoManager?.canRedo == true)

        textView.undoManager?.redo()
        XCTAssertEqual(coordinator.serialize(textView), movedSerialized)
        XCTAssertEqual(draft, movedSerialized)
        XCTAssertEqual(
            ComposerAttachmentReordering.payloads(
                in: try XCTUnwrap(textView.textStorage)),
            ["file-token", "image-path"])
    }

    func testDescriptorCopyUsesRequestedCharacterBoundaryAndKeepsOnePayload() throws {
        _ = NSApplication.shared
        var draft = "ABCD"
        var height = ChatInput.minHeight
        let input = ChatInput(
            text: Binding(
                get: { draft },
                set: { draft = $0 }),
            height: Binding(
                get: { height },
                set: { height = $0 }),
            isEnabled: true,
            onSend: {})
        let coordinator = ChatInput.Coordinator(input)
        let textView = ComposerTextView()
        textView.isRichText = true
        _ = textView.layoutManager
        textView.delegate = coordinator
        coordinator.textView = textView
        textView.textStorage?.setAttributedString(NSAttributedString(string: draft))
        coordinator.lastSerialized = draft

        let reference = ArtifactDragReference(
            artifactID: UUID(),
            title: "Drop Coordinate",
            type: "markdown",
            currentSourcePath: "/tmp/Drop Coordinate.md")
        let descriptor = ComposerAttachmentDragDescriptor(
            nonce: UUID(),
            payload: reference.promptToken,
            sourceConversationID: UUID())
        let item = NSPasteboardItem()
        item.setData(
            try XCTUnwrap(descriptor.processSignedEncodedData),
            forType: ComposerAttachmentDragDescriptor.pasteboardType)
        item.setString("[Artifact]", forType: .string)
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("attachment-reorder-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        ComposerAttachmentDragRegistry.register(descriptor.nonce)
        defer { ComposerAttachmentDragRegistry.retire(descriptor.nonce) }

        XCTAssertEqual(coordinator.dropOperation(for: pasteboard), .copy)
        XCTAssertTrue(coordinator.handleDrop(
            from: pasteboard,
            into: textView,
            insertionIndex: 2))
        XCTAssertEqual(
            coordinator.serialize(textView),
            "AB\(reference.promptToken) CD")
        XCTAssertEqual(draft, "AB\(reference.promptToken) CD")
        XCTAssertEqual(
            ComposerAttachmentReordering.payloads(
                in: try XCTUnwrap(textView.textStorage)),
            [reference.promptToken])
    }

    func testCapturedSignedDescriptorRequiresItsLiveVisibleProjection() throws {
        _ = NSApplication.shared
        let reference = ArtifactDragReference(
            artifactID: UUID(),
            title: "Captured private artifact",
            type: "markdown",
            currentSourcePath: "/tmp/Captured private artifact.md")
        let descriptor = ComposerAttachmentDragDescriptor(
            nonce: UUID(),
            payload: reference.promptToken,
            sourceConversationID: UUID())
        ComposerAttachmentDragRegistry.register(descriptor.nonce)
        defer { ComposerAttachmentDragRegistry.retire(descriptor.nonce) }

        for visibleText in ["Visible decoy", nil] as [String?] {
            var draft = "AB"
            let input = ChatInput(
                text: Binding(get: { draft }, set: { draft = $0 }),
                height: .constant(ChatInput.minHeight),
                isEnabled: true,
                onSend: {})
            let coordinator = ChatInput.Coordinator(input)
            let textView = ComposerTextView()
            textView.isRichText = true
            textView.isEditable = true
            textView.delegate = coordinator
            coordinator.textView = textView
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: draft))
            coordinator.lastSerialized = draft

            let item = NSPasteboardItem()
            item.setData(
                try XCTUnwrap(descriptor.processSignedEncodedData),
                forType: ComposerAttachmentDragDescriptor.pasteboardType)
            if let visibleText {
                item.setString(visibleText, forType: .string)
            }
            let pasteboard = NSPasteboard(name: .init(
                "captured-descriptor-visible-\(UUID().uuidString)"))
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects([item]))

            XCTAssertTrue(coordinator.handleDrop(
                from: pasteboard,
                into: textView,
                insertionIndex: 1))
            XCTAssertEqual(
                draft,
                visibleText.map { "A\($0)B" } ?? "AB")
            XCTAssertFalse(draft.contains(ArtifactDragReference.openingTag))
            XCTAssertTrue(ComposerAttachmentReordering.payloads(
                in: try XCTUnwrap(textView.textStorage)).isEmpty)
        }
    }

    func testCapturedSignedDescriptorIsRejectedAfterDragNonceRetires() throws {
        _ = NSApplication.shared
        let reference = ArtifactDragReference(
            artifactID: UUID(),
            title: "Retired private artifact",
            type: "markdown",
            currentSourcePath: "/tmp/Retired private artifact.md")
        let descriptor = ComposerAttachmentDragDescriptor(
            nonce: UUID(),
            payload: reference.promptToken,
            sourceConversationID: UUID())
        ComposerAttachmentDragRegistry.register(descriptor.nonce)
        XCTAssertTrue(ComposerAttachmentDragRegistry.contains(descriptor.nonce))
        ComposerAttachmentDragRegistry.retire(descriptor.nonce)
        XCTAssertFalse(ComposerAttachmentDragRegistry.contains(descriptor.nonce))

        let item = NSPasteboardItem()
        item.setData(
            try XCTUnwrap(descriptor.processSignedEncodedData),
            forType: ComposerAttachmentDragDescriptor.pasteboardType)
        item.setString("[Artifact]", forType: .string)
        let pasteboard = NSPasteboard(name: .init(
            "captured-descriptor-retired-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        var draft = ""
        let input = ChatInput(
            text: Binding(get: { draft }, set: { draft = $0 }),
            height: .constant(ChatInput.minHeight),
            isEnabled: true,
            onSend: {})
        let coordinator = ChatInput.Coordinator(input)
        let textView = ComposerTextView()
        textView.isRichText = true
        textView.isEditable = true
        textView.delegate = coordinator
        coordinator.textView = textView

        XCTAssertTrue(coordinator.handleDrop(
            from: pasteboard,
            into: textView))
        XCTAssertEqual(draft, "[Artifact]")
        XCTAssertTrue(ComposerAttachmentReordering.payloads(
            in: try XCTUnwrap(textView.textStorage)).isEmpty)
    }

    func testForgedDescriptorUsesOnlyItsVisibleDropText() throws {
        _ = NSApplication.shared
        var draft = "AB"
        let input = ChatInput(
            text: Binding(get: { draft }, set: { draft = $0 }),
            height: .constant(ChatInput.minHeight),
            isEnabled: true,
            onSend: {},
            conversationID: UUID())
        let coordinator = ChatInput.Coordinator(input)
        let textView = ComposerTextView()
        textView.isRichText = true
        textView.isEditable = true
        textView.delegate = coordinator
        coordinator.textView = textView
        textView.textStorage?.setAttributedString(NSAttributedString(string: draft))
        coordinator.lastSerialized = draft

        // Naming a plausible conversation and advertising the private UTI is not provenance. This
        // descriptor has no process signature and its hidden payload must never reach the draft.
        let descriptor = ComposerAttachmentDragDescriptor(
            nonce: UUID(),
            payload: "INVISIBLE FORGED PROMPT",
            sourceConversationID: UUID())
        let item = NSPasteboardItem()
        item.setData(
            try XCTUnwrap(descriptor.encodedData),
            forType: ComposerAttachmentDragDescriptor.pasteboardType)
        item.setString("Visible dropped text", forType: .string)
        let pasteboard = NSPasteboard(
            name: .init("forged-attachment-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertTrue(coordinator.handleDrop(
            from: pasteboard,
            into: textView,
            insertionIndex: 1))
        XCTAssertEqual(draft, "AVisible dropped textB")
        XCTAssertFalse(draft.contains("INVISIBLE FORGED PROMPT"))
        XCTAssertTrue(ComposerAttachmentReordering.payloads(
            in: try XCTUnwrap(textView.textStorage)).isEmpty)
    }

    func testClipboardPayloadRejectsOversizedPrivateMetadataBeforeEncoding() {
        let payload = ComposerClipboardPayload(
            sourceConversationID: UUID(),
            segments: [
                .init(
                    kind: .text,
                    content: String(
                        repeating: "x",
                        count: ComposerClipboardPayload.maximumEncodedBytes + 1)),
            ])

        XCTAssertNil(payload.encodedData)
        XCTAssertNil(payload.processSignedEncodedData)
        XCTAssertNil(ComposerClipboardPayload.decode(Data(
            repeating: 0,
            count: ComposerClipboardPayload.maximumEncodedBytes + 1)))
        XCTAssertNil(ComposerClipboardPayload.decodeProcessPrivate(Data(
            repeating: 0,
            count: ComposerClipboardPayload.maximumEncodedBytes + 1)))
    }

    func testClipboardPrivateItemLookupStopsAtValidAndBoundsItsPrefix() throws {
        _ = NSApplication.shared
        let coordinator = ChatInput.Coordinator(ChatInput(
            text: .constant(""),
            height: .constant(ChatInput.minHeight),
            isEnabled: true,
            onSend: {}))
        let payload = ComposerClipboardPayload(
            sourceConversationID: UUID(),
            segments: [.init(kind: .text, content: "bounded")])
        let validData = try XCTUnwrap(payload.processSignedEncodedData)

        func pasteboard(
            data: [Data]
        ) -> (NSPasteboard, [ComposerPasteboardDataProbe]) {
            let probes = data.map(ComposerPasteboardDataProbe.init(data:))
            let items = probes.map { probe -> NSPasteboardItem in
                let item = NSPasteboardItem()
                item.setDataProvider(
                    probe,
                    forTypes: [ComposerClipboardPayload.pasteboardType])
                return item
            }
            let pasteboard = NSPasteboard(name: .init(
                "bounded-private-items-\(UUID().uuidString)"))
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects(items))
            return (pasteboard, probes)
        }

        let (earlyPasteboard, earlyProbes) = pasteboard(data: [
            Data([0]),
            validData,
            Data([1]),
            Data([2]),
            Data([3]),
        ])
        let decodedEarly = try XCTUnwrap(
            coordinator.composerClipboardPayload(from: earlyPasteboard))
        XCTAssertEqual(decodedEarly.sourceConversationID, payload.sourceConversationID)
        XCTAssertEqual(decodedEarly.segments, payload.segments)
        XCTAssertTrue(decodedEarly.isTrustedForCurrentProcess)
        XCTAssertGreaterThanOrEqual(earlyProbes[0].requestCount, 1)
        XCTAssertGreaterThanOrEqual(earlyProbes[1].requestCount, 1)
        XCTAssertEqual(
            earlyProbes.dropFirst(2).map(\.requestCount),
            [0, 0, 0],
            "lookup must stop as soon as one authenticated item is found")

        let (latePasteboard, lateProbes) = pasteboard(data: [
            Data([0]),
            Data([1]),
            Data([2]),
            Data([3]),
            validData,
        ])
        XCTAssertNil(coordinator.composerClipboardPayload(from: latePasteboard))
        XCTAssertEqual(
            lateProbes[ComposerClipboardPayload.maximumPasteboardItems]
                .requestCount,
            0,
            "items beyond the bounded prefix must never be retrieved")
    }

    func testPrivateDragDescriptorsRejectOversizedDataBeforeTrustValidation() {
        let descriptor = ComposerAttachmentDragDescriptor(
            nonce: UUID(),
            payload: String(
                repeating: "x",
                count: ComposerAttachmentDragDescriptor.maximumPayloadBytes + 1),
            sourceConversationID: UUID())

        XCTAssertNil(descriptor.encodedData)
        XCTAssertNil(descriptor.signedForCurrentProcess.encodedData)
        XCTAssertNil(descriptor.processSignedEncodedData)
        XCTAssertNil(ComposerAttachmentDragDescriptor.decode(Data(
            repeating: 0,
            count: ComposerAttachmentDragDescriptor.maximumEncodedBytes + 1)))
        XCTAssertNil(ComposerAttachmentDragDescriptor.decodeProcessPrivate(Data(
            repeating: 0,
            count: ComposerAttachmentDragDescriptor.maximumEncodedBytes + 1)))
    }

    func testProcessPrivateRepresentationsAreCiphertextAndDomainSeparated() throws {
        let marker = "CONFIDENTIAL-\(UUID().uuidString)-DO-NOT-EXPOSE"
        let clipboard = ComposerClipboardPayload(
            sourceConversationID: UUID(),
            segments: [.init(kind: .opaqueAttachment, content: marker)])
        let descriptor = ComposerAttachmentDragDescriptor(
            nonce: UUID(),
            payload: marker,
            sourceConversationID: UUID())
        let artifact = ArtifactDragReference(
            artifactID: UUID(),
            title: marker,
            type: "markdown",
            currentSourcePath: "/tmp/\(marker).md")

        let clipboardCiphertext = try XCTUnwrap(clipboard.processSignedEncodedData)
        let descriptorCiphertext = try XCTUnwrap(descriptor.processSignedEncodedData)
        let artifactCiphertext = try XCTUnwrap(artifact.processSignedEncodedData)
        let markerData = Data(marker.utf8)
        XCTAssertNil(clipboardCiphertext.range(of: markerData))
        XCTAssertNil(descriptorCiphertext.range(of: markerData))
        XCTAssertNil(artifactCiphertext.range(of: markerData))
        XCTAssertNil(ComposerClipboardPayload.decode(clipboardCiphertext))
        XCTAssertNil(ComposerAttachmentDragDescriptor.decode(descriptorCiphertext))
        XCTAssertNil(ArtifactDragReference.decode(artifactCiphertext))

        let openedClipboard = try XCTUnwrap(
            ComposerClipboardPayload.decodeProcessPrivate(clipboardCiphertext))
        let openedDescriptor = try XCTUnwrap(
            ComposerAttachmentDragDescriptor.decodeProcessPrivate(descriptorCiphertext))
        let openedArtifact = try XCTUnwrap(
            ArtifactDragReference.decodeProcessPrivate(artifactCiphertext))
        XCTAssertEqual(openedClipboard.segments, clipboard.segments)
        XCTAssertEqual(openedDescriptor.payload, marker)
        XCTAssertEqual(openedArtifact.artifactID, artifact.artifactID)
        XCTAssertTrue(openedClipboard.isTrustedForCurrentProcess)
        XCTAssertTrue(openedDescriptor.isTrustedForCurrentProcess)
        XCTAssertTrue(openedArtifact.isTrustedForCurrentProcess)

        XCTAssertNil(ComposerClipboardPayload.decodeProcessPrivate(descriptorCiphertext))
        XCTAssertNil(ComposerAttachmentDragDescriptor.decodeProcessPrivate(
            clipboardCiphertext))
        XCTAssertNil(ArtifactDragReference.decodeProcessPrivate(clipboardCiphertext))

        // Opening a correctly encrypted envelope is not enough: the inner process HMAC must also
        // authenticate the structured value before a receiver accepts it.
        let encryptedUnsignedClipboard = try XCTUnwrap(
            ComposerPrivatePasteboardProvenance.seal(
                clipboard.encodedData,
                domain: .composerClipboard,
                maximumEncodedBytes: ComposerClipboardPayload.maximumEncodedBytes))
        XCTAssertNil(ComposerClipboardPayload.decodeProcessPrivate(
            encryptedUnsignedClipboard))

        // Durable prompt/reference encoding remains raw JSON and process-independent.
        XCTAssertEqual(
            ArtifactDragReference.decode(try XCTUnwrap(artifact.encodedData())),
            artifact)
        XCTAssertEqual(
            ArtifactDragReference.matches(in: artifact.promptToken).map(\.reference),
            [artifact])
    }

    func testClipboardSignatureIsBoundedBeforeEncodingOrSigning() {
        let payload = ComposerClipboardPayload(
            sourceConversationID: UUID(),
            segments: [.init(kind: .text, content: "visible")],
            provenanceSignature: String(repeating: "s", count: 257))

        XCTAssertNil(payload.encodedData)
        XCTAssertNil(payload.processSignedEncodedData)
        XCTAssertFalse(payload.isTrustedForCurrentProcess)
    }

    func testArtifactProcessPrivateDecoderRejectsOversizedEnvelope() {
        XCTAssertNil(ArtifactDragReference.decodeProcessPrivate(Data(
            repeating: 0,
            count: ArtifactDragReference.maximumEncodedBytes + 1)))
    }
}

/// Keeps mixed test segments readable without erasing whether a String is prose or payload.
private enum Either<Left, Right> {
    case left(Left)
    case right(Right)
}
