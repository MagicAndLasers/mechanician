import CryptoKit
import Foundation

/// Organization policy delivered to Mechanician's application preference domain by macOS MDM.
///
/// The entire document must be a *forced* managed preference. A value written by the person, a
/// script, or a manually installed ordinary preference is ignored. This distinction makes the
/// source suitable for enforcement, while the separately signed tenant profile remains the trust
/// boundary for provider endpoints and managed catalogs.
struct ManagedEnterprisePolicy: Equatable {
    static let preferenceKey = "MechanicianManagedConfiguration"
    static let supportedSchemaVersion = 1
    static let maximumDocumentBytes = 1_048_576
    static let maximumManagedExtensionServerBytes = 65_536

    enum UpdateAuthority: String, Codable {
        case sparkle
        case mdm
    }

    struct Resolution: Equatable {
        var policy: ManagedEnterprisePolicy?
        var error: String?

        static let unmanaged = Resolution(policy: nil, error: nil)
    }

    private struct Document: Decodable {
        var schemaVersion: Int
        var signedProfile: Data?
        var policyIdentifier: String?
        var revision: Int?
        var policy: PolicyDocument?
    }

    /// Every field is optional so an administrator can adopt one restriction without inheriting
    /// unrelated product choices. Missing fields preserve ordinary Mechanician behavior.
    private struct PolicyDocument: Decodable {
        var allowedProviderAccesses: [String]?
        var maximumInteractivePermissionMode: String?
        var allowUnattendedTasks: Bool?
        var allowLocalProfile: Bool?
        var allowLocalConfigurationOverrides: Bool?
        var allowUserConfiguredExtensions: Bool?
        var allowPublicExtensionDiscovery: Bool?
        var updateAuthority: UpdateAuthority?
        var sparkleUpdateChannel: UpdateChannel?
        var sparkleAutomaticChecks: Bool?
        var minimumAppBuild: Int?
    }

    enum PolicyError: LocalizedError, Equatable {
        case malformedDocument
        case unknownField(String)
        case unsupportedSchemaVersion(Int)
        case invalidPolicyIdentifier
        case invalidRevision
        case oversizedSignedProfile
        case emptyProviderAllowlist
        case invalidProviderAccess(String)
        case invalidMaximumPermissionMode(String)
        case invalidMinimumAppBuild
        case incompatibleUpdateSettings

        var errorDescription: String? {
            switch self {
            case .malformedDocument:
                return "The managed enterprise policy is not a valid property-list dictionary."
            case .unknownField(let field):
                return "The managed enterprise policy contains an unknown schema version 1 field: \(field)."
            case .unsupportedSchemaVersion(let version):
                return "Managed enterprise policy schema version \(version) is not supported."
            case .invalidPolicyIdentifier:
                return "The managed enterprise policy identifier is invalid."
            case .invalidRevision:
                return "The managed enterprise policy revision must be a positive integer."
            case .oversizedSignedProfile:
                return "The signed profile in the managed enterprise policy is too large."
            case .emptyProviderAllowlist:
                return "The managed enterprise policy must allow at least one provider lane."
            case .invalidProviderAccess(let access):
                return "The managed enterprise policy contains an invalid provider lane identifier: \(access)."
            case .invalidMaximumPermissionMode(let mode):
                return "The managed enterprise policy names an unsupported permission ceiling: \(mode)."
            case .invalidMinimumAppBuild:
                return "The managed enterprise policy minimum app build must be a positive integer."
            case .incompatibleUpdateSettings:
                return "An MDM-owned update policy cannot also configure Sparkle update settings."
            }
        }
    }

    let schemaVersion: Int
    let signedProfile: Data?
    let policyIdentifier: String?
    let revision: Int?
    /// Raw strings intentionally retain future provider lanes. An older app treats them as
    /// unavailable instead of rejecting an otherwise forward-compatible policy document.
    let allowedProviderAccesses: Set<String>?
    let maximumInteractivePermissionMode: String?
    let allowUnattendedTasks: Bool
    let allowLocalProfile: Bool
    let allowLocalConfigurationOverrides: Bool
    let allowUserConfiguredExtensions: Bool
    let allowPublicExtensionDiscovery: Bool
    let updateAuthority: UpdateAuthority
    let sparkleUpdateChannel: UpdateChannel?
    let sparkleAutomaticChecks: Bool?
    let minimumAppBuild: Int?

    private static let currentResolutionStorage = resolve(defaults: .standard)

    static var current: ManagedEnterprisePolicy? { currentResolutionStorage.policy }
    static var startupError: String? { currentResolutionStorage.error }
    static var currentResolution: Resolution { currentResolutionStorage }
    static var isManaged: Bool { current != nil }

