import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// MCP OAuth state belongs to one Claude provider lane. Resolve that lane independently from the
/// conversation currently visible in the active workspace: changing conversations must never move
/// an authorization flow into a different Claude config directory.
enum MCPAccessSelection {
    static let preferenceKey = "extensions.mcpProviderAccess.v1"

    static func resolve(
        savedRawValue: String?,
        available: [ModelAccess],
        profileDefault: ModelAccess?,
        conversationDefault: ModelAccess?,
        current: ModelAccess?
    ) -> ModelAccess {
        // No maker filter: MCP is a standard both providers implement, and the Codex lane now
        // configures, mounts and reports servers of its own. `available` is the whole gate — the
        // caller decides which lanes can carry extensions.
        let candidates = [
            savedRawValue.flatMap(ModelAccess.init(rawValue:)),
            profileDefault,
            conversationDefault,
            current,
            .claudeSubscription,
            .anthropicAPI,
        ]
        return candidates.compactMap { $0 }.first(where: { available.contains($0) })
            ?? available.first
            ?? .claudeSubscription
    }
}

/// Pure user-facing policy for one typed authorization failure. Both the prominent readiness
/// banner and each connection row consume this value so they cannot disagree about whether retry,
/// a manual token, or editing the endpoint is the useful next step.
struct MCPAuthorizationFailurePresentation: Equatable {
    enum Action: Equatable {
        case retry
        case addToken
        case editCredentials
        case editServer

        var label: String {
            switch self {
            case .retry: return "Try Again"
            case .addToken: return "Add Token…"
            case .editCredentials: return "Edit Credentials"
            case .editServer: return "Edit Server…"
            }
        }
    }

    let title: String
    let message: String
    let action: Action?

    static func resolve(
        _ failure: MCPAuthorizationFailure,
        hasManualCredentials: Bool,
        allowsManualCredentials: Bool = true
    ) -> Self {
        if failure.isCancellation {
            return Self(title: "Sign-in cancelled", message: failure.message, action: nil)
        }

        // A server that cannot register a client will never sign in, so this outranks any retry the
        // provider suggested: pressing Try Again forever is the one outcome that is certainly wrong.
        // The provider's own wording is several nested "Registration failed:" clauses deep; say what
        // this means for the person and what actually works instead.
        if failure.indicatesUnsupportedDynamicRegistration {
            guard allowsManualCredentials else {
                return Self(
                    title: "This server needs a token",
                    message: "\(failure.message.trimmingCharacters(in: .whitespacesAndNewlines))",
                    action: nil)
            }
            return Self(
                title: "This server needs a token",
                message: "It does not support browser sign-in. Add an access token for it instead.",
                action: hasManualCredentials ? .editCredentials : .addToken)
        }

        let fallbackAction: Action? = {
            if failure.kind == .configuration, failure.retryable == false {
                return .editServer
            }
            return failure.retryable == false ? nil : .retry
        }()

        let action: Action?
        switch failure.suggestedAction {
        case .some(.retry), .some(.checkNetwork), .some(.checkVPN):
            action = .retry
        case .some(.manualCredentials):
            guard allowsManualCredentials else {
                action = failure.retryable == true ? .retry : nil
                break
            }
            action = hasManualCredentials ? .editCredentials : .addToken
        case .some(.editServer):
            action = .editServer
        case .some(.none):
            action = nil
        case .some(.other), nil:
            action = fallbackAction
        }
        return Self(title: "Sign-in failed", message: failure.message, action: action)
    }
}

/// One high-signal readiness problem for the Extensions panel. A configured endpoint is not useful
/// to a conversation until its selected Claude lane is authenticated and reports at least one tool.
struct MCPAttention: Equatable {
    enum Kind: Equatable {
        case preparing
        case authorizing
        case waitingForBrowser
        case needsAuthentication
        case authenticationFailed(MCPAuthorizationFailure)
        case connectionFailed(String)
        case noTools
        case toolCountUnavailable
        case checking
        case statusUnavailable
    }

    let serverName: String
    let kind: Kind
}

enum MCPAttentionResolver {
    static func primary(
        servers: [MCPServer],
        authStates: [String: MCPAuthState],
        connectionStates: [String: MCPConnState]
    ) -> MCPAttention? {
        let enabled = servers.filter { $0.enabled && $0.isRemote && $0.isValid }
        func first(_ match: (MCPServer, MCPAuthState, MCPConnState) -> MCPAttention.Kind?)
            -> MCPAttention? {
            for server in enabled {
                let auth = authStates[server.name] ?? .idle
                let connection = connectionStates[server.name] ?? .unknown
                if let kind = match(server, auth, connection) {
                    return MCPAttention(serverName: server.name, kind: kind)
                }
            }
            return nil
        }

        return first { _, auth, _ in auth == .waiting ? .waitingForBrowser : nil }
            ?? first { _, auth, _ in auth == .authorizing ? .authorizing : nil }
            ?? first { _, auth, _ in auth == .preparing ? .preparing : nil }
            ?? first { _, auth, _ in
                if case .failed(let failure) = auth { return .authenticationFailed(failure) }
                return nil
            }
            ?? first { _, _, connection in connection == .needsAuth ? .needsAuthentication : nil }
            ?? first { _, _, connection in
                if case .failed(let message) = connection { return .connectionFailed(message) }
                return nil
            }
            ?? first { _, _, connection in
                if case .connected(let tools) = connection, tools == 0 { return .noTools }
                return nil
            }
            // A missing tool count, an in-flight check, or an indeterminate idle probe is not a
            // user-actionable failure. Real turns can mount tools even when the SDK's disposable
            // status query remains `pending` (observed with VICE).
    }
}

/// The three visible phases between accepting an MCP sign-in click and receiving its terminal
/// result. `preparing` intentionally has no Cancel action: the durable attempt and daemon request
/// do not exist yet, so presenting cancellation would promise control over work that has no owner.
enum MCPAuthorizationProgressPhase: Equatable {
    case preparing
    case authorizing
    case waitingForBrowser

    init?(_ state: MCPAuthState) {
        switch state {
        case .preparing: self = .preparing
        case .authorizing: self = .authorizing
        case .waiting: self = .waitingForBrowser
        case .idle, .authorized, .failed: return nil
        }
    }

}

/// Installed-first MCP server management. The persisted model remains `ExtensionsStore` because
/// agentd reads that wire format, but provider package formats are not part of the primary UI.
struct ExtensionsSettings: View {
    /// Embedded = hosted in the Extensions utility window (fluid width); standalone keeps the
    /// fixed width used by older settings call sites.
    var embedded = false
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var store = ExtensionsStore.shared
    @ObservedObject private var active = ActiveWorkspace.shared
    @ObservedObject private var accounts = ProviderAccountStore.shared
    @AppStorage(MCPAccessSelection.preferenceKey) private var savedAccessRawValue = ""
    @State private var editing: MCPServer?
    /// Removing a server deletes a configuration the user typed in, and takes its stored
    /// credential with it. Same rule as uninstalling a plugin: the reversible actions do not ask,
    /// the destructive one does.
    @State private var confirmingServerRemoval: MCPServer?
    @State private var showingAddConnection = false
    @State private var mcpTab: MCPTab = .configured
    @State private var pickingPlugin = false
    /// The live registry feed behind the Browse tab. Its client was already written and tested; the
    /// only thing missing was a consumer that did not filter the public sources away.
    @StateObject private var registry = MCPRegistryClient()
    @State private var browseSearch = ""
    @State private var serverDetail: MCPServer?
    @State private var browseFacet: BrowseFacet = .all
    /// Registries the user has collapsed. Empty = all open, which is right when there
    /// are two or three of them.
    @State private var collapsedRegistries: Set<String> = []
    /// Every lane that can carry MCP servers. Both makers now can: Anthropic through the SDK's
    /// per-query mcpServers, Codex through its own config plus mcpServerStatus/list.
    private var mcpAccesses: [ModelAccess] { ModelAccess.selectableCases }

    /// Says only what is true on this lane. On Codex the credential belongs to Codex, and its
    /// logout is LOCAL — measured: after clearing, a replayed token is still accepted by the server
    /// until it expires. Promising "revoked" there would be a security claim we cannot keep.
    private var remoteAuthenticationFootnote: String {
        guard supportsLiveMCP else {
            return "Open a workspace before checking or authenticating remote servers."
        }
        let scope = "Authentication is scoped to \(extensionAccess.displayName). "
            + "A real tool call is authoritative even if the optional status check is indeterminate."
        guard extensionAccess.maker == .openAI else { return scope }
        return scope + " Codex stores these credentials in your keychain; clearing one removes it "
            + "from this Mac but does not revoke it on the server."
    }

