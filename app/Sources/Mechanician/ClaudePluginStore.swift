import Foundation
import Combine
import CryptoKit

/// Claude plugin marketplaces, in Anthropic's own vocabulary, plus archive-backed catalogs.
///
/// The provider supplies every noun here — **marketplace**, **plugin**, and the `plugin@marketplace`
/// identity — so native marketplaces use the provider's CLI. Archive registries point to individual
/// tarballs instead; those are authenticated and materialized by agentd, then mounted through the
/// SDK's existing reviewed local-plugin path.
///
/// Provider marketplace work happens in agentd, which drives the bundled `claude` binary. Writing
/// `extraKnownMarketplaces` into settings.json was measured NOT to install anything.
@MainActor
final class ClaudePluginStore: ObservableObject {
    static let shared = ClaudePluginStore()

    struct Marketplace: Identifiable, Equatable {
        var id: String { archiveSourceID?.uuidString.lowercased() ?? name }
        let name: String
        let source: String        // "github", "url", "file", …
        let repo: String?
        let installLocation: String?
        let isManaged: Bool
        let networkScope: ExtensionNetworkScope?
        /// Non-nil for an app-owned archive registry rather than a provider CLI marketplace.
        let archiveSourceID: UUID?

        /// What a person would recognise: `anthropics/knowledge-work-plugins` beats "github".
        var detail: String {
            if isManaged {
                return networkScope == .vpnOnly
                    ? "Managed by your organization · VPN"
                    : "Managed by your organization"
            }
            return repo ?? installLocation ?? source
        }

        var isArchiveCatalog: Bool { archiveSourceID != nil }
    }

    /// What a plugin actually contains. The answer to "what am I installing?" — and, for something
    /// already installed, "what did I put in here?", which is the same question asked later.
    struct Components: Equatable {
        let commands: [String]
        let agents: [String]
        let skills: [String]
        let hooks: [String]
        let mcpServers: [String]
        let lspServers: [String]

        var isEmpty: Bool {
            commands.isEmpty && agents.isEmpty && skills.isEmpty
                && hooks.isEmpty && mcpServers.isEmpty && lspServers.isEmpty
        }

        /// Ordered for a reader, not for the schema: what it can DO first, what it wires up after.
        var groups: [(label: String, names: [String])] {
            [("Skills", skills), ("Commands", commands), ("Agents", agents),
             ("Hooks", hooks), ("MCP servers", mcpServers), ("LSP servers", lspServers)]
                .filter { !$0.names.isEmpty }
        }

        init?(_ row: [String: Any]?) {
            guard let row else { return nil }
            func names(_ key: String) -> [String] { row[key] as? [String] ?? [] }
            commands = names("commands"); agents = names("agents"); skills = names("skills")
            hooks = names("hooks"); mcpServers = names("mcpServers"); lspServers = names("lspServers")
        }

        init(commands: [String] = [], agents: [String] = [], skills: [String] = [],
             hooks: [String] = [], mcpServers: [String] = [], lspServers: [String] = []) {
            self.commands = commands
            self.agents = agents
            self.skills = skills
            self.hooks = hooks
            self.mcpServers = mcpServers
            self.lspServers = lspServers
        }
    }

    /// What having it enabled costs in context. `alwaysOn` is paid on EVERY turn just for being
    /// installed; `onInvoke` only when used. Nothing in either provider's own UI shows this, and it
    /// is the difference between a free plugin and a permanent tax on the context window.
    struct TokenCost: Equatable {
        let model: String
        let alwaysOn: Int
        let onInvoke: Int

        init?(_ row: [String: Any]?) {
            guard let row, let model = row["model"] as? String else { return nil }
            self.model = model
            alwaysOn = row["alwaysOn"] as? Int ?? 0
            onInvoke = row["onInvoke"] as? Int ?? 0
        }
    }

    /// Everything agentd needs to materialize one archive without trusting an arbitrary path or
    /// handing an enterprise identity token to an unrelated host.
    struct ArchiveInstall: Equatable {
        let sourceID: UUID
        let sourceName: String
        let catalogURL: String
        let archiveURL: String
        let expectedSHA256: String?
        let version: String?
        let authentication: ExtensionSourceAuthentication?
        let networkScope: ExtensionNetworkScope?
        let isManaged: Bool

        func request(pluginID: String, pluginName: String) -> [String: Any] {
            var request: [String: Any] = [
                "action": "installArchive",
                "pluginId": pluginID,
                "pluginName": pluginName,
                "sourceId": sourceID.uuidString.lowercased(),
                "sourceName": sourceName,
                "catalogUrl": catalogURL,
                "archiveUrl": archiveURL,
                "managed": isManaged,
            ]
            if let expectedSHA256 { request["sha256"] = expectedSHA256 }
            if let version { request["version"] = version }
            if let authentication { request["authentication"] = authentication.rawValue }
            if let networkScope { request["networkScope"] = networkScope.rawValue }
            return request
        }
    }

