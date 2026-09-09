import XCTest
import SwiftUI
@testable import Mechanician

/// The reader's position must survive a change to the SHAPE of the transcript, not just to the
/// measured height of a row (FR-341, "the transcript window is scrolling up on its own").
///
/// Inserting, removing or re-identifying a row above the viewport moves every row below it in
/// document coordinates while the clip origin stays put, so the viewport lands somewhere else.
/// Rows above growing is why it lands EARLIER, which is the direction people report.
///
/// `scheduleHeightFlush` already restores the reading position when a row is REMEASURED, and
/// `AppKitTranscriptHostTests` covers that. These cover the structural path, which did not.
///
/// The last test is the control that matters: a reader who is FOLLOWING the tail must still be
/// carried to the bottom. A fix that held the viewport unconditionally would break the thing the
/// transcript exists to do, and would pass every other assertion here.
@MainActor
final class TranscriptStructuralAnchorTests: XCTestCase {

    private func makeTable(coordinator: AppKitTranscriptHost.Coordinator) -> NSTableView {
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        table.headerView = nil
        table.intercellSpacing = .zero
        table.rowHeight = 44
        table.usesAutomaticRowHeights = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("test-transcript"))
        column.width = 600
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.table = table
        return table
    }

    private func drainMainQueue(passes: Int = 4) async {
        for _ in 0..<passes {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func chunk(_ name: String, index: Int, text: String? = nil) -> AppKitTranscriptChunk {
        AppKitTranscriptChunk(
            id: AnyHashable(name),
            revision: 1,
            sourceIndex: index,
            assistant: AppKitAssistantContent(
                text: text ?? "Response \(name).",
                chatScale: 1,
                isLive: false,
                canRetry: true,
                cwd: "/tmp"))
    }

    private struct Harness {
        let coordinator: AppKitTranscriptHost.Coordinator
        let table: NSTableView
        let scroll: NSScrollView
        let window: NSWindow
        let pin: TranscriptPinController
    }

    private func makeHarness() -> Harness {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 220))
        scroll.documentView = table
        let window = NSWindow(
            contentRect: scroll.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = scroll
        window.alphaValue = 0
        window.orderFrontRegardless()
        let pin = TranscriptPinController()
        coordinator.attach(table: table, scrollView: scroll, pin: pin)
        pin.scrollView = scroll
        return Harness(
            coordinator: coordinator, table: table, scroll: scroll, window: window, pin: pin)
    }

    private func tearDownHarness(_ harness: Harness) {
        harness.pin.scrollView = nil
        harness.coordinator.removeAll()
        harness.window.orderOut(nil)
        harness.window.contentView = nil
    }

    /// Fill the transcript and park a detached reader with `anchorRow` partway down the viewport.
    /// Returns that row's offset from the top of the viewport, which is what must not change.
    private func parkedReader(_ harness: Harness, anchorRow: Int) -> CGFloat {
        let anchorRect = harness.table.rect(ofRow: anchorRow)
        harness.scroll.contentView.scroll(to: NSPoint(x: 0, y: anchorRect.minY + 17))
        harness.scroll.reflectScrolledClipView(harness.scroll.contentView)
        harness.pin.pinned = false
        return harness.table.rect(ofRow: anchorRow).minY
            - harness.scroll.contentView.bounds.minY
    }

    private func offset(_ harness: Harness, ofRow row: Int) -> CGFloat {
        harness.table.rect(ofRow: row).minY - harness.scroll.contentView.bounds.minY
    }

    func testARowInsertedAboveTheReaderDoesNotMoveWhatTheyAreReading() async {
        let harness = makeHarness()
        defer { tearDownHarness(harness) }
        let anchorRow = 50

        var chunks = (0..<80).map { chunk("row-\($0)", index: $0) }
        harness.coordinator.sync(chunks: chunks, content: { _ in AnyView(EmptyView()) })
        harness.table.reloadData()
        harness.coordinator.reconcileDocumentGeometry()
        let offsetBefore = parkedReader(harness, anchorRow: anchorRow)

        // A row appears above the reader. Every row below it moves down in document coordinates.
        chunks.insert(chunk("row-inserted", index: 5), at: 5)
        harness.coordinator.sync(chunks: chunks, content: { _ in AnyView(EmptyView()) })
        await drainMainQueue(passes: 8)

        XCTAssertEqual(harness.table.numberOfRows, 81, "the document really did change shape")
        XCTAssertEqual(
            offset(harness, ofRow: anchorRow + 1), offsetBefore, accuracy: 1,
            "inserting a row above the reader must not move what they are reading")
    }

    func testARowRemovedAboveTheReaderDoesNotMoveWhatTheyAreReading() async {
        let harness = makeHarness()
        defer { tearDownHarness(harness) }
        let anchorRow = 50

        var chunks = (0..<80).map { chunk("row-\($0)", index: $0) }
        harness.coordinator.sync(chunks: chunks, content: { _ in AnyView(EmptyView()) })
        harness.table.reloadData()
        harness.coordinator.reconcileDocumentGeometry()
        let offsetBefore = parkedReader(harness, anchorRow: anchorRow)

        chunks.remove(at: 5)
        harness.coordinator.sync(chunks: chunks, content: { _ in AnyView(EmptyView()) })
        await drainMainQueue(passes: 8)

        XCTAssertEqual(harness.table.numberOfRows, 79)
        XCTAssertEqual(
            offset(harness, ofRow: anchorRow - 1), offsetBefore, accuracy: 1,
            "removing a row above the reader must not move what they are reading")
    }

    /// The full-rebuild path. When row identities change in the middle of the document the
    /// coordinator cannot express it as an insert or a remove and reloads everything, dropping the
    /// measured heights of the rows whose identity changed. A re-chunked activity group does this
    /// during an ordinary turn, which is why the jump is periodic rather than rare.
    func testRebuildingEarlierRowsDoesNotMoveWhatTheReaderIsReading() async {
        let harness = makeHarness()
        defer { tearDownHarness(harness) }
        let anchorRow = 50

        var chunks = (0..<80).map { chunk("row-\($0)", index: $0) }
        harness.coordinator.sync(chunks: chunks, content: { _ in AnyView(EmptyView()) })
        harness.table.reloadData()
        harness.coordinator.reconcileDocumentGeometry()
        let offsetBefore = parkedReader(harness, anchorRow: anchorRow)

        // Same row count, different identity above the reader: neither an insert nor a remove, and
        // deliberately much taller, so an uncompensated viewport lands far EARLIER in the document.
        chunks[5] = chunk(
            "row-5-rebuilt",
            index: 5,
            text: Array(repeating: "This rebuilt earlier row is much taller than it was.",
                        count: 40).joined(separator: " "))
        harness.coordinator.sync(chunks: chunks, content: { _ in AnyView(EmptyView()) })
        await drainMainQueue(passes: 8)

        XCTAssertEqual(harness.table.numberOfRows, 80)
        XCTAssertEqual(
            offset(harness, ofRow: anchorRow), offsetBefore, accuracy: 1,
            "rebuilding earlier rows must not move what the reader is reading")
    }

    /// **The control.** Following the live tail is the transcript's whole job. A reader who has not
    /// scrolled away is `pinned`, and the preservation must not engage for them at all.
    func testAReaderFollowingTheTailIsNeverHeldBack() async {
        let harness = makeHarness()
        defer { tearDownHarness(harness) }

        var chunks = (0..<40).map { chunk("row-\($0)", index: $0) }
        harness.coordinator.sync(chunks: chunks, content: { _ in AnyView(EmptyView()) })
        harness.table.reloadData()
        harness.coordinator.reconcileDocumentGeometry()
        harness.pin.pinned = true

        // The gate the preservation consults. While following, there is no anchor to take.
        XCTAssertFalse(harness.pin.mayPreserveDetachedViewportAnchor)

        chunks.append(chunk("row-40", index: 40))
        harness.coordinator.sync(chunks: chunks, content: { _ in AnyView(EmptyView()) })
        await drainMainQueue(passes: 8)

        XCTAssertTrue(harness.pin.pinned, "structural change must not detach a following reader")
        XCTAssertFalse(harness.pin.mayPreserveDetachedViewportAnchor)
    }
}
