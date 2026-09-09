import AppKit
import SwiftUI

/// `PillButtonStyle` as an `NSButton`.
///
/// The memory review moved to an `NSTableView` and its Accept and Reject controls became stock
/// `NSButton`s with `.rounded` bezels, because that is what an `NSButton` looks like when nobody
/// says otherwise. The window went from the app's own capsules to system push buttons in one commit
/// and nothing failed, which is the same silent-regression shape as a migration dropping a call
/// site: the build stays green while the surface changes underneath it.
///
/// The numbers here are not an approximation. They are read off `PillButtonStyle`
/// (`Theme.swift:455`) so the two treatments are one treatment: 13pt medium, 14 by 7 padding, a
/// capsule, accent at 0.16 rising to 0.26 on hover and 0.30 while pressed, plain transparent until
/// hovered, and destructive at a legible restrained wash. If that style changes, this has to change with it, which is what the test in
/// `MemoryReviewControlTests` is for.
final class AppKitPillButton: NSButton {
    enum Kind: Equatable { case accent, plain, destructive }

    private let kind: Kind
    private let symbolName: String?
    private let iconAccessibilityLabel: String?
    private var hovered = false
    private var tracking: NSTrackingArea?

    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let horizontalPadding: CGFloat = 14
    static let height: CGFloat = 30
    /// Text actions follow the app's capsule language. Tiny glyph actions belong to the compact
    /// control language instead: a softly rounded rectangle with a visible hairline, not a circle
    /// made by squeezing that capsule into a square. Keeping these dimensions here makes reuse in
    /// native cells deliberate rather than an assortment of one-off icon hit targets.
    static let iconWidth: CGFloat = 26
    static let iconHeight: CGFloat = 26
    static let iconCornerRadius: CGFloat = 7

    override var isHighlighted: Bool {
        didSet { guard isHighlighted != oldValue else { return }; refreshFill() }
    }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            hovered = isEnabled && hovered
            refreshFill()
        }
    }

    init(kind: Kind, title: String, target: AnyObject?, action: Selector) {
        self.kind = kind
        symbolName = nil
        iconAccessibilityLabel = nil
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .exterior
        wantsLayer = true
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        setTitle(title)
        refreshFill()
    }

    /// A compact, still-recognizably Mechanician control. Icon-only affordances must retain their
    /// full spoken and hover name; the visual title is intentionally empty so the icon is the
    /// visible label rather than a tiny decoration beside duplicated prose.
    init(
        kind: Kind,
        symbolName: String,
        accessibilityLabel: String,
        target: AnyObject?,
        action: Selector
    ) {
        self.kind = kind
        self.symbolName = symbolName
        iconAccessibilityLabel = accessibilityLabel
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .exterior
        wantsLayer = true
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        toolTip = accessibilityLabel
        setAccessibilityLabel(accessibilityLabel)
        refreshIcon()
        refreshFill()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setTitle(_ title: String) {
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: Self.font, .foregroundColor: NSColor(foreground)])
        setAccessibilityLabel(title)
    }

    /// The width this button needs for a title, so a caller can reserve it BEFORE laying out the
    /// text beside it. Reserving the wrong amount is what drew statements underneath these controls.
    static func width(for title: String) -> CGFloat {
        let measured = NSAttributedString(string: title, attributes: [.font: font])
            .size().width
        return ceil(measured) + horizontalPadding * 2
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = symbolName == nil
            ? bounds.height / 2
            : Self.iconCornerRadius
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = isEnabled; refreshFill() }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshFill() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The fill is a resolved CGColor, so it does not follow a light/dark switch on its own.
        if symbolName != nil {
            refreshIcon()
        } else {
            setTitle(attributedTitle.string)
        }
        refreshFill()
    }

    private func refreshIcon() {
        guard let symbolName, let iconAccessibilityLabel else { return }
        let icon = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: iconAccessibilityLabel) ?? NSImage()
        icon.isTemplate = true
        icon.size = NSSize(width: 13, height: 13)
        image = icon
        contentTintColor = NSColor(foreground)
        setAccessibilityLabel(iconAccessibilityLabel)
        toolTip = iconAccessibilityLabel
    }

    private var foreground: Color {
        switch kind {
        case .accent: .nInfoText
        case .plain: .nText
        case .destructive: .nErrorText
        }
    }

    private func refreshFill() {
        if symbolName != nil {
            refreshIconControlAppearance()
            return
        }

        let fill: Color
        switch kind {
        case .accent:
            fill = Color.nAccent.opacity(isHighlighted ? 0.30 : (hovered ? 0.26 : 0.16))
        case .plain:
            fill = hovered ? Color.nElevated.opacity(0.55) : Color.clear
        case .destructive:
            // A truth-maintenance action must read as an action before it is hovered. A completely
            // clear "No longer true" capsule looked like a sentence about the statement itself.
            fill = Color.nErrorText.opacity(isHighlighted ? 0.24 : (hovered ? 0.18 : 0.11))
        }
        layer?.backgroundColor = NSColor(fill).cgColor
        layer?.borderWidth = 0
        alphaValue = isEnabled ? 1 : 0.45
    }

    /// Icon actions are a compact native control family, not miniaturised text pills. The subtle
    /// stroke keeps their hit targets legible at rest; hover and pressed states strengthen one
    /// control at a time without turning the whole recall card into a band of bright bubbles.
    private func refreshIconControlAppearance() {
        let background: NSColor
        let border: NSColor
        let accent = NSColor(Color.nAccent)
        let elevated = NSColor(Color.nElevated)
        let muted = NSColor(Color.nMuted)
        let error = NSColor(Color.nErrorText)

        switch kind {
        case .accent:
            background = accent.withAlphaComponent(
                isHighlighted ? 0.22 : (hovered ? 0.16 : 0.10))
            border = accent.withAlphaComponent(hovered || isHighlighted ? 0.42 : 0.28)
        case .plain:
            background = elevated.withAlphaComponent(isHighlighted ? 0.95 : (hovered ? 0.78 : 0.48))
            border = muted.withAlphaComponent(hovered || isHighlighted ? 0.50 : 0.32)
        case .destructive:
            background = error.withAlphaComponent(
                isHighlighted ? 0.18 : (hovered ? 0.12 : 0.055))
            border = error.withAlphaComponent(hovered || isHighlighted ? 0.42 : 0.25)
        }

        layer?.backgroundColor = background.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = border.cgColor
        alphaValue = isEnabled ? 1 : 0.45
    }

    var kindForTesting: Kind { kind }
    var symbolNameForTesting: String? { symbolName }
    var isIconOnlyForTesting: Bool { symbolName != nil && attributedTitle.string.isEmpty }
}
