import AppKit
import XCTest
@testable import Mechanician

final class ComposerDeliveryMenuTests: XCTestCase {

    // MARK: item model

    func testGuideIsOfferedOnlyWhenTheTurnCanBeSteered() {
        let steerable = ComposerDeliveryMenuModel.items(canGuide: true, selected: .sendNext)
        let unsteerable = ComposerDeliveryMenuModel.items(canGuide: false, selected: .sendNext)

        XCTAssertEqual(
            steerable.map(\.action),
            [.guideCurrentTurn, .sendNext, .stopAndRedirect])
        XCTAssertEqual(
            unsteerable.map(\.action),
            [.sendNext, .stopAndRedirect],
            "Offering guidance the provider cannot deliver would be a dead option.")
    }

    func testExactlyTheSelectedActionIsTicked() {
        for selected in [ComposerDeliveryAction.guideCurrentTurn, .sendNext, .stopAndRedirect] {
            let items = ComposerDeliveryMenuModel.items(canGuide: true, selected: selected)
            XCTAssertEqual(items.filter(\.isChecked).map(\.action), [selected])
        }
    }

    func testNothingIsTickedWhenNoTurnIsRunning() {
        // `.startTurn` is the plain-send state, which the menu does not list.
        let items = ComposerDeliveryMenuModel.items(canGuide: true, selected: .startTurn)
        XCTAssertTrue(items.allSatisfy { !$0.isChecked })
    }

    /// The destructive option is set apart from the two that let the running turn finish.
    func testOnlyStopAndRedirectStartsANewSection() {
        for canGuide in [true, false] {
            let items = ComposerDeliveryMenuModel.items(canGuide: canGuide, selected: .sendNext)
            XCTAssertEqual(items.filter(\.startsSection).map(\.action), [.stopAndRedirect])
        }
    }

    func testEachOptionKeepsItsOwnRoadSign() {
        let items = ComposerDeliveryMenuModel.items(canGuide: true, selected: .sendNext)
        XCTAssertEqual(
            items.map(\.icon), [.curveAhead, .yield, .detour],
            "The menu must use the same glyphs as the send button it belongs to.")
    }

    // MARK: built NSMenu

    @MainActor
    private func makeView(
        canGuide: Bool,
        selected: ComposerDeliveryAction,
        choose: @escaping (ComposerDeliveryAction) -> Void = { _ in }
    ) -> ComposerDeliveryMenuView {
        let view = ComposerDeliveryMenuView(frame: NSRect(x: 0, y: 0, width: 22, height: 34))
        view.configure(canGuide: canGuide, selected: selected, choose: choose)
        return view
    }

    @MainActor
    func testMenuMirrorsTheModelIncludingSeparatorAndTicks() {
        let menu = makeView(canGuide: true, selected: .sendNext).buildMenu()

        XCTAssertEqual(
            menu.items.map(\.title),
            ["Guide current turn", "Send next", "", "Stop and redirect"])
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertEqual(menu.items.map(\.state), [.off, .on, .off, .off])
        // Every real option carries its road sign.
        for item in menu.items where !item.isSeparatorItem {
            XCTAssertNotNil(item.image)
        }
    }

    @MainActor
    func testMenuDropsGuidanceWhenTheTurnCannotBeSteered() {
        let menu = makeView(canGuide: false, selected: .stopAndRedirect).buildMenu()

        XCTAssertEqual(menu.items.map(\.title), ["Send next", "", "Stop and redirect"])
        XCTAssertFalse(menu.items[0].isSeparatorItem)
        XCTAssertTrue(menu.items[1].isSeparatorItem)
    }

    /// A separator must never lead the menu — dropping the guide item used to leave one stranded
    /// at the top if the section marker were attached to the wrong row.
    @MainActor
    func testMenuNeverOpensWithASeparator() {
        for canGuide in [true, false] {
            let menu = makeView(canGuide: canGuide, selected: .sendNext).buildMenu()
            XCTAssertFalse(menu.items.first?.isSeparatorItem ?? true)
        }
    }

    @MainActor
    func testChoosingAnItemReportsThatAction() {
        var chosen: [ComposerDeliveryAction] = []
        let view = makeView(canGuide: true, selected: .sendNext) { chosen.append($0) }
        let menu = view.buildMenu()

        for item in menu.items where !item.isSeparatorItem {
            _ = item.target?.perform(item.action, with: item)
        }

        XCTAssertEqual(chosen, [.guideCurrentTurn, .sendNext, .stopAndRedirect])
    }

    @MainActor
    func testControlIsReachableAsAPopUpButton() {
        let view = makeView(canGuide: true, selected: .sendNext)

        XCTAssertEqual(view.accessibilityRole(), .popUpButton)
        XCTAssertEqual(view.accessibilityLabel(), "Message delivery options")
        XCTAssertEqual(view.intrinsicContentSize, NSSize(width: 22, height: 34))
        XCTAssertNotNil(view.toolTip)
    }
}
