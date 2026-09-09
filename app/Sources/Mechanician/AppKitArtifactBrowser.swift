import AppKit
import SwiftUI

enum ArtifactBrowserColumn: String, CaseIterable {
    case name
    case favorite
    case type
    case size
    case modified
    case created

    static let autosaveName = "global-artifacts.columns.v1"

    var title: String {
        switch self {
        case .name: return String(localized: "Name")
        case .favorite: return ""
        case .type: return String(localized: "Kind")
        case .size: return String(localized: "Size")
        case .modified: return String(localized: "Date Modified")
        case .created: return String(localized: "Date Created")
        }
    }

    var sort: ArtifactSort? {
        switch self {
        case .name: return .name
        case .favorite: return nil
        case .type: return .type
        case .size: return .size
        case .modified: return .modified
        case .created: return .created
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .name: return 240
        case .favorite: return 30
        case .type: return 90
        case .size: return 78
        case .modified, .created: return 150
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .name: return 140
        case .favorite: return 26
        case .type: return 58
        case .size: return 54
        case .modified, .created: return 104
        }
    }

    var maximumWidth: CGFloat {
        self == .favorite ? 44 : .greatestFiniteMagnitude
    }

    var canHide: Bool { self != .name }
}

/// The two-line artifact name cell needs a real custom row height. `NSTableView`'s `.small`
/// row-size style silently pins every row to the system's compact height, even after assigning a
/// larger `rowHeight`; that leaves the detailed subtitle outside the cell and clips it under the
/// next row.
enum ArtifactBrowserRowMetrics {
    static let compactHeight: CGFloat = 22
    static let detailedHeight: CGFloat = 38

    static func configure(_ outline: NSOutlineView) {
        outline.rowSizeStyle = .custom
        outline.usesAutomaticRowHeights = false
    }

    static func height(for density: ArtifactRowDensity) -> CGFloat {
        density == .compact ? compactHeight : detailedHeight
    }
}

enum ArtifactBrowserMenuAction: Equatable {
    case showPreview
    case open
    case quickLook
    case favorite(Bool)
    case rename
    case duplicate
    case moveToWorkspace
    case share
    case saveToFile
    case saveAsPDF
    case copyFile
    case copySource
    case copyLink
    case revealInFinder
    case openWorkspaceFolder
    case delete
}

/// Framework-independent menu policy. AppKit renders these sections, while tests can assert the
/// complete Finder-style action set without opening an `NSMenu`.
enum ArtifactBrowserMenuModel {
    static func sections(for artifacts: [Artifact]) -> [[ArtifactBrowserMenuAction]] {
        guard !artifacts.isEmpty else { return [] }
        let single = artifacts.count == 1
        let favorite = artifacts.contains { !$0.favorite }

        var open: [ArtifactBrowserMenuAction] = [.showPreview, .open]
        if single { open.append(.quickLook) }

        var organization: [ArtifactBrowserMenuAction] = [.favorite(favorite)]
        if single { organization.append(.rename) }
        organization += [.duplicate, .moveToWorkspace]

        var file: [ArtifactBrowserMenuAction] = [.share]
        if single {
            file.append(.saveToFile)
            if artifacts[0].type.lowercased() == "html" { file.append(.saveAsPDF) }
        }

        var copy: [ArtifactBrowserMenuAction] = [.copyFile, .copySource]
        if single { copy.append(.copyLink) }

        var location: [ArtifactBrowserMenuAction] = [.revealInFinder]
        if single, !artifacts[0].cwd.isEmpty { location.append(.openWorkspaceFolder) }

        return [open, organization, file, copy, location, [.delete]]
    }
}

/// Replaces only the artifact inventory with the AppKit object that owns the missing behavior:
/// column identity/geometry, native selection, responder keys, menus, and drag sessions. The
/// surrounding filters, preview and editor remain SwiftUI content.
@MainActor
struct AppKitArtifactBrowser: NSViewRepresentable {
    let groups: [ArtifactGroup]
    let organization: ArtifactOrganization
    @Binding var selection: ArtifactListSelection
    let projects: [Project]
    let onSort: (ArtifactSort, Bool) -> Void
    let onFavorite: (Set<UUID>, Bool) -> Void
    let onRename: (UUID, String) -> Void
    let onDuplicate: ([UUID]) -> Void
    let onMove: (Set<UUID>, WorkspaceDestination) -> Void
    let onMoveToNewWorkspace: (Set<UUID>) -> Void
    let onOpenWorkspace: (Artifact) -> Void
    let onDelete: (Set<UUID>) -> Void
    let onImport: ([URL]) -> Void
    let onQuickLook: (Artifact) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = ArtifactOutlineView()
        let coordinator = context.coordinator
        coordinator.outline = outline

