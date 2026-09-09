import SwiftUI
import AppKit
import CoreText

/// Product typography shared with the Mechanician website. The font is registered for this
/// process at launch because macOS does not discover an arbitrary font file in Resources on its
/// own. Keep the PostScript name in sync with `app/Resources/dm-serif-display-latin.woff2`.
enum MechanicianTypography {
    static let productName = "Mechanician"
    static let productDisplayPostScriptName = "DMSerifDisplay-Regular"
    static let newConversationWordmarkFont = Font.custom(
        productDisplayPostScriptName,
        size: 34)
    static let newConversationWordmarkTracking: CGFloat = 0.34

    static func isProductWordmark(_ title: String) -> Bool {
        title.caseInsensitiveCompare(productName) == .orderedSame
    }

    @discardableResult
    static func registerBundledProductDisplayFont(in bundle: Bundle = .main) -> Bool {
        if NSFont(name: productDisplayPostScriptName, size: 12) != nil { return true }
        guard let url = bundle.url(
            forResource: "dm-serif-display-latin",
            withExtension: "woff2"
        ) else {
            return false
        }
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return registered || NSFont(name: productDisplayPostScriptName, size: 12) != nil
    }
}

/// An NSColor that resolves differently in light vs dark, so the palette follows the
/// system appearance instead of being pinned to one mode.
private func adaptiveNSColor(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
}

private func nsGray(_ w: CGFloat) -> NSColor { NSColor(white: w, alpha: 1) }

/// The persisted Appearance choice, normalized in one place for both SwiftUI and AppKit.
/// Unknown/legacy values deliberately fall back to System instead of pinning a stale appearance.
enum MechanicianAppearancePreference: String, CaseIterable {
    case system
    case light
    case dark

    init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .system
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var appKitAppearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }
}

/// Layer-backed AppKit views need a concrete CGColor. Reading `cgColor` directly from a dynamic
/// NSColor resolves it against the process's current/system appearance, which can disagree with an
/// app-overridden window. Resolve under the view's effective appearance before storing the color
/// in a CALayer.
extension NSColor {
    func mechanicianResolved(in appearance: NSAppearance) -> NSColor {
        var resolved = self
        appearance.performAsCurrentDrawingAppearance {
            resolved = usingColorSpace(.sRGB) ?? self
        }
        return resolved
    }

    func mechanicianCGColor(
        in appearance: NSAppearance,
        alpha: CGFloat? = nil
    ) -> CGColor {
        let resolved = mechanicianResolved(in: appearance)
        return alpha.map(resolved.withAlphaComponent)?.cgColor ?? resolved.cgColor
    }
}

extension NSAppearance {
    /// The effective Light/Dark polarity for appearance-specific drawing. Custom AppKit views use
    /// this instead of consulting the Mac's ambient setting, because Mechanician can override the
    /// app to Light or Dark while the system remains in the opposite appearance.
    var mechanicianIsDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// The six outgoing rays in the Magic & Lasers mark, ordered top-to-bottom:
/// green → gold → orange → red → purple → blue.
///
/// These are intentionally separate from `MagicBeam`, whose softer four-colour palette is sampled
/// from the mark's swirling "magic" side and remains on the dictation waveform. The crisp laser
/// spectrum belongs to the composer outline, caret, activity spinner, and categorical tool meters.
enum MagicLaserSpectrum {
    struct RGB: Equatable {
        let r: Double
        let g: Double
        let b: Double
    }

    /// Core pixels sampled from the six rays in `magic_and_lasers.PNG`.
    static let sampledComponents: [RGB] = [
        RGB(r: 0x44 / 255.0, g: 0x99 / 255.0, b: 0x38 / 255.0), // green
        RGB(r: 0xEA / 255.0, g: 0xAE / 255.0, b: 0x05 / 255.0), // gold
        RGB(r: 0xF5 / 255.0, g: 0x66 / 255.0, b: 0x00 / 255.0), // orange
        RGB(r: 0xEC / 255.0, g: 0x22 / 255.0, b: 0x00 / 255.0), // red
        RGB(r: 0xA4 / 255.0, g: 0x4B / 255.0, b: 0x93 / 255.0), // purple
        RGB(r: 0x03 / 255.0, g: 0x3B / 255.0, b: 0xDA / 255.0), // blue
    ]

