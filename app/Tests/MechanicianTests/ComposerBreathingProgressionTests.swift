import AppKit
import QuartzCore
import XCTest
@testable import Mechanician

final class ComposerBreathingProgressionTests: XCTestCase {

    // MARK: rhythm

    /// The jank in earlier revisions came from a phase machine whose stage boundaries were visible.
    /// The replacement has no stages at all, so the only thing worth pinning is that the three
    /// motions cannot resynchronise into a perceptible loop.
    func testTheThreeMotionsNeverRealignIntoAShortLoop() {
        let periods = ComposerBreathingRhythm.periods
        XCTAssertEqual(periods.count, 3)

        for (index, period) in periods.enumerated() {
            XCTAssertGreaterThan(period, 0)
            for other in periods[(index + 1)...] {
                let ratio = max(period, other) / min(period, other)
                let nearestWhole = (ratio).rounded()
                XCTAssertGreaterThan(
                    abs(ratio - nearestWhole), 0.08,
                    "\(period)s and \(other)s are too close to a whole-number ratio")
            }
        }
    }

    func testBreathIsSlowEnoughToReadAsCalm() {
        // Between roughly eight and fourteen breaths a minute.
        XCTAssertGreaterThan(ComposerBreathingRhythm.breathPeriod, 4.2)
        XCTAssertLessThan(ComposerBreathingRhythm.breathPeriod, 7.5)
        // The drifts are slower still, so nothing races the breath.
        XCTAssertGreaterThan(
            ComposerBreathingRhythm.arcDriftPeriod,
            ComposerBreathingRhythm.breathPeriod * 2)
        XCTAssertGreaterThan(
            ComposerBreathingRhythm.paletteDriftPeriod,
            ComposerBreathingRhythm.arcDriftPeriod)
    }

    func testBreathIsSubtleAndNeverFullyExtinguishesTheOutline() {
        XCTAssertGreaterThan(ComposerBreathingRhythm.restingLineOpacity, 0.25)
        XCTAssertLessThan(ComposerBreathingRhythm.peakLineOpacity, 0.85)
        XCTAssertGreaterThan(ComposerBreathingRhythm.restingGlowOpacity, 0)
        // The bloom carries most of the visible swell; the keyline only firms up slightly.
        let glowSwell = ComposerBreathingRhythm.peakGlowOpacity
            / ComposerBreathingRhythm.restingGlowOpacity
        let lineSwell = ComposerBreathingRhythm.peakLineOpacity
            / ComposerBreathingRhythm.restingLineOpacity
        XCTAssertGreaterThan(glowSwell, lineSwell)
        XCTAssertGreaterThan(
            ComposerBreathingRhythm.peakGlowWidth,
            ComposerBreathingRhythm.restingGlowWidth)
    }

    // MARK: composition

    /// No endpoint markers. Earlier revisions added a sprite at each seam, which read as two orbs
    /// appearing in the middle of the bar.
    @MainActor
    func testOutlineIsTwoBandsWithNoEndpointMarkers() throws {
        let view = ComposerActivityOutlineLayerView(
            frame: NSRect(x: 0, y: 0, width: 880, height: 104))
        view.layoutSubtreeIfNeeded()

        let root = try XCTUnwrap(view.layer?.sublayers)
        XCTAssertEqual(root.count, 2, "Only a glow band and a line band belong at the root.")
        for band in root {
            XCTAssertNil(band.contents, "A band draws through masks, never a bitmap marker.")
            XCTAssertTrue(band.mask is CAShapeLayer, "Perimeter geometry is a still mask.")
            XCTAssertEqual(band.sublayers?.count, 1)
        }
    }

    /// Colour and light must live on separate layers, otherwise they are forced to drift together
    /// and the composition visibly repeats.
    @MainActor
    func testArcWindowAndPaletteAreIndependentlyDriftableLayers() throws {
        let view = ComposerActivityOutlineLayerView(
            frame: NSRect(x: 0, y: 0, width: 880, height: 104))
        view.layoutSubtreeIfNeeded()

        let root = try XCTUnwrap(view.layer?.sublayers)
        for band in root {
            let arc = try XCTUnwrap(band.sublayers?.first)
            let fade = try XCTUnwrap(arc.mask as? CAGradientLayer)
            let palette = try XCTUnwrap(arc.sublayers?.first as? CAGradientLayer)
            XCTAssertFalse(fade === palette)
            XCTAssertEqual(fade.type, .conic)
            XCTAssertEqual(palette.type, .conic)
            // Both spin, so both must be square and centred or a turn would expose a corner.
            for rotating in [fade, palette] {
                XCTAssertEqual(rotating.bounds.width, rotating.bounds.height, accuracy: 0.000_001)
                XCTAssertGreaterThanOrEqual(rotating.bounds.width, view.bounds.width)
                XCTAssertEqual(rotating.position.x, view.bounds.midX, accuracy: 0.000_001)
                XCTAssertEqual(rotating.position.y, view.bounds.midY, accuracy: 0.000_001)
            }
        }
    }

