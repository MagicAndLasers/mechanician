import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Mechanician

final class AppKitArtifactBrowserTests: XCTestCase {
    private func artifact(
        _ title: String,
        type: String,
        favorite: Bool = false,
        cwd: String = ""
    ) -> Artifact {
        Artifact(
            title: title,
            type: type,
            source: "source for \(title)",
            favorite: favorite,
            cwd: cwd)
    }

    @MainActor
    private func browser(
        artifacts: [Artifact],
        organization: ArtifactOrganization,
        selection: Binding<ArtifactListSelection>
    ) -> AppKitArtifactBrowser {
        AppKitArtifactBrowser(
            groups: [ArtifactGroup(id: "all", title: "", artifacts: artifacts)],
            organization: organization,
            selection: selection,
            projects: [],
            onSort: { _, _ in },
            onFavorite: { _, _ in },
            onRename: { _, _ in },
            onDuplicate: { _ in },
            onMove: { _, _ in },
            onMoveToNewWorkspace: { _ in },
            onOpenWorkspace: { _ in },
            onDelete: { _ in },
            onImport: { _ in },
            onQuickLook: { _ in })
    }

    @MainActor
    private func outline(
        for browser: AppKitArtifactBrowser
    ) -> (ArtifactOutlineView, AppKitArtifactBrowser.Coordinator) {
        let outline = ArtifactOutlineView(frame: NSRect(x: 0, y: 0, width: 760, height: 240))
        for definition in ArtifactBrowserColumn.allCases {
            let column = NSTableColumn(identifier: .init(definition.rawValue))
            column.width = definition.defaultWidth
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumn(
            withIdentifier: .init(ArtifactBrowserColumn.name.rawValue))
        let coordinator = browser.makeCoordinator()
        coordinator.outline = outline
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.apply(parent: browser, reload: true)
        return (outline, coordinator)
    }

    func testColumnDefinitionsHaveStableIdentityGeometryAndSortMapping() {
        let columns = ArtifactBrowserColumn.allCases

        XCTAssertEqual(
            columns.map(\.rawValue),
            ["name", "favorite", "type", "size", "modified", "created"])
        XCTAssertEqual(ArtifactBrowserColumn.autosaveName, "global-artifacts.columns.v1")
        XCTAssertEqual(
            columns.map { $0.sort?.rawValue },
            ["name", nil, "type", "size", "modified", "created"])
        XCTAssertEqual(
            columns.map(\.defaultWidth),
            [240, 30, 90, 78, 150, 150])
        XCTAssertEqual(
            columns.map(\.minimumWidth),
            [140, 26, 58, 54, 104, 104])
        XCTAssertEqual(
            columns.map(\.canHide),
            [false, true, true, true, true, true])
        XCTAssertEqual(ArtifactBrowserColumn.favorite.maximumWidth, 44)
        XCTAssertEqual(ArtifactBrowserColumn.name.maximumWidth, .greatestFiniteMagnitude)
        XCTAssertEqual(ArtifactBrowserColumn.favorite.title, "")
        XCTAssertTrue(columns.filter { $0 != .favorite }.allSatisfy { !$0.title.isEmpty })

        XCTAssertEqual(ArtifactBrowserColumn.name.sort?.defaultsAscending, true)
        XCTAssertEqual(ArtifactBrowserColumn.type.sort?.defaultsAscending, true)
        XCTAssertEqual(ArtifactBrowserColumn.size.sort?.defaultsAscending, false)
        XCTAssertEqual(ArtifactBrowserColumn.modified.sort?.defaultsAscending, false)
        XCTAssertEqual(ArtifactBrowserColumn.created.sort?.defaultsAscending, false)
    }

    @MainActor
    func testCustomRowMetricsKeepDetailedContentOutOfTheSystemSmallRow() {
        let outline = NSOutlineView()
        outline.rowSizeStyle = .small

        ArtifactBrowserRowMetrics.configure(outline)
        outline.rowHeight = ArtifactBrowserRowMetrics.height(for: .detailed)

        XCTAssertEqual(outline.rowSizeStyle, .custom)
        XCTAssertFalse(outline.usesAutomaticRowHeights)
        XCTAssertEqual(outline.rowHeight, ArtifactBrowserRowMetrics.detailedHeight)

        outline.rowHeight = ArtifactBrowserRowMetrics.height(for: .compact)
        XCTAssertEqual(outline.rowHeight, ArtifactBrowserRowMetrics.compactHeight)
    }

    func testSingleHTMLContextMenuOffersTheCompleteFileAndWorkspaceActions() {
        let item = artifact(
            "Dashboard",
            type: "HTML",
            cwd: "/tmp/example-workspace")

        XCTAssertEqual(
            ArtifactBrowserMenuModel.sections(for: [item]),
            [
                [.showPreview, .open, .quickLook],
                [.favorite(true), .rename, .duplicate, .moveToWorkspace],
                [.share, .saveToFile, .saveAsPDF],
                [.copyFile, .copySource, .copyLink],
                [.revealInFinder, .openWorkspaceFolder],
                [.delete],
            ])
    }

    func testSingleNonHTMLContextMenuOmitsPDFAndMissingWorkspaceActions() {
        let item = artifact("Notes", type: "markdown", favorite: true)

        XCTAssertEqual(
            ArtifactBrowserMenuModel.sections(for: [item]),
            [
                [.showPreview, .open, .quickLook],
                [.favorite(false), .rename, .duplicate, .moveToWorkspace],
                [.share, .saveToFile],
                [.copyFile, .copySource, .copyLink],
                [.revealInFinder],
                [.delete],
            ])
    }

    func testBulkContextMenuUsesOnlyActionsThatApplyToTheWholeSelection() {
        let items = [
            artifact("Dashboard", type: "html", cwd: "/tmp/workspace"),
            artifact("Diagram", type: "svg", favorite: true, cwd: "/tmp/workspace"),
        ]

        XCTAssertEqual(
            ArtifactBrowserMenuModel.sections(for: items),
            [
                [.showPreview, .open],
                [.favorite(true), .duplicate, .moveToWorkspace],
                [.share],
                [.copyFile, .copySource],
                [.revealInFinder],
                [.delete],
            ])
        XCTAssertEqual(ArtifactBrowserMenuModel.sections(for: []), [])
    }

    func testDuplicateTitlesUseFinderStyleNumberedNamesWithoutCollisions() {
        XCTAssertEqual(
            artifactDuplicateTitle(for: "Roadmap", existingTitles: ["Roadmap"]),
            "Roadmap copy")
        XCTAssertEqual(
            artifactDuplicateTitle(
                for: "Roadmap",
                existingTitles: ["Roadmap", "Roadmap copy", "Roadmap copy 2"]),
            "Roadmap copy 3")

        var existing = Set(["Roadmap"])
        let first = artifactDuplicateTitle(for: "Roadmap", existingTitles: existing)
        existing.insert(first)
        let second = artifactDuplicateTitle(for: "Roadmap", existingTitles: existing)
        XCTAssertEqual([first, second], ["Roadmap copy", "Roadmap copy 2"])
    }

    func testSelectionSynchronizationKeepsAValidPrimaryAndAnchor() {
        let first = UUID()
        let second = UUID()
        var selection = ArtifactListSelection()

        selection.synchronize(ids: [first, second], primary: second)
        XCTAssertEqual(selection.ids, [first, second])
        XCTAssertEqual(selection.primary, second)
        XCTAssertEqual(selection.anchor, second)

        selection.synchronize(ids: [first], primary: second)
        XCTAssertEqual(selection.ids, [first])
        XCTAssertEqual(selection.primary, first)
        XCTAssertEqual(selection.anchor, first)

        selection.synchronize(ids: [], primary: first)
        XCTAssertTrue(selection.ids.isEmpty)
        XCTAssertNil(selection.primary)
        XCTAssertNil(selection.anchor)
    }

    @MainActor
    func testDensityChangeReconfiguresExistingNativeNameCells() throws {
        _ = NSApplication.shared
        let item = artifact("Density", type: "markdown")
        var selection = ArtifactListSelection()
        let binding = Binding(
            get: { selection },
            set: { selection = $0 })
        let detailed = browser(
            artifacts: [item],
            organization: ArtifactOrganization(density: .detailed),
            selection: binding)
        let (outline, coordinator) = outline(for: detailed)

        func subtitleField() throws -> NSTextField {
            let cell = try XCTUnwrap(outline.view(
                atColumn: 0,
                row: 0,
                makeIfNecessary: true))
            return try XCTUnwrap(cell.subviews.compactMap { $0 as? NSTextField }
                .first { $0.stringValue != item.title })
        }

        outline.selectRowIndexes([0], byExtendingSelection: false)
        let detailedCell = try XCTUnwrap(outline.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true))
        detailedCell.layoutSubtreeIfNeeded()
        let visibleFields = detailedCell.subviews
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden }
        XCTAssertEqual(visibleFields.count, 2)
        for field in visibleFields {
            XCTAssertGreaterThanOrEqual(field.frame.minY, detailedCell.bounds.minY - 0.5)
            XCTAssertLessThanOrEqual(field.frame.maxY, detailedCell.bounds.maxY + 0.5)
            XCTAssertGreaterThanOrEqual(field.frame.minX, detailedCell.bounds.minX - 0.5)
            XCTAssertLessThanOrEqual(field.frame.maxX, detailedCell.bounds.maxX + 0.5)
        }
        let title = try XCTUnwrap(visibleFields.first { $0.stringValue == item.title })
        XCTAssertEqual(title.lineBreakMode, .byTruncatingTail)
        XCTAssertFalse(try subtitleField().isHidden)
        XCTAssertEqual(outline.rowHeight, ArtifactBrowserRowMetrics.detailedHeight)
        XCTAssertEqual(
            outline.rect(ofRow: 0).height,
            ArtifactBrowserRowMetrics.detailedHeight)