    private static let lightComponents: [RGB] = [
        RGB(r: 0x28 / 255.0, g: 0x7A / 255.0, b: 0x23 / 255.0),
        RGB(r: 0x9B / 255.0, g: 0x68 / 255.0, b: 0x00 / 255.0),
        RGB(r: 0xB9 / 255.0, g: 0x47 / 255.0, b: 0x00 / 255.0),
        RGB(r: 0xC9 / 255.0, g: 0x25 / 255.0, b: 0x18 / 255.0),
        RGB(r: 0x85 / 255.0, g: 0x33 / 255.0, b: 0x78 / 255.0),
        RGB(r: 0x14 / 255.0, g: 0x4F / 255.0, b: 0xC4 / 255.0),
    ]

    private static let darkComponents: [RGB] = [
        RGB(r: 0x61 / 255.0, g: 0xC9 / 255.0, b: 0x54 / 255.0),
        RGB(r: 0xF1 / 255.0, g: 0xC2 / 255.0, b: 0x32 / 255.0),
        RGB(r: 0xFF / 255.0, g: 0x84 / 255.0, b: 0x2B / 255.0),
        RGB(r: 0xFF / 255.0, g: 0x5A / 255.0, b: 0x4C / 255.0),
        RGB(r: 0xC0 / 255.0, g: 0x5B / 255.0, b: 0xAD / 255.0),
        RGB(r: 0x4D / 255.0, g: 0x80 / 255.0, b: 0xFF / 255.0),
    ]

    static let colors: [NSColor] = zip(lightComponents, darkComponents).map { light, dark in
        adaptiveNSColor(
            light: NSColor(srgbRed: light.r, green: light.g, blue: light.b, alpha: 1),
            dark: NSColor(srgbRed: dark.r, green: dark.g, blue: dark.b, alpha: 1))
    }

    /// Small text uses the same hue anchors, with the Dark Mode blue and purple lifted just enough
    /// to clear 4.5:1 on the raised `nSurface` card (the original display colors already clear the
    /// darker base background, but not that card).
    private static let semanticTextDarkComponents: [RGB] = [
        darkComponents[0],
        darkComponents[1],
        darkComponents[2],
        darkComponents[3],
        RGB(r: 0xD4 / 255.0, g: 0x77 / 255.0, b: 0xC5 / 255.0),
        RGB(r: 0x5F / 255.0, g: 0x8F / 255.0, b: 0xFF / 255.0),
    ]

    static let semanticTextColors: [NSColor] =
        zip(lightComponents, semanticTextDarkComponents).map { light, dark in
            adaptiveNSColor(
                light: NSColor(
                    srgbRed: light.r, green: light.g, blue: light.b, alpha: 1),
                dark: NSColor(
                    srgbRed: dark.r, green: dark.g, blue: dark.b, alpha: 1))
        }

    /// Flat five-point meter segments expose a color much more directly than a glowing,
    /// interpolated outline. These deeper rail colors retain the logo's crisp saturation without
    /// changing the composer palette the user already approved.
    private static let meterLightComponents: [RGB] = [
        sampledComponents[0],
        // Use the ray itself. A bounded meter already has a dark keyline on Light surfaces, so
        // changing the logo's clean yellow-gold into a contrast-driven mustard only makes the
        // brand less recognizable without improving the segment's shape boundary.
        sampledComponents[1],
        sampledComponents[2],
        sampledComponents[3],
        sampledComponents[4],
        // The sampled navy looked almost black across a long model span. Lift its luminance while
        // preserving enough white-background contrast for a compact graphical mark.
        RGB(r: 0x34 / 255.0, g: 0x70 / 255.0, b: 0xE6 / 255.0),
    ]

    private static let meterDarkComponents: [RGB] = [
        RGB(r: 0x46 / 255.0, g: 0xA8 / 255.0, b: 0x3C / 255.0),
        RGB(r: 0xED / 255.0, g: 0xB5 / 255.0, b: 0x09 / 255.0),
        RGB(r: 0xF6 / 255.0, g: 0x68 / 255.0, b: 0x00 / 255.0),
        RGB(r: 0xF0 / 255.0, g: 0x35 / 255.0, b: 0x20 / 255.0),
        RGB(r: 0xBE / 255.0, g: 0x40 / 255.0, b: 0x9C / 255.0),
        RGB(r: 0x35 / 255.0, g: 0x6A / 255.0, b: 0xF5 / 255.0),
    ]

