import Foundation
import Combine

/// A non-secret, app-owned identity for one configured account instance. It deliberately does not
/// contain an email address, provider subject, credential, or credential digest. Credential changes
/// rotate this value so provider-derived state from an older account snapshot cannot be reused.
struct ProviderAccountInstanceID: RawRepresentable, Codable, Equatable, Hashable {
    var rawValue: UUID

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    init() {
        self.rawValue = UUID()
    }
}

/// Provider capability truth is workspace-policy scoped, not merely cwd scoped. `identity` is an
/// app-owned workspace/project identity (or the canonical cwd while that migration is incomplete),
/// and the revision changes whenever effective workspace policy changes.
struct ProviderCapabilityWorkspace: Codable, Equatable, Hashable {
    var identity: String
    var policyRevision: UInt64

    static let accountWide = ProviderCapabilityWorkspace(identity: "account", policyRevision: 0)
}

/// The complete ownership key for provider-derived capability state. A model id alone is unsafe:
/// the same id can exist on several access routes, accounts, and workspace policies.
struct ProviderCapabilityKey: Codable, Equatable, Hashable {
    var access: ModelAccess
    var accountInstanceID: ProviderAccountInstanceID
    var credentialEpoch: Int
    var modelID: String
    var workspace: ProviderCapabilityWorkspace
}

enum ProviderCapabilityAvailability: String, Codable, Equatable, Hashable {
    case available
    case unavailable
    case experimental
    case deprecated
    case unknown
}

/// Provider availability and Mechanician support are deliberately independent. A provider feature
/// must not become actionable merely because it exists upstream when this adapter cannot honor it.
enum MechanicianCapabilitySupport: String, Codable, Equatable, Hashable {
    case implemented
    case unimplemented
    case disabled
}

enum ProviderCapabilitySymmetry: String, Codable, Equatable, Hashable {
    case symmetric
    case partial
    case providerSpecific
    case unclassified
}

enum ProviderCapabilityEvidenceSource: String, Codable, Equatable, Hashable {
    case providerResponse
    case providerContract
    case adapterStatic
}

struct ProviderCapabilityEvidence: Codable, Equatable, Hashable {
    var source: ProviderCapabilityEvidenceSource
    var operation: String
    var revision: String?
}

/// One normalized capability. Unknown ids are retained as strings so newer provider evidence can be
/// decoded safely by an older Mechanician without enabling an unrecognized operation.
struct ProviderCapability: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var providerAvailability: ProviderCapabilityAvailability
    var mechanicianSupport: MechanicianCapabilitySupport
    var symmetry: ProviderCapabilitySymmetry
    var operation: String?
    var constraints: [String: String]
    var disclosures: [String: String]
    var evidence: ProviderCapabilityEvidence
}

struct ProviderCapabilityRequestTicket: Equatable, Hashable {
    var key: ProviderCapabilityKey
    var revision: UInt64
}

struct ProviderCapabilitySnapshot: Equatable {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    var phase: Phase
    var capabilities: [ProviderCapability]
    var adapterRevision: String?
    var sourceRevision: String?
    var rawEvidenceDigest: String?
    var updatedAt: Date?

    static let idle = ProviderCapabilitySnapshot(
        phase: .idle,
        capabilities: [],
        adapterRevision: nil,
        sourceRevision: nil,
        rawEvidenceDigest: nil,
        updatedAt: nil)
}

private struct ProviderCapabilityOwner: Equatable {
    var accountInstanceID: ProviderAccountInstanceID
    var credentialEpoch: Int
}

/// Process-wide, generation-safe capability cache. Window-owned runtimes may request the same
/// account/model/workspace concurrently; only the newest request for the exact key may publish.
/// Replacing an account or credential epoch invalidates every prior key for that access route.
@MainActor
final class ProviderCapabilityStore: ObservableObject {
    static let shared = ProviderCapabilityStore()

    @Published private(set) var snapshots: [ProviderCapabilityKey: ProviderCapabilitySnapshot] = [:]

