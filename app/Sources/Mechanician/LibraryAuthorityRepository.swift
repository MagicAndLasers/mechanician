import CryptoKit
import Foundation

struct LibraryAuthorityLaunchConversation: Sendable {
    let summary: ConversationSummary
    let artifactIDs: Set<UUID>
    let modelAccess: ModelAccess?
    let sourceRevision: String
    let sourceByteCount: Int
    let requiresIntrinsicResidency: Bool
}

struct LibraryAuthorityLaunchInventory: Sendable {
    let databaseInstanceID: UUID
    let committedSequence: Int64
    let home: HomeWorkspaceSettings
    let workspaces: [Project]
    let conversations: [LibraryAuthorityLaunchConversation]
    let intrinsicConversations: [Conversation]
    let artifacts: [Artifact]
    /// False is the fast path: a full check was durably recorded for this exact committed sequence.
    /// True never blocks first paint; the app schedules `verifyIntegrityAfterReady()` instead.
    let requiresDeferredIntegrityCheck: Bool
}

struct LibraryAuthorityConversationCommitResult: Equatable, Sendable {
    let committedSequence: Int64
    /// True when transcript/tool content changed. The durable outbox always coalesces the entity;
    /// callers may use false to update summary metadata without immediately rehashing FTS.
    /// Conversation titles live in the summary projection, not `entry_fts`, so title-only changes
    /// deliberately leave this false.
    let searchableContentChanged: Bool
}

struct LibraryAuthorityWorkspaceInventory: Sendable {
    let home: HomeWorkspaceSettings
    let workspaces: [Project]
}

/// Broad authority fence for UI/context snapshots.
struct LibraryAuthoritySnapshotGeneration: Equatable, Sendable {
    let databaseInstanceID: UUID
    let committedSequence: Int64

    var isValid: Bool { committedSequence >= 0 }
}

/// How long one bounded transcript-tail read spent waiting for the authority queue, and how long
/// the read itself took. Separated because a slow surface is almost always the wait rather than
/// the query, and reporting a single total hides which one it was.
struct LibraryRecentTranscriptReadTiming: Equatable, Sendable {
    let queueWaitSeconds: TimeInterval
    let readSeconds: TimeInterval
}

/// A presentation-only transcript tail plus the timing of the read that produced it. This remains
/// an entry array rather than a partial Conversation so it cannot enter an authority save path.
struct LibraryRecentTranscriptReadResult {
    let entries: [TranscriptEntry]
    let timing: LibraryRecentTranscriptReadTiming
}

