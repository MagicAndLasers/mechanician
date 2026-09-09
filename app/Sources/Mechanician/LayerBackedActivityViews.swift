import SwiftUI
import AppKit
import QuartzCore

/// Shared lifecycle for tiny compositor-owned animations. The model layer tree is stable;
/// Core Animation interpolates presentation-layer properties without asking SwiftUI to
/// reevaluate the hosting tree on every frame.
class CompositorAnimationView: NSView {
    private var windowObservers: [NSObjectProtocol] = []
    private(set) var animationsRunning = false
    private var reduceMotion = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
        syncAnimationState()
    }

    override func viewDidHide() {
        super.viewDidHide()
        syncAnimationState()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        syncAnimationState()
    }

    func configureReduceMotion(_ reduceMotion: Bool) {
        guard self.reduceMotion != reduceMotion else { return }
        self.reduceMotion = reduceMotion
        syncAnimationState()
    }

    func animationConfigurationDidChange() {
        if animationsRunning {
            stopContinuousAnimations()
            applyStaticPresentation()
            startContinuousAnimations()
        } else {
            applyStaticPresentation()
        }
    }

    func prepareForRemoval() {
        unregisterWindowObservers()
        if animationsRunning {
            stopContinuousAnimations()
            animationsRunning = false
        }
    }

    func startContinuousAnimations() {}
    func stopContinuousAnimations() {}
    func applyStaticPresentation() {}

    private func observeWindow() {
        unregisterWindowObservers()
        guard let window else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        windowObservers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.syncAnimationState()
            }
        }
    }

    private func unregisterWindowObservers() {
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers.removeAll()
    }

    private func syncAnimationState() {
        let shouldRun: Bool
        if let window {
            shouldRun = !reduceMotion
                && !isHiddenOrHasHiddenAncestor
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        } else {
            shouldRun = false
        }

        guard shouldRun != animationsRunning else { return }
        animationsRunning = shouldRun
        if shouldRun {
            startContinuousAnimations()
        } else {
            stopContinuousAnimations()
            applyStaticPresentation()
        }
    }

    deinit {
        unregisterWindowObservers()
    }
}

// MARK: - Composer activity outline

/// Timing for the composer's activity outline.
///
/// There are deliberately no phases. Three continuous motions run at non-harmonic periods, so the
/// composition never visibly restarts and there is no stage boundary for the eye to catch: the
/// palette drifts around the perimeter, two long feathered arcs of light drift at a different rate,
/// and the whole outline breathes in brightness and bloom.
///
/// An earlier revision modelled this as a state machine — hold, emit, travel, absorb — which made
/// every stage boundary visible and turned the two seams into objects that popped in and out.
enum ComposerBreathingRhythm {
    struct Presentation: Equatable {
        let restingGlowOpacity: Double
        let peakGlowOpacity: Double
        let restingLineOpacity: Double
        let peakLineOpacity: Double
        let restingGlowWidth: CGFloat
        let peakGlowWidth: CGFloat
        let lineWidth: CGFloat
    }

    /// One calm breath, a little under eleven a minute.
    static let breathPeriod: CFTimeInterval = 5.6
    /// How long the two arcs of light take to drift once around the perimeter.
    static let arcDriftPeriod: CFTimeInterval = 13
    /// How long the palette takes to drift once around it. Deliberately not a whole multiple of
    /// either other period, so the three motions never realign into a perceptible loop.
    static let paletteDriftPeriod: CFTimeInterval = 21.5

    static let restingGlowOpacity = 0.055
    static let peakGlowOpacity = 0.17
    static let restingLineOpacity = 0.40
    static let peakLineOpacity = 0.70
    static let restingGlowWidth: CGFloat = 3.2
    static let peakGlowWidth: CGFloat = 6.8
    static let lineWidth: CGFloat = 1.05

    static let darkPresentation = Presentation(
        restingGlowOpacity: restingGlowOpacity,
        peakGlowOpacity: peakGlowOpacity,
        restingLineOpacity: restingLineOpacity,
        peakLineOpacity: peakLineOpacity,
        restingGlowWidth: restingGlowWidth,
        peakGlowWidth: peakGlowWidth,
        lineWidth: lineWidth)

