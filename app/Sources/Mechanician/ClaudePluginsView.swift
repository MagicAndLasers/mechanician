import AppKit
import SwiftUI

func resolvedClaudeMarketplaceTabTitle(
    _ marketplace: ClaudePluginStore.Marketplace,
    among marketplaces: [ClaudePluginStore.Marketplace]
) -> String {
    let namesakes = marketplaces.filter {
        $0.name.caseInsensitiveCompare(marketplace.name) == .orderedSame
    }
    guard namesakes.count > 1 else { return marketplace.name }

    let sameFormat = namesakes.filter {
        $0.isArchiveCatalog == marketplace.isArchiveCatalog
    }
    guard sameFormat.count > 1 else {
        return "\(marketplace.name) · \(marketplace.isArchiveCatalog ? "Archive" : "Claude")"
    }

    if marketplace.isArchiveCatalog,
       let url = URL(string: marketplace.detail),
       let host = url.host {
        let path = url.path == "/" ? "" : url.path
        return "\(marketplace.name) · \(host)\(path)"
    }
    if let sourceID = marketplace.archiveSourceID {
        return "\(marketplace.name) · \(sourceID.uuidString.prefix(8))"
    }
    return "\(marketplace.name) · \(marketplace.detail)"
}

/// Claude plugin marketplaces.
///
/// **Marketplaces are the tabs.** The thing you would otherwise open a modal to configure becomes
/// the browsing surface itself. The Sources sheet this replaces listed sources without ever showing
/// what was in them — a dead end by construction, because you had to open it to learn what you could
/// even look at.
///
/// Its own destination, not a tab beside MCP: a Claude plugin cannot install into Codex, and one
/// filtered list would imply a portability that does not exist.
struct ClaudePluginsView: View {
    @ObservedObject private var store = ClaudePluginStore.shared
    @ObservedObject private var extensions = ExtensionsStore.shared
    @ObservedObject private var active = ActiveWorkspace.shared
    @State private var selection = Tab.installed
    @State private var search = ""
    @State private var category: String?
    @State private var contains: ClaudePluginStore.Contains = .any
    @State private var detail: ClaudePluginStore.Available?
    @State private var installedDetail: ClaudePluginStore.Installed?
    @State private var confirmingUninstall: ClaudePluginStore.Installed?
    @State private var newMarketplace = ""
    @State private var newMarketplaceName = ""
    @State private var newMarketplaceFormat: MarketplaceFormat = .claudeMarketplace
    @State private var addingMarketplace = false
    @State private var marketplacePersistenceError: String?