    static let meterColors: [NSColor] = zip(meterLightComponents, meterDarkComponents).map {
        light, dark in
        adaptiveNSColor(
            light: NSColor(srgbRed: light.r, green: light.g, blue: light.b, alpha: 1),
            dark: NSColor(srgbRed: dark.r, green: dark.g, blue: dark.b, alpha: 1))
    }

    /// A cyclic sample through the same appearance-specific anchors the composer outline draws.
    /// Keeping interpolation here prevents the caret from maintaining a subtly different copy of
    /// the brand spectrum.
    static func rgb(at t: Double, isDark: Bool) -> RGB {
        let components = isDark ? darkComponents : lightComponents
        let wrapped = ((t.truncatingRemainder(dividingBy: 1)) + 1)
            .truncatingRemainder(dividingBy: 1)
        let position = wrapped * Double(components.count)
        let index = Int(position) % components.count
        let fraction = position - Double(Int(position))
        let current = components[index]
        let next = components[(index + 1) % components.count]
        return RGB(
            r: current.r + (next.r - current.r) * fraction,
            g: current.g + (next.g - current.g) * fraction,
            b: current.b + (next.b - current.b) * fraction)
    }

    /// A three-dot activity mark cannot carry all six rays without becoming a tiny color wheel.
    /// Gold, purple, and blue are distinct alternating brand anchors that also avoid borrowing the
    /// green/red terminal-state language used beside the spinner for success and failure.
    static var spinnerColors: [NSColor] {
        [colors[1], colors[4], colors[5]]
    }

    /// Layer-backed views need concrete colors rather than named/dynamic `NSColor`s. Resolve inside
    /// the target appearance so changing the app between Light and Dark updates the composition
    /// without relaunching.
    static func resolvedColors(
        _ source: [NSColor] = colors,
        in appearance: NSAppearance
    ) -> [NSColor] {
        source.map { color in
            var resolved = color
            appearance.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB) ?? color
            }
            return resolved
        }
    }
}

/// Shared visual policy for the account-recovery card above the composer.
///
/// The card is an actionable setup surface, not a destructive warning. Its broad field therefore
/// stays on the raised neutral surface with only a quiet cool wash; the complete six-ray mark is
/// reserved for the narrow decorative rail, where gold/orange/red remain crisp instead of turning
/// a full-width Light Mode surface beige.
enum ProviderRecoveryCardPalette {
    /// A subtle tint that leaves caption-sized copy readable in both appearances.
    static let washOpacity = 0.09
    static let baseSurface: NSColor = .nSurface

    /// Purple → blue → green follows the cool side of the existing six-ray mark.
    static let washColors: [NSColor] = [
        MagicLaserSpectrum.colors[4],
        MagicLaserSpectrum.colors[5],
        MagicLaserSpectrum.colors[0],
    ]

    /// The narrow rail carries the complete logo spectrum in its canonical order.
    static let railColors: [NSColor] = MagicLaserSpectrum.colors
}