    /// White absorbs a translucent glow instead of reflecting it the way the dark composer does.
    /// Give Light Mode a firmer keyline and a wider, brighter bloom while preserving the same calm
    /// timing and chromatic motion.
    static let lightPresentation = Presentation(
        restingGlowOpacity: 0.12,
        peakGlowOpacity: 0.32,
        restingLineOpacity: 0.66,
        peakLineOpacity: 0.96,
        restingGlowWidth: 4.4,
        peakGlowWidth: 9.0,
        lineWidth: 1.30)

    static func presentation(for appearance: NSAppearance) -> Presentation {
        appearance.mechanicianIsDark ? darkPresentation : lightPresentation
    }

    static var periods: [CFTimeInterval] {
        [breathPeriod, arcDriftPeriod, paletteDriftPeriod]
    }
}

/// The running-state indicator belongs to the whole composer, not to one of its actions. Two long,
/// softly feathered arcs of chromatic light drift around the glass perimeter while the outline
/// breathes. Core Animation owns all three motions as plain repeating animations, so transcript and
/// composer SwiftUI views remain still while the agent works.
struct LayerBackedComposerActivityOutline: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> ComposerActivityOutlineLayerView {
        let view = ComposerActivityOutlineLayerView()
        view.configure(cornerRadius: cornerRadius, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ nsView: ComposerActivityOutlineLayerView, context: Context) {
        nsView.configure(cornerRadius: cornerRadius, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ nsView: ComposerActivityOutlineLayerView, coordinator: ()) {
        nsView.prepareForRemoval()
    }
}

final class ComposerActivityOutlineLayerView: CompositorAnimationView {
    /// The palette is repeated around the perimeter so that each arc — not just the ring as a
    /// whole — spans most of the green→gold→orange→red→purple→blue laser ribbon. Two loops of six
    /// hues preserve the old twelve-band density; retaining the old three loops would turn the
    /// command box into eighteen narrow stripes.
    static let paletteRepetitions = 2

    /// The faintest the keyline ever gets. It never reaches zero: the composer is a rounded frame,
    /// and letting the dark part of the window land on one of the short ends would black that end
    /// out and break the outline into two floating bars.
    static let arcFloorAlpha = 0.28

    /// Two long lobes of light with long, soft ramps at both ends, riding over a keyline that is
    /// always present. Because neither lobe ever presents a hard tip, nothing has to "land"
    /// anywhere and no endpoint marker is needed: where the lobes are brightest is simply where the
    /// light currently is, and it moves continuously.
    static let arcAlphaStops: [(location: Double, alpha: Double)] = [
        (0.00, arcFloorAlpha), (0.04, arcFloorAlpha), (0.16, 1), (0.34, 1), (0.46, arcFloorAlpha),
        (0.54, arcFloorAlpha), (0.66, 1), (0.84, 1), (0.96, arcFloorAlpha), (1.00, arcFloorAlpha),
    ]

    private let glowContainer = CALayer()
    private let glowRing = CAShapeLayer()
    private let glowArc = CALayer()
    private let glowFade = CAGradientLayer()
    private let glowColor = CAGradientLayer()
    private let lineContainer = CALayer()
    private let lineRing = CAShapeLayer()
    private let lineArc = CALayer()
    private let lineFade = CAGradientLayer()
    private let lineColor = CAGradientLayer()
    private var outlineCornerRadius: CGFloat = 18

