import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

@MainActor
final class FileBrowserMultiSelectionTests: XCTestCase {
    private final class SelectionBox {
        var value: Set<URL> = []
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for deferred file-browser selection delivery", file: file, line: line)
    }

    private func makeFiles(_ names: [String]) throws -> (dir: URL, urls: [URL]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileBrowserMultiSelectionTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls = try names.map { name -> URL in
            let url = dir.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return url
        }
        return (dir, urls)
    }

    private func makeOutline(
        root: URL,
        selection: SelectionBox,
        onPreviewSelection: @escaping (URL?) -> Void = { _ in }
    ) -> (FinderOutline, FinderOutlineView.Coordinator) {
        let browser = FinderOutlineView(
            root: root,
            selection: Binding(
                get: { selection.value },
                set: { selection.value = $0 }),
            reloadToken: 0,
            onActivate: { _, _ in },
            onRename: { _, _ in },
            onChanged: {},
            onPreviewSelection: onPreviewSelection,
            onQuickLook: { _ in },
            onInject: { _ in },
            onWatch: { _ in })
        let coordinator = browser.makeCoordinator()
        let outline = FinderOutline()
        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = coordinator
        outline.delegate = coordinator
        FinderOutlineView.configureSelection(on: outline)
        coordinator.outline = outline
        coordinator.rebuild(root: root)
        return (outline, coordinator)
    }

    func testNativeOutlineEnablesCommandAndShiftSelection() {
        let outline = FinderOutline()

        FinderOutlineView.configureSelection(on: outline)

        XCTAssertTrue(outline.allowsMultipleSelection)
        XCTAssertTrue(outline.allowsEmptySelection)
    }

    /// AppKit computes Command-toggle and Shift-range index sets. The coordinator must publish the
    /// complete set rather than collapsing every delegate callback back to `selectedRow`.
    func testCoordinatorPublishesReplacementExtensionToggleAndRangeSelections() throws {
        let made = try makeFiles(["a.txt", "b.txt", "c.txt"])
        defer { try? FileManager.default.removeItem(at: made.dir) }
        let selection = SelectionBox()
        let (outline, coordinator) = makeOutline(root: made.dir, selection: selection)
        _ = coordinator // retain the outline's weakly-held delegate for the complete interaction
        XCTAssertEqual(outline.numberOfRows, 3)

        outline.selectRowIndexes([0], byExtendingSelection: false)       // ordinary click
        XCTAssertEqual(selection.value.count, 1)

        outline.selectRowIndexes([2], byExtendingSelection: true)        // Command-add
        XCTAssertEqual(selection.value.count, 2)

        outline.deselectRow(0)                                           // Command-toggle off
        XCTAssertEqual(selection.value.count, 1)

        outline.selectRowIndexes(IndexSet(integersIn: 0 ... 2),
                                 byExtendingSelection: false)             // Shift-range
        XCTAssertEqual(
            Set(selection.value.map { $0.resolvingSymlinksInPath() }),
            Set(made.urls.map { $0.resolvingSymlinksInPath() }))

        outline.selectRowIndexes([1], byExtendingSelection: false)        // ordinary replacement
        XCTAssertEqual(
            Set(selection.value.map { $0.resolvingSymlinksInPath() }),
            [made.urls[1].resolvingSymlinksInPath()])
    }

    func testSelectionEchoShortCircuitsAndProgrammaticSelectionUsesTheNodeIndex() throws {
        let names = (0 ..< 200).map { String(format: "file-%03d.txt", $0) }
        let made = try makeFiles(names)
        defer { try? FileManager.default.removeItem(at: made.dir) }
        let selection = SelectionBox()
        let (outline, coordinator) = makeOutline(root: made.dir, selection: selection)
        XCTAssertEqual(outline.numberOfRows, names.count)

        outline.selectRowIndexes([137], byExtendingSelection: false)
        let nativeSelection = selection.value
        let lookupsBeforeEcho = coordinator.indexedSelectionLookupCount

        coordinator.syncSelection(nativeSelection)

        XCTAssertEqual(
            coordinator.indexedSelectionLookupCount,
            lookupsBeforeEcho,
            "An AppKit selection echoed through SwiftUI must not walk or look up the tree again.")

        outline.deselectAll(nil)
        let destination = made.urls[42]
        selection.value = [destination]
        let lookupsBeforeProgrammaticSelection = coordinator.indexedSelectionLookupCount

        coordinator.syncSelection(selection.value)

        XCTAssertEqual(
            coordinator.indexedSelectionLookupCount,
            lookupsBeforeProgrammaticSelection + 1,
            "Selection reconciliation should perform one indexed lookup per requested URL.")
        XCTAssertTrue(coordinator.loadedNode(for: destination) === outline.item(atRow: outline.selectedRow) as? FileNode)
    }

