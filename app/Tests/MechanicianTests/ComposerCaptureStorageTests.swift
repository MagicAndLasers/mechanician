import AppKit
import XCTest
@testable import Mechanician

/// Selecting several photos attached several copies of one photo. Every capture and export writes
/// through this one helper, and its filename was a second-precision timestamp: photos exported in
/// the same second landed on the same path, each overwriting the last, so every URL handed to the
/// composer pointed at the final file.
final class ComposerCaptureStorageTests: XCTestCase {
    func testCapturesWrittenInTheSameSecondDoNotOverwriteEachOther() throws {
        let first = try XCTUnwrap(
            ComposerCaptureStorage.write(Data([1, 1, 1]), fileExtension: "png", basename: "Photo"))
        let second = try XCTUnwrap(
            ComposerCaptureStorage.write(Data([2, 2, 2]), fileExtension: "png", basename: "Photo"))
        let third = try XCTUnwrap(
            ComposerCaptureStorage.write(Data([3, 3, 3]), fileExtension: "png", basename: "Photo"))
        defer { for url in [first, second, third] { try? FileManager.default.removeItem(at: url) } }

        XCTAssertEqual(Set([first, second, third]).count, 3, "Each export needs its own file.")
        XCTAssertEqual(try Data(contentsOf: first), Data([1, 1, 1]))
        XCTAssertEqual(try Data(contentsOf: second), Data([2, 2, 2]))
        XCTAssertEqual(try Data(contentsOf: third), Data([3, 3, 3]))
    }

    func testReservedPathsAreUniqueAndUnwritten() throws {
        let first = try XCTUnwrap(
            ComposerCaptureStorage.reserveURL(fileExtension: "png", basename: "Screen"))
        let second = try XCTUnwrap(
            ComposerCaptureStorage.reserveURL(fileExtension: "png", basename: "Screen"))

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(first.pathExtension, "png")
    }
}

import UniformTypeIdentifiers

/// A photo library hands back HEIC. Anthropic's vision API does not accept it, so exporting the
/// original untouched attaches a thumbnail the person can see and the agent cannot read.
final class ComposerCaptureTranscodeTests: XCTestCase {
    private func pngData(_ color: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 12, height: 12))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 12, height: 12).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testAlreadyReadableFormatsAreKeptAsIs() throws {
        let data = try pngData(.systemBlue)
        let url = try XCTUnwrap(
            ComposerCaptureStorage.writeImage(data, sourceType: .png, basename: "Photo"))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: url), data, "No pointless re-encode.")
    }

    /// HEIC in, PNG out. The bytes here are a PNG standing in for camera-native data; what matters
    /// is that an unreadable *declared* type is transcoded rather than passed through and mislabeled.
    func testUnreadableFormatsAreTranscodedToPNG() throws {
        let url = try XCTUnwrap(ComposerCaptureStorage.writeImage(
            try pngData(.systemRed), sourceType: UTType.heic, basename: "Photo"))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.pathExtension, "jpg")
        let written = try Data(contentsOf: url)
        XCTAssertEqual(written.prefix(2), Data([0xFF, 0xD8]), "Real JPEG magic bytes.")
    }

    func testUnknownTypeIsTranscodedRatherThanGuessed() throws {
        let url = try XCTUnwrap(ComposerCaptureStorage.writeImage(
            try pngData(.systemGreen), sourceType: nil, basename: "Photo"))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.pathExtension, "jpg")
    }

    /// The regression that made photos vanish: transcoding to PNG inflated a photo past the
    /// composer's whole-batch import budget, so everything after the first was dropped.
    func testTranscodedPhotosStayWellInsideTheImportBudget() throws {
        let wide = NSImage(size: NSSize(width: 1_200, height: 1_600))
        wide.lockFocus()
        NSColor.systemIndigo.setFill()
        NSRect(x: 0, y: 0, width: 1_200, height: 1_600).fill()
        NSColor.systemYellow.setFill()
        NSBezierPath(ovalIn: NSRect(x: 100, y: 100, width: 900, height: 900)).fill()
        wide.unlockFocus()
        let tiff = try XCTUnwrap(wide.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let source = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        let url = try XCTUnwrap(ComposerCaptureStorage.writeImage(
            source, sourceType: UTType.heic, basename: "Photo"))
        defer { try? FileManager.default.removeItem(at: url) }
        let written = try Data(contentsOf: url).count

        // Three of these must still fit in one batch, which is the case that broke.
        XCTAssertLessThan(
            written * 3, ConversationAttachmentImportBudget.maximumBytes,
            "Three photos have to fit in one batch.")
    }

    func testEveryReadableTypeIsOneTheVisionAPIAccepts() {
        XCTAssertEqual(
            ComposerCaptureStorage.modelReadableTypes,
            [.png, .jpeg, .gif, .webP],
            "Widening this set means claiming the provider can read a format it may not.")
    }
}
