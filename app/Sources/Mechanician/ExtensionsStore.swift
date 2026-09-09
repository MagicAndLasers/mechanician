import Foundation
import Combine
import CryptoKit

/// Some catalogs publish a service's HOST ROOT while its MCP endpoint actually lives at a fixed
/// path beneath it, so an entry has to be completed before it can be connected to.
///
/// Which hosts, and which path, is one organization's fact — not the app's. It arrives in the
/// signed tenant profile as a `RegistryEndpointRule`, so supporting another catalog is a profile
/// change rather than an app release. With no rule, nothing is rewritten: guessing paths for
/// arbitrary public MCP servers is exactly the behavior this must not have.
enum MCPEndpointNormalizer {
    static func normalized(
        _ rawValue: String,
        rule: TenantProfile.RegistryEndpointRule?
    ) -> String {
        guard let rule, !rule.hostSuffix.isEmpty, !rule.path.isEmpty else { return rawValue }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              host.hasSuffix(rule.hostSuffix.lowercased()),
              components.path.isEmpty || components.path == "/"
        else { return rawValue }
        components.path = rule.path.hasPrefix("/") ? rule.path : "/" + rule.path
        return components.url?.absoluteString ?? rawValue
    }

    static func migrateInstalledServers(
        _ servers: [MCPServer],
        rule: TenantProfile.RegistryEndpointRule?
    ) -> [MCPServer] {
        guard rule != nil else { return servers }
        return servers.map { original in
            guard original.isRemote else { return original }
            var server = original
            server.url = normalized(server.url, rule: rule)
            return server
        }
    }
}

/// User-configured EXTENSIONS — external MCP servers + local plugins — persisted to
/// `<support>/extensions.json` (honoring `MECHANICIAN_SUPPORT_DIR`, so the dev build stays isolated).
/// agentd reads the SAME file per turn and folds the enabled entries into the SDK options
/// (`options.mcpServers` / `options.plugins`). Claude fixes that tool schema when a provider session
/// is created, so a durable config revision is also bound to the session that mounted it; a changed
/// revision starts a fresh provider session on the next message and replays app history. This store
/// remains the app-side source of truth for the Connections window.
@MainActor final class ExtensionsStore: ObservableObject {
    static let shared = ExtensionsStore()

    /// Managed catalogs are synthesized from the signed tenant profile and never written into the
    /// user's `extensions.json`. Keeping the two layers separate makes "managed" a provenance fact
    /// the user sidecar cannot forge, while still letting public/user sources remain fully editable.
    private let tenantExtensionPolicy: TenantProfile.ExtensionPolicy
    private let managedRegistrySources: [RegistrySource]
    private let managedMarketplaceSources: [MarketplaceSource]

    @Published var mcpServers: [MCPServer] = []
    @Published var plugins: [LocalPlugin] = []
    /// Verified archive versions that are no longer mounted but still need deletion. Keeping this
    /// in the same atomic sidecar as `plugins` closes the crash window between unmount and cleanup.
    @Published private(set) var pendingArchiveCleanups: [ArchivePluginCleanup] = []
    /// Materialized archive versions whose lease still needs acknowledgement after their mount was
    /// durably committed. Persisting the exact identity and token with `plugins` closes the inverse
    /// crash window: relaunch can finish the acknowledgement instead of waiting for lease expiry.
    @Published private(set) var pendingArchiveFinalizations: [PendingArchiveFinalization] = []
    /// A failed Keychain or disk transaction leaves the previous file untouched. Surface the error
    /// instead of silently persisting a credential back into world-readable JSON.
    @Published private(set) var persistenceError: String?
    /// Durable, non-secret generation for the external-tool configuration written to disk. It lets
    /// conversations reject an opaque Claude session initialized before a server/plugin/auth change.
    private(set) var providerConfigurationRevision = UUID()
    /// Route-scoped credential generation survives after an attempt/claim is consumed. Unlike the
    /// configured-server revision, it exists even for provider-owned connectors, so a crash can
    /// never make an old nil-stamped opaque session look current again.
    private var mcpCredentialRevisionByAccess: [String: UUID] = [:]
    /// Servers whose provider credential changed but whose real fresh query has not yet reported a
    /// terminal inventory. Persist by provider route so another window—or a relaunch—cannot start a
    /// deferred, tool-less session while the OAuth-owning daemon's memory is gone.
    private var pendingMCPReadiness = MCPPendingReadinessLedger()
    /// Non-secret write-ahead intents committed before a daemon may touch MCP credentials.
    private var pendingMCPAuthorizations = MCPPendingAuthorizationLedger()

    /// Legacy discovery sources retained in the persisted schema so the Connections migration does
    /// not discard user configuration. They are no longer presented in the primary UI.
    @Published var registrySources: [RegistrySource] = []
    @Published var marketplaceSources: [MarketplaceSource] = []

    /// Browse preference: show only VERIFIED / first-party servers (DNS-verified reverse-DNS namespace,
    /// e.g. `com.stripe/*`, `io.github.microsoft/*`). Structural trust, not a hardcoded brand list.
    @Published var mcpVerifiedOnly = false
    /// One-time flag so the PulseMCP enrichment source is added to existing installs exactly once
    /// (and never re-added after a user deletes it). Retained only so the retirement below can read
    /// the persisted schema; nothing seeds PulseMCP any more.
    private var seededPulseMCP = false
    /// One-time flag for the retirement of the open registry + PulseMCP defaults.
    private var retiredLegacyRegistries = false

    /// Sources retired as defaults, removed once from installs that were seeded with them.
    ///
    /// **`registry.modelcontextprotocol.io`** — 18,522 servers, run by the Linux Foundation (not
    /// Anthropic; its Registry maintainers are from PulseMCP, Stacklok and TeamSpark). Its own
    /// moderation policy says to assume minimal-to-no moderation, and its docs state it is "not
    /// intended to be directly consumed by host applications" — host apps should consume a
    /// downstream marketplace instead. That is exactly what the two defaults below are.
    ///
    /// **PulseMCP** — a private company, 22,264 servers with AI-generated descriptions and no
    /// vetting statement anywhere. It was seeded here as a stars-and-downloads "enrichment" source,
    /// which is a fair description of what it adds and a poor one of what it also brings with it.
    static let retiredRegistryURLs: Set<String> = [
        "https://registry.modelcontextprotocol.io/v0.1/servers",
        "https://registry.modelcontextprotocol.io/v0/servers",
        "https://api.pulsemcp.com/v0beta/servers",
    ]

    /// The registries Mechanician ships enabled: **vendor-operated and curated, or not at all.**
    ///
    /// Both are Microsoft's, both are unauthenticated, and both conform to the official MCP registry
    /// schema — so the existing `.officialV01` adapter decodes them with no new code. Between them
    /// they list 251 reviewed servers, against 18,522 unreviewed ones in the open registry.
    ///
    /// Checked and rejected: Anthropic's Connectors Directory is real and human-reviewed but has no
    /// public feed (every endpoint 403s behind Cloudflare, and its plugin marketplaces populate
    /// `mcpServers` on 2 of 2,269 entries). OpenAI operates no registry. Google's closest equivalent
    /// is a star-ranked GitHub crawl with no trust, verification or review field anywhere in it.
    ///
    /// Docker's catalog is the other genuinely curated option — 317 servers, digest-pinned, signed,
    /// with SBOMs — and is the strongest provenance story of the three. It uses its own schema
    /// rather than the MCP one, so adopting it needs an adapter (FR-114).
    static let defaultRegistries = [
        RegistrySource(name: "Microsoft Azure MCP Registry",
                       url: "https://registry.mcp.azure.com/v0/servers"),
        RegistrySource(name: "GitHub MCP Registry",
                       url: "https://api.mcp.github.com/v0.1/servers"),
    ]
    static let defaultMarketplaces = [
        MarketplaceSource(name: "Anthropic Official", repo: "anthropics/claude-plugins-official"),
        MarketplaceSource(name: "Knowledge Work", repo: "anthropics/knowledge-work-plugins"),
    ]

    /// MCP OAuth records and connector status belong to the exact provider/profile route. App-owned
    /// records are scoped that way in Keychain; foreign claude.ai connectors remain SDK-owned. A
    /// single name-keyed projection would therefore show one route's state while another is active.
    private struct MCPTransientState {
        var authState: [String: MCPAuthState] = [:]
        var authURL: [String: String] = [:]
        var connState: [String: MCPConnState] = [:]
        var foreignServers: [String] = []
        var lastStatusCheck: Date?
        var didAutoCheckStatus = false
    }
    @Published private var mcpTransientByAccess: [ModelAccess: MCPTransientState] = [:]

    func setAuthState(_ name: String, _ state: MCPAuthState, for access: ModelAccess) {
        // Cancellation is a terminal outcome, but not a failed authorization. Normalize it at the
        // store boundary so every caller (including older bridges) gets the same behavior without
        // inspecting provider-controlled English prose for words such as "cancel". The pending
        // browser URL is part of that same lane-scoped attempt and must disappear with it.
        var transient = mcpTransientByAccess[access] ?? MCPTransientState()
        let normalized: MCPAuthState
        if case .failed(let failure) = state, failure.isCancellation {
            normalized = .idle
            transient.authURL[name] = nil
        } else {
            normalized = state
        }
        transient.authState[name] = normalized
        mcpTransientByAccess[access] = transient
    }
    func authState(for name: String, access: ModelAccess) -> MCPAuthState {
        mcpTransientByAccess[access]?.authState[name] ?? .idle
    }
    func authStates(for access: ModelAccess) -> [String: MCPAuthState] {
        mcpTransientByAccess[access]?.authState ?? [:]
    }
    func setAuthURL(_ url: String?, for name: String, access: ModelAccess) {
        mcpTransientByAccess[access, default: MCPTransientState()].authURL[name] = url
    }
    func authURL(for name: String, access: ModelAccess) -> String? {
        mcpTransientByAccess[access]?.authURL[name]
    }
    func setConnState(_ name: String, _ state: MCPConnState, for access: ModelAccess) {
        mcpTransientByAccess[access, default: MCPTransientState()].connState[name] = state
    }
    func connState(for name: String, access: ModelAccess) -> MCPConnState {
        mcpTransientByAccess[access]?.connState[name] ?? .unknown
    }
    /// Servers the user has to act on in ONE lane: a remote awaiting sign-in, or one that failed to
    /// start. A blocked MCP server is otherwise invisible until a turn quietly lacks its tools, so
    /// the toolbar reads this to surface it.
    ///
    /// Scoped to a lane on purpose. Connection state is keyed by `ModelAccess`, the Extensions panel
    /// works one lane at a time, and a warning about a lane you aren't using is one you can neither
    /// explain nor act on from here.
    func mcpServersNeedingAttention(for access: ModelAccess) -> [String] {
        guard let state = mcpTransientByAccess[access] else { return [] }
        return state.connState.compactMap { name, conn in
            switch conn {
            case .needsAuth, .failed: name
            default: nil
            }
        }.sorted()
    }