        for definition in ArtifactBrowserColumn.allCases {
            let column = NSTableColumn(identifier: .init(definition.rawValue))
            column.title = definition.title
            column.width = definition.defaultWidth
            column.minWidth = definition.minimumWidth
            column.maxWidth = definition.maximumWidth
            column.resizingMask = .userResizingMask
            if let sort = definition.sort {
                column.sortDescriptorPrototype = NSSortDescriptor(
                    key: sort.rawValue,
                    ascending: sort.defaultsAscending)
            }
            if definition == .favorite {
                let label = String(localized: "Favorite")
                column.headerToolTip = label
                column.headerCell.setAccessibilityLabel(label)
            }
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumn(withIdentifier: .init(ArtifactBrowserColumn.name.rawValue))
        outline.headerView = NSTableHeaderView()
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.allowsColumnResizing = true
        outline.allowsColumnReordering = true
        outline.allowsColumnSelection = false
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.usesAlternatingRowBackgroundColors = true
        outline.indentationPerLevel = 12
        outline.floatsGroupRows = true
        outline.backgroundColor = .clear
        outline.autosaveName = ArtifactBrowserColumn.autosaveName
        outline.autosaveTableColumns = true
        // Column autosave also restores a prior sort descriptor. Install the delegate only after
        // restoration so that copy cannot overwrite ArtifactOrganizationStore while this
        // representable is still being constructed; `apply` installs the declared sort below.
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.identifier = .init("artifactBrowserOutline")
        outline.setAccessibilityLabel(String(localized: "Artifacts"))

        outline.target = coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked)
        outline.onOpen = { [weak coordinator] in coordinator?.openSelected() }
        outline.onQuickLook = { [weak coordinator] in coordinator?.quickLookSelected() }
        outline.onRename = { [weak coordinator] in coordinator?.renameSelected() }
        outline.onDelete = { [weak coordinator] in coordinator?.deleteSelected() }
        outline.onCopy = { [weak coordinator] in coordinator?.copySelected() }
        outline.onDuplicate = { [weak coordinator] in coordinator?.duplicateSelected() }
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setDraggingSourceOperationMask(.copy, forLocal: true)
        outline.registerForDraggedTypes([.fileURL])

        let menu = NSMenu()
        menu.delegate = coordinator
        outline.menu = menu
        coordinator.rowMenu = menu

        let headerMenu = NSMenu()
        headerMenu.delegate = coordinator
        outline.headerView?.menu = headerMenu
        coordinator.headerMenu = headerMenu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        coordinator.apply(parent: self, reload: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(parent: self, reload: false)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.rowMenu?.delegate = nil
        coordinator.headerMenu?.delegate = nil
        coordinator.outline?.dataSource = nil
        coordinator.outline?.delegate = nil
        coordinator.outline?.menu = nil
        coordinator.outline = nil
    }
}