/// The sole process-wide writable connection after marker-last SQLite activation.
///
/// `open(recognition:)` is registry-backed: Conversation, Workspace, Artifact, Ambient and inbox
/// integrations all receive this same queue-confined store rather than opening competing writers.
final class LibraryAuthorityRepository: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [String: LibraryAuthorityRepository] = [:]

    /// Drop any cached repository for a root, so the next `open` builds a fresh handle.
    ///
    /// The schema upgrade replaces `library.db` by rename. The registry key is the root path plus
    /// the activation id, and an upgrade deliberately PRESERVES the activation id — so without this
    /// the key still matches after the swap and callers are handed a store whose file descriptor
    /// points at the file that was moved aside. That reads as `disk I/O error`, which is a
    /// spectacularly unhelpful way to learn the library was replaced underneath you.
    ///
    /// This only forgets the cache entry. It cannot invalidate a handle someone already holds,
    /// which is why the upgrade runs before anything opens a repository.
    static func forget(supportRoot: URL) {
        let prefix = supportRoot.standardizedFileURL.path + "|"
        registryLock.lock()
        defer { registryLock.unlock() }
        for key in registry.keys where key.hasPrefix(prefix) {
            registry.removeValue(forKey: key)
        }
    }

    let supportRoot: URL
    let activationID: UUID
    let databaseInstanceID: UUID

    private let store: SQLiteLibraryStore
    private let interactiveReadStore: SQLiteLibraryStore?
    private let projectionWorkerLock = NSLock()
    private var projectionWorker: LibraryAuthorityProjectionWorker?
    /// Physical media is written before its lightweight Conversation reference is published. A
    /// generation counter carries that fact to the next Conversation COMMIT without scanning every
    /// media directory on ordinary text/state saves, and preserves a newer write that races a scan.
    private let retainedByteMutationLock = NSLock()
    private var pendingConversationMediaGenerations: [UUID: UInt64] = [:]

    /// The facts the post-soak reclaim needs, read through the one open writer.
    ///
    /// The reclaim must never open a second connection to answer them: this repository is the
    /// single authority writer for the process, and a second writer is exactly what the marker
    /// protocol exists to prevent.
    struct ReclaimFacts: Equatable, Sendable {
        let integrityPassed: Bool
        let conversationRowCount: Int
        let unrepresentedConversationSourceCount: Int
    }

    func reclaimFacts() throws -> ReclaimFacts {
        ReclaimFacts(
            integrityPassed: try store.status().integrity.state == .passed,
            conversationRowCount: try store.conversationRowCount(),
            unrepresentedConversationSourceCount:
                try store.unrepresentedConversationSourceCount())
    }

    static var sharedIfActive: LibraryAuthorityRepository? {
        try? open(recognition: StorageAuthorityBootstrap.current)
    }

    static func open(
        recognition: StorageAuthorityRecognition = StorageAuthorityBootstrap.current
    ) throws -> LibraryAuthorityRepository? {
        guard case .sqlite(let marker, let probe) = recognition.disposition else { return nil }
        guard probe.authorityState == .active,
              probe.activationID == marker.activationID,
              probe.databaseInstanceID == marker.databaseInstanceID else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "SQLite marker does not name a matching active repository")
        }
        let key = recognition.effectiveSupportRoot.standardizedFileURL.path
            + "|" + marker.activationID.uuidString
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[key] { return existing }
        let opened = try LibraryAuthorityRepository(
            store: SQLiteLibraryStore.openActiveAuthority(
                supportRoot: recognition.effectiveSupportRoot,
                marker: marker),
            supportRoot: recognition.effectiveSupportRoot,
            marker: marker)
        registry[key] = opened
        return opened
    }

    init(
        store: SQLiteLibraryStore,
        supportRoot: URL,
        marker: StorageAuthorityMarker
    ) throws {
        let metadata = try store.authorityMetadata()
        guard marker.mode == .sqlite,
              metadata.authorityState == .active,
              metadata.activationID == marker.activationID,
              metadata.databaseInstanceID == marker.databaseInstanceID else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "repository initializer requires matching active authority")
        }
        let interactiveReadStore: SQLiteLibraryStore?
        do {
            interactiveReadStore = try SQLiteLibraryStore.openActiveAuthorityInteractiveReader(
                supportRoot: supportRoot,
                marker: marker)
        } catch {
            // This connection is a latency optimization, never an authority prerequisite. Keep
            // launch available and use the already-verified primary handle if a second read-only
            // descriptor cannot be opened. Do not put paths, identifiers, or content in this log.
            NSLog(
                "Mechanician: interactive transcript reader unavailable; using the primary authority lane")
            interactiveReadStore = nil
        }
        self.store = store
        self.interactiveReadStore = interactiveReadStore
        self.supportRoot = supportRoot.standardizedFileURL
        activationID = marker.activationID
        databaseInstanceID = marker.databaseInstanceID
    }

    func launchInventory() throws -> LibraryAuthorityLaunchInventory {
        let bundle = try store.authoritativeLaunchInventoryBundle(activationID: activationID)
        guard bundle.databaseInstanceID == databaseInstanceID else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "authority changed during launch inventory")
        }
        let home: HomeWorkspaceSettings
        switch try LibraryWorkspaceAdapter.reconstruct(from: bundle.home) {
        case .home(let value): home = value
        case .named, .unresolved:
            throw SQLiteLibraryStoreError.invalidInput(
                "authoritative Home row did not reconstruct as Home")
        }
        let workspaces = try bundle.workspaces.map { snapshot -> Project in
            guard case .named(let value) = try LibraryWorkspaceAdapter.reconstruct(from: snapshot)
            else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "authoritative named Workspace did not reconstruct")
            }
            return value
        }
        let artifacts = try store.authoritativeArtifactSnapshots(activationID: activationID)
            .map(LibraryArtifactAdapter.reconstruct)
        let conversations = bundle.conversations.map {
            LibraryAuthorityLaunchConversation(
                summary: $0.summary,
                artifactIDs: $0.artifactIDs,
                modelAccess: $0.modelAccess,
                sourceRevision: $0.source.revision,
                sourceByteCount: $0.source.byteCount,
                requiresIntrinsicResidency: $0.requiresIntrinsicResidency)
        }
        return LibraryAuthorityLaunchInventory(
            databaseInstanceID: databaseInstanceID,
            // This sequence and the Conversation/Workspace rows were read in one SQLite snapshot.
            // Re-reading metadata afterward can observe a newer commit and let the disposable
            // projection acknowledge facts that were not present in this inventory.
            committedSequence: bundle.shadowChangeSequence,
            home: home,
            workspaces: workspaces,
            conversations: conversations,
            intrinsicConversations: bundle.intrinsicConversations,
            artifacts: artifacts,
            requiresDeferredIntegrityCheck:
                try !store.activeIntegrityReceiptIsCurrent(activationID: activationID))
    }

    func conversation(
        id: UUID,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> Conversation? {
        let snapshot = try store.authoritativeConversationSnapshot(
            id: id,
            activationID: activationID,
            isCancelled: isCancelled)
        // SQLite has released its serial queue at this point. Selection cancellation can therefore
        // skip the expensive parallel reconstruction without interrupting a database operation or
        // delaying a newer conversation's tiny preview read.
        guard !isCancelled() else { throw CancellationError() }
        return try snapshot.map { snapshot in
            try LibraryConversationAdapter.reconstruct(
                from: snapshot,
                isCancelled: isCancelled)
        }
    }

    /// Complete selected Conversations use the same read-only WAL connection as their transcript
    /// preview. This is a latency lane, not a second authority: it reads one pinned snapshot and
    /// falls back to the verified primary connection when the optimization could not open.
    func interactiveConversation(
        id: UUID,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> Conversation? {
        let snapshot = try (interactiveReadStore ?? store).authoritativeConversationSnapshot(
            id: id,
            activationID: activationID,
            isCancelled: isCancelled)
        // The SQLite call has released its queue, so a newer click can still avoid reconstruction.
        guard !isCancelled() else { throw CancellationError() }
        return try snapshot.map { snapshot in
            try LibraryConversationAdapter.reconstruct(
                from: snapshot,
                isCancelled: isCancelled)
        }
    }

    /// The newest entries of one Conversation's transcript, for painting it before the whole
    /// record has been reconstructed. Entries only: there is no partial Conversation value here
    /// that could be mistaken for the record and saved over it.
    func recentTranscriptRead(
        id: UUID,
        limit: Int,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> LibraryRecentTranscriptReadResult {
        try (interactiveReadStore ?? store).authoritativeRecentTranscriptRead(
            id: id,
            limit: limit,
            activationID: activationID,
            isCancelled: isCancelled)
    }

    func recentTranscript(id: UUID, limit: Int) throws -> [TranscriptEntry] {
        try recentTranscriptRead(id: id, limit: limit).entries
    }

#if DEBUG
    func setConversationSnapshotQueueTestHook(
        _ hook: (@Sendable (UUID) -> Void)?
    ) {
        store.setConversationSnapshotQueueTestHook(hook)
    }

    func setRecentTranscriptRowTestHook(
        _ hook: (@Sendable () -> Void)?
    ) {
        (interactiveReadStore ?? store).setRecentTranscriptRowTestHook(hook)
    }
#endif



    func workspaceInventory() throws -> LibraryAuthorityWorkspaceInventory {
        let values = try store.authoritativeWorkspaceSnapshots(activationID: activationID)
        guard case .home(let home) = try LibraryWorkspaceAdapter.reconstruct(from: values.home)
        else {
            throw SQLiteLibraryStoreError.invalidInput(
                "authoritative Home Workspace did not reconstruct")
        }
        let workspaces = try values.named.map { snapshot -> Project in
            guard case .named(let value) = try LibraryWorkspaceAdapter.reconstruct(from: snapshot)
            else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "authoritative named Workspace did not reconstruct")
            }
            return value
        }
        return LibraryAuthorityWorkspaceInventory(home: home, workspaces: workspaces)
    }



    func authoritySnapshotGeneration() throws -> LibraryAuthoritySnapshotGeneration {
        let generation = try store.authoritativeSnapshotGeneration(activationID: activationID)
        guard generation.databaseInstanceID == databaseInstanceID else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "authority freshness fence came from another library")
        }
        return generation
    }

    /// Display facts for every live Conversation, in sidebar order, without hydrating any record.
    /// The headless Spotlight and App Intents readers need these and nothing more.
    func conversationSummaries() throws -> [ConversationSummary] {
        try store.authoritativeConversationSummaries(activationID: activationID)
    }

    func artifacts() throws -> [Artifact] {
        try store.authoritativeArtifactSnapshots(activationID: activationID)
            .map(LibraryArtifactAdapter.reconstruct)
    }

    func workspace(id: UUID) throws -> LibraryWorkspaceReconstruction? {
        try store.authoritativeWorkspaceSnapshot(id: id, activationID: activationID)
            .map(LibraryWorkspaceAdapter.reconstruct)
    }

    func artifact(id: UUID) throws -> Artifact? {
        try store.authoritativeArtifactSnapshot(id: id, activationID: activationID)
            .map(LibraryArtifactAdapter.reconstruct)
    }

    func ambientState() throws -> [ShadowLibraryAmbientSnapshot] {
        try store.authoritativeAmbientSnapshots(activationID: activationID)
    }

    /// Exact-key repository observations for every Conversation bound to one Git common directory.
    /// This query never hydrates or searches transcripts.
    func conversationWorkEvidence(
        repositoryID: String
    ) throws -> [ConversationWorkEvidence] {
        try store.authoritativeConversationWorkEvidence(
            repositoryID: repositoryID,
            activationID: activationID)
    }

    /// Exact-key repository observations for one Conversation.
    func conversationWorkEvidence(
        conversationID: UUID
    ) throws -> [ConversationWorkEvidence] {
        try store.authoritativeConversationWorkEvidence(
            conversationID: conversationID,
            activationID: activationID)
    }

    /// Atomically append a repository boundary and any exact file receipts captured with it.
    @discardableResult
    func recordConversationWorkEvidence(
        repository: ConversationRepositoryObservation,
        files: [ConversationFileObservation]
    ) throws -> Int64 {
        try store.commitAuthoritativeConversationWorkEvidence(
            repository: repository,
            files: files,
            activationID: activationID)
    }

    func conversationMediaSourcesChanged(conversationID: UUID) {
        retainedByteMutationLock.lock()
        let current = pendingConversationMediaGenerations[conversationID] ?? 0
        pendingConversationMediaGenerations[conversationID] = current == UInt64.max
            ? UInt64.max : current + 1
        retainedByteMutationLock.unlock()
    }

    /// Conversations the app could not decode, still carrying the quarantine file's identity.
    func recoveredConversationBindings() throws -> [ShadowLibraryRecoveredConversationBinding] {
        try store.recoveredConversationBindings()
    }

    /// Promote a recovered Conversation to a live record.
    ///
    /// Its stored source identity names the `.json.corrupt-*` file the app could not read, and the
    /// launch inventory selects on a canonical `.json` identity. Committing it normally would keep
    /// that identity, so the record would show for the rest of the session and be gone after the
    /// next launch — which is what restoring it used to do.
    @discardableResult
    func restoreRecoveredConversation(
        _ conversation: Conversation
    ) throws -> LibraryAuthorityConversationCommitResult {
        try commit(conversation: conversation, adoptsCanonicalSourceIdentity: true)
    }

    @discardableResult
    func commit(
        conversation: Conversation,
        changedTranscriptEntryIDs: Set<UUID>? = nil,
        priorConversation: Conversation? = nil,
        adoptsCanonicalSourceIdentity: Bool = false
    ) throws -> LibraryAuthorityConversationCommitResult {
        let mediaGeneration = pendingConversationMediaGeneration(conversation.id)
        let retainedByteMutation: LibraryAuthorityRetainedByteMutation?
        if mediaGeneration != nil || Self.retainedByteReferencesMayHaveChanged(
            from: priorConversation,
            to: conversation,
            changedTranscriptEntryIDs: changedTranscriptEntryIDs,
            supportRoot: supportRoot
        ) {
            retainedByteMutation = try makeRetainedByteMutation(for: conversation)
        } else {
            retainedByteMutation = nil
        }
        let priorSource = try store.authoritativeConversationSource(
            id: conversation.id, activationID: activationID)
        let canonicalIdentity = "conversations/\(conversation.id.uuidString).json"
        let source = authoritySource(
            identity: adoptsCanonicalSourceIdentity
                ? canonicalIdentity
                : (priorSource?.identity ?? canonicalIdentity),
            approximateByteCount: priorSource?.byteCount ?? 0)
        let result = try store.commitAuthoritativeMutation(
            conversation: LibraryConversationAdapter.capture(
                conversation,
                source: source,
                changedTranscriptEntryIDs: changedTranscriptEntryIDs),
            changedTranscriptEntryIDs: changedTranscriptEntryIDs,
            // The structural truth for this write. A partial capture names only the entries the
            // caller believes changed; this names every entry the record still holds, so a stale
            // delta can no longer leave a withdrawn row squatting on a live entry's position.
            liveTranscriptOrder: changedTranscriptEntryIDs == nil
                ? nil : conversation.messages.map(\.id),
            retainedByteMutation: retainedByteMutation,
            activationID: activationID)
        if let mediaGeneration {
            clearPendingConversationMediaGeneration(
                conversation.id,
                through: mediaGeneration)
        }
        scheduleProjectionCatchUp()
        return result
    }

    /// Publishes an inbox entity and its applied receipt in the same authority transaction. A
    /// relaunch may repeat the exact capture; receipt identity is idempotent and any collision with
    /// different facts fails closed.
    @discardableResult
    func commit(
        conversation: Conversation,
        adopting capture: LibraryTransientOperationCaptureFactory.Capture
    ) throws -> LibraryAuthorityAdoptionResult {
        let payload = try capture.operation.backgroundAdoptionPayload()
        guard payload.conversationID == conversation.id, payload.artifactID == nil else {
            throw SQLiteLibraryStoreError.invalidInput(
                "background adoption capture does not name this Conversation")
        }
        let prior = try store.authoritativeConversationSnapshot(
            id: conversation.id, activationID: activationID)
        let snapshot = try LibraryConversationAdapter.capture(
            conversation,
            source: authoritySource(
                identity: prior?.source.identity
                    ?? "conversations/\(conversation.id.uuidString).json",
                approximateByteCount: prior?.source.byteCount ?? 0))
        let result = try store.commitAuthoritative(
            conversation: snapshot,
            operation: ShadowLibraryOperationSnapshot(
                operation: capture.operation,
                source: ShadowLibrarySourceFingerprint(
                    identity: payload.sourceIdentity,
                    revision: payload.sourceRevision,
                    digest: payload.sourceDigest,
                    byteCount: 0)),
            receipt: capture.receipt,
            activationID: activationID)
        scheduleProjectionCatchUp()
        return result
    }

    @discardableResult
    func commit(workspace: Project) throws -> Int64 {
        let prior = try store.authoritativeWorkspaceSnapshot(
            id: workspace.id, activationID: activationID)
        let source = authoritySource(
            identity: prior?.source.identity
                ?? "workspaces/\(workspace.id.uuidString).json",
            approximateByteCount: prior?.source.byteCount ?? 0)
        return try store.commitAuthoritativeWorkspaceMutation(
            workspace: LibraryWorkspaceAdapter.capture(workspace, source: source),
            activationID: activationID)
    }

    @discardableResult
    func commit(home settings: HomeWorkspaceSettings) throws -> Int64 {
        let prior = try store.authoritativeWorkspaceSnapshot(
            id: SQLiteLibraryStore.homeWorkspaceID, activationID: activationID)
        let source = authoritySource(
            identity: prior?.source.identity ?? "home-workspace.json",
            approximateByteCount: prior?.source.byteCount ?? 0)
        return try store.commitAuthoritative(
            workspace: LibraryWorkspaceAdapter.capture(home: settings, source: source),
            activationID: activationID)
    }

    @discardableResult
    func commit(artifact: Artifact) throws -> Int64 {
        let prior = try store.authoritativeArtifactSnapshot(
            id: artifact.uuid, activationID: activationID)
        let rawPayload = try prior?.rawSourcePayload
            ?? ArtifactStore.persistedEncoder().encode(artifact)
        let source = artifactAuthoritySource(
            identity: prior?.source.identity ?? "artifacts/\(artifact.uuid.uuidString).json",
            rawPayload: rawPayload)
        return try store.commitAuthoritative(
            artifact: LibraryArtifactAdapter.capture(
                artifact, source: source, preserving: prior),
            activationID: activationID)
    }

    @discardableResult
    func commit(
        artifact: Artifact,
        adopting capture: LibraryTransientOperationCaptureFactory.Capture
    ) throws -> Int64 {
        let prior = try store.authoritativeArtifactSnapshot(
            id: artifact.uuid, activationID: activationID)
        let rawPayload = try prior?.rawSourcePayload
            ?? ArtifactStore.persistedEncoder().encode(artifact)
        let snapshot = try LibraryArtifactAdapter.capture(
            artifact,
            source: artifactAuthoritySource(
                identity: prior?.source.identity ?? "artifacts/\(artifact.uuid.uuidString).json",
                rawPayload: rawPayload),
            preserving: prior)
        return try store.commitAuthoritative(
            artifact: snapshot,
            operation: try operationSnapshot(capture),
            receipt: capture.receipt,
            activationID: activationID)
    }

    /// Persists bounded multi-entity operation facts after the current UI mutation has committed
    /// all affected entity rows. Replays are idempotent at the operation/receipt identities.
    @discardableResult
    func commit(
        captures: [LibraryTransientOperationCaptureFactory.Capture]
    ) throws -> Int64 {
        try store.commitAuthoritativeOperations(
            captures.map {
                (operation: try operationSnapshot($0), receipt: $0.receipt)
            },
            activationID: activationID)
    }

    func adoptBackgroundArtifact(
        candidate: Artifact,
        producerTaskID: String,
        capture: LibraryTransientOperationCaptureFactory.Capture
    ) throws -> LibraryAuthorityArtifactAdoptionResult {
        let payload = try capture.operation.backgroundAdoptionPayload()
        guard payload.artifactID == candidate.uuid,
              payload.conversationID == nil,
              !producerTaskID.isEmpty else {
            throw SQLiteLibraryStoreError.invalidInput(
                "background adoption capture does not name this Artifact/producer")
        }
        let prior = try store.authoritativeArtifactSnapshot(
            id: candidate.uuid, activationID: activationID)
        let operationSource = ShadowLibrarySourceFingerprint(
            identity: payload.sourceIdentity,
            revision: payload.sourceRevision,
            digest: payload.sourceDigest,
            byteCount: 0)
        let rawPayload = try prior?.rawSourcePayload
            ?? ArtifactStore.persistedEncoder().encode(candidate)
        let candidateSource = artifactAuthoritySource(
            identity: prior?.source.identity ?? "artifacts/\(candidate.uuid.uuidString).json",
            rawPayload: rawPayload)
        return try store.adoptAuthoritativeBackgroundArtifact(
            candidate: candidate,
            producerTaskID: producerTaskID,
            source: candidateSource,
            operation: ShadowLibraryOperationSnapshot(
                operation: capture.operation, source: operationSource),
            receipt: capture.receipt,
            activationID: activationID)
    }

    @discardableResult
    func commitAmbientState(_ snapshots: [ShadowLibraryAmbientSnapshot]) throws -> Int64 {
        let rebound = snapshots.map { value in
            ShadowLibraryAmbientSnapshot(
                kind: value.kind,
                payloadVersion: value.payloadVersion,
                payload: value.payload,
                source: authoritySource(
                    identity: value.source.identity,
                    approximateByteCount: value.payload.count))
        }
        return try store.replaceAuthoritativeAmbient(rebound, activationID: activationID)
    }

    @discardableResult
    func deleteConversation(id: UUID) throws -> Int64 {
        let sequence = try store.deleteAuthoritativeConversation(
            id: id, activationID: activationID)
        scheduleProjectionCatchUp()
        return sequence
    }

    /// Release retained-byte sources whose owning Conversation no longer exists, so a backup
    /// that has been refusing for weeks can run again. Returns how many were released.
    @discardableResult
    func releaseOrphanedRetainedByteSources() throws -> Int {
        try store.releaseOrphanedRetainedByteSources(activationID: activationID)
    }

    /// Delete and return the exact cascading work evidence for the in-session Undo receipt. Callers
    /// performing a permanent delete use `deleteConversation(id:)` so those facts are not retained.
    func deleteConversationForUndo(
        id: UUID
    ) throws -> LibraryAuthorityConversationDeleteResult {
        let result = try store.deleteAuthoritativeConversationForUndo(
            id: id,
            activationID: activationID)
        scheduleProjectionCatchUp()
        return result
    }

    @discardableResult
    func deleteWorkspace(id: UUID) throws -> Int64 {
        try store.deleteAuthoritativeWorkspace(id: id, activationID: activationID)
    }

    @discardableResult
    func deleteArtifact(id: UUID) throws -> Int64 {
        try store.deleteAuthoritativeArtifact(id: id, activationID: activationID)
    }

    @discardableResult
    func deleteArtifact(
        id: UUID,
        capture: LibraryTransientOperationCaptureFactory.Capture
    ) throws -> Int64 {
        try store.deleteAuthoritativeArtifact(
            id: id,
            operation: try operationSnapshot(capture),
            receipt: capture.receipt,
            activationID: activationID)
    }

    /// Full SQLite checks are intentionally off the launch path. This records a receipt bound to
    /// the exact sequence it checked; a concurrent commit simply leaves the receipt stale.
    func verifyIntegrityAfterReady() throws {
        _ = try store.integrityCheck()
    }

    // MARK: Conversation retained bytes

    private func pendingConversationMediaGeneration(_ conversationID: UUID) -> UInt64? {
        retainedByteMutationLock.lock()
        defer { retainedByteMutationLock.unlock() }
        return pendingConversationMediaGenerations[conversationID]
    }

    private func clearPendingConversationMediaGeneration(
        _ conversationID: UUID,
        through committedGeneration: UInt64
    ) {
        retainedByteMutationLock.lock()
        defer { retainedByteMutationLock.unlock() }
        if pendingConversationMediaGenerations[conversationID] == committedGeneration {
            pendingConversationMediaGenerations[conversationID] = nil
        }
    }

    /// Build a complete owner-scoped source/reference replacement outside the SQLite transaction,
    /// then let `commitAuthoritativeMutation` publish it atomically with the Conversation event.
    /// Descriptor-stable scanning and permission adoption make the digest a retained-byte fact,
    /// rather than trusting the pathname that the UI just wrote.
    private func makeRetainedByteMutation(
        for conversation: Conversation
    ) throws -> LibraryAuthorityRetainedByteMutation {
        let existing = try store.retainedByteInventory()
        let existingByIdentity = Dictionary(uniqueKeysWithValues: existing.map {
            ($0.source.identity, $0)
        })
        let cached = Dictionary(uniqueKeysWithValues: existing.map {
            ($0.source.identity, $0.source)
        })
        let scan = ArtifactMediaSourceScanner.scanConversationMedia(
            supportRoot: supportRoot,
            conversationID: conversation.id,
            cachedFingerprints: cached)
        guard scan.hasCompleteCensus, scan.issues.isEmpty else {
            let detail = scan.issues.prefix(3).map(\.diagnostics).joined(separator: " ")
            throw SQLiteLibraryStoreError.invalidInput(
                "Conversation media could not be inventoried exactly. \(detail)")
        }

        let extraction = LibraryRetainedByteReferenceExtractor.extract(
            from: conversation,
            supportRoot: supportRoot)
        // An invalid or cross-owner managed path gets no retained-byte edge, which is the whole of
        // what this mutation decides. Refusing the commit instead meant a Conversation that had been
        // forked from one containing an image could not be saved at all: the copy keeps the
        // original's media paths verbatim, so they point into another Conversation's directory.
        // The transcript keeps the path either way and nothing collects `conversation-media`, so
        // there is nothing this refusal protected. It is recorded rather than acted on.
        if !extraction.invalidManagedReferences.isEmpty {
            NSLog(
                "[storage] conversation %@ references %d managed media path(s) it cannot own",
                conversation.id.uuidString,
                extraction.invalidManagedReferences.count)
        }
        let observed = scan.retainedBytes.map { candidate in
            let prior = existingByIdentity[candidate.source.identity]
            return LibraryRetainedByteObservedSource(
                sourceIdentity: candidate.source.identity,
                revision: candidate.source.revision,
                digest: candidate.source.digest,
                byteCount: candidate.source.byteCount,
                mediaType: candidate.mediaType,
                isAdopted: prior?.storageState == .adopted,
                isUnclaimedRecovery: prior?.disposition == .unclaimedRecovery)
        }
        let resolution = LibraryRetainedByteReferenceExtractor.resolve(
            extraction,
            against: observed)
        guard resolution.missing.isEmpty, resolution.mismatched.isEmpty else {
            throw SQLiteLibraryStoreError.invalidInput(
                "Conversation media references do not match the retained bytes on disk")
        }

        let referencedIdentities = Set(resolution.matched.map { $0.source.sourceIdentity })
        let sources = try scan.retainedBytes.map { candidate
            -> ShadowLibraryRetainedByteSnapshot in
            let prior = existingByIdentity[candidate.source.identity]
            if referencedIdentities.contains(candidate.source.identity) {
                let source: ShadowLibrarySourceFingerprint
                if prior?.storageState == .adopted,
                   prior?.disposition == .referenced,
                   prior?.source == candidate.source {
                    source = candidate.source
                } else {
                    source = try LibraryRetainedBytePermissionAdopter.adopt(
                        source: candidate.source,
                        supportRoot: supportRoot)
                }
                return ShadowLibraryRetainedByteSnapshot(
                    kind: .conversationMedia,
                    ownerConversationID: conversation.id,
                    storageName: candidate.storageName,
                    mediaType: candidate.mediaType,
                    linkState: .current,
                    diagnostics: nil,
                    source: source,
                    storageState: .adopted,
                    disposition: .referenced)
            }

            if let prior,
               prior.ownerConversationID == nil,
               prior.disposition == .unclaimedRecovery,
               prior.source == candidate.source {
                return prior
            }
            let source = try LibraryRetainedBytePermissionAdopter.protectUnclaimedRecovery(
                source: candidate.source,
                supportRoot: supportRoot)
            return ShadowLibraryRetainedByteSnapshot(
                kind: .conversationMedia,
                ownerConversationID: nil,
                storageName: candidate.storageName,
                mediaType: candidate.mediaType,
                linkState: .current,
                diagnostics: nil,
                source: source,
                storageState: .observed,
                disposition: .unclaimedRecovery)
        }
        return LibraryAuthorityRetainedByteMutation(
            sources: sources,
            references: resolution.matched.map {
                LibraryRetainedByteReferenceAdapter.capture($0.reference)
            })
    }

    /// Most SQLite commits contain no managed-byte facts. Inspect only transcript rows already
    /// known to have changed, plus the four local prompt surfaces, so ordinary streaming saves keep
    /// the differential fast path even for a 10,000-row Conversation.
    private static func retainedByteReferencesMayHaveChanged(
        from before: Conversation?,
        to after: Conversation,
        changedTranscriptEntryIDs: Set<UUID>?,
        supportRoot: URL
    ) -> Bool {
        let mediaPrefix = supportRoot.standardizedFileURL
            .appendingPathComponent("conversation-media", isDirectory: true)
            .appendingPathComponent(after.id.uuidString, isDirectory: true)
            .path + "/"
        let textMayReferenceMedia: (String) -> Bool = { text in
            text.contains(ConversationFileReference.openingTag) || text.contains(mediaPrefix)
        }
        let entryMayReferenceMedia: (TranscriptEntry?) -> Bool = { entry in
            guard let entry else { return false }
            return entry.toolImage != nil
                || entry.imagePaths?.isEmpty == false
                || textMayReferenceMedia(entry.text)
        }
        let localTexts: (Conversation) -> [String] = { conversation in
            var result = [conversation.draft]
            result.append(contentsOf: conversation.queuedPrompts)
            if let prompt = conversation.pendingTurnPrompt { result.append(prompt) }
            if let request = conversation.providerAccessRequest {
                result.append(contentsOf: request.resumePrompts)
            }
            return result
        }

        guard let before else {
            return after.messages.contains(where: { entryMayReferenceMedia($0) })
                || localTexts(after).contains(where: textMayReferenceMedia)
        }
        let beforeLocal = localTexts(before)
        let afterLocal = localTexts(after)
        if beforeLocal != afterLocal,
           beforeLocal.contains(where: textMayReferenceMedia)
            || afterLocal.contains(where: textMayReferenceMedia) {
            return true
        }
        let beforeByID = Dictionary(uniqueKeysWithValues: before.messages.map { ($0.id, $0) })
        let afterByID = Dictionary(uniqueKeysWithValues: after.messages.map { ($0.id, $0) })
        let changed = changedTranscriptEntryIDs
            ?? Set(beforeByID.keys).union(afterByID.keys)
        return changed.contains { id in
            entryMayReferenceMedia(beforeByID[id]) || entryMayReferenceMedia(afterByID[id])
        }
    }

    // MARK: Durable disposable-projection outbox

    func prepareFullProjectionReplay(projectionSchemaVersion: Int) throws {
        try store.prepareFullProjectionReplay(projectionSchemaVersion: projectionSchemaVersion)
    }

    func nextProjectionWork(
        projectionSchemaVersion: Int
    ) throws -> ShadowLibraryProjectionWorkItem? {
        try store.nextProjectionWork(projectionSchemaVersion: projectionSchemaVersion)
    }

    func acknowledgeProjectionWork(
        _ work: ShadowLibraryProjectionWorkItem,
        projectionSchemaVersion: Int
    ) throws {
        try store.acknowledgeProjectionWork(
            work, projectionSchemaVersion: projectionSchemaVersion)
    }

    func failProjectionWork(
        _ work: ShadowLibraryProjectionWorkItem,
        projectionSchemaVersion: Int,
        diagnostics: String
    ) throws {
        try store.failProjectionWork(
            work,
            projectionSchemaVersion: projectionSchemaVersion,
            diagnostics: diagnostics)
    }

    func failProjectionCatchUp(
        projectionSchemaVersion: Int,
        diagnostics: String
    ) throws {
        try store.failProjectionCatchUp(
            projectionSchemaVersion: projectionSchemaVersion,
            diagnostics: diagnostics)
    }

    func conversationProjectionCacheRequiresRebuild() throws -> Bool {
        try store.conversationProjectionCacheRequiresRebuild()
    }

    func projectionFrontier() throws -> ShadowLibraryProjectionFrontier? {
        try store.projectionFrontier()
    }

    func acknowledgeProjectionFrontier(
        _ frontier: ShadowLibraryProjectionFrontier,
        projectionSchemaVersion: Int
    ) throws {
        try store.acknowledgeExactProjectionSnapshot(
            databaseInstanceID: frontier.databaseInstanceID,
            through: frontier.shadowChangeSequence,
            projectionSchemaVersion: projectionSchemaVersion)
    }

    func acknowledgeExactProjectionSnapshot(
        through sequence: Int64,
        projectionSchemaVersion: Int
    ) throws {
        try store.acknowledgeExactProjectionSnapshot(
            databaseInstanceID: databaseInstanceID,
            through: sequence,
            projectionSchemaVersion: projectionSchemaVersion)
    }

    func projectionBacklogCount() throws -> Int {
        try store.projectionBacklogCount()
    }

    /// Prove or rebuild the disposable cache, then continuously drain the durable outbox. This is
    /// asynchronous and never delays authority launch/readiness.
    func reconcileProjection(
        _ projection: ConversationProjectionStore,
        inventory: LibraryAuthorityLaunchInventory,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let summaries = inventory.conversations.map(\.summary)
        let revisions = Dictionary(uniqueKeysWithValues: inventory.conversations.map {
            ($0.summary.id, $0.sourceRevision)
        })
        projection.matchesAuthoritativeInventory(
            summaries, sourceRevisions: revisions
        ) { [weak self, weak projection] exact in
            guard let self, let projection else {
                completion(false)
                return
            }
            let worker = self.retainProjectionWorker(projection)
            worker.start(
                exactSnapshotSequence: exact ? inventory.committedSequence : nil,
                completion: completion)
        }
    }

    /// Migration receipts remain useful rollback metadata, but after activation they are not
    /// content authorities. Mint a small per-transaction token instead of re-encoding/hash-scanning
    /// a 100 MB Conversation solely to imitate its retired JSON generation.
    private func authoritySource(
        identity: String,
        approximateByteCount: Int
    ) -> ShadowLibrarySourceFingerprint {
        let token = UUID().uuidString.lowercased()
        let digest = SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return ShadowLibrarySourceFingerprint(
            identity: identity,
            revision: "sqlite:\(activationID.uuidString.lowercased()):\(token)",
            digest: digest,
            byteCount: max(0, approximateByteCount))
    }

    private func operationSnapshot(
        _ capture: LibraryTransientOperationCaptureFactory.Capture
    ) throws -> ShadowLibraryOperationSnapshot {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var bytes = try encoder.encode(capture.operation)
        bytes.append(Data("\n".utf8))
        bytes.append(try encoder.encode(capture.receipt))
        let digest = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }.joined()
        return ShadowLibraryOperationSnapshot(
            operation: capture.operation,
            source: ShadowLibrarySourceFingerprint(
                identity: "authority-operation-captures/\(capture.operation.id.uuidString)",
                revision: "sha256:\(digest)",
                digest: digest,
            byteCount: bytes.count))
    }

    private func artifactAuthoritySource(
        identity: String,
        rawPayload: Data
    ) -> ShadowLibrarySourceFingerprint {
        let digest = SHA256.hash(data: rawPayload)
            .map { String(format: "%02x", $0) }.joined()
        return ShadowLibrarySourceFingerprint(
            identity: identity,
            revision: "sqlite:\(activationID.uuidString.lowercased()):\(UUID().uuidString.lowercased())",
            digest: digest,
            byteCount: rawPayload.count)
    }

    private func retainProjectionWorker(
        _ projection: ConversationProjectionStore
    ) -> LibraryAuthorityProjectionWorker {
        projectionWorkerLock.lock()
        defer { projectionWorkerLock.unlock() }
        if let projectionWorker { return projectionWorker }
        let created = LibraryAuthorityProjectionWorker(
            repository: self, projection: projection)
        projectionWorker = created
        return created
    }

    private func scheduleProjectionCatchUp() {
        projectionWorkerLock.lock()
        let worker = projectionWorker
        projectionWorkerLock.unlock()
        worker?.schedule()
    }
}