    private var rings: [CAShapeLayer] { [glowRing, lineRing] }
    private var fades: [CAGradientLayer] { [glowFade, lineFade] }
    private var palettes: [CAGradientLayer] { [glowColor, lineColor] }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installLayers()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(cornerRadius: CGFloat, reduceMotion: Bool) {
        if outlineCornerRadius != cornerRadius {
            outlineCornerRadius = cornerRadius
            needsLayout = true
        }
        configureReduceMotion(reduceMotion)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let localBounds = CGRect(origin: .zero, size: bounds.size)
        let center = CGPoint(x: localBounds.midX, y: localBounds.midY)
        // Anything that rotates is square and centred on the composer, so a full turn can never
        // expose an empty corner. Only these layers spin; the perimeter geometry stays still.
        let side = hypot(localBounds.width, localBounds.height)
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        let outlineRect = localBounds.insetBy(dx: 1.5, dy: 1.5)
        let radius = max(0, outlineCornerRadius - 1.5)
        let path = CGPath(
            roundedRect: outlineRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        for still in [glowContainer, lineContainer, glowArc, lineArc] {
            still.frame = localBounds
            still.contentsScale = scale
        }
        for ring in rings {
            ring.frame = localBounds
            ring.path = path
            ring.contentsScale = scale
        }
        for rotating in fades + palettes {
            rotating.bounds = square
            rotating.position = center
            rotating.contentsScale = scale
        }
        CATransaction.commit()
    }

    override func startContinuousAnimations() {
        let presentation = ComposerBreathingRhythm.presentation(for: effectiveAppearance)
        let start = lineContainer.convertTime(CACurrentMediaTime(), from: nil) + 0.05
        for fade in fades {
            fade.add(
                drift(period: ComposerBreathingRhythm.arcDriftPeriod, beginTime: start),
                forKey: "composer.arcDrift")
        }
        for palette in palettes {
            palette.add(
                drift(period: ComposerBreathingRhythm.paletteDriftPeriod, beginTime: start),
                forKey: "composer.paletteDrift")
        }
        glowContainer.add(
            breath(
                keyPath: "opacity",
                from: presentation.restingGlowOpacity,
                to: presentation.peakGlowOpacity,
                beginTime: start),
            forKey: "composer.breath")
        lineContainer.add(
            breath(
                keyPath: "opacity",
                from: presentation.restingLineOpacity,
                to: presentation.peakLineOpacity,
                beginTime: start),
            forKey: "composer.breath")
        // The bloom widens as it brightens, so the breath reads as light swelling off the keyline
        // rather than as the keyline itself thickening.
        glowRing.add(
            breath(
                keyPath: "lineWidth",
                from: Double(presentation.restingGlowWidth),
                to: Double(presentation.peakGlowWidth),
                beginTime: start),
            forKey: "composer.breath")
    }

    override func stopContinuousAnimations() {
        for target: CALayer in [glowContainer, lineContainer, glowArc, lineArc]
            + rings + fades + palettes {
            target.removeAllAnimations()
        }
    }

    override func applyStaticPresentation() {
        // Reduce Motion keeps the composition, frozen mid-breath.
        let presentation = ComposerBreathingRhythm.presentation(for: effectiveAppearance)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowContainer.opacity = Float(
            (presentation.restingGlowOpacity + presentation.peakGlowOpacity) / 2)
        lineContainer.opacity = Float(
            (presentation.restingLineOpacity + presentation.peakLineOpacity) / 2)
        glowRing.lineWidth =
            (presentation.restingGlowWidth + presentation.peakGlowWidth) / 2
        lineRing.lineWidth = presentation.lineWidth
        for rotating in fades + palettes {
            rotating.transform = CATransform3DIdentity
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBrandPalette()
        animationConfigurationDidChange()
    }

    private func installLayers() {
        guard let root = layer else { return }
        applyBrandPalette()
        for fade in fades {
            fade.type = .conic
            fade.colors = Self.arcAlphaStops.map {
                NSColor(white: 1, alpha: $0.alpha).cgColor
            }
            fade.locations = Self.arcAlphaStops.map { NSNumber(value: $0.location) }
            fade.startPoint = CGPoint(x: 0.5, y: 0.5)
            fade.endPoint = CGPoint(x: 0.5, y: 0)
        }
        for ring in rings {
            ring.fillColor = NSColor.clear.cgColor
            ring.strokeColor = NSColor.black.cgColor
            ring.lineCap = .round
            ring.lineJoin = .round
        }

        // Each band is: perimeter geometry (a still mask) → drifting arc window (a rotating mask)
        // → drifting palette. Keeping the two rotations on separate layers is what lets the colour
        // and the light travel at different speeds and never resynchronise.
        glowArc.mask = glowFade
        lineArc.mask = lineFade
        glowArc.addSublayer(glowColor)
        lineArc.addSublayer(lineColor)
        glowContainer.mask = glowRing
        lineContainer.mask = lineRing
        glowContainer.addSublayer(glowArc)
        lineContainer.addSublayer(lineArc)
        root.addSublayer(glowContainer)
        root.addSublayer(lineContainer)
        applyStaticPresentation()
    }

    private func applyBrandPalette() {
        let palette = MagicLaserSpectrum.resolvedColors(in: effectiveAppearance).map(\.cgColor)
        guard !palette.isEmpty else { return }
        let loop = (0..<Self.paletteRepetitions).flatMap { _ in palette } + [palette[0]]
        let loopLocations = loop.indices.map {
            NSNumber(value: Double($0) / Double(max(1, loop.count - 1)))
        }
        for color in palettes {
            color.type = .conic
            color.colors = loop
            color.locations = loopLocations
            color.startPoint = CGPoint(x: 0.5, y: 0.5)
            color.endPoint = CGPoint(x: 0.5, y: 0)
        }
    }

    private func drift(period: CFTimeInterval, beginTime: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = 2 * Double.pi
        animation.duration = period
        animation.beginTime = beginTime
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        return animation
    }

    private func breath(
        keyPath: String,
        from: Double,
        to: Double,
        beginTime: CFTimeInterval
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        // Half a period out, half a period back. Ease-in-ease-out gives zero velocity at both
        // extremes, which is what a breath does and what a linear ramp conspicuously does not.
        animation.duration = ComposerBreathingRhythm.breathPeriod / 2
        animation.autoreverses = true
        animation.beginTime = beginTime
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        return animation
    }

    #if DEBUG
    /// Drives the presentation to an arbitrary point in each motion so the composition can be
    /// rendered and inspected offline instead of chased through a live turn.
    func applyDebugPresentation(
        breath: Double,
        arcDrift: Double,
        paletteDrift: Double
    ) {
        let presentation = ComposerBreathingRhythm.presentation(for: effectiveAppearance)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let swell = 0.5 - 0.5 * cos(2 * .pi * breath)
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * swell }
        glowContainer.opacity = Float(lerp(
            presentation.restingGlowOpacity,
            presentation.peakGlowOpacity))
        lineContainer.opacity = Float(lerp(
            presentation.restingLineOpacity,
            presentation.peakLineOpacity))
        glowRing.lineWidth = CGFloat(lerp(
            Double(presentation.restingGlowWidth),
            Double(presentation.peakGlowWidth)))
        lineRing.lineWidth = presentation.lineWidth
        for fade in fades {
            fade.transform = CATransform3DMakeRotation(2 * .pi * arcDrift, 0, 0, 1)
        }
        for palette in palettes {
            palette.transform = CATransform3DMakeRotation(2 * .pi * paletteDrift, 0, 0, 1)
        }
        CATransaction.commit()
    }
    #endif
}

// MARK: - Magic beam rings

struct LayerBackedMagicBeam: NSViewRepresentable {
    enum Mode: Equatable {
        case working
        case armed
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: Mode