@MainActor
final class ArtifactOutlineView: NSOutlineView {
    var onOpen: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDuplicate: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        ArtifactBrowserRowMetrics.configure(self)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        ArtifactBrowserRowMetrics.configure(self)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 49 where selectedRow >= 0:
            onQuickLook?()
        case 36 where selectedRow >= 0:
            onRename?()
        case 51 where selectedRow >= 0 && flags.contains(.command),
             117 where selectedRow >= 0 && flags.contains(.command):
            onDelete?()
        default:
            if flags.contains(.command), selectedRow >= 0 {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "o": onOpen?(); return
                case "c": onCopy?(); return
                case "d": onDuplicate?(); return
                default: break
                }
            }
            super.keyDown(with: event)
        }
    }

    /// Finder selects a right-clicked row when it is outside the current selection, while a click
    /// inside a multi-selection keeps the whole set as the context-menu target.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let hitRow = row(at: point)
        if hitRow >= 0,
           !selectedRowIndexes.contains(hitRow),
           (item(atRow: hitRow) as? ArtifactBrowserNode)?.artifactID != nil {
            selectRowIndexes([hitRow], byExtendingSelection: false)
        }
        return super.menu(for: event)
    }

    /// Main-menu key equivalents are resolved before `keyDown`. Consume file-browser commands in
    /// the focused outline so the app-wide ⌘O folder picker cannot win over "open this artifact."
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command,
              window?.firstResponder === self,
              selectedRow >= 0 else {
            return super.performKeyEquivalent(with: event)
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
            return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "o": onOpen?(); return true
        case "c": onCopy?(); return true
        case "d": onDuplicate?(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    @objc func copy(_ sender: Any?) {
        guard selectedRow >= 0 else { return }
        onCopy?()
    }

}

private final class ArtifactBrowserNode: NSObject {
    enum Kind {
        case group(id: String, title: String)
        case artifact(UUID)
    }

    var kind: Kind
    var children: [ArtifactBrowserNode] = []

    init(kind: Kind) {
        self.kind = kind
    }

    var artifactID: UUID? {
        guard case .artifact(let id) = kind else { return nil }
        return id
    }

    var groupID: String? {
        guard case .group(let id, _) = kind else { return nil }
        return id
    }
}

private struct ArtifactBrowserPresentation: Equatable {
    struct Row: Equatable {
        let id: UUID
        let title: String
        let type: String
        let size: Int
        let modified: Date
        let created: Date
        let favorite: Bool
        let subtitle: String
    }

    struct Group: Equatable {
        let id: String
        let title: String
        let rows: [Row]
    }

    let groups: [Group]
    let isGrouped: Bool
    let density: ArtifactRowDensity

    init(groups: [ArtifactGroup], isGrouped: Bool, density: ArtifactRowDensity) {
        self.isGrouped = isGrouped
        self.density = density
        self.groups = groups.map { group in
            Group(
                id: group.id,
                title: group.title,
                rows: group.artifacts.map { artifact in
                    Row(
                        id: artifact.uuid,
                        title: artifact.title,
                        type: artifact.type,
                        size: artifactSize(artifact),
                        modified: artifact.updatedAt,
                        created: artifact.createdAt,
                        favorite: artifact.favorite,
                        subtitle: artifactBrowserSubtitle(artifact))
                })
        }
    }
}

private func artifactBrowserSubtitle(_ artifact: Artifact) -> String {
    let owner = artifact.conversationTitle.isEmpty
        ? artifact.origin.capitalized
        : artifact.conversationTitle
    let folder = artifact.cwd.isEmpty ? "" : " · \((artifact.cwd as NSString).lastPathComponent)"
    return owner + folder
}

private let artifactBrowserDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

@MainActor
extension AppKitArtifactBrowser {
    @MainActor
    final class Coordinator: NSObject,
        NSOutlineViewDataSource,
        NSOutlineViewDelegate,
        NSTextFieldDelegate,
        NSMenuDelegate
    {
        var parent: AppKitArtifactBrowser
        weak var outline: ArtifactOutlineView?
        weak var rowMenu: NSMenu?
        weak var headerMenu: NSMenu?

        private var presentation: ArtifactBrowserPresentation?
        private var rootNodes: [ArtifactBrowserNode] = []
        private var artifactNodes: [UUID: ArtifactBrowserNode] = [:]
        private var groupNodes: [String: ArtifactBrowserNode] = [:]
        private var artifactsByID: [UUID: Artifact] = [:]
        private var orderedArtifactIDs: [UUID] = []
        private var isApplyingSelection = false
        private var isApplyingSort = false
        private var editingArtifactID: UUID?
        private var deferredReload = false

        init(_ parent: AppKitArtifactBrowser) {
            self.parent = parent
        }

        func apply(parent: AppKitArtifactBrowser, reload: Bool) {
            self.parent = parent
            guard let outline else { return }

            let nextPresentation = ArtifactBrowserPresentation(
                groups: parent.groups,
                isGrouped: parent.organization.grouping != .none,
                density: parent.organization.density)
            outline.rowHeight = ArtifactBrowserRowMetrics.height(for: parent.organization.density)
            let needsReload = reload || presentation != nextPresentation
            if needsReload, editingArtifactID != nil {
                // `reloadData` ends AppKit's field editor and would otherwise commit a half-typed
                // title as a user rename. Keep canonical action snapshots fresh, then redraw once
                // the actual edit session ends.
                deferredReload = true
                refreshArtifacts()
                syncSort()
                return
            }
            if needsReload {
                deferredReload = false
                let oldGrouping = presentation?.isGrouped
                let oldGroupIDs = Set(groupNodes.keys)
                let expandedGroupIDs = Set(rootNodes.compactMap { node -> String? in
                    guard let id = node.groupID, outline.isItemExpanded(node) else { return nil }
                    return id
                })

                rebuildNodes(from: nextPresentation)
                presentation = nextPresentation
                isApplyingSelection = true
                outline.reloadData()
                isApplyingSelection = false

                if nextPresentation.isGrouped {
                    let groupingChanged = oldGrouping != nextPresentation.isGrouped
                    for node in rootNodes {
                        guard let id = node.groupID else { continue }
                        if groupingChanged || oldGrouping == nil
                            || expandedGroupIDs.contains(id)
                            || !oldGroupIDs.contains(id) {
                            outline.expandItem(node)
                        }
                    }
                }
            } else {
                // Artifact values are used by actions and drags even when their visible metadata did
                // not change, so always refresh the canonical snapshots supplied by SwiftUI.
                refreshArtifacts()
            }

            syncSort()
            syncSelection()
        }

        private func rebuildNodes(from presentation: ArtifactBrowserPresentation) {
            refreshArtifacts()
            let availableArtifactIDs = Set(presentation.groups.flatMap(\.rows).map(\.id))
            artifactNodes = artifactNodes.filter { availableArtifactIDs.contains($0.key) }

            func artifactNode(_ id: UUID) -> ArtifactBrowserNode {
                if let node = artifactNodes[id] { return node }
                let node = ArtifactBrowserNode(kind: .artifact(id))
                artifactNodes[id] = node
                return node
            }

            orderedArtifactIDs = presentation.groups.flatMap(\.rows).map(\.id)
            if presentation.isGrouped {
                let grouping = parent.organization.grouping.rawValue
                var nextGroups: [String: ArtifactBrowserNode] = [:]
                rootNodes = presentation.groups.map { group in
                    let stableID = "\(grouping)\u{001F}\(group.id)"
                    let node = groupNodes[stableID]
                        ?? ArtifactBrowserNode(kind: .group(id: stableID, title: group.title))
                    node.kind = .group(id: stableID, title: group.title)
                    node.children = group.rows.map { artifactNode($0.id) }
                    nextGroups[stableID] = node
                    return node
                }
                groupNodes = nextGroups
            } else {
                groupNodes.removeAll(keepingCapacity: true)
                rootNodes = presentation.groups.flatMap(\.rows).map { artifactNode($0.id) }
            }
        }

        private func refreshArtifacts() {
            let artifacts = parent.groups.flatMap(\.artifacts)
            artifactsByID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.uuid, $0) })
        }

        // MARK: - Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? ArtifactBrowserNode else { return rootNodes.count }
            return node.children.count
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            child index: Int,
            ofItem item: Any?
        ) -> Any {
            guard let node = item as? ArtifactBrowserNode else { return rootNodes[index] }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? ArtifactBrowserNode else { return false }
            return node.groupID != nil
        }

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            (item as? ArtifactBrowserNode)?.groupID != nil
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            pasteboardWriterForItem item: Any
        ) -> NSPasteboardWriting? {
            guard let id = (item as? ArtifactBrowserNode)?.artifactID,
                  let artifact = artifactsByID[id] else { return nil }
            return ArtifactActions.pasteboardItem(for: artifact)
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            guard (info.draggingSource as? NSOutlineView) !== outline,
                  !isInternalArtifactDrag(info.draggingPasteboard),
                  info.draggingPasteboard.canReadObject(
                    forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]) else { return [] }
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            guard (info.draggingSource as? NSOutlineView) !== outline,
                  !isInternalArtifactDrag(info.draggingPasteboard) else { return false }
            let urls = (info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            guard !urls.isEmpty else { return false }
            parent.onImport(urls)
            return true
        }

        private func isInternalArtifactDrag(_ pasteboard: NSPasteboard) -> Bool {
            if !ArtifactActions.references(from: pasteboard).isEmpty { return true }
            let urls = (pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            return urls.contains {
                ArtifactFileExport.contains($0)
                    || ArtifactActions.reference(forExportedURL: $0) != nil
            }
        }

        // MARK: - Cells

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard let node = item as? ArtifactBrowserNode else { return nil }
            if case .group(_, let title) = node.kind {
                return groupCell(outlineView, title: title, count: node.children.count)
            }
            guard let id = node.artifactID,
                  let artifact = artifactsByID[id],
                  let column = tableColumn.flatMap({ ArtifactBrowserColumn(rawValue: $0.identifier.rawValue) })
            else { return nil }

            switch column {
            case .name:
                return nameCell(outlineView, artifact: artifact)
            case .favorite:
                return favoriteCell(outlineView, artifact: artifact)
            case .type:
                return textCell(
                    outlineView,
                    identifier: "artifactKindCell",
                    text: artifact.type.uppercased(),
                    alignment: .left)
            case .size:
                return textCell(
                    outlineView,
                    identifier: "artifactSizeCell",
                    text: artifactSizeLabel(artifact),
                    alignment: .right)
            case .modified:
                return dateCell(
                    outlineView,
                    identifier: "artifactModifiedCell",
                    date: artifact.updatedAt)
            case .created:
                return dateCell(
                    outlineView,
                    identifier: "artifactCreatedCell",
                    date: artifact.createdAt)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? ArtifactBrowserNode)?.artifactID != nil
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let node = item as? ArtifactBrowserNode else { return outlineView.rowHeight }
            return node.groupID == nil ? outlineView.rowHeight : 24
        }

        private func groupCell(_ outline: NSOutlineView, title: String, count: Int) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier("artifactGroupCell")
            let cell = (outline.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
                ?? {
                    let cell = NSTableCellView()
                    cell.identifier = identifier
                    let field = NSTextField(labelWithString: "")
                    field.translatesAutoresizingMaskIntoConstraints = false
                    field.font = .systemFont(ofSize: 11, weight: .semibold)
                    field.textColor = .secondaryLabelColor
                    field.lineBreakMode = .byTruncatingTail
                    cell.addSubview(field)
                    cell.textField = field
                    NSLayoutConstraint.activate([
                        field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                        field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                        field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    ])
                    return cell
                }()
            cell.textField?.stringValue = "\(title)  \(count)"
            cell.toolTip = title
            return cell
        }

        private func nameCell(_ outline: NSOutlineView, artifact: Artifact) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier("artifactNameCell")
            let cell = (outline.makeView(withIdentifier: identifier, owner: self) as? ArtifactNameCellView)
                ?? ArtifactNameCellView(identifier: identifier, delegate: self)
            cell.configure(
                artifact: artifact,
                detailed: parent.organization.density == .detailed)
            return cell
        }

        private func favoriteCell(_ outline: NSOutlineView, artifact: Artifact) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier("artifactFavoriteCell")
            let cell = (outline.makeView(withIdentifier: identifier, owner: self) as? ArtifactFavoriteCellView)
                ?? ArtifactFavoriteCellView(identifier: identifier, target: self)
            cell.configure(artifact: artifact)
            return cell
        }

        private func textCell(
            _ outline: NSOutlineView,
            identifier rawIdentifier: String,
            text: String,
            alignment: NSTextAlignment
        ) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier(rawIdentifier)
            let cell = (outline.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
                ?? {
                    let cell = NSTableCellView()
                    cell.identifier = identifier
                    let field = NSTextField(labelWithString: "")
                    field.translatesAutoresizingMaskIntoConstraints = false
                    field.font = .systemFont(ofSize: 11)
                    field.textColor = .secondaryLabelColor
                    field.lineBreakMode = .byTruncatingTail
                    cell.addSubview(field)
                    cell.textField = field
                    NSLayoutConstraint.activate([
                        field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                        field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                        field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    ])
                    return cell
                }()
            cell.textField?.stringValue = text
            cell.textField?.alignment = alignment
            cell.toolTip = text
            return cell
        }

        private func dateCell(
            _ outline: NSOutlineView,
            identifier: String,
            date: Date
        ) -> NSView {
            textCell(
                outline,
                identifier: identifier,
                text: artifactBrowserDateFormatter.string(from: date),
                alignment: .left)
        }

        // MARK: - Selection and responder actions

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection else { return }
            publishSelection()
        }

        private func selectedArtifactIDs() -> [UUID] {
            guard let outline else { return [] }
            return outline.selectedRowIndexes.compactMap { row in
                (outline.item(atRow: row) as? ArtifactBrowserNode)?.artifactID
            }
        }

        private func actionArtifacts(clicked id: UUID? = nil) -> [Artifact] {
            let selected = selectedArtifactIDs()
            let ids: [UUID]
            if let id, !selected.contains(id) {
                ids = [id]
            } else {
                ids = selected
            }
            return ids.compactMap { artifactsByID[$0] }
        }

        private func publishSelection(primary explicitPrimary: UUID? = nil) {
            guard let outline else { return }
            let ids = selectedArtifactIDs()
            let primary: UUID?
            if let explicitPrimary, ids.contains(explicitPrimary) {
                primary = explicitPrimary
            } else if outline.clickedRow >= 0,
                      let clicked = (outline.item(atRow: outline.clickedRow) as? ArtifactBrowserNode)?.artifactID,
                      ids.contains(clicked) {
                primary = clicked
            } else if let current = parent.selection.primary, ids.contains(current) {
                primary = current
            } else {
                primary = ids.first
            }

            var selection = parent.selection
            selection.synchronize(ids: Set(ids), primary: primary)
            parent.selection = selection
        }

        private func syncSelection() {
            guard let outline else { return }
            let desired = parent.selection.ids.intersection(orderedArtifactIDs)
            let current = Set(selectedArtifactIDs())
            guard current != desired else { return }

            var rows = IndexSet()
            for id in orderedArtifactIDs where desired.contains(id) {
                guard let node = artifactNodes[id] else { continue }
                if let group = outline.parent(forItem: node) {
                    outline.expandItem(group)
                }
                let row = outline.row(forItem: node)
                if row >= 0 { rows.insert(row) }
            }
            isApplyingSelection = true
            if rows.isEmpty {
                outline.deselectAll(nil)
            } else {
                outline.selectRowIndexes(rows, byExtendingSelection: false)
                if let primary = parent.selection.primary,
                   let node = artifactNodes[primary] {
                    let row = outline.row(forItem: node)
                    if row >= 0 { outline.scrollRowToVisible(row) }
                }
            }
            isApplyingSelection = false
        }

        @objc func doubleClicked() {
            guard let outline, outline.clickedRow >= 0,
                  let id = (outline.item(atRow: outline.clickedRow) as? ArtifactBrowserNode)?.artifactID
            else { return }
            ArtifactActions.openInDefaultApp(actionArtifacts(clicked: id))
        }

        func openSelected() {
            let artifacts = actionArtifacts()
            guard !artifacts.isEmpty else { return }
            ArtifactActions.openInDefaultApp(artifacts)
        }

        func quickLookSelected() {
            let artifacts = actionArtifacts()
            guard artifacts.count == 1, let artifact = artifacts.first else {
                NSSound.beep()
                return
            }
            parent.onQuickLook(artifact)
        }

        func renameSelected() {
            guard let outline, outline.selectedRowIndexes.count == 1,
                  let row = outline.selectedRowIndexes.first else { return }
            let column = outline.column(withIdentifier: .init(ArtifactBrowserColumn.name.rawValue))
            guard column >= 0 else { return }
            outline.editColumn(column, row: row, with: nil, select: true)
        }

        func deleteSelected() {
            let ids = Set(selectedArtifactIDs())
            guard !ids.isEmpty else { return }
            parent.onDelete(ids)
        }

        func copySelected() {
            let artifacts = actionArtifacts()
            guard !artifacts.isEmpty else { return }
            ArtifactActions.copyFiles(artifacts)
        }

        func duplicateSelected() {
            let ids = selectedArtifactIDs()
            guard !ids.isEmpty else { return }
            parent.onDuplicate(ids)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? ArtifactTitleField else { return }
            let id = field.editingArtifactID ?? field.artifactID
            field.editingArtifactID = nil
            editingArtifactID = nil
            defer { performDeferredReloadAfterEditing() }
            guard let id, let artifact = artifactsByID[id] else { return }
            let newTitle = field.stringValue
            if field.artifactID == id { field.stringValue = artifact.title }
            if newTitle != artifact.title { parent.onRename(id, newTitle) }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? ArtifactTitleField else { return }
            field.editingArtifactID = field.artifactID
            editingArtifactID = field.artifactID
        }

        private func performDeferredReloadAfterEditing() {
            guard deferredReload else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.deferredReload, self.editingArtifactID == nil else { return }
                self.apply(parent: self.parent, reload: true)
            }
        }

        @objc fileprivate func toggleFavorite(_ sender: ArtifactFavoriteButton) {
            guard let id = sender.artifactID,
                  let artifact = artifactsByID[id] else { return }
            parent.onFavorite([id], !artifact.favorite)
        }

        // MARK: - Sorting

        func outlineView(
            _ outlineView: NSOutlineView,
            sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            guard !isApplyingSort,
                  let descriptor = outlineView.sortDescriptors.first,
                  let key = descriptor.key,
                  let sort = ArtifactSort(rawValue: key) else { return }
            parent.onSort(sort, descriptor.ascending)
        }

        private func syncSort() {
            guard let outline else { return }
            let desired = NSSortDescriptor(
                key: parent.organization.sort.rawValue,
                ascending: parent.organization.ascending)
            if let current = outline.sortDescriptors.first,
               current.key == desired.key,
               current.ascending == desired.ascending,
               outline.sortDescriptors.count == 1 {
                return
            }
            isApplyingSort = true
            outline.sortDescriptors = [desired]
            isApplyingSort = false
        }

        // MARK: - Menus

        func menuNeedsUpdate(_ menu: NSMenu) {
            if menu === headerMenu {
                populateHeaderMenu(menu)
            } else {
                populateRowMenu(menu)
            }
        }

        private func populateHeaderMenu(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline else { return }
            for definition in ArtifactBrowserColumn.allCases where definition.canHide {
                let title = definition == .favorite
                    ? String(localized: "Favorites")
                    : definition.title
                let item = NSMenuItem(
                    title: title,
                    action: #selector(toggleColumn(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = definition.rawValue
                item.state = outline.tableColumn(withIdentifier: .init(definition.rawValue))?.isHidden == false
                    ? .on : .off
                menu.addItem(item)
            }
        }

        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let rawValue = sender.representedObject as? String,
                  let outline,
                  let column = outline.tableColumn(withIdentifier: .init(rawValue)) else { return }
            column.isHidden.toggle()
        }

        private func populateRowMenu(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, outline.clickedRow >= 0,
                  let clickedID = (outline.item(atRow: outline.clickedRow) as? ArtifactBrowserNode)?.artifactID
            else { return }
            let artifacts = actionArtifacts(clicked: clickedID)
            guard !artifacts.isEmpty else { return }
            let payload = ArtifactBrowserMenuPayload(
                clickedID: clickedID,
                ids: artifacts.map(\.uuid))

            for (sectionIndex, section) in ArtifactBrowserMenuModel.sections(for: artifacts).enumerated() {
                if sectionIndex > 0 { menu.addItem(.separator()) }
                for action in section {
                    if action == .moveToWorkspace {
                        menu.addItem(moveMenuItem(artifacts: artifacts, payload: payload))
                    } else {
                        menu.addItem(menuItem(for: action, artifacts: artifacts, payload: payload))
                    }
                }
            }
        }

        private func menuItem(
            for action: ArtifactBrowserMenuAction,
            artifacts: [Artifact],
            payload: ArtifactBrowserMenuPayload
        ) -> NSMenuItem {
            let count = artifacts.count
            let title: String
            let symbol: String
            let selector: Selector
            switch action {
            case .showPreview:
                title = String(localized: "Show in Preview")
                symbol = "sidebar.right"
                selector = #selector(menuShowPreview(_:))
            case .open:
                title = count == 1
                    ? String(localized: "Open in Default App")
                    : String(localized: "Open \(count) Artifacts")
                symbol = "arrow.up.forward.app"
                selector = #selector(menuOpen(_:))
            case .quickLook:
                title = String(localized: "Quick Look")
                symbol = "eye"
                selector = #selector(menuQuickLook(_:))
            case .favorite(let favorite):
                title = favorite
                    ? (count == 1
                        ? String(localized: "Favorite")
                        : String(localized: "Favorite \(count) Artifacts"))
                    : (count == 1
                        ? String(localized: "Unfavorite")
                        : String(localized: "Unfavorite \(count) Artifacts"))
                symbol = favorite ? "star" : "star.slash"
                selector = #selector(menuFavorite(_:))
                payload.favorite = favorite
            case .rename:
                title = String(localized: "Rename")
                symbol = "pencil"
                selector = #selector(menuRename(_:))
            case .duplicate:
                title = count == 1
                    ? String(localized: "Duplicate")
                    : String(localized: "Duplicate \(count) Artifacts")
                symbol = "plus.square.on.square"
                selector = #selector(menuDuplicate(_:))
            case .moveToWorkspace:
                preconditionFailure("Move to Workspace is rendered as a submenu")
            case .share:
                title = count == 1
                    ? String(localized: "Share…")
                    : String(localized: "Share \(count) Artifacts…")
                symbol = "square.and.arrow.up"
                selector = #selector(menuShare(_:))
            case .saveToFile:
                title = String(localized: "Save to File…")
                symbol = "square.and.arrow.down"
                selector = #selector(menuSave(_:))
            case .saveAsPDF:
                title = String(localized: "Save as PDF…")
                symbol = "doc.richtext"
                selector = #selector(menuSaveAsPDF(_:))
            case .copyFile:
                title = count == 1
                    ? String(localized: "Copy")
                    : String(localized: "Copy \(count) Artifacts")
                symbol = "doc.on.doc"
                selector = #selector(menuCopyFiles(_:))
            case .copySource:
                title = count == 1
                    ? String(localized: "Copy Source")
                    : String(localized: "Copy \(count) Sources")
                symbol = "curlybraces"
                selector = #selector(menuCopySources(_:))
            case .copyLink:
                title = String(localized: "Copy Link")
                symbol = "link"
                selector = #selector(menuCopyLink(_:))
            case .revealInFinder:
                title = count == 1
                    ? String(localized: "Reveal in Finder")
                    : String(localized: "Reveal \(count) Artifacts in Finder")
                symbol = "folder"
                selector = #selector(menuReveal(_:))
            case .openWorkspaceFolder:
                title = String(localized: "Open Workspace Folder")
                symbol = "folder"
                selector = #selector(menuOpenWorkspace(_:))
            case .delete:
                title = count == 1
                    ? String(localized: "Delete")
                    : String(localized: "Delete \(count) Artifacts")
                symbol = "trash"
                selector = #selector(menuDelete(_:))
            }

            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = payload
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            return item
        }

        private func moveMenuItem(
            artifacts: [Artifact],
            payload: ArtifactBrowserMenuPayload
        ) -> NSMenuItem {
            let item = NSMenuItem(
                title: String(localized: "Move to Workspace"),
                action: nil,
                keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let submenu = NSMenu()

            let newWorkspace = NSMenuItem(
                title: String(localized: "New Workspace…"),
                action: #selector(menuMoveToNewWorkspace(_:)),
                keyEquivalent: "")
            newWorkspace.target = self
            newWorkspace.representedObject = payload
            newWorkspace.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            submenu.addItem(newWorkspace)
            submenu.addItem(.separator())

            addMoveDestination(.home, artifacts: artifacts, payload: payload, to: submenu)
            for project in parent.projects {
                addMoveDestination(.project(project), artifacts: artifacts, payload: payload, to: submenu)
            }
            item.submenu = submenu
            return item
        }

        private func addMoveDestination(
            _ destination: WorkspaceDestination,
            artifacts: [Artifact],
            payload: ArtifactBrowserMenuPayload,
            to menu: NSMenu
        ) {
            let item = NSMenuItem(
                title: destination.displayName,
                action: #selector(menuMove(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = ArtifactBrowserMovePayload(
                artifactPayload: payload,
                destination: destination)
            let current = artifacts.allSatisfy {
                $0.workspaceID == destination.projectID && $0.cwd == destination.cwd
            }
            item.state = current ? .on : .off
            item.isEnabled = !current
            menu.addItem(item)
        }

        private func payload(_ sender: NSMenuItem) -> ArtifactBrowserMenuPayload? {
            sender.representedObject as? ArtifactBrowserMenuPayload
        }

        private func artifacts(_ sender: NSMenuItem) -> [Artifact] {
            guard let payload = payload(sender) else { return [] }
            return payload.ids.compactMap { artifactsByID[$0] }
        }

        private func selectArtifacts(_ ids: [UUID], primary: UUID?) {
            guard let outline else { return }
            var rows = IndexSet()
            for id in ids {
                guard let node = artifactNodes[id] else { continue }
                if let group = outline.parent(forItem: node) { outline.expandItem(group) }
                let row = outline.row(forItem: node)
                if row >= 0 { rows.insert(row) }
            }
            isApplyingSelection = true
            outline.selectRowIndexes(rows, byExtendingSelection: false)
            isApplyingSelection = false
            publishSelection(primary: primary)
        }

        @objc private func menuShowPreview(_ sender: NSMenuItem) {
            guard let payload = payload(sender) else { return }
            selectArtifacts(payload.ids, primary: payload.clickedID)
        }

        @objc private func menuOpen(_ sender: NSMenuItem) {
            ArtifactActions.openInDefaultApp(artifacts(sender))
        }

        @objc private func menuQuickLook(_ sender: NSMenuItem) {
            guard let artifact = artifacts(sender).first else { return }
            parent.onQuickLook(artifact)
        }

        @objc private func menuFavorite(_ sender: NSMenuItem) {
            guard let payload = payload(sender), let favorite = payload.favorite else { return }
            parent.onFavorite(Set(payload.ids), favorite)
        }

        @objc private func menuRename(_ sender: NSMenuItem) {
            guard let payload = payload(sender), payload.ids.count == 1,
                  let id = payload.ids.first else { return }
            selectArtifacts([id], primary: id)
            renameSelected()
        }

        @objc private func menuDuplicate(_ sender: NSMenuItem) {
            guard let payload = payload(sender) else { return }
            parent.onDuplicate(payload.ids)
        }

        @objc private func menuMove(_ sender: NSMenuItem) {
            guard let payload = sender.representedObject as? ArtifactBrowserMovePayload else { return }
            parent.onMove(Set(payload.artifactPayload.ids), payload.destination)
        }

        @objc private func menuMoveToNewWorkspace(_ sender: NSMenuItem) {
            guard let payload = payload(sender) else { return }
            parent.onMoveToNewWorkspace(Set(payload.ids))
        }

        @objc private func menuShare(_ sender: NSMenuItem) {
            guard let outline else { return }
            let anchor = outline.clickedRow >= 0
                ? outline.rowView(atRow: outline.clickedRow, makeIfNecessary: false)
                : outline
            ArtifactActions.share(artifacts(sender), relativeTo: anchor ?? outline)
        }

        @objc private func menuSave(_ sender: NSMenuItem) {
            guard let artifact = artifacts(sender).first else { return }
            ArtifactActions.save(artifact)
        }

        @objc private func menuSaveAsPDF(_ sender: NSMenuItem) {
            guard let artifact = artifacts(sender).first else { return }
            ArtifactActions.saveAsPDF(artifact)
        }

        @objc private func menuCopyFiles(_ sender: NSMenuItem) {
            ArtifactActions.copyFiles(artifacts(sender))
        }

        @objc private func menuCopySources(_ sender: NSMenuItem) {
            ArtifactActions.copySources(artifacts(sender))
        }

        @objc private func menuCopyLink(_ sender: NSMenuItem) {
            guard let artifact = artifacts(sender).first else { return }
            MechanicianURL.copyLink(to: .artifact(artifact.uuid))
        }

        @objc private func menuReveal(_ sender: NSMenuItem) {
            ArtifactActions.revealInFinder(artifacts(sender))
        }

        @objc private func menuOpenWorkspace(_ sender: NSMenuItem) {
            guard let artifact = artifacts(sender).first else { return }
            parent.onOpenWorkspace(artifact)
        }

        @objc private func menuDelete(_ sender: NSMenuItem) {
            guard let payload = payload(sender) else { return }
            parent.onDelete(Set(payload.ids))
        }
    }
}