    func foreignServers(for access: ModelAccess) -> [String] {
        mcpTransientByAccess[access]?.foreignServers ?? []
    }
    func setForeignServers(_ names: [String], for access: ModelAccess) {
        mcpTransientByAccess[access, default: MCPTransientState()].foreignServers = names
    }
    func lastStatusCheck(for access: ModelAccess) -> Date? {
        mcpTransientByAccess[access]?.lastStatusCheck
    }
    func setLastStatusCheck(_ date: Date?, for access: ModelAccess) {
        mcpTransientByAccess[access, default: MCPTransientState()].lastStatusCheck = date
    }
    func didAutoCheckStatus(for access: ModelAccess) -> Bool {
        mcpTransientByAccess[access]?.didAutoCheckStatus ?? false
    }
    func setDidAutoCheckStatus(_ checked: Bool, for access: ModelAccess) {
        mcpTransientByAccess[access, default: MCPTransientState()].didAutoCheckStatus = checked
    }
    /// A local server edit invalidates only that configured server's observations. claude.ai
    /// connectors are discovered independently and may have a browser authorization in flight, so
    /// never erase their rows merely because extensions.json changed.
    func invalidateConfiguredMCPStatus(_ names: Set<String>) {
        guard !names.isEmpty else { return }
        for access in Array(mcpTransientByAccess.keys) {
            for name in names {
                mcpTransientByAccess[access]?.connState[name] = nil
                let auth = mcpTransientByAccess[access]?.authState[name] ?? .idle
                if !auth.isInProgress {
                    mcpTransientByAccess[access]?.authState[name] = nil
                    mcpTransientByAccess[access]?.authURL[name] = nil
                }
            }
            mcpTransientByAccess[access]?.lastStatusCheck = nil
            mcpTransientByAccess[access]?.didAutoCheckStatus = false
        }
    }
    func resetMCPTransientState(for access: ModelAccess) {
        mcpTransientByAccess[access] = nil
    }

    private init() {
        tenantExtensionPolicy = TenantProfile.current.extensions
        managedRegistrySources = Self.makeManagedRegistrySources(from: TenantProfile.current)
        managedMarketplaceSources = Self.makeManagedMarketplaceSources(from: TenantProfile.current)
        load()
    }

