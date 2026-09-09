import Foundation

/// Exact, non-secret proof obligation created whenever an MCP credential may have changed.
/// `changeId` is the generation. The provider route and account identity live in the ledger key;
/// `serverID` additionally prevents a renamed/replaced configured row from inheriting the claim.
struct MCPReadinessClaim: Codable, Equatable, Hashable {
    enum Source: String, Codable {
        case configured
        case providerConnector
    }

    var name: String
    var changeId: String
    var source: Source
    var serverID: UUID? = nil
    var accountInstanceID: UUID
    var routeIdentity: String = "legacy"

    private enum CodingKeys: String, CodingKey {
        case name, changeId, source, serverID, accountInstanceID, routeIdentity
    }

    init(
        name: String,
        changeId: String,
        source: Source,
        serverID: UUID? = nil,
        accountInstanceID: UUID,
        routeIdentity: String = "legacy"
    ) {
        self.name = name
        self.changeId = changeId
        self.source = source
        self.serverID = serverID
        self.accountInstanceID = accountInstanceID
        self.routeIdentity = routeIdentity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        changeId = try container.decode(String.self, forKey: .changeId)
        source = try container.decode(Source.self, forKey: .source)
        serverID = try container.decodeIfPresent(UUID.self, forKey: .serverID)
        accountInstanceID = try container.decode(UUID.self, forKey: .accountInstanceID)
        routeIdentity = try container.decodeIfPresent(String.self, forKey: .routeIdentity)
            ?? "legacy"
    }

    var wireValue: [String: Any] {
        var value: [String: Any] = [
            "name": name,
            "changeId": changeId,
            "source": source.rawValue,
            "accountInstanceId": accountInstanceID.uuidString.lowercased(),
            "routeIdentity": routeIdentity,
        ]
        if let serverID { value["serverId"] = serverID.uuidString.lowercased() }
        return value
    }
}

/// A write-ahead authorization attempt is persisted before the daemon may touch a provider's
/// credential store. Cancel is advisory: configured OAuth setup can already have removed an old
/// token, and a provider-owned browser flow can still finish after its request route is retired.
struct MCPPendingAuthorizationAttempt: Codable, Equatable, Hashable {
    enum Operation: String, Codable {
        case authorize
        case reauthorize
        case clear
    }