private final class ArtifactBrowserMenuPayload: NSObject {
    let clickedID: UUID
    let ids: [UUID]
    var favorite: Bool?

    init(clickedID: UUID, ids: [UUID]) {
        self.clickedID = clickedID
        self.ids = ids
    }
}

private final class ArtifactBrowserMovePayload: NSObject {
    let artifactPayload: ArtifactBrowserMenuPayload
    let destination: WorkspaceDestination

    init(artifactPayload: ArtifactBrowserMenuPayload, destination: WorkspaceDestination) {
        self.artifactPayload = artifactPayload
        self.destination = destination
    }
}

@MainActor
private final class ArtifactTitleField: NSTextField {
    var artifactID: UUID?
    var editingArtifactID: UUID?
}

@MainActor
private final class ArtifactNameCellView: NSTableCellView {
    let titleField = ArtifactTitleField()
    private let subtitleField = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, delegate: NSTextFieldDelegate) {
        super.init(frame: .zero)
        self.identifier = identifier

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        imageView = icon

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.font = .systemFont(ofSize: 12)
        // Artifact names are prose titles, not filenames whose extension needs preserving. Tail
        // truncation keeps the distinguishing beginning readable instead of splicing two unrelated
        // fragments together in a narrow column.
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.usesSingleLineMode = true
        titleField.delegate = delegate
        textField = titleField

        subtitleField.translatesAutoresizingMaskIntoConstraints = false
        subtitleField.font = .systemFont(ofSize: 10)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.cell?.usesSingleLineMode = true

        addSubview(icon)
        addSubview(titleField)
        addSubview(subtitleField)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            titleField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            subtitleField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: -1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(artifact: Artifact, detailed: Bool) {
        titleField.artifactID = artifact.uuid
        imageView?.image = NSImage(
            systemSymbolName: ArtifactActions.symbol(forType: artifact.type),
            accessibilityDescription: nil)
        imageView?.contentTintColor = .controlAccentColor
        if titleField.currentEditor() == nil {
            titleField.stringValue = artifact.title
        }
        subtitleField.stringValue = artifactBrowserSubtitle(artifact)
        subtitleField.isHidden = !detailed
        toolTip = artifact.title

        if detailed {
            titleField.font = .systemFont(ofSize: 12)
            titleField.setContentHuggingPriority(.defaultHigh, for: .vertical)
        } else {
            titleField.font = .systemFont(ofSize: 12)
        }
    }
}

@MainActor
private final class ArtifactFavoriteButton: NSButton {
    var artifactID: UUID?
}

@MainActor
private final class ArtifactFavoriteCellView: NSTableCellView {
    private let button = ArtifactFavoriteButton()

    init(identifier: NSUserInterfaceItemIdentifier, target: AnyObject) {
        super.init(frame: .zero)
        self.identifier = identifier
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = target
        button.action = #selector(AppKitArtifactBrowser.Coordinator.toggleFavorite(_:))
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(artifact: Artifact) {
        button.artifactID = artifact.uuid
        button.image = NSImage(
            systemSymbolName: artifact.favorite ? "star.fill" : "star",
            accessibilityDescription: nil)
        button.contentTintColor = artifact.favorite ? .systemYellow : .secondaryLabelColor
        let label = artifact.favorite
            ? String(localized: "Unfavorite")
            : String(localized: "Favorite")
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }
}
