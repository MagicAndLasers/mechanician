import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

/// Dragging an attachment to a new position still does not work. The move itself is covered by
/// `ComposerAttachmentReorderingTests`, so this pins the other half: whether a press on the glyph is
/// recognised as the start of a drag at all.
@MainActor
final class ComposerAttachmentDragStartTests: XCTestCase {
    private func composer(with serialized: String) -> (ChatInput.Coordinator, ComposerTextView) {
        _ = NSApplication.shared
        let input = ChatInput(
            text: .constant(serialized),
            height: .constant(ChatInput.minHeight),
            isEnabled: true,
            onSend: {})
        let coordinator = ChatInput.Coordinator(input)
        let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 90))
        textView.isEditable = true
        textView.isRichText = true
        textView.importsGraphics = true
        _ = textView.layoutManager
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.restoreSerializedContent(serialized, into: textView)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        return (coordinator, textView)
    }

    func testPressingOnAnAttachmentGlyphStartsADrag() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mech-drag-\(UUID().uuidString).png")
        let image = NSImage(size: NSSize(width: 40, height: 40))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 40).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        let (coordinator, textView) = composer(with: "\(path.path) tail")
        let storage = try XCTUnwrap(textView.textStorage)
        XCTAssertTrue(
            storage.string.contains("\u{fffc}"),
            "The fixture has to actually contain an attachment glyph.")

        // The centre of the glyph, in view coordinates, which is where a press would land.
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: 1), actualCharacterRange: nil)
        let bounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        let centre = NSPoint(x: bounds.midX, y: bounds.midY)

        XCTAssertTrue(
            coordinator.prepareAttachmentDrag(at: centre, in: textView),
            "A press in the middle of the attachment must arm the drag.")
    }
}

/// Reordering never landed because entering the composer re-activated the app and re-keyed the
/// window in the middle of the drag's own session. That fronting exists for Finder → composer, which
/// is the only case that needs it.
final class ComposerDropActivationTests: XCTestCase {
    func testAnIntraApplicationDragDoesNotRefrontTheWindow() {
        // A drag that started in this app always reports a source; ours is the composer text view.
        XCTAssertFalse(
            ComposerTextView.shouldFrontWindowForDrop(draggingSource: NSObject()),
            "Activating mid-session disturbs the drag that is already in flight.")
    }

    func testACrossApplicationDragStillFrontsTheWindow() {
        // Finder may own the active Space, so the destination has to come forward to receive a drop.
        XCTAssertTrue(ComposerTextView.shouldFrontWindowForDrop(draggingSource: nil))
    }
}

/// The drag preview handed to AppKit must be encodable. `NSImage(size:)` has no representations, and
/// AppKit encodes the dragging item's contents as PNG: a real drag logged 147
/// "CGImageDestinationFinalize was called, but there were no images added" errors, one every few
/// milliseconds, and put nothing under the pointer.
@MainActor
final class ComposerDragImageTests: XCTestCase {
    private func textView() -> ComposerTextView {
        _ = NSApplication.shared
        let view = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        view.isEditable = true
        view.isRichText = true
        _ = view.layoutManager
        return view
    }

    func testAnAttachmentWithoutAnImageStillYieldsAnEncodablePreview() throws {
        let frame = NSRect(x: 0, y: 0, width: 30, height: 20)
        // A file chip draws through its cell and has no `image`, which is the ordinary case.
        let image = ChatInput.Coordinator.dragImage(
            for: NSTextAttachment(), frame: frame, in: textView())

        XCTAssertFalse(
            image.representations.isEmpty,
            "An image with no representations is exactly what AppKit failed to encode.")
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertNotNil(
            NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
                .representation(using: .png, properties: [:]),
            "It has to survive the PNG encode AppKit performs on the drag contents.")
    }

    func testAnAttachmentImageIsUsedWhenItHasContent() throws {
        let backing = NSImage(size: NSSize(width: 24, height: 24))
        backing.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: 24, height: 24).fill()
        backing.unlockFocus()
        let attachment = NSTextAttachment()
        attachment.image = backing

        let image = ChatInput.Coordinator.dragImage(
            for: attachment, frame: NSRect(x: 0, y: 0, width: 24, height: 24), in: textView())
        XCTAssertIdentical(image, backing)
    }

    /// A zero-sized glyph must not produce a zero-sized image, which cannot be encoded either.
    func testDegenerateFramesAreClampedToSomethingRenderable() {
        let image = ChatInput.Coordinator.dragImage(
            for: nil, frame: NSRect(x: 0, y: 0, width: 0, height: 0), in: textView())
        XCTAssertGreaterThanOrEqual(image.size.width, 1)
        XCTAssertGreaterThanOrEqual(image.size.height, 1)
        XCTAssertFalse(image.representations.isEmpty)
    }
}

