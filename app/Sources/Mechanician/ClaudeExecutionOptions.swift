import Foundation

/// Claude-only, conversation-scoped execution preferences and the dev gate that can expose them.
///
/// Three rules shape everything here:
///
/// 1. **Intent and effect are separate.** A persisted preference is the user's intent. Whether it is
///    actually sent depends on the route and on whether this build implements the feature. A
///    preference that cannot be honored is withheld from the request, never erased from disk — so
///    losing an entitlement (or opening a dev-build conversation in a release build) degrades to the
///    baseline instead of destroying what the user chose.
/// 2. **Default means silent.** An all-default preference set contributes NO request payload, so a
///    conversation that has never touched a Claude preference produces byte-identical daemon
///    requests to the release that predates this type.
/// 3. **Unknown persisted values disable, never quarantine.** Every decode path here falls back to a
///    default rather than throwing. A single unreadable preference must not cost the conversation.

/// One preview surface from the Opus 5 platform. Raw values are the wire contract shared with
/// `agentd/src/claude-turn-options.mjs`.
enum ClaudeExperimentalFeature: String, Codable, Equatable, Hashable, CaseIterable {
    case advisor
    case fast
    case refusalFallback
}

/// Which preview surfaces this build may expose.
///
/// The gate is COMPILE-TIME first: a release build resolves to an empty set no matter what the
/// launch environment says, so an inherited `MECHANICIAN_ENABLE_CLAUDE_EXPERIMENTS` from a developer
/// shell (or a parent Mechanician process) cannot switch on a billed preview behind the user's back.
/// In a debug build the same variable names the features to expose.
struct ClaudeExperiments: Equatable {
    static let environmentKey = "MECHANICIAN_ENABLE_CLAUDE_EXPERIMENTS"

    var enabled: Set<ClaudeExperimentalFeature>

    static let none = ClaudeExperiments(enabled: [])

    static let current = ClaudeExperiments(environment: ProcessInfo.processInfo.environment)

    init(enabled: Set<ClaudeExperimentalFeature>) {
        self.enabled = enabled
    }

    init(environment: [String: String]) {
        #if DEBUG
        self.enabled = Self.parse(environment[Self.environmentKey])
        #else
        // Deliberately ignores the environment entirely. See the type comment.
        self.enabled = []
        #endif
    }

    static func parse(_ raw: String?) -> Set<ClaudeExperimentalFeature> {
        guard let raw, !raw.isEmpty else { return [] }
        return Set(raw.split(separator: ",").compactMap {
            ClaudeExperimentalFeature(rawValue: $0.trimmingCharacters(in: .whitespaces))
        })
    }

    func allows(_ feature: ClaudeExperimentalFeature) -> Bool { enabled.contains(feature) }

    /// The value to hand `agentd`, or nil when nothing is enabled. The daemon applies the same
    /// fail-closed parsing, so the two sides cannot drift into disagreement about what is on.
    var daemonEnvironmentValue: String? {
        guard !enabled.isEmpty else { return nil }
        return ClaudeExperimentalFeature.allCases
            .filter(enabled.contains)
            .map(\.rawValue)
            .joined(separator: ",")
    }
}

enum ClaudeAdvisorPreference: String, Codable, Equatable, Hashable, CaseIterable {
    case off
    case automatic

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = ClaudeAdvisorPreference(rawValue: raw) ?? .off
    }
}

enum ClaudeSpeedPreference: String, Codable, Equatable, Hashable, CaseIterable {
    case standard
    case fast

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = ClaudeSpeedPreference(rawValue: raw) ?? .standard
    }
}

/// Classifier-refusal fallback. Kept structurally distinct from operational (overload/unavailable)
/// fallback: the two are different product concepts even where a provider option is shared, and
/// conflating them would let an outage present itself as a safety refusal.
enum ClaudeRefusalFallbackPreference: Codable, Equatable, Hashable {
    case off
    case providerDefault
    case model(String)

    enum CodingKeys: String, CodingKey {
        case mode
        case model
    }

    var mode: String {
        switch self {
        case .off: return "off"
        case .providerDefault: return "providerDefault"
        case .model: return "model"
        }
    }

