import SwiftUI
import WebKit
import AppKit
import UniformTypeIdentifiers

struct Artifact: Identifiable, Codable, Equatable {
    var uuid = UUID()          // stable identity — survives a rename (JSON key "id")
    var id: UUID { uuid }
    var title: String
    var type: String // html | svg | mermaid | csv | markdown
    var source: String
    var createdAt = Date()
    var updatedAt = Date()
    var revisions = 1
    var favorite = false
    // Standalone-store metadata (empty/default on legacy conversation-nested copies).
    var origin: String = "interactive"      // interactive | ambient | user
    /// Durable workspace ownership. The conversation remains provenance, not the container.
    var workspaceID: UUID? = nil
    var conversationID: UUID? = nil
    var conversationTitle: String = ""
    var cwd: String = ""

    enum CodingKeys: String, CodingKey {
        case uuid = "id", title, type, source, createdAt, updatedAt, revisions,
             favorite, origin, workspaceID, conversationID, conversationTitle, cwd
    }

    init(title: String, type: String, source: String,
         favorite: Bool = false, origin: String = "interactive",
         workspaceID: UUID? = nil, conversationID: UUID? = nil, conversationTitle: String = "", cwd: String = "",
         uuid: UUID = UUID(), createdAt: Date = Date(), updatedAt: Date = Date(), revisions: Int = 1) {
        self.uuid = uuid; self.title = title; self.type = type; self.source = source
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.revisions = revisions
        self.favorite = favorite; self.origin = origin
        self.workspaceID = workspaceID
        self.conversationID = conversationID; self.conversationTitle = conversationTitle; self.cwd = cwd
    }

    // Tolerant decode: older nested artifacts (and ambient JSON) may lack the newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decodeIfPresent(UUID.self, forKey: .uuid) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        type = try c.decode(String.self, forKey: .type)
        source = try c.decode(String.self, forKey: .source)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        revisions = try c.decodeIfPresent(Int.self, forKey: .revisions) ?? 1
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? "interactive"
        workspaceID = try c.decodeIfPresent(UUID.self, forKey: .workspaceID)
        conversationID = try c.decodeIfPresent(UUID.self, forKey: .conversationID)
        conversationTitle = try c.decodeIfPresent(String.self, forKey: .conversationTitle) ?? ""
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
    }
}

/// Resolve a conversation-cached artifact to its durable record without allowing content equality
/// to become cross-conversation identity. Exact UUIDs are authoritative. The legacy fallback is
/// intentionally narrower: the cached copy must belong (or predate explicit ownership) to the
/// visible conversation, and the durable candidate must carry that conversation plus the same
/// origin. Otherwise the cache remains a read-only snapshot instead of giving its action buttons
/// an unrelated durable UUID.
func storedPanelArtifact(
    matching cached: Artifact,
    in durableArtifacts: [Artifact],
    currentConversationID: UUID?
) -> Artifact? {
    if let exact = durableArtifacts.first(where: { $0.uuid == cached.uuid }) {
        return exact
    }
    guard let currentConversationID,
          cached.conversationID == nil
            || cached.conversationID == currentConversationID else {
        return nil
    }
    let equivalent = durableArtifacts.filter {
        $0.conversationID == currentConversationID
            && $0.origin == cached.origin
            && $0.title == cached.title
            && $0.type == cached.type
            && $0.source == cached.source
    }
    return equivalent.count == 1 ? equivalent[0] : nil
}

struct ArtifactsPanelView: View {
    @EnvironmentObject private var bridge: AgentBridge
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var artifactStore = ArtifactStore.shared
    @ObservedObject private var organizer = ArtifactOrganizationStore.panel
    @State private var isImportTargeted = false // FR-102: highlight while a file drag hovers the panel
    @State private var showRename = false
    @State private var renameText = ""
    @State private var renameTarget: UUID?
    @State private var showDelete = false
    @State private var deleteTarget: UUID?

    private var current: Artifact? {
        panelArtifacts.first { $0.title == bridge.selectedArtifact } ?? panelArtifacts.last
    }

    /// Prefer the durable snapshot so favorite/workspace metadata responds immediately to
    /// ArtifactStore changes. The content-equivalent fallback covers legacy conversation caches
    /// created before durable UUID convergence.
    private var panelArtifacts: [Artifact] {
        bridge.artifacts.map { cached in
            storedArtifact(matching: cached) ?? cached
        }
    }

