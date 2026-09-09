import AppKit
import XCTest
@testable import Mechanician

/// Since macOS 15 the caret is an AppKit-owned `NSTextInsertionIndicator`: its shape, size and
/// blink belong to the system and `drawInsertionPoint(in:color:turnedOn:)` is never called. Colour
/// is the one thing a host can set, so that is all these cover.
final class ComposerCaretTests: XCTestCase {

    // MARK: drift

    func testHueDriftSharesTheOutlinePeriodAndWrapsCleanly() {
        let period = ComposerBreathingRhythm.paletteDriftPeriod

        XCTAssertEqual(
            ComposerCaret.driftPhase(at: 0, reduceMotion: false), 0, accuracy: 0.000_001)
        XCTAssertEqual(
            ComposerCaret.driftPhase(at: period / 2, reduceMotion: false),
            0.5, accuracy: 0.000_001)
        // Wraps rather than running away.
        XCTAssertEqual(
            ComposerCaret.driftPhase(at: period, reduceMotion: false), 0, accuracy: 0.000_001)
        XCTAssertEqual(
            ComposerCaret.driftPhase(at: period * 3.25, reduceMotion: false),
            0.25, accuracy: 0.000_001)

        for step in 0..<40 {
            let phase = ComposerCaret.driftPhase(at: Double(step) * 1.7, reduceMotion: false)
            XCTAssertGreaterThanOrEqual(phase, 0)
            XCTAssertLessThan(phase, 1)
        }
    }

    func testDriftIsSlowEnoughToNeverCompeteWithTyping() {
        // A whole second of typing moves the hue only a few percent of the palette.
        let a = ComposerCaret.driftPhase(at: 4, reduceMotion: false)
        let b = ComposerCaret.driftPhase(at: 5, reduceMotion: false)
        XCTAssertLessThan(abs(b - a), 0.06)
    }

    /// The tint is pushed on a timer rather than drawn, so the sampling interval — not the frame
    /// rate — decides whether the drift looks continuous or stepped.
    func testTintIsResampledFarFinerThanOneStepOfThePalette() {
        let legOfPalette = 1.0 / Double(MagicLaserSpectrum.colors.count)
        let phasePerRefresh =
            ComposerCaret.refreshInterval / ComposerBreathingRhythm.paletteDriftPeriod
        XCTAssertLessThan(phasePerRefresh, legOfPalette / 4)
        XCTAssertGreaterThan(
            ComposerCaret.refreshInterval, 0.1, "Needlessly frequent for a 20 s drift.")
    }

    func testReduceMotionFreezesTheHue() {
        for time in [0.0, 3.0, 11.5, 200.0] {
            XCTAssertEqual(
                ComposerCaret.driftPhase(at: time, reduceMotion: true), 0, accuracy: 0.000_001)
        }
    }

    // MARK: colour

    func testHueActuallyChangesAcrossTheDrift() {
        let sampled = stride(from: 0.0, to: 1.0, by: 0.25).map {
            ComposerCaret.color(
                driftPhase: $0, isDark: true, inFlight: false, increaseContrast: false)
        }
        let hues = Set(sampled.map { Int(($0.usingColorSpace(.sRGB)?.hueComponent ?? 0) * 360) })
        XCTAssertGreaterThanOrEqual(
            hues.count, 3, "The caret should visibly travel the palette, not sit on one colour.")
    }