    private var owners: [ModelAccess: ProviderCapabilityOwner] = [:]
    private var latestRequestRevisions: [ProviderCapabilityKey: UInt64] = [:]
    private var nextRequestRevision: UInt64 = 0

    init() {}

    func snapshot(for key: ProviderCapabilityKey) -> ProviderCapabilitySnapshot {
        snapshots[key] ?? .idle
    }

    func hasSnapshot(for access: ModelAccess) -> Bool {
        snapshots.keys.contains { $0.access == access }
    }

    /// Install the app-owned current account/credential boundary. A different account identity is
    /// authoritative regardless of its epoch; for the same identity, an older epoch is stale.
    @discardableResult
    func setCurrentOwner(
        access: ModelAccess,
        accountInstanceID: ProviderAccountInstanceID,
        credentialEpoch: Int
    ) -> Bool {
        let replacement = ProviderCapabilityOwner(
            accountInstanceID: accountInstanceID,
            credentialEpoch: credentialEpoch)
        if let current = owners[access] {
            if current.accountInstanceID == accountInstanceID,
               credentialEpoch < current.credentialEpoch {
                return false
            }
            if current == replacement { return true }
        }
        owners[access] = replacement
        snapshots = snapshots.filter { $0.key.access != access }
        latestRequestRevisions = latestRequestRevisions.filter { $0.key.access != access }
        return true
    }

    func isCurrent(_ key: ProviderCapabilityKey) -> Bool {
        owners[key.access] == ProviderCapabilityOwner(
            accountInstanceID: key.accountInstanceID,
            credentialEpoch: key.credentialEpoch)
    }

    /// Allocate request ownership only after the caller has successfully written request bytes to
    /// its immutable provider runtime. Beginning a refresh clears stale actionable capability data.
    func beginRequest(for key: ProviderCapabilityKey) -> ProviderCapabilityRequestTicket? {
        guard isCurrent(key) else { return nil }
        nextRequestRevision &+= 1
        let ticket = ProviderCapabilityRequestTicket(key: key, revision: nextRequestRevision)
        latestRequestRevisions[key] = ticket.revision
        snapshots[key] = ProviderCapabilitySnapshot(
            phase: .loading,
            capabilities: [],
            adapterRevision: nil,
            sourceRevision: nil,
            rawEvidenceDigest: nil,
            updatedAt: Date())
        return ticket
    }

    @discardableResult
    func publish(
        _ capabilities: [ProviderCapability],
        ticket: ProviderCapabilityRequestTicket,
        adapterRevision: String,
        sourceRevision: String? = nil,
        rawEvidenceDigest: String? = nil
    ) -> Bool {
        guard isCurrent(ticket.key),
              latestRequestRevisions[ticket.key] == ticket.revision else { return false }
        let normalized = capabilities
            .filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .reduce(into: [String: ProviderCapability]()) { result, capability in
                result[capability.id] = capability
            }
            .values
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        // An authoritative empty response is meaningful and must clear old availability.
        snapshots[ticket.key] = ProviderCapabilitySnapshot(
            phase: .ready,
            capabilities: normalized,
            adapterRevision: adapterRevision,
            sourceRevision: sourceRevision,
            rawEvidenceDigest: rawEvidenceDigest,
            updatedAt: Date())
        return true
    }

    @discardableResult
    func fail(_ ticket: ProviderCapabilityRequestTicket, message: String) -> Bool {
        guard isCurrent(ticket.key),
              latestRequestRevisions[ticket.key] == ticket.revision else { return false }
        snapshots[ticket.key] = ProviderCapabilitySnapshot(
            phase: .failed(message),
            capabilities: [],
            adapterRevision: nil,
            sourceRevision: nil,
            rawEvidenceDigest: nil,
            updatedAt: Date())
        return true
    }

    func invalidate(access: ModelAccess) {
        owners[access] = nil
        snapshots = snapshots.filter { $0.key.access != access }
        latestRequestRevisions = latestRequestRevisions.filter { $0.key.access != access }
    }
}
