import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

final class InspectorTabBarMetricsTests: XCTestCase {
    func testTabChromeCapsWideProposalsWithoutAddingANarrowFloor() {
        XCTAssertEqual(InspectorTabBarMetrics.boundedTabWidth(proposed: -20), 0)
        XCTAssertEqual(InspectorTabBarMetrics.boundedTabWidth(proposed: 31), 31)
        XCTAssertEqual(
            InspectorTabBarMetrics.boundedTabWidth(proposed: 900),
            InspectorTabBarMetrics.maximumTabWidth)
        XCTAssertEqual(
            InspectorTabBarMetrics.boundedTabWidth(proposed: .infinity),
            InspectorTabBarMetrics.maximumTabWidth)
        XCTAssertLessThan(
            InspectorTabBarMetrics.idealTabWidth,
            InspectorTabBarMetrics.maximumTabWidth)
    }

    func testEveryTabHasAStableAutomationIdentifier() {
        XCTAssertEqual(
            InspectorTabBarMetrics.accessibilityIdentifier(for: .help),
            "inspector.tab.help")
        XCTAssertEqual(
            Set(InspectorTab.allCases.map(InspectorTabBarMetrics.accessibilityIdentifier)),
            Set(InspectorTab.allCases.map { "inspector.tab.\($0.rawValue)" }))
    }
}

/// Exercises the actual SwiftUI button and its AppKit semantic target. The window stays fixed while
/// only the hosted inspector region changes width, matching a divider drag rather than a window
/// resize. This is the seam the value-only responsive-layout tests cannot see.
@MainActor
final class InspectorTabBarHostingTests: XCTestCase {
    func testSingleHelpTabAndGuideTargetStayBoundedAcrossInspectorResize() throws {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-tab-layout-\(UUID().uuidString)", isDirectory: true)
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        bridge.window = window
        defer {
            bridge.window = nil
            bridge.shutdown()
            window.contentView = nil
            try? FileManager.default.removeItem(at: support)
        }

        let owner = try XCTUnwrap(GuidedHelpPresentationOwner(bridge: bridge, window: window))
        let registry = GuidedHelpTargetRegistry(owner: owner)
        let root = HStack(spacing: 0) {
            InspectorTabButtonChrome(
                tab: .help,
                active: true,
                badgeText: nil,
                badgeIsLive: false,
                highlighted: false,
                guideRegistry: registry,
                action: {})
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        let host = NSHostingView(rootView: root)
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(host)

        for inspectorWidth in [900.0, 180.0, 720.0] {
            host.frame = NSRect(
                x: content.bounds.maxX - inspectorWidth,
                y: 0,
                width: inspectorWidth,
                height: content.bounds.height)
            settle(content: content, host: host)

            guard case .available(let frame) = registry.resolve(.helpInspectorTab) else {
                return XCTFail("The live Help tab must remain registered after width \(inspectorWidth)")
            }
            XCTAssertLessThanOrEqual(
                frame.width,
                InspectorTabBarMetrics.maximumTabWidth + 0.5,
                "surplus inspector width belongs to the trailing spacer, not the Help tab")
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertTrue(
                host.frame.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                "the exact Guided Help target must stay inside its resized inspector host")
        }
    }

    private func settle(content: NSView, host: NSView) {
        content.needsLayout = true
        host.needsLayout = true
        content.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        content.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
    }
}
