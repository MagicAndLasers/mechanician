import AppKit
import SwiftUI

/// Codex plugin marketplaces — the same screen as Claude Plugins, with the differences the two
/// catalogs genuinely have.
///
/// Its own destination, not a provider toggle beside Claude's: a Codex plugin cannot install into
/// Claude, and one filtered list would imply a portability that does not exist.
///
/// Two things differ from the Claude screen, both because the data does:
///   * Cards carry a logo, category and developer — Codex's `interface` provides them; Anthropic's
///     browse feed returns four text fields, so its cards are text.
///   * Search is mandatory, not a nicety: `openai-curated-remote` lists 2,255 plugins, and a grid
///     of 2,255 cards is not a browsing experience.
struct CodexPluginsView: View {
    @ObservedObject private var store = CodexPluginStore.shared
    @ObservedObject private var active = ActiveWorkspace.shared
    @State private var selection = Tab.installed
    @State private var search = ""
    @State private var category: String?
    @State private var detail: CodexPluginStore.Plugin?
    @State private var newMarketplace = ""
    @State private var addingMarketplace = false
    /// Uninstall deletes the plugin from disk, so it asks — the same rule the Claude browser
    /// applies to the identical operation. A one-click Remove here was the only asymmetry.
    @State private var confirmingRemove: CodexPluginStore.Plugin?

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
            content
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Color.nBg)
        .onAppear { store.loadIfNeeded(bridge: active.bridge) }
        .sheet(item: $detail) { detailSheet($0) }
        .confirmationDialog(
            "Remove \(confirmingRemove?.name ?? "this plugin")?",
            isPresented: Binding(get: { confirmingRemove != nil },
                                 set: { if !$0 { confirmingRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let plugin = confirmingRemove {
                    store.uninstall(plugin.pluginId, bridge: active.bridge)
                }
                confirmingRemove = nil
            }
            Button("Cancel", role: .cancel) { confirmingRemove = nil }
        } message: {
            Text("It is deleted from disk and removed from every conversation.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Plugins").font(.system(size: 19, weight: .semibold))
                Text("Extend Codex with skills, apps, hooks and MCP servers.")
                    .font(.caption).foregroundStyle(Color.nSecondaryText)
            }
            Spacer(minLength: 16)
            if store.isWorking { ProgressView().controlSize(.small) }
            Button { store.refresh(bridge: active.bridge) } label: {
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
                    tabButton(marketplace.name, count: marketplace.count,
                              tab: .marketplace(marketplace.name))
                }
                Button { addingMarketplace = true } label: {
                    Label("Add Marketplace", systemImage: "plus").font(.system(size: 12))
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
        return Button { selection = tab; search = ""; category = nil } label: {
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

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .installed: installedPane
        case .marketplace(let name): marketplacePane(name)
        }
    }

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
                        logo(plugin, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(plugin.name).fontWeight(.medium)
                                if let version = plugin.version {
                                    Text("v\(version)").font(.caption2)
                                        .foregroundStyle(Color.nSecondaryText)
                                }
                            }
                            Text(plugin.marketplaceName)
                                .font(.caption).foregroundStyle(Color.nSecondaryText)
                        }
                        Spacer(minLength: 8)
                        if store.busyPluginID == plugin.pluginId {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Remove") {
                                store.uninstall(plugin.pluginId, bridge: active.bridge)
                            }
                            .buttonStyle(PillButtonStyle(kind: .neutral)).controlSize(.small)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.nSurface))
                    // The same card as an uninstalled entry. An installed plugin is exactly the
                    // thing you most want to look up — what it does, what it can reach, whose terms
                    // you agreed to — and that was only available before installing.
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { detail = plugin }
                    .contextMenu {
                        Button("Show Details") { detail = plugin }
                        if let raw = plugin.websiteUrl, let url = URL(string: raw) {
                            Link("Open Website", destination: url)
                        }
                        Divider()
                        Button("Copy Plugin ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(plugin.pluginId, forType: .string)
                        }
                        Divider()
                        Button("Remove…", role: .destructive) { confirmingRemove = plugin }
                    }
                    .accessibilityHint("Show details")
                }
            }
            .padding(16)
        }
    }

    private func marketplacePane(_ name: String) -> some View {
        let marketplace = store.marketplaces.first { $0.name == name }
        let matches = store.plugins(inMarketplace: name, matching: search, category: category)
        let categories = store.categories(inMarketplace: name)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                    TextField("Search \(marketplace?.count ?? 0) plugins", text: $search)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Search plugins")
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .cardSurface(cornerRadius: 7)
                if let marketplace, !marketplace.remote {
                    Button("Refresh") { store.upgradeMarketplace(name, bridge: active.bridge) }
                        .buttonStyle(PillButtonStyle(kind: .neutral)).controlSize(.small)
                    if marketplace.removable {
                        Button("Remove") { store.removeMarketplace(name, bridge: active.bridge) }
                            .buttonStyle(PillButtonStyle(kind: .destructive)).controlSize(.small)
                    } else {
                        // Registered for you because it ships on this Mac, and re-registered on the
                        // next launch. A Remove button here would silently undo itself.
                        Text(marketplace.detail).font(.caption2)
                            .foregroundStyle(Color.nSecondaryText)
                    }
                } else {
                    // A remote catalog is OpenAI's, not yours: there is nothing local to refresh
                    // and nothing to remove, so say so instead of offering dead buttons.
                    Text("Remote catalog").font(.caption2)
                        .foregroundStyle(Color.nSecondaryText)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            if categories.count > 1 { categoryBar(categories) }

            ScrollView {
                if matches.isEmpty {
                    Text(search.isEmpty ? "This marketplace lists no plugins."
                                        : "Nothing matches “\(search)”.")
                        .font(.caption).foregroundStyle(Color.nSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                    ForEach(matches.prefix(300)) { plugin in pluginCard(plugin) }
                }
                .padding(16)
                if matches.count > 300 {
                    // Never silently truncate: a capped list that looks complete is a lie about
                    // what is available.
                    Text("Showing 300 of \(matches.count). Search to narrow it down.")
                        .font(.caption2).foregroundStyle(Color.nSecondaryText)
                        .padding(.bottom, 16)
                }
            }
        }
    }

    /// Category is the browse axis, because it is the one that exists: ~100% coverage across 13
    /// values. A 2,216-card grid with only a search box assumes you already know what you want;
    /// these chips are what make it browsable by someone who does not.
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

    private func pluginCard(_ plugin: CodexPluginStore.Plugin) -> some View {
        let busy = store.busyPluginID == plugin.pluginId
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                logo(plugin, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(plugin.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let developer = plugin.developerName {
                        Text(developer).font(.caption2)
                            .foregroundStyle(Color.nSecondaryText).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
            }
            Text(plugin.description)
                .font(.caption).foregroundStyle(Color.nSecondaryText)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
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
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                } else if plugin.installed {
                    Text("Installed").font(.caption).foregroundStyle(Color.nSuccessText)
                } else if plugin.installable {
                    Button("Install") { requestInstallation(plugin) }
                        .buttonStyle(PillButtonStyle(kind: .accent)).controlSize(.small)
                        .accessibilityLabel("Install \(plugin.name)")
                } else {
                    Text("Unavailable").font(.caption2)
                        .foregroundStyle(Color.nSecondaryText)
                        .help(plugin.installationUnavailableReason)
                }
            }
        }
        .padding(12)
        .frame(minHeight: 150, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.nSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.nMuted.opacity(0.30)))
        // The whole card opens the detail, because deciding is the point of browsing and a
        // 27-character summary cannot support a decision. Install stays a separate hit target.
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { detail = plugin }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Show details")
    }

    // MARK: detail

    /// What a card cannot hold: the real description, what it suggests you ask it, screenshots, and
    /// the links that let you check a vendor before handing it your account. All of it was already
    /// crossing the wire and being thrown away.
    private func detailSheet(_ plugin: CodexPluginStore.Plugin) -> some View {
        DetailSheet(width: 560, height: 580, onClose: { detail = nil }) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    logo(plugin, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.name).font(.system(size: 17, weight: .semibold))
                        if let developer = plugin.developerName {
                            Text(developer).font(.caption)
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
                            if let version = plugin.version {
                                Text("v\(version)").font(.caption2)
                                    .foregroundStyle(Color.nSecondaryText)
                            }
                        }
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 8)
                    detailAction(plugin)
                }

                Text(plugin.longDescription ?? plugin.description)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if !plugin.installed && plugin.installationDecision == .reviewDetails {
                    Label(
                        "Review this plugin's developer, capabilities, privacy policy, and terms before installing.",
                        systemImage: "exclamationmark.shield")
                        .font(.caption)
                        .foregroundStyle(Color.nSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !plugin.installed && plugin.installationDecision == .unavailable {
                    Label(
                        plugin.installationUnavailableReason,
                        systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color.nSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !plugin.defaultPrompt.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Try asking").font(.caption)
                            .foregroundStyle(Color.nSecondaryText)
                        ForEach(plugin.defaultPrompt, id: \.self) { prompt in
                            Text("“\(prompt)”")
                                .font(.caption).foregroundStyle(Color.nSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color.nSurface))
                        }
                    }
                }

                if !plugin.capabilities.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What it does").font(.caption)
                            .foregroundStyle(Color.nSecondaryText)
                        Text(plugin.capabilities.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Color.nSecondaryText)
                    }
                }

                if !plugin.screenshotUrls.isEmpty { screenshots(plugin.screenshotUrls) }

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
            detailAction(plugin)
        }
    }

    @ViewBuilder
    private func detailAction(_ plugin: CodexPluginStore.Plugin) -> some View {
        if store.busyPluginID == plugin.pluginId {
            ProgressView().controlSize(.small)
        } else if plugin.installed {
            Button("Remove") { store.uninstall(plugin.pluginId, bridge: active.bridge) }
                .buttonStyle(PillButtonStyle(kind: .neutral)).controlSize(.small)
        } else if plugin.installable {
            Button("Install") { requestInstallation(plugin, reviewedDetails: true) }
                .buttonStyle(PillButtonStyle(kind: .accent)).controlSize(.small)
        }
    }

    private func requestInstallation(
        _ plugin: CodexPluginStore.Plugin,
        reviewedDetails: Bool = false
    ) {
        switch plugin.installationDecision {
        case .install:
            store.install(plugin.pluginId, bridge: active.bridge)
        case .reviewDetails:
            if reviewedDetails {
                detail = nil
                store.install(
                    plugin.pluginId,
                    installationInterstitialAccepted: true,
                    bridge: active.bridge)
            } else {
                detail = plugin
            }
        case .unavailable:
            break
        }
    }

    private func screenshots(_ urls: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(urls, id: \.self) { raw in
                    if let url = URL(string: raw) {
                        AsyncImage(url: url) { image in
                            image.resizable().aspectRatio(contentMode: .fit)
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 8).fill(Color.nSurface)
                                .frame(width: 220, height: 140)
                        }
                        .frame(maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    /// The vendor's own pages. Privacy policy and terms are on ~98% of the catalog, and they are
    /// exactly what you want before granting an app access to an account.
    private func detailLinks(_ plugin: CodexPluginStore.Plugin) -> [(title: String, url: URL)] {
        [("Website", plugin.websiteUrl),
         ("Privacy policy", plugin.privacyPolicyUrl),
         ("Terms of service", plugin.termsOfServiceUrl)]
            .compactMap { title, raw in
                guard let raw, let url = URL(string: raw) else { return nil }
                return (title: title, url: url)
            }
    }

    /// A real logo when the catalog has one, a monogram when it does not — never an empty square.
    @ViewBuilder
    private func logo(_ plugin: CodexPluginStore.Plugin, size: CGFloat) -> some View {
        if let raw = plugin.logoUrl, let url = URL(string: raw) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                MakerBadge(text: plugin.name, size: size)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        } else {
            MakerBadge(text: plugin.name, size: size)
        }
    }

    private var addMarketplaceSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a marketplace").font(.headline)
            Text("A GitHub repository (owner/repo), a git URL, or a local marketplace path.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("owner/repo", text: $newMarketplace)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Marketplace source")
            HStack {
                Spacer()
                Button("Cancel") { addingMarketplace = false; newMarketplace = "" }
                    .buttonStyle(PillButtonStyle(kind: .neutral))
                Button("Add") {
                    store.addMarketplace(
                        newMarketplace.trimmingCharacters(in: .whitespacesAndNewlines),
                        bridge: active.bridge)
                    addingMarketplace = false
                    newMarketplace = ""
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .disabled(newMarketplace.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440)
        .background(Color.nBg)
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
}