    /// An entry offered by a marketplace.
    ///
    /// The CLI's browse feed carries seven fields; `category`, `homepage` and `author` come from the
    /// marketplace manifest on disk, which agentd joins in (see `claude-plugins.mjs`). There is
    /// genuinely no icon anywhere in Anthropic's schema — that, and only that, is why these cards
    /// stay text-only while the Codex ones carry art. An earlier version of this comment claimed
    /// there was no category or author either; there is, on 95% and 69% of entries.
    struct Available: Identifiable, Equatable {
        var id: String { pluginId }
        let pluginId: String      // `plugin@marketplace`
        let name: String
        let displayName: String?
        let description: String
        let marketplaceName: String
        let category: String?
        let homepage: String?
        let authorName: String?
        let authorURL: String?
        /// How many people run it. The strongest trust signal in the whole feed, and it was already
        /// arriving in the payload — only the struct was blocking it.
        let installCount: Int?
        let sourceURL: String?
        let components: Components?
        let tokenCost: TokenCost?
        let archiveInstall: ArchiveInstall?
        let canInstall: Bool
        let installUnavailableReason: String?
        let isManaged: Bool

        var title: String { displayName ?? name }
    }

    struct Installed: Identifiable, Equatable {
        var id: String { pluginId }
        let pluginId: String
        let version: String?
        let scope: String?
        let enabled: Bool
        let mcpServers: [String]
        /// An installed plugin needs its inventory MORE than an uninstalled one, not less.
        let components: Components?
        let tokenCost: TokenCost?
        let installCount: Int?
        /// Read from the catalog cache's embedded marketplace entry, because the CLI omits an
        /// installed plugin from its `available` list — so looking it up there finds nothing.
        let description: String
        let category: String?
        let homepage: String?
        let authorName: String?
        let authorURL: String?
        let marketplaceDisplayName: String?

        /// `data@knowledge-work-plugins` → `data`. The marketplace is shown separately.
        var shortName: String { pluginId.split(separator: "@").first.map(String.init) ?? pluginId }
        var marketplaceName: String {
            marketplaceDisplayName
                ?? pluginId.split(separator: "@").dropFirst().first.map(String.init) ?? ""
        }
    }

    @Published private(set) var marketplaces: [Marketplace] = []
    @Published private(set) var available: [Available] = []
    @Published private(set) var providerInstalled: [Installed] = []
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?
    @Published private(set) var archiveCatalogIssues: [UUID: ExtensionSourceIssue] = [:]
    @Published private(set) var archiveCatalogLoading: Set<UUID> = []
    /// The plugin currently installing, so its own card can show progress instead of a global spinner.
    @Published private(set) var busyPluginID: String?

    private var loadedOnce = false
    private var providerMarketplaces: [Marketplace] = []
    private var providerAvailable: [Available] = []
    private var archiveMarketplaces: [Marketplace] = []
    private var archiveAvailable: [Available] = []
    private var archiveCatalogGeneration = UUID()
    private struct PendingArchiveInstall {
        let bridge: AgentBridge
        let pluginID: String
    }
    private var pendingArchiveInstalls: [String: PendingArchiveInstall] = [:]
    private var foregroundOperationID: String?
    private var cleanupRequestsInFlight: [UUID: AgentBridge] = [:]
    private var cleanupRetryTasks: [UUID: Task<Void, Never>] = [:]
    private var finalizationRequestsInFlight: [UUID: AgentBridge] = [:]
    private var finalizationRetryTasks: [UUID: Task<Void, Never>] = [:]
    private var archiveReconciliationInFlight = false

    /// Archive installs are persisted in extensions.json and mounted on every Claude lane. Native
    /// CLI installs remain route-owned; merge the two projections without letting a stale CLI list
    /// erase a durable archive install.
    var installed: [Installed] {
        let archive = ExtensionsStore.shared.plugins.compactMap(archiveInstalled)
        let archiveIDs = Set(archive.map(\.pluginId))
        return archive + providerInstalled.filter { !archiveIDs.contains($0.pluginId) }
    }

    func loadIfNeeded(bridge: AgentBridge?) {
        guard !loadedOnce else { return }
        loadedOnce = true
        refresh(bridge: bridge)
    }

    func refresh(bridge: AgentBridge?) {
        guard canStartForegroundAction() else { return }
        send(["action": "list"], bridge: bridge)
    }

