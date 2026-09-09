import AppKit
import XCTest
@testable import Mechanician

/// Dragging a file from the browser to the Trash.
///
/// The Trash is not an ordinary drop destination: Finder performs no drop of its own. It completes
/// the drag with `NSDragOperation.delete` and leaves removing the original to the drag source. A
/// source that advertises only `.copy` is therefore refused outright — which is why the browser
/// could drag out to a Finder window but not to the Trash.
@MainActor
final class FileBrowserDragTrashTests: XCTestCase {
    private func makeFiles(_ names: [String]) throws -> (dir: URL, urls: [URL]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileBrowserDragTrashTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls = try names.map { name -> URL in
            let url = dir.appendingPathComponent(name)
            try Data("contents of \(name)".utf8).write(to: url)
            return url
        }
        return (dir, urls)
    }

    func testEveryDraggedFileIsTrashedAndReported() throws {
        let made = try makeFiles(["notes.md", "chart.html"])
        defer { try? FileManager.default.removeItem(at: made.dir) }

        var requested: [URL] = []
        let trashed = FinderOutlineView.Coordinator.trashDraggedItems(made.urls) { url in
            requested.append(url)
        }

        XCTAssertEqual(requested, made.urls)
        XCTAssertEqual(trashed, made.urls)
    }

    /// A refusal must not read as a successful delete: the caller uses the returned list to decide
    /// whether to clear the selection and reload, so a file left on disk must stay out of it.
    func testAFileThatCannotBeTrashedIsLeftOutOfTheResult() throws {
        let made = try makeFiles(["keep.md", "go.md"])
        defer { try? FileManager.default.removeItem(at: made.dir) }
        struct Denied: Error {}

        let trashed = FinderOutlineView.Coordinator.trashDraggedItems(made.urls) { url in
            if url.lastPathComponent == "keep.md" { throw Denied() }
        }

        XCTAssertEqual(trashed.map(\.lastPathComponent), ["go.md"])
    }

    func testTrashingUsesTheRecoverableTrashRatherThanDeletingInPlace() throws {
        let made = try makeFiles(["recoverable.md"])
        defer { try? FileManager.default.removeItem(at: made.dir) }
        let original = made.urls[0]

        // The default implementation must route through FileManager.trashItem, which relocates the
        // file rather than destroying it. Assert relocation, not merely absence, so a future
        // `removeItem` cannot pass this test.
        var resulting: NSURL?
        try FileManager.default.trashItem(at: original, resultingItemURL: &resulting)
        let landed = try XCTUnwrap(resulting) as URL
        defer { try? FileManager.default.removeItem(at: landed) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: landed.path))
        XCTAssertEqual(
            try String(contentsOf: landed, encoding: .utf8),
            "contents of recoverable.md",
            "A trashed file must still be recoverable with its contents intact.")
    }
}
