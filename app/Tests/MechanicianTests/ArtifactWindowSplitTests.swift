import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

@MainActor
private final class ArtifactWindowSplitTestState: ObservableObject {
    @Published var selected = false
    @Published var previewWidth = 620.0
}

private struct ArtifactWindowSplitHarness: View {
    @ObservedObject var state: ArtifactWindowSplitTestState

    var body: some View {
        ArtifactWindowSplit(storedPreviewWidth: $state.previewWidth) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } preview: {
            Group {
                if state.selected {
                    Text(String(repeating: "selected-wide-content", count: 200))
                        .fixedSize()
                } else {
                    Text("Select an artifact")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

final class ArtifactWindowSplitTests: XCTestCase {
    func testRoomyWindowStartsWithAWidePreviewAndUsableBrowser() {
        let layout = ArtifactWindowSplitSizing.resolve(
            availableWidth: 1_280,
            storedPreviewWidth: ArtifactWindowSplitSizing.defaultPreviewWidth)

        XCTAssertEqual(layout.previewWidth, 700)
        XCTAssertEqual(layout.browserWidth, 579)
    }

    func testAUserChosenPreviewWidthIsTheExactLayoutAuthority() {
        let layout = ArtifactWindowSplitSizing.resolve(
            availableWidth: 1_280,
            storedPreviewWidth: 620)

        XCTAssertEqual(layout.previewWidth, 620)
        XCTAssertEqual(layout.browserWidth, 659)
    }

    func testNarrowWindowClampsOnlyTheDisplayedProjection() {
        let narrow = ArtifactWindowSplitSizing.resolve(
            availableWidth: 840,
            storedPreviewWidth: 700)
        XCTAssertEqual(narrow.previewWidth, 519)
        XCTAssertEqual(narrow.browserWidth, ArtifactWindowSplitSizing.minimumBrowserWidth)

        let roomyAgain = ArtifactWindowSplitSizing.resolve(
            availableWidth: 1_280,
            storedPreviewWidth: 700)
        XCTAssertEqual(roomyAgain.previewWidth, 700)
        XCTAssertEqual(roomyAgain.browserWidth, 579)
    }

    func testInvalidStoredWidthsReturnToTheWideDefault() {
        for invalid in [
            0.0,
            ArtifactWindowSplitSizing.minimumPreviewWidth - 1,
            ArtifactWindowSplitSizing.maximumPreviewWidth + 1,
            Double.nan,
            Double.infinity,
        ] {
            XCTAssertEqual(
                ArtifactWindowSplitSizing.preferredWidth(invalid),
                ArtifactWindowSplitSizing.defaultPreviewWidth)
        }
    }

    @MainActor
    func testReplacingPreviewContentCannotMoveTheMountedDivider() throws {
        _ = NSApplication.shared
        let state = ArtifactWindowSplitTestState()
        let frame = NSRect(x: 0, y: 0, width: 1_280, height: 760)
        let host = NSHostingView(rootView: ArtifactWindowSplitHarness(state: state))
        host.frame = frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = host
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        settle(host)
        let before = try seamX(in: host)

        state.selected = true
        settle(host)
        let after = try seamX(in: host)

        XCTAssertEqual(after, before, accuracy: 0.5)
        XCTAssertEqual(state.previewWidth, 620)
        XCTAssertEqual(
            host.bounds.maxX - (after + ArtifactWindowSplitSizing.seamWidth / 2),
            620,
            accuracy: 0.5)
    }

    @MainActor
    private func seamX(in host: NSView) throws -> CGFloat {
        let handle = try XCTUnwrap(descendant(CursorArea.CursorNSView.self, in: host))
        return handle.convert(
            NSPoint(x: handle.bounds.midX, y: handle.bounds.midY),
            to: host).x
    }

    @MainActor
    private func descendant<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let root = root as? T { return root }
        for child in root.subviews {
            if let found = descendant(type, in: child) { return found }
        }
        return nil
    }

    @MainActor
    private func settle(_ host: NSView) {
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
    }
}