    /// Load archive registries separately from the provider CLI's own marketplaces.
    ///
    /// The source row is published before the first network await, so a VPN/auth failure leaves a
    /// visible marketplace with useful recovery guidance instead of making it disappear. Sources
    /// may come from a signed profile or from a registry the user added themselves.
    func loadArchiveCatalog(via bridge: AgentBridge?, sources: [MarketplaceSource]) async {
        let active = sources.filter {
            $0.enabled && $0.isValid && $0.format == .archiveRegistryV1
        }
        let generation = UUID()
        archiveCatalogGeneration = generation
        archiveMarketplaces = active.map(Self.archiveMarketplacePlaceholder)
        archiveAvailable = []
        archiveCatalogIssues = [:]
        archiveCatalogLoading = Set(active.map(\.id))
        publishCombinedCatalog()

        for source in active {
            guard archiveCatalogGeneration == generation, !Task.isCancelled else { return }
            do {
                let data = try await BrowseFetcher.shared.get(
                    source.rawURL,
                    via: bridge,
                    authentication: source.authentication)
                guard archiveCatalogGeneration == generation, !Task.isCancelled else { return }
                try Self.verifyCatalogDigest(data, expected: source.sha256)
                let decoded = try Self.decodeArchiveCatalog(source: source, data: data)
                replaceArchiveMarketplace(source.id, with: decoded.marketplace)
                archiveAvailable.removeAll { $0.archiveInstall?.sourceID == source.id }
                archiveAvailable.append(contentsOf: decoded.available)
                archiveCatalogIssues[source.id] = nil
            } catch is CancellationError {
                return
            } catch let error as BrowseFetcher.BrowseError {
                guard archiveCatalogGeneration == generation else { return }
                archiveCatalogIssues[source.id] = ExtensionSourceIssue(
                    sourceID: source.id,
                    sourceName: source.displayName,
                    networkScope: source.networkScope,
                    authentication: source.authentication,
                    kind: error.kind,
                    detail: error.message,
                    status: error.status)
            } catch {
                guard archiveCatalogGeneration == generation else { return }
                archiveCatalogIssues[source.id] = ExtensionSourceIssue(
                    sourceID: source.id,
                    sourceName: source.displayName,
                    networkScope: source.networkScope,
                    authentication: source.authentication,
                    kind: .invalidResponse,
                    detail: error.localizedDescription,
                    status: nil)
            }
            archiveCatalogLoading.remove(source.id)
            publishCombinedCatalog()
        }
    }

    func archiveIssue(in marketplace: Marketplace) -> ExtensionSourceIssue? {
        marketplace.archiveSourceID.flatMap { archiveCatalogIssues[$0] }
    }

    func isArchiveMarketplaceLoading(_ marketplace: Marketplace) -> Bool {
        marketplace.archiveSourceID.map(archiveCatalogLoading.contains) ?? false
    }

    func addMarketplace(_ source: String, bridge: AgentBridge?) {
        guard canStartForegroundAction() else { return }
        send(["action": "addMarketplace", "source": source], bridge: bridge)
    }

    func removeMarketplace(_ name: String, bridge: AgentBridge?) {
        guard canStartForegroundAction() else { return }
        send(["action": "removeMarketplace", "name": name], bridge: bridge)
    }

    func updateMarketplace(_ name: String, bridge: AgentBridge?) {
        guard canStartForegroundAction() else { return }
        send(["action": "updateMarketplace", "name": name], bridge: bridge)
    }

    func install(_ plugin: Available, bridge: AgentBridge?) {
        guard canStartForegroundAction() else { return }
        busyPluginID = plugin.pluginId
        if let archive = plugin.archiveInstall {
            let operationID = UUID().uuidString
            if let bridge {
                pendingArchiveInstalls[operationID] = PendingArchiveInstall(
                    bridge: bridge,
                    pluginID: plugin.pluginId)
            }
            send(
                archive.request(pluginID: plugin.pluginId, pluginName: plugin.name),
                bridge: bridge,
                operationID: operationID)
        } else {
            send(["action": "install", "pluginId": plugin.pluginId], bridge: bridge)
        }
    }

    func setEnabled(_ pluginId: String, _ enabled: Bool, bridge: AgentBridge?) {
        guard canStartForegroundAction() else { return }
        if ExtensionsStore.shared.catalogPlugin(withID: pluginId) != nil {
            lastError = ExtensionsStore.shared.setCatalogPluginEnabled(pluginId, enabled: enabled)
                ? nil
                : ExtensionsStore.shared.persistenceError ?? "The plugin setting could not be saved."
            return
        }
        busyPluginID = pluginId
        send(["action": enabled ? "enable" : "disable", "pluginId": pluginId], bridge: bridge)
    }

    /// Actually remove it, as distinct from disabling. `claude plugin uninstall` is a real verb;
    /// the app offered only Disable because a code comment here wrongly claimed it was not.
    func uninstall(_ pluginId: String, bridge: AgentBridge?) {
        guard canStartForegroundAction() else { return }
        if ExtensionsStore.shared.catalogPlugin(withID: pluginId) != nil {
            guard ExtensionsStore.shared.removeCatalogPlugin(pluginId) != nil else {
                lastError = ExtensionsStore.shared.persistenceError
                    ?? "This archive install is missing its verified installation identity."
                return
            }
            // The durable unmount is the user-visible operation. Byte cleanup is retryable
            // housekeeping and must not make an offline removal look like it failed.
            lastError = nil
            if let bridge {
                // One content-addressed path can have more than one outstanding install lease.
                // The atomic unmount transfers all of them into the durable cleanup queue.
                retryPendingArchiveCleanups(bridge: bridge)
            }
            return
        }
        busyPluginID = pluginId
        send(["action": "uninstall", "pluginId": pluginId], bridge: bridge)
    }

    func update(_ pluginId: String, bridge: AgentBridge?) {
        if ExtensionsStore.shared.catalogPlugin(withID: pluginId) != nil {
            guard let plugin = available.first(where: {
                $0.pluginId == pluginId && $0.archiveInstall != nil
            }) else {
                lastError = "Refresh this marketplace before checking for an archive update."
                return
            }
            install(plugin, bridge: bridge)
            return
        }
        guard canStartForegroundAction() else { return }
        busyPluginID = pluginId
        send(["action": "update", "pluginId": pluginId], bridge: bridge)
    }