    /// Managed sources always lead the merge. Registry entries are subsequently merged by server
    /// identity, so a public/user registry cannot shadow a same-named managed entry.
    var effectiveRegistrySources: [RegistrySource] {
        Self.mergeSources(managed: managedRegistrySources,
                          user: userDiscoveryAllowed ? registrySources : [],
                          key: { $0.url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }

    var effectiveMarketplaceSources: [MarketplaceSource] {
        Self.mergeSources(managed: managedMarketplaceSources,
                          user: userDiscoveryAllowed ? marketplaceSources : [],
                          key: { $0.rawURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }

    var hasManagedDiscovery: Bool {
        !managedRegistrySources.isEmpty || !managedMarketplaceSources.isEmpty
    }

    private var userDiscoveryAllowed: Bool {
        tenantExtensionPolicy.allowPublic
            && (ManagedEnterprisePolicy.current?.allowPublicExtensionDiscovery ?? true)
            && (ManagedEnterprisePolicy.current?.allowUserConfiguredExtensions ?? true)
    }

    private static func mergeSources<T>(managed: [T], user: [T], key: (T) -> String) -> [T] {
        var seen = Set<String>()
        return (managed + user).filter { seen.insert(key($0)).inserted }
    }

    /// Convert only known declarative source kinds/formats. Unsupported entries are ignored rather
    /// than guessed; a tenant profile may select parsers, never executable behavior.
    static func makeManagedRegistrySources(from profile: TenantProfile) -> [RegistrySource] {
        var seen = Set<UUID>()
        return profile.extensions.managedSources.compactMap { source in
            guard source.kind == "registry", let url = source.url,
                  url.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("https://"),
                  let format = RegistryFormat(rawValue: source.format ?? RegistryFormat.officialV01.rawValue)
            else { return nil }
            let id = deterministicSourceID(profile: profile, source: source)
            let candidate = RegistrySource(
                id: id,
                name: source.name,
                url: url,
                enabled: true,
                format: format,
                source: .managed,
                networkScope: ExtensionNetworkScope(rawValue: source.networkScope ?? "public"),
                authentication: ExtensionSourceAuthentication(rawValue: source.authentication ?? ""),
                sha256: source.sha256,
                governance: source.governance)
            guard candidate.isValid, seen.insert(id).inserted else { return nil }
            return candidate
        }
    }

    static func makeManagedMarketplaceSources(from profile: TenantProfile) -> [MarketplaceSource] {
        var seen = Set<UUID>()
        return profile.extensions.managedSources.compactMap { source in
            guard source.kind == "marketplace",
                  let format = MarketplaceFormat(rawValue: source.format ?? MarketplaceFormat.claudeMarketplace.rawValue),
                  let location = source.url ?? source.repo,
                  !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (!location.contains("://") || location.hasPrefix("https://")),
                  (format != .archiveRegistryV1 || source.url?.hasPrefix("https://") == true)
            else { return nil }
            let id = deterministicSourceID(profile: profile, source: source)
            let candidate = MarketplaceSource(
                id: id,
                name: source.name,
                repo: location,
                enabled: true,
                format: format,
                source: .managed,
                networkScope: ExtensionNetworkScope(rawValue: source.networkScope ?? "public"),
                authentication: ExtensionSourceAuthentication(rawValue: source.authentication ?? ""),
                sha256: source.sha256)
            guard candidate.isValid, seen.insert(id).inserted else { return nil }
            return candidate
        }
    }

    private static func deterministicSourceID(
        profile: TenantProfile, source: TenantProfile.ManagedSource
    ) -> UUID {
        // The endpoint is delivery configuration, not source identity. A signed profile may rotate
        // a catalog host without turning every installed plugin into an orphaned catalog entry.
        let material = [profile.tenantId, source.kind, source.name]
            .joined(separator: "\u{0}")
        var bytes = Array(SHA256.hash(data: Data(material.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50 // UUID v5-shaped stable identifier
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: Persistence

    private var appSupportBase: URL {
        let base = MechanicianEnvironment.currentSupportRoot()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private var fileURL: URL { appSupportBase.appendingPathComponent("extensions.json") }
    private let secretVault: any MCPSecretVault = SystemMCPSecretVault()
    /// Retain failed post-commit deletions for an in-session retry. A Keychain failure never rolls
    /// back the already-durable config, but it also must not be silently treated as cleanup success.
    private var pendingSecretCleanup = Set<String>()

    // registrySources/marketplaceSources are OPTIONAL so an absent key (first run / older file) seeds
    // the public defaults, while an explicitly-empty array (the user removed them all) is respected.
    private struct Payload: Codable {
        var mcpServers: [MCPServer] = []
        var plugins: [LocalPlugin] = []
        var pendingArchiveCleanups: [ArchivePluginCleanup]? = nil
        var pendingArchiveFinalizations: [PendingArchiveFinalization]? = nil
        var registrySources: [RegistrySource]? = nil
        var marketplaceSources: [MarketplaceSource]? = nil
        var mcpVerifiedOnly: Bool? = nil
        var seededPulseMCP: Bool? = nil
        var retiredLegacyRegistries: Bool? = nil
        var providerConfigurationRevision: UUID? = nil
        var mcpCredentialRevisionByAccess: [String: UUID]? = nil
        var pendingMCPReadiness: MCPPendingReadinessLedger? = nil
        var pendingMCPAuthorizations: MCPPendingAuthorizationLedger? = nil
    }

    /// `nil` is the canonical no-external-tools configuration. Users without enabled connections
    /// keep their existing sessions, while an older sidecar with an enabled connection safely gets
    /// one fresh Claude session after this field is introduced.
    func providerSessionConfigurationRevision(for access: ModelAccess) -> UUID? {
        if let policy = ManagedEnterprisePolicy.current,
           !policy.allowUserConfiguredExtensions {
            let servers = TenantProfile.current.extensions.managedServers
            let encoded = (try? JSONEncoder().encode(servers)) ?? Data()
            let material = Data(policy.runtimeIdentity.utf8) + Data([0]) + encoded
            var bytes = Array(SHA256.hash(data: material).prefix(16))
            bytes[6] = (bytes[6] & 0x0f) | 0x50
            bytes[8] = (bytes[8] & 0x3f) | 0x80
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]))
        }
        let hasServer = mcpServers.contains { $0.enabled && $0.isValid }
        let hasPlugin = plugins.contains { $0.enabled && $0.isValid }
        let configured = hasServer || hasPlugin ? providerConfigurationRevision : nil
        let credential = mcpCredentialRevisionByAccess[access.rawValue]
        guard configured != nil || credential != nil else { return nil }
        let material = [
            "mechanician-mcp-route-revision-v1",
            configured?.uuidString.lowercased() ?? "no-configured-extensions",
            credential?.uuidString.lowercased() ?? "no-route-credential-change",
        ].joined(separator: "\0")
        var bytes = Array(SHA256.hash(data: Data(material.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func load() {
        // Older releases used the default umask, normally 0644. Tighten the legacy file before even
        // decoding it so a failed credential migration does not leave its plaintext broadly readable.
        PrivateAtomicFile.enforcePrivatePermissions(at: fileURL)
        let data = try? Data(contentsOf: fileURL)
        guard let data, let p = try? JSONDecoder().decode(Payload.self, from: data) else {
            // Distinguish first run (no file) from a corrupt file. A corrupt file previously fell
            // through to defaults with empty mcpServers/plugins — the user's whole extension config
            // appeared wiped, and their next edit's save() overwrote the corrupt bytes, making the
            // loss permanent. Preserve the file aside first so it's recoverable, THEN seed defaults.
            if let data, !data.isEmpty { quarantineCorruptFile() }
            registrySources = Self.defaultRegistries; marketplaceSources = Self.defaultMarketplaces
            seededPulseMCP = true; return   // new install: vendor-curated defaults only
        }
        let hydration = MCPSecretPersistence.hydrate(p.mcpServers, vault: secretVault)
        providerConfigurationRevision = p.providerConfigurationRevision ?? UUID()
        mcpCredentialRevisionByAccess = p.mcpCredentialRevisionByAccess ?? [:]
        pendingMCPReadiness = p.pendingMCPReadiness ?? MCPPendingReadinessLedger()
        pendingMCPAuthorizations = p.pendingMCPAuthorizations
            ?? MCPPendingAuthorizationLedger()
        mcpServers = MCPEndpointNormalizer.migrateInstalledServers(
            hydration.servers,
            rule: TenantProfile.current.registryEndpointRule)
        var migratedLegacyReadiness = false
        for access in ModelAccess.allCases {
            migratedLegacyReadiness = pendingMCPReadiness.normalizeLegacyClaims(
                for: access,
                accountInstanceID: ProviderAccountStore.shared
                    .accountInstanceID(for: access).rawValue,
                routeIdentity: AgentBridge.mcpRouteIdentity(
                    for: access, profile: TenantProfile.current),
                configuredServerID: { name in
                    mcpServers.first { $0.name == name }?.id
                }) || migratedLegacyReadiness
        }
        let endpointMigrationNeeded = mcpServers != hydration.servers
        persistenceError = hydration.warnings.isEmpty ? nil : hydration.warnings.joined(separator: " ")
        plugins = p.plugins
        pendingArchiveCleanups = (p.pendingArchiveCleanups ?? []).filter(\.isValid)
        pendingArchiveFinalizations = (p.pendingArchiveFinalizations ?? []).filter(\.isValid)
        // Anything decoded from the user-writable sidecar is user-owned regardless of a forged
        // `source` field. Only the signed profile can synthesize a managed source.
        registrySources = (p.registrySources ?? Self.defaultRegistries).map {
            var source = $0; source.source = .user; source.authentication = nil; return source
        }
        marketplaceSources = (p.marketplaceSources ?? Self.defaultMarketplaces).map {
            var source = $0; source.source = .user; source.authentication = nil; return source
        }
        mcpVerifiedOnly = p.mcpVerifiedOnly ?? false
        seededPulseMCP = p.seededPulseMCP ?? false
        retiredLegacyRegistries = p.retiredLegacyRegistries ?? false
        var needsSave = hydration.needsMigration || endpointMigrationNeeded
            || migratedLegacyReadiness
            || p.providerConfigurationRevision == nil
        // One-time retirement of the sources this app used to seed: the open MCP registry (18,522
        // servers, self-declared unmoderated, and whose own docs say host apps should not consume it
        // directly) and PulseMCP (a private aggregator, 22,264 servers, no vetting statement).
        //
        // Keyed on URL and run ONCE, so a user who deliberately re-adds either keeps it — this
        // removes a default we chose for them, not a choice they made. The vendor-curated defaults
        // are seeded in the same pass for anyone who ends up with nothing left.
        if !retiredLegacyRegistries {
            let before = registrySources.count
            registrySources.removeAll { Self.retiredRegistryURLs.contains(
                $0.url.trimmingCharacters(in: .whitespaces).lowercased()) || $0.format == .pulseBeta }
            if registrySources.isEmpty, before > 0 { registrySources = Self.defaultRegistries }
            retiredLegacyRegistries = true
            needsSave = true
        }
        // Legacy plaintext is migrated only after every Keychain write succeeds. `save()` is a
        // transaction: a failure preserves the original, now-0600 file for recovery.
        if needsSave {
            save()
            if persistenceError == nil, !hydration.warnings.isEmpty {
                persistenceError = hydration.warnings.joined(separator: " ")
            }
        }
    }

    /// Write the file agentd reads (mcpServers/plugins) plus the browser's sources. Called after every edit.
    @discardableResult
    func save(advancingProviderConfiguration: Bool = true) -> Bool {
        let oldAccounts: Set<String> = {
            guard let data = try? Data(contentsOf: fileURL),
                  let old = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
            return MCPSecretPersistence.referencedAccounts(in: old.mcpServers)
        }()
        var newAccounts = Set<String>()
        do {
            let protection = try MCPSecretPersistence.protect(mcpServers, vault: secretVault)
            newAccounts = protection.accounts
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let nextProviderConfigurationRevision = advancingProviderConfiguration
                ? UUID() : providerConfigurationRevision
            let payload = Payload(mcpServers: protection.servers, plugins: plugins,
                                  pendingArchiveCleanups: pendingArchiveCleanups,
                                  pendingArchiveFinalizations: pendingArchiveFinalizations,
                                  registrySources: registrySources, marketplaceSources: marketplaceSources,
                                  mcpVerifiedOnly: mcpVerifiedOnly, seededPulseMCP: seededPulseMCP,
                                  retiredLegacyRegistries: retiredLegacyRegistries,
                                  providerConfigurationRevision: nextProviderConfigurationRevision,
                                  mcpCredentialRevisionByAccess: mcpCredentialRevisionByAccess,
                                  pendingMCPReadiness: pendingMCPReadiness,
                                  pendingMCPAuthorizations: pendingMCPAuthorizations)
            let data = try enc.encode(payload)
            // The temp file is created 0600, fsynced, and atomically renamed. There is no interval
            // where the new credential references or the legacy migration are exposed as 0644.
            try PrivateAtomicFile.write(data, to: fileURL)
            providerConfigurationRevision = nextProviderConfigurationRevision
            let cleanup = oldAccounts.subtracting(newAccounts).union(pendingSecretCleanup)
            pendingSecretCleanup = MCPSecretPersistence.remove(cleanup, vault: secretVault)
            persistenceError = pendingSecretCleanup.isEmpty ? nil
                : "The connection was saved, but an old MCP credential could not be removed from Keychain. Retry to finish cleanup."
            return true
        } catch {
            // `protect` uses fresh versioned accounts. If encoding or the atomic rename failed after
            // the Keychain phase, discard only this attempt and keep the old file/accounts intact.
            let failedCleanup = MCPSecretPersistence.remove(
                newAccounts.subtracting(oldAccounts), vault: secretVault)
            pendingSecretCleanup.formUnion(failedCleanup)
            // Was the bare `localizedDescription`, shown verbatim in the MCP Servers banner.
            NSLog("[persistence] extension settings could not be saved: %@",
                  error.localizedDescription)
            persistenceError = "Mechanician couldn’t save your connection settings. The change is "
                + "still here but not yet on disk."
            return false
        }
    }

    func pendingMCPReadinessClaims(for access: ModelAccess) -> [MCPReadinessClaim] {
        pendingMCPReadiness.claims(for: access)
    }

    @discardableResult
    func resolveMCPReadiness(
        _ claims: [MCPReadinessClaim],
        for access: ModelAccess
    ) -> Bool {
        guard !claims.isEmpty,
              claims.allSatisfy({ pendingMCPReadiness.claims(for: access).contains($0) })
        else { return false }
        let previous = pendingMCPReadiness
        for claim in claims { _ = pendingMCPReadiness.resolve(claim, for: access) }
        guard save(advancingProviderConfiguration: false) else {
            pendingMCPReadiness = previous
            return false
        }
        return true
    }

    func pendingMCPAuthorizationAttempts(
        for access: ModelAccess
    ) -> [MCPPendingAuthorizationAttempt] {
        pendingMCPAuthorizations.attempts(for: access)
    }

    func pendingMCPAuthorizationAttempt(
        id: String,
        for access: ModelAccess
    ) -> MCPPendingAuthorizationAttempt? {
        pendingMCPAuthorizations.attempts(for: access).first { $0.id == id }
    }

    /// Commit uncertainty before agentd can invalidate, remove, or replace a credential.
    @discardableResult
    func beginMCPAuthorizationAttempt(
        _ attempt: MCPPendingAuthorizationAttempt,
        for access: ModelAccess
    ) -> Bool {
        let previous = pendingMCPAuthorizations
        let previousRevision = mcpCredentialRevisionByAccess[access.rawValue]
        guard pendingMCPAuthorizations.begin(attempt, for: access) else { return false }
        mcpCredentialRevisionByAccess[access.rawValue] = UUID()
        guard save(advancingProviderConfiguration: false) else {
            pendingMCPAuthorizations = previous
            mcpCredentialRevisionByAccess[access.rawValue] = previousRevision
            return false
        }
        return true
    }

    /// Atomically move a provider-observed credential mutation from its write-ahead attempt into
    /// the exact readiness obligation (or retire both on clear). The sidecar is the crash boundary:
    /// no process may observe an attempt as resolved unless the replacement claim is in the same
    /// durable write. `rotateCredentialRevision` covers a valid late/idless provider observation
    /// for which this app process did not create the original attempt.
    @discardableResult
    func applyMCPCredentialTransition(
        phase: MCPCredentialActivationPhase,
        claim: MCPReadinessClaim,
        attemptID: String,
        for access: ModelAccess,
        rotateCredentialRevision: Bool
    ) -> Bool {
        let previousReadiness = pendingMCPReadiness
        let previousAuthorizations = pendingMCPAuthorizations
        let previousRevision = mcpCredentialRevisionByAccess[access.rawValue]
        var changed = false

        if rotateCredentialRevision {
            mcpCredentialRevisionByAccess[access.rawValue] = UUID()
            changed = true
        }

        switch phase {
        case .activating, .failed:
            break
        case .ready:
            let alreadyPresent = pendingMCPReadiness.claims(for: access).contains(claim)
            let marked = pendingMCPReadiness.mark(claim, for: access)
            guard marked || alreadyPresent else {
                mcpCredentialRevisionByAccess[access.rawValue] = previousRevision
                return false
            }
            changed = changed || marked
            changed = pendingMCPAuthorizations.resolve(id: attemptID, for: access) || changed
        case .cleared:
            changed = pendingMCPReadiness.retireIdentity(
                source: claim.source,
                serverID: claim.serverID,
                name: claim.name,
                for: access) || changed
            changed = pendingMCPAuthorizations.resolve(id: attemptID, for: access) || changed
        }

        guard changed else { return true }
        guard save(advancingProviderConfiguration: false) else {
            pendingMCPReadiness = previousReadiness
            pendingMCPAuthorizations = previousAuthorizations
            mcpCredentialRevisionByAccess[access.rawValue] = previousRevision
            return false
        }
        return true
    }

    /// A provider-account epoch change makes every prior MCP attempt/proof identity obsolete.
    /// Retire that route atomically and rotate its independent session generation so neither a late
    /// old-daemon event nor an opaque session can cross into the replacement account.
    @discardableResult
    func retireMCPStateForProviderAccountChange(for access: ModelAccess) -> Bool {
        let previousReadiness = pendingMCPReadiness
        let previousAuthorizations = pendingMCPAuthorizations
        let previousRevision = mcpCredentialRevisionByAccess[access.rawValue]
        let retiredReadiness = pendingMCPReadiness.retireAll(for: access)
        let retiredAuthorization = pendingMCPAuthorizations.retireAll(for: access)
        let changed = retiredReadiness || retiredAuthorization
        mcpCredentialRevisionByAccess[access.rawValue] = UUID()
        guard save(advancingProviderConfiguration: false) else {
            pendingMCPReadiness = previousReadiness
            pendingMCPAuthorizations = previousAuthorizations
            mcpCredentialRevisionByAccess[access.rawValue] = previousRevision
            return false
        }
        return changed || previousRevision != mcpCredentialRevisionByAccess[access.rawValue]
    }

    /// Keep a pending configured identity coherent across a display-name edit. Generation and
    /// stable server id do not change, so a provider proof after the rename still matches exactly.
    private func renamePendingMCPServer(id: UUID, to name: String) {
        for access in ModelAccess.allCases {
            _ = pendingMCPReadiness.renameConfiguredServer(id: id, to: name, for: access)
            _ = pendingMCPAuthorizations.renameConfiguredServer(id: id, to: name, for: access)
        }
    }

    /// Removing/disabling the exact configured row is the explicit escape hatch from a failed
    /// readiness gate. Stable identity prevents a same-name replacement from consuming it.
    private func retirePendingMCPServer(id: UUID) {
        for access in ModelAccess.allCases {
            _ = pendingMCPReadiness.retireConfiguredServer(id: id, for: access)
            _ = pendingMCPAuthorizations.retireConfiguredServer(id: id, for: access)
        }
    }

    /// Move an undecodable extensions.json aside (non-`.json` suffix) so its bytes survive for
    /// recovery instead of being silently overwritten by the next save().
    private func quarantineCorruptFile() {
        let dest = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: fileURL, to: dest)
        PrivateAtomicFile.enforcePrivatePermissions(at: dest)
    }

    // MARK: Mutations (persist immediately)

    func upsert(_ s: MCPServer) {
        if ManagedEnterprisePolicy.current?.allowUserConfiguredExtensions == false {
            guard let existing = mcpServers.first(where: { $0.id == s.id }),
                  existing.enabled, !s.enabled else { return }
        }
        var affectedNames = Set([s.name])
        if let i = mcpServers.firstIndex(where: { $0.id == s.id }) {
            affectedNames.insert(mcpServers[i].name)
            if mcpServers[i].name != s.name { renamePendingMCPServer(id: s.id, to: s.name) }
            if !s.enabled { retirePendingMCPServer(id: s.id) }
            mcpServers[i] = s
        } else {
            mcpServers.append(s)
        }
        invalidateConfiguredMCPStatus(affectedNames)
        save()
    }
    func removeServer(_ id: UUID) {
        let affectedNames = Set(mcpServers.filter { $0.id == id }.map(\.name))
        retirePendingMCPServer(id: id)
        mcpServers.removeAll { $0.id == id }
        invalidateConfiguredMCPStatus(affectedNames)
        save()
    }
    /// Remove every configured remote header for one server. Headers are credential-bearing in the
    /// MCP editor (and persisted through Keychain references), so "Clear Authorization" must clear
    /// both SDK-owned OAuth state and app-owned header/PAT state instead of falsely reporting success
    /// while the next turn silently reloads the old credential.
    @discardableResult
    func clearMCPAuthorization(_ name: String) -> Bool {
        // Provider-owned connectors have no app-owned header row, so clearing that half is a
        // successful no-op before the SDK-owned credential control is sent.
        guard let index = mcpServers.firstIndex(where: { $0.name == name }) else { return true }
        guard mcpServers[index].isRemote else { return false }
        guard !mcpServers[index].headers.isEmpty else { return true }
        let previousHeaders = mcpServers[index].headers
        mcpServers[index].headers.removeAll()
        invalidateConfiguredMCPStatus([name])
        guard save() else {
            mcpServers[index].headers = previousHeaders
            return false
        }
        return true
    }
    @discardableResult
    func upsert(_ p: LocalPlugin) -> Bool {
        if ManagedEnterprisePolicy.current?.allowUserConfiguredExtensions == false {
            guard let existing = plugins.first(where: { $0.id == p.id }),
                  existing.enabled, !p.enabled else { return false }
        }
        if let existing = plugins.first(where: { $0.id == p.id }) {
            if let pluginID = existing.catalogPluginID {
                // Generic folder editors may only change the mounted state of a catalog install.
                // Classify from the stored row so clearing provenance on the incoming value cannot
                // downgrade it into an ordinary folder and bypass archive lifecycle handling.
                guard p.catalogPluginID == pluginID else { return false }
                return setCatalogPluginEnabled(pluginID, enabled: p.enabled)
            }
            // Installing an archive is an explicit catalog operation, never a mutation that may
            // silently convert an existing user-managed folder in place.
            guard p.catalogPluginID == nil else { return false }
        }
        // Archive installation must enter through ClaudePluginStore's verified materialization
        // result and its explicit commitCatalogPlugin call, never through this generic folder API.
        guard p.catalogPluginID == nil else { return false }

        let previous = plugins
        if let i = plugins.firstIndex(where: { $0.id == p.id }) {
            plugins[i] = p
        } else {
            plugins.append(p)
        }
        guard save() else {
            plugins = previous
            return false
        }
        return true
    }

    @discardableResult
    func removePlugin(_ id: UUID) -> Bool {
        if let pluginID = plugins.first(where: {
            $0.id == id && $0.catalogPluginID != nil
        })?.catalogPluginID {
            return removeCatalogPlugin(pluginID) != nil
        }
        guard plugins.contains(where: { $0.id == id }) else { return false }
        let previous = plugins
        plugins.removeAll { $0.id == id }
        guard save() else {
            plugins = previous
            return false
        }
        return true
    }

    /// Archive-backed marketplace plugins are mounted through the SDK's reviewed local-plugin
    /// path. Keep their catalog identity alongside the folder so they survive relaunch and can be
    /// managed from the same Installed screen as provider-native plugins.
    func catalogPlugin(withID pluginID: String) -> LocalPlugin? {
        plugins.first { $0.catalogPluginID == pluginID }
    }

    /// Commit an extracted catalog plugin only after agentd has authenticated, verified and
    /// atomically materialized it. A failed extensions.json transaction restores the in-memory
    /// snapshot too, so the UI never claims a plugin is mounted when the next turn cannot see it.
    @discardableResult
    func commitCatalogPlugin(_ plugin: LocalPlugin, leaseToken: String? = nil) -> Bool {
        guard ManagedEnterprisePolicy.current?.allowUserConfiguredExtensions ?? true else {
            return false
        }
        guard ArchivePluginCleanup(plugin: plugin) != nil else { return false }
        let newFinalization: PendingArchiveFinalization?
        if let leaseToken {
            guard let finalization = PendingArchiveFinalization(
                plugin: plugin, leaseToken: leaseToken)
            else { return false }
            newFinalization = finalization
        } else {
            // Compatibility for callers that mount an already-finalized archive. Fresh verified
            // materializations pass a lease and therefore take the durable acknowledgement path.
            newFinalization = nil
        }
        let previousPlugins = plugins
        let previousCleanups = pendingArchiveCleanups
        let previousFinalizations = pendingArchiveFinalizations
        var plugin = plugin
        // A content-addressed version may become current again before an older cleanup executes.
        // Mounting it is authoritative: no pending deletion may continue to target that path.
        guard Self.reconcileArchiveMount(
            plugin,
            pendingCleanups: &pendingArchiveCleanups,
            pendingFinalizations: &pendingArchiveFinalizations)
        else {
            pendingArchiveCleanups = previousCleanups
            pendingArchiveFinalizations = previousFinalizations
            return false
        }
        if let index = plugins.firstIndex(where: {
            $0.catalogPluginID == plugin.catalogPluginID && plugin.catalogPluginID != nil
        }) {
            let replaced = plugins[index]
            plugin.id = plugins[index].id
            plugin.enabled = plugins[index].enabled
            plugins[index] = plugin
            if replaced.path != plugin.path {
                guard let cleanups = Self.archiveCleanupsForUnmounting(
                    replaced,
                    pendingFinalizations: &pendingArchiveFinalizations)
                else {
                    plugins = previousPlugins
                    pendingArchiveCleanups = previousCleanups
                    pendingArchiveFinalizations = previousFinalizations
                    return false
                }
                enqueueArchiveCleanups(cleanups)
            }
        } else {
            plugins.append(plugin)
        }
        if let newFinalization {
            guard Self.enqueueArchiveFinalization(
                newFinalization,
                into: &pendingArchiveFinalizations)
            else {
                plugins = previousPlugins
                pendingArchiveCleanups = previousCleanups
                pendingArchiveFinalizations = previousFinalizations
                return false
            }
        }
        guard save() else {
            plugins = previousPlugins
            pendingArchiveCleanups = previousCleanups
            pendingArchiveFinalizations = previousFinalizations
            return false
        }
        return true
    }

    static func reconcilingArchiveCleanups(
        _ cleanups: [ArchivePluginCleanup],
        mountedPath: String
    ) -> [ArchivePluginCleanup] {
        cleanups.filter { $0.installPath != mountedPath }
    }

    /// Cancel deletions aimed at a newly mounted content-addressed path. If a canceled cleanup
    /// carries an unacknowledged install lease, move that capability back to the finalization queue
    /// instead of dropping it. The newly returned lease is appended separately by the caller.
    static func reconcileArchiveMount(
        _ plugin: LocalPlugin,
        pendingCleanups: inout [ArchivePluginCleanup],
        pendingFinalizations: inout [PendingArchiveFinalization]
    ) -> Bool {
        guard let mountedIdentity = ArchivePluginCleanup(plugin: plugin) else { return false }
        let canceled = pendingCleanups.filter { $0.installPath == plugin.path }
        var nextFinalizations = pendingFinalizations
        for cleanup in canceled where cleanup.leaseToken != nil {
            guard cleanup.hasSameInstallIdentity(as: mountedIdentity),
                  let finalization = PendingArchiveFinalization(cleanup: cleanup),
                  enqueueArchiveFinalization(finalization, into: &nextFinalizations)
            else { return false }
        }
        pendingCleanups = reconcilingArchiveCleanups(
            pendingCleanups,
            mountedPath: plugin.path)
        pendingFinalizations = nextFinalizations
        return true
    }

    private static func enqueueArchiveFinalization(
        _ finalization: PendingArchiveFinalization,
        into pending: inout [PendingArchiveFinalization]
    ) -> Bool {
        if let existing = pending.first(where: {
            $0.leaseToken.caseInsensitiveCompare(finalization.leaseToken) == .orderedSame
        }) {
            return existing.hasSameInstallIdentity(as: finalization)
        }
        pending.append(finalization)
        return true
    }

    /// Convert an unmounted version's outstanding install acknowledgements into deletion
    /// capabilities. The transfer is pure apart from the caller-owned array, so update and
    /// uninstall can include it in the same extensions.json transaction as the mount mutation.
    static func archiveCleanupsForUnmounting(
        _ plugin: LocalPlugin,
        pendingFinalizations: inout [PendingArchiveFinalization]
    ) -> [ArchivePluginCleanup]? {
        guard let identity = ArchivePluginCleanup(plugin: plugin) else { return nil }
        let inherited = pendingFinalizations.filter {
            $0.hasSameInstallIdentity(as: identity)
        }
        guard !inherited.isEmpty else { return [identity] }
        let inheritedIDs = Set(inherited.map(\.id))
        pendingFinalizations.removeAll { inheritedIDs.contains($0.id) }
        let cleanups = inherited.compactMap(\.archiveCleanup)
        return cleanups.count == inherited.count ? cleanups : nil
    }

    private func enqueueArchiveCleanups(_ cleanups: [ArchivePluginCleanup]) {
        for cleanup in cleanups {
            let sameIdentity: (ArchivePluginCleanup) -> Bool = {
                $0.hasSameInstallIdentity(as: cleanup)
            }
            if let leaseToken = cleanup.leaseToken {
                pendingArchiveCleanups.removeAll {
                    sameIdentity($0) && $0.leaseToken == nil
                }
                guard !pendingArchiveCleanups.contains(where: {
                    sameIdentity($0)
                        && $0.leaseToken?.caseInsensitiveCompare(leaseToken) == .orderedSame
                }) else { continue }
            } else {
                // A token-bearing deletion can also remove this exact path; a second generic row
                // would only duplicate work.
                guard !pendingArchiveCleanups.contains(where: sameIdentity) else { continue }
            }
            pendingArchiveCleanups.append(cleanup)
        }
    }

    @discardableResult
    func setCatalogPluginEnabled(_ pluginID: String, enabled: Bool) -> Bool {
        if enabled, ManagedEnterprisePolicy.current?.allowUserConfiguredExtensions == false {
            return false
        }
        guard let index = plugins.firstIndex(where: { $0.catalogPluginID == pluginID }) else {
            return false
        }
        let previous = plugins
        plugins[index].enabled = enabled
        guard save() else {
            plugins = previous
            return false
        }
        return true
    }

    /// Atomically unmount the plugin and retain its exact deletion identity for retry across a
    /// crash or runtime restart.
    func removeCatalogPlugin(_ pluginID: String) -> ArchivePluginCleanup? {
        guard let plugin = catalogPlugin(withID: pluginID) else { return nil }
        let previousPlugins = plugins
        let previousCleanups = pendingArchiveCleanups
        let previousFinalizations = pendingArchiveFinalizations
        guard let cleanups = Self.archiveCleanupsForUnmounting(
            plugin,
            pendingFinalizations: &pendingArchiveFinalizations),
              let cleanup = cleanups.first
        else {
            pendingArchiveFinalizations = previousFinalizations
            return nil
        }
        plugins.removeAll { $0.catalogPluginID == pluginID }
        enqueueArchiveCleanups(cleanups)
        guard save() else {
            plugins = previousPlugins
            pendingArchiveCleanups = previousCleanups
            pendingArchiveFinalizations = previousFinalizations
            return nil
        }
        return cleanup
    }

    @discardableResult
    func completeArchiveCleanup(_ cleanupID: UUID) -> Bool {
        guard pendingArchiveCleanups.contains(where: { $0.id == cleanupID }) else { return true }
        let previous = pendingArchiveCleanups
        pendingArchiveCleanups.removeAll { $0.id == cleanupID }
        guard save(advancingProviderConfiguration: false) else {
            pendingArchiveCleanups = previous
            return false
        }
        return true
    }

    @discardableResult
    func completeArchiveFinalization(_ finalizationID: UUID) -> Bool {
        let hasFinalization = pendingArchiveFinalizations.contains { $0.id == finalizationID }
        let hasTransferredCleanup = pendingArchiveCleanups.contains {
            $0.id == finalizationID && $0.leaseToken != nil
        }
        guard hasFinalization || hasTransferredCleanup else { return true }
        let previousFinalizations = pendingArchiveFinalizations
        let previousCleanups = pendingArchiveCleanups
        pendingArchiveFinalizations.removeAll { $0.id == finalizationID }
        // A finalize response can cross an update/uninstall that already transferred this token
        // into a cleanup. Keep the deletion queued, but stop retrying with the now-consumed lease.
        for index in pendingArchiveCleanups.indices
        where pendingArchiveCleanups[index].id == finalizationID {
            pendingArchiveCleanups[index].leaseToken = nil
        }
        guard save(advancingProviderConfiguration: false) else {
            pendingArchiveFinalizations = previousFinalizations
            pendingArchiveCleanups = previousCleanups
            return false
        }
        return true
    }

    func upsert(_ r: RegistrySource) {
        guard ManagedEnterprisePolicy.current?.allowUserConfiguredExtensions ?? true else { return }
        var userSource = r
        userSource.source = .user
        userSource.authentication = nil
        if let i = registrySources.firstIndex(where: { $0.id == userSource.id }) {
            registrySources[i] = userSource
        } else {
            registrySources.append(userSource)
        }
        save()
    }
    func removeRegistry(_ id: UUID) { registrySources.removeAll { $0.id == id }; save() }
    @discardableResult
    func upsert(_ m: MarketplaceSource) -> Bool {
        guard ManagedEnterprisePolicy.current?.allowUserConfiguredExtensions ?? true else {
            return false
        }
        let previous = marketplaceSources
        var userSource = m
        userSource.source = .user
        userSource.authentication = nil
        if let i = marketplaceSources.firstIndex(where: { $0.id == userSource.id }) {
            marketplaceSources[i] = userSource
        } else {
            marketplaceSources.append(userSource)
        }
        guard save() else {
            marketplaceSources = previous
            return false
        }
        return true
    }
    @discardableResult
    func removeMarketplace(_ id: UUID) -> Bool {
        let previous = marketplaceSources
        marketplaceSources.removeAll { $0.id == id }
        guard save() else {
            marketplaceSources = previous
            return false
        }
        return true
    }
}

/// Provenance and reachability metadata shared by catalogs and installed extensions. These fields
/// are optional on disk so every pre-enterprise `extensions.json` remains decodable.
/// Where an extension came from, expressed as WHO VOUCHES for it — the only question that
/// usefully distinguishes these. Trust belongs to a source, not to an individual server: a public
/// registry is unusable when it asks you to judge five hundred entries, and workable when you
/// decide once about a publisher.
///
/// Raw values are stable and persisted; `verified` is additive, so older files decode unchanged.
enum ExtensionSource: String, Codable {
    /// The publisher of the service vouches — a first-party server from the vendor whose service
    /// it exposes (Anthropic, OpenAI, Google, Microsoft, GitHub). NOT "servers we like".
    case verified
    /// Your organisation vouches, via a signed tenant profile.
    case managed
    /// You vouch: a registry URL you added, or a server you configured by hand.
    case user

    /// Shown on a row so provenance is answerable. A nil source is deliberately NOT rendered as
    /// "user" — we genuinely do not know where pre-provenance rows came from, and guessing is how
    /// "servers I don't remember installing" became unanswerable in the first place.
    var rowLabel: String {
        switch self {
        case .verified: return "Verified"
        case .managed: return "Managed"
        case .user: return "Added by you"
        }
    }
}

enum ExtensionNetworkScope: String, Codable {
    case `public`, vpnOnly
}

/// A persisted MCP registry source from the retired discovery browser. `url` is the base of a registry that
/// speaks the official `/v0.1/servers` schema — the official one, or any compatible sub-registry / mirror
/// (incl. an internal/enterprise one).
struct RegistrySource: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = ""
    var url: String = ""
    var enabled: Bool = true
    var format: RegistryFormat = .officialV01
    var source: ExtensionSource? = nil
    var networkScope: ExtensionNetworkScope? = nil
    var authentication: ExtensionSourceAuthentication? = nil
    var sha256: String? = nil
    var governance: TenantProfile.RegistryGovernancePolicy? = nil
    var displayName: String { name.isEmpty ? (URL(string: url)?.host ?? url) : name }
    var isValid: Bool { url.trimmingCharacters(in: .whitespaces).hasPrefix("https://") }
    var isManaged: Bool { source == .managed }
    enum CodingKeys: String, CodingKey {
        case id, name, url, enabled, format, source, networkScope, authentication, sha256, governance
    }
}

// Tolerant decode in an EXTENSION so the synthesized memberwise init (`RegistrySource(name:url:…)`) is
// retained. A missing `format` in an older extensions.json falls back to the official schema instead of
// throwing — a throw would fail the whole Payload decode and silently drop the user's servers/plugins.
extension RegistrySource {
    init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        if let v = try? c.decode(UUID.self, forKey: .id) { id = v }
        if let v = try? c.decode(String.self, forKey: .name) { name = v }
        if let v = try? c.decode(String.self, forKey: .url) { url = v }
        if let v = try? c.decode(Bool.self, forKey: .enabled) { enabled = v }
        if let v = try? c.decode(RegistryFormat.self, forKey: .format) { format = v }
        source = try? c.decodeIfPresent(ExtensionSource.self, forKey: .source)
        networkScope = try? c.decodeIfPresent(ExtensionNetworkScope.self, forKey: .networkScope)
        authentication = try? c.decodeIfPresent(ExtensionSourceAuthentication.self, forKey: .authentication)
        sha256 = try? c.decodeIfPresent(String.self, forKey: .sha256)
        governance = try? c.decodeIfPresent(TenantProfile.RegistryGovernancePolicy.self, forKey: .governance)
    }
}

/// How a registry source's HTTP responses are shaped, so the browser can point at more than the official
/// schema. Each case has an adapter (query params + decode) in ExtensionsBrowser (`RegistryAdapter`).
enum RegistryFormat: String, Codable, CaseIterable, Identifiable {
    case officialV01     // registry.modelcontextprotocol.io — /v0(.1)/servers, packages/remotes
    case pulseBeta       // api.pulsemcp.com/v0beta/servers — adds github_stars + download counts
    /// Any registry nobody wrote an adapter for. Infers field names instead of mapping them, so a
    /// new catalog needs no app release. See ``GenericMCPRegistryAdapter``.
    case generic
    var id: String { rawValue }

    /// Retired per-organization formats decode to `generic` rather than throwing.
    ///
    /// This is a plain `String` enum, so an unknown raw value would fail the whole source's decode
    /// and take an installed registry with it. One private server-card format used to have its own
    /// case; the inference adapter reads the same documents, so a stored source naming it keeps
    /// working. An unrecognized value lands on `generic` for the same reason: an unidentifiable
    /// catalog is exactly what inference is for.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RegistryFormat(rawValue: raw) ?? .generic
    }
    var label: String {
        switch self {
        case .officialV01: return "Official MCP Registry"
        case .pulseBeta:   return "PulseMCP (enriched)"
        case .generic:     return "Other registry (auto-detect)"
        }
    }
    var hint: String {
        switch self {
        case .officialV01: return "Official /v0/servers schema: DNS-verified reverse-DNS namespaces."
        case .pulseBeta:   return "PulseMCP /v0beta/servers: adds GitHub stars and package downloads."
        case .generic:     return "Detects the shape of most JSON server catalogs automatically."
        }
    }

    /// What the format actually is, for someone deciding which to pick. Registries differ in shape
    /// and there is no content negotiation to sort it out: choose wrong and the registry decodes to
    /// nothing, which looks exactly like an empty registry.
    var documentation: String {
        switch self {
        case .officialV01:
            return "The Model Context Protocol's own registry schema. A JSON object with a "
                + "`servers` array, each entry naming packages or remotes. Namespaces are "
                + "reverse-DNS and DNS-verified, so `com.stripe/mcp` really is Stripe's. Pick this "
                + "for the official registry and for anything that mirrors it. It is the closest "
                + "thing to a standard."
        case .pulseBeta:
            return "PulseMCP's enriched feed. The official schema plus GitHub stars and package "
                + "download counts, which are the only popularity signals available anywhere. Same "
                + "servers, more context for judging them."
        case .generic:
            return "For a catalog that follows no published schema, most often an organization's "
                + "own. Rather than being told which field is which, it recognizes them: a list of "
                + "servers under any usual key, and per server a name, an https endpoint or an "
                + "npm/PyPI package, and optionally a description, version, repository and review "
                + "status. Field names are matched ignoring case and separators, so `server_name`, "
                + "`serverName` and `Server-Name` are the same thing. Anything it cannot recognize "
                + "is skipped rather than guessed at, so a server with no usable endpoint is left "
                + "out instead of offered as connectable."
        }
    }

    /// Whether a person can pick this when adding a registry by hand.
    ///
    /// Every remaining format is general: a private catalog is now described by a signed profile
    /// pointing `generic` at its URL, rather than by a case named after one organization.
    var isUserSelectable: Bool { true }

    static var userSelectableCases: [RegistryFormat] { allCases.filter(\.isUserSelectable) }
}

enum MarketplaceFormat: String, Codable, CaseIterable, Identifiable {
    case claudeMarketplace
    // Keep the serialized value stable for existing saved sources and signed managed profiles.
    case archiveRegistryV1 = "claudeworkV1"
    var id: String { rawValue }
}

/// HTTP authentication a signed tenant profile may select for catalog discovery. This is not
/// user-editable: arbitrary sources must never receive the enterprise user's Google identity token.
enum ExtensionSourceAuthentication: String, Codable, Equatable {
    case googleIdentity
}

/// A user-editable plugin marketplace source. `repo` is either a Claude Code marketplace location
/// (`owner/repo`, HTTPS URL, or local path) or, for `archiveRegistryV1`, an HTTPS archive-registry
/// URL.
struct MarketplaceSource: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = ""
    var repo: String = ""
    var enabled: Bool = true
    var format: MarketplaceFormat = .claudeMarketplace
    var source: ExtensionSource? = nil
    var networkScope: ExtensionNetworkScope? = nil
    var authentication: ExtensionSourceAuthentication? = nil
    var sha256: String? = nil
    var displayName: String { name.isEmpty ? repo : name }
    var rawURL: String {
        let r = repo.trimmingCharacters(in: .whitespaces)
        if let scheme = URL(string: r)?.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return r
        }
        return "https://raw.githubusercontent.com/\(r)/main/.claude-plugin/marketplace.json"
    }
    var isValid: Bool {
        let r = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return false }
        guard format == .archiveRegistryV1 else { return true }
        guard let url = URL(string: r),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil, url.password == nil,
              url.fragment == nil else { return false }
        return true
    }
    var isManaged: Bool { source == .managed }
    enum CodingKeys: String, CodingKey {
        case id, name, repo, enabled, format, source, networkScope, authentication, sha256
    }
}

extension MarketplaceSource {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode(UUID.self, forKey: .id) { id = v }
        if let v = try? c.decode(String.self, forKey: .name) { name = v }
        if let v = try? c.decode(String.self, forKey: .repo) { repo = v }
        if let v = try? c.decode(Bool.self, forKey: .enabled) { enabled = v }
        if let v = try? c.decode(MarketplaceFormat.self, forKey: .format) { format = v }
        source = try? c.decodeIfPresent(ExtensionSource.self, forKey: .source)
        networkScope = try? c.decodeIfPresent(ExtensionNetworkScope.self, forKey: .networkScope)
        authentication = try? c.decodeIfPresent(ExtensionSourceAuthentication.self, forKey: .authentication)
        sha256 = try? c.decodeIfPresent(String.self, forKey: .sha256)
    }
}

/// One external MCP server. `transport` selects which fields apply: stdio → command/args/env;
/// http or sse → url/headers. agentd converts an ENABLED server to the SDK's McpServerConfig
/// (`{type,command,args,env}` or `{type,url,headers}`) keyed by `name`.
struct MCPServer: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = ""
    var enabled: Bool = true
    var transport: MCPTransport = .stdio
    // stdio
    var command: String = ""
    var args: [String] = []
    var env: [String: String] = [:]
    // http / sse
    var url: String = ""
    var headers: [String: String] = [:]
    /// Catalog provenance is informational after installation; the user still owns this connection.
    var source: ExtensionSource? = nil
    /// Who published it, for a verified row — "Anthropic", "GitHub", "Microsoft". Optional, so
    /// older records decode unchanged; absent means we cannot say, and the row says nothing rather
    /// than inventing an attribution.
    var publisher: String? = nil
    var networkScope: ExtensionNetworkScope? = nil
    var sha256: String? = nil

    var isRemote: Bool { transport == .http || transport == .sse }
    /// Remote headers are the explicit manual-credential alternative to browser OAuth in the
    /// connection editor. Their values are persisted in Keychain, never as plaintext preferences.
    var hasManualHeaderCredentials: Bool {
        isRemote && headers.values.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    /// A one-line summary for the list row.
    var detail: String {
        switch transport {
        case .stdio: return ([command] + args).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        case .http, .sse: return url
        }
    }
    var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return transport == .stdio ? !command.trimmingCharacters(in: .whitespaces).isEmpty
                                   : !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

}

/// Tolerant decode, deliberately in an EXTENSION so the memberwise initializer survives.
///
/// The synthesized decoder throws on any unexpected value, and the loader drops a record it cannot
/// decode — so one unrecognised enum case silently deletes a configured server. That is the
/// quarantine bug this codebase has now hit twice (0.11.7 subagents; `CapabilityParam` this week),
/// and a vanished MCP server is the worst version of it: the user configured it by hand, and gets
/// no error, no row, and nothing to fix.
///
/// Rule: a field we cannot understand falls back to its default; the record survives.
extension MCPServer {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func opt<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        self.init(name: opt(String.self, .name) ?? "")
        id = opt(UUID.self, .id) ?? UUID()
        enabled = opt(Bool.self, .enabled) ?? true
        transport = opt(MCPTransport.self, .transport) ?? .stdio
        command = opt(String.self, .command) ?? ""
        args = opt([String].self, .args) ?? []
        env = opt([String: String].self, .env) ?? [:]
        url = opt(String.self, .url) ?? ""
        headers = opt([String: String].self, .headers) ?? [:]
        // An unknown provenance stays unknown rather than being guessed — the badge says so.
        source = opt(ExtensionSource.self, .source)
        publisher = opt(String.self, .publisher)
        networkScope = opt(ExtensionNetworkScope.self, .networkScope)
        sha256 = opt(String.self, .sha256)
    }
}

enum MCPTransport: String, Codable, CaseIterable, Identifiable {
    case stdio, http, sse
    var id: String { rawValue }
    var label: String {
        switch self {
        case .stdio: return "Local (stdio)"
        case .http: return "HTTP"
        case .sse: return "SSE"
        }
    }
}

/// A sanitized, provider-neutral description of one MCP authorization failure. The daemon keeps
/// the SDK's raw error, response body, and credential-bearing details on its side of the process
/// boundary; the app receives only these optional diagnostic fields plus a user-safe message.
///
/// The nested enums deliberately accept unknown wire values. Agentd and provider runtimes can add
/// classifications without making an older app discard the message or fail to render the row.
struct MCPAuthorizationFailure: Equatable {
    enum Stage: Equatable {
        case authorizationSetup
        case callbackListener
        case protectedResourceDiscovery
        case authorizationServerDiscovery
        case clientRegistration
        case authorizationRedirect
        case authorizationCallback
        case tokenExchange
        case credentialStorage
        case sameOriginBrowser
        case other(String)