    func makeNSView(context: Context) -> MagicBeamLayerView {
        let view = MagicBeamLayerView()
        view.configure(mode: mode, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ nsView: MagicBeamLayerView, context: Context) {
        nsView.configure(mode: mode, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ nsView: MagicBeamLayerView, coordinator: ()) {
        nsView.prepareForRemoval()
    }
}

final class MagicBeamLayerView: CompositorAnimationView {
    private let bloomRotation = CALayer()
    private let bloom = CAGradientLayer()
    private let coreGlow = CAGradientLayer()
    private let violetShadow = CAShapeLayer()
    private let goldShadow = CAShapeLayer()
    private let ringRotation = CALayer()
    private let ring = CAGradientLayer()
    private let bloomMask = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    private var mode: LayerBackedMagicBeam.Mode = .armed

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installLayers()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(mode: LayerBackedMagicBeam.Mode, reduceMotion: Bool) {
        let changed = self.mode != mode
        self.mode = mode
        configureReduceMotion(reduceMotion)
        updateLayerVisibility()
        if changed { animationConfigurationDidChange() }
    }

    override func layout() {
        super.layout()
        guard let root = layer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let localBounds = CGRect(origin: .zero, size: bounds.size)
        let center = CGPoint(x: localBounds.midX, y: localBounds.midY)
        let ringRect = CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.contentsScale = scale
        for container in [bloomRotation, ringRotation] {
            container.bounds = localBounds
            container.position = center
            container.contentsScale = scale
        }
        for gradient in [bloom, ring] {
            // `bloom` carries a model-layer scale. Setting `frame` on a transformed layer is
            // undefined; bounds + position keeps its 34-point geometry centered at every phase.
            gradient.bounds = localBounds
            gradient.position = center
            gradient.contentsScale = scale
        }
        bloomMask.frame = localBounds
        bloomMask.contentsScale = scale
        ringMask.frame = localBounds
        ringMask.contentsScale = scale
        ringMask.path = strokedRingPath(in: ringRect)
        for shadow in [violetShadow, goldShadow] {
            shadow.frame = bounds
            shadow.contentsScale = scale
            // Draw no helper stroke: the explicit path produces only a diffuse shadow beneath the
            // one intended chromatic ring. Opaque source strokes leak through when that ring's
            // luminosity breathes down and read as an extra hard circle.
            shadow.shadowPath = strokedRingPath(in: ringRect)
        }
        // A 16pt white disc blurred by 6pt in the original occupies roughly this 28pt footprint.
        // The radial gradient supplies the same feathered core without a hard circle edge.
        coreGlow.frame = CGRect(x: bounds.midX - 14, y: bounds.midY - 14,
                                width: 28, height: 28)
        coreGlow.contentsScale = scale
        CATransaction.commit()
    }

    override func startContinuousAnimations() {
        let start = ringRotation.convertTime(CACurrentMediaTime(), from: nil) + 0.05
        let secondsPerTurn = mode == .working ? 9.0 : 15.0
        ringRotation.add(rotationAnimation(duration: secondsPerTurn, beginTime: start),
                         forKey: "magic.rotation")

        guard mode == .working else { return }
        bloomRotation.add(rotationAnimation(duration: secondsPerTurn, beginTime: start),
                          forKey: "magic.rotation")
        addBreathAnimations(beginTime: start)
    }

    override func stopContinuousAnimations() {
        bloomRotation.removeAllAnimations()
        ringRotation.removeAllAnimations()
        bloom.removeAllAnimations()
        coreGlow.removeAllAnimations()
        violetShadow.removeAllAnimations()
        goldShadow.removeAllAnimations()
        ring.removeAllAnimations()
    }

    override func applyStaticPresentation() {
        let breath = 0.5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bloomRotation.transform = CATransform3DIdentity
        ringRotation.transform = CATransform3DIdentity
        applyBreath(breath)
        CATransaction.commit()
    }

    private func installLayers() {
        guard let root = layer else { return }
        let colors = MagicBeam.components.map {
            NSColor(red: $0.r, green: $0.g, blue: $0.b, alpha: 1).cgColor
        }
        let loop = colors + [colors[0]]
        let locations = (0...MagicBeam.components.count).map {
            NSNumber(value: Double($0) / Double(MagicBeam.components.count))
        }

        for gradient in [bloom, ring] {
            gradient.type = .conic
            gradient.colors = loop
            gradient.locations = locations
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
        }
        // Feather the chromatic fill itself. The previous hard ellipse mask exposed a pulsing
        // colored disc behind the Stop glyph instead of the original diffuse color wash.
        bloomMask.type = .radial
        bloomMask.colors = [
            NSColor.black.cgColor,
            NSColor.black.withAlphaComponent(0.82).cgColor,
            NSColor.clear.cgColor,
        ]
        bloomMask.locations = [0, 0.48, 1]
        bloomMask.startPoint = CGPoint(x: 0.5, y: 0.5)
        bloomMask.endPoint = CGPoint(x: 1, y: 0.5)
        bloom.mask = bloomMask
        ring.mask = ringMask

        violetShadow.fillColor = NSColor.clear.cgColor
        violetShadow.strokeColor = NSColor.clear.cgColor
        violetShadow.shadowColor = colors[0]
        violetShadow.shadowOffset = .zero
        violetShadow.shadowOpacity = 0.5

        goldShadow.fillColor = NSColor.clear.cgColor
        goldShadow.strokeColor = NSColor.clear.cgColor
        goldShadow.shadowColor = colors[1]
        goldShadow.shadowOffset = .zero
        goldShadow.shadowOpacity = 0.35

        coreGlow.type = .radial
        coreGlow.colors = [
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(0.42).cgColor,
            NSColor.clear.cgColor,
        ]
        coreGlow.locations = [0, 0.32, 1]
        coreGlow.startPoint = CGPoint(x: 0.5, y: 0.5)
        coreGlow.endPoint = CGPoint(x: 1, y: 0.5)

        bloomRotation.addSublayer(bloom)
        ringRotation.addSublayer(ring)
        root.addSublayer(bloomRotation)
        root.addSublayer(coreGlow)
        root.addSublayer(goldShadow)
        root.addSublayer(violetShadow)
        root.addSublayer(ringRotation)
        updateLayerVisibility()
        applyStaticPresentation()
    }

    private func updateLayerVisibility() {
        let working = mode == .working
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bloomRotation.isHidden = !working
        coreGlow.isHidden = !working
        violetShadow.isHidden = !working
        goldShadow.isHidden = !working
        CATransaction.commit()
    }

    private func strokedRingPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addEllipse(in: rect.insetBy(dx: 1, dy: 1))
        return path.copy(strokingWithWidth: 2, lineCap: .butt, lineJoin: .miter,
                         miterLimit: 10)
    }

    private func rotationAnimation(duration: CFTimeInterval,
                                   beginTime: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = Double.pi * 2
        animation.duration = duration
        animation.beginTime = beginTime
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        return animation
    }

    private func addBreathAnimations(beginTime: CFTimeInterval) {
        addBreath(to: bloom, keyPath: "transform.scale", beginTime: beginTime) {
            1.1 + 0.55 * $0
        }
        addBreath(to: bloom, keyPath: "opacity", beginTime: beginTime) {
            0.08 + 0.28 * $0
        }
        addBreath(to: coreGlow, keyPath: "opacity", beginTime: beginTime) {
            0.10 + 0.22 * $0
        }
        addBreath(to: ring, keyPath: "opacity", beginTime: beginTime) {
            0.55 + 0.45 * $0
        }
        addBreath(to: violetShadow, keyPath: "shadowOpacity", beginTime: beginTime) {
            0.18 + 0.65 * $0
        }
        addBreath(to: violetShadow, keyPath: "shadowRadius", beginTime: beginTime) {
            2 + 6 * $0
        }
        addBreath(to: goldShadow, keyPath: "shadowOpacity", beginTime: beginTime) {
            0.10 + 0.50 * $0
        }
        addBreath(to: goldShadow, keyPath: "shadowRadius", beginTime: beginTime) {
            4 + 12 * $0
        }
    }

    private func addBreath(to layer: CALayer, keyPath: String,
                           beginTime: CFTimeInterval,
                           value: (Double) -> Double) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        let samples = 60
        animation.values = (0...samples).map { index -> NSNumber in
            let phase = Double(index) / Double(samples)
            // Begin at the same midpoint used by the model layers so attachment, unocclusion,
            // and Reduce Motion changes never flash from the static state to a different phase.
            let breath = 0.5 + 0.5 * sin(phase * 2 * .pi)
            return NSNumber(value: value(breath))
        }
        animation.keyTimes = (0...samples).map {
            NSNumber(value: Double($0) / Double(samples))
        }
        animation.duration = 3.8
        animation.beginTime = beginTime
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "magic.breath.\(keyPath)")
    }

