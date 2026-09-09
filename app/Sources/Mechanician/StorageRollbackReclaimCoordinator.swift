import Foundation

/// Gathers what `StorageRollbackReclaimPolicy` needs to decide, and acts on the answer.
///
/// The policy and the executor have existed since the cutover with nothing calling them, so the
/// migration's leftovers — the frozen structured sources and the rollback generation — accumulated
/// with no plan. This is the caller. It runs once per launch, off the main actor, and does nothing
/// at all until the library has been the authority for a week.
///
/// Every count it supplies is read fresh here rather than passed in by a caller who might be
/// holding a stale one: the whole point of the coverage proof is that it compares what the library
/// actually holds against what is actually still on disk.
enum StorageRollbackReclaimCoordinator {
    struct Outcome: Equatable, Sendable {
        let decision: StorageRollbackReclaimDecision
        let report: StorageRollbackReclaimReport?
    }

    /// Where the last completed reclaim is recorded, so a surface can tell the person what was
    /// released without having to observe the moment it happened.
    struct Receipt: Codable, Equatable, Sendable {
        let releasedNames: [String]
        let releasedBytes: Int64
        let releasedAt: Date
    }

    static let receiptDefaultsKey = "storageRollbackReclaimReceipt"

    /// Decide and, when the decision is `reclaim`, release. Returns what happened so a caller can
    /// report it; never throws, because a reclaim that cannot run is not a launch failure.
    @discardableResult
    static func runIfDue(
        supportRoot: URL,
        recognition: StorageAuthorityRecognition,
        repository: LibraryAuthorityRepository,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Outcome {
        guard case .sqlite(let marker, let probe) = recognition.disposition else {
            return Outcome(
                decision: .blocked("the library is not the active authority"), report: nil)
        }
        var inputs: StorageRollbackReclaimInputs
        do {
            inputs = try gatherInputs(
                supportRoot: supportRoot, marker: marker, probe: probe,
                repository: repository, now: now)
            // After the one real reclaim, the policy remains `.reclaim` on every later launch.
            // An authoritative commit also clears the integrity receipt, so without this empty-set
            // check those launches can run quick_check + foreign_key_check merely to discover that
            // the rollback generation is already gone. Preserve every policy gate except integrity;
            // there is no data-loss decision left to prove when there is literally no target.
            if let emptyOutcome = emptyReclaimOutcomeIfDue(
                supportRoot: supportRoot, inputs: inputs) {
                return emptyOutcome
            }
            // Every authoritative commit clears the integrity receipt, and the replacement is
            // computed asynchronously after launch. So on any library that has been used, this runs
            // against a receipt that is merely still being recomputed, and would be turned away by a
            // check that was going to pass. Wait for the answer rather than lose the race — but only
            // once nothing else stands in the way, so the cost lands on the single launch in the
            // life of an installation where the reclaim is actually due.
            if !inputs.integrityPassed, wouldReclaimGivenIntegrity(inputs) {
                try repository.verifyIntegrityAfterReady()
                inputs = try gatherInputs(
                    supportRoot: supportRoot, marker: marker, probe: probe,
                    repository: repository, now: now)
            }
        } catch {
            return Outcome(
                decision: .blocked(
                    "the library could not be measured: \(error.localizedDescription)"),
                report: nil)
        }
        let decision = StorageRollbackReclaimPolicy.decide(inputs)
        guard decision == .reclaim else { return Outcome(decision: decision, report: nil) }
        do {
            let report = try StorageRollbackReclaimService.reclaim(supportRoot: supportRoot)
            if !report.isEmpty {
                record(report, at: now, in: defaults)
            }
            return Outcome(decision: decision, report: report)
        } catch {
            return Outcome(
                decision: .blocked("release failed: \(error.localizedDescription)"), report: nil)
        }
    }

    /// Whether a passing integrity check is the only thing between these inputs and a reclaim.
    /// Asking the real policy rather than re-listing its conditions, so a new precondition cannot be
    /// silently skipped here.
    static func wouldReclaimGivenIntegrity(_ inputs: StorageRollbackReclaimInputs) -> Bool {
        var optimistic = inputs
        optimistic.integrityPassed = true
        return StorageRollbackReclaimPolicy.decide(optimistic) == .reclaim
    }

    /// The idempotent post-reclaim path. Kept separate so the important claim — an empty target set
    /// may skip integrity only when every other reclaim gate passes — is directly testable without
    /// constructing a live authority repository.
    static func emptyReclaimOutcomeIfDue(
        supportRoot: URL,
        inputs: StorageRollbackReclaimInputs
    ) -> Outcome? {
        guard wouldReclaimGivenIntegrity(inputs),
              StorageRollbackReclaimPolicy.reclaimableTargets(supportRoot: supportRoot).isEmpty
        else { return nil }
        return Outcome(decision: .reclaim, report: StorageRollbackReclaimReport())
    }

    static func gatherInputs(
        supportRoot: URL,
        marker: StorageAuthorityMarker,
        probe: StorageAuthorityDatabaseProbe,
        repository: LibraryAuthorityRepository,
        now: Date = Date()
    ) throws -> StorageRollbackReclaimInputs {
        let facts = try repository.reclaimFacts()
        return StorageRollbackReclaimInputs(
            authorityState: probe.authorityState,
            markerCreatedAt: markerDate(marker.createdAt),
            now: now,
            integrityPassed: facts.integrityPassed,
            hasVerifiedBackup: LibraryBackupLifecycle.hasVerifiedBackup(for: supportRoot),
            sqliteConversationCount: facts.conversationRowCount,
            legacyConversationFileCount: legacyConversationFileCount(in: supportRoot),
            preservedUnreadableSourceCount: facts.unrepresentedConversationSourceCount)
    }

    /// `.json` sidecars still sitting in the frozen tree. A directory that cannot be read counts as
    /// nothing released rather than nothing present: `reclaimableTargets` skips what is absent, and
    /// an unreadable directory must never be mistaken for an empty one.
    static func legacyConversationFileCount(in supportRoot: URL) -> Int {
        let directory = supportRoot.appendingPathComponent("conversations", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return Int.max
        }
        return names.filter { $0.hasSuffix(".json") }.count
    }

    static func markerDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func record(
        _ report: StorageRollbackReclaimReport,
        at moment: Date,
        in defaults: UserDefaults
    ) {
        let receipt = Receipt(
            releasedNames: report.releasedNames,
            releasedBytes: report.releasedBytes,
            releasedAt: moment)
        guard let data = try? JSONEncoder().encode(receipt) else { return }
        defaults.set(data, forKey: receiptDefaultsKey)
    }

    static func lastReceipt(in defaults: UserDefaults = .standard) -> Receipt? {
        guard let data = defaults.data(forKey: receiptDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }

    /// "1.4 GB released from your previous library" reads better than a byte count, and this is the
    /// only number in the sentence a person cares about.
    static func releasedDescription(_ receipt: Receipt) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: receipt.releasedBytes)
    }
}