        init?(wireValue: String?) {
            guard let value = Self.normalized(wireValue) else { return nil }
            switch value {
            case "authorization_setup":
                self = .authorizationSetup
            case "callback_listener":
                self = .callbackListener
            case "protected_resource_discovery":
                self = .protectedResourceDiscovery
            case "discovery", "metadata", "oauth_discovery", "authorization_server_discovery":
                self = .authorizationServerDiscovery
            case "registration", "dynamic_registration", "client_registration":
                self = .clientRegistration
            case "authorization", "authorize", "browser", "authorization_start",
                 "authorization_redirect":
                self = .authorizationRedirect
            case "callback", "redirect", "authorization_callback":
                self = .authorizationCallback
            case "token", "token_exchange", "exchange":
                self = .tokenExchange
            case "fallback", "browser_fallback", "same_origin_browser":
                self = .sameOriginBrowser
            case "persistence", "keychain", "storage", "credential_storage":
                self = .credentialStorage
            default:
                self = .other(value)
            }
        }

        private static func normalized(_ value: String?) -> String? {
            MCPAuthorizationFailure.normalizedWireValue(value)
        }
    }

    enum Kind: Equatable {
        case cancelled
        case timeout
        case network
        case unsupported
        case denied
        case oauth
        case http
        case `protocol`
        case invalidResponse
        case configuration
        case credentials
        case server
        case unknown
        case other(String)