    private func canStartForegroundAction() -> Bool {
        guard !isWorking else {
            lastError = "Wait for the current plugin action to finish, then try again."
            return false
        }
        return true
    }

    private func send(
        _ originalRequest: [String: Any],
        bridge: AgentBridge?,
        operationID suppliedOperationID: String? = nil
    ) {
        let operationID = suppliedOperationID ?? UUID().uuidString
        var request = originalRequest
        request["operationId"] = operationID
        foregroundOperationID = operationID
        guard let bridge else {
            pendingArchiveInstalls.removeValue(forKey: operationID)
            foregroundOperationID = nil
            lastError = "Open a conversation first. Plugin management needs a running agent."
            busyPluginID = nil
            isWorking = false
            return
        }
        isWorking = true
        lastError = nil
        bridge.claudePlugins(request)
    }

    /// Provider CLI mutations return the whole new provider state. Archive operations return only
    /// their scoped result because they may run on a Vertex auth lane whose CLI store is unrelated
    /// to the marketplace list currently on screen.
    func apply(_ event: [String: Any]) {
        let action = event["action"] as? String
        let isBackground = event["background"] as? Bool == true
        let cleanupID = (event["cleanupId"] as? String).flatMap(UUID.init(uuidString:))
        let finalizationID = (event["finalizationId"] as? String)
            .flatMap(UUID.init(uuidString:))
        var cleanupBridge: AgentBridge?
        var finalizationBridge: AgentBridge?
        if action == "removeArchive", let cleanupID {
            cleanupBridge = cleanupRequestsInFlight.removeValue(forKey: cleanupID)
        }
        if action == "finalizeArchive", let finalizationID {
            finalizationBridge = finalizationRequestsInFlight.removeValue(forKey: finalizationID)
        }
        if action == "reconcileArchives" {
            archiveReconciliationInFlight = false
        }
        if !isBackground {
            guard let operationID = event["operationId"] as? String,
                  operationID == foregroundOperationID else {
                if let operationID = event["operationId"] as? String {
                    pendingArchiveInstalls.removeValue(forKey: operationID)
                }
                return
            }
            foregroundOperationID = nil
            isWorking = false
            if action != "list" { busyPluginID = nil }
        }
        guard event["ok"] as? Bool == true else {
            if action == "installArchive",
               let operationID = event["operationId"] as? String {
                pendingArchiveInstalls.removeValue(forKey: operationID)
            }
            if isBackground {
                if action == "removeArchive", let cleanupID, let cleanupBridge {
                    scheduleArchiveCleanupRetry(
                        cleanupID, afterMilliseconds: 30_000, bridge: cleanupBridge)
                }
                if action == "finalizeArchive", let finalizationID, let finalizationBridge {
                    scheduleArchiveFinalizationRetry(
                        finalizationID, afterMilliseconds: 30_000, bridge: finalizationBridge)
                }
                return
            }
            lastError = event["message"] as? String ?? "The plugin command failed."
            return
        }
        if action == "removeArchive", let cleanupID,
           let removal = event["removal"] as? [String: Any],
           let status = removal["status"] as? String {
            switch status {
            case "removed", "missing", "mounted":
                cleanupRetryTasks.removeValue(forKey: cleanupID)?.cancel()
                if !ExtensionsStore.shared.completeArchiveCleanup(cleanupID),
                   let cleanupBridge {
                    scheduleArchiveCleanupRetry(
                        cleanupID, afterMilliseconds: 30_000, bridge: cleanupBridge)
                }
            case "protected":
                if let cleanupBridge {
                    let requestedDelay = (removal["retryAfterMilliseconds"] as? NSNumber)?
                        .doubleValue ?? 1_000
                    scheduleArchiveCleanupRetry(
                        cleanupID,
                        afterMilliseconds: min(max(requestedDelay, 250), 60_000),
                        bridge: cleanupBridge)
                }
            default:
                break
            }
        }
        if action == "finalizeArchive", let finalizationID {
            finalizationRetryTasks.removeValue(forKey: finalizationID)?.cancel()
            if !ExtensionsStore.shared.completeArchiveFinalization(finalizationID),
               let finalizationBridge {
                scheduleArchiveFinalizationRetry(
                    finalizationID, afterMilliseconds: 30_000, bridge: finalizationBridge)
            }
        }
        if isBackground { return }
        lastError = nil
        if action == "installArchive" {
            applyArchiveInstall(event)
            return
        }
        if action == "removeArchive" {
            return
        }
        providerMarketplaces = (event["marketplaces"] as? [[String: Any]] ?? []).compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return Marketplace(name: name,
                               source: row["source"] as? String ?? "",
                               repo: row["repo"] as? String,
                               installLocation: row["installLocation"] as? String,
                               isManaged: false,
                               networkScope: nil,
                               archiveSourceID: nil)
        }
        providerAvailable = (event["available"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["pluginId"] as? String else { return nil }
            // `source` is `{ source, url, sha }` for a git-backed plugin and a bare path string for
            // a vendored one. Only the URL form is something to link to.
            let source = row["source"] as? [String: Any]
            return Available(pluginId: id,
                             name: row["name"] as? String ?? id,
                             displayName: row["displayName"] as? String,
                             description: row["description"] as? String ?? "",
                             marketplaceName: row["marketplaceName"] as? String ?? "",
                             category: row["category"] as? String,
                             homepage: row["homepage"] as? String,
                             authorName: row["authorName"] as? String,
                             authorURL: row["authorURL"] as? String,
                             installCount: row["installCount"] as? Int,
                             sourceURL: source?["url"] as? String,
                             components: Components(row["components"] as? [String: Any]),
                             tokenCost: TokenCost(row["tokenCost"] as? [String: Any]),
                             archiveInstall: nil,
                             canInstall: true,
                             installUnavailableReason: nil,
                             isManaged: false)
        }
        providerInstalled = (event["installed"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return Installed(pluginId: id,
                             version: row["version"] as? String,
                             scope: row["scope"] as? String,
                             enabled: row["enabled"] as? Bool ?? true,
                             mcpServers: (row["mcpServers"] as? [String]) ?? [],
                             components: Components(row["components"] as? [String: Any]),
                             tokenCost: TokenCost(row["tokenCost"] as? [String: Any]),
                             installCount: row["installCount"] as? Int,
                             description: row["description"] as? String ?? "",
                             category: row["category"] as? String,
                             homepage: row["homepage"] as? String,
                             authorName: row["authorName"] as? String,
                             authorURL: row["authorURL"] as? String,
                             marketplaceDisplayName: nil)
        }
        publishCombinedCatalog()
    }

    private func applyArchiveInstall(_ event: [String: Any]) {
        let operationID = event["operationId"] as? String
        guard let row = event["archivePlugin"] as? [String: Any],
              let pluginID = row["pluginId"] as? String,
              let pluginName = row["pluginName"] as? String,
              let sourceIDRaw = row["sourceId"] as? String,
              let sourceID = UUID(uuidString: sourceIDRaw),
              let marketplaceName = row["sourceName"] as? String,
              let path = row["path"] as? String,
              let digest = row["sha256"] as? String,
              let leaseToken = row["leaseToken"] as? String,
              Self.isArchiveLeaseToken(leaseToken) else {
            if let operationID { pendingArchiveInstalls.removeValue(forKey: operationID) }
            lastError = "The archive installer returned an incomplete result."
            return
        }
        guard let operationID,
              let pending = pendingArchiveInstalls.removeValue(forKey: operationID),
              pending.pluginID == pluginID else {
            return
        }
        var plugin = LocalPlugin()
        plugin.name = pluginName
        plugin.enabled = true
        plugin.path = path
        plugin.source = (row["managed"] as? Bool == true) ? .managed : .user
        plugin.networkScope = (row["networkScope"] as? String)
            .flatMap(ExtensionNetworkScope.init(rawValue:))
        plugin.sha256 = digest
        plugin.catalogPluginID = pluginID
        plugin.marketplaceSourceID = sourceID
        plugin.marketplaceName = marketplaceName
        plugin.version = row["version"] as? String
        guard let installIdentity = ArchivePluginCleanup(plugin: plugin) else {
            lastError = "The archive installer returned an invalid installation identity."
            return
        }
        guard ExtensionsStore.shared.commitCatalogPlugin(plugin, leaseToken: leaseToken) else {
            requestArchiveInstallAbort(
                installIdentity,
                leaseToken: leaseToken,
                bridge: pending.bridge)
            lastError = ExtensionsStore.shared.persistenceError
                ?? "The plugin was verified, but its active configuration could not be saved."
            return
        }
        retryPendingArchiveFinalizations(bridge: pending.bridge)
        retryPendingArchiveCleanups(bridge: pending.bridge)
    }

    private func archiveRemovalRequest(
        _ cleanup: ArchivePluginCleanup,
        pluginID: String? = nil
    ) -> [String: Any]? {
        archiveIdentityRequest(
            action: "removeArchive",
            cleanup,
            pluginID: pluginID,
            cleanupID: cleanup.id)
    }

    private func archiveIdentityRequest(
        action: String,
        _ cleanup: ArchivePluginCleanup,
        pluginID: String? = nil,
        cleanupID: UUID? = nil,
        leaseToken: String? = nil
    ) -> [String: Any]? {
        guard let sourceID = cleanup.sourceID, cleanup.isValid else { return nil }
        var request: [String: Any] = [
            "action": action,
            "sourceId": sourceID.uuidString.lowercased(),
            "pluginName": cleanup.pluginName,
            "sha256": cleanup.sha256,
            "installPath": cleanup.installPath,
        ]
        if let cleanupID {
            request["cleanupId"] = cleanupID.uuidString.lowercased()
        }
        if let leaseToken = leaseToken ?? cleanup.leaseToken {
            request["leaseToken"] = leaseToken
        }
        if let version = cleanup.version { request["version"] = version }
        if let pluginID { request["pluginId"] = pluginID }
        return request
    }

    private func requestArchiveInstallFinalization(
        _ finalization: PendingArchiveFinalization,
        bridge: AgentBridge
    ) {
        guard finalizationRequestsInFlight[finalization.id] == nil,
              let cleanup = finalization.archiveCleanup else { return }
        guard var request = archiveIdentityRequest(
            action: "finalizeArchive",
            cleanup,
            pluginID: cleanup.pluginID,
            leaseToken: finalization.leaseToken)
        else { return }
        request["background"] = true
        request["finalizationId"] = finalization.id.uuidString.lowercased()
        finalizationRetryTasks.removeValue(forKey: finalization.id)?.cancel()
        finalizationRequestsInFlight[finalization.id] = bridge
        bridge.claudePlugins(request)
    }

    private func requestArchiveInstallAbort(
        _ cleanup: ArchivePluginCleanup,
        leaseToken: String,
        bridge: AgentBridge
    ) {
        guard var request = archiveIdentityRequest(
            action: "removeArchive",
            cleanup,
            pluginID: cleanup.pluginID,
            leaseToken: leaseToken)
        else { return }
        request["background"] = true
        bridge.claudePlugins(request)
    }

    private func requestArchiveCleanup(
        _ cleanup: ArchivePluginCleanup,
        pluginID: String? = nil,
        bridge: AgentBridge
    ) {
        if ExtensionsStore.shared.plugins.contains(where: { $0.path == cleanup.installPath }) {
            cleanupRetryTasks.removeValue(forKey: cleanup.id)?.cancel()
            if !ExtensionsStore.shared.completeArchiveCleanup(cleanup.id) {
                scheduleArchiveCleanupRetry(
                    cleanup.id, afterMilliseconds: 30_000, bridge: bridge)
            }
            return
        }
        guard cleanupRequestsInFlight[cleanup.id] == nil,
              var request = archiveRemovalRequest(cleanup, pluginID: pluginID) else { return }
        request["background"] = true
        cleanupRetryTasks.removeValue(forKey: cleanup.id)?.cancel()
        cleanupRequestsInFlight[cleanup.id] = bridge
        bridge.claudePlugins(request)
    }

    private func scheduleArchiveCleanupRetry(
        _ cleanupID: UUID,
        afterMilliseconds delay: Double,
        bridge: AgentBridge
    ) {
        cleanupRetryTasks.removeValue(forKey: cleanupID)?.cancel()
        cleanupRetryTasks[cleanupID] = Task { @MainActor [weak self, weak bridge] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self, let bridge else { return }
            self.cleanupRetryTasks[cleanupID] = nil
            guard let cleanup = ExtensionsStore.shared.pendingArchiveCleanups.first(where: {
                $0.id == cleanupID
            }) else { return }
            self.requestArchiveCleanup(cleanup, bridge: bridge)
        }
    }

    private func scheduleArchiveFinalizationRetry(
        _ finalizationID: UUID,
        afterMilliseconds delay: Double,
        bridge: AgentBridge
    ) {
        finalizationRetryTasks.removeValue(forKey: finalizationID)?.cancel()
        finalizationRetryTasks[finalizationID] = Task { @MainActor [weak self, weak bridge] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self, let bridge else { return }
            self.finalizationRetryTasks[finalizationID] = nil
            guard let finalization = ExtensionsStore.shared.pendingArchiveFinalizations.first(
                where: { $0.id == finalizationID }
            ) else { return }
            self.requestArchiveInstallFinalization(finalization, bridge: bridge)
        }
    }

    private func retryPendingArchiveCleanups(bridge: AgentBridge?) {
        guard let bridge else { return }
        for cleanup in ExtensionsStore.shared.pendingArchiveCleanups {
            requestArchiveCleanup(cleanup, bridge: bridge)
        }
    }

    private func retryPendingArchiveFinalizations(bridge: AgentBridge?) {
        guard let bridge else { return }
        for finalization in ExtensionsStore.shared.pendingArchiveFinalizations {
            requestArchiveInstallFinalization(finalization, bridge: bridge)
        }
    }

    /// Exposed to the browser's explicit retry/refresh path without making cleanup foreground work.
    func retryArchiveCleanups(bridge: AgentBridge?) {
        retryPendingArchiveFinalizations(bridge: bridge)
        retryPendingArchiveCleanups(bridge: bridge)
    }

    /// A runtime can appear after the plugin browser already tried its durable cleanup queue.
    /// Resume both exact queued deletions and crash-orphan reconciliation on every readiness edge.
    func runtimeDidBecomeReady(bridge: AgentBridge) {
        retryPendingArchiveFinalizations(bridge: bridge)
        retryPendingArchiveCleanups(bridge: bridge)
        guard !archiveReconciliationInFlight else { return }
        archiveReconciliationInFlight = true
        bridge.claudePlugins([
            "action": "reconcileArchives",
            "background": true,
        ])
    }

    private func archiveInstalled(_ plugin: LocalPlugin) -> Installed? {
        guard let pluginID = plugin.catalogPluginID else { return nil }
        let catalog = available.first { $0.pluginId == pluginID }
        return Installed(
            pluginId: pluginID,
            version: plugin.version,
            scope: plugin.source == .managed ? "managed" : "user",
            enabled: plugin.enabled,
            mcpServers: catalog?.components?.mcpServers ?? [],
            components: catalog?.components,
            tokenCost: catalog?.tokenCost,
            installCount: catalog?.installCount,
            description: catalog?.description ?? "",
            category: catalog?.category,
            homepage: catalog?.homepage,
            authorName: catalog?.authorName,
            authorURL: catalog?.authorURL,
            marketplaceDisplayName: plugin.marketplaceName)
    }

    /// Pure normalization used by the async loader and regression tests. A signed source's authored
    /// name remains authoritative; a user-added unnamed source may adopt the registry's own name.
    static func decodeArchiveCatalog(
        source: MarketplaceSource,
        data: Data
    ) throws -> (marketplace: Marketplace, available: [Available]) {
        let manifest = try PluginMarketplaceAdapter.decode(data, source: source)
        let authoredName = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let manifestName = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableName = !authoredName.isEmpty ? authoredName
            : (!manifestName.isEmpty ? manifestName : source.displayName)
        let marketplace = Marketplace(
            name: stableName,
            source: "archive",
            repo: source.rawURL,
            installLocation: nil,
            isManaged: source.isManaged,
            networkScope: source.networkScope,
            archiveSourceID: source.id)
        var seen = Set<String>()
        let available = manifest.plugins.compactMap { plugin -> Available? in
            let pluginName = plugin.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isInstallerText(plugin.name, maximum: 256),
                  pluginName == plugin.name,
                  seen.insert(pluginName.lowercased()).inserted else {
                return nil
            }
            let components = Components(
                commands: plugin.commands ?? [],
                skills: plugin.skills ?? [],
                mcpServers: plugin.mcpServers ?? [])
            let versionIsValid = plugin.version.map {
                isInstallerText($0, maximum: 128)
            } ?? true
            let archive = versionIsValid
                ? archiveInstall(source: source, marketplaceName: stableName, plugin: plugin)
                : nil
            let unavailable: String?
            if plugin.archive?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                unavailable = "This registry entry does not declare a plugin archive."
            } else if !versionIsValid {
                unavailable = "This registry entry declares an invalid plugin version."
            } else if archive == nil {
                unavailable = "This registry entry has an invalid HTTPS archive URL or SHA-256 value."
            } else {
                unavailable = nil
            }
            return Available(
                pluginId: "\(pluginName)@archive-\(source.id.uuidString.lowercased())",
                name: pluginName,
                displayName: plugin.displayName,
                description: plugin.description ?? "",
                marketplaceName: stableName,
                category: plugin.category,
                homepage: plugin.homepage,
                authorName: plugin.author?.name ?? stableName,
                authorURL: nil,
                installCount: nil,
                sourceURL: plugin.source?.repoURL?.absoluteString,
                components: components.isEmpty ? nil : components,
                tokenCost: nil,
                archiveInstall: archive,
                canInstall: archive != nil,
                installUnavailableReason: unavailable,
                isManaged: source.isManaged)
        }
        return (marketplace, available)
    }