/// One lightweight asynchronous bridge from committed `library.db` outbox rows to the disposable
/// search cache. It is deliberately repository-owned so every Conversation writer merely schedules
/// the same worker; no product mutation waits for tokenization or FTS I/O.
private final class LibraryAuthorityProjectionWorker: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "ai.mechanician.library-authority-projection", qos: .utility)
    private weak var repository: LibraryAuthorityRepository?
    private weak var projection: ConversationProjectionStore?
    private var inFlight = false
    private var drainRequested = false
    /// Once the disposable cache retires itself, later Conversation saves must not keep reading and
    /// reconstructing full authority snapshots just to rediscover the same session-wide failure.
    /// The next launch rebuilds the cache before exposing it to any Conversation or Memory reader.
    private var projectionTerminated = false
    /// Cached content-free failure text lets later save-triggered schedules restore truthful
    /// authority health without reading or reconstructing another full Conversation snapshot.
    private var terminalDiagnostics: String?
    private var completions: [@MainActor @Sendable (Bool) -> Void] = []

    init(
        repository: LibraryAuthorityRepository,
        projection: ConversationProjectionStore
    ) {
        self.repository = repository
        self.projection = projection
    }

    func start(
        exactSnapshotSequence: Int64?,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        queue.async { [self] in
            completions.append(completion)
            guard let repository else {
                finish(false)
                return
            }
            guard !projectionTerminated else {
                reassertTerminalFailure(repository: repository)
                finish(false)
                return
            }
            guard let projection else {
                finish(false)
                return
            }
            inFlight = true
            if let exactSnapshotSequence {
                projection.bindExactLibrarySnapshot(
                    databaseInstanceID: repository.databaseInstanceID,
                    appliedSequence: exactSnapshotSequence
                ) { [weak self] succeeded in
                    self?.queue.async { [weak self] in
                        guard let self, let repository = self.repository else { return }
                        do {
                            guard succeeded else {
                                self.inFlight = false
                                self.retireProjection(
                                    diagnostics: projection.failureDiagnostics
                                        ?? "projections.db exact-binding transaction failed",
                                    failedWork: nil,
                                    repository: repository)
                                return
                            }
                            try repository.acknowledgeExactProjectionSnapshot(
                                through: exactSnapshotSequence,
                                projectionSchemaVersion:
                                    Int(ConversationProjectionStore.schemaVersion))
                            self.inFlight = false
                            self.drainRequested = true
                            self.drain()
                        } catch {
                            self.finish(false)
                        }
                    }
                }
            } else {
                do {
                    try repository.prepareFullProjectionReplay(
                        projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion))
                    inFlight = false
                    drainRequested = true
                    drain()
                } catch {
                    finish(false)
                }
            }
        }
    }

    func schedule() {
        queue.async { [self] in
            if projectionTerminated {
                if let repository { reassertTerminalFailure(repository: repository) }
                return
            }
            drainRequested = true
            drain()
        }
    }

    private func drain() {
        if projectionTerminated {
            if let repository { reassertTerminalFailure(repository: repository) }
            return
        }
        guard drainRequested, !inFlight,
              let repository, let projection else { return }
        do {
            if let work = try repository.nextProjectionWork(
                projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion)) {
                let conversation = try work.conversation.map(
                    LibraryConversationAdapter.reconstruct)
                inFlight = true
                projection.applyLibraryWorkWithDiagnostics(
                    conversation: conversation,
                    entityID: work.entityID,
                    sourceRevision: work.conversation?.source.revision ?? "",
                    databaseInstanceID: work.databaseInstanceID,
                    desiredSequence: work.desiredSequence,
                    forceReindex: work.forceReindex
                ) { [weak self] succeeded, diagnostics in
                    self?.queue.async { [weak self] in
                        guard let self, let repository = self.repository else { return }
                        self.inFlight = false
                        do {
                            if succeeded {
                                try repository.acknowledgeProjectionWork(
                                    work,
                                    projectionSchemaVersion:
                                        Int(ConversationProjectionStore.schemaVersion))
                                self.drain()
                            } else {
                                self.retireProjection(
                                    diagnostics: diagnostics
                                        ?? "projections.db transaction failed without diagnostics",
                                    failedWork: work,
                                    repository: repository)
                            }
                        } catch {
                            self.finish(false)
                        }
                    }
                }
                return
            }
            guard let frontier = try repository.projectionFrontier() else {
                // A commit landed between the empty-outbox read and closed-frontier capture.
                // Back off instead of recursively spinning; active writers also call `schedule()`,
                // and this bounded retry covers the exact race if that signal already arrived.
                inFlight = true
                queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                    guard let self else { return }
                    self.inFlight = false
                    self.drainRequested = true
                    self.drain()
                }
                return
            }
            inFlight = true
            projection.finalizeLibraryCatchUp(frontier) { [weak self] succeeded in
                self?.queue.async { [weak self] in
                    guard let self, let repository = self.repository else { return }
                    self.inFlight = false
                    do {
                        guard succeeded else {
                            self.retireProjection(
                                diagnostics: projection.failureDiagnostics
                                    ?? "projections.db closed-set transaction failed",
                                failedWork: nil,
                                repository: repository)
                            return
                        }
                        try repository.acknowledgeProjectionFrontier(
                            frontier,
                            projectionSchemaVersion:
                                Int(ConversationProjectionStore.schemaVersion))
                        if try repository.projectionBacklogCount() == 0 {
                            self.finish(true)
                        } else {
                            self.drain()
                        }
                    } catch {
                        self.finish(false)
                    }
                }
            }
        } catch {
            try? repository.failProjectionCatchUp(
                projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion),
                diagnostics: "library projection catch-up failed: \(error.localizedDescription)")
            finish(false)
        }
    }

    private func retireProjection(
        diagnostics: String,
        failedWork: ShadowLibraryProjectionWorkItem?,
        repository: LibraryAuthorityRepository
    ) {
        projectionTerminated = true
        terminalDiagnostics = diagnostics
        NSLog("[projection] %@; the disposable cache will rebuild on next launch", diagnostics)
        persistProjectionFailure(
            diagnostics: diagnostics,
            failedWork: failedWork,
            repository: repository)
        finish(false)
    }

    private func reassertTerminalFailure(repository: LibraryAuthorityRepository) {
        guard let terminalDiagnostics else { return }
        try? repository.failProjectionCatchUp(
            projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion),
            diagnostics: terminalDiagnostics)
    }

    private func persistProjectionFailure(
        diagnostics: String,
        failedWork: ShadowLibraryProjectionWorkItem?,
        repository: LibraryAuthorityRepository
    ) {
        if let failedWork {
            try? repository.failProjectionWork(
                failedWork,
                projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion),
                diagnostics: diagnostics)
        } else {
            try? repository.failProjectionCatchUp(
                projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion),
                diagnostics: diagnostics)
        }
    }

    private func finish(_ succeeded: Bool) {
        inFlight = false
        drainRequested = false
        let callbacks = completions
        completions.removeAll()
        for callback in callbacks {
            Task { @MainActor in callback(succeeded) }
        }
    }
}