    func testCaretTintTracksAllSixAnchorsOfTheOutlinePaletteInBothAppearances() throws {
        for (isDark, appearanceName) in [(true, NSAppearance.Name.darkAqua),
                                         (false, NSAppearance.Name.aqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let anchors = MagicLaserSpectrum.resolvedColors(in: appearance)
            for (index, expected) in anchors.enumerated() {
                let phase = Double(index) / Double(anchors.count)
                let caret = try XCTUnwrap(ComposerCaret.color(
                    driftPhase: phase, isDark: isDark,
                    inFlight: false, increaseContrast: false)
                    .usingColorSpace(.sRGB))
                let resolved = try XCTUnwrap(expected.usingColorSpace(.sRGB))
                XCTAssertEqual(caret.redComponent, resolved.redComponent, accuracy: 0.01)
                XCTAssertEqual(caret.greenComponent, resolved.greenComponent, accuracy: 0.01)
                XCTAssertEqual(caret.blueComponent, resolved.blueComponent, accuracy: 0.01)
            }
        }
    }

    func testLightAppearanceDeepensTheColourForContrast() throws {
        let dark = try XCTUnwrap(ComposerCaret.color(
            driftPhase: 0, isDark: true, inFlight: false, increaseContrast: false)
            .usingColorSpace(.sRGB))
        let light = try XCTUnwrap(ComposerCaret.color(
            driftPhase: 0, isDark: false, inFlight: false, increaseContrast: false)
            .usingColorSpace(.sRGB))

        XCTAssertLessThan(
            light.brightnessComponent, dark.brightnessComponent,
            "The palette is tuned for dark glass and is too pale on a white field.")
        XCTAssertEqual(light.hueComponent, dark.hueComponent, accuracy: 0.02)
    }

    func testInFlightCaretIsDimmedButStillVisible() {
        let idle = ComposerCaret.color(
            driftPhase: 0.3, isDark: true, inFlight: false, increaseContrast: false)
        let inFlight = ComposerCaret.color(
            driftPhase: 0.3, isDark: true, inFlight: true, increaseContrast: false)

        XCTAssertEqual(idle.alphaComponent, 1, accuracy: 0.000_001)
        XCTAssertLessThan(inFlight.alphaComponent, idle.alphaComponent)
        XCTAssertGreaterThan(inFlight.alphaComponent, 0.25, "Dimmed must not mean invisible.")
    }

    func testIncreaseContrastDropsTheTintEntirely() {
        for isDark in [true, false] {
            for phase in [0.0, 0.4, 0.8] {
                let color = ComposerCaret.color(
                    driftPhase: phase, isDark: isDark,
                    inFlight: false, increaseContrast: true)
                XCTAssertEqual(color, NSColor.labelColor.withAlphaComponent(1))
            }
        }
        // The queued-turn signal still survives the accessibility path.
        let dimmed = ComposerCaret.color(
            driftPhase: 0, isDark: true, inFlight: true, increaseContrast: true)
        XCTAssertLessThan(dimmed.alphaComponent, 1)
    }

    // MARK: glow

    func testGlowIsSubtleRelativeToTheCaretItself() {
        // A caret is a couple of points wide against a ~16 pt line; a few points of bloom reads as
        // phosphor, much more reads as a smear.
        XCTAssertGreaterThan(ComposerCaret.glowRadius, 1)
        XCTAssertLessThanOrEqual(ComposerCaret.glowRadius, 4)
        XCTAssertGreaterThan(ComposerCaret.baseGlowOpacity, 0.3)
        XCTAssertLessThan(ComposerCaret.baseGlowOpacity, 0.9)
    }

    func testGlowIsDroppedWhenTheUserAsksForHarderEdges() {
        XCTAssertEqual(
            ComposerCaret.glowOpacity(increaseContrast: false, reduceTransparency: false),
            ComposerCaret.baseGlowOpacity)
        XCTAssertEqual(
            ComposerCaret.glowOpacity(increaseContrast: true, reduceTransparency: false), 0)
        XCTAssertEqual(
            ComposerCaret.glowOpacity(increaseContrast: false, reduceTransparency: true), 0)
        XCTAssertEqual(
            ComposerCaret.glowOpacity(increaseContrast: true, reduceTransparency: true), 0)
    }

    /// The bloom has to land on the system indicator's own layer — that is what makes it track the
    /// caret while typing instead of trailing a frame behind.
    @MainActor
    func testGlowIsAppliedToTheSystemInsertionIndicator() throws {
        _ = NSApplication.shared
        let input = ChatInput(
            text: .constant(""),
            height: .constant(ChatInput.minHeight),
            isEnabled: true,
            onSend: {})
        let coordinator = ChatInput.Coordinator(input)
        let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        let indicator = NSTextInsertionIndicator(
            frame: NSRect(x: 10, y: 7, width: 0, height: 16))
        textView.addSubview(indicator)
        coordinator.textView = textView

        XCTAssertIdentical(
            ChatInput.Coordinator.insertionIndicator(in: textView), indicator,
            "The bloom cannot be attached if the indicator cannot be found.")

        let tint = NSColor(srgbRed: 0.62, green: 0.45, blue: 0.95, alpha: 1)
        coordinator.applyCaretGlow(tint: tint, in: textView, opacity: 0.7)

        let layer = try XCTUnwrap(indicator.layer)
        XCTAssertEqual(layer.shadowOpacity, 0.7, accuracy: 0.000_001)
        XCTAssertEqual(layer.shadowRadius, ComposerCaret.glowRadius, accuracy: 0.000_001)
        XCTAssertEqual(layer.shadowOffset, .zero, "An offset bloom would read as a drop shadow.")
        XCTAssertFalse(layer.masksToBounds)

        // The bloom is the caret's own colour, at full alpha so a dimmed in-flight caret still
        // glows in its hue rather than fading the bloom twice over.
        let shadow = try XCTUnwrap(
            NSColor(cgColor: try XCTUnwrap(layer.shadowColor))?.usingColorSpace(.sRGB))
        XCTAssertEqual(Double(shadow.redComponent), 0.62, accuracy: 0.02)
        XCTAssertEqual(Double(shadow.greenComponent), 0.45, accuracy: 0.02)
        XCTAssertEqual(Double(shadow.blueComponent), 0.95, accuracy: 0.02)
        XCTAssertEqual(shadow.alphaComponent, 1, accuracy: 0.000_001)
    }

    // MARK: plumbing

    /// The tint can only reach an AppKit-owned indicator by being assigned to the text view, so
    /// assert the host actually pushes it there.
    @MainActor
    func testCoordinatorPushesTheTintOntoTheTextView() {
        _ = NSApplication.shared
        let input = ChatInput(
            text: .constant(""),
            height: .constant(ChatInput.minHeight),
            isEnabled: true,
            onSend: {})
        let coordinator = ChatInput.Coordinator(input)
        let textView = ComposerTextView()
        textView.insertionPointColor = .labelColor
        coordinator.textView = textView

        coordinator.refreshCaretTint()

        XCTAssertNotEqual(
            textView.insertionPointColor, NSColor.labelColor,
            "A tinted caret is the whole point; label colour means nothing was applied.")
    }

    // MARK: per-keystroke cost

    /// `updateNSView` runs on every keystroke. The tint is already resampled on its own timer, so
    /// re-deriving it here — three `NSWorkspace` accessibility queries plus a recursive subview
    /// walk — made typing cost scale with the caret's styling. It must only fire on a real change.
    @MainActor
    func testTintIsNotRederivedOnEveryUpdate() {
        _ = NSApplication.shared
        let input = ChatInput(
            text: .constant(""),
            height: .constant(ChatInput.minHeight),
            isEnabled: true,
            onSend: {})
        let coordinator = ChatInput.Coordinator(input)
        let textView = ComposerTextView()
        coordinator.textView = textView

        textView.insertionPointColor = .labelColor
        coordinator.refreshCaretTintIfTurnStateChanged(false)
        let afterFirst = textView.insertionPointColor
        XCTAssertNotEqual(afterFirst, NSColor.labelColor, "The first call must establish the tint.")

        // Simulate keystrokes: same turn state, so nothing should be recomputed.
        textView.insertionPointColor = .labelColor
        for _ in 0..<20 { coordinator.refreshCaretTintIfTurnStateChanged(false) }
        XCTAssertEqual(
            textView.insertionPointColor, NSColor.labelColor,
            "Unchanged turn state must not re-derive the tint on every update.")

        // A turn starting is a real change and must be picked up at once.
        coordinator.refreshCaretTintIfTurnStateChanged(true)
        XCTAssertNotEqual(textView.insertionPointColor, NSColor.labelColor)
    }

    /// `initialFirstResponder` only needs setting when the editor lands in a new window; doing it
    /// per keystroke was pointless work.
    @MainActor
    func testFocusIsOnlyReattachedWhenTheWindowChanges() {
        _ = NSApplication.shared
        let input = ChatInput(
            text: .constant(""),
            height: .constant(ChatInput.minHeight),
            isEnabled: true,
            onSend: {})
        let coordinator = ChatInput.Coordinator(input)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled], backing: .buffered, defer: false)
        let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        window.contentView?.addSubview(textView)

        XCTAssertTrue(coordinator.shouldReattachFocus(for: textView), "First sighting attaches.")
        for _ in 0..<20 {
            XCTAssertFalse(
                coordinator.shouldReattachFocus(for: textView),
                "The same window must not be re-attached on every keystroke.")
        }

        let moved = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled], backing: .buffered, defer: false)
        moved.contentView?.addSubview(textView)
        XCTAssertTrue(
            coordinator.shouldReattachFocus(for: textView),
            "A genuinely new window must re-establish the preferred responder.")
    }
}
