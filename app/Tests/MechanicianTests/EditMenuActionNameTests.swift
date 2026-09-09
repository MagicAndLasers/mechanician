import AppKit
import XCTest
@testable import Mechanician

/// Edit ▸ Undo used to read a bare "Undo" no matter what it was about to undo.
///
/// The title rewrite lives in `WorkspaceWindow.validateMenuItem`, which AppKit only calls for an
/// item whose action is `undo:`. The shipped items are SwiftUI buttons — deliberately, because a
/// disabled menu item does not fire its key equivalent and that would break ⌘Z in every text field
/// — so that override never ran for them and every `setActionName` in the app was invisible.
@MainActor
final class EditMenuActionNameTests: XCTestCase {
    private func editMenuBar(
        undoTitle: String = "Undo",
        redoTitle: String = "Redo",
        menuTitle: String = "Edit"
    ) -> NSMenu {
        let bar = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: menuTitle)
        let undo = NSMenuItem(title: undoTitle, action: nil, keyEquivalent: "z")
        undo.keyEquivalentModifierMask = [.command]
        let redo = NSMenuItem(title: redoTitle, action: nil, keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(undo)
        edit.addItem(redo)
        editItem.submenu = edit
        bar.addItem(editItem)
        return bar
    }

    private func titles(_ bar: NSMenu) -> (undo: String, redo: String) {
        let items = bar.items[0].submenu!.items
        return (items[0].title, items[1].title)
    }

    /// With nothing registered anywhere, the plain verbs are correct and must not be decorated.
    func testTitlesFallBackToThePlainVerbs() {
        let bar = editMenuBar(undoTitle: "Undo Something Stale", redoTitle: "Redo Something Stale")
        EditMenuActionNames.shared.refresh(mainMenu: bar, keyWindow: nil, activeBridge: nil)
        XCTAssertEqual(titles(bar).undo, "Undo")
        XCTAssertEqual(titles(bar).redo, "Redo")
    }

    /// The items are found by key equivalent, not by title — the title is the thing being replaced,
    /// so matching on it would work exactly once and then never again.
    func testItemsAreLocatedByKeyEquivalentRatherThanTitle() {
        let bar = editMenuBar(undoTitle: "Undo Delete Conversation",
                              redoTitle: "Redo Delete Conversation")
        EditMenuActionNames.shared.refresh(mainMenu: bar, keyWindow: nil, activeBridge: nil)
        XCTAssertEqual(titles(bar).undo, "Undo", "a previously written title must not stick")
        XCTAssertEqual(titles(bar).redo, "Redo")
    }

    /// A menu with no Edit submenu, or none matching, must be left alone rather than trapped.
    func testAnUnexpectedMenuShapeIsLeftAlone() {
        let bar = NSMenu()
        let item = NSMenuItem()
        let other = NSMenu(title: "File")
        let unrelated = NSMenuItem(title: "Save", action: nil, keyEquivalent: "s")
        other.addItem(unrelated)
        item.submenu = other
        bar.addItem(item)
        EditMenuActionNames.shared.refresh(mainMenu: bar, keyWindow: nil, activeBridge: nil)
        XCTAssertEqual(unrelated.title, "Save")
        EditMenuActionNames.shared.refresh(mainMenu: nil, keyWindow: nil, activeBridge: nil)
    }

    /// The Edit menu must be found without reading its title, because the title is translated.
    ///
    /// This used to match `submenu?.title == "Edit"`, which works in English and stops working the
    /// moment the app ships another language — at which point Undo/Redo silently keep the generic
    /// titles and the feature looks like it regressed rather than like a localization bug.
    func testTheEditMenuIsFoundWhateverItIsCalled() {
        for title in ["Édition", "Bearbeiten", "編集"] {
            let bar = editMenuBar(
                undoTitle: "stale", redoTitle: "stale", menuTitle: title)
            EditMenuActionNames.shared.refresh(mainMenu: bar, keyWindow: nil, activeBridge: nil)
            XCTAssertEqual(titles(bar).undo, "Undo", "not found when the menu is called \(title)")
            XCTAssertEqual(titles(bar).redo, "Redo")
        }
    }

    /// The names AppKit composes "Undo " in front of. These are what the menu now shows, so they
    /// are worth pinning: they are user-visible strings, not internal identifiers.
    ///
    /// They resolve through the string catalogue, so the plural forms are declared rather than
    /// written as `count == 1 ? …` — English needs two forms and several languages need up to six.
    ///
    /// **Only the plural form is asserted here, and that is not an oversight.** These go through
    /// `Bundle.main`, which under `xctest` is the test runner and carries no catalogue, so a lookup
    /// falls back to the key with its argument substituted. That fallback happens to be right for
    /// "other" and wrong for "one" — `actionName(count: 1)` reads "Delete 1 Conversations" here and
    /// "Delete Conversation" in the app, which `LocalizableCatalogTests` pins and the build step
    /// enforces. Asserting the singular in this file would only pin the fallback.
    func testTheRegisteredActionNamesReadAsMenuTitles() {
        XCTAssertEqual(ConversationDeleteUndo.actionName(count: 3), "Delete 3 Conversations")
        XCTAssertEqual(ConversationDeleteUndo.deleteAllActionName, "Delete All Conversations")
        XCTAssertEqual(ArtifactDeleteUndo.actionName(count: 2), "Delete 2 Artifacts")
        XCTAssertEqual(WorkspaceMoveUndo.actionName(conversations: 4), "Move 4 Conversations")
        XCTAssertEqual(WorkspaceMoveUndo.actionName(artifacts: 5), "Move 5 Artifacts")
        XCTAssertEqual(AmbientTaskDeleteUndo.actionName, "Delete Scheduled Task")
    }
}