        init?(wireValue: String?) {
            guard let value = Self.normalized(wireValue) else { return nil }
            switch value {
            case "cancelled", "canceled", "user_cancelled", "user_canceled", "superseded":
                self = .cancelled
            case "timeout", "timed_out":
                self = .timeout
            case "network", "dns", "connection":
                self = .network
            case "unsupported", "unsupported_auth", "unsupported_oauth",
                 "dynamic_registration_unsupported", "registration_unsupported":
                self = .unsupported
            case "denied", "access_denied", "authorization_denied":
                self = .denied
            case "oauth", "oauth_error":
                self = .oauth
            case "http", "http_error":
                self = .http
            case "protocol", "protocol_error":
                self = .protocol
            case "invalid_response", "malformed_response":
                self = .invalidResponse
            case "configuration", "config", "invalid_configuration":
                self = .configuration
            case "credentials", "credential", "keychain":
                self = .credentials
            case "server", "server_error", "temporarily_unavailable":
                self = .server
            case "unknown":
                self = .unknown
            default:
                self = .other(value)
            }
        }

        private static func normalized(_ value: String?) -> String? {
            MCPAuthorizationFailure.normalizedWireValue(value)
        }
    }

    enum SuggestedAction: Equatable {
        case retry
        case manualCredentials
        case checkNetwork
        case checkVPN
        case editServer
        case none
        case other(String)