    /// claude.ai connectors are provider-owned and discovered through a disposable Claude probe
    /// that does not exist in a Codex daemon. Gate them EXPLICITLY rather than relying on the
    /// accident that foreignServers happened to be empty on other lanes.
    private var supportsProviderConnectors: Bool { extensionAccess.maker == .anthropic }
    private var extensionAccess: ModelAccess {
        MCPAccessSelection.resolve(
            savedRawValue: savedAccessRawValue,
            available: mcpAccesses,
            profileDefault: TenantProfile.current.defaultAccess,
            conversationDefault: active.bridge?.defaultConversationAccess,
            current: active.bridge?.currentModelAccess)
    }
    private var extensionAccessBinding: Binding<ModelAccess> {
        Binding(
            get: { extensionAccess },
            set: { savedAccessRawValue = $0.rawValue })
    }
    private var supportsLiveMCP: Bool { active.bridge != nil }
    private var foreignServers: [String] { store.foreignServers(for: extensionAccess) }
    private var remoteServerCount: Int { store.mcpServers.filter(\.isRemote).count }
    private var localServerCount: Int { store.mcpServers.count - remoteServerCount }
    private var connectionCount: Int { store.mcpServers.count + foreignServers.count }
    private var attention: MCPAttention? {
        let connections = Dictionary(uniqueKeysWithValues: store.mcpServers.map {
            ($0.name, store.connState(for: $0.name, access: extensionAccess))
        })
        return MCPAttentionResolver.primary(
            servers: store.mcpServers,
            authStates: store.authStates(for: extensionAccess),
            connectionStates: connections)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP Servers").font(.system(size: 19, weight: .semibold))
                    Text("Connect your agent to data sources and tools. Changes apply on the next message.")
                        .font(.caption).foregroundStyle(Color.nSecondaryText)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("MCP authentication")
                        .font(.caption2).foregroundStyle(Color.nSecondaryText)
                    Menu {
                        ForEach(mcpAccesses, id: \.self) { access in
                            Button {
                                extensionAccessBinding.wrappedValue = access
                            } label: {
                                if access == extensionAccess {
                                    Label(access.displayName, systemImage: "checkmark")
                                } else {
                                    Text(access.displayName)
                                }
                            }
                        }
                    } label: {
                        MechanicianControlTrigger(
                            title: extensionAccess.displayName,
                            systemImage: "key.horizontal",
                            showsChevron: true,
                            maxTitleWidth: 230)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    HStack(spacing: 5) {
                        Text(accounts.state(for: extensionAccess).statusLabel)
                            .font(.caption2)
                            .foregroundStyle(accounts.state(for: extensionAccess).isAvailable
                                             ? Color.nSecondaryText : Color.nWarningText)
                        if !accounts.state(for: extensionAccess).isAvailable {
                            Button("Connect") { showProviders(using: openWindow) }
                                .buttonStyle(PillButtonStyle(kind: .accent))
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            mcpTabBar

            Divider()

            if let error = store.persistenceError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.nWarningText)
                    Text(error).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Retry") { store.save() }
                        .buttonStyle(PillButtonStyle(kind: .neutral))
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
            }

            switch mcpTab {
            case .browse:     browsePane
            case .configured: configuredPane
            case .add:        addServerPane
            }
        }
        .background(Color.nBg)
        .frame(width: embedded ? nil : 720)
        .frame(maxWidth: embedded ? 820 : nil)
        .onAppear {
            if supportsLiveMCP { active.bridge?.autoCheckMcpStatusIfNeeded(for: extensionAccess) }
        }
        .onChange(of: extensionAccess) { _, access in
            if supportsLiveMCP { active.bridge?.autoCheckMcpStatusIfNeeded(for: access) }
        }
        // SwiftUI's importer, not a nested modal NSOpenPanel, which can tear down the utility
        // scene when cancelled.
        .fileImporter(isPresented: $pickingPlugin,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.upsert(LocalPlugin(name: url.lastPathComponent, enabled: true, path: url.path))
            }
        }
        .sheet(isPresented: $showingAddConnection) {
            AddConnectionSheet(
                isConnected: { catalogServer in
                    let name = connectName(catalogServer)
                    return store.mcpServers.contains(where: { $0.name == name })
                },
                onConnect: { server in
                    addConnection(server)
                    showingAddConnection = false
                },
                onAddMCPServer: {
                    showingAddConnection = false
                    DispatchQueue.main.async { editing = MCPServer() }
                })
        }
        .sheet(item: $serverDetail) { serverDetailSheet($0) }
        .confirmationDialog(
            "Remove \(confirmingServerRemoval?.name ?? "this server")?",
            isPresented: Binding(get: { confirmingServerRemoval != nil },
                                 set: { if !$0 { confirmingServerRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let server = confirmingServerRemoval {
                    store.removeServer(server.id)
                    if supportsLiveMCP {
                        active.bridge?.reloadMcpConfiguration(for: extensionAccess)
                    }
                }
                confirmingServerRemoval = nil
            }
            Button("Cancel", role: .cancel) { confirmingServerRemoval = nil }
        } message: {
            Text("Its settings and any stored credential are removed. "
               + "Its tools stop being offered in every conversation.")
        }
        .sheet(item: $editing) { s in
            MCPServerEditor(server: s,
                            onSave: {
                                store.upsert($0)
                                editing = nil
                                if supportsLiveMCP {
                                    active.bridge?.reloadMcpConfiguration(for: extensionAccess)
                                }
                            },
                            onCancel: { editing = nil })
        }
    }

    private var remoteServerIndices: [Int] {
        store.mcpServers.indices.filter { store.mcpServers[$0].isRemote }
    }

    private var localServerIndices: [Int] {
        store.mcpServers.indices.filter { !store.mcpServers[$0].isRemote }
    }

    // MARK: tabs

    /// Three tabs, three moments: find something, manage what you have, add one by hand. A browse
    /// experience hidden behind a modal (the old "Sources…" sheet) is a dead end, because you had
    /// to open it to discover what you could even look at.
    enum MCPTab: String, CaseIterable, Identifiable {
        case browse = "Browse"
        case configured = "Configured"
        case add = "Add Server"
        var id: String { rawValue }
    }

    private var mcpTabBar: some View {
        HStack(spacing: 2) {
            ForEach(MCPTab.allCases) { item in
                let selected = mcpTab == item
                Button { mcpTab = item } label: {
                    HStack(spacing: 5) {
                        Text(item.rawValue)
                        if item == .configured, connectionCount > 0 {
                            Text("\(connectionCount)")
                                .font(.caption2)
                                .foregroundStyle(
                                    selected ? Color.nText : Color.nSecondaryText)
                        }
                    }
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.nText : Color.nSecondaryText)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(
                        selected ? Color.nAccent.opacity(0.30) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    // MARK: browse

    /// Cards, not rows: browsing is scanning, and a name plus a sentence is what you scan.
    ///
    /// Two rails, because they make different claims. **Our picks** is Mechanician's hand-curated
    /// list — the only trust statement in the panel, and it says nothing more than "we chose these."
    /// **Everything else** is the live feed from the configured registries, which was written,
    /// tested and then never switched on: the sole consumer filtered the public sources out, so the
    /// panel showed thirteen servers compiled into the binary while a client capable of thousands
    /// sat idle beside it.
    ///
    /// The official registry verifies NAMESPACE OWNERSHIP, not code, so nothing down there is
    /// promoted to "verified" by appearing in it — see `fetchMerged`, which deliberately downgrades
    /// a registry's self-asserted trust.
    private var browsePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                browseSearchField
                browseFacetBar
                if let issue = registry.sourceIssues.first, registryGroups.isEmpty {
                    browseIssueBar(issue)
                }
                if registryGroups.isEmpty {
                    browseEmptyState
                } else {
                    ForEach(registryGroups, id: \.registry) { group in
                        registrySection(group)
                    }
                }
            }
            .padding(16)
        }
        .task(id: browseFeedKey) {
            await registry.loadFeatured(via: active.bridge, sources: store.effectiveRegistrySources)
        }
        // Typing has to reach the WHOLE registry, not just the page already in hand. Filtering the
        // 100 servers `loadFeatured` fetched would quietly redefine "search" as "search what we
        // happened to download", so a query for Stripe's own server would come back empty while the
        // registry has it. Debounced, because every keystroke is a network round trip.
        .task(id: browseSearch) {
            let query = browseSearch.trimmingCharacters(in: .whitespaces)
            guard query.count >= 2 else { registry.servers = []; return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await registry.load(search: query, via: active.bridge,
                                sources: store.effectiveRegistrySources)
        }
    }

    @ViewBuilder
    private var browseEmptyState: some View {
        if registry.loadingFeatured {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading the registries…").font(.caption)
                    .foregroundStyle(Color.nSecondaryText)
            }
        } else if !browseSearch.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("Nothing matches “\(browseSearch.trimmingCharacters(in: .whitespaces))”.")
                .font(.caption).foregroundStyle(Color.nSecondaryText)
        } else {
            Text("No registries enabled. Add one in Settings to browse servers.")
                .font(.caption).foregroundStyle(Color.nSecondaryText)
        }
    }

    /// One collapsible section per registry.
    ///
    /// Grouping by SOURCE rather than pouring everything into one list is the point: these are
    /// separate curations by separate companies, and which one vouched for a server is the single
    /// most useful thing to know about it. It also makes the page navigable — you collapse the ones
    /// you are not shopping in instead of scrolling past them.
    private func registrySection(_ group: RegistryGroup) -> some View {
        let open = !collapsedRegistries.contains(group.registry)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                if open { collapsedRegistries.insert(group.registry) }
                else { collapsedRegistries.remove(group.registry) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(.secondary).frame(width: 10)
                    Text(group.registry).font(.system(size: 13, weight: .semibold))
                    Text("\(group.servers.count)")
                        .font(.caption2).foregroundStyle(Color.nSecondaryText)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.registry)
            .accessibilityValue("\(group.servers.count) servers")
            .accessibilityHint(open ? "Collapse" : "Expand")

            if open {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                    ForEach(group.servers.prefix(browseLimit), id: \.name) { browseCard($0) }
                }
                if group.servers.count > browseLimit {
                    // Never silently truncate: a capped grid that looks complete misrepresents what
                    // the registry actually offers.
                    Text("Showing \(browseLimit) of \(group.servers.count). Search to narrow it down.")
                        .font(.caption2).foregroundStyle(Color.nSecondaryText)
                }
            }
        }
    }

    private var browseFacetBar: some View {
        HStack(spacing: 6) {
            ForEach(BrowseFacet.allCases) { facet in
                let selected = browseFacet == facet
                Button { browseFacet = facet } label: {
                    Text(facet.label)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(
                            selected ? Color.nText : Color.nSecondaryText)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(selected ? Color.nAccent.opacity(0.30)
                                                            : Color.nSecondaryText.opacity(0.14)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(facet.help)
                .accessibilityLabel(facet.label)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
            Spacer()
        }
    }

    private var browseSearchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("Search MCP servers", text: $browseSearch)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search MCP servers")
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .cardSurface(cornerRadius: 7)
            if registry.loadingFeatured { ProgressView().controlSize(.small) }
            Button {
                Task { await registry.reloadFeatured(via: active.bridge,
                                                     sources: store.effectiveRegistrySources) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Refresh the registry feed")
            .accessibilityLabel("Refresh")
        }
    }

    private func browseSection(_ title: String, note: String, servers: [MCPRegistryServer]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(note).font(.caption2).foregroundStyle(Color.nSecondaryText)
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(servers, id: \.name) { entry in browseCard(entry) }
            }
        }
    }

    private func browseIssueBar(_ issue: ExtensionSourceIssue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.nWarningText)
            Text("\(issue.sourceName): \(issue.message)")
                .font(.caption).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
    }

    /// Re-fetch when the enabled source set changes, not on every keystroke — filtering is local.
    private var browseFeedKey: String {
        store.effectiveRegistrySources.filter(\.enabled).map(\.url).joined(separator: "|")
    }

    typealias RegistryGroup = (registry: String, servers: [MCPRegistryServer])

    /// How many cards a section shows before it asks you to search. A registry can return hundreds;
    /// an unbounded grid is the endless scroll this replaced.
    private var browseLimit: Int { 60 }

    /// What you can narrow by, drawn from facts the data actually carries rather than invented
    /// taxonomy. A registry entry declares its transports, so remote-versus-local is real; a
    /// verified reverse-DNS namespace is real. There is nothing else in `server.schema.json` worth
    /// facetting on, and inventing categories would mean guessing.
    enum BrowseFacet: String, CaseIterable, Identifiable {
        case all, remote, local, verified
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .remote: return "Remote"
            case .local: return "Runs locally"
            case .verified: return "First-party"
            }
        }
        var help: String {
            switch self {
            case .all: return "Every server the enabled registries list"
            case .remote: return "Hosted servers you connect to over HTTPS, usually with OAuth"
            case .local: return "Servers that run as a process on this Mac"
            case .verified: return "Published under a DNS-verified namespace by the vendor whose "
                                 + "service it exposes"
            }
        }
    }

    private func matchesFacet(_ entry: MCPRegistryServer) -> Bool {
        switch browseFacet {
        case .all: return true
        case .remote: return entry.firstRemote != nil
        case .local: return entry.firstRemote == nil
        case .verified: return entry.isFeatured
        }
    }

    /// Every server the enabled registries offer, grouped by which registry vouched for it.
    ///
    /// The hand-curated "Our picks" rail that used to sit above this is gone. It was thirteen
    /// servers compiled into the binary — one engineer's list, presented beside real registries as
    /// though it carried comparable weight. Two vendor-curated registries say more than our opinion
    /// does, and they say who is saying it.
    private var registryGroups: [RegistryGroup] {
        // Server-side hits pass through unfiltered by search: they ARE the answer to the query, and
        // re-testing them against our local predicate would discard any match the registry made on
        // a field we do not carry. Only the pre-fetched page needs local search filtering.
        let searched = registry.servers
        let local = registry.featured.filter { matchesBrowseSearch($0) }
        var seen = Set<String>()
        let all = (searched + local)
            .filter { seen.insert($0.name).inserted }
            .filter { !store.mcpVerifiedOnly || $0.isFeatured }
            .filter { matchesFacet($0) }

        var byRegistry: [String: [MCPRegistryServer]] = [:]
        for server in all {
            byRegistry[server.publisher ?? "Other", default: []].append(server)
        }
        return byRegistry
            .map { (registry: $0.key,
                    servers: $0.value.sorted {
                        $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
                    }) }
            .sorted { $0.registry.localizedCaseInsensitiveCompare($1.registry) == .orderedAscending }
    }

    /// Local, full-text matching over the fields a person actually reads. The official registry's
    /// own `search` is a NAME-substring match — `github` does not find `com.github/mcp` — so
    /// filtering here is what makes the box behave the way it looks like it should.
    private func matchesBrowseSearch(_ entry: MCPRegistryServer) -> Bool {
        let needle = browseSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return [entry.name, entry.displayTitle, entry.description, entry.maker,
                entry.publisher ?? ""]
            .joined(separator: " ").lowercased()
            .contains(needle)
    }

    private func configuredServer(matching entry: MCPRegistryServer) -> MCPServer? {
        let host = entry.firstRemote.flatMap { URL(string: $0.url)?.host?.lowercased() }
        return store.mcpServers.first { server in
            if let host, let existing = URL(string: server.url)?.host?.lowercased() {
                return existing == host
            }
            return server.name.caseInsensitiveCompare(entry.shortName) == .orderedSame
        }
    }

    private func browseCard(_ entry: MCPRegistryServer) -> some View {
        let configured = configuredServer(matching: entry)
        let progress = configured.flatMap {
            MCPAuthorizationProgressPhase(
                store.authState(for: $0.name, access: extensionAccess))
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                MakerBadge(text: entry.publisher ?? entry.displayTitle, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayTitle).font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    // WHERE THIS CAME FROM, always. A catalog that does not name its source is
                    // asking you to trust it without saying who is being trusted — which was the
                    // exact complaint that got the unvetted aggregators removed from the defaults.
                    Text(entry.publisher ?? "Mechanician's picks")
                        .font(.caption2).foregroundStyle(Color.nSecondaryText).lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            Text(entry.description)
                .font(.caption).foregroundStyle(Color.nSecondaryText)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                // What it will ask of you, before you commit to it.
                if entry.firstRemote != nil {
                    Text("OAuth").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.nSecondaryText.opacity(0.14)))
                        .foregroundStyle(Color.nSecondaryText)
                } else {
                    Text("Local").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.nSecondaryText.opacity(0.14)))
                        .foregroundStyle(Color.nSecondaryText)
                }
                Spacer()
                if configured != nil, let progress {
                    HStack(spacing: 5) {
                        OrbitingDots(diameter: 13, allowsVisualOverflow: true)
                        switch progress {
                        case .preparing:
                            Text("Preparing sign-in…")
                        case .authorizing:
                            Text("Opening sign-in…")
                        case .waitingForBrowser:
                            Text("Check your browser…")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.nSecondaryText)
                    .accessibilityElement(children: .combine)
                } else if configured != nil {
                    Text("Configured").font(.caption).foregroundStyle(Color.nSuccessText)
                } else {
                    Button("Add") { addConnection(entry) }
                        .buttonStyle(PillButtonStyle(kind: .accent))
                        .controlSize(.small)
                        .accessibilityLabel("Add \(entry.displayTitle)")
                }
            }
        }
        .padding(12)
        .frame(minHeight: 150, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.nSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.nMuted.opacity(0.30)))
    }

    // MARK: configured

    private var configuredPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let attention { mcpAttentionBanner(attention) }
                if store.mcpServers.isEmpty && foreignServers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No servers yet.").font(.system(size: 13, weight: .medium))
                        Text("Browse to add one, or add a server by hand.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    remoteServersSection
                    localServersSection
                }
            }
            .padding(16)
        }
    }

    // MARK: add by hand

    /// A tab, not a sheet. Adding a server by hand is a normal thing to do, not an interruption,
    /// and it belongs beside the catalog it is an alternative to.
    private var addServerPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add a server by providing its connection details.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            MCPServerEditor(
                server: MCPServer(),
                inlineInTab: true,
                onSave: { server in
                    store.upsert(server)
                    mcpTab = .configured
                    if supportsLiveMCP {
                        active.bridge?.reloadMcpConfiguration(for: extensionAccess)
                    }
                },
                onCancel: { mcpTab = .configured })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var remoteServersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Remote Servers").font(.headline)
                Text("\(remoteServerCount + foreignServers.count)")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if supportsProviderConnectors, !foreignServers.isEmpty {
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/connectors")!)
                    } label: {
                        ExtensionIconLabel(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .help("Manage Claude connections on claude.ai")
                    .accessibilityLabel("Manage Claude connections on claude.ai")
                }
                Button { active.bridge?.refreshMcpStatus(for: extensionAccess) } label: {
                    Label("Refresh Auth", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle(kind: .plain))
                .controlSize(.small)
                .disabled(active.bridge == nil || !supportsLiveMCP)
                .help("Refresh configured servers’ authorization state from macOS Keychain.")
            }

            VStack(spacing: 0) {
                if remoteServerIndices.isEmpty && foreignServers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No remote MCP servers are configured.")
                            .font(.callout).foregroundStyle(.secondary)
                        if store.hasManagedDiscovery {
                            Text("Choose Add Server to connect an entry from your managed catalog.")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                ForEach(Array(remoteServerIndices.enumerated()), id: \.element) { offset, index in
                    serverRow($store.mcpServers[index])
                        .padding(.horizontal, 14).padding(.vertical, 11)
                    if offset < remoteServerIndices.count - 1 || !foreignServers.isEmpty { Divider() }
                }
                ForEach(Array(foreignServers.enumerated()), id: \.element) { offset, name in
                    connectorRow(name)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                    if offset < foreignServers.count - 1 { Divider() }
                }
            }
            .cardSurface(cornerRadius: 12, strokeOpacity: 0.38)

            Text(remoteAuthenticationFootnote)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var localServersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Local Servers").font(.headline)
                Text("\(localServerCount)")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                if localServerIndices.isEmpty {
                    Text("No local MCP servers.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                ForEach(Array(localServerIndices.enumerated()), id: \.element) { offset, index in
                    serverRow($store.mcpServers[index])
                        .padding(.horizontal, 14).padding(.vertical, 11)
                    if offset < localServerIndices.count - 1 { Divider() }
                }
            }
            .cardSurface(cornerRadius: 12, strokeOpacity: 0.38)
            if localServerCount > 0 {
                Text("Local processes run on this Mac with the permissions of your agent session.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func mcpAttentionBanner(_ attention: MCPAttention) -> some View {
        let name = attention.serverName
        let manualCredentials = store.mcpServers.first(where: { $0.name == name })?
            .hasManualHeaderCredentials == true
        HStack(alignment: .center, spacing: 12) {
            Group {
                switch attention.kind {
                case .preparing, .authorizing, .waitingForBrowser, .checking:
                    OrbitingDots(diameter: 18, allowsVisualOverflow: true)
                case .needsAuthentication, .authenticationFailed:
                    Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                        .foregroundStyle(Color.nWarningText)
                case .connectionFailed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.nErrorText)
                case .noTools, .toolCountUnavailable, .statusUnavailable:
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .foregroundStyle(Color.nWarningText)
                }
            }
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(attentionTitle(attention))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.nText)
                Text(attentionDetail(attention))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            switch attention.kind {
            case .preparing:
                EmptyView()
            case .authorizing:
                Button("Cancel") {
                    active.bridge?.mcpAuthorizeCancel(name, for: extensionAccess)
                }
                .buttonStyle(PillButtonStyle(kind: .neutral))
            case .waitingForBrowser:
                if let raw = store.authURL(for: name, access: extensionAccess),
                   let url = URL(string: raw) {
                    Button("Open Sign-In") { NSWorkspace.shared.open(url) }
                        .buttonStyle(PillButtonStyle(kind: .accent))
                }
                Button("Cancel") {
                    active.bridge?.mcpAuthorizeCancel(name, for: extensionAccess)
                }
                .buttonStyle(PillButtonStyle(kind: .neutral))
            case .needsAuthentication:
                if manualCredentials,
                   let server = store.mcpServers.first(where: { $0.name == name }) {
                    Button("Edit Credentials") { editing = server }
                        .buttonStyle(PillButtonStyle(kind: .accent))
                } else {
                    Button("Authenticate") {
                        active.bridge?.mcpAuthorize(name, for: extensionAccess)
                    }
                    .buttonStyle(PillButtonStyle(kind: .accent))
                }
            case .authenticationFailed(let failure):
                let presentation = MCPAuthorizationFailurePresentation.resolve(
                    failure,
                    hasManualCredentials: manualCredentials)
                authorizationFailureAction(
                    presentation.action,
                    name: name,
                    server: store.mcpServers.first(where: { $0.name == name }))
            case .connectionFailed:
                Button("Refresh Authorization") {
                    active.bridge?.refreshMcpStatus(for: extensionAccess)
                }
                .buttonStyle(PillButtonStyle(kind: .neutral))
                if manualCredentials,
                   let server = store.mcpServers.first(where: { $0.name == name }) {
                    Button("Edit Credentials") { editing = server }
                        .buttonStyle(PillButtonStyle(kind: .accent))
                } else {
                    Button("Re-authenticate") {
                        active.bridge?.mcpReauthorize(name, for: extensionAccess)
                    }
                    .buttonStyle(PillButtonStyle(kind: .accent))
                }
            case .noTools, .toolCountUnavailable, .statusUnavailable:
                Button("Refresh Authorization") {
                    active.bridge?.refreshMcpStatus(for: extensionAccess)
                }
                .buttonStyle(PillButtonStyle(kind: .neutral))
                if manualCredentials,
                   let server = store.mcpServers.first(where: { $0.name == name }) {
                    Button("Edit Credentials") { editing = server }
                        .buttonStyle(PillButtonStyle(kind: .accent))
                } else {
                    Button("Re-authenticate") {
                        active.bridge?.mcpReauthorize(name, for: extensionAccess)
                    }
                    .buttonStyle(PillButtonStyle(kind: .accent))
                }
            case .checking:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(attentionColor(attention).opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(attentionColor(attention).opacity(0.42), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func attentionTitle(_ attention: MCPAttention) -> String {
        switch attention.kind {
        case .preparing:
            return String(localized: "Preparing sign-in for \(attention.serverName)…")
        case .authorizing: return "Starting sign-in for \(attention.serverName)…"
        case .waitingForBrowser: return "Finish signing in to \(attention.serverName)"
        case .needsAuthentication:
            let manualCredentials = store.mcpServers.first(where: {
                $0.name == attention.serverName
            })?.hasManualHeaderCredentials == true
            return manualCredentials
                ? "\(attention.serverName) rejected its saved credentials"
                : "\(attention.serverName) is not authenticated"
        case .authenticationFailed(let failure):
            let presentation = MCPAuthorizationFailurePresentation.resolve(
                failure,
                hasManualCredentials: store.mcpServers.first(where: {
                    $0.name == attention.serverName
                })?.hasManualHeaderCredentials == true)
            return "\(presentation.title) for \(attention.serverName)"
        case .connectionFailed:
            return "\(attention.serverName) is not available"
        case .noTools:
            return "\(attention.serverName) connected without tools"
        case .toolCountUnavailable:
            return "Verifying tools from \(attention.serverName)"
        case .checking:
            return "Checking \(attention.serverName)…"
        case .statusUnavailable:
            return "Could not verify \(attention.serverName)"
        }
    }

    private func attentionDetail(_ attention: MCPAttention) -> String {
        switch attention.kind {
        case .preparing:
            return String(localized: "Your sign-in request was accepted. Your browser will open when the secure connection is ready.")
        case .authorizing:
            return "Mechanician is preparing the browser authentication flow."
        case .waitingForBrowser:
            return "Complete the browser flow. Until it finishes, this server's tools are not available to the agent."
        case .needsAuthentication:
            let manualCredentials = store.mcpServers.first(where: {
                $0.name == attention.serverName
            })?.hasManualHeaderCredentials == true
            return manualCredentials
                ? "Edit the saved header or PAT. This server uses manual credentials, not browser sign-in."
                : "Authenticate for \(extensionAccess.displayName) before asking the agent to use this server."
        case .authenticationFailed(let failure):
            return failure.message
        case .connectionFailed(let message):
            return message
        case .noTools:
            return "The endpoint connected, but the provider reported zero tools, so the agent cannot use it yet."
        case .toolCountUnavailable:
            return "The connection succeeded, but the provider did not report a tool count. New turns wait for tools to mount before starting."
        case .checking:
            return "Verifying authentication and counting the tools that will be available to the agent."
        case .statusUnavailable:
            return "Sign-in completed, but the connection check did not return a final status. Try the check again before using this server."
        }
    }

    private func attentionColor(_ attention: MCPAttention) -> Color {
        if case .connectionFailed = attention.kind { return .red }
        if case .checking = attention.kind { return .nAccent }
        if case .preparing = attention.kind { return .nAccent }
        if case .authorizing = attention.kind { return .nAccent }
        if case .waitingForBrowser = attention.kind { return .nAccent }
        return .orange
    }

    @ViewBuilder private func authorizationFailureAction(
        _ action: MCPAuthorizationFailurePresentation.Action?,
        name: String,
        server: MCPServer?
    ) -> some View {
        switch action {
        case .some(.retry):
            Button(MCPAuthorizationFailurePresentation.Action.retry.label) {
                active.bridge?.mcpReauthorize(name, for: extensionAccess)
            }
            .buttonStyle(PillButtonStyle(kind: .accent))
        case .some(.addToken):
            if let server {
                Button(MCPAuthorizationFailurePresentation.Action.addToken.label) {
                    editing = server
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .fixedSize()
                .help("This server doesn't support browser sign-in. Add a header like Authorization=Bearer <token> instead.")
            }
        case .some(.editCredentials):
            if let server {
                Button(MCPAuthorizationFailurePresentation.Action.editCredentials.label) {
                    editing = server
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .fixedSize()
            }
        case .some(.editServer):
            if let server {
                Button(MCPAuthorizationFailurePresentation.Action.editServer.label) {
                    editing = server
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .fixedSize()
            }
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder private func serverRow(_ server: Binding<MCPServer>) -> some View {
        let value = server.wrappedValue
        let auth = store.authState(for: value.name, access: extensionAccess)
        let authInFlight = auth.isInProgress
        HStack(spacing: 10) {
            Toggle("", isOn: server.enabled).labelsHidden()
                .onChange(of: value.enabled) { _, enabled in
                    store.save()
                    store.invalidateConfiguredMCPStatus([value.name])
                    guard supportsLiveMCP else { return }
                    if !enabled {
                        if authInFlight {
                            active.bridge?.mcpAuthorizeCancel(value.name, for: extensionAccess)
                        }
                        store.setConnState(value.name, .unknown, for: extensionAccess)
                    }
                    active.bridge?.reloadMcpConfiguration(for: extensionAccess)
                }
                .accessibilityLabel("Enable \(value.name)")
            Image(systemName: value.isRemote ? "link" : "terminal")
                .foregroundStyle(Color.nInfoText).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(value.name).fontWeight(.medium)
                    provenanceBadge(value)
                }
                Text(connectionDetail(value))
                    .font(.caption).foregroundStyle(Color.nSecondaryText)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if value.enabled {
                if supportsLiveMCP {
                    mcpStatusControl(value)
                } else {
                    Text("Claude")
                        .font(.caption2).foregroundStyle(Color.nSecondaryText)
                }
            }
            // A configured server deserves the same card as one you are only considering. "What is
            // this, where did it come from, what can it reach" is a question you ask about the
            // things already running, and it had no answer here at all.
            Button { serverDetail = value } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Show details for \(value.name)")
                .accessibilityLabel("Details for \(value.name)")
            serverActionsMenu(value)
                .disabled(authInFlight)
        }
    }

    // MARK: configured server detail

    /// Everything known about a server that is already configured: how it connects, where it came
    /// from, what it is doing right now, and — when it matches a catalog entry — what it is for.
    ///
    /// Deliberately shows the NAMES of environment variables and headers and never their values.
    /// Those are credentials; the panel's whole job is to be a place you can safely look.
    private func serverDetailSheet(_ server: MCPServer) -> some View {
        let catalog = MCPCatalog.servers.first { $0.shortName.caseInsensitiveCompare(server.name) == .orderedSame }
            ?? registry.featured.first { $0.shortName.caseInsensitiveCompare(server.name) == .orderedSame }
        let state = store.connState(for: server.name, access: extensionAccess)
        return DetailSheet(width: 520, height: 480, onClose: { serverDetail = nil }) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    MakerBadge(text: server.publisher ?? server.name, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(server.name).font(.system(size: 17, weight: .semibold))
                        HStack(spacing: 6) {
                            provenanceBadge(server)
                            Text(server.isRemote ? server.transport.rawValue.uppercased() : "Local")
                                .font(.caption2).foregroundStyle(Color.nSecondaryText)
                            Text(server.enabled ? "Enabled" : "Disabled")
                                .font(.caption2)
                                .foregroundStyle(
                                    server.enabled ? Color.nSuccessText : Color.nWarningText)
                        }
                    }
                    Spacer(minLength: 8)
                }

                if let catalog, !catalog.description.isEmpty {
                    Text(catalog.description).font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }

                detailBlock("Status") {
                    Text(liveStatusDescription(state))
                        .font(.caption).foregroundStyle(Color.nSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                detailBlock("Connection") {
                    VStack(alignment: .leading, spacing: 3) {
                        if server.isRemote {
                            Text(server.url).font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(([server.command] + server.args).joined(separator: " "))
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // Names only, never values.
                        if !server.env.isEmpty {
                            Text("Environment: \(server.env.keys.sorted().joined(separator: ", "))")
                                .font(.caption2).foregroundStyle(Color.nSecondaryText)
                        }
                        if !server.headers.isEmpty {
                            Text("Headers: \(server.headers.keys.sorted().joined(separator: ", "))")
                                .font(.caption2).foregroundStyle(Color.nSecondaryText)
                        }
                    }
                }

                if server.publisher != nil || server.networkScope != nil || server.sha256 != nil {
                    detailBlock("Provenance") {
                        VStack(alignment: .leading, spacing: 2) {
                            if let publisher = server.publisher {
                                Text("Published by \(publisher)").font(.caption)
                                    .foregroundStyle(Color.nSecondaryText)
                            }
                            if let scope = server.networkScope {
                                Text("Network: \(scope.rawValue)").font(.caption2)
                                    .foregroundStyle(Color.nSecondaryText)
                            }
                            if let sha = server.sha256 {
                                Text(sha).font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color.nSecondaryText).lineLimit(1)
                                    .truncationMode(.middle).textSelection(.enabled)
                            }
                        }
                    }
                }

                if let catalog, let repo = catalog.repository?.url, let url = URL(string: repo) {
                    Link(destination: url) {
                        HStack(spacing: 5) {
                            Text("Repository")
                            Image(systemName: "arrow.up.right").font(.caption2)
                        }
                        .font(.caption)
                    }
                }
            }
        } actions: {
            Button("Edit…") { let s = server; serverDetail = nil; editing = s }
                .buttonStyle(PillButtonStyle(kind: .neutral))
        }
    }

    private func detailBlock<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.nSurface))
        }
    }

    private func liveStatusDescription(_ state: MCPConnState) -> String {
        switch state {
        case .connected(let tools):
            guard let tools else { return "Connected. The provider did not report a tool count." }
            return tools == 1 ? "Connected, exposing 1 tool." : "Connected, exposing \(tools) tools."
        case .authenticated:
            return "Authenticated. Its tools mount on the next message."
        case .needsAuth: return "Needs sign-in before the agent can use it."
        case .checking: return "Checking…"
        case .failed(let why): return "Failed: \(why)"
        case .disabled: return "Reported disabled by the provider."
        case .unknown: return "Not checked yet. A real tool call is authoritative."
        }
    }

    private func connectorRow(_ name: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .foregroundStyle(Color.nInfoText).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).fontWeight(.medium)
                Text("Managed by Claude").font(.caption)
                    .foregroundStyle(Color.nSecondaryText)
            }
            Spacer(minLength: 8)
            connectorControl(name)
        }
    }

    /// Where this server came from, and who vouched. A row with NO provenance says so plainly
    /// rather than guessing: everything configured before provenance was recorded is genuinely
    /// unknown, and quietly labelling it "added by you" would be inventing an answer to the exact
    /// question — "I don't remember installing this" — that the badge exists to settle.
    @ViewBuilder
    private func provenanceBadge(_ server: MCPServer) -> some View {
        switch server.source {
        case .verified:
            let who = server.publisher ?? "the publisher"
            badgeChip("Verified", Color.nSuccessText)
                .help("Published by \(who). Verified means it comes from the vendor whose service it exposes.")
                .accessibilityLabel("Verified, published by \(who)")
        case .managed:
            badgeChip("Managed", Color.nInfoText)
                .help("Provided by your organization's managed configuration.")
                .accessibilityLabel("Managed by your organization")
        case .user:
            if let publisher = server.publisher, !publisher.isEmpty {
                badgeChip("From \(publisher)", Color.nSecondaryText)
                    .help("Added from the source “\(publisher)”, which you added.")
                    .accessibilityLabel("From \(publisher)")
            } else {
                badgeChip("Added by you", Color.nSecondaryText)
                    .accessibilityLabel("Added by you")
            }
        case .none:
            badgeChip("Unknown origin", Color.nWarningText)
                .help("This server predates provenance tracking, so its origin was never recorded. "
                      + "Remove and re-add it if you don't recognise it.")
                .accessibilityLabel("Unknown origin, not recorded")
        }
    }

    private func badgeChip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            // The semantic inks sit close to the small-text contrast threshold by design. Tinting
            // their own background toward the ink lowers that contrast in both appearances, so
            // keep the card surface and carry the status color on the keyline instead.
            .background(Capsule().fill(Color.nSurface))
            .overlay(Capsule().strokeBorder(color.opacity(0.40)))
    }

    /// Plugin folders, in the SAME scroll and under the SAME header as servers — not a second
    /// self-contained view stacked below with its own title and its own Sources button. Composing
    /// two complete screens produced three "Sources…" buttons, three headings, and a server list
    /// squeezed into one visible row. Both are extensions from a source; one surface, two sections.
    @ViewBuilder
    private var pluginFoldersSection: some View {
        let localFolderCount = store.plugins.lazy.filter { !$0.isCatalogBacked }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Plugin Folders").font(.system(size: 13, weight: .semibold))
                Text("\(localFolderCount)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { pickingPlugin = true } label: {
                    Label("Add Folder", systemImage: "plus")
                }
                .buttonStyle(PillButtonStyle(kind: .neutral))
            }

            if localFolderCount == 0 {
                Text("No plugin folders. A plugin can bundle skills, agents, hooks, commands or MCP "
                     + "servers; its contents appear in their own sections once added.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach($store.plugins) { $plugin in
                if !plugin.isCatalogBacked {
                    HStack(spacing: 10) {
                        Toggle("", isOn: $plugin.enabled).labelsHidden()
                            .onChange(of: plugin.enabled) { _, _ in store.save() }
                            .accessibilityLabel("Enable \(plugin.displayName)")
                        Image(systemName: "shippingbox")
                            .foregroundStyle(Color.nInfoText).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(plugin.displayName).fontWeight(.medium)
                            Text(plugin.path).font(.caption)
                                .foregroundStyle(Color.nSecondaryText)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Button(role: .destructive) { store.removePlugin(plugin.id) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.nErrorText)
                        .accessibilityLabel("Remove \(plugin.displayName)")
                    }
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.nSurface))
                }
            }
        }
    }

    private func connectionDetail(_ server: MCPServer) -> String {
        if server.isRemote {
            return URL(string: server.url)?.host ?? "Remote MCP"
        }
        let command = ([server.command] + server.args).filter { !$0.isEmpty }.joined(separator: " ")
        return command.isEmpty ? "Local MCP" : command
    }

    private func connectName(_ server: MCPRegistryServer) -> String {
        let base = server.displayTitle.lowercased()
            .replacingOccurrences(of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return base.isEmpty ? "mcp-server" : base
    }

    private func addConnection(_ catalogServer: MCPRegistryServer) {
        var name = connectName(catalogServer)
        if store.mcpServers.contains(where: { $0.name == name }) {
            var suffix = 2
            while store.mcpServers.contains(where: { $0.name == "\(name)-\(suffix)" }) { suffix += 1 }
            name = "\(name)-\(suffix)"
        }
        guard let remote = catalogServer.firstRemote else { return }
        var server = MCPServer(name: name)
        server.transport = remote.type == "sse" ? .sse : .http
        server.url = remote.url
        // Provenance travels with the server. Without this a row could never answer "where did
        // this come from?" — which is exactly how a list of seven servers became unrecognisable.
        server.source = catalogServer.source
        server.publisher = catalogServer.publisher
        server.networkScope = catalogServer.networkScope
        server.sha256 = catalogServer.sha256
        if catalogServer.name == "com.github/mcp" {
            DispatchQueue.main.async { editing = server }
            return
        }
        store.upsert(server)
        if supportsLiveMCP {
            // Publish the accepted click first. Authorization itself is deferred one UI turn, so
            // the configuration reload still reaches agentd before the prepared request begins.
            active.bridge?.mcpAuthorize(name, for: extensionAccess)
            active.bridge?.reloadMcpConfiguration(for: extensionAccess)
        }
    }

    /// Unified status + auth control for an enabled MCP server. In-progress OAuth state takes
    /// visual priority; Cancel appears only after agentd owns an exact request. Otherwise we render
    /// the live connection status (`connState`) as a badge plus a context-appropriate action.
    @ViewBuilder private func mcpStatusControl(_ s: MCPServer) -> some View {
        let name = s.name   // RAW name: the key agentd/connState/authState all use
        let auth = store.authState(for: name, access: extensionAccess)
        HStack(spacing: 8) {
            switch auth {
            case .preparing:
                OrbitingDots(diameter: 13, allowsVisualOverflow: true)
                Text("Preparing sign-in…")
                    .font(.caption).foregroundStyle(Color.nSecondaryText)
            case .authorizing, .waiting:
                OrbitingDots(diameter: 13, allowsVisualOverflow: true)
                if auth == .waiting {
                    Text("Check your browser…")
                        .font(.caption).foregroundStyle(Color.nSecondaryText)
                } else {
                    Text("Opening sign-in…")
                        .font(.caption).foregroundStyle(Color.nSecondaryText)
                }
                // Manual fallback: a cold-launching default browser can DROP the URL LaunchServices
                // hands it (seen live: Chrome came up on chrome://newtab). Keep the sign-in page a
                // click away instead of leaving the user staring at a spinner.
                if auth == .waiting,
                   let u = store.authURL(for: name, access: extensionAccess),
                   let url = URL(string: u) {
                    Button("Open sign-in page") { NSWorkspace.shared.open(url) }
                        .buttonStyle(PillButtonStyle(kind: .accent))
                }
                Button("Cancel") { active.bridge?.mcpAuthorizeCancel(name, for: extensionAccess) }
                    .buttonStyle(PillButtonStyle(kind: .neutral))
            case .failed(let failure):
                // A failed sign-in attempt — the REASON shows inline (a tooltip hid it, and users
                // retried a doomed flow). The typed recovery policy below points servers without
                // browser OAuth at the header-token editor without matching English prose.
                let presentation = MCPAuthorizationFailurePresentation.resolve(
                    failure,
                    hasManualCredentials: s.hasManualHeaderCredentials)
                VStack(alignment: .trailing, spacing: 2) {
                    Label(presentation.title, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon).font(.caption)
                        .foregroundStyle(Color.nWarningText)
                        .fixedSize()
                    Text(presentation.message).font(.caption2)
                        .foregroundStyle(Color.nSecondaryText)
                        .lineLimit(2).frame(maxWidth: 260, alignment: .trailing)
                        .help(presentation.message)
                }
                authorizationFailureAction(presentation.action, name: name, server: s)
            default:
                // Only `.checking` means a probe is actually in flight. A completed or timed-out
                // probe maps to `.unknown` and must not be turned back into an endless spinner.
                let conn = store.connState(for: name, access: extensionAccess)
                statusBadge(conn, manualCredentials: s.hasManualHeaderCredentials)
                if conn.wantsAuth {
                    if s.hasManualHeaderCredentials {
                        Button("Edit Credentials") { editing = s }
                            .buttonStyle(PillButtonStyle(kind: .accent))
                            .controlSize(.small)
                    } else {
                        Button("Sign In") { active.bridge?.mcpAuthorize(name, for: extensionAccess) }
                            .buttonStyle(PillButtonStyle(kind: .accent))
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    /// Status + sign-in control for a claude.ai connector. Mirrors `mcpStatusControl` minus the
    /// Edit/token affordances (a connector's config lives on claude.ai, not in extensions.json).
    /// "Sign in" stays offered even when the status is unknown — connectors can report `pending`
    /// indefinitely, and re-authorizing is the thing users come here to do.
    @ViewBuilder private func connectorControl(_ name: String) -> some View {
        let auth = store.authState(for: name, access: extensionAccess)
        HStack(spacing: 8) {
            switch auth {
            case .preparing:
                OrbitingDots(diameter: 13, allowsVisualOverflow: true)
                Text("Preparing sign-in…")
                    .font(.caption).foregroundStyle(Color.nSecondaryText)
            case .authorizing, .waiting:
                OrbitingDots(diameter: 13, allowsVisualOverflow: true)
                if auth == .waiting {
                    Text("Check your browser…")
                        .font(.caption).foregroundStyle(Color.nSecondaryText)
                } else {
                    Text("Opening sign-in…")
                        .font(.caption).foregroundStyle(Color.nSecondaryText)
                }
                if auth == .waiting,
                   let u = store.authURL(for: name, access: extensionAccess),
                   let url = URL(string: u) {
                    Button("Open sign-in page") { NSWorkspace.shared.open(url) }
                        .buttonStyle(PillButtonStyle(kind: .accent))
                }
                Button("Cancel") { active.bridge?.mcpAuthorizeCancel(name, for: extensionAccess) }
                    .buttonStyle(PillButtonStyle(kind: .neutral))
            case .failed(let failure):
                let presentation = MCPAuthorizationFailurePresentation.resolve(
                    failure,
                    hasManualCredentials: false,
                    allowsManualCredentials: false)
                VStack(alignment: .trailing, spacing: 2) {
                    Label(presentation.title, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon).font(.caption)
                        .foregroundStyle(Color.nWarningText)
                    Text(presentation.message).font(.caption2)
                        .foregroundStyle(Color.nSecondaryText)
                        .lineLimit(2).frame(maxWidth: 260, alignment: .trailing)
                        .help(presentation.message)
                }
                authorizationFailureAction(presentation.action, name: name, server: nil)
                connectorActionsMenu(name)
            default:
                let conn = store.connState(for: name, access: extensionAccess)
                statusBadge(conn)
                if conn.wantsAuth {
                    Button("Sign In") { active.bridge?.mcpAuthorize(name, for: extensionAccess) }
                        .buttonStyle(PillButtonStyle(kind: .accent))
                        .controlSize(.small)
                }
                connectorActionsMenu(name)
            }
        }
    }

    /// Compact status pill mirroring the SDK's per-server connection status.
    @ViewBuilder private func statusBadge(
        _ conn: MCPConnState,
        manualCredentials: Bool = false
    ) -> some View {
        switch conn {
        case .unknown:
            Label("Not checked", systemImage: "minus.circle")
                .labelStyle(.titleAndIcon).font(.caption)
                .foregroundStyle(Color.nSecondaryText)
                .help("The optional connection check did not return a definitive status. A real conversation can still use this server.")
        case .checking:
            HStack(spacing: 5) {
                OrbitingDots(diameter: 13, allowsVisualOverflow: true)
                Text("Checking…").font(.caption)
                    .foregroundStyle(Color.nSecondaryText)
            }
        case .authenticated:
            Label("Authenticated", systemImage: "key.fill")
                .labelStyle(.titleAndIcon).font(.caption)
                .foregroundStyle(Color.nSuccessText)
                .help("The credential is saved. The next real conversation verifies and mounts this server's tools.")
        case .connected(.some(let n)):
            Label("Connected · \(n) tool\(n == 1 ? "" : "s")",
                  systemImage: n > 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon).font(.caption)
                .foregroundStyle(n > 0 ? Color.nSuccessText : Color.nWarningText)
                .help(n > 0
                      ? "The server is mounted and its tools are available to new turns."
                      : "The transport connected, but the provider reported no tools. The agent cannot use this server yet.")
        case .connected(nil):
            Label("Connected", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon).font(.caption)
                .foregroundStyle(Color.nSuccessText)
                .help("The server is mounted in a real conversation or connected without reporting an exact tool count.")
        case .needsAuth:
            if manualCredentials {
                Label("Credentials rejected", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon).font(.caption)
                    .foregroundStyle(Color.nWarningText)
                    .help("Edit the saved header or PAT. This server uses manual credentials, not browser sign-in.")
            } else {
                Label("Needs sign-in", systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon).font(.caption)
                    .foregroundStyle(Color.nWarningText)
            }
        case .failed(let msg):
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon).font(.caption)
                .foregroundStyle(Color.nErrorText)
                .help(msg)
        case .disabled:
            Text("Disabled").font(.caption).foregroundStyle(Color.nSecondaryText)
        }
    }

    private func serverActionsMenu(_ server: MCPServer) -> some View {
        let name = server.name
        return Menu {
            if server.isRemote {
                Button("Refresh Authorization Status", systemImage: "arrow.clockwise") {
                    active.bridge?.refreshMcpStatus(for: extensionAccess)
                }
                Divider()
                if server.hasManualHeaderCredentials {
                    Button("Edit Credentials…", systemImage: "key") { editing = server }
                    Button("Clear Credentials", role: .destructive) {
                        active.bridge?.mcpClearAuth(name, for: extensionAccess)
                    }
                } else {
                    Button("Authenticate…") {
                        active.bridge?.mcpAuthorize(name, for: extensionAccess)
                    }
                    Button("Re-authenticate…") {
                        active.bridge?.mcpReauthorize(name, for: extensionAccess)
                    }
                    Button("Clear Authorization", role: .destructive) {
                        active.bridge?.mcpClearAuth(name, for: extensionAccess)
                    }
                }
                Divider()
            }
            Button("Edit Server…", systemImage: "slider.horizontal.3") { editing = server }
            Button("Remove Server…", systemImage: "trash", role: .destructive) {
                confirmingServerRemoval = server
            }
        } label: {
            ExtensionIconLabel(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        .help(server.hasManualHeaderCredentials
              ? "Refresh, edit credentials, or remove \(name)"
              : "Refresh authorization, authenticate, edit, or remove \(name)")
        .accessibilityLabel("Manage \(name)")
    }

    private func connectorActionsMenu(_ name: String) -> some View {
        Menu {
            Button("Check Connection", systemImage: "arrow.clockwise") {
                active.bridge?.refreshMcpStatus(
                    for: extensionAccess, includeProviderConnectors: true)
            }
            Divider()
            Button("Authenticate…") {
                active.bridge?.mcpAuthorize(name, for: extensionAccess)
            }
            Button("Re-authenticate…") {
                active.bridge?.mcpReauthorize(name, for: extensionAccess)
            }
            Divider()
            Button("Clear Authorization", role: .destructive) {
                active.bridge?.mcpClearAuth(name, for: extensionAccess)
            }
        } label: {
            ExtensionIconLabel(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(active.bridge == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
        .help("Check or manage authorization for \(name)")
        .accessibilityLabel("Manage \(name)")
    }
}

/// Compact panel glyph with the same hover surface as Mechanician's conversation controls. This
/// avoids falling back to AppKit's blue borderless-button chrome for edit/refresh/remove actions.
private struct ExtensionIconLabel: View {
    let systemName: String
    var tint: Color = .nText
    @State private var hovering = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(hovering ? tint : tint.opacity(0.78))
            .frame(width: 28, height: 26)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Color.nElevated.opacity(0.9) : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

/// The small, curated entry point for common remote services. MCP remains available as the
/// advanced/manual connection mechanism without exposing a general registry browser.
private struct AddConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var registry = MCPRegistryClient()
    @ObservedObject private var store = ExtensionsStore.shared
    @ObservedObject private var active = ActiveWorkspace.shared
    @State private var dismissedSourceIssueIDs = Set<UUID>()
    let isConnected: (MCPRegistryServer) -> Bool
    let onConnect: (MCPRegistryServer) -> Void
    let onAddMCPServer: () -> Void

    /// Four pinned starting points, from Mechanician's own curated list. This used to read through
    /// `VerifiedCatalog`, which promised a signed remote manifest that could update without a build
    /// — but its refresh had no caller and its feed host did not resolve, so it only ever returned
    /// `MCPCatalog.servers`. Saying so directly is the same behaviour with none of the pretence.
    private var commonServices: [MCPRegistryServer] {
        ["com.github/mcp", "com.notion/mcp", "app.linear/mcp", "dev.sentry/mcp"]
            .compactMap { id in MCPCatalog.servers.first(where: { $0.name == id }) }
    }
    private var managedSources: [RegistrySource] {
        store.effectiveRegistrySources.filter(\.isManaged)
    }
    private var managedServices: [MCPRegistryServer] {
        registry.featured.sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Connection").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(PillButtonStyle(kind: .neutral))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            Form {
                if !managedSources.isEmpty {
                    Section {
                        ForEach(registry.sourceIssues.filter {
                            !dismissedSourceIssueIDs.contains($0.id)
                        }) { issue in
                            sourceIssueRow(issue)
                        }
                        if registry.loadingFeatured && managedServices.isEmpty {
                            HStack(spacing: 8) {
                                OrbitingDots(diameter: 13, allowsVisualOverflow: true)
                                Text("Loading servers available through your profile…")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else if managedServices.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("No managed servers could be loaded.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(managedServices) { serviceRow($0, managed: true) }
                        }
                    } header: {
                        Text(TenantProfile.current.displayName == "Mechanician"
                             ? "Managed Catalog" : "\(TenantProfile.current.displayName) Catalog")
                    } footer: {
                        Text("A profile supplies a catalog. Choose Connect to configure a server for Mechanician and begin its sign-in flow.")
                    }
                }

                Section("Apps & Services") {
                    ForEach(commonServices) { serviceRow($0, managed: false) }
                }

                Section("Advanced") {
                    Button(action: onAddMCPServer) {
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 18)).foregroundStyle(Color.nInfoText)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("MCP Server").foregroundStyle(.primary)
                                Text("Configure a local process or remote endpoint")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 660, height: 530)
        .background(Color.nBg)
        .task(id: managedSources) {
            registry.featured = []
            await registry.loadFeatured(via: active.bridge, sources: managedSources)
        }
    }

    private func sourceIssueRow(_ issue: ExtensionSourceIssue) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: issue.systemImage)
                .foregroundStyle(Color.nWarningText)
                .frame(width: 18)
            Text(issue.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if issue.isRetryable {
                Button("Retry") { retryManagedSources() }
                    .buttonStyle(PillButtonStyle(kind: .neutral))
                    .disabled(registry.loadingFeatured)
            }
            Button {
                dismissedSourceIssueIDs.insert(issue.id)
            } label: {
                ExtensionIconLabel(systemName: "xmark", tint: .secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss \(issue.sourceName) warning")
        }
        .padding(.vertical, 3)
    }

    private func retryManagedSources() {
        dismissedSourceIssueIDs.removeAll()
        registry.featured = []
        Task {
            await registry.loadFeatured(via: active.bridge, sources: managedSources)
        }
    }

    private func serviceRow(_ service: MCPRegistryServer, managed: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            MakerBadge(text: service.maker, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(service.displayTitle).fontWeight(.medium)
                    if managed {
                        Text("Managed")
                            .font(.caption2).foregroundStyle(Color.nInfoText)
                    }
                    if service.networkScope == .vpnOnly {
                        Text("VPN")
                            .font(.caption2).foregroundStyle(Color.nWarningText)
                    }
                    RegistryGovernanceBadge(governance: service.governance)
                    if let authenticationBadge = service.authenticationBadge {
                        Text(authenticationBadge)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(service.description)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            if isConnected(service) {
                Label("Configured", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(Color.nSuccessText)
                    .fixedSize()
            } else {
                Button("Connect") { onConnect(service) }
                    .buttonStyle(PillButtonStyle(kind: .accent))
                    .fixedSize()
            }
        }
        .padding(.vertical, 4)
    }
}

/// Plugin folders are distinct from MCP servers: a package may contribute skills, agents, hooks,
/// commands, or servers at once, so it belongs in its own Extensions category.

/// Add/edit an MCP server. Transport picks which fields apply; args/env/headers are edited as text
/// (one entry per line) and parsed on save.
private struct MCPServerEditor: View {
    @State var server: MCPServer
    /// Hosted inside the Add Server tab rather than a sheet: the tab is the title, so the view
    /// must not repeat it.
    var inlineInTab = false
    let onSave: (MCPServer) -> Void
    let onCancel: () -> Void

    @State private var argsText = ""
    @State private var envText = ""
    @State private var headersText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !inlineInTab {
                Text(server.name.isEmpty ? "Add MCP Server" : "Edit “\(server.name)”")
                    .font(.headline).padding([.horizontal, .top], 16).padding(.bottom, 4)
            }
            Form {
                Section {
                    TextField("Name", text: $server.name)
                        .help("A unique identifier. Tools appear as mcp__<name>__<tool>.")
                    Picker("Type", selection: $server.transport) {
                        ForEach(MCPTransport.allCases) { Text($0.label).tag($0) }
                    }
                }
                if server.transport == .stdio {
                    Section("Command") {
                        TextField("Command (e.g. npx)", text: $server.command)
                        labeledEditor("Arguments (one per line)", $argsText)
                        labeledEditor("Environment (KEY=value per line)", $envText)
                    }
                } else {
                    Section {
                        TextField("URL (https://…)", text: $server.url)
                        labeledEditor("Headers (KEY=value per line)", $headersText)
                    } header: {
                        Text(server.transport.label)
                    } footer: {
                        if URL(string: server.url)?.host == "api.githubcopilot.com" {
                            Text("GitHub requires `Authorization=Bearer YOUR_TOKEN`.")
                        } else {
                            Text("Leave headers empty when the service supports browser sign-in.")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }.buttonStyle(PillButtonStyle(kind: .neutral))
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    server.name = server.name.trimmingCharacters(in: .whitespaces)
                    server.args = Self.parseLines(argsText)
                    server.env = Self.parseKV(envText)
                    server.headers = Self.parseKV(headersText)
                    onSave(server)
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, inlineInTab ? 10 : 16)
        }
        // In the Add Server tab the Form owns the scrolling region and the action row stays
        // pinned beneath it. Wrapping this fixed-height editor in another ScrollView put Save and
        // Cancel below the minimum-height Extensions window — exactly the controls a person needs
        // to finish. The sheet variant keeps its established 480 × 480 presentation.
        .frame(width: inlineInTab ? nil : 480,
               height: inlineInTab ? nil : 480)
        .frame(maxWidth: inlineInTab ? 560 : nil,
               maxHeight: inlineInTab ? .infinity : nil,
               alignment: .topLeading)
        .background(Color.nBg)
        .onAppear {
            argsText = server.args.joined(separator: "\n")
            envText = server.env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
            headersText = server.headers.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
        }
    }

    private var valid: Bool {
        !server.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        (server.transport == .stdio
            ? !server.command.trimmingCharacters(in: .whitespaces).isEmpty
            : !server.url.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Arguments, environment and headers are all source, not prose. A SwiftUI `TextEditor` applies
    /// the system's automatic substitutions, which rewrites `--flag` to `–flag` and
    /// `Authorization=Bearer "token"` to curly quotes — silently, at the keystroke, producing an MCP
    /// server that fails to start for a reason nothing in the UI explains (FR-335).
    @ViewBuilder private func labeledEditor(_ title: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            // 10pt matches what `.font(.system(.caption))` resolved to here, so the fields keep
            // their existing density.
            SourceTextEditor(text: text, fontSize: 10, insets: NSSize(width: 4, height: 4))
                .frame(height: inlineInTab ? 44 : 56)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.25)))
        }
    }

    static func parseLines(_ s: String) -> [String] {
        s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    static func parseKV(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in s.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            out[key] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return out
    }
}

/// Add/edit an MCP registry source (name + a /v0.1/servers-compatible URL).
private struct RegistrySourceEditor: View {
    @State var source: RegistrySource
    let onSave: (RegistrySource) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(source.url.isEmpty ? "Add MCP Registry" : "Edit Registry")
                .font(.headline).padding([.horizontal, .top], 16).padding(.bottom, 4)
            Form {
                Section {
                    TextField("Name (optional)", text: $source.name)
                    TextField("Registry URL (https://…)", text: $source.url)
                        .autocorrectionDisabled()
                    Picker("Format", selection: $source.format) {
                        ForEach(RegistryFormat.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text(source.format.hint)
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }.buttonStyle(PillButtonStyle(kind: .neutral)).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(source) }.buttonStyle(PillButtonStyle(kind: .accent))
                    .keyboardShortcut(.defaultAction).disabled(!source.isValid)
            }
            .padding(16)
        }
        .frame(width: 460).background(Color.nBg)
    }
}

/// Add/edit a plugin marketplace source (name + owner/repo or a marketplace.json URL).
private struct MarketplaceSourceEditor: View {
    @State var source: MarketplaceSource
    let onSave: (MarketplaceSource) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(source.repo.isEmpty ? "Add Plugin Marketplace" : "Edit Marketplace")
                .font(.headline).padding([.horizontal, .top], 16).padding(.bottom, 4)
            Form {
                Section {
                    TextField("Name (optional)", text: $source.name)
                    TextField("owner/repo or marketplace.json URL", text: $source.repo)
                        .autocorrectionDisabled()
                } footer: {
                    Text("A Claude Code plugin marketplace: a git repo containing `.claude-plugin/marketplace.json` (e.g. `anthropics/claude-plugins-official`).")
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }.buttonStyle(PillButtonStyle(kind: .neutral)).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(source) }.buttonStyle(PillButtonStyle(kind: .accent))
                    .keyboardShortcut(.defaultAction).disabled(!source.isValid)
            }
            .padding(16)
        }
        .frame(width: 460).background(Color.nBg)
    }
}