/// App palette. Now adaptive + system-derived: neutrals track Light/Dark, and the accent
/// is the user's chosen system accent — so the app looks native in both appearances.
extension Color {
    // Dark neutrals: near-black and very slightly COOL (blue ≥ red), like Apple Mail —
    // this reads neutral/black, not the warm grey that looked "brown".
    /// Base window/panel background.
    static let nBg = Color(nsColor: adaptiveNSColor(
        light: .windowBackgroundColor,
        dark: NSColor(srgbRed: 0.098, green: 0.101, blue: 0.110, alpha: 1))) // ~#191A1C
    /// A raised content surface (cards, composer, code blocks).
    static let nSurface = Color(nsColor: adaptiveNSColor(
        light: .white,
        dark: NSColor(srgbRed: 0.137, green: 0.141, blue: 0.153, alpha: 1))) // ~#232427
    /// A more prominent fill (search fields, pills, hover chips).
    static let nElevated = Color(nsColor: adaptiveNSColor(
        light: nsGray(0.925),
        dark: NSColor(srgbRed: 0.188, green: 0.192, blue: 0.208, alpha: 1))) // ~#303135
    /// Borders / hairlines (always used with opacity).
    static let nMuted = Color(nsColor: .nMuted)
    /// Primary text/icon color.
    static let nText = Color(nsColor: .labelColor)
    /// A source-list selection can be a pale neutral when the table is not first responder (as it
    /// normally is while typing in the composer). White text on that native Light Mode selection
    /// is nearly invisible, so selected-row copy follows the appearance: dark ink in Light Mode,
    /// light ink in Dark Mode.
    static let nSelectedText = Color(nsColor: .nSelectedText)
    static let nSelectedSecondaryText = Color(nsColor: .nSelectedSecondaryText)
    /// Secondary copy that remains readable at caption sizes on raised cards. The system
    /// `.secondary` and especially `.tertiary` styles are intentionally subtle, but fall below
    /// text contrast on the white marketplace cards where provenance and setup labels are vital.
    static let nSecondaryText = Color(nsColor: .nSecondaryText)
    /// Semantic colors intended for small text and thin glyphs. Apple's system semantic colors are
    /// excellent filled marks, but several resolve below 4.5:1 against a white surface. These use
    /// the appearance-tuned Magic & Lasers anchors already used by the composer and activity UI.
    static let nInfoText = Color(nsColor: .nInfoText)
    static let nSuccessText = Color(nsColor: .nSuccessText)
    static let nGoldText = Color(nsColor: .nGoldText)
    static let nWarningText = Color(nsColor: .nWarningText)
    static let nErrorText = Color(nsColor: .nErrorText)
    static let nPurpleText = Color(nsColor: .nPurpleText)
    /// Accent — the user's system accent color.
    static let nAccent = Color(nsColor: .controlAccentColor)
    /// A solid app-owned action fill paired with white ink. Unlike `nAccent`, this cannot become
    /// yellow, graphite, or another user-selected accent that makes fixed white symbols disappear.
    /// Use it for dense badges and primary icon buttons whose foreground is necessarily white.
    static let nSolidActionFill = Color(nsColor: .nSolidActionFill)
    /// The Magic & Lasers beam violet, deepened just enough to carry white primary-action ink.
    /// This is app-owned rather than system-accent-derived, so the action stays recognizably ours
    /// and remains readable when the user's macOS accent is Graphite, Yellow, or another pale hue.
    static let nBrandActionFill = Color(nsColor: .nBrandActionFill)
    /// Pinned-conversation accent — the app's highlight blue, tuned per appearance so the pin reads
    /// as a mark rather than another grey glyph. A selected row is already accent-filled, so the
    /// glyph goes white there instead of stacking a second colour on top of it.
    static let nPinned = Color(nsColor: .nPinned)
}

