import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ArtifactWindowSplitLayout: Equatable {
    let browserWidth: CGFloat
    let previewWidth: CGFloat
}

/// Stable horizontal geometry for the standalone artifact browser.
///
/// `HSplitView` asks both children for an ideal width whenever their content changes. Replacing the
/// empty preview with a web view therefore moved the divider just because a row was selected. This
/// model gives the trailing preview one durable preference instead: a narrow window may temporarily
/// clamp what is displayed, but it never overwrites the width the person chose.
enum ArtifactWindowSplitSizing {
    static let preferenceKey = "artifactsPreviewWidth"
    static let defaultPreviewWidth = 700.0
    static let minimumPreviewWidth = 480.0
    static let maximumPreviewWidth = 2_000.0
    static let preferenceRange = minimumPreviewWidth...maximumPreviewWidth
    static let minimumBrowserWidth = CGFloat(320)
    static let seamWidth = CGFloat(1)

    static func preferredWidth(_ storedWidth: Double) -> Double {
        guard storedWidth.isFinite,
              storedWidth >= minimumPreviewWidth,
              storedWidth <= maximumPreviewWidth else {
            return defaultPreviewWidth
        }
        return storedWidth
    }

    static func resolve(
        availableWidth: CGFloat,
        storedPreviewWidth: Double
    ) -> ArtifactWindowSplitLayout {
        let available = max(0, availableWidth)
        let maximumDisplayedPreview = max(
            0,
            available - seamWidth - minimumBrowserWidth)
        let effectiveMinimumPreview = min(
            CGFloat(minimumPreviewWidth),
            maximumDisplayedPreview)
        let preferred = CGFloat(preferredWidth(storedPreviewWidth))
        let preview = min(
            max(preferred, effectiveMinimumPreview),
            maximumDisplayedPreview)
        return ArtifactWindowSplitLayout(
            browserWidth: max(0, available - seamWidth - preview),
            previewWidth: preview)
    }
}

/// A selection-stable, user-resizable inventory/preview split. The explicit child frames are the
/// important part: preview content is replaced freely, but it never gets to vote on the divider.
struct ArtifactWindowSplit<Inventory: View, Preview: View>: View {
    @Binding private var storedPreviewWidth: Double
    private let inventory: Inventory
    private let preview: Preview

    init(
        storedPreviewWidth: Binding<Double>,
        @ViewBuilder inventory: () -> Inventory,
        @ViewBuilder preview: () -> Preview
    ) {
        _storedPreviewWidth = storedPreviewWidth
        self.inventory = inventory()
        self.preview = preview()
    }

    private var previewWidthBinding: Binding<Double> {
        Binding(
            get: { ArtifactWindowSplitSizing.preferredWidth(storedPreviewWidth) },
            set: { storedPreviewWidth = $0 })
    }