/// The measured failure: the window hit-tests to the editor and the press is over it, but
/// `mouseDown` is never entered, because `NSTextView`'s own gesture recognizers consume the press.
/// Arming therefore cannot depend on a remembered press — it has to work from the drag itself.
@MainActor
final class ComposerLateArmingTests: XCTestCase {
    func testArmingWorksWithoutAnyPrecedingMouseDown() throws {
        _ = NSApplication.shared
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mech-late-\(UUID().uuidString).png")
        let image = NSImage(size: NSSize(width: 40, height: 40))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 40).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        let input = ChatInput(
            text: .constant(path.path),
            height: .constant(ChatInput.minHeight),
            isEnabled: true,
            onSend: {})
        let coordinator = ChatInput.Coordinator(input)
        let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 90))
        textView.isEditable = true
        textView.isRichText = true
        textView.importsGraphics = true
        _ = textView.layoutManager
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.restoreSerializedContent(path.path, into: textView)
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))

        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let bounds = layoutManager
            .boundingRect(
                forGlyphRange: layoutManager.glyphRange(
                    forCharacterRange: NSRange(location: 0, length: 1),
                    actualCharacterRange: nil),
                in: container)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)

        // No mouseDown at all — exactly the situation the log showed.
        XCTAssertTrue(
            coordinator.prepareAttachmentDrag(
                at: NSPoint(x: bounds.midX, y: bounds.midY), in: textView),
            "Arming has to succeed from the drag's own location.")
        XCTAssertFalse(
            coordinator.hasActiveAttachmentDrag,
            "Arming is not yet a live session; that guard is what stops a second drag starting.")
    }
}

/// Reordering is payload-keyed, not image-specific, so a file chip must be draggable exactly like an
/// image. Worth pinning separately: a chip is a different attachment shape, and a still-importing
/// placeholder must stay put because its bytes are not there yet.
@MainActor
final class ComposerFileChipDragTests: XCTestCase {
    private func composer(
        _ serialized: String
    ) throws -> (ChatInput.Coordinator, ComposerTextView) {
        _ = NSApplication.shared
        let input = ChatInput(
            text: .constant(serialized),
            height: .constant(ChatInput.minHeight),
            isEnabled: true,
            onSend: {})
        let coordinator = ChatInput.Coordinator(input)
        let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 90))
        textView.isEditable = true
        textView.isRichText = true
        textView.importsGraphics = true
        _ = textView.layoutManager
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.restoreSerializedContent(serialized, into: textView)
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        return (coordinator, textView)
    }

    private func glyphCentre(
        at characterIndex: Int,
        in textView: ComposerTextView
    ) throws -> NSPoint {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let bounds = layoutManager
            .boundingRect(
                forGlyphRange: layoutManager.glyphRange(
                    forCharacterRange: NSRange(location: characterIndex, length: 1),
                    actualCharacterRange: nil),
                in: container)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        return NSPoint(x: bounds.midX, y: bounds.midY)
    }

    func testAFileChipArmsADragTheSameWayAnImageDoes() throws {
        let reference = ConversationFileReference(
            storageName: "\(UUID().uuidString).docx",
            displayName: "Quarterly report.docx",
            typeIdentifier: "org.openxmlformats.wordprocessingml.document",
            byteCount: 4_096)
        let (coordinator, textView) = try composer("before \(reference.promptToken) after")

        let attachment = textView.textStorage?.attribute(
            .attachment, at: 7, effectiveRange: nil) as? NSTextAttachment
        XCTAssertNotNil(attachment, "The fixture has to produce a real chip.")

        XCTAssertTrue(
            coordinator.prepareAttachmentDrag(
                at: try glyphCentre(at: 7, in: textView), in: textView),
            "A file chip carries a payload, so it reorders like any other attachment.")

        // And its preview survives the PNG encode AppKit performs on the drag contents.
        let preview = ChatInput.Coordinator.dragImage(
            for: attachment, frame: NSRect(x: 0, y: 0, width: 120, height: 24), in: textView)
        XCTAssertFalse(preview.representations.isEmpty)
    }

    /// A placeholder for a file still being imported has no bytes behind it yet, so dragging it
    /// somewhere else would move a promise the drop cannot honour.
    func testAStillImportingPlaceholderDoesNotArm() throws {
        let pending = ChatInput.pendingFilePromisePayloadPrefix + "in progress]"
        let (coordinator, textView) = try composer(pending)
        // No attachment glyph is required here; what matters is that nothing arms over the text.
        XCTAssertFalse(
            coordinator.prepareAttachmentDrag(at: NSPoint(x: 12, y: 10), in: textView))
    }
}