        init?(wireValue: String?) {
            guard let value = Self.normalized(wireValue) else { return nil }
            switch value {
            case "retry", "try_again", "reauthorize", "re_authenticate":
                self = .retry
            case "manual_credentials", "add_token", "edit_credentials", "header_token":
                self = .manualCredentials
            case "check_network":
                self = .checkNetwork
            case "check_vpn":
                self = .checkVPN
            case "edit_server", "edit_connection", "check_configuration":
                self = .editServer
            case "none", "no_action":
                self = .none
            default:
                self = .other(value)
            }
        }

        private static func normalized(_ value: String?) -> String? {
            MCPAuthorizationFailure.normalizedWireValue(value)
        }
    }

    var message: String
    var stage: Stage?
    var kind: Kind?
    var code: String?
    var status: Int?
    var oauth: String?
    var suggestedAction: SuggestedAction?
    var retryable: Bool?

    init(
        message: String,
        stage: Stage? = nil,
        kind: Kind? = nil,
        code: String? = nil,
        status: Int? = nil,
        oauth: String? = nil,
        suggestedAction: SuggestedAction? = nil,
        retryable: Bool? = nil
    ) {
        self.message = Self.nonEmpty(message) ?? "Authorization failed"
        self.stage = stage
        self.kind = kind
        self.code = Self.nonEmpty(code)
        self.status = status.flatMap { (100...599).contains($0) ? $0 : nil }
        self.oauth = Self.nonEmpty(oauth)
        self.suggestedAction = suggestedAction
        self.retryable = retryable
    }