    static func resolve(
        defaults: UserDefaults,
        forcedOverride: Bool? = nil
    ) -> Resolution {
        guard defaults.object(forKey: preferenceKey) != nil else { return .unmanaged }
        let isForced = forcedOverride ?? defaults.objectIsForced(forKey: preferenceKey)
        guard isForced else { return .unmanaged }
        guard let dictionary = defaults.dictionary(forKey: preferenceKey),
              PropertyListSerialization.propertyList(dictionary, isValidFor: .binary),
              let data = try? PropertyListSerialization.data(
                  fromPropertyList: dictionary, format: .binary, options: 0),
              data.count <= maximumDocumentBytes,
              let document = try? PropertyListDecoder().decode(Document.self, from: data)
        else {
            return Resolution(policy: nil, error: PolicyError.malformedDocument.localizedDescription)
        }

        do {
            try validateKnownKeys(in: dictionary)
            return Resolution(policy: try validate(document), error: nil)
        } catch {
            return Resolution(policy: nil, error: error.localizedDescription)
        }
    }

    /// Schema v1 rejects unknown keys so an administrator typo cannot silently select a permissive
    /// default. A later product feature must bump `schemaVersion` before adding another field.
    private static func validateKnownKeys(in dictionary: [String: Any]) throws {
        let documentKeys: Set<String> = [
            "schemaVersion", "signedProfile", "policyIdentifier", "revision", "policy",
        ]
        if let unknown = dictionary.keys.first(where: { !documentKeys.contains($0) }) {
            throw PolicyError.unknownField(unknown)
        }
        guard let policyValue = dictionary["policy"] else { return }
        guard let policy = policyValue as? [String: Any] else { return }
        let policyKeys: Set<String> = [
            "allowedProviderAccesses",
            "maximumInteractivePermissionMode",
            "allowUnattendedTasks",
            "allowLocalProfile",
            "allowLocalConfigurationOverrides",
            "allowUserConfiguredExtensions",
            "allowPublicExtensionDiscovery",
            "updateAuthority",
            "sparkleUpdateChannel",
            "sparkleAutomaticChecks",
            "minimumAppBuild",
        ]
        if let unknown = policy.keys.first(where: { !policyKeys.contains($0) }) {
            throw PolicyError.unknownField("policy.\(unknown)")
        }
    }

    private static func validate(_ document: Document) throws -> ManagedEnterprisePolicy {
        guard document.schemaVersion == supportedSchemaVersion else {
            throw PolicyError.unsupportedSchemaVersion(document.schemaVersion)
        }
        let identifier = document.policyIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let identifier, identifier.isEmpty || identifier.count > 128
            || identifier.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            throw PolicyError.invalidPolicyIdentifier
        }
        if let revision = document.revision, revision < 1 { throw PolicyError.invalidRevision }
        if let signedProfile = document.signedProfile,
           signedProfile.count > maximumDocumentBytes {
            throw PolicyError.oversizedSignedProfile
        }

