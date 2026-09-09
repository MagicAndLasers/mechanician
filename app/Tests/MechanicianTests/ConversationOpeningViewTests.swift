import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

@MainActor
final class ConversationOpeningViewTests: XCTestCase {
    func testOpeningStateYieldsToStoreReadinessOrExplicitNavigation() {
        XCTAssertTrue(ConversationOpeningPresentation.shouldShow(
            storeIsReady: false,
            currentID: nil,
            openingConversationID: nil,
            initialViewResolutionPending: true))
        XCTAssertFalse(ConversationOpeningPresentation.shouldShow(
            storeIsReady: true,
            currentID: nil,
            openingConversationID: nil,
            initialViewResolutionPending: false))
        XCTAssertFalse(ConversationOpeningPresentation.shouldShow(
            storeIsReady: false,
            currentID: UUID(),
            openingConversationID: nil,
            initialViewResolutionPending: true),
            "A user-created or selected Conversation must never be covered by launch loading UI.")
    }

    func testInventoryReadinessDoesNotHideSelectedConversationHydration() {
        let selected = UUID()
        XCTAssertTrue(ConversationOpeningPresentation.shouldShow(
            storeIsReady: true,
            currentID: nil,
            openingConversationID: selected,
            initialViewResolutionPending: true))
        XCTAssertFalse(ConversationOpeningPresentation.shouldShow(
            storeIsReady: true,
            currentID: selected,
            openingConversationID: nil,
            initialViewResolutionPending: false))
    }

    func testReadyInventoryWithoutResolvedInitialViewKeepsOpeningPresentation() {
        XCTAssertTrue(ConversationOpeningPresentation.shouldShow(
            storeIsReady: true,
            currentID: nil,
            openingConversationID: nil,
            initialViewResolutionPending: true),
            "Workspace validation must not expose a blank composer between inventory and hydration.")
    }

    func testHeroSpinnerGrowsItsDotsWithoutEscapingItsFrame() {
        let diameter = ConversationOpeningPresentation.spinnerDiameter
        let compact = OrbitingDotsGeometry.fitted(to: diameter)
        let hero = OrbitingDotsGeometry.fitted(
            to: diameter,
            scalesDotsWithDiameter: true)

        XCTAssertLessThanOrEqual(hero.maximumPaintedRadius, diameter / 2)
        XCTAssertGreaterThan(
            hero.coreDiameter,
            compact.coreDiameter * 2,
            "The loading mark must enlarge its colored dots, not only spread compact dots apart.")
    }

    func testOpeningViewUsesOnlyTheThreeDotCompositorSpinner() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ConversationOpeningView())
        let frame = NSRect(x: 0, y: 0, width: 720, height: 520)
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

        host.layoutSubtreeIfNeeded()
        let allViews = descendants(of: host)
        let spinners = allViews.compactMap { $0 as? OrbitingDotsLayerView }
        let spinner = try XCTUnwrap(spinners.first)
        spinner.layoutSubtreeIfNeeded()

        XCTAssertFalse(allViews.contains { $0 is NSProgressIndicator })
        XCTAssertEqual(spinners.count, 1, "The opening state should contain only one activity mark.")
        XCTAssertEqual(
            spinner.bounds.width,
            ConversationOpeningPresentation.spinnerDiameter,
            accuracy: 1)
        XCTAssertTrue(spinner.coreDiametersForTesting.allSatisfy { $0 > 8 })
        XCTAssertEqual(spinner.coreColorsForTesting.count, 3)

        if let directory = ProcessInfo.processInfo.environment["MECHANICIAN_OPENING_RENDER_DUMP"] {
            for (appearanceName, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                host.appearance = appearance
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                appearance.performAsCurrentDrawingAppearance {
                    host.cacheDisplay(in: host.bounds, to: rep)
                }
                try rep.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("conversation-opening-\(suffix).png"))
            }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
