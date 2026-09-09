import Foundation

/// What the migration left behind that can eventually be released, and the conditions under which
/// releasing it is safe.
///
/// The dangerous mistake this type exists to prevent: "delete the Legacy tree" is wrong.
/// `conversation-media` was adopted **in place** — those bytes are the live attachments the active
/// library references by path, not a copy of them. Only the frozen structured sources and the
/// rollback generation are redundant after the cutover, and only once the database has proved
/// itself and a verified backup still exists.
enum StorageRollbackReclaimDecision: Equatable, Sendable {
    /// The library is healthy but the soak window has not elapsed.
    case waitForSoak(remaining: TimeInterval)
    /// Something is not proven. Nothing is released, and the reason is reportable.
    case blocked(String)
    case reclaim
}

struct StorageRollbackReclaimInputs: Sendable {
    var authorityState: LibraryAuthorityState
    var markerCreatedAt: Date?
    var now: Date
    var integrityPassed: Bool
    var hasVerifiedBackup: Bool
    /// Live Conversations the active database reports.
    var sqliteConversationCount: Int
    /// `.json` Conversation sources still sitting in the frozen Legacy directory.
    var legacyConversationFileCount: Int
    /// Sidecars the migrated library holds no Conversation for, whose exact bytes were carried into
    /// `preserved-sources` at activation. The coverage proof below has to count them or a single
    /// unreadable file would block every reclaim forever.
    ///
    /// Count only the **unrepresented** ones. Activation also preserves sources that imported fine
    /// but carry something the model cannot re-emit; those are already counted as Conversations, and
    /// counting them twice would let the frozen tree be released while a real source is unaccounted.
    var preservedUnreadableSourceCount: Int

    init(
        authorityState: LibraryAuthorityState,
        markerCreatedAt: Date?,
        now: Date = Date(),
        integrityPassed: Bool,
        hasVerifiedBackup: Bool,
        sqliteConversationCount: Int,
        legacyConversationFileCount: Int,
        preservedUnreadableSourceCount: Int = 0
    ) {
        self.preservedUnreadableSourceCount = preservedUnreadableSourceCount
        self.authorityState = authorityState
        self.markerCreatedAt = markerCreatedAt
        self.now = now
        self.integrityPassed = integrityPassed
        self.hasVerifiedBackup = hasVerifiedBackup
        self.sqliteConversationCount = sqliteConversationCount
        self.legacyConversationFileCount = legacyConversationFileCount
    }
}

enum StorageRollbackReclaimPolicy {
    /// How long the migrated library must run before its predecessor is released. A week of
    /// ordinary use, not a timer that starts hopeful.
    static let soak: TimeInterval = 7 * 24 * 60 * 60
    /// Migration-era unreadable sources may still be the only copy of a user's bytes. Keep this
    /// stable on disk even though the one-time carrier that originally created it is gone.
    static let preservedSourcesDirectoryName = "preserved-sources"

    static func decide(_ inputs: StorageRollbackReclaimInputs) -> StorageRollbackReclaimDecision {
        guard inputs.authorityState == .active else {
            return .blocked("the library is not the active authority")
        }
        guard let createdAt = inputs.markerCreatedAt else {
            return .blocked("the authority marker has no creation time to age")
        }
        guard inputs.integrityPassed else {
            return .blocked("the library has not passed an integrity check")
        }
        guard inputs.hasVerifiedBackup else {
            return .blocked("no verified backup remains to go back to")
        }
        // The cheapest honest proof that nothing would be lost: the active library must account for
        // every Conversation still sitting in the frozen sources — as a live Conversation, or as an
        // unreadable sidecar whose exact bytes were carried into `preserved-sources`.
        let accounted = inputs.sqliteConversationCount + inputs.preservedUnreadableSourceCount
        guard accounted >= inputs.legacyConversationFileCount else {
            return .blocked(
                "the library accounts for \(accounted) of "
                + "\(inputs.legacyConversationFileCount) frozen sources")
        }
        let elapsed = inputs.now.timeIntervalSince(createdAt)
        // A clock that moved backwards must not look like a completed soak.
        guard elapsed >= 0 else { return .blocked("the marker is dated in the future") }
        guard elapsed >= soak else { return .waitForSoak(remaining: soak - elapsed) }
        return .reclaim
    }