    var id: String
    var name: String
    var source: MCPReadinessClaim.Source
    var operation: Operation
    var serverID: UUID? = nil
    var accountInstanceID: UUID
    var routeIdentity: String = "legacy"
    var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, name, source, operation, serverID, accountInstanceID, routeIdentity, createdAt
    }

    init(
        id: String,
        name: String,
        source: MCPReadinessClaim.Source,
        operation: Operation,
        serverID: UUID? = nil,
        accountInstanceID: UUID,
        routeIdentity: String = "legacy",
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.operation = operation
        self.serverID = serverID
        self.accountInstanceID = accountInstanceID
        self.routeIdentity = routeIdentity
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decode(MCPReadinessClaim.Source.self, forKey: .source)
        operation = try container.decode(Operation.self, forKey: .operation)
        serverID = try container.decodeIfPresent(UUID.self, forKey: .serverID)
        accountInstanceID = try container.decode(UUID.self, forKey: .accountInstanceID)
        routeIdentity = try container.decodeIfPresent(String.self, forKey: .routeIdentity)
            ?? "legacy"
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

/// A corrupt element in extensions.json must cost one pending MCP record, not the complete
/// extensions authority. The enclosing ledgers additionally validate decoded values before use.
private struct FailableMCPRecord<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private struct MCPAccessCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

enum MCPCredentialActivationPhase: String {
    case activating
    case ready
    case cleared
    case failed
}

struct MCPPostAuthorizationTransition {
    struct Effect: Equatable {
        var retireSessions: Bool
        var createReadiness: Bool
        var retireReadiness: Bool
        var resolveAttempt: Bool
        var authorized: Bool
    }

    static func effect(for phase: MCPCredentialActivationPhase) -> Effect {
        switch phase {
        case .activating:
            return Effect(
                retireSessions: true, createReadiness: false, retireReadiness: false,
                resolveAttempt: false, authorized: false)
        case .ready:
            return Effect(
                retireSessions: true, createReadiness: true, retireReadiness: false,
                resolveAttempt: true, authorized: true)
        case .cleared:
            return Effect(
                retireSessions: true, createReadiness: false, retireReadiness: true,
                resolveAttempt: true, authorized: false)
        case .failed:
            return Effect(
                retireSessions: true, createReadiness: false, retireReadiness: false,
                resolveAttempt: false, authorized: false)
        }
    }
}

/// Durable route-scoped handoff from the window that observed/initiated a credential mutation to
/// whichever window (or later app process) owns the first real provider query. No secret material
/// is stored. Decoding the legacy string-only shape is intentionally supported so an intermediate
/// dogfood cannot strand its sidecar; those rows become fresh generations and fail closed.
struct MCPPendingReadinessLedger: Codable, Equatable {
    private var byAccess: [String: [MCPReadinessClaim]] = [:]

    func claims(for access: ModelAccess) -> [MCPReadinessClaim] {
        byAccess[access.rawValue] ?? []
    }

    func names(for access: ModelAccess) -> [String] {
        claims(for: access).map(\.name)
    }

    mutating func mark(_ claim: MCPReadinessClaim, for access: ModelAccess) -> Bool {
        guard Self.valid(claim) else { return false }
        let key = access.rawValue
        var claims = byAccess[key] ?? []
        if let index = claims.firstIndex(where: { existing in
            if let serverID = claim.serverID { return existing.serverID == serverID }
            return existing.source == claim.source && existing.name == claim.name
        }) {
            guard claims[index] != claim else { return false }
            claims[index] = claim
        } else {
            claims.append(claim)
        }
        byAccess[key] = claims.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.changeId < $1.changeId
        }
        return true
    }

    mutating func resolve(_ claim: MCPReadinessClaim, for access: ModelAccess) -> Bool {
        let key = access.rawValue
        guard var claims = byAccess[key], claims.contains(claim) else { return false }
        claims.removeAll { $0 == claim }
        byAccess[key] = claims.isEmpty ? nil : claims
        return true
    }

    mutating func renameConfiguredServer(
        id: UUID, to name: String, for access: ModelAccess
    ) -> Bool {
        let key = access.rawValue
        guard var claims = byAccess[key],
              let index = claims.firstIndex(where: { $0.serverID == id }) else { return false }
        claims[index].name = name
        byAccess[key] = claims
        return true
    }

    mutating func retireConfiguredServer(id: UUID, for access: ModelAccess) -> Bool {
        let key = access.rawValue
        guard var claims = byAccess[key], claims.contains(where: { $0.serverID == id })
        else { return false }
        claims.removeAll { $0.serverID == id }
        byAccess[key] = claims.isEmpty ? nil : claims
        return true
    }

    mutating func retireIdentity(
        source: MCPReadinessClaim.Source,
        serverID: UUID?,
        name: String,
        for access: ModelAccess
    ) -> Bool {
        let key = access.rawValue
        guard var claims = byAccess[key] else { return false }
        let matches: (MCPReadinessClaim) -> Bool = { claim in
            guard claim.source == source else { return false }
            if source == .configured { return serverID != nil && claim.serverID == serverID }
            return claim.name == name
        }
        guard claims.contains(where: matches) else { return false }
        claims.removeAll(where: matches)
        byAccess[key] = claims.isEmpty ? nil : claims
        return true
    }

    mutating func retireAll(for access: ModelAccess) -> Bool {
        byAccess.removeValue(forKey: access.rawValue) != nil
    }

    mutating func normalizeLegacyClaims(
        for access: ModelAccess,
        accountInstanceID: UUID,
        routeIdentity: String,
        configuredServerID: (String) -> UUID?
    ) -> Bool {
        let key = access.rawValue
        guard var claims = byAccess[key] else { return false }
        var changed = false
        for index in claims.indices where claims[index].routeIdentity == "legacy" {
            let serverID = configuredServerID(claims[index].name)
            claims[index].source = serverID == nil ? .providerConnector : .configured
            claims[index].serverID = serverID
            claims[index].accountInstanceID = accountInstanceID
            claims[index].routeIdentity = routeIdentity
            changed = true
        }
        if changed { byAccess[key] = claims }
        return changed
    }

    private static func valid(_ claim: MCPReadinessClaim) -> Bool {
        !claim.name.isEmpty && claim.name.utf8.count <= 500
            && !claim.changeId.isEmpty && claim.changeId.utf8.count <= 500
            && !claim.routeIdentity.isEmpty && claim.routeIdentity.utf8.count <= 500
            && ((claim.source == .configured && claim.serverID != nil)
                || (claim.source == .providerConnector && claim.serverID == nil))
    }

    private enum CodingKeys: String, CodingKey { case byAccess }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let claimsContainer = try? container.nestedContainer(
            keyedBy: MCPAccessCodingKey.self, forKey: .byAccess
        ) {
            var decoded: [String: [MCPReadinessClaim]] = [:]
            for key in claimsContainer.allKeys {
                if let legacyNames = try? claimsContainer.decode([String].self, forKey: key) {
                    let claims = legacyNames.filter {
                        !$0.isEmpty && $0.utf8.count <= 500
                    }.map {
                        MCPReadinessClaim(
                            name: $0,
                            changeId: UUID().uuidString,
                            source: .providerConnector,
                            accountInstanceID: UUID(),
                            routeIdentity: "legacy")
                    }
                    if !claims.isEmpty { decoded[key.stringValue] = claims }
                    continue
                }
                guard let records = try? claimsContainer.decode(
                    [FailableMCPRecord<MCPReadinessClaim>].self, forKey: key
                ) else { continue }
                let valid = records.compactMap(\.value).filter(Self.valid)
                if !valid.isEmpty { decoded[key.stringValue] = valid }
            }
            byAccess = decoded
            return
        }
        byAccess = [:]
    }
}

