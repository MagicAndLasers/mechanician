import Foundation
import Combine

/// Codex plugin marketplaces, in OpenAI's own vocabulary.
///
/// Deliberately a sibling of `ClaudePluginStore` rather than a shared abstraction over both. They
/// agree on nouns — marketplace, plugin, `plugin@marketplace` — but their payloads genuinely
/// differ: Codex carries logos, categories and install policies that Anthropic's four-field browse
/// feed does not. A common supertype would either lose that or force empty fields on the Claude
/// side, and pretending two catalogs are the same is what produced the mess this replaces.
@MainActor
final class CodexPluginStore: ObservableObject {
    static let shared = CodexPluginStore()

    struct Marketplace: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let path: String?
        /// A remote catalog has no local path — which changes what Refresh and Remove can mean.
        let remote: Bool
        /// Registered by Mechanician because it ships on this Mac, not added by the user. Removing
        /// one is meaningless: the next launch registers it again.
        let bundled: Bool
        let count: Int
        var detail: String {
            if remote { return "Remote catalog" }
            return bundled ? "Ships with ChatGPT" : (path ?? "Local")
        }
        /// Only a marketplace the user chose is theirs to remove.
        var removable: Bool { !remote && !bundled }
    }

    struct Plugin: Identifiable, Equatable {
        enum InstallationDecision: Equatable {
            case install
            case reviewDetails
            case unavailable
        }

        var id: String { pluginId }
        let pluginId: String          // `plugin@marketplace`
        let name: String
        let description: String
        let marketplaceName: String
        let installed: Bool
        let enabled: Bool
        let version: String?
        let category: String?
        let developerName: String?
        let logoUrl: String?
        let availability: String
        let installPolicy: String
        /// Local plugins have no remote interstitial policy. Remote plugins must carry an explicit
        /// true/false decision; nil means Codex could not verify policy and installation fails closed.
        let remote: Bool
        let mustShowInstallationInterstitial: Bool?
        /// Everything a card cannot show and a decision needs. `websiteUrl` in particular was
        /// already crossing the bridge and being dropped for want of a property to land in.
        let longDescription: String?
        let websiteUrl: String?
        let privacyPolicyUrl: String?
        let termsOfServiceUrl: String?
        let screenshotUrls: [String]
        let defaultPrompt: [String]
        let capabilities: [String]

        /// Codex gates some entries. A card must not offer Install on something policy will refuse.
        var installationDecision: InstallationDecision {
            guard availability == "AVAILABLE",
                  ["AVAILABLE", "INSTALLED_BY_DEFAULT"].contains(installPolicy)
            else {
                return .unavailable
            }
            guard remote else { return .install }
            switch mustShowInstallationInterstitial {
            case true: return .reviewDetails
            case false: return .install
            case nil: return .unavailable
            }
        }

        var installable: Bool { installationDecision != .unavailable }

        var installationUnavailableReason: String {
            if availability != "AVAILABLE"
                || !["AVAILABLE", "INSTALLED_BY_DEFAULT"].contains(installPolicy)
            {
                return "Codex does not allow this plugin to be installed under the current account or policy."
            }
            if remote && mustShowInstallationInterstitial == nil {
                return "Codex could not verify this remote plugin's installation policy. Try again later."
            }
            return "This plugin is not available to install."
        }
    }

    @Published private(set) var marketplaces: [Marketplace] = []
    @Published private(set) var plugins: [Plugin] = []
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?
    @Published private(set) var busyPluginID: String?

    private var loadedOnce = false

    func loadIfNeeded(bridge: AgentBridge?) {
        guard !loadedOnce else { return }
        loadedOnce = true
        refresh(bridge: bridge)
    }

    func refresh(bridge: AgentBridge?) { send(["action": "list"], bridge: bridge) }

    func install(
        _ pluginId: String,
        installationInterstitialAccepted: Bool = false,
        bridge: AgentBridge?
    ) {
        busyPluginID = pluginId
        send([
            "action": "install",
            "pluginId": pluginId,
            "installationInterstitialAccepted": installationInterstitialAccepted,
        ], bridge: bridge)
    }

    func uninstall(_ pluginId: String, bridge: AgentBridge?) {
        busyPluginID = pluginId
        send(["action": "uninstall", "pluginId": pluginId], bridge: bridge)
    }

    func addMarketplace(_ source: String, bridge: AgentBridge?) {
        send(["action": "addMarketplace", "source": source], bridge: bridge)
    }

    func removeMarketplace(_ name: String, bridge: AgentBridge?) {
        send(["action": "removeMarketplace", "name": name], bridge: bridge)
    }

    func upgradeMarketplace(_ name: String, bridge: AgentBridge?) {
        send(["action": "upgradeMarketplace", "name": name], bridge: bridge)
    }

    private func send(_ request: [String: Any], bridge: AgentBridge?) {
        guard let bridge else {
            lastError = "No runtime is ready yet. Open a conversation and try again."
            return
        }
        isWorking = true
        lastError = nil
        bridge.codexPlugins(request)
    }

    func apply(_ event: [String: Any]) {
        isWorking = false
        busyPluginID = nil
        guard event["ok"] as? Bool == true else {
            lastError = event["message"] as? String ?? "The plugin command failed."
            return
        }
        lastError = nil
        marketplaces = (event["marketplaces"] as? [[String: Any]] ?? []).compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return Marketplace(name: name,
                               path: row["path"] as? String,
                               remote: row["remote"] as? Bool ?? false,
                               bundled: row["bundled"] as? Bool ?? false,
                               count: row["count"] as? Int ?? 0)
        }
        let remoteMarketplaceNames = Set(
            marketplaces.lazy.filter(\.remote).map(\.name)
        )
        plugins = (event["plugins"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["pluginId"] as? String else { return nil }
            return Plugin(pluginId: id,
                          name: row["name"] as? String ?? id,
                          description: row["description"] as? String ?? "",
                          marketplaceName: row["marketplaceName"] as? String ?? "",
                          installed: row["installed"] as? Bool ?? false,
                          enabled: row["enabled"] as? Bool ?? true,
                          version: row["version"] as? String,
                          category: row["category"] as? String,
                          developerName: row["developerName"] as? String,
                          logoUrl: row["logoUrl"] as? String,
                          availability: row["availability"] as? String ?? "AVAILABLE",
                          installPolicy: row["installPolicy"] as? String ?? "AVAILABLE",
                          remote: row["remote"] as? Bool
                              ?? remoteMarketplaceNames.contains(
                                  row["marketplaceName"] as? String ?? ""),
                          mustShowInstallationInterstitial:
                              row["mustShowInstallationInterstitial"] as? Bool,
                          longDescription: row["longDescription"] as? String,
                          websiteUrl: row["websiteUrl"] as? String,
                          privacyPolicyUrl: row["privacyPolicyUrl"] as? String,
                          termsOfServiceUrl: row["termsOfServiceUrl"] as? String,
                          screenshotUrls: row["screenshotUrls"] as? [String] ?? [],
                          defaultPrompt: row["defaultPrompt"] as? [String] ?? [],
                          capabilities: row["capabilities"] as? [String] ?? [])
        }
    }

    var installed: [Plugin] {
        plugins.filter(\.installed)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// One marketplace's offerings, filtered by a search term and optionally a category. The remote
    /// catalog has 2,216 entries, so filtering is not a nicety here — it is the only way to use the
    /// tab at all.
    func plugins(inMarketplace name: String, matching query: String,
                 category: String? = nil) -> [Plugin] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return plugins
            .filter { $0.marketplaceName == name }
            .filter { category == nil || $0.category == category }
            .filter { plugin in
                guard !needle.isEmpty else { return true }
                return plugin.name.lowercased().contains(needle)
                    || plugin.description.lowercased().contains(needle)
                    || (plugin.longDescription?.lowercased().contains(needle) ?? false)
                    || (plugin.developerName?.lowercased().contains(needle) ?? false)
                    || (plugin.category?.lowercased().contains(needle) ?? false)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The categories a marketplace actually uses, most-populated first, each with its count.
    ///
    /// Category is the taxonomy that exists: ~100% of the remote catalog carries one, across 13
    /// clean values. Keywords are not — only 3.5% of plugins have any, and 454 of the 550 distinct
    /// keywords occur exactly once, so a tag UI would be an empty affordance on 97% of cards.
    func categories(inMarketplace name: String) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for plugin in plugins where plugin.marketplaceName == name {
            guard let category = plugin.category, !category.isEmpty else { continue }
            counts[category, default: 0] += 1
        }
        return counts
            .map { (name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }
}