    private func adjustPreviewWidth(
        _ direction: AccessibilityAdjustmentDirection,
        displayedWidth: Double
    ) {
        let translation: Double
        switch direction {
        case .increment: translation = -40
        case .decrement: translation = 40
        @unknown default: return
        }
        storedPreviewWidth = ResponsiveResizeDrag.preferredSize(
            preferredSize: ArtifactWindowSplitSizing.preferredWidth(storedPreviewWidth),
            displayedSize: displayedWidth,
            translation: translation,
            range: ArtifactWindowSplitSizing.preferenceRange)
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = ArtifactWindowSplitSizing.resolve(
                availableWidth: proxy.size.width,
                storedPreviewWidth: storedPreviewWidth)
            HStack(spacing: 0) {
                inventory
                    .frame(width: layout.browserWidth)
                    .frame(maxHeight: .infinity)
                    .clipped()
                ResizeHandle(
                    size: previewWidthBinding,
                    axis: .horizontal,
                    range: ArtifactWindowSplitSizing.preferenceRange,
                    displayedSize: Double(layout.previewWidth))
                    .background(Color(nsColor: .separatorColor))
                    .accessibilityLabel(String(localized: "Resize artifact preview"))
                    .accessibilityValue(String(localized: "\(Int(layout.previewWidth)) points wide"))
                    .accessibilityAdjustableAction { direction in
                        adjustPreviewWidth(
                            direction,
                            displayedWidth: Double(layout.previewWidth))
                    }
                preview
                    .frame(width: layout.previewWidth)
                    .frame(maxHeight: .infinity)
                    .clipped()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// Selection shared between the native artifact outline and the SwiftUI preview/actions around it.
/// The AppKit view owns pointer and keyboard selection mechanics; this value is the UUID projection
/// used for programmatic Spotlight selection and state reconciliation after filters or mutations.
struct ArtifactListSelection: Equatable {
    private(set) var ids: Set<UUID> = []
    private(set) var primary: UUID?
    private(set) var anchor: UUID?

    mutating func selectOnly(_ id: UUID?) {
        guard let id else {
            ids = []
            primary = nil
            anchor = nil
            return
        }
        ids = [id]
        primary = id
        anchor = id
    }

    mutating func select(
        _ id: UUID,
        orderedIDs: [UUID],
        extending: Bool,
        range: Bool
    ) {
        guard orderedIDs.contains(id) else { return }

        if range,
           let anchor,
           let anchorIndex = orderedIDs.firstIndex(of: anchor),
           let clickedIndex = orderedIDs.firstIndex(of: id) {
            let bounds = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            let rangeIDs = Set(bounds.map { orderedIDs[$0] })
            if extending {
                ids.formUnion(rangeIDs)
            } else {
                ids = rangeIDs
            }
            primary = id
            return
        }

        if extending {
            if ids.remove(id) != nil {
                if primary == id {
                    primary = orderedIDs.first(where: ids.contains)
                }
                if ids.isEmpty {
                    primary = nil
                }
            } else {
                ids.insert(id)
                primary = id
            }
            // A later Shift-click extends from the most recently Command-clicked row, including
            // when that row was toggled off (Finder's stable range-anchor behavior).
            anchor = id
        } else {
            selectOnly(id)
        }
    }

    /// Keep hidden/deleted/moved rows out of bulk commands while retaining the primary preview when
    /// it is still visible.
    mutating func reconcile(orderedIDs: [UUID]) {
        let available = Set(orderedIDs)
        ids.formIntersection(available)
        if let primary, !ids.contains(primary) {
            self.primary = orderedIDs.first(where: ids.contains)
        }
        if let anchor, !available.contains(anchor) {
            self.anchor = self.primary
        }
        if ids.isEmpty {
            primary = nil
            anchor = nil
        }
    }

    func actionIDs(for rowID: UUID) -> Set<UUID> {
        ids.contains(rowID) ? ids : [rowID]
    }

    mutating func synchronize(ids: Set<UUID>, primary: UUID?) {
        self.ids = ids
        self.primary = primary.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        anchor = self.primary
        if ids.isEmpty {
            self.primary = nil
            anchor = nil
        }
    }
}

/// Presentation details for the standalone artifact window that are deliberately kept separate
/// from the persisted workspace scope. The artifact stack symbol describes an artifact; this
/// control changes *which Workspaces* are in scope, so it must not reuse that symbol.
enum ArtifactWorkspaceScopePresentation {
    static let currentWorkspaceSymbol = "rectangle.3.group"
    static let allWorkspacesSymbol = "rectangle.3.group.fill"

    static func symbolName(showingAllWorkspaces: Bool) -> String {
        showingAllWorkspaces ? allWorkspacesSymbol : currentWorkspaceSymbol
    }
}

/// A title editor never commits an accidental blank name, and a no-op edit should not write a new
/// artifact revision. Keeping that decision here makes Return, focus-loss, and the Rename menu
/// entry agree on the same behavior.
enum ArtifactInlineTitleEditing {
    static func titleToCommit(draft: String, currentTitle: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != currentTitle else { return nil }
        return trimmed
    }
}

private enum ArtifactToolbarControlEmphasis: Equatable {
    case standard
    case selected
    case destructive
}

/// One quiet macOS-toolbar glyph. Ordinary commands reveal their boundary on hover, while real
/// toggle states retain a tinted selected state. It is shared by buttons and menu labels so their
/// hit targets do not drift apart.
private struct ArtifactToolbarControl<Content: View>: View {
    let emphasis: ArtifactToolbarControlEmphasis
    var isHovered = false
    var isPressed = false
    @ViewBuilder let content: Content
    @Environment(\.isEnabled) private var isEnabled

    init(
        emphasis: ArtifactToolbarControlEmphasis,
        isHovered: Bool = false,
        isPressed: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.emphasis = emphasis
        self.isHovered = isHovered
        self.isPressed = isPressed
        self.content = content()
    }

    var body: some View {
        content
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(foreground)
            .frame(width: 28, height: 28)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(border, lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isEnabled ? 1 : 0.42)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: isPressed)
    }

    private var foreground: Color {
        switch emphasis {
        case .standard: .nSecondaryText
        case .selected: .nInfoText
        case .destructive: .nErrorText
        }
    }

    private var background: Color {
        if isPressed {
            switch emphasis {
            case .standard: return .nMuted.opacity(0.34)
            case .selected: return .nAccent.opacity(0.36)
            case .destructive: return .nErrorText.opacity(0.24)
            }
        }
        if emphasis == .selected { return .nAccent.opacity(isHovered ? 0.25 : 0.18) }
        guard isHovered else { return .clear }
        switch emphasis {
        case .standard: return .nElevated.opacity(0.9)
        case .selected: return .nAccent.opacity(0.25)
        case .destructive: return .nErrorText.opacity(0.14)
        }
    }

    private var border: Color {
        if emphasis == .selected { return .nAccent.opacity(0.46) }
        return (isHovered || isPressed) ? .nMuted.opacity(0.62) : .clear
    }
}

/// A quiet icon-only control modeled on a macOS toolbar item: no permanent chrome for an ordinary
/// command, a clear hover and pressed state, and a persistent selected state only for a real mode.
private struct ArtifactToolbarIconButtonStyle: ButtonStyle {
    let emphasis: ArtifactToolbarControlEmphasis

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, emphasis: emphasis)
    }

