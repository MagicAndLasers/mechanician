import Foundation
import CryptoKit

/// The single source of truth for optional enterprise configuration (FR-103). Every installation
/// runs the same signed `Mechanician.app`; an administrator may add one separately signed,
/// human-readable `.mechanician-profile` file to activate audited provider routes and managed
/// extension sources.
///
/// The app embeds only the dedicated profile-signing public key. The private key is deliberately
/// separate from Sparkle's update-signing key and remains in the release Keychain. A missing file
/// resolves to ``TenantProfile/default``; an invalid file is a launch-blocking configuration error.
///
/// Trust rule: a profile only ever *selects* audited built-in adapters (e.g. `claude-vertex`). It
/// never supplies executables, commands, or raw environment variables. Consumers must treat every
/// field as declarative policy, never as something to `exec`.
struct TenantProfile: Codable, Equatable {
    var schemaVersion: Int
    /// Stable slug. `"default"` for the public app; a tenant slug (e.g. `"acme"`) otherwise.
    var tenantId: String
    var displayName: String
    /// Legacy distribution metadata. External profiles are sanitized before use, so this value can
    /// never change the running app's identity.
    var bundleIdentifier: String?
    var branding: Branding
    var update: Update?
    /// Additive enterprise routes (e.g. Claude-on-Vertex). The app's four built-in routes are always
    /// present regardless of this list.
    var routes: [Route]
    var extensions: ExtensionPolicy
    var portal: Portal?

    var isDefault: Bool { tenantId == TenantProfile.defaultTenantId }

    static let defaultTenantId = "default"

    struct Branding: Codable, Equatable {
        var iconRef: String?
        var dmgVolumeName: String?
        var supportURL: String?
        var copyright: String?
    }

    struct Update: Codable, Equatable {
        enum ProfileUpdateMode: String, Codable, Equatable {
            case automatic
            case manual
        }

        /// Sparkle feed for the APP binary.
        var feedURL: String?
        var publicEDKey: String?
        /// Where a newer signed copy of THIS DOCUMENT lives.
        ///
        /// Everything in a tenant profile is operational config that rotates on someone else's
        /// schedule — registry hostnames, a Cloud Run marketplace URL, a Vertex project, a model
        /// list — while the profile itself is a file each user imports once by hand. Without this,
        /// changing any of them means asking every user to re-import. The fetched document is
        /// verified against the same embedded key as an imported one, so the transport is not
        /// trusted and an unreachable or hostile feed can only leave the current profile in place.
        var profileFeedURL: String?
        /// Whether Mechanician may consult ``profileFeedURL`` at launch or only after the person
        /// explicitly presses Check. Missing means `automatic` so profiles signed before this field
        /// existed retain their existing behavior and can deliver one later manual-mode revision.
        var profileUpdateMode: ProfileUpdateMode?
        /// Monotonically increasing signed configuration revision. Equal content at the same
        /// revision is unchanged; different or older content is refused so an intermediary cannot
        /// replay a previously valid profile to undo a model or endpoint correction.
        var revision: Int?

        init(
            feedURL: String? = nil,
            publicEDKey: String? = nil,
            profileFeedURL: String? = nil,
            profileUpdateMode: ProfileUpdateMode? = nil,
            revision: Int? = nil
        ) {
            self.feedURL = feedURL
            self.publicEDKey = publicEDKey
            self.profileFeedURL = profileFeedURL
            self.profileUpdateMode = profileUpdateMode
            self.revision = revision
        }

        var effectiveProfileUpdateMode: ProfileUpdateMode {
            profileUpdateMode ?? .automatic
        }
    }

    struct Route: Codable, Equatable {
        var routeId: String
        var displayName: String?
        /// Names an audited adapter. `ModelAccess(adapter:)` maps exactly `claude-vertex` and
        /// `claude-bedrock` — every other value resolves to nil, so a route naming one activates
        /// nothing and declares no models. (Reading any wider list as implemented is a live trap: a
        /// route declaring models for `claude-subscription` silently has no effect at all. The
        /// managed-configuration surface reports such a route explicitly rather than showing it as
        /// configured.) Candidates for later: `anthropic-api`, `codex-subscription`, `openai-api`.
        var adapter: String
        var vertex: Vertex?
        var bedrock: Bedrock?
        /// Models this deployment is known to carry.
        ///
        /// AUTHORITATIVE for the lane, and therefore subtractive. This was originally additive —
        /// "never filter a catalog the provider successfully returned" — on the assumption that the
        /// provider's catalog describes the deployment. Measured, it does not: Claude's
        /// `supportedModels()` is answered by the local runtime from its own build-time list and
        /// returns the full first-party catalog even for a nonexistent Vertex project with no
        /// credentials, led by `default` → `claude-opus-5`. Trusting it selected a model a managed
        /// project answers with 404 on every turn, with no path back.
        ///
        /// The two failure modes are not symmetric. Withholding a model the deployment does carry
        /// is recoverable — publish an updated signed profile, and ``ModelCatalogStore/constrained``
        /// surfaces exactly what was withheld. Offering one it cannot serve leaves the account with
        /// no working turn at all. The generic built-in list is what a lane falls back to when a
        /// route declares nothing.
        var models: [Model]
        var isDefault: Bool