    func testReloadPublishesARenamedFileEvenWhenItsSelectedRowIndexDoesNotChange() async throws {
        let made = try makeFiles(["before.txt"])
        defer { try? FileManager.default.removeItem(at: made.dir) }
        let selection = SelectionBox()
        var previewSelections: [URL?] = []
        let (outline, coordinator) = makeOutline(
            root: made.dir,
            selection: selection,
            onPreviewSelection: { previewSelections.append($0) })
        outline.selectRowIndexes([0], byExtendingSelection: false)
        XCTAssertTrue(
            previewSelections.isEmpty,
            "The representable must defer SwiftUI selection delivery until after its update turn.")
        await waitUntil { (previewSelections.last ?? nil) != nil }
        XCTAssertEqual(
            try XCTUnwrap(previewSelections.last ?? nil).resolvingSymlinksInPath(),
            made.urls[0].resolvingSymlinksInPath())

        let renamed = made.dir.appendingPathComponent("after.txt")
        try FileManager.default.moveItem(at: made.urls[0], to: renamed)
        selection.value = [renamed]

        coordinator.reloadKeepingExpansion()
        await waitUntil {
            (previewSelections.last ?? nil)?.lastPathComponent == "after.txt"
        }

        XCTAssertEqual(
            try XCTUnwrap(previewSelections.last ?? nil).resolvingSymlinksInPath(),
            renamed.resolvingSymlinksInPath())
    }

    func testPreviewRequiresExactlyOneSelectedItem() {
        let a = URL(fileURLWithPath: "/tmp/a")
        let b = URL(fileURLWithPath: "/tmp/b")

        XCTAssertNil(FileBrowserSelection.previewURL(in: []))
        XCTAssertEqual(FileBrowserSelection.previewURL(in: [a]), a)
        XCTAssertNil(FileBrowserSelection.previewURL(in: [a, b]))
    }

    func testRightClickInsideMultiSelectionTargetsEverythingInDisplayOrder() {
        let a = URL(fileURLWithPath: "/tmp/a")
        let b = URL(fileURLWithPath: "/tmp/b")
        let c = URL(fileURLWithPath: "/tmp/c")

        XCTAssertEqual(
            FileBrowserSelection.actionTargets(clicked: b, selectedInDisplayOrder: [a, b]),
            [a, b])
        XCTAssertEqual(
            FileBrowserSelection.actionTargets(clicked: c, selectedInDisplayOrder: [a, b]),
            [c],
            "A context menu outside the selection must not unexpectedly mutate the selected files.")
    }

    func testBulkTrashTitleReportsItsScope() {
        XCTAssertEqual(FileBrowserSelection.trashTitle(count: 1), "Move to Trash")
        XCTAssertEqual(FileBrowserSelection.trashTitle(count: 3), "Move 3 Items to Trash")
    }

    func testCommandDeleteUsesBatchTrashButPlainDeleteRemainsNative() throws {
        final class Rows: NSObject, NSOutlineViewDataSource {
            func outlineView(_ outlineView: NSOutlineView,
                             numberOfChildrenOfItem item: Any?) -> Int { item == nil ? 2 : 0 }
            func outlineView(_ outlineView: NSOutlineView,
                             child index: Int, ofItem item: Any?) -> Any { NSString(string: "\(index)") }
            func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
        }
        _ = NSApplication.shared
        let outline = FinderOutline()
        let rows = Rows()
        outline.addTableColumn(NSTableColumn(identifier: .init("name")))
        outline.dataSource = rows
        FinderOutlineView.configureSelection(on: outline)
        outline.reloadData()
        outline.selectRowIndexes([0, 1], byExtendingSelection: false)
        var trashCalls = 0
        outline.onTrash = { trashCalls += 1 }

        func event(modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 51))
        }

        outline.keyDown(with: try event(modifiers: []))
        XCTAssertEqual(trashCalls, 0)
        outline.keyDown(with: try event(modifiers: [.command]))
        XCTAssertEqual(trashCalls, 1)
    }
}