    private func applyBreath(_ breath: Double) {
        bloom.transform = CATransform3DMakeScale(1.1 + 0.55 * breath,
                                                1.1 + 0.55 * breath, 1)
        bloom.opacity = Float(0.08 + 0.28 * breath)
        coreGlow.opacity = Float(0.10 + 0.22 * breath)
        ring.opacity = Float(mode == .working ? 0.55 + 0.45 * breath : 1)
        violetShadow.opacity = 1
        violetShadow.shadowOpacity = Float(0.18 + 0.65 * breath)
        violetShadow.shadowRadius = 2 + 6 * breath
        goldShadow.opacity = 1
        goldShadow.shadowOpacity = Float(0.10 + 0.50 * breath)
        goldShadow.shadowRadius = 4 + 12 * breath
    }
}

// MARK: - Orbiting dots

struct OrbitingDotsGeometry {
    static let maximumPulseScale: CGFloat = 2.8 / 2.15

    let orbitRadius: CGFloat
    let baseRadius: CGFloat

    var glowDiameter: CGFloat { baseRadius * 3.8 }
    var coreDiameter: CGFloat { baseRadius * 2 }
    var maximumCorePaintedRadius: CGFloat {
        orbitRadius + baseRadius * Self.maximumPulseScale
    }
    var maximumPaintedRadius: CGFloat {
        orbitRadius + glowDiameter / 2 * Self.maximumPulseScale
    }

