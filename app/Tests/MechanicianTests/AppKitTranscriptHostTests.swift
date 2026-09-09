import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

@MainActor
final class AppKitTranscriptHostTests: XCTestCase {
    func testHostedHeightCycleFuseLocksSmallLargeSmallAtLargeHeight() {
        var fuse = TranscriptHeightCycleFuse()

        XCTAssertEqual(fuse.reportableHeight(for: 179.2), 180)
        XCTAssertEqual(fuse.reportableHeight(for: 419.2), 420)
        XCTAssertNil(fuse.reportableHeight(for: 179.2))
        XCTAssertEqual(fuse.lockedHeight, 420)

        for height in [CGFloat(180), 420, 180, 420] {
            XCTAssertNil(fuse.reportableHeight(for: height))
        }
    }

    func testHostedHeightCycleFuseRestoresLargeHeightWhenCycleStartsLarge() {
        var fuse = TranscriptHeightCycleFuse()

        XCTAssertEqual(fuse.reportableHeight(for: 420), 420)
        XCTAssertEqual(fuse.reportableHeight(for: 180), 180)
        XCTAssertEqual(fuse.reportableHeight(for: 420), 420)
        XCTAssertEqual(fuse.lockedHeight, 420)
        XCTAssertNil(fuse.reportableHeight(for: 180))
    }

    func testHostedHeightCycleFuseExplicitEpochAllowsLegitimateShrink() {
        var fuse = TranscriptHeightCycleFuse()
        _ = fuse.reportableHeight(for: 180)
        _ = fuse.reportableHeight(for: 420)
        _ = fuse.reportableHeight(for: 180)

        fuse.beginNewLayoutEpoch()

        XCTAssertNil(fuse.lockedHeight)
        XCTAssertEqual(fuse.reportableHeight(for: 180), 180)
        XCTAssertNil(fuse.reportableHeight(for: 180))
    }