extension NSColor {
    static let nBg = NSColor.windowBackgroundColor
    static let nSurface = adaptiveNSColor(
        light: .white,
        dark: NSColor(srgbRed: 0.137, green: 0.141, blue: 0.153, alpha: 1))
    static let nElevated = adaptiveNSColor(
        light: nsGray(0.925),
        dark: NSColor(srgbRed: 0.188, green: 0.192, blue: 0.208, alpha: 1))
    /// A control track for a well or segmented strip drawn on the WINDOW background, not on a card.
    ///
    /// `nElevated` is the fill for a track on `nSurface`, and on the window background it is not a
    /// fill at all: measured off the running app it is 0.925 against that background's 0.940, four
    /// levels at 8 bits. Dark Mode lifts off its background; Light Mode has to go the other way and
    /// sit BELOW its own, which is why one static grey cannot serve both.
    ///
    /// The light value is deliberately darker than `nElevated` rather than lighter than it. Going up
    /// to white looked right against the 0.940 a real window renders and disappeared entirely when
    /// `windowBackgroundColor` resolved to pure white, which it does outside a window — a track
    /// whose visibility depends on the panel never being white is a track that will vanish
    /// somewhere. Below every light window background, it cannot.
    static let nTrackOnBackground = adaptiveNSColor(
        light: nsGray(0.88),
        dark: NSColor(srgbRed: 0.188, green: 0.192, blue: 0.208, alpha: 1))
    /// Borders / hairlines (always used with opacity). AppKit-side surfaces — the conversation
    /// rename field among them — need the same hairline the SwiftUI `Color.nMuted` draws, so the
    /// two are one value rather than two definitions that can drift.
    static let nMuted = adaptiveNSColor(light: nsGray(0.74), dark: nsGray(0.34))
    static let nSelectedText = adaptiveNSColor(
        light: NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1), // #1D1D1F
        dark: NSColor(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1))  // #F5F5F7
    static let nSelectedSecondaryText = adaptiveNSColor(
        light: NSColor(srgbRed: 0.227, green: 0.227, blue: 0.235, alpha: 1), // #3A3A3C
        dark: NSColor(srgbRed: 0.780, green: 0.780, blue: 0.804, alpha: 1))  // #C7C7CD
    static let nSecondaryText = adaptiveNSColor(
        light: NSColor(srgbRed: 0.373, green: 0.388, blue: 0.408, alpha: 1), // #5F6368
        dark: NSColor(srgbRed: 0.651, green: 0.651, blue: 0.682, alpha: 1))  // #A6A6AE
    static let nInfoText = MagicLaserSpectrum.semanticTextColors[5]
    static let nSuccessText = MagicLaserSpectrum.semanticTextColors[0]
    static let nGoldText = MagicLaserSpectrum.semanticTextColors[1]
    static let nWarningText = MagicLaserSpectrum.semanticTextColors[2]
    static let nErrorText = MagicLaserSpectrum.semanticTextColors[3]
    static let nPurpleText = MagicLaserSpectrum.semanticTextColors[4]
    /// The same appearance-tuned app blue used for the selected conversation. Both endpoints clear
    /// 4.5:1 against white, so compact white count text and symbols remain readable regardless of
    /// the user's system accent.
    static let nSolidActionFill = adaptiveNSColor(
        light: NSColor(
            srgbRed: 0x24 / 255.0,
            green: 0x6F / 255.0,
            blue: 0xC8 / 255.0,
            alpha: 1), // #246FC8
        dark: NSColor(
            srgbRed: 0x2B / 255.0,
            green: 0x70 / 255.0,
            blue: 0xD1 / 255.0,
            alpha: 1)) // #2B70D1
    /// Essential chart microcopy: stronger than tertiary labels because 7–8 pt timeline metadata
    /// otherwise disappears on the Light plot, while still reading as subordinate in Dark Mode.
    static let nChartMuted = nSecondaryText

    /// The pin glyph's tint: the app's own highlight blue (`controlAccentColor`, #007AFF), lightened
    /// for Dark Mode so it pops off the row and deepened for Light Mode so it reads on white. Held
    /// as fixed values rather than the live accent because a graphite or grey system accent would
    /// turn the pin back into the indistinguishable grey glyph this replaced.
    static let nPinned = adaptiveNSColor(
        light: NSColor(srgbRed: 0.000, green: 0.384, blue: 0.800, alpha: 1),  // #0062CC
        dark: NSColor(srgbRed: 0.302, green: 0.639, blue: 1.000, alpha: 1))   // #4DA3FF

    /// The Magic & Lasers beam violet (`MagicBeam` #9E72F2), deepened along its own hue until it
    /// carries white text. The raw brand violet measures only 3.42:1; this lands at 5.82:1 while
    /// keeping the brand's character.
    static let nBrandActionFill =
        NSColor(srgbRed: 0.467, green: 0.271, blue: 0.839, alpha: 1) // #7745D6
    /// The pin action deliberately aliases the brand violet rather than blue: the `systemBlue`
    /// "Mark Unread" action sits directly beside it, and two adjacent blues read as one split button.
    static let nPinnedFill = nBrandActionFill
}

extension View {
    /// A raised interactive surface: a filled + hairline-stroked rounded rectangle. (Liquid Glass
    /// was tried and reverted — the app uses the classic flat surface look; the folder toolbar item
    /// and window tab bar are held to that look too via `UIDesignRequiresCompatibility` in Info.plist.)
    func glassSurface(cornerRadius: CGFloat = 12,
                      legacyFill: Color = .nSurface,
                      legacyStroke: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self.background(shape.fill(legacyFill))
            .overlay { if let s = legacyStroke { shape.stroke(s) } }
    }

