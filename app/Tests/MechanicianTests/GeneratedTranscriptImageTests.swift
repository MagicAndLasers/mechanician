import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

@MainActor
final class GeneratedTranscriptImageTests: XCTestCase {
    private func pngData(width: CGFloat = 32, height: CGFloat = 20) throws -> (Data, NSImage) {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return (png, image)
    }

    func testGeneratedImageHandoffIsConsumedAndDeletedBeforeTranscriptRouting() throws {
        let (data, _) = try pngData()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mechanician-generated-image-\(UUID().uuidString).image")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let resolved = AgentBridge.resolvingGeneratedImageHandoff([
            "type": "tool_result",
            "status": "success",
            "result": "Generated image.",
            "generatedImagePath": url.path,
            "generatedImageBytes": data.count,
        ])

        XCTAssertEqual(resolved["generatedImageData"] as? Data, data)
        XCTAssertNil(resolved["generatedImagePath"])
        XCTAssertNil(resolved["generatedImageBytes"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testGeneratedImageToolRendersItsPersistedPreview() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MechanicianGeneratedTranscriptImage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ConversationMediaStorage(root: root)
        let conversationID = UUID()
        let entryID = UUID()
        let (data, image) = try pngData()
        let reference = try storage.persistScreenshot(
            data,
            conversationID: conversationID,
            entryID: entryID,
            width: 32,
            height: 20)
        let url = try XCTUnwrap(storage.imageURL(
            conversationID: conversationID,
            reference: reference))

        var entry = TranscriptEntry(kind: .tool, text: "{\"prompt\":\"teal square\"}")
        entry.id = entryID
        entry.toolName = "ImageGeneration"
        entry.toolState = .succeeded
        entry.toolImage = reference
        let host = NSHostingView(rootView: ExpandedToolContent(
            entry: entry,
            capturedImage: image,
            persistedImageURL: url,
            chatScale: 1))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 500)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.fittingSize.height, 300)
    }
}