    /// Convenience for AgentBridge's dynamically typed NDJSON event. Keeping raw-value parsing
    /// here ensures the store, presentation, and tests share one tolerant compatibility policy.
    init(
        message: String,
        wireStage: String?,
        wireKind: String?,
        code: String?,
        status: Int?,
        oauth: String?,
        wireSuggestedAction: String?,
        retryable: Bool?
    ) {
        self.init(
            message: message,
            stage: Stage(wireValue: wireStage),
            kind: Kind(wireValue: wireKind),
            code: code,
            status: status,
            oauth: oauth,
            suggestedAction: SuggestedAction(wireValue: wireSuggestedAction),
            retryable: retryable)
    }

    /// Decode the stable agentd wire contract while retaining short aliases used by development
    /// builds and message-only events from older Codex/Claude runtimes.
    init(event: [String: Any]) {
        func string(_ keys: [String]) -> String? {
            for key in keys {
                if let value = event[key] as? String { return value }
            }
            return nil
        }
        func integer(_ keys: [String]) -> Int? {
            for key in keys {
                if let value = event[key] as? NSNumber { return value.intValue }
                if let value = event[key] as? Int { return value }
            }
            return nil
        }
        func boolean(_ keys: [String]) -> Bool? {
            for key in keys {
                if let value = event[key] as? Bool { return value }
                if let value = event[key] as? NSNumber { return value.boolValue }
            }
            return nil
        }

        self.init(
            message: string(["message"]) ?? "Authorization failed",
            wireStage: string(["errorStage", "stage"]),
            wireKind: string(["errorKind", "kind"]),
            code: string(["errorCode", "code"]),
            status: integer(["httpStatus", "status"]),
            oauth: string(["oauthError", "oauth"]),
            wireSuggestedAction: string(["suggestedAction"]),
            retryable: boolean(["retryable"]))
    }

    static func legacy(_ message: String) -> Self {
        Self(message: message)
    }

    var isCancellation: Bool {
        if kind == .cancelled { return true }
        guard let code = Self.normalizedWireValue(code) else { return false }
        return ["cancelled", "canceled", "mcp_oauth_cancelled", "mcp_oauth_canceled"]
            .contains(code)
    }

    var indicatesUnsupportedDynamicRegistration: Bool {
        if kind == .unsupported { return true }
        if let code = Self.normalizedWireValue(code), kind == .protocol,
           [
               "dynamic_client_registration_unsupported",
               "dynamic_registration_unsupported",
           ].contains(code) {
            return true
        }
        // Providers that run their own OAuth do not send our machine-readable code. Codex reports
        // this one only in prose — "Dynamic client registration not supported" — and without a
        // fallback the policy below offered Try Again for a sign-in that can never succeed, no
        // matter how many times it is pressed. Matching text is weaker than a code, so it is
        // deliberately last and requires both halves of the phrase.
        let text = message.lowercased()
        let namesRegistration = text.contains("dynamic client registration")
            || text.contains("dynamic registration")
        return namesRegistration
            && (text.contains("not supported") || text.contains("unsupported"))
    }

    private static func normalizedWireValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

/// Transient OAuth progress for a remote MCP server (see `ExtensionsStore.authState`). The token
/// itself is owned + persisted by the provider runtime or Mechanician's route-scoped Keychain;
/// neither the token nor an unsanitized provider error is stored in this state.
enum MCPAuthState: Equatable {
    case idle          // no attempt this session
    case preparing     // button accepted; durable/session preparation runs on the next UI turn
    case authorizing   // request sent to agentd
    case waiting       // browser opened; awaiting the redirect
    case authorized    // OAuth completed
    case failed(MCPAuthorizationFailure)

    var isInProgress: Bool {
        switch self {
        case .preparing, .authorizing, .waiting: true
        case .idle, .authorized, .failed: false
        }
    }

    /// Source-compatible bridge for message-only events produced by older agentd/Codex builds.
    /// New callers should construct `MCPAuthorizationFailure` so action selection is structural.
    static func failed(_ legacyMessage: String) -> Self {
        .failed(.legacy(legacyMessage))
    }
}

/// Live connection status for a configured MCP server, mirroring the SDK's `mcpServerStatus()`
/// (see `ExtensionsStore.connState`). `checking` is our client-side "probe in flight" state; the
/// rest map 1:1 to the SDK's `connected | failed | needs-auth | pending | disabled`.
enum MCPConnState: Equatable {
    case unknown            // not probed yet
    case checking           // probe in flight
    case authenticated      // Keychain grant exists; the next real turn will verify tool mounting
    // `mcpServerStatus()` is allowed to omit its tools array even when connected. Keep that
    // distinct from a real empty array: nil = count unavailable, 0 = definitively no tools.
    case connected(Int?)
    case needsAuth          // remote OAuth server awaiting sign-in
    case failed(String)     // transport/startup failure; String = error detail
    case disabled           // reported disabled by the SDK

    /// True when the panel should offer a "Sign in" affordance for this server.
    var wantsAuth: Bool { self == .needsAuth }