        let compact = browser(
            artifacts: [item],
            organization: ArtifactOrganization(density: .compact),
            selection: binding)
        coordinator.apply(parent: compact, reload: false)

        XCTAssertTrue(try subtitleField().isHidden)
        XCTAssertEqual(outline.rowHeight, ArtifactBrowserRowMetrics.compactHeight)
        XCTAssertEqual(
            outline.rect(ofRow: 0).height,
            ArtifactBrowserRowMetrics.compactHeight)
    }

    @MainActor
    func testCommandOpenIsConsumedOnlyWhileTheNativeOutlineIsFocused() throws {
        _ = NSApplication.shared
        let item = artifact("Open", type: "markdown")
        var selection = ArtifactListSelection()
        let binding = Binding(
            get: { selection },
            set: { selection = $0 })
        var opens = 0
        let browser = browser(
            artifacts: [item],
            organization: ArtifactOrganization(),
            selection: binding)
        let (outline, _) = outline(for: browser)
        outline.onOpen = { opens += 1 }
        outline.selectRowIndexes([0], byExtendingSelection: false)

        let window = NSWindow(
            contentRect: outline.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView = outline
        XCTAssertTrue(window.makeFirstResponder(outline))
        let commandOpen = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "o",
            charactersIgnoringModifiers: "o",
            isARepeat: false,
            keyCode: 31))

        XCTAssertTrue(outline.performKeyEquivalent(with: commandOpen))
        XCTAssertEqual(opens, 1)

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        outline.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        _ = outline.performKeyEquivalent(with: commandOpen)
        XCTAssertEqual(opens, 1, "A search/editor field must retain its own menu key equivalents.")
    }

    @MainActor
    func testRightClickOutsideSelectionSelectsThatRowButPreservesAMultiSelection() throws {
        _ = NSApplication.shared
        let items = [
            artifact("First", type: "markdown"),
            artifact("Second", type: "markdown"),
        ]
        var selection = ArtifactListSelection()
        let binding = Binding(
            get: { selection },
            set: { selection = $0 })
        let browser = browser(
            artifacts: items,
            organization: ArtifactOrganization(sort: .name, ascending: true),
            selection: binding)
        let (outline, _) = outline(for: browser)
        outline.menu = NSMenu()
        let window = NSWindow(
            contentRect: outline.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView = outline

        func rightClick(row: Int) throws {
            let point = NSPoint(
                x: outline.rect(ofRow: row).midX,
                y: outline.rect(ofRow: row).midY)
            let windowPoint = outline.convert(point, to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: windowPoint,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1))
            _ = outline.menu(for: event)
        }

        outline.selectRowIndexes([0], byExtendingSelection: false)
        try rightClick(row: 1)
        XCTAssertEqual(outline.selectedRowIndexes, [1])

        outline.selectRowIndexes([0, 1], byExtendingSelection: false)
        try rightClick(row: 1)
        XCTAssertEqual(outline.selectedRowIndexes, [0, 1])
    }

    @MainActor
    func testNativePasteboardItemCarriesARealFileAndTrustedArtifactReference() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AppKitArtifactBrowserTests-\(UUID().uuidString)",
                isDirectory: true)
        let supportRoot = root.appendingPathComponent("support", isDirectory: true)
        let exportRoot = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ArtifactStore(
            appSupportBaseOverride: supportRoot,
            watchesDirectory: false)
        defer {
            store.flushSaves()
            ArtifactActions.pruneTemporaryExports(root: exportRoot)
            try? FileManager.default.removeItem(at: root)
        }

        let source = "# Native drag\n\nCurrent durable source."
        let artifact = store.upsertFromAgent(
            title: "Native drag",
            type: "markdown",
            source: source,
            workspaceID: nil,
            conversationID: nil,
            conversationTitle: "",
            cwd: "")

        let item = try XCTUnwrap(ArtifactActions.pasteboardItem(
            for: artifact,
            temporaryRoot: exportRoot,
            artifactStore: store))
        let fileURLString = try XCTUnwrap(item.string(forType: .fileURL))
        let fileURL = try XCTUnwrap(URL(string: fileURLString))

        XCTAssertTrue(fileURL.isFileURL)
        XCTAssertTrue(ArtifactFileExport.contains(fileURL, in: exportRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(fileURL.lastPathComponent, "Native drag.md")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), source)

        let privateData = try XCTUnwrap(
            item.data(forType: ArtifactActions.referencePasteboardType))
        let itemReference = try XCTUnwrap(
            ArtifactDragReference.decodeProcessPrivate(privateData))
        XCTAssertTrue(itemReference.isTrustedForCurrentProcess)
        XCTAssertEqual(itemReference.artifactID, artifact.uuid)
        XCTAssertEqual(itemReference.sourceURL.standardizedFileURL, fileURL.standardizedFileURL)

        let pasteboard = NSPasteboard(name: .init(
            "AppKitArtifactBrowserTests.drag.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let references = ArtifactActions.references(from: pasteboard)
        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(references.first?.artifactID, artifact.uuid)
        XCTAssertEqual(references.first?.title, artifact.title)
        XCTAssertEqual(references.first?.type, artifact.type)
        XCTAssertEqual(references.first?.sourceURL.standardizedFileURL, fileURL.standardizedFileURL)
        XCTAssertEqual(references.first?.isTrustedForCurrentProcess, true)
    }

    @MainActor
    func testNativePasteboardItemKeepsFileURLWhenPrivateReferenceExceedsSigningBounds() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AppKitArtifactBrowserBoundsTests-\(UUID().uuidString)",
                isDirectory: true)
        let supportRoot = root.appendingPathComponent("support", isDirectory: true)
        let exportRoot = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ArtifactStore(
            appSupportBaseOverride: supportRoot,
            watchesDirectory: false)
        defer {
            store.flushSaves()
            ArtifactActions.pruneTemporaryExports(root: exportRoot)
            try? FileManager.default.removeItem(at: root)
        }

        let source = "The public file representation must survive."
        let artifact = store.upsertFromAgent(
            title: String(
                repeating: "x",
                count: ArtifactDragReference.maximumTitleBytes + 1),
            type: "markdown",
            source: source,
            workspaceID: nil,
            conversationID: nil,
            conversationTitle: "",
            cwd: "")

        let item = try XCTUnwrap(ArtifactActions.pasteboardItem(
            for: artifact,
            temporaryRoot: exportRoot,
            artifactStore: store))
        let fileURLString = try XCTUnwrap(item.string(forType: .fileURL))
        let fileURL = try XCTUnwrap(URL(string: fileURLString))

        XCTAssertTrue(fileURL.isFileURL)
        XCTAssertTrue(ArtifactFileExport.contains(fileURL, in: exportRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), source)
        XCTAssertNil(item.data(forType: ArtifactActions.referencePasteboardType))
        XCTAssertFalse(item.types.contains(ArtifactActions.referencePasteboardType))

        let pasteboard = NSPasteboard(name: .init(
            "AppKitArtifactBrowserBoundsTests.drag.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        XCTAssertNotNil(pasteboard.string(forType: .fileURL))
        XCTAssertNil(pasteboard.data(forType: ArtifactActions.referencePasteboardType))
    }

    func testSafeImportRejectsSymlinksAndOversizedRegularFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AppKitArtifactImportSafetyTests-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("target.md")
        try "# linked source".write(to: target, atomically: true, encoding: .utf8)
        let symlink = root.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        let oversized = root.appendingPathComponent("oversized.md")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(ArtifactActions.maximumImportFileBytes + 1))
        try handle.close()

        let result = ArtifactActions.imports(from: [symlink, oversized])

        XCTAssertTrue(result.ready.isEmpty)
        XCTAssertEqual(Set(result.skipped), ["alias.md", "oversized.md"])
    }

    func testSafeImportEnforcesFileCountAndBatchByteBudgets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AppKitArtifactImportBudgetTests-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let countURLs = try (0..<(ArtifactActions.maximumImportFiles + 2)).map { index in
            let url = root.appendingPathComponent("count-\(index).md")
            try Data("# \(index)".utf8).write(to: url)
            return url
        }
        let countResult = ArtifactActions.imports(from: countURLs)
        XCTAssertEqual(countResult.ready.count, ArtifactActions.maximumImportFiles)
        XCTAssertEqual(
            countResult.skipped,
            countURLs.suffix(2).map(\.lastPathComponent))

        let fullFile = Data(
            repeating: Character("x").asciiValue!,
            count: ArtifactActions.maximumImportFileBytes)
        let batchURLs = try (0..<5).map { index in
            let url = root.appendingPathComponent("batch-\(index).md")
            try fullFile.write(to: url)
            return url
        }
        let batchResult = ArtifactActions.imports(from: batchURLs)
        XCTAssertEqual(
            batchResult.ready.count,
            ArtifactActions.maximumImportBatchBytes / ArtifactActions.maximumImportFileBytes)
        XCTAssertEqual(batchResult.skipped, [batchURLs.last!.lastPathComponent])
    }
}