    private struct IconButtonBody: View {
        let configuration: ArtifactToolbarIconButtonStyle.Configuration
        let emphasis: ArtifactToolbarControlEmphasis
        @State private var isHovered = false

        var body: some View {
            ArtifactToolbarControl(
                emphasis: emphasis,
                isHovered: isHovered,
                isPressed: configuration.isPressed
            ) {
                configuration.label
            }
            .onHover { isHovered = $0 }
        }
    }
}

/// `Menu` does not expose its pressed configuration to a custom label. This trigger supplies the
/// same hit target and hover affordance while AppKit provides the menu's native pressed/highlighted
/// behavior when it opens.
private struct ArtifactToolbarMenuTrigger: View {
    let systemImage: String
    var emphasis: ArtifactToolbarControlEmphasis = .standard
    @State private var isHovered = false

    var body: some View {
        ArtifactToolbarControl(
            emphasis: emphasis,
            isHovered: isHovered
        ) {
            Image(systemName: systemImage)
        }
        .onHover { isHovered = $0 }
        .accessibilityHidden(true)
    }
}

/// A title remains visually like a document title, but it reveals a lightweight hit treatment on
/// hover so selecting it is discoverable without reintroducing a separate pencil command.
private struct ArtifactTitleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TitleButtonBody(configuration: configuration)
    }

    private struct TitleButtonBody: View {
        let configuration: ArtifactTitleButtonStyle.Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(configuration.isPressed
                              ? Color.nMuted.opacity(0.34)
                              : (isHovered ? Color.nElevated.opacity(0.9) : .clear))
                }
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// The Artifacts manager window — full CRUD over the standalone `ArtifactStore`, plus a live
/// preview. User-created artifacts (origin "user") and those written by interactive or ambient
/// agents all live in one store and update live (agent write-through + a directory watcher).
struct GlobalArtifactsView: View {
    @ObservedObject private var store = ArtifactStore.shared
    @ObservedObject private var active = ActiveWorkspace.shared
    @ObservedObject private var projects = ProjectStore.shared
    @ObservedObject private var organizer = ArtifactOrganizationStore.window
    @Environment(\.openWindow) private var openWindow

    @State private var search = ""
    @State private var typeFilter = "all"
    @State private var favoritesOnly = false
    @State private var allWorkspaces = false
    @State private var selection = ArtifactListSelection()
    @AppStorage(ArtifactWindowSplitSizing.preferenceKey)
    private var storedPreviewWidth = ArtifactWindowSplitSizing.defaultPreviewWidth

    // Editing state
    @State private var editingSource = false
    @State private var sourceDraft = ""
    @State private var editBaselineSource = "" // source when editing began — detects a concurrent agent update
    @State private var showConflict = false
    @State private var showNew = false
    @State private var editingTitleID: UUID?
    @State private var titleDraft = ""
    @FocusState private var titleFieldFocused: Bool
    @State private var showDelete = false
    @State private var deleteTargets: Set<UUID> = []
    @State private var isImportTargeted = false // FR-102: highlight while a file drag hovers the list
    @State private var quickLookURL: URL?
    @StateObject private var quickLook = QuickLookController()

    private let types = [("All", "all"), ("HTML", "html"), ("SVG", "svg"),
                         ("Mermaid", "mermaid"), ("Markdown", "markdown"), ("CSV", "csv")]

    private var filtered: [Artifact] {
        store.artifacts.filter { a in
            (allWorkspaces || workspaceScope.contains(artifact: a))
                && (typeFilter == "all" || a.type == typeFilter)
                && (!favoritesOnly || a.favorite)
                && (search.isEmpty
                    || a.title.localizedCaseInsensitiveContains(search)
                    || a.conversationTitle.localizedCaseInsensitiveContains(search))
        }
    }

    private var groups: [ArtifactGroup] {
        groupedArtifacts(filtered, by: organizer.organization) { artifact in
            guard let id = artifact.workspaceID,
                  let project = projects.project(id) else {
                return artifact.cwd.isEmpty ? "" : (artifact.cwd as NSString).lastPathComponent
            }
            return project.name
        }
    }

    private var current: Artifact? {
        guard let selected = selection.primary else { return nil }
        return store.artifacts.first { $0.uuid == selected }
    }

    private var orderedArtifactIDs: [UUID] {
        groups.flatMap(\.artifacts).map(\.uuid)
    }

    private var visibleSelectionIDs: Set<UUID> {
        selection.ids.intersection(orderedArtifactIDs)
    }