        enum CodingKeys: String, CodingKey {
            case routeId, displayName, adapter, vertex, bedrock, models
            case isDefault = "default"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            routeId = try c.decode(String.self, forKey: .routeId)
            displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            adapter = try c.decode(String.self, forKey: .adapter)
            vertex = try c.decodeIfPresent(Vertex.self, forKey: .vertex)
            bedrock = try c.decodeIfPresent(Bedrock.self, forKey: .bedrock)
            models = try c.decodeIfPresent([Model].self, forKey: .models) ?? []
            isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        }

        init(routeId: String, displayName: String? = nil, adapter: String, vertex: Vertex? = nil,
             bedrock: Bedrock? = nil, models: [Model] = [], isDefault: Bool = false) {
            self.routeId = routeId
            self.displayName = displayName
            self.adapter = adapter
            self.vertex = vertex
            self.bedrock = bedrock
            self.models = models
            self.isDefault = isDefault
        }
    }

    /// One model a managed deployment declares. `id` is the provider model id sent on the wire.
    struct Model: Codable, Equatable {
        var id: String
        var displayName: String?
        /// Exact provider effort ids this managed deployment supports for this model. An empty
        /// list makes no capability claim, preserving older profiles and live discovery.
        var supportedEfforts: [String]
        var isDefault: Bool

        enum CodingKeys: String, CodingKey {
            case id, displayName
            case supportedEfforts = "efforts"
            case isDefault = "default"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            supportedEfforts = try c.decodeIfPresent(
                [String].self, forKey: .supportedEfforts) ?? []
            isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        }

        init(
            id: String,
            displayName: String? = nil,
            supportedEfforts: [String] = [],
            isDefault: Bool = false
        ) {
            self.id = id
            self.displayName = displayName
            self.supportedEfforts = supportedEfforts
            self.isDefault = isDefault
        }
    }

    struct Vertex: Codable, Equatable {
        var projectId: String
        var region: String
    }

    /// AWS Bedrock endpoint selection. Deliberately NO credentials: Bedrock resolves the ordinary
    /// AWS chain (environment, `AWS_PROFILE`, SSO, instance role) inside the engine process, exactly
    /// as the `aws` CLI does. `profile` names which of the user's existing AWS profiles to use — it
    /// is a selector, not a secret, and a configuration that carried keys would be a configuration
    /// people email to each other with credentials in it.
    struct Bedrock: Codable, Equatable {
        var region: String
        var profile: String?
    }

    struct ExtensionPolicy: Codable, Equatable {
        /// When true, the user's own MCP/plugin sources and the public registries remain available
        /// alongside the managed ones.
        var allowPublic: Bool
        var managedSources: [ManagedSource]
        var managedServers: [ManagedServer]
        /// Host suffix permitted to use the audited same-origin browser sign-in for remote MCP,
        /// for a deployment whose gateway predates standards OAuth discovery. A candidate host must
        /// be exactly one label beneath it. Absent here — as in the public profile — no host
        /// qualifies and that fallback does not exist.
        var sameOriginBrowserAuthHostSuffix: String? = nil

        init(allowPublic: Bool = true, managedSources: [ManagedSource] = [],
             managedServers: [ManagedServer] = [],
             sameOriginBrowserAuthHostSuffix: String? = nil) {
            self.allowPublic = allowPublic
            self.managedSources = managedSources
            self.managedServers = managedServers
            self.sameOriginBrowserAuthHostSuffix = sameOriginBrowserAuthHostSuffix
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            allowPublic = try c.decodeIfPresent(Bool.self, forKey: .allowPublic) ?? true
            managedSources = try c.decodeIfPresent([ManagedSource].self, forKey: .managedSources) ?? []
            sameOriginBrowserAuthHostSuffix = try c.decodeIfPresent(
                String.self, forKey: .sameOriginBrowserAuthHostSuffix)
            managedServers = try c.decodeIfPresent([ManagedServer].self, forKey: .managedServers) ?? []
        }
    }

    /// Source-level governance semantics shared by every audited registry adapter. Adapters normalize
    /// a registry's native review field into a status string; the signed profile declares which native
    /// values mean "approved" for that company. Entries outside that set remain visible and connectable
    /// but receive a "Not approved" badge in the app.
    struct RegistryGovernancePolicy: Codable, Equatable {
        var approvedStatuses: [String]

        init(approvedStatuses: [String] = ["Approved"]) {
            self.approvedStatuses = approvedStatuses
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            approvedStatuses = try c.decodeIfPresent([String].self, forKey: .approvedStatuses)
                ?? ["Approved"]
        }

        func isApproved(_ status: String) -> Bool {
            let candidate = Self.normalized(status)
            return approvedStatuses.contains { Self.normalized($0) == candidate }
        }

        private static func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
    }