    /// A raised card / well that reads in BOTH appearances. Fills with `nSurface` (white in
    /// light, #232427 in dark → genuinely raised over the `nBg` panel) plus an `nMuted`
    /// hairline. Use for cards, rows, search fields and control wells that sit on `nBg`:
    /// `nElevated` equals `nBg` in light mode, so an `nElevated` fill alone is invisible there.
    func cardSurface(cornerRadius: CGFloat = 10, strokeOpacity: Double = 0.55) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(shape.fill(Color.nSurface))
            .overlay(shape.strokeBorder(Color.nMuted.opacity(strokeOpacity)))
    }

    /// The shared account-recovery surface used in both the conversation and Provider Center.
    ///
    /// Keeping the cool wash, six-ray rail, border, and final clipping together prevents the
    /// Provider Center prompt from drifting back to a plain warning card while the composer uses
    /// the branded recovery treatment.
    func providerRecoverySurface(
        cornerRadius: CGFloat = 10,
        strokeOpacity: Double = 0.42
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                shape
                    .fill(Color(nsColor: ProviderRecoveryCardPalette.baseSurface))
                    .overlay {
                        shape.fill(
                            LinearGradient(
                                colors: ProviderRecoveryCardPalette.washColors.map {
                                    Color(nsColor: $0)
                                        .opacity(ProviderRecoveryCardPalette.washOpacity)
                                },
                                startPoint: .leading,
                                endPoint: .trailing))
                    }
            }
            .overlay(alignment: .leading) {
                LinearGradient(
                    colors: ProviderRecoveryCardPalette.railColors.map(Color.init(nsColor:)),
                    startPoint: .top,
                    endPoint: .bottom)
                    .frame(width: 4)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: cornerRadius,
                            bottomLeadingRadius: cornerRadius))
                    .accessibilityHidden(true)
            }
            .overlay {
                shape.strokeBorder(Color.nMuted.opacity(strokeOpacity))
            }
            .clipShape(shape)
    }

}

/// The app's button LANGUAGE — soft capsule "pills", NOT standard system buttons. Matches the
/// composer/status chips (`Capsule().fill(.nAccent.opacity(0.18))`) and the bare-glyph send/mic
/// controls. `accent` = a tinted-accent pill; `brand` = the solid Magic & Lasers primary action;
/// `neutral` = an `nElevated` pill (secondary); `plain` = text-only until hovered (Cancel-style).
struct PillButtonStyle: ButtonStyle {
    enum Kind { case accent, brand, neutral, plain, destructive }
    var kind: Kind = .neutral
    func makeBody(configuration: Configuration) -> some View { PillBody(configuration: configuration, kind: kind) }

    private struct PillBody: View {
        let configuration: PillButtonStyle.Configuration
        let kind: PillButtonStyle.Kind
        @Environment(\.isEnabled) private var isEnabled
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background {
                    switch kind {
                    case .accent:  Capsule().fill(Color.nAccent.opacity(configuration.isPressed ? 0.30 : (hover ? 0.26 : 0.16)))
                    case .brand:
                        Capsule()
                            .fill(Color.nBrandActionFill)
                            .overlay {
                                Capsule().fill(
                                    configuration.isPressed
                                        ? Color.black.opacity(0.12)
                                        : hover ? Color.white.opacity(0.10) : Color.clear)
                            }
                    case .neutral: Capsule().fill(Color.nElevated.opacity(configuration.isPressed ? 0.6 : (hover ? 1.0 : 0.8)))
                    case .plain:   Capsule().fill(hover ? Color.nElevated.opacity(0.55) : Color.clear)
                    case .destructive: Capsule().fill(Color.red.opacity(configuration.isPressed ? 0.24 : (hover ? 0.16 : 0.0)))
                    }
                }
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }

        private var foreground: Color {
            switch kind {
            case .brand: return .white
            case .accent: return .nInfoText
            case .destructive: return .nErrorText
            case .neutral, .plain: return .nText
            }
        }
    }
}