    static func fitted(
        to diameter: CGFloat,
        reservesGlow: Bool = true,
        scalesDotsWithDiameter: Bool = false
    ) -> OrbitingDotsGeometry {
        let boundedDiameter = max(1, diameter)
        let orbit = boundedDiameter * (reservesGlow ? 0.22 : 0.25)
        let availablePaintRadius = max(0.5, boundedDiameter / 2 - orbit - 0.5)
        let base: CGFloat
        if reservesGlow {
            // Reserve a half point for antialiasing at the edge. The old fixed 12pt dot layer could
            // paint almost twice as far as compact hosts advertised once its pulse was applied.
            let fittedBase = availablePaintRadius / (1.9 * maximumPulseScale)
            base = scalesDotsWithDiameter ? fittedBase : min(2.15, fittedBase)
        } else {
            // A monochrome selected-row mark has no halo. Spend that recovered footprint on the
            // three cores so the 20pt control actually reads as a 20pt activity indicator.
            base = min(
                2.8,
                availablePaintRadius / maximumPulseScale)
        }
        return OrbitingDotsGeometry(
            orbitRadius: orbit,
            baseRadius: max(0.5, base))
    }
}

struct LayerBackedOrbitingDots: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var color: Color?
    var allowsVisualOverflow = false
    var showsGlow = true
    var scalesDotsWithDiameter = false

