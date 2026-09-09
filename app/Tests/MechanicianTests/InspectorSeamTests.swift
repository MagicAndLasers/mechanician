import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

/// The seam between the chat and the inspector, and what removing it costs elsewhere.
///
/// The workspace window is `fullSizeContentView` with a transparent titlebar on purpose, so a
/// column's frame reaches the top of the window and its background paints straight through the
/// toolbar. The chat has always painted `nBg` there and vanished into the window; the inspector
/// painted `nSurface`, which drew a band across the titlebar and a full-height vertical seam beside
/// the chat. It was invisible while that column was 360pt against the window's edge and obvious the
/// moment the wiki opened it wide.
///
/// Three fixes tried to keep the surface and hide it under the toolbar — an inset by
/// `safeAreaInsets.top`, an inset by a measured titlebar height, an overlay strip — and all three
/// were geometry, which is what kept being wrong. Matching the window needs no measurement, and that
/// is the whole reason it holds. These tests pin the match, and the consequences of making it.
final class InspectorSeamTests: XCTestCase {

    private func source(_ file: String) throws -> String {
        try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/MechanicianTests/InspectorSeamTests.swift",
                with: "Sources/Mechanician/\(file)"),
            encoding: .utf8)
    }

    /// The one fact the seam depends on: both columns paint the same token. Not "a similar colour" —
    /// the same one, because anything else is a difference that the transparent titlebar publishes
    /// across the full height of the window.
    func testBothColumnsPaintTheWindowBackground() throws {
        let inspector = try source("InspectorView.swift")
        let chat = try source("ContentView.swift")

        XCTAssertTrue(
            inspector.contains(".background(Color.nBg)"),
            "the inspector column must paint the window background")
        XCTAssertFalse(
            inspector.contains(".background(Color.nSurface)"),
            "a surface on this column is a band across the titlebar and a seam beside the chat")
        XCTAssertTrue(
            chat.contains(".background(Color.nBg)"),
            "and the chat column must still be painting the same one")
    }

    /// With both columns the same colour, nothing separates them. The colour difference was doing
    /// that work by accident; a hairline does it on purpose, which is what the AppKit split view
    /// already draws down the sidebar's edge.
    func testTheInspectorKeepsAnEdgeOnceTheColourStopsProvidingOne() throws {
        let inspector = try source("InspectorView.swift")
        let overlay = try XCTUnwrap(inspector.range(of: ".overlay(alignment: .leading)"))
        let body = inspector[overlay.lowerBound...].prefix(240)
        XCTAssertTrue(body.contains("separatorColor"), "the edge follows the native divider colour")
        XCTAssertTrue(body.contains("width: 1"), "one point, like the split view's own")
    }

    /// A state marker inside the inspector now sits on the window background rather than on the
    /// white surface the column used to be, and `nElevated` — the fill for a track on a card — is
    /// four 8-bit levels away from that background in Light Mode. The active tab was filled with it
    /// and would have had no marker at all.
    ///
    /// The shipped background is asserted as a literal because `windowBackgroundColor` resolves to
    /// pure white in a test process while a real window renders 0.940: testing only the resolved
    /// token would measure a background the app never draws.
    func testStateMarkersAreVisibleAgainstTheWindowBackgroundInBothAppearances() throws {
        let shippedLightPanel = NSColor(srgbRed: 0.940, green: 0.940, blue: 0.940, alpha: 1)

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var panels = [NSColor(Color.nBg).mechanicianResolved(in: appearance)]
            if appearanceName == .aqua { panels.append(shippedLightPanel) }

            for panel in panels {
                let activeTab = composite(
                    NSColor(Color.nAccent).mechanicianResolved(in: appearance),
                    alpha: 0.16,
                    over: panel)
                XCTAssertGreaterThanOrEqual(
                    channelDistance(activeTab, panel),
                    0.03,
                    "the active inspector tab must be visible in \(appearanceName)")

                let track = composite(
                    NSColor.nTrackOnBackground.mechanicianResolved(in: appearance),
                    alpha: 0.72,
                    over: panel)
                XCTAssertGreaterThanOrEqual(
                    channelDistance(track, panel),
                    0.03,
                    "a control track on a panel must be visible in \(appearanceName)")
            }
        }
    }

    /// And the fill that was there before is not, which is the measurement the change rests on. If
    /// `nElevated` is ever given a light value that clears this, the workarounds above become
    /// unnecessary and this test is the place that says so.
    func testTheFillThatWasThereBeforeIsInvisibleOnTheShippedLightPanel() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let shippedLightPanel = NSColor(srgbRed: 0.940, green: 0.940, blue: 0.940, alpha: 1)
        let elevated = composite(
            NSColor.nElevated.mechanicianResolved(in: appearance),
            alpha: 1,
            over: shippedLightPanel)

        XCTAssertLessThan(
            channelDistance(elevated, shippedLightPanel),
            0.03,
            "nElevated on the window background is the fill nobody can see")
    }

    /// The largest per-channel difference, not a WCAG ratio. A ratio is a luminance measure and
    /// reports a pale accent tint on a pale panel as barely a change, when a hue shift of that size
    /// is plainly visible — and it flatters two greys that differ by nothing a person can see.
    private func channelDistance(_ lhs: NSColor, _ rhs: NSColor) -> Double {
        let a = lhs.usingColorSpace(.sRGB)!
        let b = rhs.usingColorSpace(.sRGB)!
        return max(
            abs(a.redComponent - b.redComponent),
            max(
                abs(a.greenComponent - b.greenComponent),
                abs(a.blueComponent - b.blueComponent)))
    }

    private func composite(_ foreground: NSColor, alpha: CGFloat, over background: NSColor) -> NSColor {
        let fg = foreground.usingColorSpace(.sRGB)!
        let bg = background.usingColorSpace(.sRGB)!
        return NSColor(
            srgbRed: fg.redComponent * alpha + bg.redComponent * (1 - alpha),
            green: fg.greenComponent * alpha + bg.greenComponent * (1 - alpha),
            blue: fg.blueComponent * alpha + bg.blueComponent * (1 - alpha),
            alpha: 1)
    }
}
