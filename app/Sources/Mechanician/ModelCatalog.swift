import Foundation
import Combine

/// One model exposed by one exact account/runtime lane. A model id alone is not a stable picker
/// identity: the same provider model may be available through both a subscription and an API key.
struct ModelCatalogEntry: Identifiable, Codable, Equatable, Hashable {
    var selection: ModelSelection
    var displayName: String
    var description: String
    var resolvedModelID: String?
    var isDefault: Bool
    var supportedEfforts: [String]
    var capabilities: [String]

    var id: ModelSelection { selection }

    /// Claude's provider catalog uses stable family aliases ("Sonnet", "Opus") as display names
    /// even when `resolvedModelID` identifies a specific generation. Keep old persisted catalogs
    /// and transient runtime snapshots honest in the UI without rewriting provider selection IDs.
    var versionedDisplayName: String {
        let label = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selection.access.maker == .anthropic,
              let resolvedModelID,
              !resolvedModelID.isEmpty else { return label }
        let stem = resolvedModelID
            .lowercased()
            .split(separator: "[", maxSplits: 1, omittingEmptySubsequences: true)[0]
        let parts = stem.split(separator: "-")
        guard parts.count >= 3, parts[0] == "claude" else { return label }
        let family = String(parts[1])
        let lowerLabel = label.lowercased()
        guard lowerLabel == family || lowerLabel.hasPrefix("\(family) (") else {
            return label
        }
        let majorDigits = parts[2].prefix { $0.isNumber }
        guard !majorDigits.isEmpty, majorDigits.count <= 2 else { return label }
        var version = String(majorDigits)
        if parts.count > 3 {
            let minorDigits = parts[3].prefix { $0.isNumber }
            if !minorDigits.isEmpty, minorDigits.count <= 2 {
                version += ".\(minorDigits)"
            }
        }
        if lowerLabel == family {
            return "\(label) \(version)"
        }
        let insertion = label.index(label.startIndex, offsetBy: family.count)
        return "\(label[..<insertion]) \(version)\(label[insertion...])"
    }
}

struct ModelCatalogKey: Hashable {
    var access: ModelAccess
    var scope: String
}

/// Process-wide ownership for one explicitly sent catalog request. Window-local daemon generations
/// are insufficient because several windows can refresh the same account/workspace concurrently.
/// The store accepts a terminal only while this revision is still the newest request for its key.
struct ModelCatalogRequestTicket: Hashable {
    var key: ModelCatalogKey
    var credentialEpoch: Int
    var revision: UInt64
}

/// An explicit state for a single access/scope catalog. Ready with an empty entry list is meaningful:
/// the provider answered authoritatively and exposed no selectable models for that scope.
struct ModelCatalogSnapshot: Equatable {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    var phase: Phase
    var entries: [ModelCatalogEntry]
    var credentialEpoch: Int
    var updatedAt: Date?

    static func idle(epoch: Int) -> ModelCatalogSnapshot {
        ModelCatalogSnapshot(phase: .idle, entries: [], credentialEpoch: epoch, updatedAt: nil)
    }
}

/// Process-wide, account-safe catalog cache. Provider runtimes are window-owned, but their catalog
/// answers describe the same account. Credential epochs prevent a late answer from an old runtime
/// generation from repopulating rows after reconnect, sign-out, or credential replacement.
@MainActor
final class ModelCatalogStore: ObservableObject {
    static let shared = ModelCatalogStore(cacheURL: defaultCacheURL)

    private struct PersistedCatalog: Codable {
        var access: ModelAccess
        var scope: String
        var routeIdentity: String?
        var entries: [ModelCatalogEntry]
    }

