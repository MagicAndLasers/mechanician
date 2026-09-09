import SwiftUI
import AppKit

/// What the composer's delivery menu offers, independent of how it is presented.
///
/// Kept separate from the view so the item list — which options exist, which is ticked, where the
/// separator falls — can be asserted directly instead of inferred from a menu that has to be opened.
enum ComposerDeliveryMenuModel {
    struct Item: Equatable {
        let title: String
        let action: ComposerDeliveryAction
        let icon: ComposerRoadSignKind
        let isChecked: Bool
        /// A separator precedes this item. "Stop and redirect" is destructive to the running turn,
        /// so it is deliberately set apart from the two options that let the turn finish.
        let startsSection: Bool
    }

    static func items(
        canGuide: Bool,
        selected: ComposerDeliveryAction
    ) -> [Item] {
        var items: [Item] = []
        if canGuide {
            items.append(Item(
                title: "Guide current turn",
                action: .guideCurrentTurn,
                icon: .curveAhead,
                isChecked: selected == .guideCurrentTurn,
                startsSection: false))
        }
        items.append(Item(
            title: "Send next",
            action: .sendNext,
            icon: .yield,
            isChecked: selected == .sendNext,
            startsSection: false))
        items.append(Item(
            title: "Stop and redirect",
            action: .stopAndRedirect,
            icon: .detour,
            isChecked: selected == .stopAndRedirect,
            startsSection: true))
        return items
    }
}

/// The chevron beside the send button, presenting the delivery options as a real `NSMenu`.
///
/// This was a SwiftUI `Menu`. SwiftUI presents menus and popovers by driving an `NSPopover` from
/// inside the view update, which is what crashed this app once already: showing the popover ran
/// `NSWindow.addChildWindow` during an AppKit layout pass. `NSMenu.popUp` runs its own event loop
/// from a mouse event, outside any view update, so the reentrancy is gone.
final class ComposerDeliveryMenuView: NSView {
    private var canGuide = false
    private var selected: ComposerDeliveryAction = .startTurn
    private var choose: ((ComposerDeliveryAction) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "Choose how this message is delivered"
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Message delivery options")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 34) }

    func configure(
        canGuide: Bool,
        selected: ComposerDeliveryAction,
        choose: @escaping (ComposerDeliveryAction) -> Void
    ) {
        self.canGuide = canGuide
        self.selected = selected
        self.choose = choose
    }

    override func draw(_ dirtyRect: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
        guard let chevron = NSImage(
            systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = chevron.size
        chevron.draw(at: NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2), from: .zero,
            operation: .sourceOver, fraction: 1)
    }

    /// On mouse *down*, matching every other pull-down control on the platform.
    override func mouseDown(with event: NSEvent) {
        let menu = buildMenu()
        // Hang the menu off the bottom-left of the chevron; AppKit flips it above when the
        // composer is near the bottom of the screen.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in ComposerDeliveryMenuModel.items(canGuide: canGuide, selected: selected) {
            if item.startsSection, menu.numberOfItems > 0 {
                menu.addItem(.separator())
            }
            let menuItem = NSMenuItem(
                title: item.title, action: #selector(pick(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.action
            menuItem.state = item.isChecked ? .on : .off
            menuItem.image = Self.icon(item.icon)
            menu.addItem(menuItem)
        }
        return menu
    }

    /// Rendered from the same SwiftUI glyph the send button uses, so the menu and the button it
    /// belongs to cannot drift apart. 16pt is the standard menu-image size and gives the diamond
    /// signs enough room for the arrows they enclose.
    static let iconSize: CGFloat = 16

    static func icon(_ kind: ComposerRoadSignKind) -> NSImage? {
        ComposerRoadSignImage.image(kind: kind, size: iconSize)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ComposerDeliveryAction else { return }
        choose?(action)
    }
}

struct ComposerDeliveryMenuButton: NSViewRepresentable {
    let canGuide: Bool
    let selected: ComposerDeliveryAction
    let choose: (ComposerDeliveryAction) -> Void

    func makeNSView(context: Context) -> ComposerDeliveryMenuView {
        let view = ComposerDeliveryMenuView()
        view.configure(canGuide: canGuide, selected: selected, choose: choose)
        return view
    }

    func updateNSView(_ nsView: ComposerDeliveryMenuView, context: Context) {
        nsView.configure(canGuide: canGuide, selected: selected, choose: choose)
        nsView.needsDisplay = true
    }
}