    private func storedArtifact(matching artifact: Artifact) -> Artifact? {
        storedPanelArtifact(
            matching: artifact,
            in: artifactStore.artifacts,
            currentConversationID: bridge.currentID)
    }

    /// The panel's live artifacts are conversation-scoped, so grouping by conversation would produce
    /// a single group; workspace names resolve from the conversation's own working directory.
    private var panelGroups: [ArtifactGroup] {
        groupedArtifacts(panelArtifacts, by: organizer.organization) { artifact in
            let path = artifact.cwd.isEmpty ? bridge.cwd : artifact.cwd
            return path.isEmpty ? "" : (path as NSString).lastPathComponent
        }
    }

    private func panelMenuLabel(_ a: Artifact) -> String {
        let stamp = organizer.organization.sort == .size
            ? artifactSizeLabel(a)
            : a.updatedAt.formatted(date: .omitted, time: .shortened)
        return "\(a.title)  —  \(a.type) · \(stamp)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = artifactStore.persistenceError {
                PersistenceErrorBanner(
                    message: error,
                    retry: artifactStore.retryFailedSaves)
                Divider()
            }
            if let artifact = current {
                preview(artifact)
                    .contextMenu { artifactContextMenu(artifact) }
            } else {
                Text("No artifacts yet.\nAsk your agent to build a page, chart, or dashboard,\nor drop a file here to add one.")
                    .scaledFont(12)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // FR-102: drop files from Finder into the panel to import them as artifacts in this conversation.
        .dropDestination(for: URL.self) { urls, _ in
            let urls = urls.filter {
                !ArtifactFileExport.contains($0)
                    && ArtifactActions.reference(forExportedURL: $0) == nil
            }
            guard !urls.isEmpty else { return false }
            Task {
                let result = await ArtifactActions.importsAsync(from: urls)
                if result.ready.isEmpty {
                    ArtifactActions.reportNothingImported(skipped: result.skipped)
                } else {
                    bridge.importArtifacts(result.ready)
                    ArtifactActions.reportSkippedImports(result.skipped)
                }
            }
            return true
        } isTargeted: { isImportTargeted = $0 }
        .overlay {
            if isImportTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.nAccent, lineWidth: 2)
                    .padding(4).allowsHitTesting(false)
            }
        }
        .alert("Rename Artifact", isPresented: $showRename) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let id = renameTarget {
                    artifactStore.rename(id, to: renameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete this artifact?",
            isPresented: $showDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = deleteTarget {
                    artifactStore.delete(id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the artifact. You can undo it with Undo in the Edit menu, and agents may re-create it on a later run.")
        }
    }

    /// The title is the Mac-like drag source (document-proxy idiom): Finder receives a real file,
    /// while a Mechanician chat receives an editable artifact reference.
    @ViewBuilder
    private var titleDragHandle: some View {
        if let a = current {
            HStack(spacing: 5) {
                Image(systemName: ArtifactActions.symbol(forType: a.type))
                    .scaledFont(12).foregroundStyle(Color.nInfoText)
                Text(a.title).scaledFont(13, weight: .semibold).lineLimit(1)
            }
            .contentShape(Rectangle())
            .onDrag { ArtifactActions.itemProvider(for: a) }
            .contextMenu { artifactContextMenu(a) }
            .help("Drag to a conversation or Finder · \(a.title)")
        } else {
            Text("Artifacts").scaledFont(13, weight: .semibold)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                titleDragHandle
                if bridge.artifacts.count > 1 {
                    Menu {
                        ForEach(panelGroups) { group in
                            Section(group.title) {
                                ForEach(group.artifacts) { a in
                                    Button {
                                        bridge.selectedArtifact = a.title
                                    } label: {
                                        Text(panelMenuLabel(a))
                                    }
                                }
                            }
                        }
                        Divider()
                        Picker("Sort by", selection: $organizer.organization.sort) {
                            ForEach(ArtifactSort.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Toggle("Reverse order", isOn: $organizer.organization.ascending)
                        Picker("Group by", selection: $organizer.organization.grouping) {
                            ForEach(ArtifactGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Toggle("Favorites on top", isOn: $organizer.organization.favoritesFirst)
                    } label: {
                        Image(systemName: "chevron.up.chevron.down").scaledFont(10).foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Switch artifact, sort, and group").accessibilityLabel("Switch artifact")
                }
                Spacer()
                if let a = current {
                    // FR-102: durable favorite plus Save / Copy / Reveal parity with the manager.
                    // Dragging OUT is on the title itself (the document-proxy idiom), not an icon.
                    Button {
                        artifactStore.setFavorite(a.uuid, !a.favorite)
                    } label: {
                        Image(systemName: a.favorite ? "star.fill" : "star")
                            .foregroundStyle(a.favorite ? Color.nGoldText : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(a.favorite ? "Unfavorite" : "Favorite")
                    .accessibilityLabel(a.favorite ? "Unfavorite artifact" : "Favorite artifact")
                    Button { ArtifactActions.save(a) } label: { Image(systemName: "square.and.arrow.down") }
                        .buttonStyle(.borderless).help("Save to file…").accessibilityLabel("Save to file")
                    Button { ArtifactActions.copySource(a) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy source").accessibilityLabel("Copy source")
                    Button { ArtifactActions.revealInFinder(a) } label: { Image(systemName: "arrow.up.forward.app") }
                        .buttonStyle(.borderless).help("Reveal in Finder").accessibilityLabel("Reveal in Finder")
                }
                // Pop the artifact into its own resizable window — escapes the inspector's
                // width cap and keeps updating live as Claude revises it.
                Button {
                    if let a = current { openPreviewWindow(a) }
                } label: { Image(systemName: "macwindow") }
                .buttonStyle(.borderless)
                .help("Open in a window")
                .accessibilityLabel("Open in a window")
                .disabled(current == nil || bridge.currentID == nil)
            }
            if let a = current {
                HStack(spacing: 6) {
                    Text(a.type.uppercased())
                        .scaledFont(10, weight: .bold, design: .monospaced)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.nAccent.opacity(0.25)))
                    Text("created \(a.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .scaledFont(10).foregroundStyle(.secondary)
                    if a.revisions > 1 {
                        Text("· updated \(a.updatedAt.formatted(date: .omitted, time: .shortened)) · v\(a.revisions)")
                            .scaledFont(10).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private func artifactContextMenu(_ artifact: Artifact) -> some View {
        if bridge.currentID != nil {
            Button { openPreviewWindow(artifact) } label: {
                Label("Open in New Window", systemImage: "macwindow")
            }
            Divider()
        }
        Button {
            artifactStore.setFavorite(artifact.uuid, !artifact.favorite)
        } label: {
            Label(
                artifact.favorite ? "Unfavorite" : "Favorite",
                systemImage: artifact.favorite ? "star.slash" : "star")
        }
        Button {
            renameTarget = artifact.uuid
            renameText = artifact.title
            showRename = true
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        Divider()
        ArtifactFileContextMenuItems(artifact: artifact)
        Divider()
        Button(role: .destructive) {
            deleteTarget = artifact.uuid
            showDelete = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func openPreviewWindow(_ artifact: Artifact) {
        guard let conv = bridge.currentID else { return }
        PreviewRegistry.shared.put(artifact, conv: conv)
        openWindow(value: PreviewPayload(conv: conv, title: artifact.title))
    }

    @ViewBuilder
    private func preview(_ artifact: Artifact) -> some View {
        switch artifact.type {
        case "markdown":
            ScrollView {
                MarkdownText(text: artifact.source)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case "csv":
            CSVTable(source: artifact.source)
        default: // html, svg, mermaid
            ArtifactWebView(artifact: artifact)
        }
    }
}

/// WKWebView that reloads only when the HTML actually changes (so live artifact
/// updates re-render without thrashing).
struct ArtifactWebView: NSViewRepresentable {
    let artifact: Artifact

    /// Read so SwiftUI re-runs `updateNSView` when the appearance flips. A rendered Mermaid diagram
    /// is a frozen SVG that carries its own colors, so unlike every other artifact type it cannot
    /// follow Dark Mode on its own — it has to be rendered again in the other theme (FR-334).
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: SafeHTMLPreview.makeConfiguration())
        web.navigationDelegate = context.coordinator.navigationDelegate
        web.setValue(false, forKey: "drawsBackground")
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.update(
            artifact: artifact,
            theme: colorScheme == .dark ? .dark : .light,
            in: web)
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.cancelRender()
    }

    @MainActor
    final class Coordinator {
        var lastHTML: String?
        let navigationDelegate = SafePreviewNavigationDelegate()

        /// The (theme, source) pair this coordinator has already tried to render. It identifies the
        /// render in flight, so a diagram arriving after the artifact or appearance changed
        /// underneath it is dropped rather than drawn, and it survives a failure so a diagram that
        /// cannot parse is not retried forever.
        private var attemptedRenderKey: String?
        private var renderTask: Task<Void, Never>?

        /// Counts renders this coordinator has started. Only tests read it — it is the one way to
        /// state "a diagram that failed is not rendered again" as an assertion rather than a hope.
        private(set) var rendersStarted = 0

        func cancelRender() {
            renderTask?.cancel()
            renderTask = nil
            attemptedRenderKey = nil
        }

        func update(artifact: Artifact, theme: MermaidRenderer.Theme, in web: WKWebView) {
            guard artifact.type == "mermaid" else {
                cancelRender()
                load(SafeHTMLPreview.artifactDocument(for: artifact), in: web)
                return
            }

            if let svg = MermaidRenderer.cachedSVG(for: artifact.source, theme: theme) {
                cancelRender()
                load(
                    SafeHTMLPreview.artifactDocument(for: artifact, renderedMermaidSVG: svg),
                    in: web)
                return
            }

            // Re-entrant by design: SwiftUI calls `updateNSView` for reasons that have nothing to do
            // with this artifact, and a render must not be restarted on each one. The key outlives
            // the render deliberately — a diagram that failed to parse has no cache entry, so
            // clearing it here would re-render the same broken source on every subsequent update.
            let key = "\(theme.rawValue)\u{1F}\(artifact.source)"
            guard attemptedRenderKey != key else { return }
            cancelRender()
            attemptedRenderKey = key
            load(SafeHTMLPreview.mermaidPlaceholderDocument(), in: web)
            rendersStarted += 1

            renderTask = Task { @MainActor [weak self, weak web] in
                let document: String
                do {
                    let svg = try await MermaidRenderer.svg(for: artifact.source, theme: theme)
                    document = SafeHTMLPreview.artifactDocument(
                        for: artifact, renderedMermaidSVG: svg)
                } catch is CancellationError {
                    return
                } catch {
                    document = SafeHTMLPreview.mermaidFailureDocument(
                        source: artifact.source,
                        message: error.localizedDescription)
                }
                guard let self, let web, !Task.isCancelled, self.attemptedRenderKey == key else {
                    return
                }
                self.renderTask = nil
                self.load(document, in: web)
            }
        }

        private func load(_ html: String, in web: WKWebView) {
            guard lastHTML != html else { return }
            lastHTML = html
            web.loadHTMLString(html, baseURL: nil)
        }
    }
}

/// Minimal CSV renderer (naive split; good enough for simple tables).
/// CSV preview backed by a real parser (FR-336). Quoted commas, escaped `""`, newlines inside
/// fields and CRLF line endings all used to render wrong — the last one turned an entire Excel
/// export into a single row.
struct CSVTable: View {
    let source: String

    /// A preview, not a spreadsheet. Past this many rows the point is "what is in this file", which
    /// the first few thousand answer, and the parser stops scanning rather than reading the rest.
    static let previewRowLimit = 2_000

    /// Parsed once per source change. As a computed property this re-parsed the whole file on every
    /// SwiftUI body evaluation, which for a large export is exactly the kind of work that has no
    /// business on a render path.
    @State private var rows: [[String]] = []
    @State private var truncated = false

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            // Lazy: the previous plain VStack built every row and cell before anything drew.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .scaledFont(11, design: .monospaced)
                                .fontWeight(i == 0 ? .semibold : .regular)
                                .frame(minWidth: 80, alignment: .leading)
                                .padding(6)
                                // A subtle accent tint reads as a header in BOTH appearances;
                                // nElevated would match nBg (invisible) in light.
                                .background(i == 0 ? Color.nAccent.opacity(0.10) : Color.clear)
                        }
                    }
                    Divider()
                }
                if truncated {
                    Text("Showing the first \(Self.previewRowLimit) rows. Open the file to see the rest.")
                        .scaledFont(11)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .padding(8)
        }
        .task(id: source) { reparse() }
    }

    private func reparse() {
        // One row past the limit, so "there is more" is a fact rather than a guess when the file
        // happens to be exactly the limit long.
        let parsed = CSVParser.rows(from: source, maximumRows: Self.previewRowLimit + 1)
        truncated = parsed.count > Self.previewRowLimit
        rows = CSVParser.rectangular(truncated ? Array(parsed.prefix(Self.previewRowLimit)) : parsed)
    }
}