    @Published private(set) var snapshots: [ModelCatalogKey: ModelCatalogSnapshot] = [:]
    /// The last provider-reported catalog for an exact access/scope. Account operations remove
    /// selectable snapshots immediately, but keeping this non-selectable evidence lets the model
    /// picker show what was configured and offer Reconnect in place. These rows are never treated
    /// as current entitlement evidence and are replaced by the next successful provider catalog.
    private var lastKnownEntries: [ModelCatalogKey: [ModelCatalogEntry]] = [:]
    /// The provider's UNCONSTRAINED answer, kept in memory only. Diagnostics for the
    /// managed-configuration surface — never a selection source, and never persisted, so it cannot
    /// become a back door to a model the managed constraint withheld.
    private var providerReportedEntries: [ModelCatalogKey: [ModelCatalogEntry]] = [:]
    /// An explicit request can authoritatively report an empty catalog. Automatic empty catalogs
    /// are different: Vertex also emits them as lifecycle clear signals while ADC is checking or
    /// disconnected. Keep that distinction so one transient auth event cannot permanently convince
    /// the Effort picker that the provider reported "no levels."
    private var explicitlyReportedCatalogs = Set<ModelCatalogKey>()
    /// The credential epoch that produced each cached row set, so an automatic empty catalog can be
    /// told apart from a credential boundary. Deliberately in memory only: a cache loaded from disk
    /// has no recorded epoch, and the safe reading of "unknown" is "not a boundary" — a lane that
    /// reports empty on the launch after a working one must keep its rows, which is exactly the
    /// case that left the Codex section of the picker permanently blank.
    private var lastKnownCredentialEpochs: [ModelCatalogKey: Int] = [:]
    private var credentialEpochs: [ModelAccess: Int] = [:]
    private let cacheURL: URL?
    private var nextRequestRevision: UInt64 = 0
    /// Retain the latest revision after its terminal arrives. An id-less startup answer may have
    /// begun before that explicit request and must never overwrite its newer success or failure.
    private var latestRequestRevisions: [ModelCatalogKey: UInt64] = [:]