    func testHostedStateChangeCanInvalidateNativeRowHeightWithoutTranscriptRevision() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        scroll.documentView = table
        let window = NSWindow(
            contentRect: scroll.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = scroll
        window.alphaValue = 0
        window.orderFrontRegardless()

        let model = ExpansionFixture()
        coordinator.sync(
            chunks: [.init(id: AnyHashable("expandable-mail"), revision: 1)],
            content: { _ in AnyView(ExpansionFixtureView(model: model)) })
        _ = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        await drainMainQueue(passes: 6)
        let collapsedHeight = table.rect(ofRow: 0).height

        model.expanded = true
        await drainMainQueue(passes: 8)

        XCTAssertGreaterThan(table.rect(ofRow: 0).height, collapsedHeight + 180)

        model.expanded = false
        await drainMainQueue(passes: 8)

        XCTAssertEqual(table.rect(ofRow: 0).height, collapsedHeight, accuracy: 1)
        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    func testHostedSwiftUIStateIsScopedToTranscriptRowIdentity() async throws {
        _ = NSApplication.shared
        let cell = TranscriptHostingCell(
            frame: NSRect(x: 0, y: 0, width: 600, height: 320))
        let window = NSWindow(
            contentRect: cell.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = cell
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        var measuredByRevision: [Int: CGFloat] = [:]
        let firstID = AnyHashable("first-compaction")
        cell.setRoot(
            HostedDisclosureIdentityFixture(initiallyExpanded: true),
            id: firstID,
            revision: 1
        ) { _, revision, height in
            measuredByRevision[revision] = height
        }
        cell.layoutSubtreeIfNeeded()
        await drainMainQueue(passes: 6)
        let expandedHeight = try XCTUnwrap(measuredByRevision[1])
        XCTAssertGreaterThan(expandedHeight, 220)

        // Summary text can refine an existing compaction entry after the streamed boundary. Keep
        // that row's local disclosure choice when only its revision changes.
        cell.setRoot(
            HostedDisclosureIdentityFixture(initiallyExpanded: false),
            id: firstID,
            revision: 2
        ) { _, revision, height in
            measuredByRevision[revision] = height
        }
        cell.layoutSubtreeIfNeeded()
        await drainMainQueue(passes: 6)
        let sameIdentityHeight = try XCTUnwrap(measuredByRevision[2])
        XCTAssertEqual(sameIdentityHeight, expandedHeight, accuracy: 1)

        // Native cell reuse must not donate the first compaction's expanded @State to a different
        // row or conversation. The replacement uses its declared collapsed default.
        cell.setRoot(
            HostedDisclosureIdentityFixture(initiallyExpanded: false),
            id: AnyHashable("second-compaction"),
            revision: 1
        ) { _, _, height in
            measuredByRevision[3] = height
        }
        cell.layoutSubtreeIfNeeded()
        await drainMainQueue(passes: 6)
        let collapsedHeight = try XCTUnwrap(measuredByRevision[3])
        XCTAssertLessThan(collapsedHeight, expandedHeight - 180)
    }


    func testPartialReloadExpandsMeasuredHostingRowAndDocument() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        scroll.documentView = table
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = scroll
        // NSTableView only asks its delegate to replace a partially reloaded row when that row is
        // actually visible. Keep this borderless test window off the active app, but order it so the
        // test exercises the same visible-row path as the transcript tail.
        window.alphaValue = 0
        window.orderFrontRegardless()

        let id = AnyHashable("streaming-tail")
        coordinator.sync(
            chunks: [.init(id: id, revision: 1)],
            content: { _ in AnyView(Self.transcriptText(lines: 1)) })
        _ = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        table.layoutSubtreeIfNeeded()
        await drainMainQueue()

        let initialHeight = table.rect(ofRow: 0).height
        XCTAssertGreaterThan(initialHeight, 20)
        XCTAssertLessThan(initialHeight, 100)

        coordinator.sync(
            chunks: [.init(id: id, revision: 2)],
            content: { _ in AnyView(Self.transcriptText(lines: 24)) })
        let updatedCell = table.view(
            atColumn: 0, row: 0, makeIfNecessary: true) as? TranscriptHostingCell
        table.layoutSubtreeIfNeeded()
        await drainMainQueue(passes: 6)

        XCTAssertEqual(updatedCell?.representedRevision, 2)
        XCTAssertGreaterThan(updatedCell?.lastMeasuredHeight ?? 0, 350)
        let grownHeight = table.rect(ofRow: 0).height
        XCTAssertGreaterThan(grownHeight, 350)
        XCTAssertGreaterThan(grownHeight, initialHeight * 5)
        XCTAssertGreaterThan(table.frame.height, scroll.contentView.bounds.height)

        // The same cache path must shrink as well as grow. Otherwise a completed/condensed tail can
        // leave a large blank region that feels like a broken scroll range.
        coordinator.sync(
            chunks: [.init(id: id, revision: 3)],
            content: { _ in AnyView(Self.transcriptText(lines: 2)) })
        await drainMainQueue(passes: 4)
        XCTAssertLessThan(table.rect(ofRow: 0).height, grownHeight / 3)

        // Streaming can replace the root again before an earlier measurement callback runs. Only
        // the newest revision may determine row geometry.
        coordinator.sync(
            chunks: [.init(id: id, revision: 4)],
            content: { _ in AnyView(Self.transcriptText(lines: 40)) })
        coordinator.sync(
            chunks: [.init(id: id, revision: 5)],
            content: { _ in AnyView(Self.transcriptText(lines: 3)) })
        await drainMainQueue(passes: 4)
        let finalCell = table.view(
            atColumn: 0, row: 0, makeIfNecessary: true) as? TranscriptHostingCell
        XCTAssertEqual(finalCell?.representedRevision, 5)
        XCTAssertLessThan(table.rect(ofRow: 0).height, 150)

        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    func testAppendingRowRemeasuresFormerTailInsteadOfLeavingBlankBand() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        scroll.documentView = table
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = scroll
        window.alphaValue = 0
        window.orderFrontRegardless()

        let formerTail = AnyHashable("former-tail")
        coordinator.sync(
            chunks: [.init(id: formerTail, revision: 1)],
            content: { _ in AnyView(Self.transcriptText(lines: 32)) })
        _ = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        await drainMainQueue(passes: 6)
        let liveTailHeight = table.rect(ofRow: 0).height
        XCTAssertGreaterThan(liveTailHeight, 500)

        // Crossing a chunk boundary changes the former tail's presentation at the same moment a
        // new native row is appended. The structural reload must still replace the old measurement;
        // otherwise the former tail leaves a large empty band before the newly appended row.
        coordinator.sync(
            chunks: [
                .init(id: formerTail, revision: 2),
                .init(id: AnyHashable("new-tail"), revision: 1),
            ],
            content: { row in AnyView(Self.transcriptText(lines: row == 0 ? 2 : 3)) })
        await drainMainQueue(passes: 8)

        let settledFormerTail = table.rect(ofRow: 0)
        let newTail = table.rect(ofRow: 1)
        XCTAssertLessThan(settledFormerTail.height, liveTailHeight / 4)
        XCTAssertEqual(newTail.minY, settledFormerTail.maxY, accuracy: 1)

        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    func testVisibleRowRemeasuresWhenTranscriptNarrows() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        scroll.documentView = table
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = scroll
        window.alphaValue = 0
        window.orderFrontRegardless()

        let prose = Array(repeating:
            "A native transcript row must reflow all streamed assistant text when its window narrows.",
            count: 14).joined(separator: " ")
        coordinator.sync(
            chunks: [.init(id: AnyHashable("resizing-row"), revision: 1)],
            content: { _ in
                AnyView(Text(prose)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10))
            })
        _ = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        table.layoutSubtreeIfNeeded()
        await drainMainQueue()
        let wideHeight = table.rect(ofRow: 0).height

        scroll.setFrameSize(NSSize(width: 280, height: 300))
        table.setFrameSize(NSSize(width: 280, height: table.frame.height))
        table.tableColumns[0].width = 280
        table.tile()
        table.layoutSubtreeIfNeeded()
        await drainMainQueue(passes: 4)
        let narrowHeight = table.rect(ofRow: 0).height

        XCTAssertGreaterThan(narrowHeight, wideHeight * 1.7)

        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    /// A visible row can correct itself after a resize, but the next row the person scrolls to is
    /// usually still virtualized. Its estimate must come from the *new* transcript width rather
    /// than the old one, or the document shifts again as that row is realized.
    func testNarrowingTranscriptReplacesWideEstimateForUnrealizedRows() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        table.setFrameSize(NSSize(width: 700, height: table.frame.height))
        table.tableColumns[0].width = 700
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 220))
        scroll.documentView = table
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 220),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = scroll
        window.alphaValue = 0
        window.orderFrontRegardless()
        let pin = TranscriptPinController()
        coordinator.attach(table: table, scrollView: scroll, pin: pin)
        pin.scrollView = scroll

        let prose = Array(repeating:
            "A virtualized transcript row needs an estimate at the width it will actually draw.",
            count: 18).joined(separator: " ")
        let rowCount = 80
        let sampledRow = 1
        let earlierTallRow = 10
        let unseenRow = 50
        let anchorRow = 60
        let tallProse = Array(repeating:
            "An earlier response is deliberately taller than the current-width estimate.",
            count: 90).joined(separator: " ")
        coordinator.sync(
            chunks: (0..<rowCount).map {
                AppKitTranscriptChunk(id: AnyHashable("width-cache-row-\($0)"), revision: 1,
                                      sourceIndex: $0)
            },
            content: { index in AnyView(Text(index == earlierTallRow ? tallProse : prose)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)) })
        table.reloadData()
        let wideCell = table.view(
            atColumn: 0, row: sampledRow, makeIfNecessary: true) as? TranscriptHostingCell
        wideCell?.layoutSubtreeIfNeeded()
        await drainMainQueue(passes: 8)
        let wideHeight = table.rect(ofRow: sampledRow).height
        XCTAssertGreaterThan(wideHeight, table.rowHeight)
        XCTAssertNil(table.view(atColumn: 0, row: unseenRow, makeIfNecessary: false))
        XCTAssertEqual(table.rect(ofRow: unseenRow).height, wideHeight, accuracy: 5)
        let wideAnchorRect = table.rect(ofRow: anchorRow)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: wideAnchorRect.minY + 17))
        scroll.reflectScrolledClipView(scroll.contentView)
        pin.pinned = false

        scroll.setFrameSize(NSSize(width: 300, height: 220))
        table.setFrameSize(NSSize(width: 300, height: table.frame.height))
        table.tableColumns[0].width = 300
        table.tile()
        table.layoutSubtreeIfNeeded()
        let narrowCell = table.view(
            atColumn: 0, row: sampledRow, makeIfNecessary: true) as? TranscriptHostingCell
        narrowCell?.needsLayout = true
        narrowCell?.layoutSubtreeIfNeeded()
        await drainMainQueue(passes: 10)

        let narrowHeight = table.rect(ofRow: sampledRow).height
        XCTAssertGreaterThan(narrowHeight, wideHeight * 1.7)
        XCTAssertNil(table.view(atColumn: 0, row: unseenRow, makeIfNecessary: false))
        XCTAssertEqual(
            table.rect(ofRow: unseenRow).height,
            narrowHeight,
            accuracy: 5,
            "an unseen row must inherit a current-width estimate, not its former wide height")

        let anchorOffsetAfterResize = table.rect(ofRow: anchorRow).minY
            - scroll.contentView.bounds.minY
        let tallCell = table.view(
            atColumn: 0, row: earlierTallRow, makeIfNecessary: true) as? TranscriptHostingCell
        tallCell?.layoutSubtreeIfNeeded()
        await drainMainQueue(passes: 10)

        XCTAssertGreaterThan(table.rect(ofRow: earlierTallRow).height, narrowHeight * 2)
        XCTAssertEqual(
            table.rect(ofRow: anchorRow).minY - scroll.contentView.bounds.minY,
            anchorOffsetAfterResize,
            accuracy: 1,
            "correcting a newly realized earlier row must not move the detached reader")

        pin.scrollView = nil
        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    func testDetachedViewportKeepsItsReadingAnchorWhenAnEarlierRowIsMeasured() async {
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

        let rowCount = 80
        let tallRow = 10
        let anchorRow = 50
        let chunks = (0..<rowCount).map { index in
            AppKitTranscriptChunk(
                id: AnyHashable("detached-anchor-row-\(index)"),
                revision: 1,
                sourceIndex: index,
                assistant: AppKitAssistantContent(
                    text: index == tallRow
                        ? Array(repeating:
                            "This earlier response is deliberately much taller than its estimate.",
                            count: 90).joined(separator: " ")
                        : "Short response \(index).",
                    chatScale: 1,
                    isLive: false,
                    canRetry: true,
                    cwd: "/tmp"))
        }
        coordinator.sync(chunks: chunks, content: { _ in AnyView(EmptyView()) })
        table.reloadData()
        coordinator.reconcileDocumentGeometry()

        let anchorRect = table.rect(ofRow: anchorRow)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: anchorRect.minY + 17))
        scroll.reflectScrolledClipView(scroll.contentView)
        pin.pinned = false
        let offsetBefore = table.rect(ofRow: anchorRow).minY
            - scroll.contentView.bounds.minY

        let earlierCell = table.view(
            atColumn: 0,
            row: tallRow,
            makeIfNecessary: true) as? NativeAssistantCell
        earlierCell?.layoutSubtreeIfNeeded()
        await drainMainQueue(passes: 8)

        XCTAssertGreaterThan(table.rect(ofRow: tallRow).height, 500)
        XCTAssertEqual(
            table.rect(ofRow: anchorRow).minY - scroll.contentView.bounds.minY,
            offsetBefore,
            accuracy: 1,
            "measuring an earlier row must not move the detached reading position")

        pin.scrollView = nil
        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    func testLiveScrollKeepsItsReadingAnchorWhenAnEarlierRowIsMeasured() async {
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

        let rowCount = 80
        let tallRow = 10
        let settledTailStart = 70
        let chunks = (0..<rowCount).map { index in
            AppKitTranscriptChunk(
                id: AnyHashable("live-anchor-row-\(index)"),
                revision: 1,
                sourceIndex: index,
                assistant: AppKitAssistantContent(
                    text: index == tallRow
                        ? Array(repeating:
                            "This earlier response is deliberately much taller than its estimate.",
                            count: 90).joined(separator: " ")
                        : "Short response \(index).",
                    chatScale: 1,
                    isLive: false,
                    canRetry: true,
                    cwd: "/tmp"))
        }
        coordinator.sync(chunks: chunks, content: { _ in AnyView(EmptyView()) })
        table.reloadData()
        coordinator.reconcileDocumentGeometry()

        // Rows already on screen have settled measurements in the real transcript. Settle the
        // entire tail viewport so the later bottom-distance assertion cannot be diluted by more
        // estimate changes below the reading anchor.
        for row in settledTailStart..<rowCount {
            let cell = table.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: true) as? NativeAssistantCell
            cell?.layoutSubtreeIfNeeded()
        }
        await drainMainQueue(passes: 6)

        pin.pinToBottom()
        let bottomY = scroll.contentView.bounds.minY
        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scroll)
        // Begin pinned, then perform the first genuine upward movement. This exercises the normal
        // pinned → detached transition instead of granting the test its desired state directly.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottomY - 30))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(
            name: NSScrollView.didLiveScrollNotification,
            object: scroll)
        XCTAssertFalse(pin.pinned)

        let visible = table.rows(in: table.visibleRect)
        XCTAssertNotEqual(visible.location, NSNotFound)
        let anchorRow = visible.location
        XCTAssertGreaterThanOrEqual(anchorRow, settledTailStart)
        let offsetBefore = table.rect(ofRow: anchorRow).minY
            - scroll.contentView.bounds.minY

        let earlierCell = table.view(
            atColumn: 0,
            row: tallRow,
            makeIfNecessary: true) as? NativeAssistantCell
        earlierCell?.layoutSubtreeIfNeeded()
        await drainMainQueue(passes: 8)

        XCTAssertGreaterThan(table.rect(ofRow: tallRow).height, 500)
        XCTAssertEqual(
            table.rect(ofRow: anchorRow).minY - scroll.contentView.bounds.minY,
            offsetBefore,
            accuracy: 1,
            "row realization must not move the reading position during a live upward scroll")

        let compensatedY = scroll.contentView.bounds.minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: compensatedY - 10))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(
            name: NSScrollView.didLiveScrollNotification,
            object: scroll)
        XCTAssertFalse(
            pin.pinned,
            "geometry compensation must not be mistaken for movement back toward the bottom")

        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scroll)
        pin.scrollView = nil
        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    func testQueuedWheelEvaluationRebasesCumulativeNativeViewportCompensation() async {
        _ = NSApplication.shared
        let document = FlippedTranscriptDocumentView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 1_000))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        scroll.documentView = document
        let pin = TranscriptPinController()
        pin.scrollView = scroll

        pin.pinToBottom()
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY - 30))
        scroll.reflectScrolledClipView(clip)
        pin.pinned = false
        XCTAssertEqual(
            document.frame.height - clip.bounds.height - clip.bounds.minY,
            30,
            accuracy: 1)

        // The local event monitor captures this origin and evaluates it on the next main-loop turn.
        // Two native row-geometry corrections land first and move both the document bottom and clip
        // origin by the same cumulative amount, so neither movement is user input.
        pin.wheelWillDispatch()
        for growth in [CGFloat(60), CGFloat(40)] {
            document.setFrameSize(NSSize(
                width: document.frame.width,
                height: document.frame.height + growth))
            let originBefore = clip.bounds.minY
            clip.scroll(to: NSPoint(x: 0, y: originBefore + growth))
            scroll.reflectScrolledClipView(clip)
            pin.nativeViewportWasCompensated(by: clip.bounds.minY - originBefore)
        }

        // Genuine wheel movement is ten points away from the bottom. The final position remains
        // inside the 48-point reattachment band, so a stale pre-compensation baseline would read
        // the net coordinate increase as movement toward the bottom and incorrectly reattach.
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY - 10))
        scroll.reflectScrolledClipView(clip)
        XCTAssertEqual(
            document.frame.height - clip.bounds.height - clip.bounds.minY,
            40,
            accuracy: 1)

        await drainMainQueue(passes: 2)

        XCTAssertFalse(
            pin.pinned,
            "queued wheel evaluation must subtract every intervening native compensation")
        pin.scrollView = nil
    }

    func testLearnedHeightEstimateRetilesStillUnrealizedRows() async {
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

        let text = Array(repeating:
            "A historical response needs a realistic cached height before it reaches the viewport.",
            count: 36).joined(separator: " ")
        let chunks = (0..<80).map { index in
            AppKitTranscriptChunk(
                id: AnyHashable("estimate-propagation-row-\(index)"),
                revision: 1,
                sourceIndex: index,
                assistant: AppKitAssistantContent(
                    text: text,
                    chatScale: 1,
                    isLive: false,
                    canRetry: true,
                    cwd: "/tmp"))
        }
        coordinator.sync(chunks: chunks, content: { _ in AnyView(EmptyView()) })
        table.reloadData()
        coordinator.reconcileDocumentGeometry()

        let unrealizedRow = 40
        XCTAssertEqual(table.rect(ofRow: unrealizedRow).height, table.rowHeight, accuracy: 1)
        XCTAssertNil(table.view(atColumn: 0, row: unrealizedRow, makeIfNecessary: false))

        let measuringRow = 79
        let cell = table.view(
            atColumn: 0,
            row: measuringRow,
            makeIfNecessary: true) as? NativeAssistantCell
        cell?.layoutSubtreeIfNeeded()
        await drainMainQueue(passes: 8)

        XCTAssertGreaterThan(table.rect(ofRow: measuringRow).height, 300)
        XCTAssertGreaterThan(
            table.rect(ofRow: unrealizedRow).height,
            300,
            "a learned estimate must replace NSTableView's cached 44-point unseen rows")
        XCTAssertNil(table.view(atColumn: 0, row: unrealizedRow, makeIfNecessary: false))

        pin.scrollView = nil
        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    func testWorkflowHeightEstimateDoesNotRetileUnmeasuredUsageLimitRow() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)

        var workflowEntry = TranscriptEntry(kind: .tool, text: "Transcript audit")
        workflowEntry.toolName = "Workflow"
        var usageLimitEntry = TranscriptEntry(
            kind: .system,
            text: "Claude five-hour usage limit reached. Usage credits are exhausted.")
        usageLimitEntry.usageLimit = UsageLimitError(
            rateLimitType: "five_hour",
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
            overageDisabledReason: "out_of_credits")

        XCTAssertEqual(AppKitHostedHeightEstimateClass(entry: workflowEntry), .workflow)
        // A system notice no longer shares one guess with every other hosted row. `bubble(_:)`
        // renders seven entry kinds through the same host and they are not the same size, so each
        // kind learns its own height and a Workflow still stands apart from its own `.tool` kind.
        XCTAssertEqual(AppKitHostedHeightEstimateClass(entry: usageLimitEntry), .kind("system"))
        var userEntry = TranscriptEntry(kind: .user, text: "hi")
        userEntry.toolName = nil
        XCTAssertNotEqual(
            AppKitHostedHeightEstimateClass(entry: userEntry),
            AppKitHostedHeightEstimateClass(entry: usageLimitEntry))

        let workflow = AppKitTranscriptChunk(
            id: AnyHashable("terminal-workflow"),
            revision: 1,
            sourceIndex: 0,
            hostedHeightEstimateClass: .workflow)
        let usageLimit = AppKitTranscriptChunk(
            id: AnyHashable("five-hour-usage-limit"),
            revision: 1,
            sourceIndex: 1,
            hostedHeightEstimateClass: .standard)
        func content(_ index: Int) -> AnyView {
            if index == 0 {
                return AnyView(VStack(spacing: 0) {
                    Text("Completed Workflow · 26 agents")
                    Color.clear.frame(height: 720)
                })
            }
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                Text("Claude 5-hour usage limit reached")
                Text("Usage credits are exhausted.")
                Color.clear.frame(height: 70)
            })
        }

        coordinator.sync(chunks: [workflow], content: content)
        table.reloadData()
        let workflowCell = table.view(
            atColumn: 0, row: 0, makeIfNecessary: true) as? TranscriptHostingCell
        workflowCell?.layoutSubtreeIfNeeded()
        await drainMainQueue(passes: 8)

        XCTAssertGreaterThan(table.rect(ofRow: 0).height, 700)

        coordinator.sync(chunks: [workflow, usageLimit], content: content)
        XCTAssertEqual(
            coordinator.tableView(table, heightOfRow: 1),
            table.rowHeight,
            accuracy: 1,
            "A Workflow measurement must not become the initial height of a provider-status row")
        await drainMainQueue(passes: 3)

        let usageLimitCell = table.view(
            atColumn: 0, row: 1, makeIfNecessary: true) as? TranscriptHostingCell
        usageLimitCell?.layoutSubtreeIfNeeded()
        await drainMainQueue(passes: 8)

        XCTAssertGreaterThan(table.rect(ofRow: 1).height, 100)
        XCTAssertLessThan(table.rect(ofRow: 1).height, 300)
        coordinator.removeAll()
    }

    func testLiveAssistantPrefixesDoNotTrainHistoricalHeightEstimate() async {
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

        let text = Array(repeating:
            "A growing live tail must not repeatedly retile every unseen historical response.",
            count: 36).joined(separator: " ")
        func chunks(finalTail: Bool) -> [AppKitTranscriptChunk] {
            (0..<80).map { index in
                AppKitTranscriptChunk(
                    id: AnyHashable("live-estimate-row-\(index)"),
                    revision: index == 79 && finalTail ? 2 : 1,
                    sourceIndex: index,
                    assistant: AppKitAssistantContent(
                        text: text,
                        chatScale: 1,
                        // Keep every synthetic row live so no incidental visible neighbour can
                        // train the estimate; only sealing the explicit tail below may contribute.
                        isLive: index == 79 ? !finalTail : true,
                        canRetry: finalTail,
                        cwd: "/tmp"))
            }
        }

        coordinator.sync(chunks: chunks(finalTail: false), content: { _ in AnyView(EmptyView()) })
        table.reloadData()
        coordinator.reconcileDocumentGeometry()
        let unseenRow = 40
        let tailRow = 79
        let liveCell = table.view(
            atColumn: 0,
            row: tailRow,
            makeIfNecessary: true) as? NativeAssistantCell
        liveCell?.layoutSubtreeIfNeeded()
        await drainMainQueue(passes: 6)

        XCTAssertGreaterThan(table.rect(ofRow: tailRow).height, 300)
        XCTAssertEqual(
            table.rect(ofRow: unseenRow).height,
            table.rowHeight,
            accuracy: 1,
            "live prefixes must not publish a conversation-wide height estimate")

        coordinator.sync(chunks: chunks(finalTail: true), content: { _ in AnyView(EmptyView()) })
        let finalCell = table.view(
            atColumn: 0,
            row: tailRow,
            makeIfNecessary: true) as? NativeAssistantCell
        finalCell?.layoutSubtreeIfNeeded()
        await drainMainQueue(passes: 6)

        XCTAssertGreaterThan(
            table.rect(ofRow: unseenRow).height,
            300,
            "the finalized response should train unseen rows exactly once")

        pin.scrollView = nil
        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    func testEveryActivityCellClipsContentWhileItsMeasuredHeightSettles() {
        let header = ActivityGroupHeaderCell(frame: NSRect(x: 0, y: 0, width: 600, height: 44))
        let action = ActivityActionCell(frame: NSRect(x: 0, y: 0, width: 600, height: 44))

        for cell in [header, action] {
            XCTAssertTrue(cell.wantsLayer)
            XCTAssertEqual(
                cell.layer?.masksToBounds,
                true,
                "native activity content must never paint through a temporarily short table row")
        }
    }

    func testSelectableMarkdownWrapsInsteadOfEllipsizingInNativeRow() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        scroll.documentView = table
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = scroll
        window.alphaValue = 0
        window.orderFrontRegardless()

        let paragraph = Array(repeating:
            "Selectable Markdown from a real assistant response must wrap to every visible line.",
            count: 12).joined(separator: " ")
        coordinator.sync(
            chunks: [.init(id: AnyHashable("markdown-row"), revision: 1)],
            content: { _ in
                AnyView(MarkdownText(text: paragraph)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading))
            })
        let cell = table.view(
            atColumn: 0, row: 0, makeIfNecessary: true) as? TranscriptHostingCell
        table.layoutSubtreeIfNeeded()
        await drainMainQueue()

        XCTAssertGreaterThan(cell?.lastMeasuredHeight ?? 0, 200)
        XCTAssertGreaterThan(table.rect(ofRow: 0).height, 200)
        let laidOutCell = table.view(
            atColumn: 0, row: 0, makeIfNecessary: true) as? TranscriptHostingCell
        laidOutCell?.layoutSubtreeIfNeeded()
        let selectionFields = descendants(of: laidOutCell).filter {
            let name = String(describing: type(of: $0))
            return name.contains("SelectionTextField") || name.contains("AppKitTextInteractionView")
        }
        XCTAssertFalse(selectionFields.isEmpty)
        XCTAssertGreaterThan(selectionFields.map(\.frame.height).max() ?? 0, 100)

        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    func testPinIgnoresTrailingTableDocumentSlack() {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let chunks = (0..<12).map {
            AppKitTranscriptChunk(id: AnyHashable("row-\($0)"), revision: 1)
        }
        coordinator.sync(chunks: chunks, content: { index in
            AnyView(Text("Transcript row \(index)"))
        })
        table.reloadData()
        table.layoutSubtreeIfNeeded()

        let contentBottom = table.rect(ofRow: table.numberOfRows - 1).maxY
        XCTAssertGreaterThan(contentBottom, 300)
        // NSTableView can retain an older, taller document frame after hosted content shrinks.
        // That trailing frame is not transcript content and must not determine the pinned bottom.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        scroll.documentView = table
        table.setFrameSize(NSSize(width: 600, height: contentBottom + 420))
        let pin = TranscriptPinController()
        pin.scrollView = scroll
        pin.pinToBottom()

        let expectedY = contentBottom - scroll.contentView.bounds.height
        XCTAssertEqual(scroll.contentView.bounds.origin.y, expectedY, accuracy: 1)

        pin.scrollView = nil
        coordinator.removeAll()
    }

    func testCoordinatorRemovesScrollableSpacePastFinalRow() {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let chunks = (0..<12).map {
            AppKitTranscriptChunk(id: AnyHashable("row-\($0)"), revision: 1)
        }
        coordinator.sync(chunks: chunks, content: { index in
            AnyView(Text("Transcript row \(index)"))
        })
        table.reloadData()
        table.layoutSubtreeIfNeeded()

        let contentBottom = table.rect(ofRow: table.numberOfRows - 1).maxY
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        scroll.documentView = table
        table.setFrameSize(NSSize(width: 600, height: contentBottom + 420))
        let pin = TranscriptPinController()
        coordinator.attach(table: table, scrollView: scroll, pin: pin)
        pin.scrollView = scroll
        coordinator.reconcileDocumentGeometry()

        XCTAssertEqual(table.frame.height, contentBottom, accuracy: 1)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: contentBottom + 200))
        scroll.reflectScrolledClipView(scroll.contentView)
        pin.nativeDocumentGeometryChanged()
        XCTAssertLessThanOrEqual(
            scroll.contentView.bounds.origin.y,
            contentBottom - scroll.contentView.bounds.height + 1)

        pin.scrollView = nil
        coordinator.removeAll()
    }

    func testGrowingTailNotifiesPinWhenDocumentFrameWasAlreadyTall() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        scroll.documentView = table
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = scroll
        window.alphaValue = 0
        window.orderFrontRegardless()
        let pin = TranscriptPinController()
        coordinator.attach(table: table, scrollView: scroll, pin: pin)
        pin.scrollView = scroll

        let id = AnyHashable("expandable-tail")
        coordinator.sync(
            chunks: [.init(id: id, revision: 1)],
            content: { _ in AnyView(Self.transcriptText(lines: 3)) })
        _ = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        await drainMainQueue(passes: 5)
        pin.pinToBottom()

        // Simulate AppKit retaining a document frame large enough that the row's subsequent growth
        // would not itself post a frame-change notification.
        table.setFrameSize(NSSize(width: 600, height: 1_200))
        coordinator.sync(
            chunks: [.init(id: id, revision: 2)],
            content: { _ in AnyView(Self.transcriptText(lines: 32)) })
        await drainMainQueue(passes: 8)

        let contentBottom = table.rect(ofRow: 0).maxY
        XCTAssertGreaterThan(contentBottom, scroll.contentView.bounds.height)
        XCTAssertEqual(table.frame.height, contentBottom, accuracy: 1)
        XCTAssertEqual(
            scroll.contentView.bounds.origin.y,
            contentBottom - scroll.contentView.bounds.height,
            accuracy: 1)

        pin.scrollView = nil
        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    func testActivityDisclosureDefersRichContentAndKeepsNativeBottomExact() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 180))
        scroll.documentView = table
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = scroll
        window.alphaValue = 0
        window.orderFrontRegardless()
        let pin = TranscriptPinController()
        coordinator.attach(table: table, scrollView: scroll, pin: pin)
        pin.scrollView = scroll

        let groupID = AnyHashable("activity-group")
        let actions = [
            AppKitActivityAction(
                id: AnyHashable("read"), sourceIndex: 0, toolName: "Read",
                rawInput: #"{"file_path":"App.swift"}"#, state: .succeeded),
            AppKitActivityAction(
                id: AnyHashable("edit"), sourceIndex: 1, toolName: "Edit",
                rawInput: #"{"file_path":"App.swift"}"#, state: .succeeded),
            AppKitActivityAction(
                id: AnyHashable("bash"), sourceIndex: 2, toolName: "Bash",
                rawInput: #"{"command":"swift test"}"#, state: .succeeded),
        ]
        let ordinaryRows = (0..<5).map {
            AppKitTranscriptChunk(id: AnyHashable("ordinary-\($0)"), revision: 1, sourceIndex: $0)
        }
        let activityRow = AppKitTranscriptChunk(
            id: groupID,
            revision: 1,
            sourceIndex: 5,
            activityGroup: AppKitActivityGroup(id: groupID, actions: actions, chatScale: 1))
        var richDetailBuilds: [Int] = []
        coordinator.sync(
            chunks: ordinaryRows + [activityRow],
            content: { _ in AnyView(Self.transcriptText(lines: 1)) },
            activityDetail: { sourceIndex in
                richDetailBuilds.append(sourceIndex)
                return AnyView(Self.transcriptText(lines: 20))
            })
        let headerRow = table.numberOfRows - 1
        _ = table.view(atColumn: 0, row: headerRow, makeIfNecessary: true)
        await drainMainQueue(passes: 6)
        pin.pinToBottom()

        let collapsedHeight = table.rect(ofRow: headerRow).height
        var cell = table.view(atColumn: 0, row: headerRow, makeIfNecessary: true)
        var buttons = descendants(of: cell).compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 1)
        XCTAssertTrue(richDetailBuilds.isEmpty)

        buttons[0].performClick(nil)
        await drainMainQueue(passes: 6)
        XCTAssertEqual(table.numberOfRows, ordinaryRows.count + actions.count + 1)
        let lastActionRow = headerRow + actions.count
        let actionListHeight = table.rect(ofRow: lastActionRow).maxY
            - table.rect(ofRow: headerRow).minY
        XCTAssertGreaterThan(actionListHeight, collapsedHeight + 70)
        XCTAssertTrue(richDetailBuilds.isEmpty)

        var disclosureColumns: [CGFloat] = []
        for rowIndex in (headerRow + 1)...lastActionRow {
            guard let actionCell = table.view(
                atColumn: 0, row: rowIndex, makeIfNecessary: true) as? ActivityActionCell
            else {
                XCTFail("Missing Activity action row \(rowIndex)")
                continue
            }
            actionCell.layoutSubtreeIfNeeded()
            let imageViews = descendants(of: actionCell).compactMap { $0 as? NSImageView }
            guard let trailingImage = imageViews.max(by: {
                $0.convert($0.bounds, to: actionCell).maxX
                    < $1.convert($1.bounds, to: actionCell).maxX
            }) else {
                XCTFail("Missing Activity disclosure chevron")
                continue
            }
            disclosureColumns.append(
                trailingImage.convert(trailingImage.bounds, to: actionCell).midX)
        }
        XCTAssertEqual(disclosureColumns.count, actions.count)
        if let firstColumn = disclosureColumns.first {
            for column in disclosureColumns.dropFirst() {
                XCTAssertEqual(
                    column, firstColumn, accuracy: 0.5,
                    "Activity disclosure chevrons must share one trailing column.")
            }
        }

        cell = table.view(atColumn: 0, row: headerRow + 1, makeIfNecessary: true)
        buttons = descendants(of: cell).compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 1)

        buttons[0].performClick(nil)
        await drainMainQueue(passes: 10)
        let richDetailHeight = table.rect(ofRow: lastActionRow).maxY
            - table.rect(ofRow: headerRow).minY
        XCTAssertEqual(richDetailBuilds, [0])
        XCTAssertGreaterThan(richDetailHeight, actionListHeight + 200)
        let expandedBottom = table.rect(ofRow: lastActionRow).maxY
        XCTAssertEqual(table.frame.height, expandedBottom, accuracy: 1)
        XCTAssertEqual(
            scroll.contentView.bounds.origin.y,
            expandedBottom - scroll.contentView.bounds.height,
            accuracy: 1)

        // Collapsing a group must release its rich child and remove all stale native scroll range.
        cell = table.view(atColumn: 0, row: headerRow, makeIfNecessary: true)
        buttons = descendants(of: cell).compactMap { $0 as? NSButton }
        buttons[0].performClick(nil)
        await drainMainQueue(passes: 8)
        XCTAssertEqual(table.numberOfRows, ordinaryRows.count + 1)
        XCTAssertEqual(table.rect(ofRow: headerRow).height, collapsedHeight, accuracy: 2)
        let collapsedBottom = table.rect(ofRow: headerRow).maxY
        XCTAssertEqual(table.frame.height, collapsedBottom, accuracy: 1)
        XCTAssertEqual(
            scroll.contentView.bounds.origin.y,
            collapsedBottom - scroll.contentView.bounds.height,
            accuracy: 1)

        // Reopening returns to the minimal native action list; rich detail is opt-in each time.
        cell = table.view(atColumn: 0, row: headerRow, makeIfNecessary: true)
        buttons = descendants(of: cell).compactMap { $0 as? NSButton }
        buttons[0].performClick(nil)
        await drainMainQueue(passes: 6)
        XCTAssertEqual(richDetailBuilds, [0])
        let reopenedLastRow = headerRow + actions.count
        let reopenedHeight = table.rect(ofRow: reopenedLastRow).maxY
            - table.rect(ofRow: headerRow).minY
        XCTAssertEqual(reopenedHeight, actionListHeight, accuracy: 2)

        pin.scrollView = nil
        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    func testLargeActivityGroupDisclosureStaysNativeAndResponsive() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        scroll.documentView = table
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = scroll
        window.alphaValue = 0
        window.orderFrontRegardless()

        let groupID = AnyHashable("large-activity-group")
        let actions = (0..<144).map { index in
            AppKitActivityAction(
                id: AnyHashable("large-action-\(index)"),
                sourceIndex: index,
                toolName: index.isMultiple(of: 3) ? "Edit" : (index.isMultiple(of: 2) ? "Read" : "Bash"),
                rawInput: #"{"file_path":"Sources/Feature.swift","command":"swift test"}"#,
                state: .succeeded)
        }
        var richDetailBuildCount = 0
        coordinator.sync(
            chunks: [.init(
                id: groupID,
                revision: 1,
                activityGroup: AppKitActivityGroup(id: groupID, actions: actions, chatScale: 1))],
            content: { _ in AnyView(EmptyView()) },
            activityDetail: { _ in
                richDetailBuildCount += 1
                return AnyView(Self.transcriptText(lines: 10))
            })
        var cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        await drainMainQueue(passes: 5)
        var buttons = descendants(of: cell).compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 1)

        let start = ProcessInfo.processInfo.systemUptime
        buttons[0].performClick(nil)
        let synchronousDisclosureTime = ProcessInfo.processInfo.systemUptime - start
        await drainMainQueue(passes: 6)

        cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        buttons = descendants(of: cell).compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 1)
        XCTAssertEqual(table.numberOfRows, actions.count + 1)
        let realizedActionRows = (1...actions.count).filter {
            table.view(atColumn: 0, row: $0, makeIfNecessary: false) != nil
        }.count
        XCTAssertLessThan(realizedActionRows, 40)
        XCTAssertEqual(richDetailBuildCount, 0)
        // The guarantees this test exists for are the two assertions above: disclosure realizes a
        // bounded number of rows and builds no rich detail. This wall-clock check is a coarse
        // backstop against a catastrophic regression, not a benchmark. It measures ~0.10s on
        // developer hardware but 0.16-0.32s on shared CI runners, so a 0.15s budget failed there
        // while the lazy-realization behaviour was entirely intact.
        XCTAssertLessThan(
            synchronousDisclosureTime, 1.0,
            "A 144-action disclosure took \(synchronousDisclosureTime)s")

        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    func testStreamingToolRunStartsAndExtendsOneStableActivityHeader() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 220))
        scroll.documentView = table
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 220),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = scroll
        window.alphaValue = 0
        window.orderFrontRegardless()
        let pin = TranscriptPinController()
        coordinator.attach(table: table, scrollView: scroll, pin: pin)
        pin.scrollView = scroll

        let groupID = AnyHashable("stable-first-tool")
        let first = AppKitActivityAction(
            id: AnyHashable("read"), sourceIndex: 0, toolName: "Read",
            rawInput: "{}", state: .running, revision: 1)
        coordinator.sync(
            chunks: [.init(
                id: groupID,
                revision: 1,
                activityGroup: AppKitActivityGroup(
                    id: groupID, actions: [first], chatScale: 1))],
            content: { _ in AnyView(EmptyView()) })
        var visible = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        await drainMainQueue(passes: 5)
        XCTAssertTrue(visible is ActivityGroupHeaderCell)
        XCTAssertEqual(table.numberOfRows, 1)
        let initialHeaderHeight = table.rect(ofRow: 0).height
        pin.pinToBottom()
        let initialViewportY = scroll.contentView.bounds.origin.y

        let firstTwo = [
            AppKitActivityAction(
                id: AnyHashable("read"), sourceIndex: 0, toolName: "Read",
                rawInput: "{}", state: .succeeded, revision: 1),
            AppKitActivityAction(
                id: AnyHashable("edit"), sourceIndex: 1, toolName: "Edit",
                rawInput: "{}", state: .running, revision: 1),
        ]
        coordinator.sync(
            chunks: [.init(
                id: groupID,
                revision: 2,
                activityGroup: AppKitActivityGroup(id: groupID, actions: firstTwo, chatScale: 1))],
            content: { _ in AnyView(EmptyView()) })
        await drainMainQueue(passes: 5)
        visible = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        XCTAssertTrue(visible is ActivityGroupHeaderCell)
        XCTAssertTrue(descendants(of: visible).contains { $0 is OrbitingDotsLayerView })
        XCTAssertFalse(descendants(of: visible).contains { $0 is NSProgressIndicator })
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(table.rect(ofRow: 0).height, initialHeaderHeight, accuracy: 1)
        XCTAssertEqual(
            scroll.contentView.bounds.origin.y,
            initialViewportY,
            accuracy: 1,
            "Adding an action to a collapsed group must not bounce the transcript viewport.")

        let headerButton = descendants(of: visible).compactMap { $0 as? NSButton }.first
        headerButton?.performClick(nil)
        await drainMainQueue(passes: 5)
        XCTAssertEqual(table.numberOfRows, 3)

        let third = AppKitActivityAction(
            id: AnyHashable("bash"), sourceIndex: 2, toolName: "Bash",
            rawInput: "{}", state: .running, revision: 1)
        coordinator.sync(
            chunks: [.init(
                id: groupID,
                revision: 3,
                activityGroup: AppKitActivityGroup(
                    id: groupID, actions: firstTwo + [third], chatScale: 1))],
            content: { _ in AnyView(EmptyView()) })
        await drainMainQueue(passes: 6)

        XCTAssertEqual(table.numberOfRows, 4)
        XCTAssertTrue(table.view(atColumn: 0, row: 0, makeIfNecessary: true) is ActivityGroupHeaderCell)
        XCTAssertTrue(table.view(atColumn: 0, row: 3, makeIfNecessary: true) is ActivityActionCell)
        let contentBottom = table.rect(ofRow: 3).maxY
        XCTAssertEqual(table.frame.height, max(contentBottom, scroll.contentView.bounds.height), accuracy: 1)

        pin.scrollView = nil
        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    func testCollapsedActivityHeaderStaysStableAsAssistantResponseStartsAndGrows() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 180))
        scroll.documentView = table
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = scroll
        window.alphaValue = 0
        window.orderFrontRegardless()
        let pin = TranscriptPinController()
        coordinator.attach(table: table, scrollView: scroll, pin: pin)
        pin.scrollView = scroll

        let groupID = AnyHashable("activity-before-response")
        let responseID = AnyHashable("streamed-response")
        let actions = [
            AppKitActivityAction(
                id: AnyHashable("edit"), sourceIndex: 0, toolName: "Edit",
                rawInput: "{}", state: .succeeded, revision: 1),
            AppKitActivityAction(
                id: AnyHashable("read"), sourceIndex: 1, toolName: "Read",
                rawInput: "{}", state: .succeeded, revision: 1),
            AppKitActivityAction(
                id: AnyHashable("bash"), sourceIndex: 2, toolName: "Bash",
                rawInput: "{}", state: .succeeded, revision: 1),
        ]
        let group = AppKitTranscriptChunk(
            id: groupID,
            revision: 1,
            activityGroup: AppKitActivityGroup(id: groupID, actions: actions, chatScale: 1))

        coordinator.sync(
            chunks: [group],
            content: { _ in AnyView(EmptyView()) })
        _ = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        await drainMainQueue(passes: 6)
        let headerHeight = table.rect(ofRow: 0).height

        var streamedLineCount = 1
        coordinator.sync(
            chunks: [
                group,
                AppKitTranscriptChunk(id: responseID, revision: 1, sourceIndex: 3),
            ],
            content: { index in
                index == 3
                    ? AnyView(Self.transcriptText(lines: streamedLineCount))
                    : AnyView(EmptyView())
            })
        _ = table.view(atColumn: 0, row: 1, makeIfNecessary: true)
        await drainMainQueue(passes: 8)
        pin.pinToBottom()

        let initialResponseHeight = table.rect(ofRow: 1).height
        XCTAssertEqual(table.rect(ofRow: 0).height, headerHeight, accuracy: 1)
        XCTAssertEqual(
            table.rect(ofRow: 1).minY,
            table.rect(ofRow: 0).maxY,
            accuracy: 1,
            "The assistant response must begin directly below the collapsed Activity header.")

        streamedLineCount = 20
        coordinator.sync(
            chunks: [
                group,
                AppKitTranscriptChunk(id: responseID, revision: 2, sourceIndex: 3),
            ],
            content: { index in
                index == 3
                    ? AnyView(Self.transcriptText(lines: streamedLineCount))
                    : AnyView(EmptyView())
            })
        _ = table.view(atColumn: 0, row: 1, makeIfNecessary: true)
        await drainMainQueue(passes: 10)

        XCTAssertGreaterThan(table.rect(ofRow: 1).height, initialResponseHeight)
        XCTAssertEqual(table.rect(ofRow: 0).height, headerHeight, accuracy: 1)
        XCTAssertEqual(
            table.rect(ofRow: 1).minY,
            table.rect(ofRow: 0).maxY,
            accuracy: 1,
            "Streaming prose must not open a transient gap or jump across the Activity header.")
        let expectedBottomY = max(
            -scroll.contentInsets.top,
            table.rect(ofRow: 1).maxY - scroll.contentView.bounds.height
                + scroll.contentInsets.bottom)
        XCTAssertEqual(
            scroll.contentView.bounds.origin.y,
            expectedBottomY,
            accuracy: 2,
            "A growing response must settle at the true bottom on the same native layout cycle.")

        pin.scrollView = nil
        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    func testRunningActivityActionUsesCompositorSpinnerAndQuietSurface() async {
        _ = NSApplication.shared
        let cell = ActivityActionCell(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
        let running = AppKitActivityAction(
            id: AnyHashable("running-command"),
            sourceIndex: 0,
            toolName: "Bash",
            rawInput: #"{"command":"swift test"}"#,
            state: .running)

        cell.setAction(
            running,
            presentationID: AnyHashable("running-presentation"),
            revision: 1,
            title: activityActionTitle(running),
            expanded: false,
            isLast: true,
            chatScale: 1,
            existingMeasuredHeight: nil,
            detail: nil,
            onToggle: {},
            onMeasuredHeight: { _, _, _ in })
        cell.layoutSubtreeIfNeeded()
        await drainMainQueue(passes: 3)

        XCTAssertTrue(descendants(of: cell).contains { $0 is OrbitingDotsLayerView })
        XCTAssertFalse(descendants(of: cell).contains { $0 is NSProgressIndicator })
        let background = descendants(of: cell).first {
            String(describing: type(of: $0)).contains("ActivityCardBackground")
        }
        XCTAssertNotNil(background)
        XCTAssertEqual(background?.layer?.borderWidth, 0)

        let completed = AppKitActivityAction(
            id: AnyHashable("running-command"),
            sourceIndex: 0,
            toolName: "Bash",
            rawInput: #"{"command":"swift test"}"#,
            state: .succeeded)
        cell.setAction(
            completed,
            presentationID: AnyHashable("running-presentation"),
            revision: 2,
            title: activityActionTitle(completed),
            expanded: false,
            isLast: true,
            chatScale: 1,
            existingMeasuredHeight: nil,
            detail: nil,
            onToggle: {},
            onMeasuredHeight: { _, _, _ in })
        cell.layoutSubtreeIfNeeded()

        XCTAssertFalse(descendants(of: cell).contains { $0 is OrbitingDotsLayerView })
    }

    func testSupersededActivityIsVisibleAndMeaningfulToVoiceOver() async {
        _ = NSApplication.shared
        let action = AppKitActivityAction(
            id: AnyHashable("superseded-command"),
            sourceIndex: 0,
            toolName: "Bash",
            rawInput: #"{"command":"swift test"}"#,
            state: .succeeded,
            isSuperseded: true)
        let title = activityActionTitle(action)
        let actionCell = ActivityActionCell(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
        actionCell.setAction(
            action,
            presentationID: AnyHashable("superseded-presentation"),
            revision: 1,
            title: title,
            expanded: false,
            isLast: true,
            chatScale: 1,
            existingMeasuredHeight: nil,
            detail: nil,
            onToggle: {},
            onMeasuredHeight: { _, _, _ in })
        actionCell.layoutSubtreeIfNeeded()
        await drainMainQueue(passes: 2)

        XCTAssertTrue(descendants(of: actionCell).contains {
            ($0 as? NSTextField)?.stringValue == "Superseded"
        })
        let actionButton = descendants(of: actionCell).compactMap { $0 as? NSButton }.first
        XCTAssertEqual(
            actionButton?.accessibilityLabel(),
            supersededActionAccessibilityLabel(title, isSuperseded: true))

        let groupCell = ActivityGroupHeaderCell(
            frame: NSRect(x: 0, y: 0, width: 600, height: 38))
        let group = AppKitActivityGroup(
            id: AnyHashable("superseded-group"),
            actions: [action],
            chatScale: 1)
        groupCell.setGroup(
            group,
            id: group.id,
            revision: 1,
            expanded: false,
            topPadding: 0,
            onToggle: {},
            onMeasuredHeight: { _, _, _ in })
        groupCell.layoutSubtreeIfNeeded()

        XCTAssertTrue(descendants(of: groupCell).contains {
            ($0 as? NSTextField)?.stringValue == "Superseded"
        })
        let groupButton = descendants(of: groupCell).compactMap { $0 as? NSButton }.first
        XCTAssertEqual(
            groupButton?.accessibilityLabel(),
            activityGroupAccessibilityLabel(activitySummary(group.actions), supersededCount: 1))
    }

    func testExpandedActivityDetailNeverOverlapsFollowingResponse() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        scroll.documentView = table
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = scroll
        window.alphaValue = 0
        window.orderFrontRegardless()
        let pin = TranscriptPinController()
        coordinator.attach(table: table, scrollView: scroll, pin: pin)
        pin.scrollView = scroll

        let groupID = AnyHashable("expanded-before-response")
        let responseID = AnyHashable("response-after-expanded-activity")
        var detailLines = 2
        func group(revision: Int) -> AppKitTranscriptChunk {
            AppKitTranscriptChunk(
                id: groupID,
                revision: revision,
                activityGroup: AppKitActivityGroup(
                    id: groupID,
                    actions: [AppKitActivityAction(
                        id: AnyHashable("edit"), sourceIndex: 0, toolName: "Edit",
                        rawInput: #"{"file_path":"Feature.swift"}"#,
                        state: .running, revision: revision)],
                    chatScale: 1))
        }
        let response = AppKitTranscriptChunk(id: responseID, revision: 1, sourceIndex: 1)
        func sync(revision: Int) {
            coordinator.sync(
                chunks: [group(revision: revision), response],
                content: { index in
                    index == 1 ? AnyView(Self.transcriptText(lines: 8)) : AnyView(EmptyView())
                },
                activityDetail: { _ in AnyView(Self.transcriptText(lines: detailLines)) })
        }

        sync(revision: 1)
        var header = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        _ = table.view(atColumn: 0, row: 1, makeIfNecessary: true)
        await drainMainQueue(passes: 7)
        descendants(of: header).compactMap { $0 as? NSButton }.first?.performClick(nil)
        await drainMainQueue(passes: 7)
        XCTAssertEqual(table.numberOfRows, 3)

        var action = table.view(atColumn: 0, row: 1, makeIfNecessary: true)
        _ = table.view(atColumn: 0, row: 2, makeIfNecessary: true)
        descendants(of: action).compactMap { $0 as? NSButton }.first?.performClick(nil)
        await drainMainQueue(passes: 10)
        XCTAssertEqual(table.rect(ofRow: 2).minY, table.rect(ofRow: 1).maxY, accuracy: 1)

        // A running detail can grow after the response row already exists. AppKit must move that
        // response on the same measured-height cycle rather than painting it under the Activity card.
        detailLines = 80
        sync(revision: 2)
        header = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        action = table.view(atColumn: 0, row: 1, makeIfNecessary: true)
        _ = table.view(atColumn: 0, row: 2, makeIfNecessary: true)
        await drainMainQueue(passes: 14)

        XCTAssertTrue(header is ActivityGroupHeaderCell)
        XCTAssertTrue(action is ActivityActionCell)
        let detailRoot = descendants(of: action).first {
            String(describing: type(of: $0)).contains("NSHosting")
        }
        let detailContainer = detailRoot?.superview
        XCTAssertNotNil(detailRoot)
        XCTAssertNotNil(detailContainer)
        XCTAssertEqual(detailRoot?.frame, detailContainer?.bounds)
        XCTAssertEqual(detailContainer?.layer?.masksToBounds, true,
                       "Rich Activity detail must not paint through its native header while sizing.")
        XCTAssertGreaterThan(table.rect(ofRow: 1).height, 500)
        XCTAssertEqual(
            table.rect(ofRow: 2).minY,
            table.rect(ofRow: 1).maxY,
            accuracy: 1,
            "A growing Activity detail must never cover the following message.")
        XCTAssertEqual(
            table.frame.height,
            table.rect(ofRow: 2).maxY,
            accuracy: 1,
            "The native document must end at the final visible response.")

        pin.scrollView = nil
        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    func testNarrowingInspectorKeepsEveryMarkdownLineBelowActivity() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        table.setFrameSize(NSSize(width: 1_050, height: table.frame.height))
        table.tableColumns[0].width = 1_050
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1_050, height: 420))
        scroll.documentView = table
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_050, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = scroll
        window.alphaValue = 0
        window.orderFrontRegardless()

        let groupID = AnyHashable("activity-before-narrow-markdown")
        let responseID = AnyHashable("narrowed-markdown-response")
        let group = AppKitTranscriptChunk(
            id: groupID,
            revision: 1,
            activityGroup: AppKitActivityGroup(
                id: groupID,
                actions: [
                    AppKitActivityAction(id: "edit", sourceIndex: 0, toolName: "Edit", rawInput: "{}", state: .succeeded),
                    AppKitActivityAction(id: "read", sourceIndex: 1, toolName: "Read", rawInput: "{}", state: .succeeded),
                    AppKitActivityAction(id: "bash", sourceIndex: 2, toolName: "Bash", rawInput: "{}", state: .succeeded),
                ],
                chatScale: 1))
        let response = AppKitTranscriptChunk(id: responseID, revision: 1, sourceIndex: 3)
        let prose = "The grouped activity is complete. This response begins directly below the stable Activity header and grows without jumping. Additional streamed text wraps onto further lines while the native viewport remains pinned. The final line should remain polished and readable above the composer."
        coordinator.sync(
            chunks: [group, response],
            content: { index in
                index == 3
                    ? AnyView(VStack(alignment: .leading, spacing: 3) {
                        MarkdownText(text: prose)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.nSurface))
                    }.frame(maxWidth: .infinity, alignment: .leading))
                    : AnyView(EmptyView())
            })
        _ = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        var responseCell = table.view(
            atColumn: 0, row: 1, makeIfNecessary: true) as? TranscriptHostingCell
        await drainMainQueue(passes: 8)
        let wideHeight = table.rect(ofRow: 1).height

        // Opening the inspector nearly halves the transcript width. The hosted Markdown must
        // remeasure before AppKit clips it, and its row must remain directly after Activity.
        scroll.setFrameSize(NSSize(width: 620, height: 420))
        table.setFrameSize(NSSize(width: 620, height: table.frame.height))
        table.tableColumns[0].width = 620
        table.tile()
        table.layoutSubtreeIfNeeded()
        responseCell = table.view(
            atColumn: 0, row: 1, makeIfNecessary: true) as? TranscriptHostingCell
        responseCell?.needsLayout = true
        responseCell?.layoutSubtreeIfNeeded()
        await drainMainQueue(passes: 10)

        let narrowHeight = table.rect(ofRow: 1).height
        XCTAssertGreaterThan(narrowHeight, wideHeight)
        XCTAssertEqual(table.rect(ofRow: 1).minY, table.rect(ofRow: 0).maxY, accuracy: 1)
        guard let responseCell else { return XCTFail("Missing narrowed response cell") }
        responseCell.layoutSubtreeIfNeeded()
        let selectionFields = descendants(of: responseCell).filter {
            let name = String(describing: type(of: $0))
            return name.contains("SelectionTextField") || name.contains("AppKitTextInteractionView")
        }
        XCTAssertFalse(selectionFields.isEmpty)
        for field in selectionFields {
            let frameInCell = field.convert(field.bounds, to: responseCell)
            XCTAssertGreaterThanOrEqual(frameInCell.minY, -1)
            XCTAssertLessThanOrEqual(
                frameInCell.maxY,
                responseCell.bounds.height + 1,
                "Every wrapped Markdown line must fit inside the remeasured native row.")
        }

        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    func testNativeAssistantUsesTextKitAndKeepsStreamingGrowthMonotonic() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 180))
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

        let responseID = AnyHashable("native-assistant-stream")
        func assistant(_ text: String, revision: Int, live: Bool = true) {
            coordinator.sync(
                chunks: [.init(
                    id: responseID,
                    revision: revision,
                    sourceIndex: 0,
                    assistant: AppKitAssistantContent(
                        text: text,
                        chatScale: 1,
                        isLive: live,
                        canRetry: !live,
                        cwd: "/tmp"))],
                content: { _ in AnyView(EmptyView()) })
        }

        assistant("A short native response.", revision: 1)
        let firstCell = table.view(
            atColumn: 0, row: 0, makeIfNecessary: true) as? NativeAssistantCell
        await drainMainQueue(passes: 4)
        XCTAssertNotNil(firstCell)
        XCTAssertFalse(descendants(of: firstCell).contains {
            $0 is NSHostingView<AnyView>
                || String(describing: type(of: $0)).contains("NSHosting")
        })
        XCTAssertTrue(descendants(of: firstCell).contains { $0 is NSTextView })
        let initialHeight = table.rect(ofRow: 0).height
        pin.pinToBottom()

        scroll.contentView.postsBoundsChangedNotifications = true
        var origins: [CGFloat] = []
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { _ in origins.append(scroll.contentView.bounds.origin.y) }

        let longResponse = Array(repeating:
            "Native TextKit measures the streamed assistant response at the final table width.",
            count: 40).joined(separator: " ")
        assistant(longResponse, revision: 2)
        let updatedCell = table.view(
            atColumn: 0, row: 0, makeIfNecessary: true) as? NativeAssistantCell
        await drainMainQueue(passes: 6)
        NotificationCenter.default.removeObserver(observer)

        XCTAssertEqual(updatedCell?.representedRevision, 2)
        XCTAssertGreaterThan(table.rect(ofRow: 0).height, initialHeight * 4)
        let significant = origins.reduce(into: [CGFloat]()) { values, value in
            if values.last.map({ abs($0 - value) > 0.5 }) ?? true { values.append(value) }
        }
        for (previous, next) in zip(significant, significant.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                next + 0.5, previous,
                "Native streaming growth must never reverse the pinned viewport: \(significant)")
        }
        XCTAssertLessThanOrEqual(
            significant.count, 1,
            "One native streamed revision should produce at most one viewport move: \(significant)")

        pin.scrollView = nil
        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    func testNativeAssistantActionLaneDoesNotGrowWhenDetachedTailCompletes() async throws {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 180))
        scroll.documentView = table
        let window = NSWindow(
            contentRect: scroll.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = scroll
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer {
            coordinator.removeAll()
            window.orderOut(nil)
            window.contentView = nil
        }

        let pin = TranscriptPinController()
        coordinator.attach(table: table, scrollView: scroll, pin: pin)
        pin.scrollView = scroll
        defer { pin.scrollView = nil }

        let responseID = AnyHashable("stable-assistant-action-lane")
        let response = Array(repeating:
            "A long response keeps its final controls at the same document position. ",
            count: 28).joined()
        func present(live: Bool, revision: Int) {
            coordinator.sync(
                chunks: [.init(
                    id: responseID,
                    revision: revision,
                    sourceIndex: 0,
                    assistant: AppKitAssistantContent(
                        text: response,
                        chatScale: 1,
                        isLive: live,
                        canRetry: true,
                        canFork: true,
                        cwd: "/tmp"))],
                content: { _ in AnyView(EmptyView()) })
        }

        present(live: true, revision: 1)
        table.reloadData()
        _ = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        await drainMainQueue(passes: 8)
        pin.pinToBottom()
        let liveHeight = table.rect(ofRow: 0).height
        let liveOrigin = scroll.contentView.bounds.origin.y

        // Reproduce a reader who stopped following while still looking at the live tail. The
        // terminal action lane must appear in the space that row already owned, not below the clip.
        pin.pinned = false
        present(live: false, revision: 2)
        let finalCell = try XCTUnwrap(table.view(
            atColumn: 0, row: 0, makeIfNecessary: true) as? NativeAssistantCell)
        await drainMainQueue(passes: 8)
        finalCell.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            table.rect(ofRow: 0).height,
            liveHeight,
            accuracy: 1,
            "revealing terminal actions must not change assistant-row geometry")
        XCTAssertEqual(
            scroll.contentView.bounds.origin.y,
            liveOrigin,
            accuracy: 1,
            "showing actions must not move a detached reader")

        let actionLabels = Set(["Copy", "Retry", "Fork"])
        let actions = descendants(of: finalCell).compactMap { $0 as? HoverActionButton }
            .filter { button in
                button.accessibilityLabel().map(actionLabels.contains) == true
            }
        XCTAssertEqual(actions.count, actionLabels.count)
        for button in actions {
            XCTAssertFalse(button.isHidden)
            let inCell = button.convert(button.bounds, to: finalCell)
            XCTAssertGreaterThanOrEqual(inCell.minY, -1)
            XCTAssertLessThanOrEqual(inCell.maxY, finalCell.bounds.maxY + 1)

            let inViewport = button.convert(button.bounds, to: scroll.contentView)
            XCTAssertGreaterThanOrEqual(inViewport.minY, scroll.contentView.bounds.minY - 1)
            XCTAssertLessThanOrEqual(
                inViewport.maxY,
                scroll.contentView.bounds.maxY + 1,
                "a terminal assistant action must be fully visible after a detached-tail landing")
        }
    }

    func testColdPreviewTailReloadsTerminalActionsAndSourceIndexAfterHydration() async throws {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        scroll.documentView = table
        let window = NSWindow(
            contentRect: scroll.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = scroll
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer {
            coordinator.removeAll()
            window.orderOut(nil)
            window.contentView = nil
        }

        let pin = TranscriptPinController()
        coordinator.attach(table: table, scrollView: scroll, pin: pin)
        pin.scrollView = scroll
        defer { pin.scrollView = nil }

        let responseID = AnyHashable("cold-preview-terminal-assistant")
        let response = Array(repeating:
            "A cold recent-page preview is replaced by the complete hydrated transcript. ",
            count: 12).joined()
        let preview = AppKitTranscriptChunk(
            id: responseID,
            revision: 1,
            sourceIndex: 0,
            assistant: AppKitAssistantContent(
                text: response,
                chatScale: 1,
                isLive: false,
                canRetry: false,
                canFork: false,
                cwd: "/preview"))
        coordinator.sync(
            chunks: [preview],
            content: { _ in AnyView(EmptyView()) },
            retryAssistant: { _ in XCTFail("preview Retry must be disabled") },
            forkAssistant: { _ in XCTFail("preview Fork must be disabled") })
        table.reloadData()
        let previewCell = try XCTUnwrap(table.view(
            atColumn: 0, row: 0, makeIfNecessary: true) as? NativeAssistantCell)
        await drainMainQueue(passes: 8)

        let actionLabels = Set(["Copy", "Retry", "Fork"])
        func actions(in cell: NativeAssistantCell) -> [String: HoverActionButton] {
            Dictionary(uniqueKeysWithValues: descendants(of: cell)
                .compactMap { $0 as? HoverActionButton }
                .compactMap { button in
                    guard let label = button.accessibilityLabel(),
                          actionLabels.contains(label) else { return nil }
                    return (label, button)
                })
        }
        let previewActions = actions(in: previewCell)
        XCTAssertFalse(try XCTUnwrap(previewActions["Copy"]).isHidden)
        XCTAssertTrue(try XCTUnwrap(previewActions["Retry"]).isHidden)
        XCTAssertTrue(try XCTUnwrap(previewActions["Fork"]).isHidden)

        var retriedIndexes: [Int] = []
        var forkedIndexes: [Int] = []
        let hydratedResponse = AppKitTranscriptChunk(
            id: responseID,
            // Persisted entry revision and ID are intentionally identical to the preview row.
            revision: 1,
            sourceIndex: 1,
            assistant: AppKitAssistantContent(
                text: response,
                chatScale: 1,
                isLive: false,
                canRetry: true,
                canFork: true,
                cwd: "/hydrated"))
        coordinator.sync(
            chunks: [
                .init(id: AnyHashable("cold-hydrated-prefix"), revision: 1, sourceIndex: 0),
                hydratedResponse,
            ],
            content: { _ in AnyView(EmptyView()) },
            retryAssistant: { retriedIndexes.append($0) },
            forkAssistant: { forkedIndexes.append($0) })
        let finalCell = try XCTUnwrap(table.view(
            atColumn: 0, row: 1, makeIfNecessary: true) as? NativeAssistantCell)
        await drainMainQueue(passes: 8)
        finalCell.layoutSubtreeIfNeeded()

        let finalActions = actions(in: finalCell)
        for label in actionLabels {
            let button = try XCTUnwrap(finalActions[label])
            XCTAssertFalse(button.isHidden, "\(label) must refresh after cold hydration")
            let frame = button.convert(button.bounds, to: finalCell)
            XCTAssertGreaterThanOrEqual(frame.minY, -1)
            XCTAssertLessThanOrEqual(
                frame.maxY,
                finalCell.bounds.maxY + 1,
                "\(label) must remain inside the hydrated terminal row")
        }

        try XCTUnwrap(finalActions["Retry"]).performClick(nil)
        try XCTUnwrap(finalActions["Fork"]).performClick(nil)
        XCTAssertEqual(retriedIndexes, [1])
        XCTAssertEqual(forkedIndexes, [1])
    }

    func testNativeAssistantMarkdownPrefixesNeverMovePinnedViewportBackward() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 180))
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

        let responseID = AnyHashable("native-assistant-prefix-stream")
        let prose = Array(repeating:
            "Streaming prose keeps the transcript taller than its viewport while Markdown arrives.",
            count: 16).joined(separator: " ")
        let prefixes = [
            prose,
            prose + "\n\n`",
            prose + "\n\n``",
            prose + "\n\n```",
            prose + "\n\n```swift",
            prose + "\n\n```swift\nlet value = 42",
            prose + "\n\n```swift\nlet value = 42\n```",
        ]

        func present(_ text: String, revision: Int) {
            coordinator.sync(
                chunks: [.init(
                    id: responseID,
                    revision: revision,
                    sourceIndex: 0,
                    assistant: AppKitAssistantContent(
                        text: text,
                        chatScale: 1,
                        isLive: true,
                        canRetry: false,
                        cwd: "/tmp"))],
                content: { _ in AnyView(EmptyView()) })
            _ = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        }

        present(prefixes[0], revision: 1)
        await drainMainQueue(passes: 6)
        pin.pinToBottom()
        var origins = [scroll.contentView.bounds.origin.y]

        for (offset, prefix) in prefixes.dropFirst().enumerated() {
            present(prefix, revision: offset + 2)
            await drainMainQueue(passes: 4)
            origins.append(scroll.contentView.bounds.origin.y)
        }

        for (previous, next) in zip(origins, origins.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                next + 0.5, previous,
                "Appending a Markdown prefix must not move the pinned viewport backward: \(origins)")
        }

        pin.scrollView = nil
        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    func testNativeMarkdownPreservesInlineSemanticsAndCodeColor() {
        let rendered = NativeMarkdownRenderer.render(
            "Plain **bold** and `code` with [link](https://example.com).\n\n```swift\nlet value = 42\n```",
            scale: 1)
        let full = NSRange(location: 0, length: rendered.length)
        var hasBold = false
        var hasLink = false
        var hasCodeBackground = false
        rendered.enumerateAttributes(in: full) { attributes, _, _ in
            if let font = attributes[.font] as? NSFont,
               NSFontManager.shared.traits(of: font).contains(.boldFontMask) {
                hasBold = true
            }
            if attributes[.link] != nil { hasLink = true }
            if attributes[.backgroundColor] != nil { hasCodeBackground = true }
        }
        XCTAssertTrue(hasBold)
        XCTAssertTrue(hasLink)
        XCTAssertTrue(hasCodeBackground)
    }

    func testNativeMarkdownRendersGFMTableAsTextKitTableBlocks() {
        let rendered = NativeMarkdownRenderer.render(
            "| Capability | Claude | Codex |\n|---|---|---|\n| Review | — | Native |\n| Rewind | Native | — |",
            scale: 1)
        let full = NSRange(location: 0, length: rendered.length)
        var textBlockCount = 0
        var hasBoldHeader = false
        rendered.enumerateAttributes(in: full) { attributes, _, _ in
            if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle {
                textBlockCount += paragraph.textBlocks.count
            }
            if let font = attributes[.font] as? NSFont,
               NSFontManager.shared.traits(of: font).contains(.boldFontMask) {
                hasBoldHeader = true
            }
        }

        XCTAssertGreaterThanOrEqual(textBlockCount, 9)
        XCTAssertTrue(hasBoldHeader)
        XCTAssertFalse(rendered.string.contains(" | "))
    }

    func testNativeAssistantPresentationRevisionDoesNotRerenderIdenticalMarkdown() {
        let cell = NativeAssistantCell(frame: NSRect(x: 0, y: 0, width: 560, height: 180))
        let id = AnyHashable("stable-markdown")

        func present(text: String, scale: CGFloat, live: Bool, revision: Int) {
            cell.setContent(
                AppKitAssistantContent(
                    text: text,
                    chatScale: scale,
                    isLive: live,
                    canRetry: !live,
                    cwd: "/tmp"),
                id: id,
                revision: revision,
                topPadding: 0,
                onRetry: {},
                onFork: {},
                onMeasuredHeight: { _, _, _ in })
        }

        present(text: "Same **Markdown**", scale: 1, live: true, revision: 1)
        XCTAssertEqual(cell.markdownRenderCountForTesting, 1)

        // Live → terminal canonically reconciles once before the finalized document is eligible for
        // reuse. Presentation-only revisions after that still leave the exact document untouched.
        present(text: "Same **Markdown**", scale: 1, live: false, revision: 2)
        XCTAssertEqual(cell.markdownRenderCountForTesting, 2)
        XCTAssertEqual(cell.canonicalMarkdownRenderCountForTesting, 2)

        // Length alone is not content identity, and zoom changes every font attribute.
        present(text: "Else **Markdown**", scale: 1, live: false, revision: 3)
        XCTAssertEqual(cell.markdownRenderCountForTesting, 3)
        present(text: "Else **Markdown**", scale: 1.1, live: false, revision: 4)
        XCTAssertEqual(cell.markdownRenderCountForTesting, 4)
    }

    func testNativeAssistantConsumesExactAppendMetadataAndCanonicallySeals() throws {
        let cell = NativeAssistantCell(frame: NSRect(x: 0, y: 0, width: 560, height: 240))
        let cache = FinalizedAssistantDocumentCache()
        let rowID = AnyHashable("exact-append-markdown")
        let conversationID = UUID()
        let entryID = UUID()
        var text = "A stable first paragraph.\n\nA live tail"

        func present(
            generation: UInt64,
            append: TranscriptTailAppend? = nil,
            live: Bool = true,
            revision: Int
        ) {
            cell.setContent(
                AppKitAssistantContent(
                    text: text,
                    chatScale: 1,
                    isLive: live,
                    canRetry: !live,
                    cwd: "/tmp",
                    tailAppend: append,
                    transcriptGeneration: generation),
                id: rowID,
                revision: revision,
                topPadding: 0,
                onRetry: {},
                onFork: {},
                onMeasuredHeight: { _, _, _ in },
                documentCache: cache)
        }

        present(generation: 1, revision: 1)
        XCTAssertEqual(cell.canonicalMarkdownRenderCountForTesting, 1)
        XCTAssertTrue(cell.setFindHighlight(query: "stable", occurrence: 0))
        let textView = try nativeTextView(in: cell)
        let stableSelection = (textView.string as NSString).range(of: "stable")
        textView.setSelectedRange(stableSelection)

        let firstDelta = " grows"
        let firstBase = text.utf8.count
        text += firstDelta
        present(
            generation: 2,
            append: TranscriptTailAppend(
                conversationID: conversationID,
                entryID: entryID,
                baseGeneration: 1,
                generation: 2,
                baseUTF8Count: firstBase,
                resultingUTF8Count: text.utf8.count,
                delta: firstDelta),
            revision: 2)

        XCTAssertEqual(cell.markdownRenderCountForTesting, 2)
        XCTAssertEqual(
            cell.canonicalMarkdownRenderCountForTesting,
            1,
            "an exact append must render only the mutable Markdown suffix")
        XCTAssertEqual(textView.string, NativeMarkdownRenderer.render(text, scale: 1).string)
        XCTAssertEqual(textView.selectedRange(), stableSelection)
        let highlighted = try XCTUnwrap(textView.textStorage)
        XCTAssertNotNil(highlighted.attribute(
            .backgroundColor, at: stableSelection.location, effectiveRange: nil))

        present(generation: 2, live: false, revision: 3)
        XCTAssertEqual(cell.canonicalMarkdownRenderCountForTesting, 2)
        XCTAssertEqual(cache.count, 1, "terminal truth should enter the finalized cache immediately")
        XCTAssertEqual(textView.string, NativeMarkdownRenderer.render(text, scale: 1).string)
    }

    func testFinalizedAssistantCacheSkipsLivePrefixesAndReusesOnlyExactDocuments() throws {
        let cache = FinalizedAssistantDocumentCache()
        let id = AnyHashable("finalized-cache-exactness")
        let liveCell = NativeAssistantCell(
            frame: NSRect(x: 0, y: 0, width: 560, height: 180))

        presentAssistant(
            liveCell, id: id, text: "Growing", scale: 1, live: true,
            revision: 1, cache: cache)
        presentAssistant(
            liveCell, id: id, text: "Growing response", scale: 1, live: true,
            revision: 2, cache: cache)
        XCTAssertEqual(cache.count, 0, "streaming prefixes must never consume the finalized MRU")
        XCTAssertEqual(liveCell.markdownRenderCountForTesting, 2)

        // Terminal reconciliation renders once from canonical source, before Find paint, and admits
        // that pristine result immediately. No possibly-highlighted live NSTextStorage is cached.
        presentAssistant(
            liveCell, id: id, text: "Growing response", scale: 1, live: false,
            revision: 3, cache: cache)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(liveCell.markdownRenderCountForTesting, 3)

        let firstRevisit = NativeAssistantCell(
            frame: NSRect(x: 0, y: 0, width: 560, height: 180))
        presentAssistant(
            firstRevisit, id: id, text: "Growing response", scale: 1, live: false,
            revision: 3, cache: cache)
        XCTAssertEqual(firstRevisit.markdownRenderCountForTesting, 0)
        XCTAssertEqual(cache.count, 1)

        let exactHit = NativeAssistantCell(
            frame: NSRect(x: 0, y: 0, width: 560, height: 180))
        presentAssistant(
            exactHit, id: id, text: "Growing response", scale: 1, live: false,
            revision: 99, cache: cache)
        XCTAssertEqual(exactHit.markdownRenderCountForTesting, 0)
        XCTAssertEqual(try nativeTextView(in: exactHit).string, "Growing response")

        // Same length is not identity. Reusing an entry id after an authoritative replacement must
        // fail closed to the renderer, as must any exact chat-scale change.
        let changedText = NativeAssistantCell(
            frame: NSRect(x: 0, y: 0, width: 560, height: 180))
        presentAssistant(
            changedText, id: id, text: "Changed response", scale: 1, live: false,
            revision: 100, cache: cache)
        XCTAssertEqual(changedText.markdownRenderCountForTesting, 1)
        XCTAssertEqual(try nativeTextView(in: changedText).string, "Changed response")

        let changedScale = NativeAssistantCell(
            frame: NSRect(x: 0, y: 0, width: 560, height: 180))
        presentAssistant(
            changedScale, id: id, text: "Changed response", scale: 1.1, live: false,
            revision: 101, cache: cache)
        XCTAssertEqual(changedScale.markdownRenderCountForTesting, 1)
        let font = try XCTUnwrap(
            nativeTextView(in: changedScale).textStorage?.attribute(
                .font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 14.3, accuracy: 0.01)
    }

    func testFinalizedAssistantCacheKeepsFindMutationsOutOfPristineDocument() throws {
        let cache = FinalizedAssistantDocumentCache()
        let id = AnyHashable("find-isolated-cache")
        let markdown = "A searchable needle beside `inline code`."
        let first = NativeAssistantCell(
            frame: NSRect(x: 0, y: 0, width: 560, height: 180))
        presentAssistant(
            first, id: id, text: markdown, scale: 1, live: false,
            revision: 1, cache: cache)

        let cached = try XCTUnwrap(cache.document(for: id, source: markdown, scale: 1))
        XCTAssertTrue(first.setFindHighlight(query: "needle", occurrence: 0))
        let highlighted = try nativeTextView(in: first)
        let highlightedStorage = try XCTUnwrap(highlighted.textStorage)
        let needle = (highlighted.string as NSString).range(of: "needle")
        XCTAssertNotNil(highlightedStorage.attribute(
            .backgroundColor, at: needle.location, effectiveRange: nil))

        // A second cell receives the same pristine cache entry, not the first cell's yellow/black
        // Find paint. Its original inline-code background remains present independently.
        let second = NativeAssistantCell(
            frame: NSRect(x: 0, y: 0, width: 560, height: 180))
        presentAssistant(
            second, id: id, text: markdown, scale: 1, live: false,
            revision: 2, cache: cache)
        XCTAssertEqual(second.markdownRenderCountForTesting, 0)
        let secondText = try nativeTextView(in: second)
        let secondStorage = try XCTUnwrap(secondText.textStorage)
        XCTAssertNil(secondStorage.attribute(
            .backgroundColor, at: needle.location, effectiveRange: nil))
        let inline = (secondText.string as NSString).range(of: "inline code")
        XCTAssertNotNil(secondStorage.attribute(
            .backgroundColor, at: inline.location, effectiveRange: nil))
        XCTAssertNil(cached.attribute(
            .backgroundColor, at: needle.location, effectiveRange: nil))

        first.clearFindHighlight()
        XCTAssertNil(highlightedStorage.attribute(
            .backgroundColor, at: needle.location, effectiveRange: nil))
        XCTAssertNotNil(highlightedStorage.attribute(
            .backgroundColor, at: inline.location, effectiveRange: nil))
    }

    func testCachedTableAndCodeDocumentReflowsIndependentlyAtTwoWidths() throws {
        let cache = FinalizedAssistantDocumentCache()
        let id = AnyHashable("shared-text-block-layout")
        let codeSource = Array(repeating:
            "let independentlyWrappedValue = providerAuthority + transcriptPresentation",
            count: 8).joined(separator: "\n")
        let markdown = """
        | Stage | Result |
        |---|---|
        | Provider harness | Remains authoritative |
        | Transcript presentation | Uses a bounded cache |

        ```swift
        \(codeSource)
        ```
        """
        var wideHeight: CGFloat = 0
        let wide = NativeAssistantCell(
            frame: NSRect(x: 0, y: 0, width: 680, height: 1_000))
        presentAssistant(
            wide, id: id, text: markdown, scale: 1, live: false,
            revision: 1, cache: cache,
            onHeight: { wideHeight = $0 })
        XCTAssertGreaterThan(wideHeight, 100)

        var narrowHeight: CGFloat = 0
        let narrow = NativeAssistantCell(
            frame: NSRect(x: 0, y: 0, width: 330, height: 1_000))
        presentAssistant(
            narrow, id: id, text: markdown, scale: 1, live: false,
            revision: 1, cache: cache,
            onHeight: { narrowHeight = $0 })
        XCTAssertEqual(narrow.markdownRenderCountForTesting, 0)
        XCTAssertGreaterThan(narrowHeight, wideHeight)

        let wideText = try nativeTextView(in: wide)
        let narrowText = try nativeTextView(in: narrow)
        for textView in [wideText, narrowText] {
            let storage = try XCTUnwrap(textView.textStorage)
            var codeRange: NSRange?
            storage.enumerateAttribute(
                .mechanicianCodeSource,
                in: NSRange(location: 0, length: storage.length)
            ) { value, range, stop in
                if value as? String == codeSource {
                    codeRange = range
                    stop.pointee = true
                }
            }
            XCTAssertNotNil(codeRange)
            var textBlockRuns = 0
            storage.enumerateAttribute(
                .paragraphStyle,
                in: NSRange(location: 0, length: storage.length)
            ) { value, _, _ in
                if let paragraph = value as? NSParagraphStyle,
                   !paragraph.textBlocks.isEmpty {
                    textBlockRuns += 1
                }
            }
            XCTAssertGreaterThan(textBlockRuns, 2)
        }

        // Laying the narrow storage through the shared table-block attributes must not alter the
        // already-realized wide cell's geometry.
        var remeasuredWideHeight = wideHeight
        wide.needsLayout = true
        wide.layoutSubtreeIfNeeded()
        presentAssistant(
            wide, id: id, text: markdown, scale: 1, live: false,
            revision: 2, cache: cache,
            onHeight: { remeasuredWideHeight = $0 })
        XCTAssertEqual(remeasuredWideHeight, wideHeight, accuracy: 1)
    }

    func testFinalizedAssistantCacheEnforcesMRUCostAndCountBounds() {
        XCTAssertEqual(FinalizedAssistantDocumentCache.maximumEntryCount, 32)
        XCTAssertEqual(
            FinalizedAssistantDocumentCache.maximumEstimatedCost,
            16 * 1_024 * 1_024)
        XCTAssertEqual(
            FinalizedAssistantDocumentCache.maximumSourceUTF8Count,
            512 * 1_024)
        XCTAssertEqual(
            FinalizedAssistantDocumentCache.maximumDocumentLength,
            512 * 1_024)

        let cache = FinalizedAssistantDocumentCache(maximumEntries: 2, maximumCost: 8_500)
        func insert(_ id: String, _ text: String = "one") {
            cache.insert(NSAttributedString(string: text), for: AnyHashable(id), source: text, scale: 1)
        }
        insert("a")
        insert("b")
        XCTAssertEqual(cache.count, 2)
        _ = cache.document(for: AnyHashable("a"), source: "one", scale: 1)
        insert("c")
        XCTAssertTrue(cache.contains(AnyHashable("a")), "a lookup must refresh MRU order")
        XCTAssertFalse(cache.contains(AnyHashable("b")))
        XCTAssertTrue(cache.contains(AnyHashable("c")))
        XCTAssertLessThanOrEqual(cache.estimatedCost, 8_500)

        let oversized = String(repeating: "x", count: 200)
        let oversizedBuilder = NSMutableAttributedString(string: oversized)
        let rejected = cache.insert(
            oversizedBuilder,
            for: AnyHashable("oversized"),
            source: oversized,
            scale: 1)
        XCTAssertTrue(
            rejected === oversizedBuilder,
            "an entry that cannot be retained must not pay for an immutable cache copy")
        XCTAssertFalse(cache.contains(AnyHashable("oversized")))
        XCTAssertLessThanOrEqual(cache.count, 2)
        XCTAssertLessThanOrEqual(cache.estimatedCost, 8_500)

        let sourceHeavy = String(
            repeating: "s",
            count: FinalizedAssistantDocumentCache.maximumSourceUTF8Count + 1)
        cache.insert(
            NSAttributedString(string: "short"),
            for: AnyHashable("source-heavy"),
            source: sourceHeavy,
            scale: 1)
        XCTAssertFalse(cache.contains(AnyHashable("source-heavy")))

        let expansionHeavy = String(
            repeating: "r",
            count: FinalizedAssistantDocumentCache.maximumDocumentLength + 1)
        cache.insert(
            NSAttributedString(string: expansionHeavy),
            for: AnyHashable("expansion-heavy"),
            source: "short",
            scale: 1)
        XCTAssertFalse(cache.contains(AnyHashable("expansion-heavy")))

        cache.retainOnly(Set([AnyHashable("c")]))
        XCTAssertEqual(cache.count, 1)
        XCTAssertTrue(cache.contains(AnyHashable("c")))
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.estimatedCost, 0)
    }

    func testCoordinatorPrunesFinalizedAssistantDocumentsWithPresentationRowsAndTeardown() {
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let id = AnyHashable("coordinator-cache-prune")
        func sync(live: Bool, revision: Int) {
            coordinator.sync(
                chunks: [.init(
                    id: id,
                    revision: revision,
                    sourceIndex: 0,
                    assistant: AppKitAssistantContent(
                        text: "A finalized response",
                        chatScale: 1,
                        isLive: live,
                        canRetry: !live,
                        cwd: "/tmp"))],
                content: { _ in AnyView(EmptyView()) })
        }

        sync(live: false, revision: 1)
        _ = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        XCTAssertEqual(coordinator.finalizedAssistantDocumentCountForTesting, 1)

        sync(live: true, revision: 2)
        XCTAssertEqual(
            coordinator.finalizedAssistantDocumentCountForTesting,
            1,
            "a same-row streamed update must not add another full-transcript pruning scan")

        sync(live: false, revision: 3)
        _ = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        XCTAssertEqual(coordinator.finalizedAssistantDocumentCountForTesting, 1)

        coordinator.sync(chunks: [], content: { _ in AnyView(EmptyView()) })
        XCTAssertEqual(coordinator.finalizedAssistantDocumentCountForTesting, 0)
        coordinator.removeAll()
        XCTAssertEqual(coordinator.finalizedAssistantDocumentCountForTesting, 0)
    }

    func testReusedNativeAssistantRendersNewIdentityEvenWhenRevisionMatches() {
        let cell = NativeAssistantCell(frame: NSRect(x: 0, y: 0, width: 560, height: 180))
        func present(id: String, text: String) {
            cell.setContent(
                AppKitAssistantContent(
                    text: text,
                    chatScale: 1,
                    isLive: false,
                    canRetry: false,
                    cwd: "/tmp"),
                id: AnyHashable(id),
                revision: 7,
                topPadding: 0,
                onRetry: {},
                onFork: {},
                onMeasuredHeight: { _, _, _ in })
            cell.layoutSubtreeIfNeeded()
        }

        present(id: "first", text: "First conversation response")
        XCTAssertEqual(
            descendants(of: cell).compactMap { $0 as? NSTextView }.first?.string,
            "First conversation response")

        present(id: "second", text: "Second conversation response")
        XCTAssertEqual(
            descendants(of: cell).compactMap { $0 as? NSTextView }.first?.string,
            "Second conversation response")
    }

    func testCodeCopyRevalidatesTheBlockUnderItsButtonAfterLayoutMoves() throws {
        _ = NSApplication.shared
        let oldPrompt = "Stop the old direction and report only stale text."
        let currentPrompt = "Spawn four agents in parallel and wait for their results."
        let cell = NativeAssistantCell(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
        let window = NSWindow(
            contentRect: cell.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = cell
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        cell.setContent(
            AppKitAssistantContent(
                text: """
                ```text
                \(oldPrompt)
                ```

                The next exercise replaces the earlier direction.

                ```text
                \(currentPrompt)
                ```
                """,
                chatScale: 1,
                isLive: false,
                canRetry: false,
                cwd: "/tmp"),
            id: AnyHashable("two-code-blocks"),
            revision: 1,
            topPadding: 0,
            onRetry: {},
            onFork: {},
            onMeasuredHeight: { _, _, _ in })
        cell.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(
            descendants(of: cell).compactMap { $0 as? NSTextView }.first)
        let button = try XCTUnwrap(
            descendants(of: cell).compactMap { $0 as? HoverActionButton }
                .first { $0.accessibilityLabel() == "Copy code" })
        let storage = try XCTUnwrap(textView.textStorage)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)

        func rect(for source: String) throws -> NSRect {
            var matchingRange: NSRange?
            storage.enumerateAttribute(
                .mechanicianCodeSource,
                in: NSRange(location: 0, length: storage.length)
            ) { value, range, stop in
                if value as? String == source {
                    matchingRange = range
                    stop.pointee = true
                }
            }
            let range = try XCTUnwrap(matchingRange)
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textView.textContainerInset.width
            rect.origin.y += textView.textContainerInset.height
            return rect
        }

        // Cache the first block exactly as a real hover does.
        let oldRect = try rect(for: oldPrompt)
        let oldWindowPoint = textView.convert(
            NSPoint(x: oldRect.midX, y: oldRect.midY),
            to: nil)
        let hover = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: oldWindowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0))
        cell.mouseMoved(with: hover)
        XCTAssertFalse(button.isHidden)

        // Reflow/scroll can move another block beneath the shared button without generating
        // mouseMoved. Reproduce that geometry directly: the click must resolve what is under the
        // button now, not write the first block's cached payload.
        let currentRect = try rect(for: currentPrompt)
        let buttonParent = try XCTUnwrap(button.superview)
        let currentCenter = textView.convert(
            NSPoint(x: currentRect.midX, y: currentRect.midY),
            to: buttonParent)
        button.frame.origin = NSPoint(
            x: currentCenter.x - button.frame.width / 2,
            y: currentCenter.y - button.frame.height / 2)

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("mechanician-code-copy-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("clipboard marker", forType: .string)
        cell.copyCodeUnderButton(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), currentPrompt)

        cell.frame.size.width = 420
        cell.needsLayout = true
        cell.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            button.isHidden,
            "a TextKit width change must invalidate the shared button's cached geometry")
    }

    func testReusedNativeAssistantDoesNotKeepAStaleActionHover() async throws {
        _ = NSApplication.shared
        let cell = NativeAssistantCell(frame: NSRect(x: 0, y: 0, width: 560, height: 180))
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 560, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = cell
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)

        func present(id: String, live: Bool) {
            cell.setContent(
                AppKitAssistantContent(
                    text: "A response",
                    chatScale: 1,
                    isLive: live,
                    canRetry: true,
                    canFork: true,
                    cwd: "/tmp"),
                id: AnyHashable(id),
                revision: live ? 2 : 1,
                topPadding: 0,
                onRetry: {},
                onFork: {},
                onMeasuredHeight: { _, _, _ in })
            cell.layoutSubtreeIfNeeded()
        }

        present(id: "first", live: false)
        let retry = try XCTUnwrap(descendants(of: cell).compactMap { $0 as? HoverActionButton }
            .first { $0.accessibilityLabel() == "Retry" })
        let point = retry.convert(
            NSPoint(x: retry.bounds.midX, y: retry.bounds.midY), to: nil)
        let enter = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0))
        retry.mouseEntered(with: enter)
        XCTAssertTrue(retry.isHovering)

        // Table reuse can hide/move a control without AppKit sending the old tracking area's exit.
        // Showing the same button on another response must start from its quiet, non-hovered state.
        present(id: "live", live: true)
        present(id: "second", live: false)
        await drainMainQueue(passes: 3)
        XCTAssertFalse(retry.isHovering)
        XCTAssertEqual(retry.alphaValue, 0.4, accuracy: 0.05)

        window.orderOut(nil)
        window.contentView = nil
    }

    func testOneStreamingRevisionDoesNotReverseOrRepeatedlyRetileViewport() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 180))
        scroll.documentView = table
        let window = NSWindow(
            contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        window.alphaValue = 0
        window.orderFrontRegardless()
        let pin = TranscriptPinController()
        coordinator.attach(table: table, scrollView: scroll, pin: pin)
        pin.scrollView = scroll

        let responseID = AnyHashable("stream-measurement-stability")
        var lines = 4
        func sync(revision: Int) {
            coordinator.sync(
                chunks: [.init(id: responseID, revision: revision, sourceIndex: 0)],
                content: { _ in AnyView(Self.transcriptText(lines: lines)) })
        }
        sync(revision: 1)
        _ = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        await drainMainQueue(passes: 8)
        pin.pinToBottom()

        scroll.contentView.postsBoundsChangedNotifications = true
        var origins: [CGFloat] = []
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { _ in origins.append(scroll.contentView.bounds.origin.y) }

        lines = 40
        sync(revision: 2)
        _ = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        await drainMainQueue(passes: 14)
        NotificationCenter.default.removeObserver(observer)

        let significant = origins.reduce(into: [CGFloat]()) { values, value in
            if values.last.map({ abs($0 - value) > 0.5 }) ?? true { values.append(value) }
        }
        for (previous, next) in zip(significant, significant.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                next + 0.5, previous,
                "A growing response must never shrink then grow its pinned viewport: \(significant)")
        }
        XCTAssertLessThanOrEqual(
            significant.count, 1,
            "One streamed revision should settle in one visible viewport move, not bounce: \(significant)")

        pin.scrollView = nil
        coordinator.removeAll()
        window.orderOut(nil)
        window.contentView = nil
    }

    private func presentAssistant(
        _ cell: NativeAssistantCell,
        id: AnyHashable,
        text: String,
        scale: CGFloat,
        live: Bool,
        revision: Int,
        cache: FinalizedAssistantDocumentCache,
        onHeight: @escaping (CGFloat) -> Void = { _ in }
    ) {
        cell.setContent(
            AppKitAssistantContent(
                text: text,
                chatScale: scale,
                isLive: live,
                canRetry: !live,
                cwd: "/tmp"),
            id: id,
            revision: revision,
            topPadding: 0,
            onRetry: {},
            onFork: {},
            onMeasuredHeight: { _, _, height in onHeight(height) },
            documentCache: cache)
        cell.layoutSubtreeIfNeeded()
    }

    private func nativeTextView(in cell: NativeAssistantCell) throws -> NSTextView {
        try XCTUnwrap(descendants(of: cell).compactMap { $0 as? NSTextView }.first)
    }

    /// FR-368. The guess for a row nobody has scrolled to has to move with how much that row
    /// says. Before this, every assistant answer — 47% of the rows in a long conversation, from
    /// five characters to forty thousand — shared one running mean, so each card entering the top
    /// of the viewport was drawn at that mean and then visibly resized when it was measured.
    func testAssistantHeightEstimateScalesWithContentLength() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
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

        let sentence = "This answer is long enough to wrap across several lines of the column. "
        func answer(_ lines: Int) -> String {
            Array(repeating: sentence, count: max(1, lines)).joined()
        }
        // Eight finalized answers of deliberately different lengths: enough samples, and enough
        // spread in the samples, for a fit to have something to stand on.
        func trained(_ index: Int) -> AppKitTranscriptChunk {
            AppKitTranscriptChunk(
                id: AnyHashable("estimate-train-\(index)"),
                revision: 1,
                sourceIndex: index,
                assistant: AppKitAssistantContent(
                    text: answer(1 + index * 6),
                    chatScale: 1,
                    isLive: false,
                    canRetry: false,
                    cwd: "/tmp"))
        }
        let training = (0..<8).map(trained)
        coordinator.sync(chunks: training, content: { _ in AnyView(EmptyView()) })
        table.reloadData()
        for row in 0..<8 {
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true)
            cell?.layoutSubtreeIfNeeded()
        }
        await drainMainQueue(passes: 10)

        // Two rows the table has never realized: one brief, one very long.
        let brief = AppKitTranscriptChunk(
            id: AnyHashable("estimate-unseen-brief"),
            revision: 1,
            sourceIndex: 8,
            assistant: AppKitAssistantContent(
                text: "Done.",
                chatScale: 1,
                isLive: false,
                canRetry: false,
                cwd: "/tmp"))
        let sprawling = AppKitTranscriptChunk(
            id: AnyHashable("estimate-unseen-sprawling"),
            revision: 1,
            sourceIndex: 9,
            assistant: AppKitAssistantContent(
                text: answer(120),
                chatScale: 1,
                isLive: false,
                canRetry: false,
                cwd: "/tmp"))
        coordinator.sync(
            chunks: training + [brief, sprawling],
            content: { _ in AnyView(EmptyView()) })

        let briefHeight = coordinator.tableView(table, heightOfRow: 8)
        let sprawlingHeight = coordinator.tableView(table, heightOfRow: 9)
        XCTAssertGreaterThan(
            sprawlingHeight,
            briefHeight * 2,
            "A far longer unmeasured answer must be guessed far taller, not at the same class mean")
        XCTAssertNotEqual(
            briefHeight,
            table.rowHeight,
            "A trained shape must never fall back to the table's single-line default")
        coordinator.removeAll()
    }

    /// The finer per-kind shape keys are only safe because an unsampled shape falls back to the
    /// pooled cross-shape estimate. If it fell back to `rowHeight` instead, splitting the keys
    /// would reintroduce the 44-point lurch the estimates exist to remove.
    func testUnsampledShapeFallsBackToPooledEstimateNotTheRowDefault() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
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

        let body = Array(repeating: "A measured answer that occupies several lines. ", count: 12)
            .joined()
        let measured = (0..<4).map { index in
            AppKitTranscriptChunk(
                id: AnyHashable("pooled-train-\(index)"),
                revision: 1,
                sourceIndex: index,
                assistant: AppKitAssistantContent(
                    text: body,
                    chatScale: 1,
                    isLive: false,
                    canRetry: false,
                    cwd: "/tmp"))
        }
        coordinator.sync(chunks: measured, content: { _ in AnyView(EmptyView()) })
        table.reloadData()
        for row in 0..<4 {
            table.view(atColumn: 0, row: row, makeIfNecessary: true)?.layoutSubtreeIfNeeded()
        }
        await drainMainQueue(passes: 10)

        // A permission card: a hosted shape with no samples of its own anywhere in this session.
        let unsampled = AppKitTranscriptChunk(
            id: AnyHashable("pooled-unsampled-permission"),
            revision: 1,
            sourceIndex: 4,
            hostedHeightEstimateClass: .kind("permission"),
            contentMetric: body.utf8.count)
        coordinator.sync(
            chunks: measured + [unsampled],
            content: { _ in AnyView(EmptyView()) })

        XCTAssertNotEqual(
            coordinator.tableView(table, heightOfRow: 4),
            table.rowHeight,
            "A shape with no samples must borrow the pooled estimate, never the 44-point default")
        coordinator.removeAll()
    }

    /// FR-368. The whole point of the prefetch band: a row must arrive at the viewport already
    /// measured, so there is no correction left to perform under the reader's eyes. This asserts
    /// the load-bearing assumption directly — that asking the table to prepare a rect larger than
    /// the viewport really does realize and measure rows outside it.
    func testRowsAboveTheViewportAreMeasuredBeforeTheReaderReachesThem() async {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
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

        let body = Array(repeating: "An answer that wraps over a few lines of the column. ",
                         count: 8).joined()
        let chunks = (0..<60).map { index in
            AppKitTranscriptChunk(
                id: AnyHashable("prefetch-row-\(index)"),
                revision: 1,
                sourceIndex: index,
                assistant: AppKitAssistantContent(
                    text: body,
                    chatScale: 1,
                    isLive: false,
                    canRetry: false,
                    cwd: "/tmp"))
        }
        coordinator.sync(chunks: chunks, content: { _ in AnyView(EmptyView()) })
        table.reloadData()
        await drainMainQueue(passes: 12)

        // Park the reader in the middle of the document, then let the prefetch settle.
        let middle = table.bounds.height / 2
        scroll.contentView.scroll(to: NSPoint(x: 0, y: middle))
        scroll.reflectScrolledClipView(scroll.contentView)
        await drainMainQueue(passes: 12)

        let visible = table.rows(in: table.visibleRect)
        XCTAssertNotEqual(visible.location, NSNotFound, "precondition: something is on screen")
        XCTAssertGreaterThan(visible.location, 0, "precondition: there are rows above the viewport")

        let justAbove = visible.location - 1
        XCTAssertNotNil(
            table.rowView(atRow: justAbove, makeIfNecessary: false),
            "the row the reader is about to scroll up into must already be realized, so its height "
                + "is exact before it is ever drawn")
        coordinator.removeAll()
    }

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

    private static func transcriptText(lines: Int) -> some View {
        Text((1...lines)
            .map { "Line \($0): streamed assistant output must remain fully visible and scrollable." }
            .joined(separator: "\n"))
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
    }

    private final class ExpansionFixture: ObservableObject {
        @Published var expanded = false
    }

    private final class FlippedTranscriptDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private struct ExpansionFixtureView: View {
        @ObservedObject var model: ExpansionFixture
        @Environment(\.invalidateTranscriptRowHeight)
        private var invalidateTranscriptRowHeight

        var body: some View {
            VStack {
                Text("Mail message")
                if model.expanded {
                    Rectangle().frame(height: 240)
                }
            }
            .onChange(of: model.expanded) { _, _ in
                DispatchQueue.main.async {
                    invalidateTranscriptRowHeight()
                }
            }
        }
    }

    private struct HostedDisclosureIdentityFixture: View {
        @State private var expanded: Bool

        init(initiallyExpanded: Bool) {
            _expanded = State(initialValue: initiallyExpanded)
        }

        var body: some View {
            VStack(spacing: 0) {
                Text("Summarized earlier messages")
                if expanded {
                    Rectangle().frame(height: 240)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func drainMainQueue(passes: Int = 4) async {
        for _ in 0..<passes {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