    private enum Tab: Hashable {
        case installed
        case marketplace(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider()
            if let error = store.lastError { errorBar(error) }
            if let error = marketplacePersistenceError { errorBar(error) }
            content
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Color.nBg)
        .onAppear {
            store.loadIfNeeded(bridge: active.bridge)
            store.retryArchiveCleanups(bridge: active.bridge)
        }
        .task(id: archiveMarketplaceSources) {
            await store.loadArchiveCatalog(
                via: active.bridge,
                sources: archiveMarketplaceSources)
        }
        .sheet(item: $detail) { detailSheet($0) }
        .sheet(item: $installedDetail) { installedDetailSheet($0) }
        // Uninstall deletes the plugin from disk, so it asks. Disable, which is reversible,
        // deliberately does not.
        .confirmationDialog(
            "Uninstall \(confirmingUninstall?.shortName ?? "this plugin")?",
            isPresented: Binding(get: { confirmingUninstall != nil },
                                 set: { if !$0 { confirmingUninstall = nil } }),
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                if let plugin = confirmingUninstall {
                    store.uninstall(plugin.pluginId, bridge: active.bridge)
                }
                confirmingUninstall = nil
            }
            Button("Cancel", role: .cancel) { confirmingUninstall = nil }
        } message: {
            Text("Its skills, commands and servers are removed from every conversation. "
               + "Disable instead if you only want to switch it off for now.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Plugins").font(.system(size: 19, weight: .semibold))
                Text("Extend Claude with ready-made skills, agents, hooks and MCP servers.")
                    .font(.caption).foregroundStyle(Color.nSecondaryText)
            }
            Spacer(minLength: 16)
            if store.isWorking || !store.archiveCatalogLoading.isEmpty {
                ProgressView().controlSize(.small)
            }
            Button { refreshAll() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Refresh marketplaces and plugins")
            .accessibilityLabel("Refresh")
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                tabButton("Installed", count: store.installed.count, tab: .installed)
                ForEach(store.marketplaces) { marketplace in
                    tabButton(marketplaceTabTitle(marketplace),
                              count: store.plugins(in: marketplace).count,
                              tab: .marketplace(marketplace.id))
                }
                Button {
                    marketplacePersistenceError = nil
                    addingMarketplace = true
                } label: {
                    Label("Add Marketplace", systemImage: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(Color.nInfoText)
                .padding(.leading, 8)
                .accessibilityLabel("Add a marketplace")
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
        }
        .sheet(isPresented: $addingMarketplace) { addMarketplaceSheet }
    }

    private func tabButton(_ title: String, count: Int, tab: Tab) -> some View {
        let selected = selection == tab
        return Button { selection = tab; search = ""; category = nil; contains = .any } label: {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                if count > 0 {
                    Text("\(count)").font(.caption2)
                        .foregroundStyle(selected ? Color.nText : Color.nSecondaryText)
                }
            }
            .font(.system(size: 13, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.nText : Color.nSecondaryText)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.nAccent.opacity(0.30) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func marketplaceTabTitle(_ marketplace: ClaudePluginStore.Marketplace) -> String {
        resolvedClaudeMarketplaceTabTitle(marketplace, among: store.marketplaces)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .installed: installedPane
        case .marketplace(let id):
            if let marketplace = store.marketplaces.first(where: { $0.id == id }) {
                marketplacePane(marketplace)
            }
        }
    }

    // MARK: installed

    private var installedPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if store.installed.isEmpty {
                    Text("No plugins installed. Pick a marketplace above to see what is available.")
                        .font(.caption).foregroundStyle(Color.nSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(store.installed) { plugin in
                    HStack(spacing: 10) {
                        Image(systemName: "shippingbox")
                            .foregroundStyle(Color.nInfoText).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(plugin.shortName).fontWeight(.medium)
                                if let version = plugin.version {
                                    Text("v\(version)").font(.caption2)
                                        .foregroundStyle(Color.nSecondaryText)
                                }
                                if !plugin.enabled {
                                    Text("Disabled").font(.caption2)
                                        .foregroundStyle(Color.nWarningText)
                                }
                            }
                            // Where it came from, always — the question that made a list of seven
                            // MCP servers unrecognisable to its owner.
                            Text(plugin.marketplaceName)
                                .font(.caption).foregroundStyle(Color.nSecondaryText)
                        }
                        Spacer(minLength: 8)
                        // What it actually put in your session, at a glance. The full named
                        // inventory is one click away in the detail sheet.
                        if let summary = installedSummary(plugin) {
                            Text(summary).font(.caption2)
                                .foregroundStyle(Color.nSecondaryText)
                        }
                        if let cost = plugin.tokenCost, cost.alwaysOn > 0 {
                            Text("\(cost.alwaysOn)/turn")
                                .font(.caption2).foregroundStyle(Color.nSecondaryText)
                                .help("Costs \(cost.alwaysOn) tokens of context on every turn, "
                                    + "whether or not it is used")
                        }
                        if store.busyPluginID == plugin.pluginId {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(plugin.enabled ? "Disable" : "Enable") {
                                store.setEnabled(plugin.pluginId, !plugin.enabled, bridge: active.bridge)
                            }
                            .buttonStyle(PillButtonStyle(kind: .neutral))
                            .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.nSurface))
                    // An installed plugin gets the same card as an uninstalled one. "What did I put
                    // in here, and what is it costing me" is the same question as "what would this
                    // install", asked after the fact — and it was only answerable before.
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { installedDetail = plugin }
                    .contextMenu { installedMenu(plugin) }
                    .accessibilityHint("Show details")
                }
            }
            .padding(16)
        }
    }

    /// Right-click on an installed plugin. Uninstall lives here rather than on the row because it
    /// is destructive and the row's primary action is "tell me more", but it must EXIST — the app
    /// previously offered no way to remove a plugin at all, only to disable it.
    @ViewBuilder
    private func installedMenu(_ plugin: ClaudePluginStore.Installed) -> some View {
        Button("Show Details") { installedDetail = plugin }
        Button(plugin.enabled ? "Disable" : "Enable") {
            store.setEnabled(plugin.pluginId, !plugin.enabled, bridge: active.bridge)
        }
        Button("Check for Update") { store.update(plugin.pluginId, bridge: active.bridge) }
        Divider()
        Button("Copy Plugin ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(plugin.pluginId, forType: .string)
        }
        Divider()
        Button("Uninstall…", role: .destructive) { confirmingUninstall = plugin }
    }

    /// "14 skills · 1 hook" — plural-correct, and silent when there is nothing to say.
    private func installedSummary(_ plugin: ClaudePluginStore.Installed) -> String? {
        guard let groups = plugin.components?.groups, !groups.isEmpty else {
            return plugin.mcpServers.isEmpty ? nil : "\(plugin.mcpServers.count) MCP"
        }
        return groups.map { group in
            let noun = group.names.count == 1
                ? String(group.label.dropLast(group.label.hasSuffix("s") ? 1 : 0))
                : group.label
            return "\(group.names.count) \(noun.lowercased())"
        }
        .joined(separator: " · ")
    }

    /// The installed plugin's own card. Separate from `detail` because the two lists carry
    /// different types — an installed record knows its version and enablement, a catalog entry
    /// knows its description and links.
    private func installedDetailSheet(_ plugin: ClaudePluginStore.Installed) -> some View {
        // The catalog entry may or may not exist — the CLI drops installed plugins from `available`.
        // Everything the card needs now arrives on the installed record itself; this is only for the
        // extra source URL.
        let catalog = store.available.first { $0.pluginId == plugin.pluginId }
        return DetailSheet(width: 520, height: 480, onClose: { installedDetail = nil }) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(catalog?.title ?? plugin.shortName)
                        .font(.system(size: 17, weight: .semibold))
                    if let author = plugin.authorName {
                        Text("by \(author)").font(.caption)
                            .foregroundStyle(Color.nSecondaryText)
                    }
                    HStack(spacing: 6) {
                        if let category = plugin.category {
                            Text(category).font(.caption2)
                                .lineLimit(1).fixedSize()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(
                                    Color.nSecondaryText.opacity(0.14)))
                                .foregroundStyle(Color.nSecondaryText)
                        }
                        Text(plugin.enabled ? "Enabled" : "Disabled")
                            .font(.caption2)
                            .foregroundStyle(
                                plugin.enabled ? Color.nSuccessText : Color.nWarningText)
                        if let version = plugin.version {
                            Text("v\(version)").font(.caption2)
                                .foregroundStyle(Color.nSecondaryText)
                        }
                        if let scope = plugin.scope {
                            Text(scope).font(.caption2)
                                .foregroundStyle(Color.nSecondaryText)
                        }
                        if let installs = plugin.installCount, installs > 0 {
                            Text(Self.compactCount(installs))
                                .font(.caption2).foregroundStyle(Color.nSecondaryText)
                        }
                    }
                    .padding(.top, 2)
                }

                if !plugin.description.isEmpty {
                    Text(plugin.description).font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }

                if let components = plugin.components ?? catalog?.components, !components.isEmpty {
                    Self.componentsSection(components)
                }
                if let cost = plugin.tokenCost ?? catalog?.tokenCost { Self.tokenCostSection(cost) }

                VStack(alignment: .leading, spacing: 4) {
                    Text("From \(plugin.marketplaceName)")
                        .font(.caption).foregroundStyle(Color.nSecondaryText)
                    Text(plugin.pluginId)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.nSecondaryText).textSelection(.enabled)
                }

                let links = installedLinks(plugin, catalog: catalog)
                if !links.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Links").font(.caption)
                            .foregroundStyle(Color.nSecondaryText)
                        ForEach(links, id: \.title) { link in
                            Link(destination: link.url) {
                                HStack(spacing: 5) {
                                    Text(link.title)
                                    Image(systemName: "arrow.up.right").font(.caption2)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
            }
        } actions: {
            Button(plugin.enabled ? "Disable" : "Enable") {
                store.setEnabled(plugin.pluginId, !plugin.enabled, bridge: active.bridge)
            }
            .buttonStyle(PillButtonStyle(kind: .neutral))
            Button("Uninstall…") {
                installedDetail = nil
                confirmingUninstall = plugin
            }
            .buttonStyle(PillButtonStyle(kind: .destructive))
        }
    }

    private func installedLinks(_ plugin: ClaudePluginStore.Installed,
                                catalog: ClaudePluginStore.Available?)
        -> [(title: String, url: URL)] {
        [("Homepage", plugin.homepage), ("Author", plugin.authorURL),
         ("Source", catalog?.sourceURL)]
            .compactMap { title, raw in
                guard let raw, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true
                else { return nil }
                return (title: title, url: url)
            }
    }

    // MARK: one marketplace

    private func marketplacePane(_ marketplace: ClaudePluginStore.Marketplace) -> some View {
        let name = marketplace.name
        let plugins = store.plugins(in: marketplace, matching: search,
                                    category: category, contains: contains)
        let categories = store.categories(in: marketplace)
        let containsCounts = store.containsCounts(in: marketplace)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                    TextField("Search \(store.plugins(in: marketplace).count) plugins",
                              text: $search)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Search plugins")
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .cardSurface(cornerRadius: 7)
                Text(marketplace.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                if marketplace.isManaged {
                    Text("Managed")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.nInfoText)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.nAccent.opacity(0.16)))
                }
                Button("Refresh") {
                    if marketplace.isArchiveCatalog {
                        refreshArchiveCatalog()
                    } else {
                        store.updateMarketplace(name, bridge: active.bridge)
                    }
                }
                    .buttonStyle(PillButtonStyle(kind: .neutral)).controlSize(.small)
                if !marketplace.isManaged {
                    Button("Remove") {
                        if let sourceID = marketplace.archiveSourceID {
                            if extensions.removeMarketplace(sourceID) {
                                selection = .installed
                                marketplacePersistenceError = nil
                            } else {
                                marketplacePersistenceError = extensions.persistenceError
                                    ?? "The marketplace could not be removed."
                            }
                        } else {
                            selection = .installed
                            store.removeMarketplace(name, bridge: active.bridge)
                        }
                    }
                        .buttonStyle(PillButtonStyle(kind: .destructive)).controlSize(.small)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            containsBar(containsCounts)
            if categories.count > 1 { categoryBar(categories) }

            ScrollView {
                if store.isArchiveMarketplaceLoading(marketplace), plugins.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading this marketplace…")
                            .font(.caption).foregroundStyle(Color.nSecondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                } else if let issue = store.archiveIssue(in: marketplace), plugins.isEmpty {
                    archiveIssueBar(issue)
                        .padding(16)
                } else if plugins.isEmpty {
                    Text(search.isEmpty ? "This marketplace lists no plugins."
                                        : "Nothing matches “\(search)”.")
                        .font(.caption).foregroundStyle(Color.nSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                    ForEach(plugins) { plugin in pluginCard(plugin) }
                }
                .padding(16)
            }
        }
    }

    /// What a plugin CONTAINS, as a filter row above the categories.
    ///
    /// Category answers "what is this for?"; this answers "what does it put in my session?" — and
    /// they are different questions people actually ask. "Which of these adds an MCP server" is not
    /// answerable from a category at all. A facet that would return nothing is not offered, because
    /// a chip you can click to reach an empty grid is worse than no chip.
    private func containsBar(_ counts: [ClaudePluginStore.Contains: Int]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ClaudePluginStore.Contains.allCases) { facet in
                    if (counts[facet] ?? 0) > 0 {
                        let selected = contains == facet
                        Button { contains = facet } label: {
                            HStack(spacing: 4) {
                                Text(facet.label)
                                Text("\(counts[facet] ?? 0)")
                                    .foregroundStyle(selected ? Color.nText.opacity(0.7)
                                                              : Color.secondary.opacity(0.7))
                            }
                            .font(.system(size: 11, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.nText : .secondary)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(Capsule().fill(selected ? Color.nAccent.opacity(0.30)
                                                                : Color.secondary.opacity(0.12)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(facet.help)
                        .accessibilityLabel("\(facet.label), \(counts[facet] ?? 0) plugins")
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }

    /// Category is the taxonomy Anthropic's data actually carries — 95% of entries across 14 values.
    /// Ordering the grid by install count and letting you narrow by category is what turns a flat
    /// 272-item list into something you can shop.
    private func categoryBar(_ categories: [(name: String, count: Int)]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                categoryChip("All", count: categories.reduce(0) { $0 + $1.count }, value: nil)
                ForEach(categories, id: \.name) { entry in
                    categoryChip(entry.name, count: entry.count, value: entry.name)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
        }
    }

    private func categoryChip(_ title: String, count: Int, value: String?) -> some View {
        let selected = category == value
        return Button { category = value } label: {
            HStack(spacing: 4) {
                Text(title)
                Text("\(count)")
                    .foregroundStyle(selected ? Color.nText.opacity(0.7)
                                              : Color.nSecondaryText)
            }
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.nText : Color.nSecondaryText)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(selected ? Color.nAccent.opacity(0.30)
                                                : Color.nSecondaryText.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) plugins")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Text-only, and that part of the old reasoning still holds: there is genuinely no icon field
    /// anywhere in Anthropic's plugin schema, so a card reserving space for art would render a grid
    /// of empty boxes. Everything else it used to say was wrong — category, author and install
    /// counts all exist, and they are what a person needs to choose between two similar plugins.
    private func pluginCard(_ plugin: ClaudePluginStore.Available) -> some View {
        let installed = store.isInstalled(plugin.pluginId)
        let busy = store.busyPluginID == plugin.pluginId
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(plugin.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if plugin.isManaged {
                        Text("Managed")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.nInfoText)
                    }
                }
                if let author = plugin.authorName {
                    Text("by \(author)").font(.caption2)
                        .foregroundStyle(Color.nSecondaryText).lineLimit(1)
                }
            }
            Text(plugin.description)
                .font(.caption).foregroundStyle(Color.nSecondaryText)
                .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if let category = plugin.category {
                    Text(category).font(.caption2)
                        // A card footer is narrow; without this the chip hyphenates itself into
                        // "productivi-ty", which reads as a rendering bug because it is one.
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.nSecondaryText.opacity(0.14)))
                        .foregroundStyle(Color.nSecondaryText)
                }
                if let installs = plugin.installCount, installs > 0 {
                    Text(Self.compactCount(installs))
                        .font(.caption2).foregroundStyle(Color.nSecondaryText)
                        .help("\(installs) installs")
                }
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                } else if installed {
                    Text("Installed").font(.caption).foregroundStyle(Color.nSuccessText)
                } else if plugin.canInstall {
                    Button("Install") { store.install(plugin, bridge: active.bridge) }
                        .buttonStyle(PillButtonStyle(kind: .accent)).controlSize(.small)
                        .accessibilityLabel("Install \(plugin.title)")
                } else {
                    Label("Unavailable", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Color.nSecondaryText)
                        .help(plugin.installUnavailableReason
                            ?? "This marketplace entry cannot be installed.")
                }
            }
        }
        .padding(12)
        .frame(minHeight: 150, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.nSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.nMuted.opacity(0.30)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { detail = plugin }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Show details")
    }

    /// What the plugin actually contains, named. "3 skills" is a fact; naming them is the difference
    /// between a claim and something you can check.
    @ViewBuilder
    static func componentsSection(_ components: ClaudePluginStore.Components) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What's inside").font(.caption)
                .foregroundStyle(Color.nSecondaryText)
            ForEach(components.groups, id: \.label) { group in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(group.label).font(.caption.weight(.medium))
                        Text("\(group.names.count)").font(.caption2)
                            .foregroundStyle(Color.nSecondaryText)
                    }
                    Text(group.names.joined(separator: ", "))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.nSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.nSurface))
            }
        }
    }

    /// The cost of having it enabled. `alwaysOn` is the number that matters and the one nobody
    /// shows: it is spent on every single turn, whether or not the plugin is used.
    static func tokenCostSection(_ cost: ClaudePluginStore.TokenCost) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Context cost").font(.caption)
                .foregroundStyle(Color.nSecondaryText)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(cost.alwaysOn) tokens").font(.caption.weight(.medium))
                    Text("every turn").font(.caption2)
                        .foregroundStyle(Color.nSecondaryText)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(cost.onInvoke) tokens").font(.caption.weight(.medium))
                    Text("when used").font(.caption2)
                        .foregroundStyle(Color.nSecondaryText)
                }
                Spacer()
                Text(cost.model).font(.caption2)
                    .foregroundStyle(Color.nSecondaryText)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.nSurface))
        }
    }

    /// "404K installs", not "404331 installs". The magnitude is the signal; the digits are noise.
    static func compactCount(_ value: Int) -> String {
        switch value {
        case 1_000_000...: return "\(value / 1_000_000)M installs"
        case 1_000...: return "\(value / 1_000)K installs"
        default: return "\(value) installs"
        }
    }

    // MARK: detail

    /// The card clamps a description that runs to 665 characters at four lines, which cuts the
    /// longest ones mid-sentence with no way to read the rest. This is the rest — plus the homepage,
    /// which is on 94% of entries and is the only way to check a plugin before running it.
    private func detailSheet(_ plugin: ClaudePluginStore.Available) -> some View {
        let installed = store.isInstalled(plugin.pluginId)
        return DetailSheet(width: 520, height: 460, onClose: { detail = nil }) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.title).font(.system(size: 17, weight: .semibold))
                        if let author = plugin.authorName {
                            Text("by \(author)").font(.caption)
                                .foregroundStyle(Color.nSecondaryText)
                        }
                        HStack(spacing: 6) {
                            if let category = plugin.category {
                                Text(category).font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(
                                        Color.nSecondaryText.opacity(0.14)))
                                    .foregroundStyle(Color.nSecondaryText)
                            }
                            if let installs = plugin.installCount, installs > 0 {
                                Text(Self.compactCount(installs))
                                    .font(.caption2)
                                    .foregroundStyle(Color.nSecondaryText)
                            }
                            if plugin.isManaged {
                                Text("Managed").font(.caption2)
                                    .foregroundStyle(Color.nInfoText)
                            }
                        }
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 8)
                    if store.busyPluginID == plugin.pluginId {
                        ProgressView().controlSize(.small)
                    } else if installed {
                        Text("Installed").font(.caption).foregroundStyle(Color.nSuccessText)
                    } else if plugin.canInstall {
                        Button("Install") { store.install(plugin, bridge: active.bridge) }
                            .buttonStyle(PillButtonStyle(kind: .accent)).controlSize(.small)
                    }
                }

                Text(plugin.description)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if let components = plugin.components, !components.isEmpty {
                    Self.componentsSection(components)
                }
                if let cost = plugin.tokenCost { Self.tokenCostSection(cost) }

                if !plugin.canInstall {
                    Label(
                        plugin.installUnavailableReason
                            ?? "This marketplace entry cannot be installed.",
                        systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color.nSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("From \(plugin.marketplaceName)")
                        .font(.caption).foregroundStyle(Color.nSecondaryText)
                    Text(plugin.pluginId)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.nSecondaryText).textSelection(.enabled)
                }

                let links = detailLinks(plugin)
                if !links.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Before you install").font(.caption)
                            .foregroundStyle(Color.nSecondaryText)
                        ForEach(links, id: \.title) { link in
                            Link(destination: link.url) {
                                HStack(spacing: 5) {
                                    Text(link.title)
                                    Image(systemName: "arrow.up.right").font(.caption2)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
            }
        } actions: {
            if !installed, plugin.canInstall, store.busyPluginID != plugin.pluginId {
                Button("Install") { store.install(plugin, bridge: active.bridge) }
                    .buttonStyle(PillButtonStyle(kind: .accent))
            }
        }
    }

    private func detailLinks(_ plugin: ClaudePluginStore.Available) -> [(title: String, url: URL)] {
        [("Homepage", plugin.homepage),
         ("Author", plugin.authorURL),
         ("Source", plugin.sourceURL)]
            .compactMap { title, raw in
                guard let raw, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true
                else { return nil }
                return (title: title, url: url)
            }
    }

    // MARK: add

    private var addMarketplaceSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a marketplace").font(.headline)
            if let error = marketplacePersistenceError {
                errorBar(error)
            }
            Picker("Format", selection: $newMarketplaceFormat) {
                Text("Claude marketplace").tag(MarketplaceFormat.claudeMarketplace)
                Text("Plugin archive registry").tag(MarketplaceFormat.archiveRegistryV1)
            }
            .pickerStyle(.segmented)
            if newMarketplaceFormat == .archiveRegistryV1 {
                TextField("Marketplace name (optional)", text: $newMarketplaceName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Marketplace name")
            }
            Text(newMarketplaceFormat == .claudeMarketplace
                 ? "A GitHub repository (owner/repo), a marketplace URL, or a local path."
                 : "An HTTPS registry whose entries point to plugin .tar.gz archives.")
                .font(.caption).foregroundStyle(.secondary)
            TextField(newMarketplaceFormat == .claudeMarketplace
                      ? "anthropics/knowledge-work-plugins"
                      : "https://plugins.example.com/registry.json",
                      text: $newMarketplace)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Marketplace source")
            HStack {
                Spacer()
                Button("Cancel") {
                    addingMarketplace = false
                    marketplacePersistenceError = nil
                    resetNewMarketplace()
                }
                    .buttonStyle(PillButtonStyle(kind: .neutral))
                Button("Add") {
                    let location = newMarketplace
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if newMarketplaceFormat == .archiveRegistryV1 {
                        var source = MarketplaceSource()
                        source.name = newMarketplaceName
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        source.repo = location
                        source.format = .archiveRegistryV1
                        guard extensions.upsert(source) else {
                            marketplacePersistenceError = extensions.persistenceError
                                ?? "The marketplace could not be saved."
                            return
                        }
                    } else {
                        store.addMarketplace(location, bridge: active.bridge)
                    }
                    marketplacePersistenceError = nil
                    addingMarketplace = false
                    resetNewMarketplace()
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .disabled(!newMarketplaceIsValid)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440)
        .background(Color.nBg)
    }

    private var newMarketplaceIsValid: Bool {
        let location = newMarketplace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty else { return false }
        if newMarketplaceFormat == .archiveRegistryV1 {
            guard let url = URL(string: location),
                  url.scheme?.lowercased() == "https",
                  url.host != nil,
                  url.user == nil, url.password == nil,
                  url.fragment == nil else { return false }
        }
        return true
    }

    private func resetNewMarketplace() {
        newMarketplace = ""
        newMarketplaceName = ""
        newMarketplaceFormat = .claudeMarketplace
    }

    private func errorBar(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.nWarningText)
            Text(message).font(.caption).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private var archiveMarketplaceSources: [MarketplaceSource] {
        extensions.effectiveMarketplaceSources.filter { $0.format == .archiveRegistryV1 }
    }

    private func refreshAll() {
        store.refresh(bridge: active.bridge)
        store.retryArchiveCleanups(bridge: active.bridge)
        refreshArchiveCatalog()
    }

    private func refreshArchiveCatalog() {
        Task {
            await store.loadArchiveCatalog(
                via: active.bridge,
                sources: archiveMarketplaceSources)
        }
    }

    private func archiveIssueBar(_ issue: ExtensionSourceIssue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: issue.systemImage).foregroundStyle(Color.nWarningText)
            VStack(alignment: .leading, spacing: 5) {
                Text(issue.message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    if issue.needsGoogleReconnect {
                        Button("Reconnect Google") {
                            active.bridge?.reconnectAccount(.claudeVertex)
                        }
                        .buttonStyle(PillButtonStyle(kind: .accent))
                        .controlSize(.small)
                        .disabled(active.bridge == nil)
                    }
                    if issue.isRetryable || issue.needsGoogleReconnect {
                        Button("Retry Catalog") { refreshArchiveCatalog() }
                            .buttonStyle(PillButtonStyle(kind: .neutral))
                            .controlSize(.small)
                    }
                }
            }
            Spacer(minLength: 8)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }
}