    /// A config/Keychain refresh is advisory. Once a real provider turn reports a terminal
    /// transport/tool state, a lower-fidelity refresh must not erase that stronger evidence.
    func reconciled(with probe: MCPConnState) -> MCPConnState {
        if probe == .unknown || probe == .checking {
            switch self {
            case .authenticated, .connected, .needsAuth, .failed, .disabled:
                return self
            case .unknown, .checking:
                break
            }
        }
        if probe == .authenticated {
            switch self {
            case .connected, .needsAuth, .failed, .disabled:
                return self
            case .unknown, .checking, .authenticated:
                break
            }
        }
        return probe
    }
}

/// A local Claude Code plugin (a directory). agentd passes enabled ones as SDK
/// `{ type: 'local', path }` plugin configs.
struct LocalPlugin: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = ""
    var enabled: Bool = true
    var path: String = ""
    var source: ExtensionSource? = nil
    var networkScope: ExtensionNetworkScope? = nil
    var sha256: String? = nil
    /// Present only for a plugin installed from an archive-backed marketplace. These optional
    /// fields are additive to the long-standing local-folder schema.
    var catalogPluginID: String? = nil
    var marketplaceSourceID: UUID? = nil
    var marketplaceName: String? = nil
    var version: String? = nil
    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? (URL(fileURLWithPath: path).lastPathComponent) : n
    }
    var isCatalogBacked: Bool { catalogPluginID != nil }
    var isValid: Bool { !path.trimmingCharacters(in: .whitespaces).isEmpty }
    enum CodingKeys: String, CodingKey {
        case id, name, enabled, path, source, networkScope, sha256
        case catalogPluginID, marketplaceSourceID, marketplaceName, version
    }
}

extension LocalPlugin {
    /// Additive archive metadata must never make one malformed optional field quarantine the
    /// user's entire extensions sidecar. Required legacy fields retain their safe defaults.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? c.decode(UUID.self, forKey: .id) { id = value }
        if let value = try? c.decode(String.self, forKey: .name) { name = value }
        if let value = try? c.decode(Bool.self, forKey: .enabled) { enabled = value }
        if let value = try? c.decode(String.self, forKey: .path) { path = value }
        source = try? c.decodeIfPresent(ExtensionSource.self, forKey: .source)
        networkScope = try? c.decodeIfPresent(ExtensionNetworkScope.self, forKey: .networkScope)
        sha256 = try? c.decodeIfPresent(String.self, forKey: .sha256)
        catalogPluginID = try? c.decodeIfPresent(String.self, forKey: .catalogPluginID)
        marketplaceSourceID = try? c.decodeIfPresent(UUID.self, forKey: .marketplaceSourceID)
        marketplaceName = try? c.decodeIfPresent(String.self, forKey: .marketplaceName)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        if catalogPluginID != nil, ArchivePluginCleanup(plugin: self) == nil {
            // A hand-edited or partially corrupt archive identity must not become an immortal row
            // that generic folder management refuses while catalog cleanup cannot identify.
            catalogPluginID = nil
            marketplaceSourceID = nil
            marketplaceName = nil
            version = nil
        }
    }
}

/// Exact identity of an app-owned archive version awaiting deletion. All fields are persisted so
/// agentd can re-derive the content-addressed path instead of trusting `installPath` by itself.
struct ArchivePluginCleanup: Codable, Identifiable, Equatable {
    var id = UUID()
    var pluginID: String = ""
    var sourceID: UUID?
    var pluginName: String = ""
    var version: String?
    var sha256: String = ""
    var installPath: String = ""
    /// Present when deletion also acknowledges an install lease that never reached finalization.
    /// It is a capability, so malformed values invalidate the entire cleanup instead of being
    /// silently discarded and turning an authorized abort into an unauthenticated deletion.
    var leaseToken: String?
    var isValid: Bool {
        hasValidInstallIdentity
            && (leaseToken.map(Self.isLeaseToken) ?? true)
    }

    private var hasValidInstallIdentity: Bool {
        sourceID != nil
            && Self.isCleanText(pluginID)
            && Self.isCleanText(pluginName, maximum: 256)
            && version.map { Self.isCleanText($0, maximum: 128) } ?? true
            && Self.isSHA256(sha256)
            && Self.isCleanText(installPath, maximum: 4096)
    }

    init?(plugin: LocalPlugin, leaseToken: String? = nil) {
        guard let pluginID = plugin.catalogPluginID,
              let sourceID = plugin.marketplaceSourceID,
              let sha256 = plugin.sha256 else { return nil }
        self.pluginID = pluginID
        self.sourceID = sourceID
        pluginName = plugin.name
        version = plugin.version
        self.sha256 = sha256
        installPath = plugin.path
        self.leaseToken = leaseToken?.lowercased()
        guard isValid else { return nil }
    }

    fileprivate init?(
        id: UUID = UUID(),
        pluginID: String,
        sourceID: UUID?,
        pluginName: String,
        version: String?,
        sha256: String,
        installPath: String,
        leaseToken: String? = nil
    ) {
        self.id = id
        self.pluginID = pluginID
        self.sourceID = sourceID
        self.pluginName = pluginName
        self.version = version
        self.sha256 = sha256
        self.installPath = installPath
        self.leaseToken = leaseToken?.lowercased()
        guard isValid else { return nil }
    }

    func hasSameInstallIdentity(as other: ArchivePluginCleanup) -> Bool {
        pluginID == other.pluginID
            && sourceID == other.sourceID
            && pluginName == other.pluginName
            && version == other.version
            && sha256.caseInsensitiveCompare(other.sha256) == .orderedSame
            && installPath == other.installPath
    }

    fileprivate static func isCleanText(_ value: String, maximum: Int? = nil) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && maximum.map { value.utf16.count <= $0 } ?? true
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    fileprivate static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains($0)
        }
    }

    fileprivate static func isLeaseToken(_ value: String) -> Bool {
        guard value.utf8.count == 36,
              let uuid = UUID(uuidString: value),
              uuid.uuidString.caseInsensitiveCompare(value) == .orderedSame
        else { return false }
        let bytes = Array(value.lowercased().utf8)
        return bytes[14] == UInt8(ascii: "4")
            && [UInt8(ascii: "8"), UInt8(ascii: "9"),
                UInt8(ascii: "a"), UInt8(ascii: "b")].contains(bytes[19])
    }

    enum CodingKeys: String, CodingKey {
        case id, pluginID, sourceID, pluginName, version, sha256, installPath, leaseToken
    }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        if let value = try? c.decode(UUID.self, forKey: .id) { id = value }
        if let value = try? c.decode(String.self, forKey: .pluginID) { pluginID = value }
        sourceID = try? c.decodeIfPresent(UUID.self, forKey: .sourceID)
        if let value = try? c.decode(String.self, forKey: .pluginName) { pluginName = value }
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        if let value = try? c.decode(String.self, forKey: .sha256) { sha256 = value }
        if let value = try? c.decode(String.self, forKey: .installPath) { installPath = value }
        leaseToken = try? c.decodeIfPresent(String.self, forKey: .leaseToken)
    }
}

/// Exact archive identity whose successful mount still has an installer lease to acknowledge.
/// This is deliberately separate from `LocalPlugin`: the mount can change or disappear while the
/// capability still needs to be finalized or transferred to a deletion.
struct PendingArchiveFinalization: Codable, Identifiable, Equatable {
    var id = UUID()
    var pluginID: String = ""
    var sourceID: UUID?
    var pluginName: String = ""
    var version: String?
    var sha256: String = ""
    var installPath: String = ""
    var leaseToken: String = ""

    var isValid: Bool {
        archiveCleanup?.isValid == true && ArchivePluginCleanup.isLeaseToken(leaseToken)
    }

    /// The same exact deletion identity, carrying the lease capability across an update/uninstall.
    var archiveCleanup: ArchivePluginCleanup? {
        ArchivePluginCleanup(
            id: id,
            pluginID: pluginID,
            sourceID: sourceID,
            pluginName: pluginName,
            version: version,
            sha256: sha256,
            installPath: installPath,
            leaseToken: leaseToken)
    }

    init?(plugin: LocalPlugin, leaseToken: String) {
        guard let identity = ArchivePluginCleanup(plugin: plugin),
              ArchivePluginCleanup.isLeaseToken(leaseToken)
        else { return nil }
        pluginID = identity.pluginID
        sourceID = identity.sourceID
        pluginName = identity.pluginName
        version = identity.version
        sha256 = identity.sha256
        installPath = identity.installPath
        self.leaseToken = leaseToken.lowercased()
    }

    init?(cleanup: ArchivePluginCleanup) {
        guard cleanup.isValid, let leaseToken = cleanup.leaseToken else { return nil }
        id = cleanup.id
        pluginID = cleanup.pluginID
        sourceID = cleanup.sourceID
        pluginName = cleanup.pluginName
        version = cleanup.version
        sha256 = cleanup.sha256
        installPath = cleanup.installPath
        self.leaseToken = leaseToken.lowercased()
    }

    func hasSameInstallIdentity(as cleanup: ArchivePluginCleanup) -> Bool {
        archiveCleanup?.hasSameInstallIdentity(as: cleanup) == true
    }

    func hasSameInstallIdentity(as other: PendingArchiveFinalization) -> Bool {
        guard let lhs = archiveCleanup, let rhs = other.archiveCleanup else { return false }
        return lhs.hasSameInstallIdentity(as: rhs)
    }

    enum CodingKeys: String, CodingKey {
        case id, pluginID, sourceID, pluginName, version, sha256, installPath, leaseToken
    }

    /// A malformed optional queue row must not quarantine the user's entire extensions sidecar.
    /// Decode each field independently and let `load()` discard records that fail `isValid`.
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        if let value = try? c.decode(UUID.self, forKey: .id) { id = value }
        if let value = try? c.decode(String.self, forKey: .pluginID) { pluginID = value }
        sourceID = try? c.decodeIfPresent(UUID.self, forKey: .sourceID)
        if let value = try? c.decode(String.self, forKey: .pluginName) { pluginName = value }
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        if let value = try? c.decode(String.self, forKey: .sha256) { sha256 = value }
        if let value = try? c.decode(String.self, forKey: .installPath) {
            installPath = value
        }
        if let value = try? c.decode(String.self, forKey: .leaseToken) {
            leaseToken = value
        }
    }
}