    /// A catalog that lists a service's host root while its MCP endpoint lives at a fixed path
    /// below it. Declaring the rule here keeps one organization's URL shape in that organization's
    /// signed profile, instead of a hostname compiled into a general-purpose app.
    struct RegistryEndpointRule: Codable, Equatable {
        /// Only hosts ending in this suffix are rewritten, so the rule cannot reach other catalogs.
        var hostSuffix: String
        /// The path to apply, and only when the entry carries none of its own.
        var path: String

        init(hostSuffix: String, path: String) {
            self.hostSuffix = hostSuffix
            self.path = path
        }
    }

    struct ManagedSource: Codable, Equatable {
        var kind: String              // "registry" | "marketplace"
        var name: String
        var url: String?
        var repo: String?
        var format: String?           // "officialV01" | "pulseBeta" | "generic"
        var authentication: String? = nil // audited values only; currently "googleIdentity"
        var networkScope: String?     // "vpnOnly" | "public"
        var sha256: String? = nil      // optional digest for a pinned static catalog
        var governance: RegistryGovernancePolicy? = nil
        var endpointRule: RegistryEndpointRule? = nil
    }

    struct ManagedServer: Codable, Equatable {
        var name: String
        var transport: String         // "stdio" | "http" | "sse"
        var url: String?
        var command: String?
        var args: [String]?
        var env: [String: String]?
        var networkScope: String?     // "vpnOnly" | "public"
    }

    struct Portal: Codable, Equatable {
        var downloadDomain: String?
        var url: String?
    }

    // MARK: - Tolerant decoding

    // Hand-authored tenant profiles may omit whole sections; a partial document must still load. Only
    // `tenantId` and `displayName` are truly required. Missing sections fall back to public-equivalent
    // defaults so an under-specified profile degrades toward "public", never toward broken.
    enum CodingKeys: String, CodingKey {
        case schemaVersion, tenantId, displayName, bundleIdentifier, branding, update, routes, extensions, portal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        tenantId = try c.decode(String.self, forKey: .tenantId)
        displayName = try c.decode(String.self, forKey: .displayName)
        bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        branding = try c.decodeIfPresent(Branding.self, forKey: .branding) ?? Branding()
        update = try c.decodeIfPresent(Update.self, forKey: .update)
        routes = try c.decodeIfPresent([Route].self, forKey: .routes) ?? []
        extensions = try c.decodeIfPresent(ExtensionPolicy.self, forKey: .extensions) ?? ExtensionPolicy()
        portal = try c.decodeIfPresent(Portal.self, forKey: .portal)
    }

    init(
        schemaVersion: Int = 1,
        tenantId: String,
        displayName: String,
        bundleIdentifier: String? = nil,
        branding: Branding = Branding(),
        update: Update? = nil,
        routes: [Route] = [],
        extensions: ExtensionPolicy = ExtensionPolicy(),
        portal: Portal? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.tenantId = tenantId
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.branding = branding
        self.update = update
        self.routes = routes
        self.extensions = extensions
        self.portal = portal
    }

    // MARK: - Loading

    /// The public-app profile: no enterprise routes, public extensions allowed, no managed sources.
    /// Behaviourally identical to shipping no profile at all.
    static let `default` = TenantProfile(
        tenantId: defaultTenantId,
        displayName: "Mechanician",
        branding: Branding(copyright: "© 2026 Magic & Lasers"))

    /// The profile resolved once for this process. Profile changes intentionally take effect only
    /// after an app restart, keeping stores and provider runtimes on one coherent configuration.
    static var current: TenantProfile { currentResolution.profile }

    /// The endpoint rule a managed registry declares, if this tenant declares one at all.
    ///
    /// Servers installed before a rule existed are completed against it at hydration, so a catalog
    /// that lists host roots does not leave unconnectable entries behind. The public profile
    /// declares none, and with none nothing is rewritten.
    var registryEndpointRule: RegistryEndpointRule? {
        extensions.managedSources.compactMap(\.endpointRule).first
    }

    /// A present-but-invalid profile fails closed at app launch instead of silently dropping the
    /// enterprise route and potentially sending a turn through a different provider.
    static var startupError: String? { currentResolution.error }

    /// The external file selected for this launch, useful for diagnostics and future Settings UI.
    /// One line naming the configuration this app is actually running, for the surfaces where a
    /// person asks "did my update land?".
    ///
    /// Answering that required reading a file out of Application Support with a Python one-liner,
    /// which is not an answer a user can be asked for. The revision is the load-bearing half: the
    /// app refuses a document whose revision does not advance, so a stale number is the single
    /// clearest signal that a published change has not arrived. Nil for the public build, which has
    /// no managed configuration and should say nothing.
    static var currentConfigurationSummary: String? { configurationSummary(for: current) }

    /// The same fact as ``configurationSummary(for:)`` but unjoined, so a SwiftUI view can build it
    /// from a literal with interpolation. A runtime `String` handed to `Text` cannot be localized,
    /// and the organization's own name must never be translated, so the words and the data have to
    /// stay separate until the view assembles them.
    static var currentConfigurationParts: (name: String, revision: Int?)? {
        configurationParts(for: current)
    }

