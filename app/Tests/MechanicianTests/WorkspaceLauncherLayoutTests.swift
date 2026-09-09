import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

/// The Workspaces scene is intrinsically measured before AppKit restores its native window frame.
/// This test keeps that sizing path honest: a tall gallery must make a scroll document, not a tall
/// root view whose scroll viewport is then clipped by the shorter window.
@MainActor
final class WorkspaceLauncherLayoutTests: XCTestCase {
    func testShortNativeWindowKeepsGalleryInsideAMovingScrollDocument() throws {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-launcher-layout-\(UUID().uuidString)", isDirectory: true)
        let projects = ProjectStore(appSupportBaseOverride: support)
        let conversations = ConversationStore(
            appSupportBaseOverride: support,
            watchesDirectory: false)
        for index in 0..<14 {
            projects.upsert(Project(
                name: "Seeded Workspace \(index + 1)",
                goal: "Enough real cards to make the launcher document taller than its window.",
                updatedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(index))))
        }
        projects.flushSaves()

        let nativeSize = NSSize(width: 820, height: 460)
        let host = NSHostingView(rootView: ProjectsLauncherView(
            onFinish: {},
            store: projects,
            conversationStore: conversations))
        host.frame = NSRect(origin: .zero, size: nativeSize)
        host.layoutSubtreeIfNeeded()

        // Match SwiftUI's Window-scene negotiation: the root first publishes its intrinsic ideal,
        // then AppKit restores a shorter frame around it. GeometryReader must keep that ideal bound
        // to the launcher's declared minimum instead of allowing ScrollView's document to become it.
        let intrinsicHeight = host.fittingSize.height
        host.frame.size = NSSize(width: nativeSize.width, height: intrinsicHeight)

        let clippingRoot = NSView(frame: NSRect(origin: .zero, size: nativeSize))
        clippingRoot.wantsLayer = true
        clippingRoot.layer?.masksToBounds = true
        clippingRoot.addSubview(host)
        let window = NSWindow(
            contentRect: clippingRoot.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = clippingRoot
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            projects.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        settle(window: window, host: host)
        let scrollView = try XCTUnwrap(
            descendants(of: host).compactMap { $0 as? NSScrollView }.max {
                documentHeight(of: $0) < documentHeight(of: $1)
            },
            "The mounted SwiftUI launcher must vend its native NSScrollView")
        let clipView = scrollView.contentView
        let viewportHeight = clipView.bounds.height
        let contentHeight = documentHeight(of: scrollView)

        XCTAssertLessThanOrEqual(
            intrinsicHeight,
            nativeSize.height,
            "The launcher's intrinsic root must not expand to its scroll document before frame restoration")
        XCTAssertLessThanOrEqual(
            viewportHeight,
            nativeSize.height,
            "The scroll viewport must be bounded by the restored native window, not the tall document")
        XCTAssertGreaterThan(
            contentHeight,
            viewportHeight + 200,
            "The seeded Workspace cards must remain overflow content inside the scroll view")

        let offsetBefore = clipView.bounds.origin.y
        let maximumOffset = max(1, contentHeight - viewportHeight)
        let requestedOffset = offsetBefore > maximumOffset / 2 ? 0 : maximumOffset
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: requestedOffset))
        scrollView.reflectScrolledClipView(clipView)
        settle(window: window, host: host)

        let offsetAfter = clipView.bounds.origin.y
        XCTAssertGreaterThan(
            abs(offsetAfter - offsetBefore),
            100,
            "A programmatic native scroll must move the launcher's real clip-view offset")
    }

    private func documentHeight(of scrollView: NSScrollView) -> CGFloat {
        scrollView.documentView?.frame.height ?? 0
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private func settle(window: NSWindow, host: NSView, passes: Int = 6) {
        for _ in 0..<passes {
            window.contentView?.needsLayout = true
            host.needsLayout = true
            window.contentView?.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