    func makeNSView(context: Context) -> OrbitingDotsLayerView {
        let view = OrbitingDotsLayerView()
        view.configure(
            color: color.map(NSColor.init),
            reduceMotion: reduceMotion,
            allowsVisualOverflow: allowsVisualOverflow,
            showsGlow: showsGlow,
            scalesDotsWithDiameter: scalesDotsWithDiameter)
        return view
    }

    func updateNSView(_ nsView: OrbitingDotsLayerView, context: Context) {
        nsView.configure(
            color: color.map(NSColor.init),
            reduceMotion: reduceMotion,
            allowsVisualOverflow: allowsVisualOverflow,
            showsGlow: showsGlow,
            scalesDotsWithDiameter: scalesDotsWithDiameter)
    }

    static func dismantleNSView(_ nsView: OrbitingDotsLayerView, coordinator: ()) {
        nsView.prepareForRemoval()
    }
}

final class OrbitingDotsLayerView: CompositorAnimationView {
    private let rotor = CALayer()
    private static let brandDotCount = 3
    private let dots: [CALayer] = (0..<brandDotCount).map { _ in CALayer() }
    private let glows: [CALayer] = (0..<brandDotCount).map { _ in CALayer() }
    private let cores: [CALayer] = (0..<brandDotCount).map { _ in CALayer() }
    private var configuredColor: NSColor?
    private var showsGlow = true
    private var scalesDotsWithDiameter = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installLayers()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        color: NSColor?,
        reduceMotion: Bool,
        allowsVisualOverflow: Bool = false,
        showsGlow: Bool = true,
        scalesDotsWithDiameter: Bool = false
    ) {
        configuredColor = color
        if self.showsGlow != showsGlow {
            self.showsGlow = showsGlow
            needsLayout = true
        }
        if self.scalesDotsWithDiameter != scalesDotsWithDiameter {
            self.scalesDotsWithDiameter = scalesDotsWithDiameter
            needsLayout = true
        }
        applyBrandPalette()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.masksToBounds = !allowsVisualOverflow
        CATransaction.commit()
        configureReduceMotion(reduceMotion)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBrandPalette()
    }