    /// Two long lobes with long ramps — never a hard tip that would need somewhere to land — and a
    /// keyline that never goes out, so the frame cannot break into floating bars.
    func testArcWindowIsTwoLongSoftlyFeatheredLobesOverAPermanentKeyline() {
        let stops = ComposerActivityOutlineLayerView.arcAlphaStops
        let floor = ComposerActivityOutlineLayerView.arcFloorAlpha
        XCTAssertEqual(stops.first?.location, 0)
        XCTAssertEqual(stops.last?.location, 1)
        XCTAssertEqual(stops.first?.alpha, floor)
        XCTAssertEqual(stops.last?.alpha, floor)

        for (previous, next) in zip(stops, stops.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.location, next.location)
        }
        for stop in stops {
            XCTAssertGreaterThanOrEqual(
                stop.alpha, floor,
                "The outline must stay continuous all the way round at every drift angle.")
            XCTAssertLessThanOrEqual(stop.alpha, 1)
        }
        XCTAssertGreaterThan(floor, 0.15)
        XCTAssertLessThan(floor, 0.45, "Too high a floor and the travelling light stops reading.")

        let lit = stops.filter { $0.alpha == 1 }
        XCTAssertEqual(lit.count, 4, "Two lobes, each with a start and an end at full brightness.")

        // Every transition between dim and lit is a long ramp, not a step.
        for (previous, next) in zip(stops, stops.dropFirst()) where previous.alpha != next.alpha {
            XCTAssertGreaterThan(
                next.location - previous.location, 0.08,
                "A short ramp would read as a hard-ended beam tip.")
        }