    init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL
        loadLastKnownEntries()
    }

    private static var defaultCacheURL: URL {
        let base = MechanicianEnvironment.currentSupportRoot()
        return base.appendingPathComponent("model-catalog-cache.json")
    }

    private func loadLastKnownEntries() {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL),
              let persisted = try? JSONDecoder().decode([PersistedCatalog].self, from: data)
        else { return }
        lastKnownEntries = persisted.reduce(into: [:]) { result, catalog in
            guard catalog.routeIdentity == TenantProfile.current.routeIdentity(for: catalog.access)
            else { return }
            let key = ModelCatalogKey(
                access: catalog.access,
                scope: Self.normalizedScope(catalog.scope))
            result[key] = catalog.entries.filter {
                $0.selection.access == catalog.access && !$0.selection.modelID.isEmpty
            }
        }
    }

    private func persistLastKnownEntries() {
        guard let cacheURL else { return }
        let persisted = lastKnownEntries.map { key, entries in
            PersistedCatalog(
                access: key.access,
                scope: key.scope,
                routeIdentity: TenantProfile.current.routeIdentity(for: key.access),
                entries: entries)
        }.sorted {
            if $0.access.rawValue != $1.access.rawValue {
                return $0.access.rawValue < $1.access.rawValue
            }
            return $0.scope < $1.scope
        }
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        let directory = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    func snapshot(for access: ModelAccess, scope: String) -> ModelCatalogSnapshot {
        let key = ModelCatalogKey(access: access, scope: Self.normalizedScope(scope))
        return snapshots[key] ?? .idle(epoch: credentialEpochs[access] ?? 0)
    }

    func entries(for access: ModelAccess, scope: String) -> [ModelCatalogEntry] {
        let snapshot = snapshot(for: access, scope: scope)
        guard snapshot.phase == .ready else { return [] }
        return snapshot.entries
    }

    func lastKnownEntries(for access: ModelAccess, scope: String) -> [ModelCatalogEntry] {
        let key = ModelCatalogKey(access: access, scope: Self.normalizedScope(scope))
        if let entries = snapshots[key]?.entries, !entries.isEmpty { return entries }
        // Constrained on READ as well as on publish: a cache written by an earlier build (or before
        // a profile was imported) can still hold rows this deployment never carried, and an upgrade
        // must heal on launch rather than only after the next successful provider catalog.
        return Self.constrained(lastKnownEntries[key] ?? [], for: access)
    }

    /// What the provider reported for this lane before any managed constraint was applied. Empty
    /// until a catalog has been published in this process.
    func providerReported(for access: ModelAccess, scope: String) -> [ModelCatalogEntry] {
        providerReportedEntries[
            ModelCatalogKey(access: access, scope: Self.normalizedScope(scope))] ?? []
    }

    /// Distinguish a declaration-only READY snapshot from an authoritative provider catalog that
    /// genuinely reported no models or no effort metadata. The values alone are both empty; map
    /// membership preserves the provenance needed to avoid either skipping discovery forever or
    /// repeatedly probing a model that does not support adjustable effort.
    func hasProviderReportedCatalog(for access: ModelAccess, scope: String) -> Bool {
        let key = ModelCatalogKey(access: access, scope: Self.normalizedScope(scope))
        return explicitlyReportedCatalogs.contains(key)
            || providerReportedEntries[key]?.isEmpty == false
    }

    /// Every model id the provider reported for this lane in this process, across all workspace
    /// scopes. Diagnostics only: the managed-configuration surface uses it to name exactly what a
    /// signed profile is withholding, which is the cost that makes the constraint subtractive.
    func providerReportedModelIDs(for access: ModelAccess) -> [String] {
        var seen = Set<String>()
        return providerReportedEntries
            .filter { $0.key.access == access }
            .flatMap(\.value)
            .map(\.selection.modelID)
            .filter { seen.insert($0).inserted }
            .sorted()
    }

    /// A managed deployment's declared models are AUTHORITATIVE over the provider's own catalog.
    ///
    /// This inverts the usual "the provider knows best" rule for one measured reason: Claude's
    /// `supportedModels()` is answered by the local Claude Code runtime from its own build-time
    /// list, NOT by the deployment. A probe run against a nonexistent Vertex project with no
    /// credentials at all still returns the full first-party catalog — led by `default`, whose
    /// `resolvedModel` is `claude-opus-5`. On a managed Vertex lane that catalog is therefore not
    /// evidence about what the project carries, and treating it as evidence is what selected a
    /// model the deployment answers with 404 on every single turn.
    ///
    /// Consequences, deliberately chosen:
    ///  * The wire id is always the DECLARED id, never a provider alias. An alias such as `default`
    ///    or `opus` re-resolves inside the runtime, so honouring one would hand model choice back to
    ///    the same build-time list this constraint exists to overrule.
    ///  * A catalog row is used only to ENRICH a declared model (efforts, capabilities, blurb).
    ///  * Undeclared rows are withheld. That is subtractive, which `TenantProfile.Route.models`
    ///    previously forbade — see ``withheldModelIDs`` for how the cost is surfaced rather than
    ///    hidden. A model the profile has not caught up with is recoverable by publishing a new
    ///    signed profile; a model the deployment cannot serve leaves the account with no working
    ///    turn at all, so the two failures are not symmetric.
    ///
    /// A lane whose profile declares nothing is returned unchanged.
    static func constrained(
        _ entries: [ModelCatalogEntry],
        for access: ModelAccess,
        profile: TenantProfile = .current
    ) -> [ModelCatalogEntry] {
        let declared = profile.declaredModels(for: access)
        guard !declared.isEmpty else { return entries }
        return declared.map { model in
            let match = entries.first { $0.selection.modelID == model.id }
                ?? entries.first { $0.resolvedModelID == model.id }
            let reportedEfforts = match?.supportedEfforts ?? []
            let supportedEfforts = reportedEfforts.isEmpty
                ? model.supportedEfforts
                : reportedEfforts
            var capabilities = match?.capabilities ?? []
            if !supportedEfforts.isEmpty, !capabilities.contains("effort") {
                capabilities.append("effort")
            }
            return ModelCatalogEntry(
                selection: ModelSelection(access: access, modelID: model.id),
                displayName: model.displayName ?? match?.displayName ?? model.id,
                description: match?.description ?? "",
                // Never inherit an alias row's resolution: the selection IS the declared id, so
                // claiming it resolves to whatever `default` currently means would be a lie.
                resolvedModelID: match?.selection.modelID == model.id ? match?.resolvedModelID : nil,
                isDefault: model.isDefault,
                // A signed deployment can carry exact, administrator-verified effort support so
                // managed Vertex does not depend on an account/catalog timing race. A nonempty live
                // report remains freshest; otherwise the declaration is trusted evidence, not an
                // invented generic fallback.
                supportedEfforts: supportedEfforts,
                capabilities: capabilities)
        }
    }

    /// Provider-reported model ids a managed profile withheld, so the managed-configuration surface
    /// can say what is being hidden instead of leaving an admin to discover it from a support call.
    static func withheldModelIDs(
        from entries: [ModelCatalogEntry],
        for access: ModelAccess,
        profile: TenantProfile = .current
    ) -> [String] {
        let declared = profile.declaredModels(for: access)
        guard !declared.isEmpty else { return [] }
        let allowed = Set(declared.map(\.id))
        return entries
            .filter { !allowed.contains($0.selection.modelID) }
            .map(\.selection.modelID)
    }

    /// Align the store with the credential owner before accepting/loading a runtime snapshot.
    /// Moving forward invalidates every scope for that access; moving backward is always stale.
    @discardableResult
    func alignCredentialEpoch(_ epoch: Int, for access: ModelAccess) -> Bool {
        let current = credentialEpochs[access] ?? 0
        guard epoch >= current else { return false }
        if epoch > current {
            credentialEpochs[access] = epoch
            snapshots = snapshots.filter { $0.key.access != access }
            providerReportedEntries = providerReportedEntries.filter { $0.key.access != access }
            explicitlyReportedCatalogs = explicitlyReportedCatalogs.filter {
                $0.access != access
            }
            latestRequestRevisions = latestRequestRevisions.filter { $0.key.access != access }
        } else if credentialEpochs[access] == nil {
            credentialEpochs[access] = epoch
        }
        return true
    }

    func beginLoading(access: ModelAccess, scope: String, credentialEpoch: Int) {
        guard alignCredentialEpoch(credentialEpoch, for: access) else { return }
        let key = ModelCatalogKey(access: access, scope: Self.normalizedScope(scope))
        // A request that is merely queued behind runtime startup must not erase a newer ready
        // process-wide snapshot. `beginExplicitRequest` changes it to loading after bytes are sent.
        if snapshots[key]?.phase == .ready { return }
        snapshots[key] = ModelCatalogSnapshot(
            phase: .loading, entries: [], credentialEpoch: credentialEpoch, updatedAt: Date())
    }

    /// Allocate ownership only after the bridge successfully writes the request to its daemon.
    /// The monotonically increasing revision orders requests across every Mechanician window.
    func beginExplicitRequest(
        access: ModelAccess,
        scope: String,
        credentialEpoch: Int
    ) -> ModelCatalogRequestTicket? {
        guard alignCredentialEpoch(credentialEpoch, for: access),
              credentialEpochs[access] == credentialEpoch else { return nil }
        let key = ModelCatalogKey(access: access, scope: Self.normalizedScope(scope))
        nextRequestRevision &+= 1
        let ticket = ModelCatalogRequestTicket(
            key: key, credentialEpoch: credentialEpoch, revision: nextRequestRevision)
        latestRequestRevisions[key] = ticket.revision
        snapshots[key] = ModelCatalogSnapshot(
            phase: .loading, entries: [], credentialEpoch: credentialEpoch, updatedAt: Date())
        return ticket
    }

    @discardableResult
    func publish(
        _ entries: [ModelCatalogEntry],
        ticket: ModelCatalogRequestTicket
    ) -> Bool {
        let access = ticket.key.access
        guard credentialEpochs[access] == ticket.credentialEpoch,
              latestRequestRevisions[ticket.key] == ticket.revision else { return false }
        publishAccepted(
            entries, key: ticket.key, credentialEpoch: ticket.credentialEpoch,
            explicitlyRequested: true)
        return true
    }

    /// Startup catalogs have no request id. Accept them only until an explicit request has claimed
    /// this exact account/scope in the current credential epoch; thereafter they are subordinate and
    /// cannot overwrite an explicitly refreshed result, regardless of arrival order.
    @discardableResult
    func publishAutomatic(
        _ entries: [ModelCatalogEntry],
        access: ModelAccess,
        scope: String,
        credentialEpoch: Int
    ) -> Bool {
        guard credentialEpochs[access] == credentialEpoch else { return false }
        let key = ModelCatalogKey(access: access, scope: Self.normalizedScope(scope))
        guard latestRequestRevisions[key] == nil else { return false }
        publishAccepted(
            entries, key: key, credentialEpoch: credentialEpoch,
            explicitlyRequested: false)
        return true
    }

    /// Publish a managed deployment's signed declaration without pretending it came from the
    /// provider. Claude's live catalog is optional enrichment for these routes and requires a
    /// subprocess; making that subprocess a prerequisite for `.ready` both delayed the first turn
    /// and let an unavailable first-party default empty the picker. A forced refresh can still
    /// replace these rows with enriched versions later.
    @discardableResult
    func publishDeclared(
        access: ModelAccess,
        scope: String,
        credentialEpoch: Int,
        profile: TenantProfile = .current
    ) -> Bool {
        guard alignCredentialEpoch(credentialEpoch, for: access) else { return false }
        let key = ModelCatalogKey(access: access, scope: Self.normalizedScope(scope))
        // A route-identity-validated cache is safe enrichment for this exact managed backend. Keep
        // its effort metadata while the signed declaration remains model authority; replacing it
        // with blank declaration rows on every launch made a previously working picker empty again.
        let entries = Self.constrained(
            lastKnownEntries[key] ?? [], for: access, profile: profile)
            .filter { $0.selection.access == access && !$0.selection.modelID.isEmpty }
        guard !entries.isEmpty else { return false }
        guard latestRequestRevisions[key] == nil else { return false }
        lastKnownEntries[key] = entries
        lastKnownCredentialEpochs[key] = credentialEpoch
        persistLastKnownEntries()
        snapshots[key] = ModelCatalogSnapshot(
            phase: .ready,
            entries: entries,
            credentialEpoch: credentialEpoch,
            updatedAt: Date())
        return true
    }

    private func publishAccepted(
        _ entries: [ModelCatalogEntry],
        key: ModelCatalogKey,
        credentialEpoch: Int,
        explicitlyRequested: Bool
    ) {
        let access = key.access
        // Record what the provider actually said BEFORE the managed constraint, so the
        // managed-configuration surface can show the difference rather than only the result.
        let providerEntries = entries
            .filter { $0.selection.access == access && !$0.selection.modelID.isEmpty }
        if explicitlyRequested {
            explicitlyReportedCatalogs.insert(key)
            providerReportedEntries[key] = providerEntries
        } else if providerEntries.isEmpty {
            // Vertex uses an id-less empty catalog to clear stale account state, and a Codex lane
            // whose token refresh lost a race publishes the same shape. It is not a completed
            // enumeration and must remain retryable after the account recovers.
            explicitlyReportedCatalogs.remove(key)
            providerReportedEntries.removeValue(forKey: key)
            // Only a CREDENTIAL BOUNDARY retires cached rows. Retiring them at the same epoch is
            // what emptied the whole Codex section of the picker: the lane reported a sign-out it
            // had not had, the empty list was persisted, and the built-in fallback below could no
            // longer be reached because a READY-and-empty snapshot reads as an authoritative "this
            // account has no models". Keep the rows and leave the snapshot alone; the account store
            // has already marked the lane unavailable, so nothing here is presented as selectable.
            if !crossedCredentialBoundary(key: key, credentialEpoch: credentialEpoch),
               lastKnownEntries[key]?.isEmpty == false {
                return
            }
        } else {
            providerReportedEntries[key] = providerEntries
        }
        let normalized = Self.constrained(entries, for: access)
            .filter { $0.selection.access == access && !$0.selection.modelID.isEmpty }
            .reduce(into: [ModelSelection: ModelCatalogEntry]()) { result, entry in
                result[entry.selection] = entry
            }
            .values
            .sorted {
                if $0.isDefault != $1.isDefault { return $0.isDefault }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        lastKnownEntries[key] = normalized
        lastKnownCredentialEpochs[key] = credentialEpoch
        persistLastKnownEntries()
        snapshots[key] = ModelCatalogSnapshot(
            phase: .ready, entries: normalized, credentialEpoch: credentialEpoch, updatedAt: Date())
    }

    /// Whether the rows cached for `key` were produced by a DIFFERENT credential than the one
    /// publishing now. An unrecorded epoch means the rows came off disk in this launch, which is
    /// not evidence of a boundary and must not be treated as one.
    private func crossedCredentialBoundary(key: ModelCatalogKey, credentialEpoch: Int) -> Bool {
        guard let recorded = lastKnownCredentialEpochs[key] else { return false }
        return recorded != credentialEpoch
    }

    @discardableResult
    func fail(ticket: ModelCatalogRequestTicket, message: String) -> Bool {
        let access = ticket.key.access
        guard credentialEpochs[access] == ticket.credentialEpoch,
              latestRequestRevisions[ticket.key] == ticket.revision else { return false }
        snapshots[ticket.key] = ModelCatalogSnapshot(
            phase: .failed(message), entries: lastKnownEntries[ticket.key] ?? [], credentialEpoch: ticket.credentialEpoch,
            updatedAt: Date())
        return true
    }

    /// An id-less startup failure is useful only before an explicit refresh owns the key, and must
    /// not erase a ready snapshot supplied by another healthy window.
    @discardableResult
    func failAutomatic(
        access: ModelAccess,
        scope: String,
        credentialEpoch: Int,
        message: String
    ) -> Bool {
        guard credentialEpochs[access] == credentialEpoch else { return false }
        let key = ModelCatalogKey(access: access, scope: Self.normalizedScope(scope))
        guard latestRequestRevisions[key] == nil,
              snapshots[key]?.phase != .ready else { return false }
        snapshots[key] = ModelCatalogSnapshot(
            phase: .failed(message), entries: lastKnownEntries[key] ?? [], credentialEpoch: credentialEpoch, updatedAt: Date())
        return true
    }

    /// Account operations disable every selectable row immediately without pretending that a
    /// credential boundary has occurred. A successful/ambiguous mutation advances the epoch later.
    func disable(access: ModelAccess, credentialEpoch: Int, message: String? = nil) {
        guard alignCredentialEpoch(credentialEpoch, for: access) else { return }
        let keys = Set(snapshots.keys.filter { $0.access == access })
            .union(latestRequestRevisions.keys.filter { $0.access == access })
        for key in keys {
            // Supersede any same-epoch request already in flight. Removing its revision would make
            // an older id-less startup event eligible again after the account operation finishes.
            nextRequestRevision &+= 1
            latestRequestRevisions[key] = nextRequestRevision
            snapshots[key] = ModelCatalogSnapshot(
                phase: message.map(ModelCatalogSnapshot.Phase.failed) ?? .idle,
                entries: snapshots[key]?.entries ?? lastKnownEntries[key] ?? [],
                credentialEpoch: credentialEpoch, updatedAt: Date())
        }
    }

    func invalidate(access: ModelAccess, credentialEpoch: Int) {
        guard alignCredentialEpoch(credentialEpoch, for: access) else { return }
        snapshots = snapshots.filter { $0.key.access != access }
        latestRequestRevisions = latestRequestRevisions.filter { $0.key.access != access }
    }

    static func normalizedScope(_ scope: String) -> String {
        let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "account" : trimmed
    }
}