/// One compact control inside the conversation control deck. The deck supplies the persistent
/// surface; individual controls reveal their hit target on hover and use accent only for a true
/// on/off state. This avoids the old mixture of blue borderless menus and unrelated filled pills.
struct MechanicianControlTrigger: View {
    let title: String
    var systemImage: String?
    var showsChevron = false
    var active = false
    var maxTitleWidth: CGFloat?
    var badge: String?
    /// Let a crowded control bar preserve the label by using a second text line. The trigger grows
    /// with the title instead of truncating it or forcing controls at the trailing edge offscreen.
    var wrapsTitle = false
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .medium))
                    .accessibilityHidden(true)
            }
            if !title.isEmpty {
                Text(title)
                    .lineLimit(wrapsTitle ? 2 : 1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: wrapsTitle)
                    .frame(maxWidth: maxTitleWidth, alignment: .leading)
            }
            if let badge {
                Text(badge)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.nInfoText)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.nAccent.opacity(0.14)))
            }
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(active ? Color.nInfoText : Color.nText)
        .padding(.horizontal, 8)
        .frame(height: wrapsTitle ? 38 : 26)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(active
                      ? Color.nAccent.opacity(0.16)
                      : (hovered ? Color.nElevated.opacity(0.9) : Color.clear))
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

/// The toolbar controls read as one designed object rather than a row of unrelated dropdowns.
struct MechanicianControlDeck<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(3)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.nSurface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.nMuted.opacity(0.42), lineWidth: 0.5)
            }
    }
}

struct MechanicianControlDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.nMuted.opacity(0.38))
            .frame(width: 1, height: 15)
            .accessibilityHidden(true)
    }
}

struct MechanicianControlChoice: Identifiable, Equatable {
    let id: String
    let title: String
    var detail: String? = nil
}

/// App-owned choice panel used for Effort and Permissions. Unlike a default macOS menu it can
/// explain provider semantics, show a stable selected state, and share Mechanician's visual system.
struct MechanicianControlChoicePopover: View {
    let title: String
    let choices: [MechanicianControlChoice]
    let selectedID: String
    var footer: String? = nil
    var footerActionTitle: String? = nil
    var onFooterAction: (() -> Void)? = nil
    let onSelect: (MechanicianControlChoice) -> Void
    @FocusState private var focusedChoiceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 4)
            VStack(spacing: 3) {
                ForEach(choices) { choice in
                    MechanicianControlChoiceRow(
                        choice: choice,
                        selected: choice.id == selectedID,
                        focus: $focusedChoiceID,
                        action: { onSelect(choice) })
                }
            }
            if let footer {
                Text(footer)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
            if let footerActionTitle, let onFooterAction {
                Button(footerActionTitle, action: onFooterAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.horizontal, 4)
            }
        }
        .padding(10)
        .frame(width: 320)
        .background(Color.nBg)
        .onAppear {
            focusedChoiceID = choices.contains(where: { $0.id == selectedID })
                ? selectedID
                : choices.first?.id
        }
        .onMoveCommand(perform: moveFocus)
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        guard !choices.isEmpty else { return }
        let current = choices.firstIndex(where: { $0.id == focusedChoiceID })
            ?? choices.firstIndex(where: { $0.id == selectedID })
            ?? 0
        switch direction {
        case .up:
            focusedChoiceID = choices[(current - 1 + choices.count) % choices.count].id
        case .down:
            focusedChoiceID = choices[(current + 1) % choices.count].id
        default:
            break
        }
    }
}

private struct MechanicianControlChoiceRow: View {
    let choice: MechanicianControlChoice
    let selected: Bool
    let focus: FocusState<String?>.Binding
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: choice.detail == nil ? .center : .top, spacing: 9) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Color.nAccent : Color.secondary.opacity(0.5))
                    .frame(width: 15)
                    .padding(.top, choice.detail == nil ? 0 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(Color.nText)
                    if let detail = choice.detail {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, choice.detail == nil ? 7 : 8)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected
                          ? Color.nAccent.opacity(0.12)
                          : (hovered ? Color.nElevated.opacity(0.75) : Color.clear))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused(focus, equals: choice.id)
        .onHover { hovered = $0 }
        .accessibilityLabel(choice.title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Formerly forced the window to a dark Nord appearance. Now a no-op kept for call-site
/// compatibility: the app follows the system Light/Dark setting and uses native window
/// chrome. (Delete once no view references it.)
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