/// Persisted write-ahead intent, route/account scoped. It remains after Cancel or ambiguous
/// failure and seeds fresh-session fencing and automatic reconciliation after relaunch.
struct MCPPendingAuthorizationLedger: Codable, Equatable {
    private var byAccess: [String: [MCPPendingAuthorizationAttempt]] = [:]

    func attempts(for access: ModelAccess) -> [MCPPendingAuthorizationAttempt] {
        byAccess[access.rawValue] ?? []
    }

    mutating func begin(_ attempt: MCPPendingAuthorizationAttempt, for access: ModelAccess) -> Bool {
        guard Self.valid(attempt) else { return false }
        let key = access.rawValue
        var attempts = byAccess[key] ?? []
        // One unresolved mutation owns a provider route. Provider connector control and Codex's
        // shared config/credential generation are route-wide; overlapping browser flows would make
        // a later completion impossible to attribute safely.
        guard attempts.isEmpty else { return false }
        attempts.append(attempt)
        byAccess[key] = attempts
        return true
    }

    mutating func resolve(id: String, for access: ModelAccess) -> Bool {
        let key = access.rawValue
        guard var attempts = byAccess[key], attempts.contains(where: { $0.id == id }) else {
            return false
        }
        attempts.removeAll { $0.id == id }
        byAccess[key] = attempts.isEmpty ? nil : attempts
        return true
    }

    mutating func renameConfiguredServer(
        id: UUID, to name: String, for access: ModelAccess
    ) -> Bool {
        let key = access.rawValue
        guard var attempts = byAccess[key],
              let index = attempts.firstIndex(where: { $0.serverID == id }) else { return false }
        attempts[index].name = name
        byAccess[key] = attempts
        return true
    }

    mutating func retireConfiguredServer(id: UUID, for access: ModelAccess) -> Bool {
        let key = access.rawValue
        guard var attempts = byAccess[key], attempts.contains(where: { $0.serverID == id })
        else { return false }
        attempts.removeAll { $0.serverID == id }
        byAccess[key] = attempts.isEmpty ? nil : attempts
        return true
    }

    mutating func retireAll(for access: ModelAccess) -> Bool {
        byAccess.removeValue(forKey: access.rawValue) != nil
    }

    private static func valid(_ attempt: MCPPendingAuthorizationAttempt) -> Bool {
        !attempt.id.isEmpty && attempt.id.utf8.count <= 500
            && !attempt.name.isEmpty && attempt.name.utf8.count <= 500
            && !attempt.routeIdentity.isEmpty && attempt.routeIdentity.utf8.count <= 500
            && ((attempt.source == .configured && attempt.serverID != nil)
                || (attempt.source == .providerConnector && attempt.serverID == nil))
    }

    private enum CodingKeys: String, CodingKey { case byAccess }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let attemptsContainer = try? container.nestedContainer(
            keyedBy: MCPAccessCodingKey.self, forKey: .byAccess
        ) else {
            byAccess = [:]
            return
        }
        var decoded: [String: [MCPPendingAuthorizationAttempt]] = [:]
        for key in attemptsContainer.allKeys {
            guard let records = try? attemptsContainer.decode(
                [FailableMCPRecord<MCPPendingAuthorizationAttempt>].self, forKey: key
            ) else { continue }
            // Retain at most the oldest valid write-ahead owner per route. A corrupt sidecar must
            // not accidentally authorize overlap, and an impossible duplicate fails conservatively.
            let valid = records.compactMap(\.value).filter(Self.valid).sorted {
                $0.createdAt < $1.createdAt
            }
            if let first = valid.first { decoded[key.stringValue] = [first] }
        }
        byAccess = decoded
    }
}

struct MCPReadinessProofCommitLedger {
    private var byTurnID: [String: [MCPReadinessClaim]] = [:]

    mutating func stage(turnID: String, claim: MCPReadinessClaim) -> Bool {
        guard !turnID.isEmpty else { return false }
        var claims = byTurnID[turnID] ?? []
        guard !claims.contains(claim) else { return false }
        claims.append(claim)
        byTurnID[turnID] = claims
        return true
    }

    mutating func takeForSession(turnID: String) -> [MCPReadinessClaim] {
        byTurnID.removeValue(forKey: turnID) ?? []
    }

    mutating func discard(turnID: String) { byTurnID[turnID] = nil }
}

/// A provider session created before OAuth cannot acquire the new tool schema. Remember the exact
/// old turns, then take their transcript only at terminal time so post-auth deltas are included.
struct MCPPostAuthorizationReplayBoundary {
    private var affectedTurnIDs = Set<String>()

    var isEmpty: Bool { affectedTurnIDs.isEmpty }
    mutating func mark(turnID: String) {
        guard !turnID.isEmpty else { return }
        affectedTurnIDs.insert(turnID)
    }
    func contains(turnID: String) -> Bool { affectedTurnIDs.contains(turnID) }
    mutating func terminalReplay(
        turnID: String, entries: [TranscriptEntry]
    ) -> [TranscriptEntry]? {
        guard affectedTurnIDs.remove(turnID) != nil else { return nil }
        return entries
    }
    mutating func discard(turnIDs: Set<String>) { affectedTurnIDs.subtract(turnIDs) }
}