    override func layout() {
        super.layout()
        guard let root = layer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let geometry = OrbitingDotsGeometry.fitted(
            to: min(bounds.width, bounds.height),
            reservesGlow: showsGlow,
            scalesDotsWithDiameter: scalesDotsWithDiameter)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.contentsScale = scale
        rotor.frame = bounds
        rotor.contentsScale = scale
        for index in dots.indices {
            let phase = Double(index) * (2 * .pi / Double(dots.count))
            let dot = dots[index]
            dot.bounds = CGRect(
                x: 0,
                y: 0,
                width: geometry.glowDiameter,
                height: geometry.glowDiameter)
            dot.position = CGPoint(
                x: center.x + CGFloat(cos(phase)) * geometry.orbitRadius,
                y: center.y + CGFloat(sin(phase)) * geometry.orbitRadius)
            dot.contentsScale = scale

            glows[index].frame = dot.bounds
            glows[index].cornerRadius = geometry.glowDiameter / 2
            glows[index].contentsScale = scale

            cores[index].frame = CGRect(
                x: (geometry.glowDiameter - geometry.coreDiameter) / 2,
                y: (geometry.glowDiameter - geometry.coreDiameter) / 2,
                width: geometry.coreDiameter,
                height: geometry.coreDiameter)
            cores[index].cornerRadius = geometry.coreDiameter / 2
            cores[index].contentsScale = scale
        }
        CATransaction.commit()
    }

    override func startContinuousAnimations() {
        let start = rotor.convertTime(CACurrentMediaTime(), from: nil) + 0.05
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = Double.pi * 2
        rotation.duration = 2 * .pi / 1.7
        rotation.beginTime = start
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        rotation.isRemovedOnCompletion = false
        rotor.add(rotation, forKey: "dots.rotation")

        let samples = 60
        for index in dots.indices {
            let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
            let offset = Double(index) * (2 * .pi / Double(dots.count))
            pulse.values = (0...samples).map { sample -> NSNumber in
                let phase = Double(sample) / Double(samples) * 2 * .pi + offset
                let radius = 1.5 + 1.3 * (0.5 + 0.5 * sin(phase))
                return NSNumber(value: radius / 2.15)
            }
            pulse.keyTimes = (0...samples).map {
                NSNumber(value: Double($0) / Double(samples))
            }
            pulse.duration = 2 * .pi / 2.2
            pulse.beginTime = start
            pulse.repeatCount = .infinity
            pulse.calculationMode = .linear
            pulse.isRemovedOnCompletion = false
            dots[index].add(pulse, forKey: "dots.pulse")
        }
    }

    override func stopContinuousAnimations() {
        rotor.removeAllAnimations()
        dots.forEach { $0.removeAllAnimations() }
    }

    override func applyStaticPresentation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotor.transform = CATransform3DIdentity
        for index in dots.indices {
            let phase = Double(index) * (2 * .pi / Double(dots.count))
            let radius = 1.5 + 1.3 * (0.5 + 0.5 * sin(phase))
            dots[index].transform = CATransform3DMakeScale(radius / 2.15,
                                                          radius / 2.15, 1)
        }
        CATransaction.commit()
    }

    private func installLayers() {
        guard let root = layer else { return }
        // Canvas clipped the old dots to their declared frame. Keep that geometry so the
        // pulsing glow cannot bleed into neighboring compact sidebar rows.
        root.masksToBounds = true
        root.addSublayer(rotor)
        for index in dots.indices {
            dots[index].masksToBounds = false
            dots[index].addSublayer(glows[index])
            dots[index].addSublayer(cores[index])
            rotor.addSublayer(dots[index])
        }
        applyStaticPresentation()
    }

    private func applyBrandPalette() {
        let source = configuredColor.map { Array(repeating: $0, count: dots.count) }
            ?? MagicLaserSpectrum.spinnerColors
        let palette = MagicLaserSpectrum.resolvedColors(source, in: effectiveAppearance)
        guard palette.count == dots.count else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in dots.indices {
            glows[index].backgroundColor = palette[index].withAlphaComponent(0.28).cgColor
            glows[index].isHidden = !showsGlow
            cores[index].backgroundColor = palette[index].withAlphaComponent(0.95).cgColor
        }
        CATransaction.commit()
    }

    var coreColorsForTesting: [NSColor] {
        cores.compactMap(\.backgroundColor).compactMap(NSColor.init(cgColor:))
    }

    var coreDiametersForTesting: [CGFloat] {
        cores.map(\.bounds.width)
    }

    var glowsAreHiddenForTesting: Bool {
        glows.allSatisfy(\.isHidden)
    }
}