    private var workspaceScope: WorkspaceUtilityScope {
        guard let bridge = active.bridge else { return .unavailable }
        return .current(
            projectID: bridge.projectID,
            cwd: bridge.cwd,
            resolvedFolderProjectID: projects.projectID(forCwd: bridge.cwd, createIfMissing: false))
    }

    private var workspaceID: UUID? { workspaceScope.workspaceID }

    private var workspaceCwd: String {
        active.bridge?.cwd.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var workspaceLabel: String {
        allWorkspaces ? "All Workspaces" : workspaceScope.displayName(projects: projects.projects)
    }

    private var headerSummary: String {
        let inventory = "\(workspaceLabel) · \(filtered.count) of \(store.artifacts.count)"
        guard visibleSelectionIDs.count > 1 else { return inventory }
        return "\(inventory) · \(visibleSelectionIDs.count) selected"
    }

    private var deleteDialogTitle: String {
        deleteTargets.count == 1
            ? "Delete this artifact?"
            : "Delete \(deleteTargets.count) artifacts?"
    }

    private var deleteDialogMessage: String {
        let noun = deleteTargets.count == 1 ? "artifact" : "artifacts"
        let pronoun = deleteTargets.count == 1 ? "it" : "them"
        return "This removes the \(noun). You can undo it with Undo in the Edit menu, and agents may re-create \(pronoun) on a later run."
    }

    /// A utility window survives workspace changes. Do not leave its preview showing an artifact
    /// from the previous workspace after the list has re-scoped.
    private func reconcileSelectionWithScope() {
        selection.reconcile(orderedIDs: orderedArtifactIDs)
    }

    /// Select the artifact a Spotlight result / App Intent asked to open (once it's loaded), and
    /// clear any filters hiding it.
    private func consumePendingSelection() {
        guard let id = active.pendingSelectArtifact,
              store.artifacts.contains(where: { $0.uuid == id }) else { return }
        favoritesOnly = false; typeFilter = "all"; search = ""
        selection.selectOnly(id)
        active.pendingSelectArtifact = nil
    }

    var body: some View {
        ArtifactWindowSplit(storedPreviewWidth: $storedPreviewWidth) {
            VStack(spacing: 0) {
                header
                Divider()
                ZStack {
                    // Keep the native browser mounted even when a filter has no matches. Its column
                    // header, saved geometry, responder chain, and drop destination remain real.
                    list
                    if filtered.isEmpty { empty.padding(.top, 24) }
                }
            }
        } preview: {
            previewPane
        }
        .frame(minWidth: 840, minHeight: 480)
        .background(Color.nBg)
        // FR-102: drop files from Finder anywhere in the window to import them as artifacts. The
        // native outline handles drops over its rows; this outer destination covers the header,
        // empty state, and preview pane.
        .dropDestination(for: URL.self) { urls, _ in
            finishImport(urls); return true
        } isTargeted: { isImportTargeted = $0 }
        .overlay {
            if isImportTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.nAccent, lineWidth: 3)
                    .padding(3).allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = store.persistenceError {
                VStack(spacing: 0) {
                    PersistenceErrorBanner(message: error, retry: store.retryFailedSaves)
                    Divider()
                }
            }
        }
        .onAppear {
            store.load()
            consumePendingSelection()
            reconcileSelectionWithScope()
        }
        .onChange(of: active.pendingSelectArtifact) { consumePendingSelection() }
        .onChange(of: store.artifacts.count) { consumePendingSelection() } // load may finish late
        // Reconcile on filters, sorting, deletes, and workspace moves without attaching another drop
        // handler to the rows themselves.
        .onChange(of: orderedArtifactIDs) { reconcileSelectionWithScope() }
        .onChange(of: selection.primary) {
            // Both editors belong to the selected artifact. Leaving one behind while the native
            // outline moves selection would commit a title to the wrong preview.
            editingSource = false
            cancelTitleEditing()
        }
        .sheet(isPresented: $showNew) {
            NewArtifactSheet { title, type, source in
                favoritesOnly = false; typeFilter = "all" // else the new row is filtered out of the list
                selection.selectOnly(
                    store.create(
                        title: title,
                        type: type,
                        source: source,
                        workspaceID: workspaceID,
                        cwd: workspaceCwd).uuid)
            }
        }
        .confirmationDialog(deleteDialogTitle, isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                deleteSelectedArtifacts()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteDialogMessage)
        }
        .confirmationDialog("This artifact changed while you were editing",
                            isPresented: $showConflict, titleVisibility: .visible) {
            Button("Overwrite with my edits", role: .destructive) {
                if let a = current { store.updateSource(a.uuid, sourceDraft) }
                editingSource = false
            }
            Button("Discard my edits", role: .cancel) { editingSource = false }
        } message: {
            Text("An agent updated this artifact since you started editing. Overwrite it with your version, or discard your edits to keep theirs.")
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Artifacts").font(.headline)
                    Text(headerSummary)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if visibleSelectionIDs.count > 1 {
                    bulkActionMenu
                }
                organizationMenu
                Button { showNew = true } label: { Image(systemName: "plus") }
                    .buttonStyle(ArtifactToolbarIconButtonStyle(emphasis: .standard))
                    .help("New artifact")
                    .accessibilityLabel("New artifact")
                    .accessibilityIdentifier("artifacts.new")
                Button { allWorkspaces.toggle() } label: {
                    Image(systemName: ArtifactWorkspaceScopePresentation.symbolName(
                        showingAllWorkspaces: allWorkspaces))
                }
                .buttonStyle(ArtifactToolbarIconButtonStyle(
                    emphasis: allWorkspaces ? .selected : .standard))
                .help(allWorkspaces ? "Show current workspace" : "Show all workspaces")
                .accessibilityLabel(allWorkspaces ? "Show current workspace" : "Show all workspaces")
                .accessibilityValue(allWorkspaces ? "Showing all workspaces" : "Showing current workspace")
                .accessibilityIdentifier("artifacts.workspaceScope")
                Button { store.load() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(ArtifactToolbarIconButtonStyle(emphasis: .standard))
                    .help("Refresh")
                    .accessibilityLabel("Refresh")
                    .accessibilityIdentifier("artifacts.refresh")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("Search artifacts", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .cardSurface(cornerRadius: 7)
            HStack(spacing: 2) {
                ForEach(types, id: \.1) { t in
                    let active = typeFilter == t.1
                    Button { typeFilter = t.1 } label: {
                        Text(t.0)
                            .scaledFont(11, weight: active ? .semibold : .regular)
                            .foregroundStyle(active ? Color.nText : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(active ? Color.nAccent.opacity(0.30) : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button { favoritesOnly.toggle() } label: {
                    Image(systemName: favoritesOnly ? "star.fill" : "star")
                        .scaledFont(11)
                        .foregroundStyle(favoritesOnly ? Color.nGoldText : .secondary)
                        .frame(width: 28)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(favoritesOnly ? Color.nAccent.opacity(0.30) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show favorites only")
                .accessibilityLabel("Show favorites only")
            }
            .padding(3)
            .cardSurface(cornerRadius: 8)
        }
        .padding(10)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text(store.artifacts.isEmpty ? "No artifacts yet." : "No artifacts match.")
                .font(.callout).foregroundStyle(.secondary)
            if store.artifacts.isEmpty {
                Button { showNew = true } label: { Label("New Artifact", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle(kind: .accent))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: list

    /// The native outline accepts drops itself. Keeping the outer window-level SwiftUI destination
    /// still makes the header and preview valid drop targets, while AppKit owns the list's event path.
    private var list: some View {
        AppKitArtifactBrowser(
            groups: groups,
            organization: organizer.organization,
            selection: $selection,
            projects: projects.projects,
            onSort: { sort, ascending in
                organizer.organization.sort = sort
                organizer.organization.ascending = ascending
            },
            onFavorite: setFavorite,
            onRename: { store.rename($0, to: $1) },
            onDuplicate: duplicateArtifacts,
            onMove: { ids, destination in
                ArtifactWorkspaceMoveActions.move(artifactIDs: ids, to: destination)
            },
            onMoveToNewWorkspace: { ids in
                ArtifactWorkspaceMoveActions.beginNewWorkspaceMove(artifactIDs: ids) {
                    openWindow(id: "projects")
                }
            },
            onOpenWorkspace: openWorkspaceFolder,
            onDelete: confirmDelete,
            onImport: finishImport,
            onQuickLook: previewWithQuickLook)
            .background(
                QuickLookHost(selected: quickLookURL, controller: quickLook)
                    .frame(width: 0, height: 0))
    }

    private var organizationMenu: some View {
        Menu {
            Picker("Group by", selection: $organizer.organization.grouping) {
                ForEach(ArtifactGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Rows", selection: $organizer.organization.density) {
                ForEach(ArtifactRowDensity.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Divider()
            Toggle("Favorites on top", isOn: $organizer.organization.favoritesFirst)
        } label: {
            ArtifactToolbarMenuTrigger(systemImage: "line.3.horizontal.decrease")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Grouping and row options")
        .accessibilityLabel("Grouping and row options")
        .accessibilityIdentifier("artifacts.organization")
    }

    private var bulkActionMenu: some View {
        let ids = visibleSelectionIDs
        let artifacts = store.artifacts.filter { ids.contains($0.uuid) }
        let shouldFavorite = artifacts.contains { !$0.favorite }
        return Menu {
            Button { setFavorite(ids, to: shouldFavorite) } label: {
                Label(
                    shouldFavorite
                        ? favoriteLabel(count: ids.count)
                        : unfavoriteLabel(count: ids.count),
                    systemImage: shouldFavorite ? "star" : "star.slash")
            }
            ArtifactWorkspaceMoveMenu(artifacts: ids)
            Divider()
            Button(role: .destructive) { confirmDelete(ids) } label: {
                Label("Delete \(ids.count) Artifacts", systemImage: "trash")
            }
        } label: {
            ArtifactToolbarMenuTrigger(systemImage: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Actions for \(ids.count) selected artifacts")
        .accessibilityLabel("Actions for \(ids.count) selected artifacts")
        .accessibilityIdentifier("artifacts.bulkActions")
    }

    private func setFavorite(_ ids: Set<UUID>, to favorite: Bool) {
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            store.setFavorite(id, favorite)
        }
    }

    private func favoriteLabel(count: Int) -> String {
        count == 1 ? "Favorite" : "Favorite \(count) Artifacts"
    }

    private func unfavoriteLabel(count: Int) -> String {
        count == 1 ? "Unfavorite" : "Unfavorite \(count) Artifacts"
    }

    private func confirmDelete(_ ids: Set<UUID>) {
        deleteTargets = ids
        showDelete = true
    }

    private func deleteSelectedArtifacts() {
        guard !WorkspaceAdoption.isPlacementOperationInProgress else {
            NSSound.beep()
            return
        }
        let ids = deleteTargets
        selection.reconcile(orderedIDs: orderedArtifactIDs.filter { !ids.contains($0) })
        let receipts = ids
            .sorted(by: { $0.uuidString < $1.uuidString })
            .compactMap { store.delete($0) }
        ArtifactDeleteUndo.register(
            receipts,
            actionName: ArtifactDeleteUndo.actionName(count: receipts.count),
            store: store,
            conversations: .shared,
            undoManager: workspaceUndoManager(for: ActiveWorkspace.shared.bridge))
        deleteTargets = []
    }

    private func duplicateArtifacts(_ ids: [UUID]) {
        let artifactsByID = Dictionary(uniqueKeysWithValues: store.artifacts.map { ($0.uuid, $0) })
        var existingTitles = Set(store.artifacts.map(\.title))
        var createdIDs: [UUID] = []
        for id in ids {
            guard let artifact = artifactsByID[id] else { continue }
            let title = artifactDuplicateTitle(for: artifact.title, existingTitles: existingTitles)
            existingTitles.insert(title)
            let duplicate = store.create(
                title: title,
                type: artifact.type,
                source: artifact.source,
                workspaceID: artifact.workspaceID,
                cwd: artifact.cwd)
            if artifact.favorite { store.setFavorite(duplicate.uuid, true) }
            createdIDs.append(duplicate.uuid)
        }
        guard !createdIDs.isEmpty else { return }
        favoritesOnly = false
        typeFilter = "all"
        search = ""
        selection.synchronize(ids: Set(createdIDs), primary: createdIDs.last)
    }

    private func openWorkspaceFolder(_ artifact: Artifact) {
        if let workspaceID = artifact.workspaceID,
           let project = projects.project(workspaceID) {
            openProject(project)
            return
        }
        if let projectID = projects.projectID(forCwd: artifact.cwd),
           let project = projects.project(projectID) {
            openProject(project)
        }
    }

    private func previewWithQuickLook(_ artifact: Artifact) {
        guard let url = try? ArtifactActions.exportedFile(for: artifact) else {
            NSSound.beep()
            return
        }
        quickLookURL = url
        DispatchQueue.main.async { quickLook.preview(url) }
    }

    /// FR-102: import files dropped from Finder as new artifacts in this (standalone) store, tagged to
    /// the current workspace. Unsupported/binary files are skipped and reported rather than failing
    /// silently. File reads happen off the item providers' completion callbacks, so fold the result
    /// back on the main actor before touching the store/selection.
    @MainActor
    private func finishImport(_ urls: [URL]) {
        let urls = urls.filter {
            !ArtifactFileExport.contains($0)
                && ArtifactActions.reference(forExportedURL: $0) == nil
        }
        guard !urls.isEmpty else { return }
        // A utility-window drop belongs to the workspace visible at the drop event. File reads are
        // asynchronous, so do not let a later active-workspace switch silently refile the result.
        let destinationWorkspaceID = workspaceID
        let destinationCwd = workspaceCwd
        Task {
            let result = await ArtifactActions.importsAsync(from: urls)
            applyImports(
                result.ready,
                skipped: result.skipped,
                workspaceID: destinationWorkspaceID,
                cwd: destinationCwd)
        }
    }

    @MainActor
    private func applyImports(
        _ ready: [ArtifactActions.Import],
        skipped: [String],
        workspaceID: UUID?,
        cwd: String
    ) {
        guard !ready.isEmpty else {
            ArtifactActions.reportNothingImported(skipped: skipped)
            return
        }
        if let workspaceID, projects.project(workspaceID) == nil {
            ArtifactActions.reportImportWorkspaceUnavailable()
            return
        }
        favoritesOnly = false; typeFilter = "all" // else a freshly imported row is filtered out
        var last: UUID?
        for imp in ready {
            last = store.create(title: imp.title, type: imp.type, source: imp.source,
                                workspaceID: workspaceID, cwd: cwd).uuid
        }
        selection.selectOnly(last)
        ArtifactActions.reportSkippedImports(skipped)
    }

    // MARK: preview

    private func beginTitleEditing(_ artifact: Artifact) {
        titleDraft = artifact.title
        editingTitleID = artifact.uuid
        // A context-menu Rename command has to dismiss before AppKit will accept a new first
        // responder. Scheduling this for the next run loop also covers a direct title click.
        DispatchQueue.main.async {
            guard editingTitleID == artifact.uuid else { return }
            titleFieldFocused = true
        }
    }

    private func commitTitleEditing(_ artifact: Artifact) {
        guard editingTitleID == artifact.uuid else { return }
        let currentTitle = store.artifacts.first(where: { $0.uuid == artifact.uuid })?.title ?? artifact.title
        if let title = ArtifactInlineTitleEditing.titleToCommit(
            draft: titleDraft,
            currentTitle: currentTitle) {
            store.rename(artifact.uuid, to: title)
        }
        cancelTitleEditing()
    }

    private func cancelTitleEditing() {
        editingTitleID = nil
        titleDraft = ""
        titleFieldFocused = false
    }

    @ViewBuilder
    private func artifactTitle(_ artifact: Artifact) -> some View {
        if editingTitleID == artifact.uuid {
            HStack(spacing: 5) {
                Image(systemName: ArtifactActions.symbol(forType: artifact.type))
                    .foregroundStyle(Color.nInfoText)
                    .accessibilityHidden(true)
                TextField("Artifact title", text: $titleDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)
                    .focused($titleFieldFocused)
                    .frame(minWidth: 120, maxWidth: 320, alignment: .leading)
                    .onSubmit { commitTitleEditing(artifact) }
                    .onExitCommand { cancelTitleEditing() }
                    .onChange(of: titleFieldFocused) { _, focused in
                        if !focused { commitTitleEditing(artifact) }
                    }
                    .accessibilityIdentifier("artifacts.preview.titleEditor")
                    .accessibilityLabel("Artifact title")
                    .accessibilityHint("Press Return to rename or Escape to cancel")
            }
        } else {
            Button { beginTitleEditing(artifact) } label: {
                HStack(spacing: 5) {
                    Image(systemName: ArtifactActions.symbol(forType: artifact.type))
                        .foregroundStyle(Color.nInfoText)
                        .accessibilityHidden(true)
                    Text(artifact.title)
                        .font(.headline)
                        .lineLimit(1)
                }
            }
            .buttonStyle(ArtifactTitleButtonStyle())
            .onDrag { ArtifactActions.itemProvider(for: artifact) }
            .contextMenu { previewContextMenu(artifact) }
            .help("Rename \(artifact.title) · Drag to a conversation or Finder")
            .accessibilityIdentifier("artifacts.preview.renameTitle")
            .accessibilityLabel("Rename artifact \(artifact.title)")
            .accessibilityHint("Select to edit the title")
        }
    }

    @ViewBuilder
    private var previewPane: some View {
        if let a = current {
            VStack(spacing: 0) {
                previewHeader(a)
                Divider()
                if editingSource {
                    VStack(spacing: 0) {
                        // Source, not prose: SwiftUI's TextEditor would rewrite a typed `-->` to
                        // `–>` and quietly break the artifact (FR-335).
                        SourceTextEditor(text: $sourceDraft)
                            .padding(6)
                        Divider()
                        HStack {
                            Spacer()
                            Button("Cancel") { editingSource = false }
                                .buttonStyle(PillButtonStyle(kind: .plain))
                            Button("Save") {
                                // Don't blindly clobber a newer revision written by an agent while
                                // the editor was open.
                                if a.source != editBaselineSource { showConflict = true }
                                else { store.updateSource(a.uuid, sourceDraft); editingSource = false }
                            }
                            .buttonStyle(PillButtonStyle(kind: .accent))
                            .keyboardShortcut("s", modifiers: .command)
                        }
                        .padding(8)
                    }
                } else {
                    ArtifactPreview(artifact: a)
                }
            }
        } else {
            Text("Select an artifact to preview")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func previewHeader(_ a: Artifact) -> some View {
        HStack(spacing: 8) {
            // The title keeps the document-proxy drag affordance, and a direct selection changes
            // it in place instead of sending the person to a separate Rename alert.
            artifactTitle(a)
            Text(a.type.uppercased())
                .font(.caption2.weight(.bold).monospaced())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.nAccent.opacity(0.25)))
            if a.revisions > 1 { Text("v\(a.revisions)").font(.caption2).foregroundStyle(.secondary) }
            Spacer()
            Button { store.setFavorite(a.uuid, !a.favorite) } label: {
                Image(systemName: a.favorite ? "star.fill" : "star")
                    .foregroundStyle(a.favorite ? Color.nGoldText : Color.secondary)
            }
            .buttonStyle(ArtifactToolbarIconButtonStyle(emphasis: .standard))
            .help(a.favorite ? "Unfavorite" : "Favorite")
            .accessibilityLabel(a.favorite ? "Unfavorite artifact" : "Favorite artifact")
            .accessibilityValue(a.favorite ? "Selected" : "Not selected")
            .accessibilityIdentifier("artifacts.preview.favorite")
            Button {
                if editingSource { editingSource = false }
                else { sourceDraft = a.source; editBaselineSource = a.source; editingSource = true }
            } label: { Image(systemName: editingSource ? "eye" : "curlybraces") }
                .buttonStyle(ArtifactToolbarIconButtonStyle(
                    emphasis: editingSource ? .selected : .standard))
                .help(editingSource ? "Preview" : "Edit source")
                .accessibilityLabel(editingSource ? "Preview" : "Edit source")
                .accessibilityValue(editingSource ? "Editing source" : "Previewing source")
                .accessibilityIdentifier("artifacts.preview.editSource")
            Button { ArtifactActions.copySource(a) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(ArtifactToolbarIconButtonStyle(emphasis: .standard))
                .help("Copy source")
                .accessibilityLabel("Copy source")
                .accessibilityIdentifier("artifacts.preview.copySource")
            Button { ArtifactActions.save(a) } label: { Image(systemName: "square.and.arrow.down") }
                .buttonStyle(ArtifactToolbarIconButtonStyle(emphasis: .standard))
                .help("Save to file…")
                .accessibilityLabel("Save to file")
                .accessibilityIdentifier("artifacts.preview.save")
            Button { ArtifactActions.revealInFinder(a) } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(ArtifactToolbarIconButtonStyle(emphasis: .standard))
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal in Finder")
                .accessibilityIdentifier("artifacts.preview.reveal")
            if !a.cwd.isEmpty {
                Button { openWorkspaceFolder(a) } label: { Image(systemName: "folder") }
                    .buttonStyle(ArtifactToolbarIconButtonStyle(emphasis: .standard))
                    .help("Open workspace folder")
                    .accessibilityLabel("Open workspace folder")
                    .accessibilityIdentifier("artifacts.preview.workspaceFolder")
            }
            Button { confirmDelete([a.uuid]) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(ArtifactToolbarIconButtonStyle(emphasis: .destructive))
            .help("Delete")
            .accessibilityLabel("Delete artifact")
            .accessibilityIdentifier("artifacts.preview.delete")
        }
        .padding(10)
    }

    @ViewBuilder
    private func previewContextMenu(_ artifact: Artifact) -> some View {
        Button { previewWithQuickLook(artifact) } label: {
            Label("Quick Look", systemImage: "eye")
        }
        Divider()
        Button { store.setFavorite(artifact.uuid, !artifact.favorite) } label: {
            Label(artifact.favorite ? "Unfavorite" : "Favorite",
                  systemImage: artifact.favorite ? "star.slash" : "star")
        }
        Button { beginTitleEditing(artifact) } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button { duplicateArtifacts([artifact.uuid]) } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button { MechanicianURL.copyLink(to: .artifact(artifact.uuid)) } label: {
            Label("Copy Link", systemImage: "link")
        }
        Divider()
        ArtifactFileContextMenuItems(artifact: artifact)
        if !artifact.cwd.isEmpty {
            Divider()
            Button { openWorkspaceFolder(artifact) } label: {
                Label("Open Workspace Folder", systemImage: "folder")
            }
        }
        Divider()
        Button(role: .destructive) { confirmDelete([artifact.uuid]) } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

func artifactDuplicateTitle(for title: String, existingTitles: Set<String>) -> String {
    let first = String(localized: "\(title) copy")
    guard existingTitles.contains(first) else { return first }
    var index = 2
    while true {
        let candidate = String(localized: "\(title) copy \(index)")
        if !existingTitles.contains(candidate) { return candidate }
        index += 1
    }
}

/// Sheet to create a new user artifact.
private struct NewArtifactSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (String, String, String) -> Void

    @State private var title = ""
    @State private var type = "html"
    @State private var source = ""
    private let types = ["html", "svg", "mermaid", "markdown", "csv"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Artifact").font(.headline)
            HStack {
                TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                Picker("", selection: $type) {
                    ForEach(types, id: \.self) { Text($0.uppercased()).tag($0) }
                }.labelsHidden().fixedSize()
            }
            Text("Source").font(.caption).foregroundStyle(.secondary)
            SourceTextEditor(text: $source)
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(PillButtonStyle(kind: .plain))
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    onCreate(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title,
                             type, source)
                    dismiss()
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 400)
        .background(Color.nBg)
    }
}

/// Shared artifact renderer (html/svg/mermaid via web view, csv table, markdown).
struct ArtifactPreview: View {
    let artifact: Artifact

    var body: some View {
        switch artifact.type {
        case "markdown":
            ScrollView {
                MarkdownText(text: artifact.source)
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
            }
        case "csv":
            CSVTable(source: artifact.source)
        default:
            ArtifactWebView(artifact: artifact)
        }
    }
}