    static func configurationParts(for profile: TenantProfile) -> (name: String, revision: Int?)? {
        guard !profile.enterpriseAccesses.isEmpty || profile.update?.profileFeedURL != nil else {
            return nil
        }
        let name = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? "Managed" : name, profile.update?.revision)
    }

    /// True when this install's local overrides replace a model list the administrator published.
    ///
    /// This is the one override with no visible consequence. Every other overridable field shows its
    /// own effect somewhere — a re-pointed source URL, a different Vertex project. A replaced model
    /// list is indistinguishable from a published one, so an administrator can publish a revision,
    /// the user can confirm that exact revision is installed, and both still see the OLD models with
    /// nothing anywhere saying why. Diagnosing that cost a full publish-and-verify round trip.
    static var currentModelsAreLocallyOverridden: Bool {
        modelsAreLocallyOverridden(effective: current, signed: currentSignedProfile)
    }

    /// Pure so it can be tested against any pair rather than only the one this process resolved.
    static func modelsAreLocallyOverridden(effective: TenantProfile, signed: TenantProfile) -> Bool {
        var published: [String: [Model]] = [:]
        for route in signed.routes { published[route.routeId] = route.models }
        return effective.routes.contains { route in
            // A locally authored route has no published list it could be disagreeing with.
            guard let declared = published[route.routeId] else { return false }
            return route.models != declared
        }
    }

    /// Pure so it can be tested against any profile rather than only the one this process resolved.
    static func configurationSummary(for profile: TenantProfile) -> String? {
        guard !profile.enterpriseAccesses.isEmpty || profile.update?.profileFeedURL != nil else {
            return nil
        }
        let name = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name.isEmpty ? "Managed configuration" : "\(name) configuration"
        guard let revision = profile.update?.revision else { return label }
        return "\(label) · revision \(revision)"
    }

    static var currentProfileURL: URL? { currentResolution.sourceURL }

    /// True only when a forced application preference supplied this launch's enterprise policy.
    static var currentIsManagedByMDM: Bool { currentResolution.managedByMDM }

    /// The profile as the administrator signed it, before this install's local overrides. The
    /// managed-configuration editor diffs against this to mark overridden fields and offer a reset.
    static var currentSignedProfile: TenantProfile { currentResolution.signed }

    /// The enterprise route lanes this profile activates, in declared order, deduplicated. Built-in
    /// adapters are ignored here — they are always present via ``ModelAccess/builtInCases``.
    var enterpriseAccesses: [ModelAccess] {
        var seen = Set<ModelAccess>()
        return routes.compactMap { ModelAccess(adapter: $0.adapter) }.filter { seen.insert($0).inserted }
    }

    /// The Vertex project/region for this profile's `claude-vertex` route, if it declares one. The
    /// daemon receives these via `MECHANICIAN_VERTEX_PROJECT` / `_REGION` (see AgentdRuntime).
    var vertexConfig: Vertex? {
        routes.first(where: { $0.adapter == "claude-vertex" })?.vertex
    }

    /// The Bedrock region/profile for this configuration's `claude-bedrock` route, if it declares
    /// one. The daemon receives these via `MECHANICIAN_BEDROCK_*` (see AgentdRuntime).
    var bedrockConfig: Bedrock? {
        routes.first(where: { $0.adapter == "claude-bedrock" })?.bedrock
    }

    /// The models this profile declares for a lane, in declared order with any `default` first.
    /// Empty when the profile says nothing — the caller then uses the generic built-in list.
    func declaredModels(for access: ModelAccess) -> [Model] {
        let declared = routes
            .filter { ModelAccess(adapter: $0.adapter) == access }
            .flatMap(\.models)
        var seen = Set<String>()
        let unique = declared.filter { seen.insert($0.id).inserted }
        return unique.filter(\.isDefault) + unique.filter { !$0.isDefault }
    }

    /// A tenant may choose the first-run route, but only from the same audited adapter list used to
    /// activate lanes. Existing user preferences still win after first launch.
    var defaultAccess: ModelAccess? {
        routes.first(where: { $0.isDefault }).flatMap { ModelAccess(adapter: $0.adapter) }
    }

    /// Stable, non-secret fingerprint for state owned by one exact enterprise backend. Project and
    /// region participate as well as tenant/route IDs, so a profile update that retargets a route
    /// cannot resume sessions or reuse credentials from the previous backend. Registry-only profile
    /// changes deliberately leave this identity unchanged.
    func routeIdentity(for access: ModelAccess) -> String? {
        let material: [String]
        switch access {
        case .claudeVertex:
            guard let route = routes.first(where: { $0.adapter == "claude-vertex" }),
                  let vertex = route.vertex,
                  !tenantId.isEmpty, !route.routeId.isEmpty,
                  !vertex.projectId.isEmpty, !vertex.region.isEmpty
            else { return nil }
            material = [
                "route-v1", tenantId, route.routeId, route.adapter, vertex.projectId, vertex.region,
            ]
        case .claudeBedrock:
            // The AWS profile participates: two profiles are two accounts, and a session or cached
            // credential from one must never be reused under the other.
            guard let route = routes.first(where: { $0.adapter == "claude-bedrock" }),
                  let bedrock = route.bedrock,
                  !tenantId.isEmpty, !route.routeId.isEmpty, !bedrock.region.isEmpty
            else { return nil }
            material = [
                "route-v1", tenantId, route.routeId, route.adapter, bedrock.region,
                bedrock.profile ?? "",
            ]
        default:
            return nil
        }
        let joined = material.joined(separator: "\0")
        let digest = SHA256.hash(data: Data(joined.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "route-v1:\(digest)"
    }

    /// Filesystem-safe storage component derived from the full route identity. No profile-controlled
    /// string is ever used directly as a path segment.
    func routeStorageComponent(for access: ModelAccess) -> String? {
        guard let identity = routeIdentity(for: access) else { return nil }
        return String(identity.dropFirst("route-v1:".count))
    }

    func routeConfigDirectory(for access: ModelAccess, supportDirectory: URL) -> URL? {
        guard let component = routeStorageComponent(for: access) else { return nil }
        return supportDirectory
            .appendingPathComponent("provider-routes", isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
            .appendingPathComponent("claude", isDirectory: true)
    }

    /// Runtime defense in depth while legacy per-tenant bundle scripts still exist on this branch.
    /// The standard public bundle may now carry any *verified external* enterprise profile. A legacy
    /// custom bundle still has to match its old embedded identity until that packaging is removed.
    static func configurationError(
        profile: TenantProfile,
        bundleIdentifier: String?
    ) -> String? {
        guard let bundleIdentifier else { return nil } // raw SwiftPM test/development executable
        if bundleIdentifier == MechanicianEnvironment.baseBundleIdentifier { return nil }
        if bundleIdentifier == MechanicianEnvironment.devBundleIdentifier { return nil }
        guard let slug = MechanicianEnvironment.identitySlug(for: bundleIdentifier) else { return nil }
        guard !profile.isDefault else {
            return "This enterprise build is missing a valid tenant profile."
        }
        guard profile.bundleIdentifier == bundleIdentifier else {
            return "The tenant profile does not match this app's bundle identity."
        }
        guard profile.tenantId == slug else {
            return "The tenant profile ID does not match this app's bundle identity."
        }
        return nil
    }

    // MARK: - Signed external profile

    struct Resolution {
        /// The EFFECTIVE profile: the signed document with the user's local overrides applied.
        /// Everything in the app reads this, so an override needs no special handling anywhere.
        var profile: TenantProfile
        /// The document exactly as the administrator signed it. Kept so the managed-configuration
        /// editor can show what was published, mark which fields are locally overridden, and offer
        /// a reset. Equal to `profile` when nothing is overridden.
        var signed: TenantProfile
        var sourceURL: URL?
        var error: String?
        var managedByMDM: Bool

        init(profile: TenantProfile, signed: TenantProfile? = nil,
             sourceURL: URL? = nil, error: String? = nil, managedByMDM: Bool = false) {
            self.profile = profile
            self.signed = signed ?? profile
            self.sourceURL = sourceURL
            self.error = error
            self.managedByMDM = managedByMDM
        }
    }

    enum SignedProfileError: LocalizedError {
        case malformedEnvelope
        case unsupportedDocumentVersion(Int)
        case invalidPublicKey
        case invalidSignature
        case unsupportedProfileSchema(Int)
        case reservedTenantId
        case invalidRouteConfiguration
        case invalidModelConfiguration
        case invalidManagedServerConfiguration
        case executableConfigurationNotAllowed

        var errorDescription: String? {
            switch self {
            case .malformedEnvelope:
                return "The file is not a valid Mechanician enterprise profile."
            case .unsupportedDocumentVersion(let version):
                return "Enterprise profile document version \(version) is not supported."
            case .invalidPublicKey:
                return "Mechanician's enterprise profile trust key is invalid."
            case .invalidSignature:
                return "The enterprise profile signature is invalid."
            case .unsupportedProfileSchema(let version):
                return "Enterprise profile schema version \(version) is not supported."
            case .reservedTenantId:
                return "An enterprise profile cannot use the reserved tenant ID “default”."
            case .invalidRouteConfiguration:
                return "The enterprise profile must define exactly one complete identity for each enabled provider route."
            case .invalidModelConfiguration:
                return "The enterprise profile contains an invalid model effort declaration."
            case .invalidManagedServerConfiguration:
                return "The enterprise profile contains an invalid managed extension server declaration."
            case .executableConfigurationNotAllowed:
                return "Enterprise profiles cannot supply executable MCP commands, arguments, or environment variables."
            }
        }
    }

    private struct SignedEnvelope: Decodable {
        var documentVersion: Int
        var profile: TenantProfile
        var signature: String
    }

    static let profileFileName = "enterprise.mechanician-profile"
    static let profileFilenameExtension = "mechanician-profile"
    static let profilePathEnvironmentVariable = "MECHANICIAN_ENTERPRISE_PROFILE"

    static func matchesProfileDocument(_ url: URL) -> Bool {
        url.isFileURL
            && url.pathExtension.caseInsensitiveCompare(profileFilenameExtension) == .orderedSame
    }

    /// Dedicated profile-signing key (`mechanician-enterprise-profiles` in the release Keychain).
    /// This is intentionally not the public app's `SUPublicEDKey`.
    static let profileSigningPublicKeyBase64 = "iiOb4sGQkFqJbPGwQ/vq/YuA8cFfe/8c6UU26PnyHSw="

    static var profileSigningPublicKey: Data {
        Data(base64Encoded: profileSigningPublicKeyBase64) ?? Data()
    }

    private static let currentResolution: Resolution = resolve(
        bundleIdentifier: Bundle.main.bundleIdentifier,
        environment: ProcessInfo.processInfo.environment,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
        publicKey: Data(base64Encoded: profileSigningPublicKeyBase64) ?? Data(),
        managedConfiguration: ManagedEnterprisePolicy.currentResolution)

    /// The standard per-user location managed by Settings. Keeping this calculation shared with
    /// launch-time resolution prevents an imported profile from being written somewhere the app
    /// will not read on its next launch.
    static func installedProfileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let supportDirectory = environment["MECHANICIAN_SUPPORT_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(
                "Library/Application Support/Mechanician", isDirectory: true)
        return supportDirectory.appendingPathComponent(profileFileName, isDirectory: false)
    }

    /// Validates and installs a signed profile atomically. Validation happens before the existing
    /// profile is touched, so a malformed replacement cannot disable a working configuration.
    @discardableResult
    static func installSignedProfile(
        _ data: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        publicKey: Data = profileSigningPublicKey,
        fileManager: FileManager = .default
    ) throws -> TenantProfile {
        let profile = try loadSignedProfile(data, publicKey: publicKey)
        let destination = installedProfileURL(
            environment: environment, homeDirectory: homeDirectory)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        return profile
    }

    static func loadInstalledProfile(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        publicKey: Data = profileSigningPublicKey,
        fileManager: FileManager = .default
    ) throws -> TenantProfile? {
        let url = installedProfileURL(environment: environment, homeDirectory: homeDirectory)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try loadSignedProfile(
            Data(contentsOf: url, options: [.mappedIfSafe]), publicKey: publicKey)
    }

    static func removeInstalledProfile(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws {
        let url = installedProfileURL(environment: environment, homeDirectory: homeDirectory)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// Resolves an explicit override or the standard per-user profile location. Raw SwiftPM/XCTest
    /// executables do not probe the user's real Application Support folder unless the override is
    /// explicitly set, keeping tests and developer tools hermetic.
    static func resolve(
        bundleIdentifier: String?,
        environment: [String: String],
        homeDirectory: URL,
        publicKey: Data,
        managedConfiguration: ManagedEnterprisePolicy.Resolution = .unmanaged
    ) -> Resolution {
        if let error = managedConfiguration.error {
            return Resolution(profile: .default, error: error, managedByMDM: true)
        }
        let managedPolicy = managedConfiguration.policy
        let applyOverrides = managedPolicy?.allowLocalConfigurationOverrides ?? true

        // Exact signed envelope bytes can travel inside the forced MDM preference. They remain
        // signature-checked here, but never need to be copied into Application Support or imported
        // through Settings.
        if let data = managedPolicy?.signedProfile {
            do {
                let signed = try loadSignedProfile(data, publicKey: publicKey)
                let effective: TenantProfile
                if applyOverrides {
                    effective = ManagedConfigurationOverrides.load(
                        environment: environment, homeDirectory: homeDirectory)
                        .applied(to: signed)
                } else {
                    effective = signed
                }
                if let error = managedProviderConfigurationError(
                    policy: managedPolicy, profile: effective) {
                    return Resolution(
                        profile: .default, error: error, managedByMDM: true)
                }
                return Resolution(
                    profile: effective,
                    signed: signed,
                    managedByMDM: true)
            } catch {
                return Resolution(
                    profile: .default,
                    error: "Mechanician could not load the enterprise profile supplied by MDM: "
                        + error.localizedDescription,
                    managedByMDM: true)
            }
        }

        let explicitPath = environment[profilePathEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExplicitPath = explicitPath?.isEmpty == false

        // Do not delete prohibited local state. Ignoring it for the managed launch makes a later
        // policy removal reversible without letting a file or launch environment bypass MDM.
        if managedPolicy?.allowLocalProfile == false {
            let effective: TenantProfile
            if applyOverrides {
                effective = ManagedConfigurationOverrides.load(
                    environment: environment, homeDirectory: homeDirectory)
                    .applied(to: .default)
            } else {
                effective = .default
            }
            if let error = managedProviderConfigurationError(
                policy: managedPolicy, profile: effective) {
                return Resolution(
                    profile: .default, error: error, managedByMDM: true)
            }
            return Resolution(
                profile: effective,
                signed: .default,
                managedByMDM: true)
        }

        let profileURL: URL
        if let explicitPath, !explicitPath.isEmpty {
            profileURL = URL(fileURLWithPath: explicitPath).standardizedFileURL
        } else {
            let isInstalledMechanician = bundleIdentifier == MechanicianEnvironment.baseBundleIdentifier
                || bundleIdentifier == MechanicianEnvironment.devBundleIdentifier
            guard isInstalledMechanician else {
                return Resolution(
                    profile: .default,
                    sourceURL: nil,
                    error: nil,
                    managedByMDM: managedPolicy != nil)
            }
            profileURL = installedProfileURL(
                environment: environment, homeDirectory: homeDirectory)
        }

        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            if !hasExplicitPath {
                // No published profile is the ORDINARY case, and it is exactly where a locally
                // authored configuration has to work — otherwise "create one from nothing" saves a
                // file that is then never read. Overrides are layered onto the empty profile.
                let effective: TenantProfile
                if applyOverrides {
                    effective = ManagedConfigurationOverrides.load(
                        environment: environment, homeDirectory: homeDirectory)
                        .applied(to: .default)
                } else {
                    effective = .default
                }
                if let error = managedProviderConfigurationError(
                    policy: managedPolicy, profile: effective) {
                    return Resolution(
                        profile: .default,
                        error: error,
                        managedByMDM: managedPolicy != nil)
                }
                return Resolution(
                    profile: effective,
                    signed: .default,
                    sourceURL: nil,
                    error: nil,
                    managedByMDM: managedPolicy != nil)
            }
            if hasExplicitPath {
                return Resolution(
                    profile: .default,
                    sourceURL: profileURL,
                    error: "The configured enterprise profile does not exist at \(profileURL.path).",
                    managedByMDM: managedPolicy != nil)
            }
            return Resolution(
                profile: .default,
                sourceURL: nil,
                error: nil,
                managedByMDM: managedPolicy != nil)
        }

        do {
            let data = try Data(contentsOf: profileURL, options: [.mappedIfSafe])
            let signed = try loadSignedProfile(data, publicKey: publicKey)
            let effective: TenantProfile
            if applyOverrides {
                effective = ManagedConfigurationOverrides.load(
                    environment: environment, homeDirectory: homeDirectory)
                    .applied(to: signed)
            } else {
                effective = signed
            }
            if let error = managedProviderConfigurationError(
                policy: managedPolicy, profile: effective) {
                return Resolution(
                    profile: .default,
                    sourceURL: profileURL,
                    error: error,
                    managedByMDM: managedPolicy != nil)
            }
            return Resolution(
                profile: effective,
                signed: signed,
                sourceURL: profileURL,
                error: nil,
                managedByMDM: managedPolicy != nil)
        } catch {
            return Resolution(
                profile: .default,
                sourceURL: profileURL,
                error: "Mechanician could not load the enterprise profile at \(profileURL.path): "
                    + error.localizedDescription,
                managedByMDM: managedPolicy != nil)
        }
    }

    private static func managedProviderConfigurationError(
        policy: ManagedEnterprisePolicy?,
        profile: TenantProfile
    ) -> String? {
        guard let policy else { return nil }
        if policy.allowedProviderAccesses != nil {
            let available = ModelAccess.builtInCases + profile.enterpriseAccesses
            guard !policy.filteredProviderAccesses(available).isEmpty else {
                return "The managed enterprise policy does not allow any provider configured in this version of Mechanician."
            }
        }
        if !policy.allowUserConfiguredExtensions {
            guard let data = try? JSONEncoder().encode(profile.extensions.managedServers),
                  data.count <= ManagedEnterprisePolicy.maximumManagedExtensionServerBytes else {
                return "The managed enterprise profile contains too much managed extension server configuration."
            }
        }
        return nil
    }

    /// Verifies the envelope before decoding any profile values into runtime policy. The signature
    /// covers canonical JSON for `{documentVersion, profile}` and excludes only `signature`.
    static func loadSignedProfile(_ data: Data, publicKey: Data) throws -> TenantProfile {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any],
              Set(object.keys) == Set(["documentVersion", "profile", "signature"]),
              let profileObject = object["profile"] as? [String: Any]
        else {
            throw SignedProfileError.malformedEnvelope
        }

        let envelope: SignedEnvelope
        do {
            envelope = try JSONDecoder().decode(SignedEnvelope.self, from: data)
        } catch {
            throw SignedProfileError.malformedEnvelope
        }
        guard envelope.documentVersion == 1 else {
            throw SignedProfileError.unsupportedDocumentVersion(envelope.documentVersion)
        }
        guard let signature = Data(base64Encoded: envelope.signature), signature.count == 64 else {
            throw SignedProfileError.invalidSignature
        }

        let trustKey: Curve25519.Signing.PublicKey
        do {
            trustKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        } catch {
            throw SignedProfileError.invalidPublicKey
        }
        let payload = try canonicalSignedPayload(
            documentVersion: envelope.documentVersion,
            profileJSONObject: profileObject)
        guard trustKey.isValidSignature(signature, for: payload) else {
            throw SignedProfileError.invalidSignature
        }
        guard envelope.profile.schemaVersion == 1 else {
            throw SignedProfileError.unsupportedProfileSchema(envelope.profile.schemaVersion)
        }
        guard !envelope.profile.isDefault else {
            throw SignedProfileError.reservedTenantId
        }
        let vertexRoutes = envelope.profile.routes.filter { $0.adapter == "claude-vertex" }
        guard vertexRoutes.count <= 1,
              vertexRoutes.allSatisfy({ route in
                  guard let vertex = route.vertex else { return false }
                  return !route.routeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !vertex.projectId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !vertex.region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              })
        else {
            throw SignedProfileError.invalidRouteConfiguration
        }
        // Bound the shape, not the vocabulary. This used to require membership in a fixed set, which
        // meant an administrator who declared an effort level shipped after this build had their
        // ENTIRE profile rejected — every route, every model, the whole managed lane gone, over one
        // string. A malformed name is still refused; an unfamiliar one is carried.
        let hasInvalidModel = envelope.profile.routes.flatMap(\.models).contains { model in
            let declared = model.supportedEfforts
            return declared.contains(where: { !EffortLevels.isWellFormed($0) })
                || Set(declared).count != declared.count
        }
        guard !hasInvalidModel else {
            throw SignedProfileError.invalidModelConfiguration
        }
        guard envelope.profile.extensions.managedServers.allSatisfy({ server in
            server.command == nil && server.args == nil && server.env == nil
        }) else {
            throw SignedProfileError.executableConfigurationNotAllowed
        }
        guard validManagedServers(envelope.profile.extensions.managedServers) else {
            throw SignedProfileError.invalidManagedServerConfiguration
        }
        return envelope.profile.sanitizedForStandardApp()
    }

    /// Keep signed declarations and the daemon's effective managed-only set identical. Silently
    /// skipping one malformed declaration would make a restrictive profile appear active while a
    /// required server was absent from every turn.
    private static func validManagedServers(_ servers: [ManagedServer]) -> Bool {
        guard servers.count <= 256 else { return false }
        let builtInServerNames: Set<String> = [
            "artifacts", "automation", "computer", "ask", "provider_access", "shortcuts",
            "capabilities", "dev", "waitmode", "scheduler", "help",
        ]
        // Claude normalizes punctuation in MCP names to `_` when it constructs tool identifiers.
        // Require the signed name to already be canonical so `provider.access` cannot shadow the
        // built-in `provider_access`, and two distinct declarations cannot normalize together.
        let canonicalNameScalars = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        var names = Set<String>()
        for server in servers {
            let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name == server.name,
                  !name.isEmpty,
                  name.utf16.count <= 160,
                  name.unicodeScalars.allSatisfy(canonicalNameScalars.contains),
                  !name.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\t" }),
                  !["__proto__", "prototype", "constructor"].contains(name),
                  !builtInServerNames.contains(where: {
                      name == $0 || name == $0 + "_" || name.hasPrefix($0 + "__")
                  }),
                  names.insert(name).inserted,
                  server.transport == "http" || server.transport == "sse",
                  let rawURL = server.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawURL.isEmpty,
                  let components = URLComponents(string: rawURL),
                  components.scheme?.lowercased() == "https",
                  components.host?.isEmpty == false,
                  components.user == nil,
                  components.password == nil,
                  let normalizedURL = components.url?.absoluteString,
                  normalizedURL.utf16.count <= 4_096,
                  server.networkScope == nil
                    || server.networkScope == "public"
                    || server.networkScope == "vpnOnly"
            else {
                return false
            }
        }
        return true
    }

    /// Shared canonicalization contract for the app, tests, and the release signing helper.
    static func canonicalSignedPayload(
        documentVersion: Int,
        profileJSONObject: [String: Any]
    ) throws -> Data {
        let payload: [String: Any] = [
            "documentVersion": documentVersion,
            "profile": profileJSONObject,
        ]
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw SignedProfileError.malformedEnvelope
        }
        return try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Enterprise configuration can select audited routes and extension policy, but it cannot turn
    /// one Mechanician binary into a differently named/branded app or alter its update channel.
    ///
    /// `update` is reduced rather than dropped. The profile revision remains meaningful even when
    /// there is deliberately no network feed, while ``Update/profileFeedURL`` and
    /// ``Update/profileUpdateMode`` let a signed deployment offer either automatic or explicit-only
    /// checks. The dangerous half — the app's own Sparkle `feedURL` and `publicEDKey` — stays
    /// stripped, and a fetched document is still verified against the same embedded key as an
    /// imported one.
    private func sanitizedForStandardApp() -> TenantProfile {
        var sanitized = self
        sanitized.displayName = TenantProfile.default.displayName
        sanitized.bundleIdentifier = nil
        sanitized.branding = TenantProfile.default.branding
        if let update,
           update.profileFeedURL != nil
                || update.profileUpdateMode != nil
                || update.revision != nil {
            sanitized.update = Update(
                profileFeedURL: update.profileFeedURL,
                profileUpdateMode: update.profileUpdateMode,
                revision: update.revision)
        } else {
            sanitized.update = nil
        }
        sanitized.portal = nil
        return sanitized
    }
}
