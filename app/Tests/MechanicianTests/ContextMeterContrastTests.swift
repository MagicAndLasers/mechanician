import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

/// The context capsule is a track with a fill; if the two are close in luminance the reading is
/// lost — you can see the bar but not how full it is.
final class ContextMeterContrastTests: XCTestCase {
    /// The surface the meter actually sits on in the Trace/Usage header.
    private final class OpaqueBackdrop: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.nElevated.setFill()
            dirtyRect.fill()
        }
    }

    private func render(fraction: Double, appearance name: NSAppearance.Name) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        // Both the track and the fill are drawn with alpha, so they only mean anything composited
        // over the panel they sit on. Sampling the meter alone reads the unpremultiplied source and
        // reports a pure black or white track that appears nowhere on screen.
        let backdrop = OpaqueBackdrop(frame: NSRect(x: 0, y: 0, width: 120, height: 8))
        backdrop.appearance = appearance
        let meter = AppKitContextMeter(frame: backdrop.bounds)
        meter.appearance = appearance
        meter.fraction = fraction
        backdrop.addSubview(meter)
        let rep = try XCTUnwrap(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
        appearance.performAsCurrentDrawingAppearance {
            backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        }
        return rep
    }

    private func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        func linear(_ v: CGFloat) -> Double {
            let d = Double(v)
            return d <= 0.04045 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent)
            + 0.7152 * linear(c.greenComponent)
            + 0.0722 * linear(c.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let l1 = luminance(a), l2 = luminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// A quarter-full meter, sampled in the fill and in the empty remainder.
    func testFillIsClearlyDistinctFromTheTrackInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let rep = try render(fraction: 0.25, appearance: name)
            let fill = try XCTUnwrap(rep.colorAt(x: 12, y: 4))
            let track = try XCTUnwrap(rep.colorAt(x: 100, y: 4))
            let ratio = contrast(fill, track)
            print(String(
                format: "%@ fill=(%.3f,%.3f,%.3f) track=(%.3f,%.3f,%.3f) contrast=%.2f",
                name.rawValue,
                fill.redComponent, fill.greenComponent, fill.blueComponent,
                track.redComponent, track.greenComponent, track.blueComponent,
                ratio))
            XCTAssertGreaterThanOrEqual(
                ratio,
                3.0,
                "\(name.rawValue): the filled portion must read as filled against the empty track")
        }
    }
}

/// Renaming a conversation happens inline on the selected row. The editor's dark ink is only
/// readable because the row paints a field behind it: a plain `TextField` has no background of its
/// own, and the field editor supplies one only while it holds focus. The reported bug was an editor
/// that had lost focus — dark ink straight on the blue selection fill, which reads as a title
/// someone coloured wrong. So the ink is measured against what is REALLY behind it, by rendering the
/// row, and the row is rendered without a window, which is exactly the unfocused case.
@MainActor
final class ConversationRenameContrastTests: XCTestCase {
    /// The row's own selection capsule, painted by `SeparatorRowView` beneath the hosted SwiftUI.
    private final class SelectionBackdrop: NSView {
        override func draw(_ dirtyRect: NSRect) {
            ConversationRowPresentation.selectionFillColor.setFill()
            dirtyRect.fill()
        }
    }