    /// Backward-compatible name retained for callers/tests written when archive catalogs were
    /// managed-only.
    static func decodeManagedCatalog(
        source: MarketplaceSource,
        data: Data
    ) throws -> (marketplace: Marketplace, available: [Available]) {
        try decodeArchiveCatalog(source: source, data: data)
    }

    private static func archiveInstall(
        source: MarketplaceSource,
        marketplaceName: String,
        plugin: PluginMarketplaceManifest.PluginEntry
    ) -> ArchiveInstall? {
        guard let catalogURL = URL(string: source.rawURL),
              catalogURL.scheme?.lowercased() == "https",
              catalogURL.host != nil,
              catalogURL.user == nil, catalogURL.password == nil,
              catalogURL.fragment == nil,
              let rawArchive = plugin.archive?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawArchive.isEmpty,
              let archiveURL = URL(string: rawArchive, relativeTo: catalogURL)?.absoluteURL,
              archiveURL.scheme?.lowercased() == "https",
              archiveURL.host != nil,
              archiveURL.user == nil, archiveURL.password == nil,
              archiveURL.fragment == nil else { return nil }
        let expectedSHA256: String?
        if let raw = plugin.sha256?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let normalized = raw.lowercased().replacingOccurrences(of: "sha256:", with: "")
            guard normalized.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
            else { return nil }
            expectedSHA256 = normalized
        } else {
            expectedSHA256 = nil
        }
        return ArchiveInstall(
            sourceID: source.id,
            sourceName: marketplaceName,
            catalogURL: catalogURL.absoluteString,
            archiveURL: archiveURL.absoluteString,
            expectedSHA256: expectedSHA256,
            version: plugin.version,
            authentication: source.authentication,
            networkScope: source.networkScope,
            isManaged: source.isManaged)
    }

    private static func isInstallerText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf16.count <= maximum
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func isArchiveLeaseToken(_ value: String) -> Bool {
        guard value.utf8.count == 36, UUID(uuidString: value) != nil else { return false }
        let lowercased = value.lowercased()
        let characters = Array(lowercased.utf8)
        return characters[14] == UInt8(ascii: "4")
            && [UInt8(ascii: "8"), UInt8(ascii: "9"),
                UInt8(ascii: "a"), UInt8(ascii: "b")].contains(characters[19])
    }

    private static func archiveMarketplacePlaceholder(_ source: MarketplaceSource) -> Marketplace {
        Marketplace(
            name: source.displayName,
            source: "archive",
            repo: source.rawURL,
            installLocation: nil,
            isManaged: source.isManaged,
            networkScope: source.networkScope,
            archiveSourceID: source.id)
    }

    private static func verifyCatalogDigest(_ data: Data, expected rawExpected: String?) throws {
        guard let rawExpected, !rawExpected.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        let expected = rawExpected.lowercased()
            .replacingOccurrences(of: "sha256:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard expected.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw BrowseFetcher.BrowseError(
                kind: .configuration,
                message: "The managed catalog has an invalid SHA-256 pin.")
        }
        let actual = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actual == expected else {
            throw BrowseFetcher.BrowseError(
                kind: .invalidResponse,
                message: "The managed catalog did not match its signed SHA-256 pin.")
        }
    }

    private func replaceArchiveMarketplace(_ sourceID: UUID, with marketplace: Marketplace) {
        if let index = archiveMarketplaces.firstIndex(where: { $0.archiveSourceID == sourceID }) {
            archiveMarketplaces[index] = marketplace
        } else {
            archiveMarketplaces.append(marketplace)
        }
    }

    private func publishCombinedCatalog() {
        // IDs carry source provenance, so same-named native and archive marketplaces can coexist.
        // A user-added archive must never be able to hide a provider-owned marketplace.
        marketplaces = archiveMarketplaces + providerMarketplaces
        available = archiveAvailable + providerAvailable
    }

    func isInstalled(_ pluginId: String) -> Bool {
        installed.contains { $0.pluginId == pluginId }
    }

    /// What a plugin CONTAINS, as a filter. The analogue of the MCP browser's Remote/Local facet,
    /// and drawn from the same place — real data, not invented taxonomy. "Show me the plugins that
    /// add MCP servers" is a question the component inventory can actually answer, and it is a
    /// different question from "show me the productivity ones".
    enum Contains: String, CaseIterable, Identifiable {
        case any, skills, commands, agents, mcpServers, hooks
        var id: String { rawValue }
        var label: String {
            switch self {
            case .any: return "All"
            case .skills: return "Skills"
            case .commands: return "Commands"
            case .agents: return "Agents"
            case .mcpServers: return "MCP servers"
            case .hooks: return "Hooks"
            }
        }
        var help: String {
            switch self {
            case .any: return "Every plugin this marketplace offers"
            case .skills: return "Plugins that add skills you can arm from the inspector"
            case .commands: return "Plugins that add slash commands"
            case .agents: return "Plugins that add subagents"
            case .mcpServers: return "Plugins that wire up MCP servers"
            case .hooks: return "Plugins that run on session events"
            }
        }
        func matches(_ components: Components?) -> Bool {
            guard self != .any else { return true }
            guard let components else { return false }
            switch self {
            case .any: return true
            case .skills: return !components.skills.isEmpty
            case .commands: return !components.commands.isEmpty
            case .agents: return !components.agents.isEmpty
            case .mcpServers: return !components.mcpServers.isEmpty
            case .hooks: return !components.hooks.isEmpty
            }
        }
    }

    /// How many plugins in a marketplace carry each kind of component. A facet chip that would
    /// return nothing should not be offered, and the count says whether it is worth clicking.
    private func belongs(_ plugin: Available, to marketplace: Marketplace) -> Bool {
        if let sourceID = marketplace.archiveSourceID {
            return plugin.archiveInstall?.sourceID == sourceID
        }
        return plugin.archiveInstall == nil && plugin.marketplaceName == marketplace.name
    }

    func containsCounts(in marketplace: Marketplace) -> [Contains: Int] {
        var counts: [Contains: Int] = [:]
        let all = available.filter { belongs($0, to: marketplace) }
        for facet in Contains.allCases {
            counts[facet] = facet == .any ? all.count
                                          : all.filter { facet.matches($0.components) }.count
        }
        return counts
    }

    func plugins(in marketplace: Marketplace, matching query: String = "",
                 category: String? = nil, contains: Contains = .any) -> [Available] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return available
            .filter { belongs($0, to: marketplace) }
            .filter { category == nil || $0.category == category }
            .filter { contains.matches($0.components) }
            .filter { plugin in
                guard !needle.isEmpty else { return true }
                return plugin.title.lowercased().contains(needle)
                    || plugin.description.lowercased().contains(needle)
                    || (plugin.category?.lowercased().contains(needle) ?? false)
                    || (plugin.authorName?.lowercased().contains(needle) ?? false)
            }
            // Most-installed first. A flat 272-item alphabetical grid tells you nothing about which
            // of two similar plugins the ecosystem actually uses; 404,331 installs does.
            .sorted {
                if ($0.installCount ?? -1) != ($1.installCount ?? -1) {
                    return ($0.installCount ?? -1) > ($1.installCount ?? -1)
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    /// The categories a marketplace uses, most-populated first. Category is the taxonomy Anthropic's
    /// data actually has (95% of entries, 14 values); `keywords` covers 1 entry in 273 and `tags` 3,
    /// so neither is a browse axis.
    func categories(in marketplace: Marketplace) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for plugin in available where belongs(plugin, to: marketplace) {
            guard let category = plugin.category, !category.isEmpty else { continue }
            counts[category, default: 0] += 1
        }
        return counts
            .map { (name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }
}