    var modelID: String? {
        if case .model(let id) = self { return id }
        return nil
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
              let mode = ((try? container.decodeIfPresent(String.self, forKey: .mode)) ?? nil) else {
            self = .off
            return
        }
        switch mode {
        case "providerDefault":
            self = .providerDefault
        case "model":
            let id = ((try? container.decodeIfPresent(String.self, forKey: .model)) ?? nil) ?? ""
            // A "model" mode with no model is not actionable; fail closed rather than send a request
            // the daemon would reject.
            self = id.isEmpty ? .off : .model(id)
        default:
            self = .off
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        if let modelID { try container.encode(modelID, forKey: .model) }
    }
}

/// Persisted alongside one conversation. Copied into the turn snapshot at send time, so editing a
/// control while a turn runs configures the NEXT turn and can never rewrite one in flight.
struct ClaudeSessionPreferences: Codable, Equatable, Hashable {
    var advisor: ClaudeAdvisorPreference = .off
    var speed: ClaudeSpeedPreference = .standard
    var refusalFallback: ClaudeRefusalFallbackPreference = .off

    enum CodingKeys: String, CodingKey {
        case advisor
        case speed
        case refusalFallback
    }

    init(
        advisor: ClaudeAdvisorPreference = .off,
        speed: ClaudeSpeedPreference = .standard,
        refusalFallback: ClaudeRefusalFallbackPreference = .off
    ) {
        self.advisor = advisor
        self.speed = speed
        self.refusalFallback = refusalFallback
    }

    /// Every field is individually tolerant: an unreadable one falls back to its default instead of
    /// failing the enclosing conversation decode.
    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        advisor = Self.tolerant(container, .advisor, default: .off)
        speed = Self.tolerant(container, .speed, default: .standard)
        refusalFallback = Self.tolerant(container, .refusalFallback, default: .off)
    }

    private static func tolerant<T: Decodable>(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys,
        default defaultValue: T
    ) -> T {
        ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? defaultValue
    }

    var isDefault: Bool { self == ClaudeSessionPreferences() }
}

extension ClaudeSessionPreferences {
    /// Routes where the Opus 5 preview surfaces are documented as available.
    ///
    /// Answered from `ProviderFacts.routesWithoutPreviewSurfaces`, which the daemon's own gate reads
    /// too. The two used to be independent lists with comments telling the reader to keep them
    /// matched, and they did not: this side withheld the surfaces on Vertex AND Bedrock while the
    /// daemon named only Vertex, so the daemon's last gate before the wire was open on Bedrock and
    /// Foundry. Managed clouds lag first-party feature availability; each stays withheld until it is
    /// verified against that backend, and now that decision is recorded once.
    static func routeSupportsPreviewSurfaces(_ access: ModelAccess) -> Bool {
        guard access.maker == .anthropic else { return false }
        return !ProviderFacts.routesWithoutPreviewSurfaces.contains(access.daemonAuthMode)
    }

    /// What can actually be sent on this route in this build. Withheld preferences remain persisted.
    func effective(for access: ModelAccess, experiments: ClaudeExperiments) -> ClaudeSessionPreferences {
        guard Self.routeSupportsPreviewSurfaces(access) else { return ClaudeSessionPreferences() }
        return ClaudeSessionPreferences(
            advisor: experiments.allows(.advisor) ? advisor : .off,
            speed: experiments.allows(.fast) ? speed : .standard,
            refusalFallback: experiments.allows(.refusalFallback) ? refusalFallback : .off)
    }

    /// The nested `claude` block of a `send` request, or nil when there is nothing to say.
    ///
    /// Returning nil for the default case is the contract that keeps this whole slice a no-op: the
    /// daemon builds identical SDK options for an absent block.
    func requestPayload(
        for access: ModelAccess,
        experiments: ClaudeExperiments = .current
    ) -> [String: Any]? {
        let effective = effective(for: access, experiments: experiments)
        guard !effective.isDefault else { return nil }

        var payload: [String: Any] = [:]
        if effective.advisor != .off {
            payload["advisor"] = ["mode": effective.advisor.rawValue]
        }
        if effective.speed != .standard {
            payload["speed"] = effective.speed.rawValue
        }
        if effective.refusalFallback != .off {
            var fallback: [String: Any] = ["mode": effective.refusalFallback.mode]
            if let modelID = effective.refusalFallback.modelID { fallback["model"] = modelID }
            payload["refusalFallback"] = fallback
        }
        return payload
    }
}