    private func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        func linear(_ v: CGFloat) -> Double {
            let d = Double(v)
            return d <= 0.04045 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent)
            + 0.7152 * linear(c.greenComponent)
            + 0.0722 * linear(c.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let l1 = luminance(a), l2 = luminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private func summary() -> ConversationSummary {
        ConversationSummary(
            Conversation(
                title: "deepseek coding harness",
                cwd: "/private/tmp/rename",
                sdkSessionId: nil,
                messages: [TranscriptEntry(kind: .user, text: "that guide entry is incorrect")],
                updatedAt: Date(),
                projectID: nil))
    }

    /// A patch on the title's line, inside the editor's field when one is open.
    ///
    /// SAMPLED IN POINTS AT AN EXPLICIT SCALE, and the first version was neither. `colorAt` indexes
    /// PIXELS, while the band was chosen by reasoning about the row's point geometry, so it only
    /// landed on the title's line where the bitmap happened to be 2x. A runner with no Retina
    /// display renders 1x, where the same numbers reached far enough down the row to sample the
    /// selection capsule below the field. The test passed on every developer machine and failed on
    /// CI, which is the worst place to learn it. Rendering at both scales here means a laptop sees
    /// what the runner sees.
    private func surfaceSamples(
        editing: Bool,
        appearance name: NSAppearance.Name,
        scale: Int
    ) throws -> [NSColor] {
        _ = NSApplication.shared
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        let backdrop = SelectionBackdrop(frame: NSRect(x: 0, y: 0, width: 260, height: 62))
        backdrop.appearance = appearance
        let row = ConversationRowView(
            convo: summary(),
            isSelected: true,
            selectionIsEmphasized: true,
            now: Date(),
            active: ActiveWorkspace(productAccessRequest: { true }, whenProductReady: { $0() }),
            onToggleFavorite: {},
            isEditing: editing,
            editText: .constant("deepseek coding harness"))
        let host = NSHostingView(rootView: row)
        host.appearance = appearance
        host.frame = backdrop.bounds
        backdrop.addSubview(host)
        backdrop.layoutSubtreeIfNeeded()
        let bounds = backdrop.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width) * scale,
            pixelsHigh: Int(bounds.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0))
        rep.size = bounds.size
        appearance.performAsCurrentDrawingAppearance {
            backdrop.cacheDisplay(in: bounds, to: rep)
        }
        // Points, converted through the scale actually rendered. This patch is on the title's line
        // and within the field's width, measured to read the same way at 1x and at 2x.
        return (16...28).flatMap { xPoint in
            (3...8).compactMap { yPoint in
                rep.colorAt(x: xPoint * scale, y: yPoint * scale)
            }
        }
    }

    func testTheRenameEditorPaintsItsOwnFieldOnTheSelectedRow() throws {
        // 1x is what a CI runner with no Retina display draws, 2x is what a developer machine
        // draws. The row has to hold up in both, and only one of them is ever in front of a person.
        for scale in [1, 2] {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let where_ = "\(name.rawValue) at \(scale)x"
                let appearance = try XCTUnwrap(NSAppearance(named: name))
                let fill = ConversationRowPresentation.renameFieldFill
                    .mechanicianResolved(in: appearance)
                let selection = ConversationRowPresentation.selectionFillColor
                    .mechanicianResolved(in: appearance)

                let editing = try surfaceSamples(editing: true, appearance: name, scale: scale)
                XCTAssertTrue(
                    editing.contains { contrast($0, fill) < 1.2 },
                    "\(where_): an open rename editor must paint its own field, "
                        + "not leave its ink on the row's selection fill")
                XCTAssertFalse(
                    editing.contains { contrast($0, selection) < 1.05 },
                    "\(where_): the selection fill must not show through the editor's field")

                // The same patch on a row that is NOT being renamed is the plain selection capsule,
                // so the field is proven to belong to the editor rather than to every selected row.
                let resting = try surfaceSamples(editing: false, appearance: name, scale: scale)
                XCTAssertTrue(
                    resting.contains { contrast($0, selection) < 1.05 },
                    "\(where_): a row that is not being renamed keeps its selection fill")
            }
        }
    }

    func testRenameInkReadsOnItsFieldAndWouldNotOnTheRow() throws {
        _ = NSApplication.shared
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let ink = ConversationRowPresentation.renameFieldInk.mechanicianResolved(in: appearance)
            let field = ConversationRowPresentation.renameFieldFill.mechanicianResolved(in: appearance)
            XCTAssertGreaterThanOrEqual(
                contrast(ink, field),
                4.5,
                "\(name.rawValue): rename ink must read on the field the editor paints")

            // Why the field is not optional, and why both of the obvious "just pick one colour"
            // fixes fail. The asymmetry is the whole story: in Light mode label ink is unreadable
            // bare on the blue row (the reported bug) and white ink is unreadable on the field (the
            // bug before it). Dark mode shows neither — label ink there is near-white — which is
            // exactly why this kept shipping.
            let selection = ConversationRowPresentation.selectionFillColor
                .mechanicianResolved(in: appearance)
            guard name == .aqua else { continue }
            XCTAssertLessThan(
                contrast(ink, selection),
                4.5,
                "Light: this is the reported bug — editor ink bare on the selected row")
            XCTAssertLessThan(
                contrast(NSColor.white.mechanicianResolved(in: appearance), field),
                1.5,
                "Light: and the row's white ink is invisible on the field")
        }
    }
}

/// The inspector's toolbar region sizes itself by constraint, which is what replaced the deprecated
/// `NSToolbarItem.minSize`/`maxSize`. Those properties repeated the width and height the view
/// already pins, so this asserts the surviving mechanism actually produces that geometry.
@MainActor
final class InspectorToolbarRegionSizingTests: XCTestCase {
    func testTheRegionReportsTheRequestedWidthAndTheDeckHeight() {
        _ = NSApplication.shared
        let region = InspectorToolbarRegionView(target: NSObject(), action: #selector(NSObject.hash))

        XCTAssertTrue(region.setWidth(
            320, leadingInset: InspectorToolbarRegionView.openLeadingInset))
        XCTAssertFalse(region.setWidth(
            320, leadingInset: InspectorToolbarRegionView.openLeadingInset),
            "identical live-resize publications must not invalidate the native toolbar again")
        region.layoutSubtreeIfNeeded()
        XCTAssertEqual(region.fittingSize.width, 320, accuracy: 0.5)
        XCTAssertEqual(region.fittingSize.height, ToolbarUtilityDeck.outerHeight, accuracy: 0.5)

        // Closed, the region collapses to the utility-deck segment rather than keeping a stale width.
        XCTAssertTrue(region.setWidth(ToolbarUtilityDeck.segmentSize.width, leadingInset: 0))
        region.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            region.fittingSize.width,
            ToolbarUtilityDeck.segmentSize.width,
            accuracy: 0.5)
    }
}