    /// The complete, explicit set of paths a reclaim may release. Enumerated rather than derived,
    /// so nothing can be swept in by a future directory appearing next to them.
    ///
    /// Deliberately absent: `conversation-media` (live retained bytes, adopted in place),
    /// `trash` (the app's own undo storage), `library.db` and its journals, `projections.db`, and
    /// the backup root, which has its own generation lifecycle.
    ///
    /// Also deliberately absent, and this one is not obvious: the **frozen structured sources**
    /// `conversations`, `workspaces`, `artifacts` and `home-workspace.json`. They look redundant
    /// after the cutover and they are not.
    ///
    /// The original reason is gone: `ConversationIndex` and `ArtifactIndex` read the authority now,
    /// so App Intents and the Spotlight artifact domain no longer depend on these files. What still
    /// does: `conversations/` holds the `.json.corrupt-*` sidecars that `RecoveredConversationRecovery`
    /// exports and restores — the only remaining copy of bytes the app could not read — and
    /// `ProviderAccountStore.prepareOnboardingPreference` still decides "this installation has
    /// data" by listing these directories. Releasing them takes an unreadable conversation's last
    /// copy with it. They stay until recovery reads its sources from somewhere durable and that
    /// onboarding probe asks the authority instead.
    static func reclaimableTargets(supportRoot: URL) -> [URL] {
        let root = supportRoot.standardizedFileURL
        return rollbackGenerations(besides: root)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Fresh-Legacy generations are published as siblings named after the support root. Match that
    /// exact shape rather than anything merely nearby.
    static func rollbackGenerations(besides supportRoot: URL) -> [URL] {
        let root = supportRoot.standardizedFileURL
        let parent = root.deletingLastPathComponent()
        let prefix = "\(root.lastPathComponent) Legacy Rollback "
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Never a live path, whatever else changes.
    static func isProtected(_ url: URL, supportRoot: URL) -> Bool {
        let root = supportRoot.standardizedFileURL
        let protectedNames = [
            "conversation-media", "trash", "library.db", "library.db-wal", "library.db-shm",
            "projections.db", "projections.db-wal", "projections.db-shm",
            "storage-authority.json", "ambient", "authority-inbox", "claude", "codex", "runtime",
            // The exact bytes of sidecars the app could not read, carried out of the frozen tree at
            // activation. They are the only remaining copy once `conversations` is released.
            preservedSourcesDirectoryName,
        ]
        // Compare resolved paths, not URLs: a caller naming a directory gets a trailing slash that
        // `==` on URL treats as a different value, and this guard must not depend on that.
        let candidate = url.standardizedFileURL.path
        return protectedNames.contains {
            candidate == root.appendingPathComponent($0).standardizedFileURL.path
        }
    }
}

struct StorageRollbackReclaimReport: Equatable, Sendable {
    var releasedNames: [String] = []
    var releasedBytes: Int64 = 0
    /// Where each released item landed in the Trash. Recorded because "you can put it back" is only
    /// true if something can still name the copies, and because a test that exercises the real
    /// `trashItem` has no other way to clean up after itself — twenty-seven abandoned sets of test
    /// debris accumulated in this developer's Trash before anything captured these.
    var trashedURLs: [URL] = []

    /// Nothing worth recording or telling anyone about. Zero bytes counts as nothing even when a
    /// name was moved: an empty directory that something recreated would otherwise be released,
    /// receipted and announced on every launch, each time as "Zero KB released".
    var isEmpty: Bool { releasedNames.isEmpty || releasedBytes <= 0 }
}

enum StorageRollbackReclaimService {
    /// Move the migration's leftovers to the Trash rather than unlinking them. The space returns
    /// when the Trash is emptied, and until then a person who is still unsure about their migration
    /// can put everything back by hand. Deleting outright would be faster and unrecoverable.
    ///
    /// Every target is re-checked against the protected set immediately before it is moved, so a
    /// future change to the enumeration cannot quietly widen what this releases.
    @discardableResult
    static func reclaim(
        supportRoot: URL,
        targets: [URL]? = nil,
        fileManager: FileManager = .default
    ) throws -> StorageRollbackReclaimReport {
        let root = supportRoot.standardizedFileURL
        let candidates = targets ?? StorageRollbackReclaimPolicy.reclaimableTargets(supportRoot: root)
        var report = StorageRollbackReclaimReport()
        for target in candidates {
            guard !StorageRollbackReclaimPolicy.isProtected(target, supportRoot: root) else {
                throw StorageRollbackReclaimError.protectedTarget(target.lastPathComponent)
            }
            guard fileManager.fileExists(atPath: target.path) else { continue }
            let bytes = allocatedBytes(of: target, fileManager: fileManager)
            var trashed: NSURL?
            try fileManager.trashItem(at: target, resultingItemURL: &trashed)
            report.releasedNames.append(target.lastPathComponent)
            report.releasedBytes += bytes
            if let trashed = trashed as URL? { report.trashedURLs.append(trashed) }
        }
        return report
    }

    private static func allocatedBytes(of url: URL, fileManager: FileManager) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

enum StorageRollbackReclaimError: Error, Equatable, LocalizedError {
    case protectedTarget(String)

    var errorDescription: String? {
        switch self {
        case .protectedTarget(let name):
            return "\(name) holds live data and cannot be reclaimed"
        }
    }
}
