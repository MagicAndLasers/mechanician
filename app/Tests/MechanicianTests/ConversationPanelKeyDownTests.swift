import AppKit
import XCTest
@testable import Mechanician

/// `where` binds to the last pattern of a comma-separated `case`, not to all of them.
///
/// Written as `case 51, 117 where selectedRow >= 0`, the guard covered only ⌦ — plain ⌫ invoked the
/// delete handler with nothing selected. That matters because the delete path falls back to the
/// right-clicked row, so an unguarded ⌫ could act on a conversation the user never selected.
@MainActor
final class ConversationPanelKeyDownTests: XCTestCase {
    private enum Key {
        static let delete: UInt16 = 51        // ⌫
        static let forwardDelete: UInt16 = 117 // ⌦
        static let ret: UInt16 = 36            // ⏎
        static let a: UInt16 = 0               // A
        static let unrelated: UInt16 = 49      // space
    }

    private func keyDown(
        _ code: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        characters: String = ""
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code))
    }

    /// An empty table reports `selectedRow == -1`, which is the state the guard exists for.
    private func makeTable() -> ConversationNSTableView {
        _ = NSApplication.shared
        let table = ConversationNSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        XCTAssertEqual(table.selectedRow, -1)
        return table
    }

    func testDeleteKeysDoNothingWithoutASelection() throws {
        let table = makeTable()
        var deletes = 0
        table.onDeleteKey = { deletes += 1 }

        table.keyDown(with: try keyDown(Key.delete))
        table.keyDown(with: try keyDown(Key.forwardDelete))

        XCTAssertEqual(
            deletes,
            0,
            "⌫ must be guarded by the selection exactly as ⌦ is; the delete path falls back to the "
                + "clicked row, so an unguarded key can act on a conversation nobody selected.")
    }

    func testReturnDoesNothingWithoutASelection() throws {
        let table = makeTable()
        var returns = 0
        table.onReturnKey = { returns += 1 }

        table.keyDown(with: try keyDown(Key.ret))

        XCTAssertEqual(returns, 0)
    }

    /// The guard must not swallow the keys outright: with a row selected they still act, and an
    /// unrelated key never reaches either handler.
    func testSelectedRowRestoresBothHandlersAndLeavesOtherKeysAlone() throws {
        final class Rows: NSObject, NSTableViewDataSource {
            func numberOfRows(in tableView: NSTableView) -> Int { 3 }
        }
        let table = makeTable()
        let rows = Rows()
        table.dataSource = rows
        table.reloadData()
        table.selectRowIndexes([1], byExtendingSelection: false)
        XCTAssertEqual(table.selectedRow, 1)

        var deletes = 0
        var returns = 0
        table.onDeleteKey = { deletes += 1 }
        table.onReturnKey = { returns += 1 }

        table.keyDown(with: try keyDown(Key.delete))
        table.keyDown(with: try keyDown(Key.forwardDelete))
        table.keyDown(with: try keyDown(Key.ret))
        table.keyDown(with: try keyDown(Key.unrelated))

        XCTAssertEqual(deletes, 2, "Both delete keys act once a row is selected.")
        XCTAssertEqual(returns, 1)
    }

    /// This table-local fallback exists alongside the normal Edit ▸ Select All responder action.
    /// It is intentionally a table override rather than a SwiftUI command, so a focused composer,
    /// search field, or inline title editor keeps its native text-selection behavior.
    func testCommandAInvokesTheTableLocalSelectAllHandlerOnlyForPlainCommandA() throws {
        let table = makeTable()
        var selections = 0
        table.onSelectAll = { selections += 1 }

        table.keyDown(with: try keyDown(Key.a, modifiers: [.command], characters: "a"))
        table.keyDown(with: try keyDown(Key.a, characters: "a"))
        table.keyDown(with: try keyDown(
            Key.a,
            modifiers: [.command, .shift],
            characters: "a"))
        table.keyDown(with: try keyDown(
            Key.a,
            modifiers: [.command, .option],
            characters: "a"))

        XCTAssertEqual(selections, 1)
    }

    func testStandardSelectAllResponderActionUsesTheSameTableLocalHandler() {
        let table = makeTable()
        var selections = 0
        table.onSelectAll = { selections += 1 }

        table.selectAll(nil)

        XCTAssertEqual(selections, 1)
    }
}