        // The lobes cover most of the perimeter, so the light is long and diffuse.
        let coverage = zip(stops, stops.dropFirst()).reduce(0.0) { total, pair in
            total + (pair.1.location - pair.0.location) * (pair.0.alpha + pair.1.alpha) / 2
        }
        XCTAssertGreaterThan(coverage, 0.55)
        XCTAssertLessThan(coverage, 0.9)
    }

    /// A short arc over a single palette loop samples ~one hue, which is what made split beams go
    /// monochrome. Two six-color loops preserve the former twelve-band density without becoming an
    /// eighteen-stripe rainbow.
    @MainActor
    func testEachArcSpansTheWholePalette() throws {
        let view = ComposerActivityOutlineLayerView(
            frame: NSRect(x: 0, y: 0, width: 880, height: 104))
        view.layoutSubtreeIfNeeded()

        let root = try XCTUnwrap(view.layer?.sublayers)
        let arc = try XCTUnwrap(root.first?.sublayers?.first)
        let palette = try XCTUnwrap(arc.sublayers?.first as? CAGradientLayer)
        let stops = try XCTUnwrap(palette.colors?.count)

        XCTAssertEqual(MagicLaserSpectrum.colors.count, 6)
        XCTAssertEqual(
            stops,
            MagicLaserSpectrum.colors.count
                * ComposerActivityOutlineLayerView.paletteRepetitions + 1)
        XCTAssertEqual(ComposerActivityOutlineLayerView.paletteRepetitions, 2)

        // One complete feathered lobe covers most of one ribbon, so it reads as chromatic without
        // repeating the same hue sequence inside a single highlight.
        let lobe = 0.46 - 0.04
        let ribbonCoverage = lobe * Double(ComposerActivityOutlineLayerView.paletteRepetitions)
        XCTAssertGreaterThan(
            ribbonCoverage, 0.75)
        XCTAssertLessThan(ribbonCoverage, 1)
    }

    @MainActor
    func testOutlineLayerCarriesTheSixLaserHuesInBrandOrder() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let view = ComposerActivityOutlineLayerView(
            frame: NSRect(x: 0, y: 0, width: 880, height: 104))
        view.appearance = appearance
        view.layoutSubtreeIfNeeded()

        let root = try XCTUnwrap(view.layer?.sublayers)
        let arc = try XCTUnwrap(root.first?.sublayers?.first)
        let palette = try XCTUnwrap(arc.sublayers?.first as? CAGradientLayer)
        let rendered = try XCTUnwrap(palette.colors as? [CGColor]).prefix(6).map {
            try XCTUnwrap(NSColor(cgColor: $0)?.usingColorSpace(.sRGB))
        }
        let expected = MagicLaserSpectrum.resolvedColors(in: appearance)

        XCTAssertEqual(rendered.count, expected.count)
        for (actual, expected) in zip(rendered, expected) {
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.01)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.01)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.01)
        }
    }

    // MARK: rendered pixels

    /// Everything above describes intent. These two assert what is actually drawn — the check that
    /// was missing while several revisions were reported as verified on the strength of phase
    /// numbers alone.
    @MainActor
    private func renderOutline(
        breath: Double,
        arcDrift: Double,
        appearanceName: NSAppearance.Name = .darkAqua
    ) throws -> NSBitmapImageRep {
        let size = CGSize(width: 420, height: 78)
        let view = ComposerActivityOutlineLayerView(
            frame: CGRect(origin: .zero, size: size))
        view.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
        view.layoutSubtreeIfNeeded()
        view.applyDebugPresentation(breath: breath, arcDrift: arcDrift, paletteDrift: 0)

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.layer?.render(in: context.cgContext)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private func totalLight(in bitmap: NSBitmapImageRep) -> Double {
        var total = 0.0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                total += Double(color.alphaComponent) * Double(color.brightnessComponent)
            }
        }
        return total
    }

    private func differenceFromWhite(in bitmap: NSBitmapImageRep) -> Double {
        var total = 0.0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let alpha = Double(color.alphaComponent)
                let red = Double(color.redComponent) * alpha + (1 - alpha)
                let green = Double(color.greenComponent) * alpha + (1 - alpha)
                let blue = Double(color.blueComponent) * alpha + (1 - alpha)
                total += (1 - red) + (1 - green) + (1 - blue)
            }
        }
        return total
    }

    @MainActor
    func testBreathIsVisibleInRenderedPixels() throws {
        let rest = try renderOutline(breath: 0, arcDrift: 0)
        let peak = try renderOutline(breath: 0.5, arcDrift: 0)

        let restLight = totalLight(in: rest)
        let peakLight = totalLight(in: peak)

        XCTAssertGreaterThan(restLight, 0, "The outline must be visible even at rest.")
        XCTAssertGreaterThan(
            peakLight, restLight * 1.3,
            "The breath has to be perceptible, not just present in the numbers.")
    }

    @MainActor
    func testLightModeShimmerHasAVisibleRestingKeylineAndBreath() throws {
        let light = ComposerBreathingRhythm.lightPresentation
        let dark = ComposerBreathingRhythm.darkPresentation
        XCTAssertGreaterThan(light.restingLineOpacity, dark.restingLineOpacity + 0.20)
        XCTAssertGreaterThan(light.peakLineOpacity, 0.90)
        XCTAssertGreaterThan(light.restingGlowOpacity, dark.restingGlowOpacity * 2)
        XCTAssertGreaterThan(light.lineWidth, dark.lineWidth)

        let rest = try renderOutline(
            breath: 0,
            arcDrift: 0.17,
            appearanceName: .aqua)
        let peak = try renderOutline(
            breath: 0.5,
            arcDrift: 0.17,
            appearanceName: .aqua)
        let restingDifference = differenceFromWhite(in: rest)
        let peakDifference = differenceFromWhite(in: peak)

        XCTAssertGreaterThan(
            restingDifference,
            12,
            "the Light keyline must be visible against the white composer even at rest")
        XCTAssertGreaterThan(
            peakDifference,
            restingDifference * 1.18,
            "the Light shimmer must visibly breathe, not merely animate layer values")
    }

    /// Guards the failure mode where the dim part of the travelling window landed on one of the
    /// short ends and split the outline into two floating horizontal bars.
    @MainActor
    func testOutlineStaysContinuousAtEveryDriftAngle() throws {
        for step in 0..<8 {
            let drift = Double(step) / 8
            let bitmap = try renderOutline(breath: 0.5, arcDrift: drift)
            // Sample a column just inside each short end; some pixel there must be lit.
            for column in [3, bitmap.pixelsWide - 4] {
                var brightest = 0.0
                for y in 0..<bitmap.pixelsHigh {
                    guard let color = bitmap.colorAt(x: column, y: y) else { continue }
                    brightest = max(brightest, Double(color.alphaComponent))
                }
                XCTAssertGreaterThan(
                    brightest, 0.05,
                    "Outline broke at column \(column) with the window at \(drift).")
            }
        }
    }
}
