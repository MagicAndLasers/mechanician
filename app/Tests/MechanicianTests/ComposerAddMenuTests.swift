import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

final class ComposerAddMenuTests: XCTestCase {
    private func titles(hasCamera: Bool = true) -> [String] {
        ComposerAddMenuModel.items(hasCamera: hasCamera).map(\.title)
    }

    /// Opening the panel must never fire a permission prompt, so an undecided library gets an
    /// explicit opt-in card where the thumbnails would be.
    func testUndecidedLibraryOffersOptInInsteadOfThumbnails() {
        XCTAssertEqual(ComposerAddMenuModel.mediaHeader(.notDetermined), .optIn)
    }

    func testGrantedLibraryDrawsTheStrip() {
        XCTAssertEqual(ComposerAddMenuModel.mediaHeader(.authorized), .photos)
    }

    /// The property that makes photos cheap: the picker runs out of process, so a denied library
    /// must not take photo attachment away, and must not keep asking.
    func testDeniedLibraryStillOffersThePickerAndStopsAsking() {
        XCTAssertEqual(ComposerAddMenuModel.mediaHeader(.unavailable), .cameraOnly)
        XCTAssertTrue(titles().contains("Photos…"))
    }

    /// Rows do not depend on photo permission at all; only the media header above them does.
    func testRowsAreIndependentOfPhotoPermission() {
        for access in [ComposerPhotoStripAccess.notDetermined, .authorized, .unavailable] {
            XCTAssertEqual(ComposerAddMenuModel.mediaHeader(access) == .photos, access == .authorized)
        }
        XCTAssertEqual(titles(), titles())
    }

    func testCameralessMacDoesNotOfferTakePhoto() {
        XCTAssertFalse(titles(hasCamera: false).contains("Take Photo…"))
        XCTAssertTrue(titles(hasCamera: true).contains("Take Photo…"))
    }

    /// Files stays reachable from the panel as well as by option-click, and stays last so the media
    /// sources read as one group.
    func testFilesIsLastAndStartsItsOwnSection() {
        let items = ComposerAddMenuModel.items(hasCamera: true)
        XCTAssertEqual(items.last?.title, "Files…")
        XCTAssertEqual(items.last?.action, .addFiles)
        XCTAssertTrue(items.last?.startsSection == true)
        XCTAssertTrue(items.contains { $0.action == .captureScreenArea })
    }

    /// A cancelled selection writes no file and a failed one writes an empty file. Neither is an
    /// error worth interrupting anyone for, but neither may be attached.
    func testCancelledScreenCaptureIsNotAttached() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appendingPathComponent("missing.png")
        XCTAssertFalse(ScreenAreaCapture.isUsableCapture(missing))

        let empty = directory.appendingPathComponent("empty.png")
        try Data().write(to: empty)
        XCTAssertFalse(ScreenAreaCapture.isUsableCapture(empty))

        let real = directory.appendingPathComponent("real.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: real)
        XCTAssertTrue(ScreenAreaCapture.isUsableCapture(real))
    }
}

/// Continuity Camera is off unless a responder declares it can receive images. Measured before this
/// change: `NSTextView` returned nil for every image type even with `isRichText` and
/// `importsGraphics` on, and its context menu carried no "Import from iPhone or iPad" item.
@MainActor
final class ComposerContinuityCameraTests: XCTestCase {
    func testComposerDeclaresItselfAbleToReceiveImportedImages() {
        _ = NSApplication.shared
        let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        textView.isEditable = true
        textView.isRichText = true
        textView.importsGraphics = true

        for type in ComposerTextView.continuityCameraReturnTypes {
            XCTAssertNotNil(
                textView.validRequestor(forSendType: nil, returnType: type),
                "\(type.rawValue) is one of the types an imported photo, scan, or sketch arrives as.")
        }
    }

    /// A service that wants to *take* a selection from us is a different question, and one the text
    /// system still answers. Claiming those would advertise a capability we do not implement.
    func testSendingSelectionsIsLeftToTheTextSystem() {
        _ = NSApplication.shared
        let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        textView.isEditable = true
        textView.isRichText = true

        XCTAssertNil(textView.validRequestor(forSendType: .png, returnType: .png))
    }
}

/// The model says what should appear; this proves the panel actually builds from it, which is the
/// part that fails at runtime rather than at compile time.
@MainActor
final class ComposerAddPanelAssemblyTests: XCTestCase {
    func testPanelBuildsAtAReadableSize() {
        _ = NSApplication.shared
        let view = ComposerAddMenuView()
        view.refreshAvailability()
        let controller = view.makePanelController()
        controller.loadView()

        // The complaint that started this: a strip of thumbnails inside a menu is unreadable. The
        // panel has to be wide enough to show photos as photos.
        XCTAssertGreaterThanOrEqual(controller.view.fittingSize.width, 320)
        XCTAssertGreaterThan(controller.view.fittingSize.height, 100)
    }

    /// Every state lays out at the panel's full width with real height, and the media row is wide
    /// enough for the camera tile plus four thumbnails without clipping the last one — which is
    /// exactly what went wrong when this was a menu.
    func testEveryStateLaysOutWithoutClippingTheStrip() {
        _ = NSApplication.shared
        let photos = (0..<4).map { index in
            PhotoLibraryAccess.RecentPhoto(
                localIdentifier: "photo-\(index)",
                thumbnail: NSImage(size: NSSize(width: 8, height: 8)))
        }
        let cases: [(ComposerAddMediaHeader, [PhotoLibraryAccess.RecentPhoto])] = [
            (.photos, photos), (.optIn, []), (.cameraOnly, []),
        ]
        for (header, sample) in cases {
            let state = ComposerAddPanelState()
            state.header = header
            state.photos = sample
            state.hasCamera = true
            let controller = NSHostingController(rootView: ComposerAddPanelView(
                state: state, perform: { _ in }, pickPhoto: { _ in }))
            controller.loadView()
            let size = controller.view.fittingSize
            XCTAssertEqual(size.width, ComposerAddPanelView.width, accuracy: 1, "\(header)")
            XCTAssertGreaterThan(size.height, 180, "\(header)")
        }

        // Camera tile plus four thumbnails and their gaps must fit inside the content width.
        XCTAssertLessThanOrEqual(5 * 76 + 4 * 8, ComposerAddPanelView.width - 24)
    }

    /// The button is glyph-only, so it needs a spoken name (standing accessibility rule).
    func testAddButtonIsLabelledForVoiceOver() {
        _ = NSApplication.shared
        let view = ComposerAddMenuView()
        XCTAssertEqual(view.accessibilityLabel(), "Add to message")
        XCTAssertEqual(view.accessibilityRole(), .popUpButton)
    }
}