        let rawPolicy = document.policy
        let allowedProviderAccesses: Set<String>?
        if let rawLanes = rawPolicy?.allowedProviderAccesses {
            let normalized = Set(rawLanes.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })
            guard !normalized.isEmpty else { throw PolicyError.emptyProviderAllowlist }
            // This set crosses the Swift/Node process boundary as a comma-delimited value. Keep
            // unknown future lanes for forward compatibility, but constrain their identifiers so
            // one apparent lane cannot split into multiple daemon-authorized lanes.
            let safeScalars = CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            if let invalid = normalized.first(where: {
                $0.count > 128 || $0.unicodeScalars.contains(where: { !safeScalars.contains($0) })
            }) {
                throw PolicyError.invalidProviderAccess(invalid)
            }
            allowedProviderAccesses = normalized
        } else {
            allowedProviderAccesses = nil
        }

        let maximumPermissionMode: String?
        if let mode = rawPolicy?.maximumInteractivePermissionMode {
            guard ["plan", "default", "acceptEdits", "bypassPermissions"].contains(mode) else {
                throw PolicyError.invalidMaximumPermissionMode(mode)
            }
            maximumPermissionMode = mode
        } else {
            maximumPermissionMode = nil
        }

        if let minimumAppBuild = rawPolicy?.minimumAppBuild, minimumAppBuild < 1 {
            throw PolicyError.invalidMinimumAppBuild
        }
        let updateAuthority = rawPolicy?.updateAuthority ?? .sparkle
        if updateAuthority == .mdm,
           rawPolicy?.sparkleUpdateChannel != nil || rawPolicy?.sparkleAutomaticChecks != nil {
            throw PolicyError.incompatibleUpdateSettings
        }

        return ManagedEnterprisePolicy(
            schemaVersion: document.schemaVersion,
            signedProfile: document.signedProfile,
            policyIdentifier: identifier,
            revision: document.revision,
            allowedProviderAccesses: allowedProviderAccesses,
            maximumInteractivePermissionMode: maximumPermissionMode,
            allowUnattendedTasks: rawPolicy?.allowUnattendedTasks ?? true,
            allowLocalProfile: rawPolicy?.allowLocalProfile ?? true,
            allowLocalConfigurationOverrides: rawPolicy?.allowLocalConfigurationOverrides ?? true,
            allowUserConfiguredExtensions: rawPolicy?.allowUserConfiguredExtensions ?? true,
            allowPublicExtensionDiscovery: rawPolicy?.allowPublicExtensionDiscovery ?? true,
            updateAuthority: updateAuthority,
            sparkleUpdateChannel: rawPolicy?.sparkleUpdateChannel,
            sparkleAutomaticChecks: rawPolicy?.sparkleAutomaticChecks,
            minimumAppBuild: rawPolicy?.minimumAppBuild)
    }

    func allows(_ access: ModelAccess) -> Bool {
        let explicitlyAllowed = allowedProviderAccesses?.contains(access.rawValue) ?? true
        // Codex keeps provider-native plugin/MCP configuration in its own user-writable home. The
        // first managed-only release cannot truthfully prove that surface absent, so fail closed on
        // that lane instead of presenting a policy it does not enforce. Other Codex lanes remain
        // available whenever user extensions are allowed.
        if !allowUserConfiguredExtensions, access == .codexSubscription { return false }
        return explicitlyAllowed
    }

    func filteredProviderAccesses(_ accesses: [ModelAccess]) -> [ModelAccess] {
        accesses.filter(allows)
    }

    /// Plan mode is always available because it is more restrictive than every interactive mode.
    /// Other modes form an explicit risk ordering, so an administrator ceiling cannot be bypassed
    /// by a stale conversation or a direct daemon request that still carries an older value.
    func clampedPermissionMode(_ rawMode: String?) -> String {
        let mode = PermissionPresentation.normalized(rawMode)
        guard let maximumInteractivePermissionMode else { return mode }
        let rank = ["plan": 0, "default": 1, "acceptEdits": 2, "bypassPermissions": 3]
        guard let requested = rank[mode], let maximum = rank[maximumInteractivePermissionMode] else {
            return "plan"
        }
        return requested <= maximum ? mode : maximumInteractivePermissionMode
    }

    func allowsPermissionMode(_ mode: String) -> Bool {
        clampedPermissionMode(mode) == PermissionPresentation.normalized(mode)
    }

    func requiresNewerApp(currentBuild: Int) -> Bool {
        guard let minimumAppBuild else { return false }
        return currentBuild < minimumAppBuild
    }

    /// Unattended work includes scheduled tasks and automatic WaitFor polling/resume. The minimum
    /// build gate applies to those turns just as it does to a person pressing Send.
    func allowsUnattendedWork(currentBuild: Int = currentAppBuild) -> Bool {
        allowUnattendedTasks && !requiresNewerApp(currentBuild: currentBuild)
    }

    static var currentAppBuild: Int {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return raw.flatMap(Int.init) ?? 0
    }

    func turnBlockReason(for access: ModelAccess, currentBuild: Int = currentAppBuild) -> String? {
        if !allows(access) {
            return "This provider is blocked by your organization. Choose an allowed provider to continue."
        }
        if requiresNewerApp(currentBuild: currentBuild) {
            return "Your organization requires a newer version of Mechanician before new turns can run."
        }
        return nil
    }

    /// Secret-free generation identity for long-lived child processes. A policy edit must replace
    /// an installed scheduler even when the app build and signed provider route are unchanged.
    var runtimeIdentity: String {
        let signedProfileIdentity = signedProfile.map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        } ?? "no-signed-profile"
        return [
            policyIdentifier ?? "unidentified",
            revision.map(String.init) ?? "unversioned",
            signedProfileIdentity,
            allowedProviderAccesses?.sorted().joined(separator: ",") ?? "all-providers",
            maximumInteractivePermissionMode ?? "all-interactive-modes",
            allowUnattendedTasks ? "unattended" : "no-unattended",
            allowUserConfiguredExtensions ? "user-extensions" : "managed-extensions-only",
        ].joined(separator: "|")
    }
}