/// What the app says about a completed reclaim, and when it stops saying it.
///
/// The reclaim runs on a background queue with nobody watching, and it moves several gigabytes of
/// somebody's previous library to the Trash. Doing that silently is the part that would be wrong:
/// the space does not come back until the Trash is emptied, and a person who finds gigabytes in
/// there with no explanation has been given a mystery instead of a choice.
///
/// The strings live here rather than inline in the view so they can be tested. The one-time notice
/// this is modelled on (`migrationBanner`) put its copy and its dismissal rules inside `ContentView`
/// and consequently has no tests at all.
enum StorageRollbackReclaimNotice {
    /// The moment whose receipt has already been seen, as a reference-date interval so `@AppStorage`
    /// can hold it. Keyed to the receipt rather than being a bare "seen" flag: a second reclaim on
    /// the same machine is a different event and deserves to be said again.
    static let dismissedAtKey = "storageRollbackReclaimNoticeDismissedAt"

    /// Posted once the reclaim has finished and recorded, so a window that is already open shows the
    /// note in the same session. Without it the only report would arrive at the next launch, and the
    /// person would meet the Trash before the explanation.
    static let didReclaim = Notification.Name("ai.mechanician.storage-reclaim.completed")

    /// The receipt worth showing, or nil when there is nothing to say or it has been dismissed.
    static func pending(
        in defaults: UserDefaults = .standard,
        dismissedAt: Double? = nil
    ) -> StorageRollbackReclaimCoordinator.Receipt? {
        guard let receipt = StorageRollbackReclaimCoordinator.lastReceipt(in: defaults),
              !receipt.releasedNames.isEmpty else { return nil }
        let seen = dismissedAt ?? defaults.double(forKey: dismissedAtKey)
        return isDismissed(receipt, dismissedAt: seen) ? nil : receipt
    }

    /// A receipt is dismissed only by a mark at or after its own moment. An older mark belongs to an
    /// earlier reclaim and must not suppress this one.
    static func isDismissed(
        _ receipt: StorageRollbackReclaimCoordinator.Receipt,
        dismissedAt: Double
    ) -> Bool {
        dismissedAt >= receipt.releasedAt.timeIntervalSinceReferenceDate
    }

    static func dismissalMark(for receipt: StorageRollbackReclaimCoordinator.Receipt) -> Double {
        receipt.releasedAt.timeIntervalSinceReferenceDate
    }

    /// Says what was released, why it was being kept, and that the space is not back yet. All three
    /// matter: without the second the reclaim looks arbitrary, and without the third the number is a
    /// promise the Trash has not kept.
    static func message(_ receipt: StorageRollbackReclaimCoordinator.Receipt) -> String {
        let size = StorageRollbackReclaimCoordinator.releasedDescription(receipt)
        return "Mechanician released \(size). It was a copy of your previous library, kept for a "
            + "week in case you needed to go back. The files are in the Trash until you empty it."
    }
}
