import CryptoKit
import Darwin
import Foundation
import SQLite3

/// The domains reported by the pre-activation `library.db` candidate.
///
/// L1 deliberately introduces domains in checkpoints. A domain that is not represented yet must
/// remain visible as `.notIncluded`, rather than looking complete because its row count is zero.
enum ShadowLibraryDomain: String, CaseIterable, Sendable {
    case conversations
    case workspaces
    case artifactMedia = "artifact_media"
    case operativeState = "operative_state"
    case ambientState = "ambient_state"
    case operations
}

struct ShadowLibrarySourceFingerprint: Equatable, Sendable {
    let identity: String
    let revision: String
    let digest: String
    let byteCount: Int

    init(identity: String, revision: String, digest: String, byteCount: Int) {
        self.identity = identity
        self.revision = revision
        self.digest = digest
        self.byteCount = byteCount
    }

    /// Build the fingerprint from the exact bytes that were decoded by the legacy authority.
    /// Keeping this operation at the adapter boundary prevents a later read from accidentally
    /// comparing SQLite with different bytes than the ones that produced the imported values.
    init(identity: String, revision: String, sourceBytes: Data) {
        self.init(
            identity: identity,
            revision: revision,
            digest: SHA256.hash(data: sourceBytes).map { String(format: "%02x", $0) }.joined(),
            byteCount: sourceBytes.count)
    }

    /// Stable logical source used when `home-workspace.json` does not exist yet. A later real file
    /// keeps this identity and advances its revision/digest instead of creating a second Home row.
    static let implicitHomeWorkspace = ShadowLibrarySourceFingerprint(
        identity: "home-workspace.json",
        revision: "implicit-default-v1",
        sourceBytes: Data("implicit-home-settings-v1".utf8))
}

struct ShadowLibraryWorkspaceSnapshot: Equatable, Sendable {
    enum Kind: String, Sendable {
        case home
        case named
        /// A Conversation names this stable Workspace id, but the current Workspace source is
        /// absent. This preserves membership without inventing Home ownership and remains a
        /// visible mismatch until the source is repaired or the Conversation is deliberately moved.
        case unresolved
    }

    let id: UUID
    let kind: Kind
    let name: String
    let goal: String
    let instructions: String
    let cwd: String
    let favorite: Bool
    let sortIndex: Int?
    let iconSymbol: String?
    let colorHex: String?
    let createdAt: Date
    let updatedAt: Date
    let revision: Int64
    let tombstoned: Bool
    let localStateVersion: Int
    let localStatePayload: Data
    let source: ShadowLibrarySourceFingerprint

    static func home(
        settings: HomeWorkspaceSettings,
        source: ShadowLibrarySourceFingerprint,
        revision: Int64 = 0,
        localStateVersion: Int = 1,
        localStatePayload: Data = Data()
    ) -> Self {
        Self(
            id: SQLiteLibraryStore.homeWorkspaceID,
            kind: .home,
            name: "Home",
            goal: "",
            instructions: settings.instructions,
            cwd: "",
            favorite: false,
            sortIndex: nil,
            iconSymbol: nil,
            colorHex: nil,
            createdAt: settings.updatedAt,
            updatedAt: settings.updatedAt,
            revision: revision,
            tombstoned: false,
            localStateVersion: localStateVersion,
            localStatePayload: localStatePayload,
            source: source)
    }

    static func named(
        _ workspace: Project,
        source: ShadowLibrarySourceFingerprint,
        revision: Int64 = 0,
        localStateVersion: Int = 1,
        localStatePayload: Data = Data()
    ) -> Self {
        Self(
            id: workspace.id,
            kind: .named,
            name: workspace.name,
            goal: workspace.goal,
            instructions: workspace.instructions,
            cwd: workspace.cwd,
            favorite: workspace.favorite,
            sortIndex: workspace.sortIndex,
            iconSymbol: workspace.iconSymbol,
            colorHex: workspace.colorHex,
            createdAt: workspace.createdAt,
            updatedAt: workspace.updatedAt,
            revision: revision,
            tombstoned: false,
            localStateVersion: localStateVersion,
            localStatePayload: localStatePayload,
            source: source)
    }

    init(
        id: UUID,
        kind: Kind,
        name: String,
        goal: String,
        instructions: String,
        cwd: String,
        favorite: Bool,
        sortIndex: Int?,
        iconSymbol: String?,
        colorHex: String?,
        createdAt: Date,
        updatedAt: Date,
        revision: Int64,
        tombstoned: Bool = false,
        localStateVersion: Int = 1,
        localStatePayload: Data = Data(),
        source: ShadowLibrarySourceFingerprint
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.goal = goal
        self.instructions = instructions
        self.cwd = cwd
        self.favorite = favorite
        self.sortIndex = sortIndex
        self.iconSymbol = iconSymbol
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.tombstoned = tombstoned
        self.localStateVersion = localStateVersion
        self.localStatePayload = localStatePayload
        self.source = source
    }
}

/// One canonical ordered fact supplied by the Conversation semantic adapter.
///
/// The shadow store owns ordering and identity columns. Complex versioned content remains a bounded
/// payload at this stage; it is not a giant encoded `Conversation`, and updating one source never
/// requires storing the legacy JSON as the relational record.
struct ShadowLibraryEventSnapshot: Equatable, Sendable {
    let id: UUID
    let captureSequence: Int64
    let kind: String
    let actorID: String?
    let targetID: String?
    let observedAt: Date?
    let providerAt: Date?
    let producingEventID: UUID?
    let causalEventID: UUID?
    let payloadVersion: Int
    let payload: Data

    init(
        id: UUID,
        captureSequence: Int64,
        kind: String,
        actorID: String? = nil,
        targetID: String? = nil,
        observedAt: Date? = nil,
        providerAt: Date? = nil,
        producingEventID: UUID? = nil,
        causalEventID: UUID? = nil,
        payloadVersion: Int = 1,
        payload: Data = Data()
    ) {
        self.id = id
        self.captureSequence = captureSequence
        self.kind = kind
        self.actorID = actorID
        self.targetID = targetID
        self.observedAt = observedAt
        self.providerAt = providerAt
        self.producingEventID = producingEventID
        self.causalEventID = causalEventID
        self.payloadVersion = payloadVersion
        self.payload = payload
    }
}

struct ShadowLibraryConversationSnapshot: Equatable, Sendable {
    let id: UUID
    let title: String
    let titleSource: String
    let cwd: String
    /// Always non-null in SQLite. The adapter maps legacy `nil projectID` to the reserved Home id.
    let workspaceID: UUID
    let updatedAt: Date
    let favorite: Bool
    let sortIndex: Int?
    let unread: Bool
    let errored: Bool
    let revision: Int64
    let tombstoned: Bool
    let localStateVersion: Int
    let localStatePayload: Data
    let source: ShadowLibrarySourceFingerprint
    let events: [ShadowLibraryEventSnapshot]
    /// Conversation-nested artifacts are legacy cache/provenance snapshots, not standalone
    /// artifact authority. Retaining their canonical values separately makes nested-only and
    /// divergent copies visible without promoting either copy over the other.
    let nestedArtifacts: [ShadowLibraryNestedArtifactSnapshot]

    init(
        id: UUID,
        title: String,
        titleSource: String,
        cwd: String,
        workspaceID: UUID?,
        updatedAt: Date,
        favorite: Bool,
        sortIndex: Int?,
        unread: Bool,
        errored: Bool,
        revision: Int64,
        tombstoned: Bool = false,
        localStateVersion: Int = 1,
        localStatePayload: Data = Data(),
        source: ShadowLibrarySourceFingerprint,
        events: [ShadowLibraryEventSnapshot],
        nestedArtifacts: [ShadowLibraryNestedArtifactSnapshot] = []
    ) {
        self.id = id
        self.title = title
        self.titleSource = titleSource
        self.cwd = cwd
        self.workspaceID = workspaceID ?? SQLiteLibraryStore.homeWorkspaceID
        self.updatedAt = updatedAt
        self.favorite = favorite
        self.sortIndex = sortIndex
        self.unread = unread
        self.errored = errored
        self.revision = revision
        self.tombstoned = tombstoned
        self.localStateVersion = localStateVersion
        self.localStatePayload = localStatePayload
        self.source = source
        self.events = events
        self.nestedArtifacts = nestedArtifacts
    }
}

struct ShadowLibraryNestedArtifactSnapshot: Equatable, Sendable {
    let artifactID: UUID
    let canonicalPayload: Data
    let canonicalPayloadDigest: String
    let contentDigest: String
    let contentByteCount: Int
}

/// One standalone artifact source adapted from the current JSON authority.
///
/// The small authored payload is represented exactly in the authority-capable database. Its raw
/// legacy envelope remains bounded during preparation only so unknown ambient/future extension
/// members can be emitted by a fresh-legacy rollback; canonical fields always come from the typed
/// value. `producerTaskID` comes only from raw legacy JSON preflight because `Artifact`
/// intentionally ignores ambientd's extra `taskId` member.
struct ShadowLibraryArtifactSnapshot: Equatable, Sendable {
    let id: UUID
    let title: String
    let type: String
    let origin: String
    let workspaceID: UUID
    let provenanceConversationID: UUID?
    let conversationTitleSnapshot: String
    let cwd: String
    let favorite: Bool
    let createdAt: Date
    let updatedAt: Date
    let revision: Int
    let tombstoned: Bool
    let producerTaskID: String?
    let rawSourcePayload: Data
    let canonicalPayload: Data
    let canonicalPayloadDigest: String
    let content: Data
    let contentDigest: String
    let contentByteCount: Int
    let payloadMediaType: String
    let source: ShadowLibrarySourceFingerprint

    init(
        id: UUID,
        title: String,
        type: String,
        origin: String,
        workspaceID: UUID?,
        provenanceConversationID: UUID?,
        conversationTitleSnapshot: String,
        cwd: String,
        favorite: Bool,
        createdAt: Date,
        updatedAt: Date,
        revision: Int,
        tombstoned: Bool = false,
        producerTaskID: String?,
        rawSourcePayload: Data,
        canonicalPayload: Data,
        canonicalPayloadDigest: String,
        content: Data,
        contentDigest: String,
        contentByteCount: Int,
        payloadMediaType: String,
        source: ShadowLibrarySourceFingerprint
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.origin = origin
        self.workspaceID = workspaceID ?? SQLiteLibraryStore.homeWorkspaceID
        self.provenanceConversationID = provenanceConversationID
        self.conversationTitleSnapshot = conversationTitleSnapshot
        self.cwd = cwd
        self.favorite = favorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.tombstoned = tombstoned
        self.producerTaskID = producerTaskID
        self.rawSourcePayload = rawSourcePayload
        self.canonicalPayload = canonicalPayload
        self.canonicalPayloadDigest = canonicalPayloadDigest
        self.content = content
        self.contentDigest = contentDigest
        self.contentByteCount = contentByteCount
        self.payloadMediaType = payloadMediaType
        self.source = source
    }
}

struct ShadowLibraryRetainedByteSnapshot: Equatable, Sendable {
    enum Kind: String, Sendable {
        case conversationMedia = "conversation_media"
        case conversationTrashMedia = "conversation_trash_media"
    }

    enum LinkState: String, Sendable {
        case current
        case orphan
        case mismatch
    }

    enum StorageClass: String, Sendable {
        case legacyLayout = "legacy_layout"
        case digestAddressed = "digest_addressed"
    }

    enum StorageState: String, Sendable {
        case observed
        case adopted
        case materialized
    }

    enum RetentionState: String, Sendable {
        case live
        case undoRetained = "undo_retained"
    }

    /// Ownership is deliberately separate from the physical path namespace. In particular, an
    /// unclaimed recovery source may sit below a Conversation-named directory without asserting a
    /// durable owner edge to that Conversation.
    enum Disposition: String, Sendable {
        case referencePending = "reference_pending"
        case referenced
        case unclaimedRecovery = "unclaimed_recovery"
        case undoRecovery = "undo_recovery"
    }

    let kind: Kind
    let ownerConversationID: UUID?
    let storageName: String
    let mediaType: String
    let linkState: LinkState
    let diagnostics: String?
    let source: ShadowLibrarySourceFingerprint
    let storageClass: StorageClass
    let storageState: StorageState
    let storageIdentity: String
    let retentionState: RetentionState
    let disposition: Disposition
    let managedBlobDigest: String?

    init(
        kind: Kind,
        ownerConversationID: UUID?,
        storageName: String,
        mediaType: String,
        linkState: LinkState,
        diagnostics: String?,
        source: ShadowLibrarySourceFingerprint,
        storageClass: StorageClass = .legacyLayout,
        storageState: StorageState = .observed,
        storageIdentity: String? = nil,
        retentionState: RetentionState? = nil,
        disposition: Disposition? = nil,
        managedBlobDigest: String? = nil
    ) {
        self.kind = kind
        self.ownerConversationID = ownerConversationID
        self.storageName = storageName
        self.mediaType = mediaType
        self.linkState = linkState
        self.diagnostics = diagnostics
        self.source = source
        self.storageClass = storageClass
        self.storageState = storageState
        self.storageIdentity = storageIdentity ?? source.identity
        self.retentionState = retentionState
            ?? (kind == .conversationTrashMedia ? .undoRetained : .live)
        self.disposition = disposition ?? {
            if kind == .conversationTrashMedia { return .undoRecovery }
            if storageState == .adopted { return .referenced }
            return .referencePending
        }()
        self.managedBlobDigest = managedBlobDigest
    }
}

enum LibraryAuthorityState: String, Equatable, Sendable {
    case shadow
    case prepared
    case active
    case rollbackPrepared = "rollback_prepared"
    case rolledBack = "rolled_back"
}

struct LibraryAuthorityMetadata: Equatable, Sendable {
    let databaseInstanceID: UUID
    let schemaVersion: Int
    let authorityState: LibraryAuthorityState
    let activationID: UUID?
    let rollbackID: UUID?
    let minimumWriterBuild: String?
    let committedSequence: Int64
}

struct ShadowLibraryRetainedByteReferenceSnapshot: Equatable, Sendable {
    enum OwnerKind: String, Sendable {
        case conversation
        case event
        case localState = "local_state"
    }

    let id: UUID
    let retainedSourceIdentity: String
    let ownerKind: OwnerKind
    let ownerConversationID: UUID
    let ownerEventID: UUID?
    let referenceKind: String
}

/// One owner-scoped retained-byte census published with the Conversation facts that reference it.
/// `sources` may include currently unreferenced recovery candidates, while `references` is the
/// complete logical edge set for the committed Conversation generation.
struct LibraryAuthorityRetainedByteMutation: Equatable, Sendable {
    let sources: [ShadowLibraryRetainedByteSnapshot]
    let references: [ShadowLibraryRetainedByteReferenceSnapshot]
}

/// One internally consistent A2 read of a complete Conversation and every managed byte edge it
/// owns. The store builds this value inside a SQLite read transaction: a concurrent shadow update
/// can therefore be observed wholly before or wholly after the bundle, never between its
/// Conversation/event rows, operative-state receipt, references, and retained-source rows.
///
/// `conversationSnapshot` already requires the durable and operative receipts for the same exact
/// legacy source generation. `retainedByteSources` is the complete set of rows currently marked
/// referenced for this Conversation; bundle validation proves that set equals the source identities
/// named by `retainedByteReferences` before exposing anything to the rehearsal reader.
struct ShadowLibraryConversationReadBundle: Equatable, Sendable {
    let conversation: ShadowLibraryConversationSnapshot
    let retainedByteReferences: [ShadowLibraryRetainedByteReferenceSnapshot]
    let retainedByteSources: [ShadowLibraryRetainedByteSnapshot]
}

/// Transcript-free launch facts for one live legacy Conversation represented exactly by the
/// previously verified schema-v6 shadow. The source remains the authority fence: a caller may use
/// this row only after proving that the complete live filesystem census is identical and that this
/// exact generation still occupies `source.identity`.
struct ShadowLibraryLaunchConversationRow: Equatable, Sendable {
    let summary: ConversationSummary
    let source: ShadowLibrarySourceFingerprint
    let artifactIDs: Set<UUID>
    let modelAccess: ModelAccess?
    let requiresIntrinsicResidency: Bool
}

/// One SQLite snapshot of the complete live Conversation/Workspace launch inventory. This is an
/// internal store value: it deliberately carries relative source identities rather than URLs so
/// the coordinator must independently enumerate the legacy filesystem and bind every identity to
/// the exact source generation before exposing a product read.
struct ShadowLibraryLaunchInventoryStoreBundle {
    let databaseInstanceID: UUID
    let shadowChangeSequence: Int64
    let home: ShadowLibraryWorkspaceSnapshot
    let workspaces: [ShadowLibraryWorkspaceSnapshot]
    let conversations: [ShadowLibraryLaunchConversationRow]
    let intrinsicConversations: [Conversation]
}


/// Durable, coalesced work exported from one committed `library.db` shadow mutation. Before
/// activation `desiredSequence` is the honest shadow-change clock; Gate L rebases the drained clock
/// into the first authoritative committed sequence rather than pretending shadow rows are already
/// authority. A nil Conversation is a committed deletion/tombstone.
struct ShadowLibraryProjectionWorkItem: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case conversationSearch = "conversation_search"
    }

    let databaseInstanceID: UUID
    let kind: Kind
    let entityID: UUID
    let desiredSequence: Int64
    let forceReindex: Bool
    let conversation: ShadowLibraryConversationSnapshot?
}

/// Closed-set frontier used only after all coalesced work has been applied. The disposable
/// projection removes ids outside `liveConversationIDs`, binds itself to this database instance,
/// and only then may `library.db` record the high-water as current.
struct ShadowLibraryProjectionFrontier: Equatable, Sendable {
    let databaseInstanceID: UUID
    let shadowChangeSequence: Int64
    let liveConversationIDs: Set<UUID>
}

struct ShadowLibraryArtifactMediaSourceIssue: Equatable, Sendable {
    let source: ShadowLibrarySourceFingerprint
    let entityIdentity: String?
    let kind: ShadowLibrarySourceIssueKind
    let diagnostics: String
}

struct ShadowLibraryImportSnapshot: Equatable, Sendable {
    let home: ShadowLibraryWorkspaceSnapshot
    let workspaces: [ShadowLibraryWorkspaceSnapshot]
    let conversations: [ShadowLibraryConversationSnapshot]

    init(
        home: ShadowLibraryWorkspaceSnapshot,
        workspaces: [ShadowLibraryWorkspaceSnapshot],
        conversations: [ShadowLibraryConversationSnapshot]
    ) {
        self.home = home
        self.workspaces = workspaces
        self.conversations = conversations
    }
}

/// One exact durable ambient source after fail-closed adaptation. Heartbeat and scheduler-lease
/// process state are intentionally not valid values here.
struct ShadowLibraryAmbientSnapshot: Equatable, Sendable {
    let kind: LibraryAmbientAuthoritySourceKind
    let payloadVersion: Int
    let payload: Data
    let source: ShadowLibrarySourceFingerprint
}

struct ShadowLibraryAmbientSourceIssue: Equatable, Sendable {
    let source: ShadowLibrarySourceFingerprint
    let entityIdentity: String?
    let kind: ShadowLibrarySourceIssueKind
    let diagnostics: String
}

struct ShadowLibraryAmbientInventory: Equatable, Sendable {
    let sources: [ShadowLibraryAmbientSnapshot]
    let sourceIssues: [ShadowLibraryAmbientSourceIssue]
    let hasCompleteCensus: Bool

    init(
        sources: [ShadowLibraryAmbientSnapshot],
        sourceIssues: [ShadowLibraryAmbientSourceIssue] = [],
        hasCompleteCensus: Bool = true
    ) {
        self.sources = sources
        self.sourceIssues = sourceIssues
        self.hasCompleteCensus = hasCompleteCensus
    }
}

struct ShadowLibraryOperationSnapshot: Equatable, Sendable {
    let operation: LibraryOperationSnapshot
    let source: ShadowLibrarySourceFingerprint
}

struct ShadowLibraryOperationRetainedSourceSnapshot: Equatable, Sendable {
    enum Kind: String, Sendable {
        case conversationTrashSidecar = "conversation_trash_sidecar"
        case conversationTrashMedia = "conversation_trash_media"
        case quarantineSource = "quarantine_source"
    }

    let operationID: UUID
    let kind: Kind
    let storageIdentity: String
    let mediaType: String
    let retentionState: String
    let referenceKind: String
    let source: ShadowLibrarySourceFingerprint
}

struct ShadowLibraryOperationSourceIssue: Equatable, Sendable {
    let operationID: UUID?
    let source: ShadowLibrarySourceFingerprint
    let kind: ShadowLibrarySourceIssueKind
    let diagnostics: String
}

struct ShadowLibraryOperationInventory: Equatable, Sendable {
    let operations: [ShadowLibraryOperationSnapshot]
    let receipts: [LibraryOperationReceiptSnapshot]
    let retainedSources: [ShadowLibraryOperationRetainedSourceSnapshot]
    let sourceIssues: [ShadowLibraryOperationSourceIssue]
    let hasCompleteCensus: Bool
}

struct ShadowLibraryOperationReadSnapshot: Equatable, Sendable {
    let operations: [LibraryOperationSnapshot]
    let receipts: [LibraryOperationReceiptSnapshot]
    let retainedSources: [ShadowLibraryOperationRetainedSourceSnapshot]
}

enum LibraryAuthorityAdoptionDisposition: Equatable, Sendable {
    case created
    case alreadyApplied
    case identityCollision
}

struct LibraryAuthorityAdoptionResult: Equatable, Sendable {
    let disposition: LibraryAuthorityAdoptionDisposition
    let committedSequence: Int64
}

struct LibraryAuthorityArtifactAdoptionResult: Equatable, Sendable {
    let disposition: LibraryAuthorityAdoptionDisposition
    let artifact: Artifact
    let committedSequence: Int64
}

/// A compact full-corpus census used to reconcile without retaining a second decoded corpus graph.
/// The caller may enumerate source identities first, then decode/adapt/import exactly one source at
/// a time between `beginReconciliation` and `finishReconciliation`.
struct ShadowLibraryReconciliationCensus: Equatable, Sendable {
    let workspaceSourceIdentities: Set<String>
    let conversationSourceIdentities: Set<String>
    /// Nil means this Conversation/Workspace pass does not participate in artifact/media census.
    /// An explicit empty set means the caller proved that the artifact/media source set is empty.
    let artifactMediaSourceIdentities: Set<String>?

    init(
        workspaceSourceIdentities: Set<String>,
        conversationSourceIdentities: Set<String>,
        artifactMediaSourceIdentities: Set<String>? = nil
    ) {
        self.workspaceSourceIdentities = workspaceSourceIdentities
        self.conversationSourceIdentities = conversationSourceIdentities
        self.artifactMediaSourceIdentities = artifactMediaSourceIdentities
    }
}

struct ShadowLibraryReconciliationToken: Equatable, Sendable {
    fileprivate let id: UUID
}

struct ShadowLibraryDomainStatus: Equatable, Sendable {
    enum Phase: String, Sendable {
        case shadowing
        case notIncluded = "not_included"
    }

    let domain: ShadowLibraryDomain
    let phase: Phase
    let imported: Int
    let total: Int
    let current: Int
    let dirty: Int
    let mismatched: Int
    let quarantined: Int
    let errors: Int
    let hasFullCensus: Bool

    var isComplete: Bool {
        phase == .shadowing && hasFullCensus && current == total && dirty == 0 && mismatched == 0
            && quarantined == 0
    }
}

struct ShadowLibraryArtifactMediaStatus: Equatable, Sendable {
    let artifactCount: Int
    /// Physical retained media files. Artifact bodies are counted separately by `artifactCount`.
    let retainedByteSourceCount: Int
    /// Aggregate payload bytes across authored Artifact bodies and retained media files.
    let retainedBytes: Int64
    /// Content-addressed payload cardinality across authored Artifact bodies and retained media.
    let uniquePayloadCount: Int
    let uniqueBytes: Int64
    let duplicateSourceCount: Int
    let duplicateBytes: Int64
    let nestedSnapshotCount: Int
    let nestedOnlyCount: Int
    let divergentCount: Int
    /// Physical legacy-layout byte sources whose complete owning reference set has been proven.
    let adoptedRetainedByteSourceCount: Int
    /// Durable Conversation event/local-state edges to retained bytes.
    let retainedByteReferenceCount: Int
    /// Live Conversation media sources with no durable owner edge. These remain observed, never
    /// silently assigned ownership. A completed A1 pass protects them read-only and records the
    /// explicit `unclaimed_recovery` disposition used by backup and reverse-root rehearsal.
    let unreferencedRetainedByteSourceCount: Int
    /// Exact bytes covered by the explicit unclaimed-recovery disposition.
    let unclaimedRecoveryBytes: Int64
    /// Sources whose physical inventory exists but whose referenced-vs-recovery disposition has
    /// not completed. This must be zero before backup or activation rehearsal.
    let pendingRetainedByteDispositionCount: Int
    /// Every artifact/media source not currently represented cleanly (mismatch, quarantine,
    /// import error, or another dirty/non-current state).
    let sourceIssueCount: Int
    let hasFullCensus: Bool

    /// L1b1 is inventory-only. No managed blob is published and this value cannot be activated.
    let managedBlobsMaterialized = false
}

/// A truthful Storage Status value. This type intentionally has no authority-switching operation:
/// The L1 database is disposable evidence and legacy JSON remains the sole writer.
struct ShadowLibraryStatus: Equatable, Sendable {
    enum CandidateState: String, Sendable {
        case healthyShadow = "healthy_shadow"
        case incompleteShadow = "incomplete_shadow"
    }

    let currentAuthority: String
    let candidateState: CandidateState
    let databaseURL: URL
    let databaseBytes: Int64
    let databaseInstanceID: UUID
    let schemaVersion: Int
    let shadowChangeSequence: Int64
    let authorityState: LibraryAuthorityState
    let wasResetOnOpen: Bool
    let resetReason: String?
    let integrity: ShadowLibraryIntegrityStatus
    let domains: [ShadowLibraryDomainStatus]
    let artifactMedia: ShadowLibraryArtifactMediaStatus?
    /// Structurally lossless legacy recovery sources represented in SQLite even though the current
    /// legacy loader intentionally ignores their `.json.corrupt-*` binding.
    let recoveredConversationCount: Int

    let isAuthority = false
    let isReadyForCutover = false

    func domain(_ domain: ShadowLibraryDomain) -> ShadowLibraryDomainStatus? {
        domains.first { $0.domain == domain }
    }
}

/// One exact legacy sidecar retained under a `.json.corrupt-*` binding and represented losslessly
/// in the SQLite candidate. These bytes are not live Conversation authority until the user
/// explicitly restores them through the guarded recovery surface.
struct ShadowLibraryRecoveredConversationBinding: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let source: ShadowLibrarySourceFingerprint
}

struct ShadowLibraryIntegrityStatus: Equatable, Sendable {
    enum State: String, Sendable {
        case passed
        case pending
    }

    let state: State
    let verifiedAt: Date?
}

enum SQLiteLibraryStoreError: Error, Equatable, LocalizedError {
    case invalidInput(String)
    case sqlite(String)
    case permissions(String)
    case protectedDatabase(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let detail): return "Invalid shadow-library input: \(detail)"
        case .sqlite(let detail): return "Shadow library SQLite failure: \(detail)"
        case .permissions(let detail): return "Shadow library permission failure: \(detail)"
        case .protectedDatabase(let detail):
            return "Existing library database was preserved: \(detail)"
        }
    }
}

enum ShadowLibrarySourceIssueKind: String, Equatable, Sendable {
    case malformed = "quarantine"
    case duplicate = "mismatch"
    case importFailure = "error"
}

/// What a retained-byte readiness finding means for the owning Conversation's operative state.
///
/// The two cases are not degrees of the same thing. A reference the inventory cannot explain —
/// ambiguous, cross-owner, or byte-count/type mismatched — leaves a real question about which bytes
/// the Conversation owns, so its operative facts cannot be trusted and the source is quarantined.
/// A reference whose file is simply **gone** asks no question: the app has always rendered a
/// placeholder for it, the transcript keeps the path verbatim, and no file exists to be wrong about.
/// Recording that as a quarantine blocked the entire cutover over a condition the running product
/// tolerates on every launch.
struct ShadowLibraryRetainedByteReadinessFinding: Equatable, Sendable {
    let diagnostics: String
    /// `true` leaves the Conversation's operative state quarantined; `false` records the finding and
    /// keeps the source current.
    let isBlocking: Bool
}

/// The authoritative Conversation write has already compared individual event rows. Carry this
/// result out of the transaction so an assistant-only stream update can advance the in-memory
/// source receipt after COMMIT without pretending that a user activity band was unchanged.
private struct AuthoritativeConversationUpsertResult {
    let structureChanged: Bool
    let activityRowsChanged: Bool
}

/// L1's resettable `library.db` shadow candidate plus A1's dormant authority-recognition seam.
///
/// This repository is deliberately synchronous and queue-confined. Callers schedule it away from
/// the main actor, after the current JSON write succeeds. The coordinator uses only shadow APIs;
/// authority transitions remain unreferenced until a gated recognition release adopts them.
final class SQLiteLibraryStore: @unchecked Sendable {
    static let homeWorkspaceID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    // ASCII "MECH". `application_id` distinguishes this database from unrelated SQLite files.
    static let applicationID: Int32 = 0x4D45_4348
    static let schemaVersion = 15
    static let maximumLocalStatePayloadBytes = 32 * 1_024 * 1_024

#if DEBUG
    /// Instance-scoped test seams used to prove that the interactive reader neither shares the
    /// authoritative queue nor ignores cancellation between bounded rows.
    private var conversationSnapshotQueueTestHook: (@Sendable (UUID) -> Void)?
    private var recentTranscriptRowTestHook: (@Sendable () -> Void)?
#endif

    let supportRoot: URL
    let databaseURL: URL

    private struct ResetMarker: Codable {
        let formatVersion: Int
        let databaseInstanceID: UUID
    }

    private struct ActiveReconciliation {
        let token: ShadowLibraryReconciliationToken
        let census: ShadowLibraryReconciliationCensus
        var accountedWorkspaceSources = Set<String>()
        var accountedConversationSources = Set<String>()
        var accountedOperativeStateSources = Set<String>()
        var accountedArtifactMediaSources = Set<String>()

        mutating func account(domain: ShadowLibraryDomain, sourceIdentity: String) {
            switch domain {
            case .workspaces: accountedWorkspaceSources.insert(sourceIdentity)
            case .conversations: accountedConversationSources.insert(sourceIdentity)
            case .artifactMedia: accountedArtifactMediaSources.insert(sourceIdentity)
            case .operativeState: accountedOperativeStateSources.insert(sourceIdentity)
            case .ambientState, .operations: break
            }
        }
    }

    private struct NormalizedRetainedByte {
        let linkState: ShadowLibraryRetainedByteSnapshot.LinkState
        let diagnostics: String?

        var importState: String { linkState == .current ? "current" : "mismatch" }
        var entityIsCurrent: Bool { linkState == .current }
    }

    private let queue: DispatchQueue
    private var db: OpaquePointer?
    private let isReadOnly: Bool
    private let activeActivationID: UUID?
    private var resetReason: String?
    private var activeReconciliation: ActiveReconciliation?
    private var resetAuthorizedForOpen = false

    /// Kept byte-for-byte stable because migration 1's persisted checksum is derived from it.
    static let schemaV2Statements = [
        """
        CREATE TABLE library_metadata (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          database_instance_id TEXT NOT NULL,
          schema_version INTEGER NOT NULL,
          application_id INTEGER NOT NULL,
          authority_state TEXT NOT NULL CHECK (authority_state = 'shadow'),
          committed_sequence INTEGER NOT NULL DEFAULT 0,
          shadow_change_sequence INTEGER NOT NULL DEFAULT 0,
          integrity_checked_sequence INTEGER,
          integrity_checked_at REAL,
          integrity_result TEXT,
          created_at REAL NOT NULL,
          last_reset_reason TEXT
        ) STRICT
        """,
        """
        CREATE TABLE schema_migrations (
          migration_id INTEGER PRIMARY KEY,
          checksum TEXT NOT NULL,
          app_build TEXT NOT NULL,
          completed_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE workspaces (
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL CHECK (kind IN ('home', 'named', 'unresolved')),
          name TEXT NOT NULL,
          goal TEXT NOT NULL,
          instructions TEXT NOT NULL,
          cwd TEXT NOT NULL,
          favorite INTEGER NOT NULL CHECK (favorite IN (0, 1)),
          sort_index INTEGER,
          icon_symbol TEXT,
          color_hex TEXT,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          revision INTEGER NOT NULL,
          source_identity TEXT UNIQUE,
          CHECK (
            (kind = 'home' AND id = '00000000-0000-0000-0000-000000000000') OR
            (kind IN ('named', 'unresolved') AND id != '00000000-0000-0000-0000-000000000000')
          )
        ) STRICT
        """,
        "CREATE UNIQUE INDEX one_home_workspace ON workspaces(kind) WHERE kind = 'home'",
        """
        CREATE TABLE conversations (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          title_source TEXT NOT NULL,
          cwd TEXT NOT NULL,
          workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON UPDATE CASCADE ON DELETE RESTRICT,
          updated_at REAL NOT NULL,
          favorite INTEGER NOT NULL CHECK (favorite IN (0, 1)),
          sort_index INTEGER,
          unread INTEGER NOT NULL CHECK (unread IN (0, 1)),
          errored INTEGER NOT NULL CHECK (errored IN (0, 1)),
          revision INTEGER NOT NULL,
          source_identity TEXT NOT NULL UNIQUE
        ) STRICT
        """,
        "CREATE INDEX conversations_workspace_order ON conversations(workspace_id, favorite DESC, sort_index, updated_at DESC)",
        """
        CREATE TABLE conversation_events (
          conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
          id TEXT NOT NULL,
          capture_sequence INTEGER NOT NULL,
          kind TEXT NOT NULL,
          actor_id TEXT,
          target_id TEXT,
          observed_at REAL,
          provider_at REAL,
          producing_event_id TEXT,
          causal_event_id TEXT,
          payload_version INTEGER NOT NULL,
          payload BLOB NOT NULL,
          PRIMARY KEY (conversation_id, id),
          UNIQUE (conversation_id, capture_sequence)
        ) STRICT
        """,
        "CREATE INDEX conversation_events_order ON conversation_events(conversation_id, capture_sequence)",
        """
        CREATE TABLE conversation_artifact_snapshots (
          conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
          artifact_id TEXT NOT NULL,
          canonical_payload BLOB NOT NULL,
          canonical_payload_digest TEXT NOT NULL,
          content_digest TEXT NOT NULL,
          content_byte_count INTEGER NOT NULL CHECK (content_byte_count >= 0),
          PRIMARY KEY (conversation_id, artifact_id)
        ) STRICT
        """,
        "CREATE INDEX conversation_artifact_snapshots_artifact ON conversation_artifact_snapshots(artifact_id)",
        """
        CREATE TABLE artifacts (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          artifact_type TEXT NOT NULL,
          origin TEXT NOT NULL,
          workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON UPDATE CASCADE ON DELETE RESTRICT,
          provenance_conversation_id TEXT,
          conversation_title_snapshot TEXT NOT NULL,
          cwd TEXT NOT NULL,
          favorite INTEGER NOT NULL CHECK (favorite IN (0, 1)),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          revision INTEGER NOT NULL CHECK (revision >= 0),
          producer_task_id TEXT,
          raw_source_payload BLOB NOT NULL,
          canonical_payload BLOB NOT NULL,
          canonical_payload_digest TEXT NOT NULL,
          content BLOB NOT NULL,
          content_digest TEXT NOT NULL,
          content_byte_count INTEGER NOT NULL CHECK (content_byte_count >= 0),
          payload_media_type TEXT NOT NULL,
          source_identity TEXT NOT NULL UNIQUE
        ) STRICT
        """,
        "CREATE INDEX artifacts_workspace_order ON artifacts(workspace_id, favorite DESC, updated_at DESC)",
        "CREATE INDEX artifacts_provenance ON artifacts(provenance_conversation_id)",
        """
        CREATE TABLE retained_byte_sources (
          source_identity TEXT PRIMARY KEY,
          kind TEXT NOT NULL CHECK (kind IN ('conversation_media', 'conversation_trash_media')),
          owner_conversation_id TEXT,
          storage_name TEXT NOT NULL,
          observed_revision TEXT NOT NULL,
          digest TEXT NOT NULL,
          byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
          media_type TEXT NOT NULL,
          link_state TEXT NOT NULL CHECK (link_state IN ('current', 'orphan', 'mismatch')),
          diagnostics TEXT,
          managed_blob_digest TEXT CHECK (managed_blob_digest IS NULL)
        ) STRICT
        """,
        "CREATE INDEX retained_byte_sources_digest ON retained_byte_sources(digest)",
        "CREATE INDEX retained_byte_sources_owner ON retained_byte_sources(owner_conversation_id)",
        """
        CREATE TABLE migration_sources (
          domain TEXT NOT NULL CHECK (domain IN ('conversations', 'workspaces', 'artifact_media')),
          source_identity TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          observed_revision TEXT NOT NULL,
          observed_digest TEXT NOT NULL,
          source_byte_count INTEGER NOT NULL CHECK (source_byte_count >= 0),
          imported_revision TEXT,
          imported_digest TEXT,
          dirty INTEGER NOT NULL CHECK (dirty IN (0, 1)),
          import_state TEXT NOT NULL CHECK (import_state IN ('pending', 'current', 'mismatch', 'error', 'quarantine')),
          diagnostics TEXT,
          imported_at REAL,
          PRIMARY KEY (domain, source_identity)
        ) STRICT
        """,
        "CREATE INDEX migration_sources_state ON migration_sources(domain, import_state, dirty)",
        """
        CREATE TABLE domain_reconciliation (
          domain TEXT PRIMARY KEY CHECK (domain IN ('conversations', 'workspaces', 'artifact_media')),
          full_census_completed_at REAL NOT NULL,
          expected_source_count INTEGER NOT NULL CHECK (expected_source_count >= 0)
        ) STRICT
        """,
    ]

    private static let schemaV3Statements = [
        """
        ALTER TABLE library_metadata RENAME TO library_metadata_v2
        """,
        """
        CREATE TABLE library_metadata (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          database_instance_id TEXT NOT NULL,
          schema_version INTEGER NOT NULL,
          application_id INTEGER NOT NULL,
          authority_state TEXT NOT NULL CHECK (
            authority_state IN ('shadow', 'prepared', 'active', 'rollback_prepared', 'rolled_back')),
          activation_id TEXT,
          rollback_id TEXT,
          minimum_writer_build TEXT,
          committed_sequence INTEGER NOT NULL DEFAULT 0 CHECK (committed_sequence >= 0),
          shadow_change_sequence INTEGER NOT NULL DEFAULT 0 CHECK (shadow_change_sequence >= 0),
          integrity_checked_sequence INTEGER,
          integrity_checked_at REAL,
          integrity_result TEXT,
          created_at REAL NOT NULL,
          last_reset_reason TEXT,
          CHECK (
            (authority_state = 'shadow'
              AND activation_id IS NULL AND rollback_id IS NULL
              AND minimum_writer_build IS NULL AND committed_sequence = 0) OR
            (authority_state IN ('prepared', 'active')
              AND activation_id IS NOT NULL AND rollback_id IS NULL
              AND length(minimum_writer_build) > 0) OR
            (authority_state IN ('rollback_prepared', 'rolled_back')
              AND activation_id IS NOT NULL AND rollback_id IS NOT NULL
              AND length(minimum_writer_build) > 0)
          )
        ) STRICT
        """,
        """
        INSERT INTO library_metadata (
          singleton, database_instance_id, schema_version, application_id, authority_state,
          activation_id, rollback_id, minimum_writer_build, committed_sequence,
          shadow_change_sequence, integrity_checked_sequence, integrity_checked_at,
          integrity_result, created_at, last_reset_reason)
        SELECT singleton, database_instance_id, 3, application_id, authority_state,
               NULL, NULL, NULL, committed_sequence, shadow_change_sequence,
               integrity_checked_sequence, integrity_checked_at, integrity_result,
               created_at, last_reset_reason
        FROM library_metadata_v2
        """,
        "DROP TABLE library_metadata_v2",
        "ALTER TABLE workspaces ADD COLUMN tombstoned INTEGER NOT NULL DEFAULT 0 CHECK (tombstoned IN (0, 1))",
        "ALTER TABLE workspaces ADD COLUMN local_state_version INTEGER NOT NULL DEFAULT 1 CHECK (local_state_version > 0)",
        "ALTER TABLE workspaces ADD COLUMN local_state_payload BLOB NOT NULL DEFAULT X'' CHECK (length(local_state_payload) <= 33554432)",
        "ALTER TABLE conversations ADD COLUMN tombstoned INTEGER NOT NULL DEFAULT 0 CHECK (tombstoned IN (0, 1))",
        "ALTER TABLE conversations ADD COLUMN local_state_version INTEGER NOT NULL DEFAULT 1 CHECK (local_state_version > 0)",
        "ALTER TABLE conversations ADD COLUMN local_state_payload BLOB NOT NULL DEFAULT X'' CHECK (length(local_state_payload) <= 33554432)",
        "ALTER TABLE conversation_artifact_snapshots ADD COLUMN ordinal INTEGER NOT NULL DEFAULT 0 CHECK (ordinal >= 0)",
        """
        UPDATE conversation_artifact_snapshots AS current
        SET ordinal = (
          SELECT COUNT(*) FROM conversation_artifact_snapshots AS prior
          WHERE prior.conversation_id = current.conversation_id
            AND prior.artifact_id < current.artifact_id
        )
        """,
        "CREATE UNIQUE INDEX conversation_artifact_snapshots_order ON conversation_artifact_snapshots(conversation_id, ordinal)",
        "ALTER TABLE artifacts ADD COLUMN tombstoned INTEGER NOT NULL DEFAULT 0 CHECK (tombstoned IN (0, 1))",
        "ALTER TABLE retained_byte_sources RENAME TO retained_byte_sources_v2",
        "DROP INDEX retained_byte_sources_digest",
        "DROP INDEX retained_byte_sources_owner",
        """
        CREATE TABLE retained_byte_sources (
          source_identity TEXT PRIMARY KEY,
          kind TEXT NOT NULL CHECK (kind IN ('conversation_media', 'conversation_trash_media')),
          owner_conversation_id TEXT,
          storage_name TEXT NOT NULL,
          observed_revision TEXT NOT NULL,
          digest TEXT NOT NULL,
          byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
          media_type TEXT NOT NULL,
          link_state TEXT NOT NULL CHECK (link_state IN ('current', 'orphan', 'mismatch')),
          diagnostics TEXT,
          storage_class TEXT NOT NULL CHECK (storage_class IN ('legacy_layout', 'digest_addressed')),
          storage_state TEXT NOT NULL CHECK (storage_state IN ('observed', 'adopted', 'materialized')),
          storage_identity TEXT NOT NULL,
          retention_state TEXT NOT NULL CHECK (retention_state IN ('live', 'undo_retained')),
          managed_blob_digest TEXT,
          CHECK (
            (storage_class = 'legacy_layout' AND storage_state IN ('observed', 'adopted')
              AND managed_blob_digest IS NULL) OR
            (storage_class = 'digest_addressed' AND storage_state = 'materialized'
              AND managed_blob_digest = digest)
          )
        ) STRICT
        """,
        """
        INSERT INTO retained_byte_sources (
          source_identity, kind, owner_conversation_id, storage_name, observed_revision,
          digest, byte_count, media_type, link_state, diagnostics, storage_class,
          storage_state, storage_identity, retention_state, managed_blob_digest)
        SELECT source_identity, kind, owner_conversation_id, storage_name, observed_revision,
               digest, byte_count, media_type, link_state, diagnostics, 'legacy_layout',
               'observed', source_identity,
               CASE WHEN kind = 'conversation_trash_media' THEN 'undo_retained' ELSE 'live' END,
               NULL
        FROM retained_byte_sources_v2
        """,
        "DROP TABLE retained_byte_sources_v2",
        "CREATE INDEX retained_byte_sources_digest ON retained_byte_sources(digest)",
        "CREATE INDEX retained_byte_sources_owner ON retained_byte_sources(owner_conversation_id)",
        """
        CREATE TABLE retained_byte_references (
          reference_id TEXT PRIMARY KEY,
          retained_source_identity TEXT NOT NULL
            REFERENCES retained_byte_sources(source_identity) ON DELETE CASCADE,
          owner_kind TEXT NOT NULL CHECK (owner_kind IN ('conversation', 'event', 'local_state')),
          owner_conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
          owner_event_id TEXT,
          reference_kind TEXT NOT NULL,
          FOREIGN KEY (owner_conversation_id, owner_event_id)
            REFERENCES conversation_events(conversation_id, id) ON DELETE CASCADE,
          CHECK (
            (owner_kind = 'event' AND owner_event_id IS NOT NULL) OR
            (owner_kind IN ('conversation', 'local_state') AND owner_event_id IS NULL)
          ),
          UNIQUE (retained_source_identity, owner_kind, owner_conversation_id, owner_event_id, reference_kind)
        ) STRICT
        """,
        "CREATE INDEX retained_byte_references_owner ON retained_byte_references(owner_conversation_id, owner_kind)",
        "ALTER TABLE migration_sources RENAME TO migration_sources_v2",
        "DROP INDEX migration_sources_state",
        """
        CREATE TABLE migration_sources (
          domain TEXT NOT NULL CHECK (domain IN ('conversations', 'workspaces', 'artifact_media', 'operative_state')),
          source_identity TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          observed_revision TEXT NOT NULL,
          observed_digest TEXT NOT NULL,
          source_byte_count INTEGER NOT NULL CHECK (source_byte_count >= 0),
          imported_revision TEXT,
          imported_digest TEXT,
          dirty INTEGER NOT NULL CHECK (dirty IN (0, 1)),
          import_state TEXT NOT NULL CHECK (import_state IN ('pending', 'current', 'mismatch', 'error', 'quarantine')),
          diagnostics TEXT,
          imported_at REAL,
          PRIMARY KEY (domain, source_identity)
        ) STRICT
        """,
        """
        INSERT INTO migration_sources
        SELECT * FROM migration_sources_v2
        """,
        "DROP TABLE migration_sources_v2",
        "CREATE INDEX migration_sources_state ON migration_sources(domain, import_state, dirty)",
        "ALTER TABLE domain_reconciliation RENAME TO domain_reconciliation_v2",
        """
        CREATE TABLE domain_reconciliation (
          domain TEXT PRIMARY KEY CHECK (domain IN ('conversations', 'workspaces', 'artifact_media', 'operative_state')),
          full_census_completed_at REAL NOT NULL,
          expected_source_count INTEGER NOT NULL CHECK (expected_source_count >= 0)
        ) STRICT
        """,
        "INSERT INTO domain_reconciliation SELECT * FROM domain_reconciliation_v2",
        "DROP TABLE domain_reconciliation_v2",
        // V2 rows have no operative-state payload. Force Conversation/Workspace decode once so
        // their bounded local state cannot appear current merely because durable content matched.
        "DELETE FROM domain_reconciliation WHERE domain IN ('conversations', 'workspaces', 'operative_state')",
        """
        UPDATE migration_sources
        SET dirty = 1, import_state = 'pending', imported_revision = NULL,
            imported_digest = NULL, imported_at = NULL
        WHERE domain IN ('conversations', 'workspaces')
        """,
    ]

    private static let schemaV4Statements = [
        "ALTER TABLE migration_sources RENAME TO migration_sources_v3",
        "DROP INDEX migration_sources_state",
        """
        CREATE TABLE migration_sources (
          domain TEXT NOT NULL CHECK (domain IN (
            'conversations', 'workspaces', 'artifact_media', 'operative_state',
            'ambient_state', 'operations')),
          source_identity TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          observed_revision TEXT NOT NULL,
          observed_digest TEXT NOT NULL,
          source_byte_count INTEGER NOT NULL CHECK (source_byte_count >= 0),
          imported_revision TEXT,
          imported_digest TEXT,
          dirty INTEGER NOT NULL CHECK (dirty IN (0, 1)),
          import_state TEXT NOT NULL CHECK (
            import_state IN ('pending', 'current', 'mismatch', 'error', 'quarantine')),
          diagnostics TEXT,
          imported_at REAL,
          PRIMARY KEY (domain, source_identity)
        ) STRICT
        """,
        "INSERT INTO migration_sources SELECT * FROM migration_sources_v3",
        "DROP TABLE migration_sources_v3",
        "CREATE INDEX migration_sources_state ON migration_sources(domain, import_state, dirty)",
        "ALTER TABLE domain_reconciliation RENAME TO domain_reconciliation_v3",
        """
        CREATE TABLE domain_reconciliation (
          domain TEXT PRIMARY KEY CHECK (domain IN (
            'conversations', 'workspaces', 'artifact_media', 'operative_state',
            'ambient_state', 'operations')),
          full_census_completed_at REAL NOT NULL,
          expected_source_count INTEGER NOT NULL CHECK (expected_source_count >= 0)
        ) STRICT
        """,
        "INSERT INTO domain_reconciliation SELECT * FROM domain_reconciliation_v3",
        "DROP TABLE domain_reconciliation_v3",
        """
        CREATE TABLE ambient_authority_sources (
          kind TEXT PRIMARY KEY CHECK (kind IN (
            'ambient_task_definitions', 'ambient_scheduler_runtime', 'ambient_run_receipts')),
          source_identity TEXT NOT NULL UNIQUE,
          payload_version INTEGER NOT NULL CHECK (payload_version > 0),
          payload BLOB NOT NULL CHECK (length(payload) <= 16777216)
        ) STRICT
        """,
        """
        CREATE TABLE operations (
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL CHECK (kind IN (
            'conversation_delete', 'artifact_delete', 'workspace_move',
            'background_adoption')),
          state TEXT NOT NULL CHECK (state IN (
            'prepared', 'committed', 'reversed', 'failed', 'quarantined')),
          format_version INTEGER NOT NULL CHECK (format_version > 0),
          idempotency_key TEXT NOT NULL UNIQUE,
          payload_version INTEGER NOT NULL CHECK (payload_version > 0),
          payload BLOB NOT NULL CHECK (length(payload) <= 1048576),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          source_identity TEXT NOT NULL UNIQUE
        ) STRICT
        """,
        "CREATE INDEX operations_state ON operations(state, updated_at)",
        """
        CREATE TABLE operation_receipts (
          id TEXT PRIMARY KEY,
          operation_id TEXT NOT NULL REFERENCES operations(id) ON DELETE CASCADE,
          operation_kind TEXT NOT NULL CHECK (operation_kind IN (
            'conversation_delete', 'artifact_delete', 'workspace_move',
            'background_adoption')),
          state TEXT NOT NULL CHECK (state IN (
            'pending', 'applied', 'reversed', 'failed', 'quarantined')),
          format_version INTEGER NOT NULL CHECK (format_version > 0),
          attempt INTEGER NOT NULL CHECK (attempt >= 0),
          recorded_at REAL NOT NULL,
          payload_version INTEGER NOT NULL CHECK (payload_version > 0),
          payload BLOB NOT NULL CHECK (length(payload) <= 65536),
          UNIQUE (operation_id, attempt)
        ) STRICT
        """,
        "CREATE INDEX operation_receipts_operation ON operation_receipts(operation_id)",
        """
        CREATE TABLE operation_retained_sources (
          source_identity TEXT PRIMARY KEY,
          operation_id TEXT NOT NULL REFERENCES operations(id) ON DELETE CASCADE,
          kind TEXT NOT NULL CHECK (kind IN (
            'conversation_trash_sidecar', 'conversation_trash_media', 'quarantine_source')),
          storage_identity TEXT NOT NULL,
          observed_revision TEXT NOT NULL,
          digest TEXT NOT NULL CHECK (length(digest) = 64),
          byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
          media_type TEXT NOT NULL,
          retention_state TEXT NOT NULL CHECK (retention_state IN ('undo_retained', 'quarantined')),
          reference_kind TEXT NOT NULL
        ) STRICT
        """,
        "CREATE INDEX operation_retained_sources_operation ON operation_retained_sources(operation_id)",
    ]

    private static let schemaV5Statements = [
        """
        ALTER TABLE retained_byte_sources ADD COLUMN disposition TEXT NOT NULL
          DEFAULT 'reference_pending' CHECK (disposition IN (
            'reference_pending', 'referenced', 'unclaimed_recovery', 'undo_recovery'))
        """,
        """
        UPDATE retained_byte_sources
        SET disposition = CASE
          WHEN kind = 'conversation_trash_media' THEN 'undo_recovery'
          WHEN storage_state = 'adopted' THEN 'referenced'
          ELSE 'reference_pending'
        END
        """,
        "CREATE INDEX retained_byte_sources_disposition ON retained_byte_sources(disposition)",
    ]

    /// A2b2's durable bridge from the resettable library candidate to the independently disposable
    /// summary/FTS database. Triggers run inside the same transaction as each Conversation mutation,
    /// so a crash can leave either neither fact or both the current row and its replayable job.
    private static let schemaV6Statements = [
        """
        CREATE TABLE projection_outbox (
          database_instance_id TEXT NOT NULL,
          projection_kind TEXT NOT NULL CHECK (projection_kind = 'conversation_search'),
          entity_id TEXT NOT NULL,
          desired_sequence INTEGER NOT NULL CHECK (desired_sequence >= 0),
          force_reindex INTEGER NOT NULL DEFAULT 0 CHECK (force_reindex IN (0, 1)),
          attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
          last_attempt_at REAL,
          last_error TEXT,
          PRIMARY KEY (database_instance_id, projection_kind, entity_id)
        ) STRICT
        """,
        "CREATE INDEX projection_outbox_order ON projection_outbox(projection_kind, desired_sequence, entity_id)",
        """
        CREATE TABLE projection_state (
          database_instance_id TEXT NOT NULL,
          projection_kind TEXT NOT NULL CHECK (projection_kind = 'conversation_search'),
          projection_schema_version INTEGER NOT NULL CHECK (projection_schema_version >= 0),
          applied_high_water_sequence INTEGER NOT NULL DEFAULT 0
            CHECK (applied_high_water_sequence >= 0),
          health TEXT NOT NULL CHECK (health IN ('queued', 'projecting', 'current', 'failed')),
          last_error TEXT,
          updated_at REAL NOT NULL,
          PRIMARY KEY (database_instance_id, projection_kind)
        ) STRICT
        """,
        """
        CREATE TRIGGER conversation_projection_insert
        AFTER INSERT ON conversations
        BEGIN
          INSERT INTO projection_outbox (
            database_instance_id, projection_kind, entity_id, desired_sequence)
          SELECT database_instance_id, 'conversation_search', NEW.id,
                 shadow_change_sequence + 1
          FROM library_metadata WHERE singleton = 1
          ON CONFLICT(database_instance_id, projection_kind, entity_id) DO UPDATE SET
            desired_sequence = MAX(projection_outbox.desired_sequence, excluded.desired_sequence),
            last_error = NULL;
          UPDATE projection_state
          SET health = 'queued', last_error = NULL,
              updated_at = CAST(strftime('%s', 'now') AS REAL) - 978307200.0
          WHERE database_instance_id = (
            SELECT database_instance_id FROM library_metadata WHERE singleton = 1)
            AND projection_kind = 'conversation_search';
        END
        """,
        """
        CREATE TRIGGER conversation_projection_update
        AFTER UPDATE ON conversations
        BEGIN
          INSERT INTO projection_outbox (
            database_instance_id, projection_kind, entity_id, desired_sequence)
          SELECT database_instance_id, 'conversation_search', NEW.id,
                 shadow_change_sequence + 1
          FROM library_metadata WHERE singleton = 1
          ON CONFLICT(database_instance_id, projection_kind, entity_id) DO UPDATE SET
            desired_sequence = MAX(projection_outbox.desired_sequence, excluded.desired_sequence),
            last_error = NULL;
          UPDATE projection_state
          SET health = 'queued', last_error = NULL,
              updated_at = CAST(strftime('%s', 'now') AS REAL) - 978307200.0
          WHERE database_instance_id = (
            SELECT database_instance_id FROM library_metadata WHERE singleton = 1)
            AND projection_kind = 'conversation_search';
        END
        """,
        """
        CREATE TRIGGER conversation_projection_delete
        AFTER DELETE ON conversations
        BEGIN
          INSERT INTO projection_outbox (
            database_instance_id, projection_kind, entity_id, desired_sequence)
          SELECT database_instance_id, 'conversation_search', OLD.id,
                 shadow_change_sequence + 1
          FROM library_metadata WHERE singleton = 1
          ON CONFLICT(database_instance_id, projection_kind, entity_id) DO UPDATE SET
            desired_sequence = MAX(projection_outbox.desired_sequence, excluded.desired_sequence),
            last_error = NULL;
          UPDATE projection_state
          SET health = 'queued', last_error = NULL,
              updated_at = CAST(strftime('%s', 'now') AS REAL) - 978307200.0
          WHERE database_instance_id = (
            SELECT database_instance_id FROM library_metadata WHERE singleton = 1)
            AND projection_kind = 'conversation_search';
        END
        """,
        // Existing projection rows came from these same exact Legacy generations, but have no
        // durable acknowledgement yet. An exact launch can adopt them without rewriting; any
        // mismatch replays these jobs from library.db and removes projection orphans at the end.
        """
        INSERT INTO projection_outbox (
          database_instance_id, projection_kind, entity_id, desired_sequence)
        SELECT metadata.database_instance_id, 'conversation_search', conversations.id,
               metadata.shadow_change_sequence
        FROM conversations, library_metadata AS metadata
        WHERE metadata.singleton = 1 AND conversations.tombstoned = 0
        """,
        """
        INSERT INTO projection_state (
          database_instance_id, projection_kind, projection_schema_version,
          applied_high_water_sequence, health, last_error, updated_at)
        SELECT database_instance_id, 'conversation_search', 0, 0, 'queued', NULL, 0.0
        FROM library_metadata WHERE singleton = 1
        """,
    ]

    /// Memory: the durable, cross-workspace, cross-provider store the wiki is a view of.
    ///
    /// The unit of truth is a CLAIM, not a page. A page composes claims and is what the user reads;
    /// a claim is what gets written, retrieved, superseded, and deleted individually. Storing whole
    /// pages as Markdown would make provenance, partial supersession, and conflict resolution
    /// guesswork the moment anything but a human edits them.
    ///
    /// Three dimensions are kept deliberately separate and must never be collapsed into one column.
    /// `scope` is who may see it, `origin` is where it came from, and `provider_policy` is which
    /// routes may receive it. A fact LEARNED while using Claude usually applies everywhere; a fact
    /// ABOUT Claude applies only to Claude. Origin is not applicability, and conflating them is how
    /// a personal memory ends up disclosed to a managed corporate route.
    ///
    /// Nothing here is written by any code path yet. This ships the authority dark, so the schema
    /// migration and its recovery behavior are proven before a UI or a capture path depends on it.
    private static let schemaV7Statements = [
        """
        CREATE TABLE memory_page (
          id TEXT PRIMARY KEY,
          slug TEXT NOT NULL,
          title TEXT NOT NULL,
          summary TEXT NOT NULL DEFAULT '',
          kind TEXT NOT NULL DEFAULT 'topic'
            CHECK (kind IN ('topic', 'person', 'project', 'index')),
          scope TEXT NOT NULL CHECK (scope IN ('global', 'workspace', 'private')),
          -- Workspace-scoped memory dies with its workspace; global and private memory has no
          -- workspace and is untouched. This deliberately differs from `artifacts`, which RESTRICTs:
          -- refusing to delete a workspace because something once learned a fact about it would be
          -- a worse outcome than dropping memory whose subject no longer exists.
          workspace_id TEXT REFERENCES workspaces(id) ON UPDATE CASCADE ON DELETE CASCADE,
          pinned INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0, 1)),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          deleted_at REAL,
          CHECK ((scope = 'workspace' AND workspace_id IS NOT NULL)
                 OR (scope IN ('global', 'private') AND workspace_id IS NULL))
        ) STRICT
        """,
        "CREATE INDEX memory_page_scope ON memory_page(scope, workspace_id, deleted_at)",
        // COALESCE, not a plain `UNIQUE (slug, scope, workspace_id)`. NULL never equals NULL in
        // SQL, so a bare unique constraint would not constrain global or private pages at all —
        // exactly the rows where `workspace_id` is always NULL. The same trap is why the tombstone
        // index below is written this way.
        """
        CREATE UNIQUE INDEX memory_page_identity
        ON memory_page(slug, scope, COALESCE(workspace_id, ''))
        """,
        """
        CREATE TABLE memory_claim (
          id TEXT PRIMARY KEY,
          page_id TEXT NOT NULL REFERENCES memory_page(id) ON DELETE CASCADE,
          ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
          text TEXT NOT NULL,
          -- Normalized-text hash. Dedupes on capture and is what a tombstone remembers, so
          -- "forget that" means "do not learn it again" rather than "delete it until next time".
          fingerprint TEXT NOT NULL,
          status TEXT NOT NULL
            CHECK (status IN ('proposed', 'active', 'superseded', 'rejected')),
          confidence REAL NOT NULL DEFAULT 0.0 CHECK (confidence >= 0.0 AND confidence <= 1.0),
          scope TEXT NOT NULL CHECK (scope IN ('global', 'workspace', 'private')),
          workspace_id TEXT REFERENCES workspaces(id) ON UPDATE CASCADE ON DELETE CASCADE,
          provider_policy TEXT NOT NULL DEFAULT 'all',
          origin TEXT NOT NULL
            CHECK (origin IN ('user_turn', 'user_authored', 'import_claude',
                              'import_codex', 'file')),
          valid_from REAL,
          valid_until REAL,
          superseded_by TEXT REFERENCES memory_claim(id) ON DELETE SET NULL,
          confirmed_by_user INTEGER NOT NULL DEFAULT 0 CHECK (confirmed_by_user IN (0, 1)),
          last_used_at REAL,
          use_count INTEGER NOT NULL DEFAULT 0 CHECK (use_count >= 0),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          deleted_at REAL,
          CHECK ((scope = 'workspace' AND workspace_id IS NOT NULL)
                 OR (scope IN ('global', 'private') AND workspace_id IS NULL))
        ) STRICT
        """,
        "CREATE INDEX memory_claim_page ON memory_claim(page_id, ordinal)",
        // The retrieval filter runs on exactly these columns, before ranking, so an out-of-scope
        // claim can never enter a ranked list where a later bug could leak it.
        "CREATE INDEX memory_claim_retrieval ON memory_claim(status, scope, workspace_id, deleted_at)",
        "CREATE INDEX memory_claim_fingerprint ON memory_claim(fingerprint)",
        """
        CREATE TABLE memory_source (
          id TEXT PRIMARY KEY,
          claim_id TEXT NOT NULL REFERENCES memory_claim(id) ON DELETE CASCADE,
          kind TEXT NOT NULL
            CHECK (kind IN ('user_turn', 'user_authored', 'import', 'file')),
          provider TEXT,
          conversation_id TEXT,
          entry_id TEXT,
          -- The verbatim span of the user's own message that asserts the claim. This is the whole
          -- capture gate: a candidate whose quote does not string-match the persisted entry is
          -- discarded, which is what keeps "automatic" from becoming "inferred".
          quote TEXT NOT NULL,
          external_path TEXT,
          captured_at REAL NOT NULL
        ) STRICT
        """,
        "CREATE INDEX memory_source_claim ON memory_source(claim_id)",
        "CREATE INDEX memory_source_conversation ON memory_source(conversation_id)",
        """
        CREATE TABLE memory_link (
          from_page_id TEXT NOT NULL REFERENCES memory_page(id) ON DELETE CASCADE,
          to_page_id TEXT NOT NULL REFERENCES memory_page(id) ON DELETE CASCADE,
          kind TEXT NOT NULL DEFAULT 'related',
          created_at REAL NOT NULL,
          PRIMARY KEY (from_page_id, to_page_id, kind),
          CHECK (from_page_id <> to_page_id)
        ) STRICT
        """,
        // Backlinks are a query against this index, never a second stored row.
        "CREATE INDEX memory_link_backlink ON memory_link(to_page_id)",
        """
        CREATE TABLE memory_alias (
          page_id TEXT NOT NULL REFERENCES memory_page(id) ON DELETE CASCADE,
          alias TEXT NOT NULL,
          PRIMARY KEY (page_id, alias)
        ) STRICT
        """,
        """
        CREATE TABLE memory_tombstone (
          id TEXT PRIMARY KEY,
          fingerprint TEXT NOT NULL,
          scope TEXT NOT NULL CHECK (scope IN ('global', 'workspace', 'private')),
          workspace_id TEXT REFERENCES workspaces(id) ON UPDATE CASCADE ON DELETE CASCADE,
          reason TEXT NOT NULL DEFAULT 'user_removed',
          created_at REAL NOT NULL
        ) STRICT
        """,
        // "Do not learn this again" is one durable statement, not one per attempt. See the page
        // identity index above for why this cannot be a plain UNIQUE constraint.
        """
        CREATE UNIQUE INDEX memory_tombstone_identity
        ON memory_tombstone(fingerprint, scope, COALESCE(workspace_id, ''))
        """,
        """
        CREATE TABLE memory_revision (
          id TEXT PRIMARY KEY,
          target_kind TEXT NOT NULL CHECK (target_kind IN ('page', 'claim')),
          target_id TEXT NOT NULL,
          before_json TEXT,
          after_json TEXT,
          actor TEXT NOT NULL CHECK (actor IN ('user', 'agent', 'import', 'system')),
          created_at REAL NOT NULL
        ) STRICT
        """,
        "CREATE INDEX memory_revision_target ON memory_revision(target_kind, target_id, created_at)",
    ]

    /// Page identity constrains LIVE pages only.
    ///
    /// v7 shipped `memory_page_identity` over every row, deleted or not. A page is soft-deleted
    /// (`deleted_at` set, claims soft-deleted with it), so deleting "About me" burned that slug
    /// permanently: the next profile build tried to create the page again and died on
    /// `UNIQUE constraint failed: index 'memory_page_identity'`, having written nothing. Deleting a
    /// page and starting over is an ordinary thing to want, and it was unrecoverable from the UI.
    ///
    /// The tombstone index is deliberately NOT changed. A tombstone has no `deleted_at` — "do not
    /// learn this again" is permanent by design, and one durable statement per fact is correct.
    private static let schemaV8Statements = [
        "DROP INDEX memory_page_identity",
        """
        CREATE UNIQUE INDEX memory_page_identity
        ON memory_page(slug, scope, COALESCE(workspace_id, ''))
        WHERE deleted_at IS NULL
        """,
    ]

    /// v9: a tombstone remembers the SENTENCE, not only its fingerprint.
    ///
    /// The fingerprint is SHA-256 of the exact statement, so a retraction blocked that exact wording
    /// and nothing else. Proven on a real library: a fact retracted in the afternoon came back on the
    /// next rebuild reworded, with a different fingerprint, and the tombstone never saw it. "Forget
    /// that" meant "forget that until it is phrased differently", and retraction is the whole safety
    /// story of a wiki that writes without asking.
    ///
    /// A column with a default rather than a table rebuild, so nothing existing is rewritten: the
    /// tombstones already on disk keep working by fingerprint and simply have no sentence to compare
    /// meaning against, which is honest — nobody recorded one at the time.
    private static let schemaV9Statements = [
        "ALTER TABLE memory_tombstone ADD COLUMN statement TEXT NOT NULL DEFAULT ''",
    ]

    /// v10: durable Memrank feedback.
    ///
    /// These rows are behavioral relationship evidence, not statement truth or derived rank. They
    /// therefore live beside the claims and conversations that give their coordinates meaning, but
    /// contain no prompt, statement, page title, vector, or score. Both transcript coordinates use
    /// composite foreign keys so a caller cannot splice a card or anchor from another Conversation.
    /// Deleting either the Conversation or statement removes its feedback rather than broadening a
    /// now-unreconstructible context into a Workspace-level relationship.
    private static let schemaV10Statements = [
        """
        CREATE TABLE memory_association_feedback (
          id TEXT PRIMARY KEY,
          claim_id TEXT NOT NULL REFERENCES memory_claim(id) ON DELETE CASCADE,
          conversation_id TEXT NOT NULL,
          anchor_entry_id TEXT NOT NULL,
          disclosure_entry_id TEXT NOT NULL,
          workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON UPDATE CASCADE ON DELETE CASCADE,
          subject_page_id TEXT REFERENCES memory_page(id) ON DELETE SET NULL,
          access TEXT NOT NULL CHECK (access IN (
            'claude_subscription', 'anthropic_api', 'codex_subscription', 'openai_api',
            'claude_vertex', 'claude_bedrock')),
          verdict TEXT NOT NULL CHECK (verdict IN ('useful', 'not_useful')),
          created_at REAL NOT NULL,
          FOREIGN KEY (conversation_id, anchor_entry_id)
            REFERENCES conversation_events(conversation_id, id) ON DELETE CASCADE,
          FOREIGN KEY (conversation_id, disclosure_entry_id)
            REFERENCES conversation_events(conversation_id, id) ON DELETE CASCADE
        ) STRICT
        """,
        """
        CREATE INDEX memory_association_feedback_latest
        ON memory_association_feedback(
          claim_id, conversation_id, anchor_entry_id, created_at DESC, id DESC)
        """,
        """
        CREATE INDEX memory_association_feedback_conversation
        ON memory_association_feedback(conversation_id, disclosure_entry_id)
        """,
        """
        CREATE TABLE memrank_input_state (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          generation INTEGER NOT NULL CHECK (generation >= 0)
        ) STRICT
        """,
        "INSERT INTO memrank_input_state (singleton, generation) VALUES (1, 0)",
        """
        CREATE TRIGGER memrank_input_page_insert AFTER INSERT ON memory_page BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER memrank_input_page_update
        AFTER UPDATE OF id, title, scope, workspace_id, deleted_at ON memory_page BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER memrank_input_page_delete AFTER DELETE ON memory_page BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER memrank_input_claim_insert AFTER INSERT ON memory_claim BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER memrank_input_claim_update
        AFTER UPDATE OF id, page_id, text, status, scope, workspace_id, provider_policy, origin,
                        confirmed_by_user, deleted_at
        ON memory_claim BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER memrank_input_claim_delete AFTER DELETE ON memory_claim BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER memrank_input_source_insert AFTER INSERT ON memory_source BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER memrank_input_source_update
        AFTER UPDATE OF id, claim_id, kind, conversation_id, entry_id, quote, external_path,
                        captured_at
        ON memory_source BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER memrank_input_source_delete AFTER DELETE ON memory_source BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER memrank_input_feedback_insert
        AFTER INSERT ON memory_association_feedback BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER memrank_input_feedback_update
        AFTER UPDATE ON memory_association_feedback BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER memrank_input_feedback_delete
        AFTER DELETE ON memory_association_feedback BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        // A source with no saved entry coordinate may resolve through one unique matching user
        // quote, so a new user row can change it. Exact-coordinate sources and feedback are already
        // anchored: an ordinary later turn in that same Conversation must not evict their graph.
        // Updates and deletions remain conservative because they can alter an anchor or its saved
        // context window; a non-user row matters only at an exact saved coordinate.
        """
        CREATE TRIGGER memrank_input_event_insert AFTER INSERT ON conversation_events
        WHEN EXISTS (
          SELECT 1 FROM memory_source AS s
          WHERE s.conversation_id = NEW.conversation_id
            AND (s.entry_id = NEW.id
                 OR (s.entry_id IS NULL AND NEW.kind = 'transcript.user'))
        ) OR EXISTS (
          SELECT 1 FROM memory_association_feedback AS f
          WHERE f.conversation_id = NEW.conversation_id
            AND (f.anchor_entry_id = NEW.id OR f.disclosure_entry_id = NEW.id)
        )
        BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER memrank_input_event_update
        AFTER UPDATE OF conversation_id, id, capture_sequence, kind, observed_at, payload_version,
                        payload
        ON conversation_events
        WHEN EXISTS (
          SELECT 1 FROM memory_source AS s
          WHERE s.conversation_id IN (OLD.conversation_id, NEW.conversation_id)
            AND (s.entry_id IN (OLD.id, NEW.id)
                 OR OLD.kind = 'transcript.user' OR NEW.kind = 'transcript.user')
        ) OR EXISTS (
          SELECT 1 FROM memory_association_feedback AS f
          WHERE f.conversation_id IN (OLD.conversation_id, NEW.conversation_id)
            AND (f.anchor_entry_id IN (OLD.id, NEW.id)
                 OR f.disclosure_entry_id IN (OLD.id, NEW.id)
                 OR OLD.kind = 'transcript.user' OR NEW.kind = 'transcript.user')
        )
        BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER memrank_input_event_delete AFTER DELETE ON conversation_events
        WHEN EXISTS (
          SELECT 1 FROM memory_source AS s
          WHERE s.conversation_id = OLD.conversation_id
            AND (s.entry_id = OLD.id OR OLD.kind = 'transcript.user')
        ) OR EXISTS (
          SELECT 1 FROM memory_association_feedback AS f
          WHERE f.conversation_id = OLD.conversation_id
            AND (f.anchor_entry_id = OLD.id OR f.disclosure_entry_id = OLD.id
                 OR OLD.kind = 'transcript.user')
        )
        BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER memrank_input_conversation_update
        AFTER UPDATE OF id, workspace_id, tombstoned ON conversations
        WHEN (OLD.id != NEW.id OR OLD.workspace_id != NEW.workspace_id
              OR OLD.tombstoned != NEW.tombstoned)
        AND (EXISTS (
          SELECT 1 FROM memory_source AS s
          WHERE s.conversation_id IN (OLD.id, NEW.id)
        ) OR EXISTS (
          SELECT 1 FROM memory_association_feedback AS f
          WHERE f.conversation_id IN (OLD.id, NEW.id)
        ))
        BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER memrank_input_conversation_delete AFTER DELETE ON conversations
        WHEN EXISTS (
          SELECT 1 FROM memory_source AS s WHERE s.conversation_id = OLD.id
        ) OR EXISTS (
          SELECT 1 FROM memory_association_feedback AS f WHERE f.conversation_id = OLD.id
        )
        BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER memrank_input_workspace_update
        AFTER UPDATE OF id, name ON workspaces
        WHEN (OLD.id != NEW.id OR OLD.name != NEW.name)
        AND (EXISTS (
          SELECT 1 FROM memory_claim AS c
          WHERE c.workspace_id IN (OLD.id, NEW.id)
        ) OR EXISTS (
          SELECT 1 FROM memory_association_feedback AS f
          WHERE f.workspace_id IN (OLD.id, NEW.id)
        ) OR EXISTS (
          SELECT 1 FROM conversations AS c
          WHERE c.workspace_id IN (OLD.id, NEW.id)
            AND (EXISTS (
                   SELECT 1 FROM memory_source AS s WHERE s.conversation_id = c.id)
                 OR EXISTS (
                   SELECT 1 FROM memory_association_feedback AS f
                   WHERE f.conversation_id = c.id))
        ))
        BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
    ]

    /// v11: the person's exact statement-relationship reviews.
    ///
    /// The on-device classifier's verdict remains disposable in `projections.db`. Only an explicit
    /// keep action writes this authority row, bound to both exact statement fingerprints. An edit
    /// therefore makes the review historical without rewriting it, while a later revision pair can
    /// be reviewed independently. Duplicate and conflict resolutions select one survivor; choosing
    /// Keep both is always the durable correction `distinct + keep_both`.
    private static let schemaV11Statements = [
        """
        CREATE TABLE memory_relationship_review (
          first_claim_id TEXT NOT NULL REFERENCES memory_claim(id) ON DELETE CASCADE,
          second_claim_id TEXT NOT NULL REFERENCES memory_claim(id) ON DELETE CASCADE,
          first_fingerprint TEXT NOT NULL,
          second_fingerprint TEXT NOT NULL,
          relationship TEXT NOT NULL CHECK (
            relationship IN ('duplicate', 'conflict', 'distinct')),
          resolution TEXT NOT NULL CHECK (
            resolution IN ('keep_first', 'keep_second', 'keep_both')),
          reviewed_at REAL NOT NULL,
          PRIMARY KEY (
            first_claim_id, second_claim_id, first_fingerprint, second_fingerprint),
          CHECK (first_claim_id < second_claim_id),
          CHECK (
            (relationship IN ('duplicate', 'conflict')
              AND resolution IN ('keep_first', 'keep_second'))
            OR (relationship = 'distinct' AND resolution = 'keep_both'))
        ) STRICT
        """,
        """
        CREATE INDEX memory_relationship_review_pair
        ON memory_relationship_review(first_claim_id, second_claim_id, reviewed_at DESC)
        """,
        """
        CREATE TRIGGER memrank_input_relationship_review_insert
        AFTER INSERT ON memory_relationship_review BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER memrank_input_relationship_review_update
        AFTER UPDATE ON memory_relationship_review BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER memrank_input_relationship_review_delete
        AFTER DELETE ON memory_relationship_review BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
    ]

    /// v12: exact, content-free receipts for Memrank maintenance decisions.
    ///
    /// Archive review is deliberately separate from ordinary removal. Its binding records the
    /// exact graph, dormancy state, collector policy, and claim revision the person reviewed. An
    /// archive is a reversible soft hide, and only a restore naming that exact archive action may
    /// clear it. There is no delete or purge action in this table's closed vocabulary.
    ///
    /// Truth retirement is also separate from contextual feedback. It records the exact disclosure
    /// coordinates behind "No longer true" while keeping all user-authored prose in the existing
    /// authority rows. The claim transition is `active` to `superseded` with a closed validity
    /// interval; it creates neither a replacement nor a tombstone.
    private static let schemaV12Statements = [
        """
        CREATE TABLE memory_claim_archive_decision (
          action_id TEXT PRIMARY KEY,
          claim_id TEXT NOT NULL REFERENCES memory_claim(id) ON DELETE CASCADE,
          decision TEXT NOT NULL CHECK (decision IN ('keep', 'archive', 'restore')),
          expected_revision_id TEXT NOT NULL CHECK (length(expected_revision_id) = 64),
          binding BLOB NOT NULL CHECK (
            length(binding) > 0
              AND length(binding) <= 4194304),
          source_archive_action_id TEXT
            REFERENCES memory_claim_archive_decision(action_id) ON DELETE CASCADE,
          resulting_revision_id TEXT NOT NULL CHECK (length(resulting_revision_id) = 64),
          decided_at REAL NOT NULL,
          CHECK ((decision = 'restore') = (source_archive_action_id IS NOT NULL)),
          CHECK (source_archive_action_id IS NULL OR source_archive_action_id != action_id)
        ) STRICT
        """,
        """
        CREATE INDEX memory_claim_archive_decision_claim
        ON memory_claim_archive_decision(claim_id, decided_at DESC, action_id DESC)
        """,
        """
        CREATE TABLE memory_claim_truth_retirement (
          action_id TEXT PRIMARY KEY,
          claim_id TEXT NOT NULL REFERENCES memory_claim(id) ON DELETE CASCADE,
          claim_fingerprint TEXT NOT NULL CHECK (length(claim_fingerprint) = 64),
          expected_revision_id TEXT NOT NULL CHECK (length(expected_revision_id) = 64),
          conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
          anchor_entry_id TEXT NOT NULL,
          disclosure_entry_id TEXT NOT NULL,
          expected_workspace_id TEXT,
          expected_subject_page_id TEXT,
          access TEXT NOT NULL CHECK (access IN (
            'claude_subscription', 'anthropic_api', 'codex_subscription', 'openai_api',
            'claude_vertex', 'claude_bedrock')),
          retired_at REAL NOT NULL,
          resulting_revision_id TEXT NOT NULL CHECK (length(resulting_revision_id) = 64)
        ) STRICT
        """,
        """
        CREATE INDEX memory_claim_truth_retirement_claim
        ON memory_claim_truth_retirement(claim_id, retired_at DESC, action_id DESC)
        """,
    ]

    /// v13: learned-procedure evidence, reviewed definitions, and explicit delivery lifecycle.
    ///
    /// Procedure identity and semantic kind are authority facts attached to an existing Memory
    /// claim. Occurrences retain exact source/tool coordinates, while a successful Build outcome
    /// keeps only its typed receipt coordinates, revision, and exact provider lane. The canonical
    /// receipt itself remains on the transcript tool row that already owns it.
    ///
    /// Keep and Reject remain content-free draft decisions. A separate explicit materialization
    /// records the exact instruction the person reviewed, its Workspace and exact ModelAccess set;
    /// append-only Enable/Disable decisions control delivery. No row writes a provider/repository
    /// file or makes a definition executable outside Mechanician's bounded prompt injection path.
    private static let schemaV13Statements = [
        """
        CREATE TABLE learned_skill_input_state (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          generation INTEGER NOT NULL CHECK (generation >= 0)
        ) STRICT
        """,
        "INSERT INTO learned_skill_input_state (singleton, generation) VALUES (1, 0)",
        """
        CREATE TABLE learned_skill_delivery_state (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          generation INTEGER NOT NULL CHECK (generation >= 0)
        ) STRICT
        """,
        "INSERT INTO learned_skill_delivery_state (singleton, generation) VALUES (1, 0)",
        """
        CREATE TABLE learned_skill_workspace_incarnation (
          workspace_id TEXT PRIMARY KEY,
          incarnation INTEGER NOT NULL CHECK (incarnation >= 1)
        ) STRICT
        """,
        """
        INSERT INTO learned_skill_workspace_incarnation (workspace_id, incarnation)
        SELECT id, 1 FROM workspaces
        """,
        """
        CREATE TRIGGER learned_skill_workspace_incarnation_insert
        AFTER INSERT ON workspaces BEGIN
          INSERT INTO learned_skill_workspace_incarnation (workspace_id, incarnation)
          VALUES (NEW.id, 1)
          ON CONFLICT(workspace_id) DO UPDATE SET incarnation = incarnation + 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_workspace_incarnation_rebind
        AFTER UPDATE OF kind, source_identity ON workspaces
        WHEN OLD.kind != NEW.kind OR OLD.source_identity IS NOT NEW.source_identity
        BEGIN
          INSERT INTO learned_skill_workspace_incarnation (workspace_id, incarnation)
          VALUES (NEW.id, 1)
          ON CONFLICT(workspace_id) DO UPDATE SET incarnation = incarnation + 1;
        END
        """,
        """
        CREATE TABLE learned_procedure_claim (
          claim_id TEXT PRIMARY KEY REFERENCES memory_claim(id) ON DELETE CASCADE,
          procedure_id TEXT NOT NULL,
          semantic_kind TEXT NOT NULL CHECK (semantic_kind = 'procedure'),
          registered_at REAL NOT NULL,
          UNIQUE (claim_id, procedure_id)
        ) STRICT
        """,
        """
        CREATE INDEX learned_procedure_claim_procedure
        ON learned_procedure_claim(procedure_id, claim_id)
        """,
        """
        CREATE TRIGGER learned_procedure_claim_immutable_update
        BEFORE UPDATE ON learned_procedure_claim BEGIN
          SELECT RAISE(ABORT, 'learned procedure identity is immutable');
        END
        """,
        """
        CREATE TABLE learned_procedure_occurrence (
          evidence_id TEXT PRIMARY KEY,
          procedure_occurrence_id TEXT NOT NULL UNIQUE,
          procedure_id TEXT NOT NULL,
          claim_id TEXT NOT NULL,
          source_id TEXT NOT NULL UNIQUE REFERENCES memory_source(id) ON DELETE CASCADE,
          conversation_id TEXT NOT NULL,
          source_entry_id TEXT NOT NULL,
          source_turn_id TEXT NOT NULL,
          source_tool_use_id TEXT NOT NULL,
          source_access TEXT NOT NULL CHECK (source_access IN (
            'claude_subscription', 'anthropic_api', 'codex_subscription', 'openai_api',
            'claude_vertex', 'claude_bedrock')),
          workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON UPDATE CASCADE ON DELETE CASCADE,
          observed_at REAL NOT NULL,
          FOREIGN KEY (claim_id, procedure_id)
            REFERENCES learned_procedure_claim(claim_id, procedure_id) ON DELETE CASCADE,
          FOREIGN KEY (conversation_id, source_entry_id)
            REFERENCES conversation_events(conversation_id, id) ON DELETE CASCADE,
          UNIQUE (procedure_occurrence_id, procedure_id),
          UNIQUE (
            procedure_id, conversation_id, source_turn_id, source_entry_id, source_tool_use_id)
        ) STRICT
        """,
        """
        CREATE INDEX learned_procedure_occurrence_procedure
        ON learned_procedure_occurrence(procedure_id, procedure_occurrence_id)
        """,
        """
        CREATE TRIGGER learned_procedure_occurrence_immutable_update
        BEFORE UPDATE ON learned_procedure_occurrence BEGIN
          SELECT RAISE(ABORT, 'learned procedure occurrences are immutable evidence');
        END
        """,
        """
        CREATE TABLE learned_procedure_verified_outcome (
          evidence_id TEXT PRIMARY KEY,
          provider_proof_evidence_id TEXT NOT NULL UNIQUE,
          procedure_id TEXT NOT NULL,
          procedure_occurrence_id TEXT NOT NULL,
          receipt_id TEXT NOT NULL UNIQUE,
          receipt_revision_id TEXT NOT NULL CHECK (length(receipt_revision_id) = 64),
          receipt_conversation_id TEXT NOT NULL,
          receipt_entry_id TEXT NOT NULL,
          receipt_turn_id TEXT NOT NULL,
          receipt_tool_use_id TEXT NOT NULL,
          adapter TEXT NOT NULL CHECK (adapter = 'mechanician_build_v1'),
          verification_fact TEXT NOT NULL CHECK (verification_fact = 'build_succeeded'),
          source_access TEXT NOT NULL CHECK (source_access IN (
            'claude_subscription', 'anthropic_api', 'codex_subscription', 'openai_api',
            'claude_vertex', 'claude_bedrock')),
          workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON UPDATE CASCADE ON DELETE CASCADE,
          linked_at REAL NOT NULL,
          FOREIGN KEY (procedure_occurrence_id, procedure_id)
            REFERENCES learned_procedure_occurrence(procedure_occurrence_id, procedure_id)
              ON DELETE CASCADE,
          FOREIGN KEY (receipt_conversation_id, receipt_entry_id)
            REFERENCES conversation_events(conversation_id, id) ON DELETE CASCADE
        ) STRICT
        """,
        """
        CREATE INDEX learned_procedure_verified_outcome_procedure
        ON learned_procedure_verified_outcome(procedure_id, procedure_occurrence_id)
        """,
        """
        CREATE TRIGGER learned_procedure_outcome_immutable_update
        BEFORE UPDATE ON learned_procedure_verified_outcome BEGIN
          SELECT RAISE(ABORT, 'learned procedure outcomes are immutable evidence');
        END
        """,
        """
        CREATE TABLE learned_skill_draft_review_decision (
          action_id TEXT PRIMARY KEY,
          procedure_id TEXT NOT NULL,
          binding_revision_id TEXT NOT NULL CHECK (length(binding_revision_id) = 64),
          binding BLOB NOT NULL CHECK (length(binding) > 0 AND length(binding) <= 4194304),
          decision TEXT NOT NULL CHECK (decision IN ('keep_draft', 'reject_draft')),
          reviewed_at REAL NOT NULL,
          UNIQUE (procedure_id, binding_revision_id)
        ) STRICT
        """,
        """
        CREATE INDEX learned_skill_draft_review_decision_recent
        ON learned_skill_draft_review_decision(reviewed_at DESC, action_id DESC)
        """,
        """
        CREATE TRIGGER learned_skill_review_decision_immutable_update
        BEFORE UPDATE ON learned_skill_draft_review_decision BEGIN
          SELECT RAISE(ABORT, 'learned skill review decisions are append-only');
        END
        """,
        """
        CREATE TRIGGER learned_skill_review_decision_immutable_delete
        BEFORE DELETE ON learned_skill_draft_review_decision BEGIN
          SELECT RAISE(ABORT, 'learned skill review decisions are append-only');
        END
        """,
        """
        CREATE TABLE learned_skill_definition_revision (
          definition_revision_id TEXT PRIMARY KEY CHECK (length(definition_revision_id) = 64),
          skill_id TEXT NOT NULL,
          procedure_id TEXT NOT NULL,
          source_review_action_id TEXT NOT NULL
            REFERENCES learned_skill_draft_review_decision(action_id) ON DELETE RESTRICT,
          source_binding_revision_id TEXT NOT NULL CHECK (length(source_binding_revision_id) = 64),
          definition BLOB NOT NULL CHECK (
            length(definition) > 0
              AND length(definition) <= 262144),
          instruction_source TEXT NOT NULL CHECK (
            instruction_source = 'accepted_procedure_claims_v1'),
          instruction_text TEXT NOT NULL CHECK (
            length(instruction_text) > 0
              AND length(CAST(instruction_text AS BLOB))
                <= 8192),
          -- Historical definition revisions retain the exact destination coordinate after a
          -- Workspace is deleted. Delivery always re-proves a live matching Workspace, so this
          -- audit coordinate cannot revive or widen after its owner disappears.
          workspace_id TEXT NOT NULL,
          workspace_incarnation INTEGER NOT NULL CHECK (workspace_incarnation >= 1),
          materialized_at REAL NOT NULL,
          UNIQUE (skill_id, definition_revision_id),
          UNIQUE (procedure_id, definition_revision_id)
        ) STRICT
        """,
        """
        CREATE INDEX learned_skill_definition_revision_skill
        ON learned_skill_definition_revision(skill_id, materialized_at DESC)
        """,
        """
        CREATE TRIGGER learned_skill_definition_immutable_update
        BEFORE UPDATE ON learned_skill_definition_revision BEGIN
          SELECT RAISE(ABORT, 'learned skill definition revisions are append-only');
        END
        """,
        """
        CREATE TRIGGER learned_skill_definition_immutable_delete
        BEFORE DELETE ON learned_skill_definition_revision BEGIN
          SELECT RAISE(ABORT, 'learned skill definition revisions are append-only');
        END
        """,
        """
        CREATE TABLE learned_skill_definition_access (
          definition_revision_id TEXT NOT NULL
            REFERENCES learned_skill_definition_revision(definition_revision_id) ON DELETE CASCADE,
          access TEXT NOT NULL CHECK (access IN (
            'claude_subscription', 'anthropic_api', 'codex_subscription', 'openai_api',
            'claude_vertex', 'claude_bedrock')),
          PRIMARY KEY (definition_revision_id, access)
        ) STRICT
        """,
        """
        CREATE TRIGGER learned_skill_definition_access_immutable_update
        BEFORE UPDATE ON learned_skill_definition_access BEGIN
          SELECT RAISE(ABORT, 'learned skill definition access rows are append-only');
        END
        """,
        """
        CREATE TRIGGER learned_skill_definition_access_immutable_delete
        BEFORE DELETE ON learned_skill_definition_access BEGIN
          SELECT RAISE(ABORT, 'learned skill definition access rows are append-only');
        END
        """,
        """
        CREATE TABLE learned_skill_lifecycle_decision (
          action_id TEXT PRIMARY KEY,
          skill_id TEXT NOT NULL,
          definition_revision_id TEXT NOT NULL,
          decision TEXT NOT NULL CHECK (decision IN ('enable', 'disable')),
          expected_prior_action_id TEXT,
          decided_at REAL NOT NULL,
          CHECK (expected_prior_action_id IS NULL OR expected_prior_action_id != action_id),
          UNIQUE (skill_id, action_id),
          FOREIGN KEY (skill_id, definition_revision_id)
            REFERENCES learned_skill_definition_revision(skill_id, definition_revision_id)
              ON DELETE RESTRICT,
          FOREIGN KEY (skill_id, expected_prior_action_id)
            REFERENCES learned_skill_lifecycle_decision(skill_id, action_id) ON DELETE RESTRICT
        ) STRICT
        """,
        """
        CREATE TRIGGER learned_skill_lifecycle_immutable_update
        BEFORE UPDATE ON learned_skill_lifecycle_decision BEGIN
          SELECT RAISE(ABORT, 'learned skill lifecycle decisions are append-only');
        END
        """,
        """
        CREATE TRIGGER learned_skill_lifecycle_immutable_delete
        BEFORE DELETE ON learned_skill_lifecycle_decision BEGIN
          SELECT RAISE(ABORT, 'learned skill lifecycle decisions are append-only');
        END
        """,
        """
        CREATE UNIQUE INDEX learned_skill_lifecycle_first_action
        ON learned_skill_lifecycle_decision(skill_id)
        WHERE expected_prior_action_id IS NULL
        """,
        """
        CREATE UNIQUE INDEX learned_skill_lifecycle_successor
        ON learned_skill_lifecycle_decision(expected_prior_action_id)
        WHERE expected_prior_action_id IS NOT NULL
        """,
        """
        CREATE INDEX learned_skill_lifecycle_recent
        ON learned_skill_lifecycle_decision(skill_id, decided_at DESC, action_id DESC)
        """,
        """
        CREATE TABLE learned_skill_disclosure_receipt (
          receipt_id TEXT PRIMARY KEY,
          conversation_id TEXT NOT NULL,
          turn_id TEXT NOT NULL,
          user_entry_id TEXT NOT NULL,
          disclosure_entry_id TEXT NOT NULL,
          workspace_id TEXT NOT NULL,
          workspace_incarnation INTEGER NOT NULL CHECK (workspace_incarnation >= 1),
          access TEXT NOT NULL CHECK (access IN (
            'claude_subscription', 'anthropic_api', 'codex_subscription', 'openai_api',
            'claude_vertex', 'claude_bedrock')),
          receipt BLOB NOT NULL CHECK (length(receipt) > 0 AND length(receipt) <= 262144),
          disclosed_at REAL NOT NULL,
          UNIQUE (conversation_id, turn_id, user_entry_id, access),
          UNIQUE (conversation_id, disclosure_entry_id)
        ) STRICT
        """,
        """
        CREATE INDEX learned_skill_disclosure_receipt_conversation
        ON learned_skill_disclosure_receipt(conversation_id, user_entry_id, disclosed_at DESC)
        """,
        """
        CREATE TABLE learned_skill_disclosure_item (
          receipt_id TEXT NOT NULL
            REFERENCES learned_skill_disclosure_receipt(receipt_id) ON DELETE CASCADE,
          item_ordinal INTEGER NOT NULL CHECK (item_ordinal >= 0 AND item_ordinal < 8),
          skill_id TEXT NOT NULL,
          procedure_id TEXT NOT NULL,
          definition_revision_id TEXT NOT NULL,
          lifecycle_action_id TEXT NOT NULL,
          claim_ids BLOB NOT NULL CHECK (length(claim_ids) > 0 AND length(claim_ids) <= 65536),
          PRIMARY KEY (receipt_id, item_ordinal),
          UNIQUE (receipt_id, skill_id),
          FOREIGN KEY (skill_id, definition_revision_id)
            REFERENCES learned_skill_definition_revision(skill_id, definition_revision_id)
              ON DELETE RESTRICT,
          FOREIGN KEY (skill_id, lifecycle_action_id)
            REFERENCES learned_skill_lifecycle_decision(skill_id, action_id) ON DELETE RESTRICT
        ) STRICT
        """,
        """
        CREATE TRIGGER learned_skill_disclosure_receipt_immutable_update
        BEFORE UPDATE ON learned_skill_disclosure_receipt BEGIN
          SELECT RAISE(ABORT, 'learned skill disclosure receipts are append-only');
        END
        """,
        """
        CREATE TRIGGER learned_skill_disclosure_receipt_immutable_delete
        BEFORE DELETE ON learned_skill_disclosure_receipt BEGIN
          SELECT RAISE(ABORT, 'learned skill disclosure receipts are append-only');
        END
        """,
        """
        CREATE TRIGGER learned_skill_disclosure_item_immutable_update
        BEFORE UPDATE ON learned_skill_disclosure_item BEGIN
          SELECT RAISE(ABORT, 'learned skill disclosure items are append-only');
        END
        """,
        """
        CREATE TRIGGER learned_skill_disclosure_item_immutable_delete
        BEFORE DELETE ON learned_skill_disclosure_item BEGIN
          SELECT RAISE(ABORT, 'learned skill disclosure items are append-only');
        END
        """,
        """
        CREATE TRIGGER learned_skill_delivery_definition_insert
        AFTER INSERT ON learned_skill_definition_revision BEGIN
          UPDATE learned_skill_delivery_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_delivery_definition_delete
        AFTER DELETE ON learned_skill_definition_revision BEGIN
          UPDATE learned_skill_delivery_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_delivery_access_insert
        AFTER INSERT ON learned_skill_definition_access BEGIN
          UPDATE learned_skill_delivery_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_delivery_access_delete
        AFTER DELETE ON learned_skill_definition_access BEGIN
          UPDATE learned_skill_delivery_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_delivery_lifecycle_insert
        AFTER INSERT ON learned_skill_lifecycle_decision BEGIN
          UPDATE learned_skill_delivery_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_delivery_review_insert
        AFTER INSERT ON learned_skill_draft_review_decision BEGIN
          UPDATE learned_skill_delivery_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_delivery_workspace_insert
        AFTER INSERT ON workspaces
        WHEN EXISTS (
          SELECT 1 FROM learned_skill_definition_revision definition
          WHERE definition.workspace_id = NEW.id)
        BEGIN
          UPDATE learned_skill_delivery_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_delivery_workspace_update
        AFTER UPDATE ON workspaces
        WHEN EXISTS (
          SELECT 1 FROM learned_skill_definition_revision definition
          WHERE definition.workspace_id IN (OLD.id, NEW.id))
        BEGIN
          UPDATE learned_skill_delivery_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_delivery_workspace_delete
        AFTER DELETE ON workspaces
        WHEN EXISTS (
          SELECT 1 FROM learned_skill_definition_revision definition
          WHERE definition.workspace_id = OLD.id)
        BEGIN
          UPDATE learned_skill_delivery_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_input_claim_metadata_insert
        AFTER INSERT ON learned_procedure_claim BEGIN
          UPDATE learned_skill_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_input_claim_metadata_update
        AFTER UPDATE ON learned_procedure_claim BEGIN
          UPDATE learned_skill_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_input_claim_metadata_delete
        AFTER DELETE ON learned_procedure_claim BEGIN
          UPDATE learned_skill_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_input_occurrence_insert
        AFTER INSERT ON learned_procedure_occurrence BEGIN
          UPDATE learned_skill_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_input_occurrence_update
        AFTER UPDATE ON learned_procedure_occurrence BEGIN
          UPDATE learned_skill_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_input_occurrence_delete
        AFTER DELETE ON learned_procedure_occurrence BEGIN
          UPDATE learned_skill_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_input_outcome_insert
        AFTER INSERT ON learned_procedure_verified_outcome BEGIN
          UPDATE learned_skill_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_input_outcome_update
        AFTER UPDATE ON learned_procedure_verified_outcome BEGIN
          UPDATE learned_skill_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_input_outcome_delete
        AFTER DELETE ON learned_procedure_verified_outcome BEGIN
          UPDATE learned_skill_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_input_claim_update
        AFTER UPDATE ON memory_claim
        WHEN EXISTS (
          SELECT 1 FROM learned_procedure_claim learned WHERE learned.claim_id = NEW.id)
        BEGIN
          UPDATE learned_skill_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_input_page_update
        AFTER UPDATE ON memory_page
        WHEN EXISTS (
          SELECT 1 FROM memory_claim claim
          JOIN learned_procedure_claim learned ON learned.claim_id = claim.id
          WHERE claim.page_id IN (OLD.id, NEW.id))
        BEGIN
          UPDATE learned_skill_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_input_source_update
        AFTER UPDATE ON memory_source
        WHEN EXISTS (
          SELECT 1 FROM learned_procedure_occurrence occurrence
          WHERE occurrence.source_id IN (OLD.id, NEW.id))
        BEGIN
          UPDATE learned_skill_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_input_event_update
        AFTER UPDATE ON conversation_events
        WHEN EXISTS (
          SELECT 1 FROM learned_procedure_occurrence occurrence
          WHERE occurrence.conversation_id IN (OLD.conversation_id, NEW.conversation_id)
            AND occurrence.source_entry_id IN (OLD.id, NEW.id))
        OR EXISTS (
          SELECT 1 FROM learned_procedure_verified_outcome outcome
          WHERE outcome.receipt_conversation_id IN (OLD.conversation_id, NEW.conversation_id)
            AND outcome.receipt_entry_id IN (OLD.id, NEW.id))
        BEGIN
          UPDATE learned_skill_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_input_conversation_update
        AFTER UPDATE OF id, workspace_id, tombstoned ON conversations
        WHEN EXISTS (
          SELECT 1 FROM learned_procedure_occurrence occurrence
          WHERE occurrence.conversation_id IN (OLD.id, NEW.id))
        OR EXISTS (
          SELECT 1 FROM learned_procedure_verified_outcome outcome
          WHERE outcome.receipt_conversation_id IN (OLD.id, NEW.id))
        BEGIN
          UPDATE learned_skill_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        """
        CREATE TRIGGER learned_skill_input_workspace_update
        AFTER UPDATE OF id, kind, cwd, source_identity, tombstoned ON workspaces
        WHEN EXISTS (
          SELECT 1 FROM learned_procedure_occurrence occurrence
          WHERE occurrence.workspace_id IN (OLD.id, NEW.id))
        OR EXISTS (
          SELECT 1 FROM learned_procedure_verified_outcome outcome
          WHERE outcome.workspace_id IN (OLD.id, NEW.id))
        BEGIN
          UPDATE learned_skill_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
        // v10 conservatively treated every later user row in a Conversation as a possible change
        // to every legacy source without an exact entry coordinate. The graph resolver can change
        // only when that row contains the source's verbatim quote. Keeping the broader predicate
        // made an otherwise unrelated send publish a valid decision and then immediately evict it.
        // Replace only the invalidation trigger; no authority row, evidence rule, or graph recipe
        // changes. Unknown/malformed future payloads remain conservative and still advance.
        "DROP TRIGGER memrank_input_event_insert",
        """
        CREATE TRIGGER memrank_input_event_insert AFTER INSERT ON conversation_events
        WHEN EXISTS (
          SELECT 1 FROM memory_source AS s
          WHERE s.conversation_id = NEW.conversation_id
            AND (s.entry_id = NEW.id
                 OR (s.entry_id IS NULL AND NEW.kind = 'transcript.user'
                     AND CASE
                       WHEN NEW.payload_version = 1
                         AND json_valid(CAST(NEW.payload AS TEXT))
                       THEN CASE
                         WHEN json_type(CAST(NEW.payload AS TEXT), '$.id') = 'text'
                           AND json_extract(CAST(NEW.payload AS TEXT), '$.id') = NEW.id
                           AND json_type(CAST(NEW.payload AS TEXT), '$.kind') = 'text'
                           AND json_extract(CAST(NEW.payload AS TEXT), '$.kind') = 'user'
                           AND json_type(CAST(NEW.payload AS TEXT), '$.text') = 'text'
                         THEN instr(
                           json_extract(CAST(NEW.payload AS TEXT), '$.text'), s.quote) > 0
                         ELSE 1
                       END
                       ELSE 1
                     END))
        ) OR EXISTS (
          SELECT 1 FROM memory_association_feedback AS f
          WHERE f.conversation_id = NEW.conversation_id
            AND (f.anchor_entry_id = NEW.id OR f.disclosure_entry_id = NEW.id)
        )
        BEGIN
          UPDATE memrank_input_state SET generation = generation + 1 WHERE singleton = 1;
        END
        """,
    ]

    static var schemaV2Checksum: String {
        let bytes = Data(schemaV2Statements.joined(separator: "\n-- next statement --\n").utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static var schemaV3Checksum: String {
        let bytes = Data(schemaV3Statements.joined(separator: "\n-- next statement --\n").utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static var schemaV4Checksum: String {
        let bytes = Data(schemaV4Statements.joined(separator: "\n-- next statement --\n").utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static var schemaV5Checksum: String {
        let bytes = Data(schemaV5Statements.joined(separator: "\n-- next statement --\n").utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static var schemaV6Checksum: String {
        let bytes = Data(schemaV6Statements.joined(separator: "\n-- next statement --\n").utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static var schemaV7Checksum: String {
        let bytes = Data(schemaV7Statements.joined(separator: "\n-- next statement --\n").utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static var schemaV8Checksum: String {
        let bytes = Data(schemaV8Statements.joined(separator: "\n-- next statement --\n").utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static var schemaV9Checksum: String {
        let bytes = Data(schemaV9Statements.joined(separator: "\n-- next statement --\n").utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static var schemaV10Checksum: String {
        let bytes = Data(schemaV10Statements.joined(separator: "\n-- next statement --\n").utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static var schemaV11Checksum: String {
        let bytes = Data(schemaV11Statements.joined(separator: "\n-- next statement --\n").utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static var schemaV12Checksum: String {
        let bytes = Data(schemaV12Statements.joined(separator: "\n-- next statement --\n").utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// v14 releases the memory, learned-skill and Memrank authority: 24 tables and 62 triggers.
    ///
    /// **`PRAGMA defer_foreign_keys` must stay first.** `learned_skill_lifecycle_decision`
    /// references itself with `ON DELETE RESTRICT`, so no drop order satisfies it on a machine
    /// that ever enabled a learned skill. A library with zero rows there drops fine either way,
    /// which is precisely how this would ship green and fail for somebody else.
    ///
    /// **Every trigger drops before any table.** `DROP TABLE` compiles the triggers defined on the
    /// table it drops, so one whose body names an already-dropped table fails the statement. The
    /// thirteen that sit on `conversations`, `conversation_events` and `workspaces` are the ones
    /// that matter most: leaving one behind means the next ordinary conversation write tries to
    /// bump a table that is gone.
    ///
    /// The three `conversation_projection_*` triggers are deliberately absent. They feed
    /// `projection_outbox`, which survives.
    private static let schemaV14Statements: [String] =
        ["PRAGMA defer_foreign_keys = ON"]
        + retiredAuthorityTriggers.map { "DROP TRIGGER IF EXISTS \($0)" }
        + retiredAuthorityTables.map { "DROP TABLE IF EXISTS \($0)" }

    private static var schemaV13Checksum: String {
        let bytes = Data(schemaV13Statements.joined(separator: "\n-- next statement --\n").utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Every object schema v14 releases, by name. The rung's statements are generated from these
    /// two lists, and so is the inverse the upgrade fixture uses, so a name can never appear in one
    /// and not the other.
    static let retiredAuthorityTriggers = [
        "learned_procedure_claim_immutable_update",
        "learned_procedure_occurrence_immutable_update",
        "learned_procedure_outcome_immutable_update",
        "learned_skill_definition_access_immutable_delete",
        "learned_skill_definition_access_immutable_update",
        "learned_skill_definition_immutable_delete",
        "learned_skill_definition_immutable_update",
        "learned_skill_delivery_access_delete",
        "learned_skill_delivery_access_insert",
        "learned_skill_delivery_definition_delete",
        "learned_skill_delivery_definition_insert",
        "learned_skill_delivery_lifecycle_insert",
        "learned_skill_delivery_review_insert",
        "learned_skill_delivery_workspace_delete",
        "learned_skill_delivery_workspace_insert",
        "learned_skill_delivery_workspace_update",
        "learned_skill_disclosure_item_immutable_delete",
        "learned_skill_disclosure_item_immutable_update",
        "learned_skill_disclosure_receipt_immutable_delete",
        "learned_skill_disclosure_receipt_immutable_update",
        "learned_skill_input_claim_metadata_delete",
        "learned_skill_input_claim_metadata_insert",
        "learned_skill_input_claim_metadata_update",
        "learned_skill_input_claim_update",
        "learned_skill_input_conversation_update",
        "learned_skill_input_event_update",
        "learned_skill_input_occurrence_delete",
        "learned_skill_input_occurrence_insert",
        "learned_skill_input_occurrence_update",
        "learned_skill_input_outcome_delete",
        "learned_skill_input_outcome_insert",
        "learned_skill_input_outcome_update",
        "learned_skill_input_page_update",
        "learned_skill_input_source_update",
        "learned_skill_input_workspace_update",
        "learned_skill_lifecycle_immutable_delete",
        "learned_skill_lifecycle_immutable_update",
        "learned_skill_review_decision_immutable_delete",
        "learned_skill_review_decision_immutable_update",
        "learned_skill_workspace_incarnation_insert",
        "learned_skill_workspace_incarnation_rebind",
        "memrank_input_claim_delete",
        "memrank_input_claim_insert",
        "memrank_input_claim_update",
        "memrank_input_conversation_delete",
        "memrank_input_conversation_update",
        "memrank_input_event_delete",
        "memrank_input_event_insert",
        "memrank_input_event_update",
        "memrank_input_feedback_delete",
        "memrank_input_feedback_insert",
        "memrank_input_feedback_update",
        "memrank_input_page_delete",
        "memrank_input_page_insert",
        "memrank_input_page_update",
        "memrank_input_relationship_review_delete",
        "memrank_input_relationship_review_insert",
        "memrank_input_relationship_review_update",
        "memrank_input_source_delete",
        "memrank_input_source_insert",
        "memrank_input_source_update",
        "memrank_input_workspace_update",
    ]

    static let retiredAuthorityTables = [
        "learned_skill_disclosure_item",
        "learned_skill_disclosure_receipt",
        "learned_skill_definition_access",
        "learned_skill_draft_review_decision",
        "learned_skill_lifecycle_decision",
        "learned_skill_definition_revision",
        "learned_skill_workspace_incarnation",
        "learned_skill_delivery_state",
        "learned_skill_input_state",
        "learned_procedure_verified_outcome",
        "learned_procedure_occurrence",
        "learned_procedure_claim",
        "memory_relationship_review",
        "memory_claim_archive_decision",
        "memory_claim_truth_retirement",
        "memory_association_feedback",
        "memory_revision",
        "memory_source",
        "memory_link",
        "memory_alias",
        "memory_tombstone",
        "memory_claim",
        "memory_page",
        "memrank_input_state",
    ]

#if DEBUG
    /// The statements from the frozen historical arrays that create what v14 releases.
    ///
    /// **Derived, never restated.** `SQLiteAuthorityUpgradeTests` builds its fixture by winding a
    /// current database back to the previous version, and for a rung that only removes, winding
    /// back means re-creating. Writing those hundreds of lines into a test would produce a fixture
    /// that hand-builds a shape production never creates — the exact way a green suite stops
    /// meaning anything. These come out of `schemaV7Statements` through `schemaV13Statements`
    /// unchanged, filtered by the same name lists the rung drops.
    ///
    /// Order is preserved, which is what makes the result runnable: a trigger's table and a
    /// foreign key's target were already created before it in the original ladder.
    static var schemaV14InverseStatementsForTesting: [String] {
        let retired = Set(retiredAuthorityTables + retiredAuthorityTriggers)
        let historical = schemaV7Statements + schemaV8Statements + schemaV9Statements
            + schemaV10Statements + schemaV11Statements + schemaV12Statements + schemaV13Statements
        let selected = historical.compactMap { statement -> (name: String, sql: String)? in
            guard let subject = createdObjectName(in: statement) else { return nil }
            let belongs = retired.contains(subject)
                // An index or a trigger belongs to whichever table it names.
                || retired.contains(where: {
                    statement.contains(" \($0)(") || statement.contains(" \($0) ")
                })
            return belongs ? (subject, statement) : nil
        }
        // A later rung drops and re-creates two of these, so the same name appears twice. Replaying
        // both fails on the second; the LAST definition is the shape v13 actually has.
        var lastIndex: [String: Int] = [:]
        for (offset, item) in selected.enumerated() { lastIndex[item.name] = offset }
        return selected.enumerated()
            .filter { lastIndex[$0.element.name] == $0.offset }
            .map(\.element.sql)
    }

    /// The object a `CREATE` statement defines, or nil for anything else.
    private static func createdObjectName(in statement: String) -> String? {
        let normalized = statement
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "IF NOT EXISTS ", with: "")
        for prefix in ["CREATE TABLE ", "CREATE TRIGGER ", "CREATE INDEX ",
                       "CREATE UNIQUE INDEX ", "CREATE VIRTUAL TABLE "] where normalized.hasPrefix(prefix) {
            let rest = normalized.dropFirst(prefix.count)
            let name = rest.prefix { !" (\n".contains($0) }
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }
#endif

    private static var schemaV14Checksum: String {
        let bytes = Data(schemaV14Statements.joined(separator: "\n-- next statement --\n").utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Durable, exact-key evidence for conversation-aware Changes. These rows never summarize or
    /// rank a transcript: they attach a mechanical Git observation to the Conversation/turn/tool
    /// identifiers the app already holds, and retain only bounded file evidence.
    private static let schemaV15Statements = [
        """
        CREATE TABLE conversation_repository_observations (
          id TEXT PRIMARY KEY,
          conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
          turn_id TEXT NOT NULL CHECK (length(turn_id) BETWEEN 1 AND 512),
          tool_use_id TEXT CHECK (tool_use_id IS NULL OR length(tool_use_id) BETWEEN 1 AND 512),
          reason TEXT NOT NULL CHECK (reason IN (
            'turn_started', 'tool_completed', 'turn_completed', 'changes_refresh', 'git_mutation')),
          root_prompt_entry_id TEXT,
          final_assistant_entry_id TEXT,
          root_prompt_excerpt TEXT CHECK (
            root_prompt_excerpt IS NULL OR length(CAST(root_prompt_excerpt AS BLOB)) <= 4096),
          root_prompt_excerpt_was_truncated INTEGER CHECK (
            root_prompt_excerpt_was_truncated IS NULL
              OR root_prompt_excerpt_was_truncated IN (0, 1)),
          final_assistant_excerpt TEXT CHECK (
            final_assistant_excerpt IS NULL
              OR length(CAST(final_assistant_excerpt AS BLOB)) <= 4096),
          final_assistant_excerpt_was_truncated INTEGER CHECK (
            final_assistant_excerpt_was_truncated IS NULL
              OR final_assistant_excerpt_was_truncated IN (0, 1)),
          repository_id TEXT NOT NULL CHECK (length(repository_id) BETWEEN 1 AND 2048),
          git_common_directory TEXT NOT NULL CHECK (length(git_common_directory) BETWEEN 1 AND 4096),
          worktree_path TEXT NOT NULL CHECK (length(worktree_path) BETWEEN 1 AND 4096),
          workspace_id TEXT REFERENCES workspaces(id) ON UPDATE CASCADE ON DELETE SET NULL,
          canonical_cwd TEXT CHECK (canonical_cwd IS NULL OR length(canonical_cwd) BETWEEN 1 AND 4096),
          head_state TEXT CHECK (head_state IS NULL OR head_state IN ('attached', 'detached', 'unborn')),
          symbolic_ref TEXT CHECK (symbolic_ref IS NULL OR length(symbolic_ref) BETWEEN 1 AND 4096),
          head_oid TEXT CHECK (
            head_oid IS NULL OR (
              length(head_oid) IN (40, 64)
              AND lower(head_oid) = head_oid
              AND head_oid NOT GLOB '*[^0-9a-f]*')),
          status_availability TEXT NOT NULL CHECK (status_availability IN ('available', 'unavailable')),
          index_change_count INTEGER CHECK (index_change_count IS NULL OR index_change_count >= 0),
          worktree_change_count INTEGER CHECK (
            worktree_change_count IS NULL OR worktree_change_count >= 0),
          untracked_count INTEGER CHECK (untracked_count IS NULL OR untracked_count >= 0),
          attribution TEXT CHECK (attribution IS NULL OR attribution IN ('direct_tool', 'observed_during_tool')),
          observed_at REAL NOT NULL,
          UNIQUE (id, conversation_id, turn_id, tool_use_id, repository_id),
          CHECK (reason != 'tool_completed' OR tool_use_id IS NOT NULL),
          CHECK (reason != 'turn_started' OR (
            root_prompt_entry_id IS NOT NULL AND final_assistant_entry_id IS NULL)),
          CHECK (reason != 'turn_completed' OR (
            root_prompt_entry_id IS NOT NULL AND final_assistant_entry_id IS NOT NULL)),
          CHECK ((root_prompt_excerpt IS NULL) =
            (root_prompt_excerpt_was_truncated IS NULL)),
          CHECK ((final_assistant_excerpt IS NULL) =
            (final_assistant_excerpt_was_truncated IS NULL)),
          CHECK (root_prompt_excerpt IS NULL OR root_prompt_entry_id IS NOT NULL),
          CHECK (final_assistant_excerpt IS NULL OR final_assistant_entry_id IS NOT NULL),
          CHECK (attribution != 'direct_tool' OR tool_use_id IS NOT NULL),
          CHECK (
            (head_state IS NULL AND symbolic_ref IS NULL AND head_oid IS NULL)
            OR (head_state = 'attached' AND symbolic_ref IS NOT NULL AND head_oid IS NOT NULL)
            OR (head_state = 'detached' AND symbolic_ref IS NULL AND head_oid IS NOT NULL)
            OR (head_state = 'unborn' AND symbolic_ref IS NOT NULL AND head_oid IS NULL)),
          CHECK (
            (status_availability = 'unavailable'
              AND index_change_count IS NULL AND worktree_change_count IS NULL
              AND untracked_count IS NULL)
            OR (status_availability = 'available'
              AND index_change_count IS NOT NULL AND worktree_change_count IS NOT NULL
              AND untracked_count IS NOT NULL))
        ) STRICT
        """,
        "CREATE INDEX conversation_repository_observations_repository ON conversation_repository_observations(repository_id, observed_at DESC, id)",
        "CREATE INDEX conversation_repository_observations_conversation ON conversation_repository_observations(conversation_id, observed_at DESC, id)",
        "CREATE INDEX conversation_repository_observations_tool ON conversation_repository_observations(conversation_id, turn_id, tool_use_id)",
        """
        CREATE TABLE conversation_file_observations (
          id TEXT PRIMARY KEY,
          repository_observation_id TEXT NOT NULL,
          conversation_id TEXT NOT NULL,
          turn_id TEXT NOT NULL CHECK (length(turn_id) BETWEEN 1 AND 512),
          tool_use_id TEXT NOT NULL CHECK (length(tool_use_id) BETWEEN 1 AND 512),
          repository_id TEXT NOT NULL CHECK (length(repository_id) BETWEEN 1 AND 2048),
          repository_relative_path TEXT NOT NULL CHECK (
            length(repository_relative_path) BETWEEN 1 AND 4096
            AND substr(repository_relative_path, 1, 1) != '/'),
          operation TEXT NOT NULL CHECK (operation IN (
            'read', 'edit', 'write', 'multi_edit', 'notebook_edit', 'opaque_change')),
          attribution TEXT NOT NULL CHECK (attribution IN ('direct_tool', 'observed_during_tool')),
          before_digest TEXT CHECK (
            before_digest IS NULL OR (
              length(before_digest) = 64
              AND lower(before_digest) = before_digest
              AND before_digest NOT GLOB '*[^0-9a-f]*')),
          after_digest TEXT CHECK (
            after_digest IS NULL OR (
              length(after_digest) = 64
              AND lower(after_digest) = after_digest
              AND after_digest NOT GLOB '*[^0-9a-f]*')),
          before_exists INTEGER CHECK (before_exists IS NULL OR before_exists IN (0, 1)),
          after_exists INTEGER CHECK (after_exists IS NULL OR after_exists IN (0, 1)),
          bounded_patch TEXT CHECK (
            bounded_patch IS NULL OR length(CAST(bounded_patch AS BLOB)) <= 262144),
          patch_was_truncated INTEGER NOT NULL CHECK (patch_was_truncated IN (0, 1)),
          observed_at REAL NOT NULL,
          FOREIGN KEY (
            repository_observation_id, conversation_id, turn_id, tool_use_id, repository_id)
            REFERENCES conversation_repository_observations(
              id, conversation_id, turn_id, tool_use_id, repository_id)
            ON DELETE CASCADE,
          CHECK (before_digest IS NULL OR before_exists = 1),
          CHECK (after_digest IS NULL OR after_exists = 1),
          CHECK (bounded_patch IS NOT NULL OR patch_was_truncated = 0),
          CHECK (
            (attribution = 'direct_tool' AND operation IN (
              'read', 'edit', 'write', 'multi_edit', 'notebook_edit'))
            OR (attribution = 'observed_during_tool' AND operation = 'opaque_change'))
        ) STRICT
        """,
        "CREATE INDEX conversation_file_observations_parent ON conversation_file_observations(repository_observation_id, observed_at, id)",
        "CREATE INDEX conversation_file_observations_conversation ON conversation_file_observations(conversation_id, observed_at DESC, id)",
        "CREATE INDEX conversation_file_observations_repository_path ON conversation_file_observations(repository_id, repository_relative_path, observed_at DESC)",
    ]

    private static var schemaV15Checksum: String {
        let bytes = Data(schemaV15Statements.joined(separator: "\n-- next statement --\n").utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    init(supportRoot: URL) throws {
        queue = DispatchQueue(label: "ai.mechanician.shadow-library", qos: .utility)
        self.supportRoot = supportRoot.standardizedFileURL
        databaseURL = self.supportRoot.appendingPathComponent("library.db", isDirectory: false)
        isReadOnly = false
        activeActivationID = nil
        try Self.prepareOwnerOnlyDirectory(self.supportRoot)
        try openOrReset()
    }

    /// Open the prior launch's shadow as evidence only. This path never creates, migrates, resets,
    /// checkpoints, chmods, or records an integrity receipt. Exact v5 ownership and reset-marker
    /// checks run before any row is exposed, and SQLite itself enforces a read-only connection.
    private init(readOnlySupportRoot supportRoot: URL) throws {
        queue = DispatchQueue(label: "ai.mechanician.shadow-library", qos: .utility)
        self.supportRoot = supportRoot.standardizedFileURL
        databaseURL = self.supportRoot.appendingPathComponent("library.db", isDirectory: false)
        isReadOnly = true
        activeActivationID = nil
        try openVerifiedReadOnlyShadow()
    }

    /// Opens an already-committed SQLite authority without running the shadow reset/migration path
    /// and without putting `quick_check`/`foreign_key_check` on the launch critical path. The root
    /// recognizer has already classified the marker/database pair read-only; this opener repeats
    /// the cheap ownership, schema-ledger, instance and activation checks on its writable handle.
    private init(activeSupportRoot supportRoot: URL, marker: StorageAuthorityMarker) throws {
        queue = DispatchQueue(label: "ai.mechanician.shadow-library", qos: .utility)
        self.supportRoot = supportRoot.standardizedFileURL
        databaseURL = self.supportRoot.appendingPathComponent(
            StorageAuthorityProtocol.databaseName, isDirectory: false)
        isReadOnly = false
        activeActivationID = marker.activationID
        do {
            try openDatabase(createIfMissing: false)
            try verifyExactActiveSchema(marker: marker)
            try configureOwnedDatabase()
            try applyOwnerOnlyFilePermissions()
        } catch {
            closeDatabase()
            throw error
        }
    }

    /// Opens the marker-active authority through a second, read-only SQLite connection dedicated
    /// to latency-sensitive presentation reads. The connection has its own user-initiated serial
    /// queue, so a projection rebuild or full Conversation snapshot on the writable store cannot
    /// stand in front of a bounded transcript preview. It deliberately does not configure WAL or
    /// touch file permissions: the primary opener has already proven ownership and configured the
    /// database, while this handle uses SQLite's ordinary read-only WAL snapshot semantics.
    private init(
        interactiveReadOnlySupportRoot supportRoot: URL,
        marker: StorageAuthorityMarker
    ) throws {
        queue = DispatchQueue(
            label: "ai.mechanician.library-interactive-read",
            qos: .userInitiated)
        self.supportRoot = supportRoot.standardizedFileURL
        databaseURL = self.supportRoot.appendingPathComponent(
            StorageAuthorityProtocol.databaseName, isDirectory: false)
        isReadOnly = true
        activeActivationID = marker.activationID
        do {
            try openDatabase(readOnly: true, createIfMissing: false)
            guard let db, sqlite3_db_readonly(db, "main") == 1 else {
                throw SQLiteLibraryStoreError.protectedDatabase(
                    "interactive transcript connection is not read-only")
            }
            try verifyExactActiveSchema(marker: marker)
            guard try scalarText("PRAGMA journal_mode").lowercased() == "wal" else {
                throw SQLiteLibraryStoreError.protectedDatabase(
                    "interactive transcript connection requires the active WAL database")
            }
        } catch {
            closeDatabase()
            throw error
        }
    }

    /// Opens the exact database left behind when marker-last activation was interrupted after the
    /// shadow had already transitioned to `prepared` or `active`. This path never creates,
    /// migrates, or resets the database. It exists only so the lease-owning dogfood launch can
    /// repeat the cutover proofs and publish the missing marker.
    private init(
        interruptedSupportRoot supportRoot: URL,
        probe: StorageAuthorityDatabaseProbe
    ) throws {
        queue = DispatchQueue(label: "ai.mechanician.shadow-library", qos: .utility)
        self.supportRoot = supportRoot.standardizedFileURL
        databaseURL = self.supportRoot.appendingPathComponent(
            StorageAuthorityProtocol.databaseName, isDirectory: false)
        isReadOnly = false
        activeActivationID = probe.activationID
        do {
            try openDatabase(createIfMissing: false)
            try verifyExactInterruptedAuthoritySchema(probe: probe)
            try configureOwnedDatabase()
            try applyOwnerOnlyFilePermissions()
        } catch {
            closeDatabase()
            throw error
        }
    }

    /// Opens a COPY of an active authority so the migration ladder can be run against it.
    ///
    /// This exists because `verifyExistingSchema` — the only path that migrates — requires
    /// `authority_state == "shadow"`, and a real library is never a shadow. Before this, nothing
    /// could carry an active library across a schema bump, and bumping `schemaVersion` therefore
    /// bricked launch for every installation that already had one (v7, reverted 2026-08-14).
    ///
    /// The caller is responsible for handing over a private copy, never the live database.
    private init(
        upgradingCopyAt databaseURL: URL,
        expecting probe: StorageAuthorityDatabaseProbe
    ) throws {
        queue = DispatchQueue(label: "ai.mechanician.shadow-library", qos: .utility)
        supportRoot = databaseURL.deletingLastPathComponent().standardizedFileURL
        self.databaseURL = databaseURL.standardizedFileURL
        isReadOnly = false
        activeActivationID = probe.activationID
        do {
            try openDatabase(createIfMissing: false)
            try verifyCopiedAuthorityMatches(probe)
            try configureOwnedDatabase()
        } catch {
            closeDatabase()
            throw error
        }
    }

    /// Migrate a copy of an active authority forward to the current schema, in place.
    ///
    /// Identity is preserved on purpose. `database_instance_id`, `authority_state`,
    /// `activation_id` and `committed_sequence` are never touched, so the result is the SAME
    /// authority at a newer schema rather than a new one — which is what lets the existing marker
    /// be republished with only its version integer changed.
    static func upgradeCopiedActiveAuthority(
        at databaseURL: URL,
        expecting probe: StorageAuthorityDatabaseProbe
    ) throws {
        let store = try SQLiteLibraryStore(upgradingCopyAt: databaseURL, expecting: probe)
        defer { store.closeDatabase() }
        try store.runUpgradeLadder(from: probe.schemaVersion)
        // Prove the result the same way launch will, so a copy that would brick the app fails here
        // instead — while the original is still untouched and the swap has not happened.
        try store.verifyExactHeaderAndMigrationLedger(label: "upgraded copy")
        let metadata = try store.readAuthorityMetadata()
        guard metadata.databaseInstanceID == probe.databaseInstanceID,
              metadata.schemaVersion == Self.schemaVersion,
              metadata.authorityState == probe.authorityState,
              metadata.activationID == probe.activationID,
              metadata.committedSequence == probe.committedSequence else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "upgraded copy did not preserve the authority's identity")
        }
    }

    /// The lowest schema version this binary can carry forward. Below it there is no ladder step,
    /// so the honest answer is a refusal rather than a partial migration.
    static let lowestUpgradableSchemaVersion = 2

    private func verifyCopiedAuthorityMatches(
        _ probe: StorageAuthorityDatabaseProbe
    ) throws {
        guard try scalarInt("PRAGMA application_id") == Int64(Self.applicationID) else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "upgrade copy is not a Mechanician library")
        }
        guard try scalarInt("PRAGMA user_version") == Int64(probe.schemaVersion) else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "upgrade copy header does not match the recognized schema version")
        }
        let metadata = try readAuthorityMetadata()
        guard metadata.databaseInstanceID == probe.databaseInstanceID,
              metadata.schemaVersion == probe.schemaVersion,
              metadata.authorityState == probe.authorityState,
              metadata.activationID == probe.activationID,
              metadata.committedSequence == probe.committedSequence else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "upgrade copy does not match the database that was recognized")
        }
    }

    /// Run the migration ladder from `version` to the current schema.
    ///
    /// Each step is its own transaction, so an interruption leaves the copy at a whole version and
    /// never half of one. The copy is discarded on any failure, so a partial ladder costs nothing.
    private func runUpgradeLadder(from version: Int) throws {
        guard version >= Self.lowestUpgradableSchemaVersion else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "schema v\(version) is older than this build can carry forward")
        }
        guard version <= Self.schemaVersion else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "schema v\(version) is newer than this build (v\(Self.schemaVersion))")
        }
        var current = version
        while current < Self.schemaVersion {
            switch current {
            case 2: try migrateV2ToV3()
            case 3: try migrateV3ToV4()
            case 4: try migrateV4ToV5()
            case 5: try migrateV5ToV6()
            case 6: try migrateV6ToV7()
            case 7: try migrateV7ToV8()
            case 8: try migrateV8ToV9()
            case 9: try migrateV9ToV10()
            case 10: try migrateV10ToV11()
            case 11: try migrateV11ToV12()
            case 12: try migrateV12ToV13()
            case 13: try migrateV13ToV14()
            case 14: try migrateV14ToV15()
            // A new schema version adds its step here. The cross-version upgrade test in
            // `check.sh` fails if it is forgotten, which is the whole point of that test.
            default:
                throw SQLiteLibraryStoreError.protectedDatabase(
                    "no migration step from schema v\(current)")
            }
            current += 1
            guard try scalarInt("PRAGMA user_version") == Int64(current) else {
                throw SQLiteLibraryStoreError.protectedDatabase(
                    "migration to v\(current) did not stamp the header")
            }
        }
    }

    static func openVerifiedReadOnlyShadow(supportRoot: URL) throws -> SQLiteLibraryStore {
        try SQLiteLibraryStore(readOnlySupportRoot: supportRoot)
    }

    static func openActiveAuthority(
        supportRoot: URL,
        marker: StorageAuthorityMarker
    ) throws -> SQLiteLibraryStore {
        try SQLiteLibraryStore(activeSupportRoot: supportRoot, marker: marker)
    }

    static func openActiveAuthorityInteractiveReader(
        supportRoot: URL,
        marker: StorageAuthorityMarker
    ) throws -> SQLiteLibraryStore {
        try SQLiteLibraryStore(
            interactiveReadOnlySupportRoot: supportRoot,
            marker: marker)
    }

    static func openInterruptedAuthority(
        supportRoot: URL,
        probe: StorageAuthorityDatabaseProbe
    ) throws -> SQLiteLibraryStore {
        try SQLiteLibraryStore(interruptedSupportRoot: supportRoot, probe: probe)
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - Caller API

    /// Reconcile complete current Conversation/Workspace source sets. Missing prior sources are
    /// stale and are removed from the shadow only; no source file is touched.
    ///
    /// This convenience is useful for bounded tests. Production launch should use the streaming
    /// begin/upsert/finish API below so only one decoded Conversation graph is retained at a time.
    @discardableResult
    func reconcile(_ snapshot: ShadowLibraryImportSnapshot) throws -> ShadowLibraryStatus {
        try validate(snapshot)
        let census = ShadowLibraryReconciliationCensus(
            workspaceSourceIdentities: Set(
                [snapshot.home.source.identity] + snapshot.workspaces.map(\.source.identity)),
            conversationSourceIdentities: Set(snapshot.conversations.map(\.source.identity)),
            artifactMediaSourceIdentities: nil)
        let token = try beginReconciliation(census)
        do {
            _ = try upsert(workspace: snapshot.home)
            for workspace in snapshot.workspaces { _ = try upsert(workspace: workspace) }
            for conversation in snapshot.conversations { _ = try upsert(conversation: conversation) }
            return try finishReconciliation(token)
        } catch {
            cancelReconciliation(token)
            throw error
        }
    }

    /// Start a full-set streaming reconcile. This invalidates the previous full-census claim before
    /// any source is imported, so a crash midway leaves a visibly incomplete (but disposable)
    /// candidate rather than stale green status.
    func beginReconciliation(
        _ census: ShadowLibraryReconciliationCensus
    ) throws -> ShadowLibraryReconciliationToken {
        guard !census.workspaceSourceIdentities.contains(where: \.isEmpty),
              !census.conversationSourceIdentities.contains(where: \.isEmpty),
              !(census.artifactMediaSourceIdentities?.contains(where: \.isEmpty) ?? false)
        else { throw SQLiteLibraryStoreError.invalidInput("the source census contains an empty identity") }
        return try queue.sync {
            guard activeReconciliation == nil else {
                throw SQLiteLibraryStoreError.invalidInput("a full reconciliation is already active")
            }
            try transaction {
                try execute(
                    "DELETE FROM domain_reconciliation WHERE domain IN ('conversations', 'workspaces', 'operative_state')")
                if census.artifactMediaSourceIdentities != nil {
                    try execute(
                        "DELETE FROM domain_reconciliation WHERE domain = 'artifact_media'")
                }
            }
            let token = ShadowLibraryReconciliationToken(id: UUID())
            activeReconciliation = ActiveReconciliation(token: token, census: census)
            return token
        }
    }

    /// Finish a streaming reconcile after every enumerated source has been imported. Stale rows are
    /// pruned only here. Missing expected imports fail visibly and leave the full-census marker
    /// absent. A coordinator composing adjacent domain imports may defer the expensive integrity
    /// pass and run `verifyIntegrity()` once after the final mutation.
    @discardableResult
    func finishReconciliation(
        _ token: ShadowLibraryReconciliationToken,
        verifyingIntegrity: Bool = true
    ) throws -> ShadowLibraryStatus {
        try queue.sync {
            guard let active = activeReconciliation, active.token == token else {
                throw SQLiteLibraryStoreError.invalidInput("unknown reconciliation token")
            }
            let missingWorkspaces = missingAccountedSources(
                expected: active.census.workspaceSourceIdentities,
                accounted: active.accountedWorkspaceSources)
            let missingConversations = missingAccountedSources(
                expected: active.census.conversationSourceIdentities,
                accounted: active.accountedConversationSources)
            let missingOperativeState = missingAccountedSources(
                expected: active.census.conversationSourceIdentities,
                accounted: active.accountedOperativeStateSources)
            let missingArtifactMedia = active.census.artifactMediaSourceIdentities.map {
                missingAccountedSources(
                    expected: $0,
                    accounted: active.accountedArtifactMediaSources)
            } ?? []
            guard missingWorkspaces.isEmpty, missingConversations.isEmpty,
                  missingOperativeState.isEmpty,
                  missingArtifactMedia.isEmpty else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "reconciliation did not import every source (Workspace: \(missingWorkspaces.count), Conversation: \(missingConversations.count), operative: \(missingOperativeState.count), Artifact/media: \(missingArtifactMedia.count))")
            }
            try transaction {
                try removeStaleSources(
                    domain: .conversations,
                    retaining: active.census.conversationSourceIdentities)
                try removeStaleSources(
                    domain: .operativeState,
                    retaining: active.census.conversationSourceIdentities)
                try removeStaleSources(
                    domain: .workspaces,
                    retaining: active.census.workspaceSourceIdentities)
                if let artifactMediaSources = active.census.artifactMediaSourceIdentities {
                    try removeStaleSources(
                        domain: .artifactMedia,
                        retaining: artifactMediaSources)
                }
                try removeOrphanUnresolvedWorkspaces()
                try markFullCensus(
                    domain: .conversations,
                    expected: try sourceCount(domain: .conversations))
                try markFullCensus(
                    domain: .operativeState,
                    expected: try sourceCount(domain: .operativeState))
                try markFullCensus(
                    domain: .workspaces,
                    expected: try sourceCount(domain: .workspaces))
                if active.census.artifactMediaSourceIdentities != nil {
                    try markFullCensus(
                        domain: .artifactMedia,
                        expected: try sourceCount(domain: .artifactMedia))
                }
            }
            activeReconciliation = nil
            if verifyingIntegrity {
                _ = try verifyIntegrityAndRecord()
            }
            try applyOwnerOnlyFilePermissions()
            return try makeStatus()
        }
    }

    func cancelReconciliation(_ token: ShadowLibraryReconciliationToken) {
        queue.sync {
            if activeReconciliation?.token == token { activeReconciliation = nil }
        }
    }

    /// Fast path for a launch census whose exact bytes were imported previously. The caller still
    /// hashes the source, but avoids decoding and re-encoding a 10k-entry Conversation merely to
    /// prove it is unchanged. Entity ownership is checked so duplicate identities cannot skip the
    /// winner-repair path.
    func accountIfImportedDigestIsCurrent(
        domain: ShadowLibraryDomain,
        source: ShadowLibrarySourceFingerprint
    ) throws -> Bool {
        guard domain == .conversations || domain == .workspaces else {
            throw SQLiteLibraryStoreError.invalidInput(
                "the digest-receipt fast path does not import the \(domain.rawValue) domain")
        }
        try validate(source: source)
        return try queue.sync {
            let entityTable = domain == .conversations ? "conversations" : "workspaces"
            let operativeReceiptClause = domain == .conversations
                ? """
                  AND EXISTS (
                    SELECT 1 FROM migration_sources operative
                    WHERE operative.domain = 'operative_state'
                      AND operative.source_identity = m.source_identity
                      AND operative.entity_id = m.entity_id
                      AND operative.observed_digest = ?3 AND operative.imported_digest = ?3
                      AND operative.dirty = 0 AND operative.import_state = 'current'
                  )
                  """
                : ""
            var current = false
            try query(
                """
                SELECT 1 FROM migration_sources m
                WHERE m.domain = ?1 AND m.source_identity = ?2
                  AND m.observed_digest = ?3 AND m.imported_digest = ?3
                  AND m.dirty = 0 AND m.import_state = 'current'
                  AND EXISTS (
                    SELECT 1 FROM \(entityTable) e
                    WHERE e.id = m.entity_id AND e.source_identity = m.source_identity
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM migration_sources other
                    WHERE other.domain = m.domain AND other.entity_id = m.entity_id
                      AND other.source_identity != m.source_identity
                  )
                  \(operativeReceiptClause)
                """,
                [.text(domain.rawValue), .text(source.identity), .text(source.digest)]) { _ in
                    current = true
                }
            if current {
                // The bytes are identical, but the O(1) filesystem-generation receipt may have
                // changed (or may predate lstat-v1). Rebind that receipt transactionally without
                // rewriting the already-proven event graph. Otherwise later product launches
                // reject a semantically current row and fall back forever.
                let importedAt = Date().timeIntervalSinceReferenceDate
                try transaction {
                    try execute(
                        """
                        UPDATE migration_sources
                        SET observed_revision = ?1, observed_digest = ?2,
                            source_byte_count = ?3, imported_revision = ?1,
                            imported_digest = ?2, dirty = 0, import_state = 'current',
                            diagnostics = NULL, imported_at = ?4
                        WHERE domain = ?5 AND source_identity = ?6
                        """,
                        [
                            .text(source.revision), .text(source.digest),
                            .int(Int64(source.byteCount)), .double(importedAt),
                            .text(domain.rawValue), .text(source.identity),
                        ])
                    if domain == .conversations {
                        try execute(
                            """
                            UPDATE migration_sources
                            SET observed_revision = ?1, observed_digest = ?2,
                                source_byte_count = ?3, imported_revision = ?1,
                                imported_digest = ?2, dirty = 0, import_state = 'current',
                                diagnostics = NULL, imported_at = ?4
                            WHERE domain = 'operative_state' AND source_identity = ?5
                            """,
                            [
                                .text(source.revision), .text(source.digest),
                                .int(Int64(source.byteCount)), .double(importedAt),
                                .text(source.identity),
                            ])
                        guard let entityID = UUID(uuidString: try requiredEntityID(
                            domain: .conversations,
                            sourceIdentity: source.identity)) else {
                            throw SQLiteLibraryStoreError.invalidInput(
                                "current Conversation receipt has an invalid entity id")
                        }
                        try enqueueConversationProjection(entityID: entityID)
                    }
                }
                accountActiveReconciliation(domain: domain, sourceIdentity: source.identity)
                if domain == .conversations {
                    accountActiveReconciliation(
                        domain: .operativeState,
                        sourceIdentity: source.identity)
                }
            }
            return current
        }
    }

    /// Incremental shadow import after a named Workspace or Home JSON write succeeds.
    @discardableResult
    func upsert(workspace: ShadowLibraryWorkspaceSnapshot) throws -> ShadowLibraryStatus {
        try queue.sync {
            try validate(workspace: workspace)
            try transaction { try upsertWorkspace(workspace) }
            accountActiveReconciliation(
                domain: .workspaces,
                sourceIdentity: workspace.source.identity)
            try applyOwnerOnlyFilePermissions()
            return try makeStatus()
        }
    }

    /// Incremental shadow import after a Conversation JSON write succeeds.
    @discardableResult
    func upsert(conversation: ShadowLibraryConversationSnapshot) throws -> ShadowLibraryStatus {
        try queue.sync {
            try validate(conversation: conversation)
            try transaction { try upsertConversation(conversation) }
            accountActiveReconciliation(
                domain: .conversations,
                sourceIdentity: conversation.source.identity)
            accountActiveReconciliation(
                domain: .operativeState,
                sourceIdentity: conversation.source.identity)
            try applyOwnerOnlyFilePermissions()
            return try makeStatus()
        }
    }

    /// Reconcile the three durable ambient authorities without interpreting heartbeat or lease
    /// process state. A complete census may prune absent sources; an incomplete scan is update-only.
    @discardableResult
    func reconcileAmbient(_ inventory: ShadowLibraryAmbientInventory) throws -> ShadowLibraryStatus {
        try validate(ambient: inventory)
        return try queue.sync {
            let live = Set(inventory.sources.map(\.source.identity)
                + inventory.sourceIssues.map(\.source.identity))
            if try ambientReconciliationIsCurrent(inventory, live: live) {
                return try makeStatus()
            }
            try transaction {
                try execute("DELETE FROM domain_reconciliation WHERE domain = 'ambient_state'")
                for source in inventory.sources { try upsertAmbient(source) }
                for issue in inventory.sourceIssues {
                    try execute(
                        "DELETE FROM ambient_authority_sources WHERE source_identity = ?1",
                        [.text(issue.source.identity)])
                    try recordSourceIssueInternal(
                        domain: .ambientState,
                        source: issue.source,
                        entityIdentity: issue.entityIdentity,
                        kind: issue.kind,
                        diagnostics: issue.diagnostics)
                }
                if inventory.hasCompleteCensus {
                    var stalePayloadSources: [String] = []
                    try query("SELECT source_identity FROM ambient_authority_sources", []) {
                        guard let identity = Self.optionalText($0, 0), !live.contains(identity)
                        else { return }
                        stalePayloadSources.append(identity)
                    }
                    for identity in stalePayloadSources {
                        try execute(
                            "DELETE FROM ambient_authority_sources WHERE source_identity = ?1",
                            [.text(identity)])
                    }
                    try removeStaleSources(domain: .ambientState, retaining: live)
                    try markFullCensus(
                        domain: .ambientState,
                        expected: try sourceCount(domain: .ambientState))
                }
            }
            try applyOwnerOnlyFilePermissions()
            return try makeStatus()
        }
    }

    /// Strict A2/rollback input. Every returned payload is bound to its current source receipt;
    /// malformed, stale, or future rows throw rather than becoming an empty scheduler.
    func ambientSnapshots() throws -> [ShadowLibraryAmbientSnapshot] {
        try queue.sync { try readAmbientSnapshots() }
    }

    /// Reconcile operation intents/receipts and the immutable recovery bytes they retain. The
    /// current pre-activation producer is the legacy Conversation trash; later A3 writers use the
    /// same bounded repository without serializing `UndoManager` or an entire Conversation.
    @discardableResult
    func reconcileOperations(
        _ inventory: ShadowLibraryOperationInventory
    ) throws -> ShadowLibraryStatus {
        try validate(operationInventory: inventory)
        return try queue.sync {
            let live = Set(inventory.operations.map(\.source.identity)
                + inventory.retainedSources.map(\.source.identity)
                + inventory.sourceIssues.map(\.source.identity))
            if try operationReconciliationIsCurrent(inventory, live: live) {
                return try makeStatus()
            }
            try transaction {
                try execute("DELETE FROM domain_reconciliation WHERE domain = 'operations'")
                for value in inventory.operations { try upsertOperation(value) }
                try execute("DELETE FROM operation_receipts")
                for receipt in inventory.receipts { try upsertOperationReceipt(receipt) }
                for retained in inventory.retainedSources {
                    try upsertOperationRetainedSource(retained)
                }
                for issue in inventory.sourceIssues {
                    try execute(
                        "DELETE FROM operation_retained_sources WHERE source_identity = ?1",
                        [.text(issue.source.identity)])
                    try execute(
                        "DELETE FROM operations WHERE source_identity = ?1",
                        [.text(issue.source.identity)])
                    try recordSourceIssueInternal(
                        domain: .operations,
                        source: issue.source,
                        entityIdentity: issue.operationID?.uuidString,
                        kind: issue.kind,
                        diagnostics: issue.diagnostics)
                }
                if inventory.hasCompleteCensus {
                    try removeStaleSources(domain: .operations, retaining: live)
                    try markFullCensus(
                        domain: .operations,
                        expected: try sourceCount(domain: .operations))
                }
            }
            try applyOwnerOnlyFilePermissions()
            return try makeStatus()
        }
    }

    /// Strict A2/rollback input. Every operation and retained recovery edge is validated against
    /// its current migration receipt before it can influence runtime reconstruction.
    func operationSnapshots() throws -> ShadowLibraryOperationReadSnapshot {
        try queue.sync { try readOperationSnapshots() }
    }

    /// Fingerprints already inventoried from exact artifact/media bytes. The scanner may compare a
    /// strong file revision (device/inode/size/mtime/ctime) and reuse the digest instead of reading a
    /// multi-gigabyte immutable corpus on every launch.
    func cachedArtifactMediaFingerprints() throws -> [String: ShadowLibrarySourceFingerprint] {
        try queue.sync {
            var result: [String: ShadowLibrarySourceFingerprint] = [:]
            try query(
                """
                SELECT source_identity, observed_revision, observed_digest, source_byte_count
                FROM migration_sources
                WHERE domain = 'artifact_media' AND imported_digest IS NOT NULL
                  AND observed_digest = imported_digest
                """,
                []) { statement in
                    guard let identity = Self.optionalText(statement, 0),
                          let revision = Self.optionalText(statement, 1),
                          let digest = Self.optionalText(statement, 2) else { return }
                    result[identity] = ShadowLibrarySourceFingerprint(
                        identity: identity,
                        revision: revision,
                        digest: digest,
                        byteCount: Int(sqlite3_column_int64(statement, 3)))
                }
            return result
        }
    }

    @discardableResult
    func upsert(artifact: ShadowLibraryArtifactSnapshot) throws -> ShadowLibraryStatus {
        try validate(artifact: artifact)
        return try queue.sync {
            if try !sourceIsCurrent(
                domain: .artifactMedia,
                source: artifact.source,
                entityID: artifact.id
            ) {
                try transaction { try upsertArtifact(artifact) }
            }
            accountActiveReconciliation(
                domain: .artifactMedia,
                sourceIdentity: artifact.source.identity)
            try applyOwnerOnlyFilePermissions()
            return try makeStatus()
        }
    }

    @discardableResult
    func upsert(retainedByte: ShadowLibraryRetainedByteSnapshot) throws -> ShadowLibraryStatus {
        try validate(retainedByte: retainedByte)
        return try queue.sync {
            let normalized = try normalizedRetainedByte(retainedByte)
            if try !retainedByteIsCurrent(retainedByte, normalized: normalized) {
                try transaction { try upsertRetainedByte(retainedByte, normalized: normalized) }
            }
            accountActiveReconciliation(
                domain: .artifactMedia,
                sourceIdentity: retainedByte.source.identity)
            try applyOwnerOnlyFilePermissions()
            return try makeStatus()
        }
    }

    /// Record that a successful legacy write is newer than the imported candidate. This call is
    /// cheap and makes the status pessimistic before asynchronous conversion catches up.
    @discardableResult
    func markSourceDirty(
        domain: ShadowLibraryDomain,
        source: ShadowLibrarySourceFingerprint,
        entityID: UUID
    ) throws -> ShadowLibraryStatus {
        guard domain == .conversations || domain == .workspaces else {
            throw SQLiteLibraryStoreError.invalidInput(
                "incremental dirty tracking does not support the \(domain.rawValue) domain")
        }
        try validate(source: source)
        return try queue.sync {
            var importedRevision: String?
            var importedDigest: String?
            try query(
                """
                SELECT imported_revision, imported_digest
                FROM migration_sources WHERE domain = ?1 AND source_identity = ?2
                """,
                [.text(domain.rawValue), .text(source.identity)]) { statement in
                    importedRevision = Self.optionalText(statement, 0)
                    importedDigest = Self.optionalText(statement, 1)
                }
            let state = importedDigest == nil
                ? "pending"
                : ((importedRevision == source.revision && importedDigest == source.digest)
                    ? "pending" : "mismatch")
            try transaction {
                try execute(
                    """
                    INSERT INTO migration_sources (
                      domain, source_identity, entity_id, observed_revision, observed_digest,
                      source_byte_count, imported_revision, imported_digest, dirty, import_state,
                      diagnostics, imported_at)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 1, ?9, NULL, NULL)
                    ON CONFLICT(domain, source_identity) DO UPDATE SET
                      entity_id = excluded.entity_id,
                      observed_revision = excluded.observed_revision,
                      observed_digest = excluded.observed_digest,
                      source_byte_count = excluded.source_byte_count,
                      dirty = 1,
                      import_state = excluded.import_state,
                      diagnostics = NULL
                    """,
                    [
                        .text(domain.rawValue), .text(source.identity), .text(entityID.uuidString),
                        .text(source.revision), .text(source.digest), .int(Int64(source.byteCount)),
                        importedRevision.map(SQLiteValue.text) ?? .null,
                        importedDigest.map(SQLiteValue.text) ?? .null,
                        .text(state),
                    ])
                if domain == .conversations {
                    try execute(
                        """
                        INSERT INTO migration_sources (
                          domain, source_identity, entity_id, observed_revision, observed_digest,
                          source_byte_count, imported_revision, imported_digest, dirty, import_state,
                          diagnostics, imported_at)
                        VALUES ('operative_state', ?1, ?2, ?3, ?4, ?5, ?6, ?7, 1, ?8, NULL, NULL)
                        ON CONFLICT(domain, source_identity) DO UPDATE SET
                          entity_id = excluded.entity_id,
                          observed_revision = excluded.observed_revision,
                          observed_digest = excluded.observed_digest,
                          source_byte_count = excluded.source_byte_count,
                          dirty = 1,
                          import_state = excluded.import_state,
                          diagnostics = NULL
                        """,
                        [
                            .text(source.identity), .text(entityID.uuidString),
                            .text(source.revision), .text(source.digest),
                            .int(Int64(source.byteCount)),
                            importedRevision.map(SQLiteValue.text) ?? .null,
                            importedDigest.map(SQLiteValue.text) ?? .null,
                            .text(state),
                        ])
                }
            }
            try applyOwnerOnlyFilePermissions()
            return try makeStatus()
        }
    }

    /// Account for a source the scanner saw but could not turn into an entity snapshot. Exact bytes
    /// remain owned by the legacy/quarantine layer; their fingerprint and diagnosis stay visible so
    /// full-corpus coverage cannot become green by omission.
    @discardableResult
    func recordSourceIssue(
        domain: ShadowLibraryDomain,
        source: ShadowLibrarySourceFingerprint,
        entityIdentity: String? = nil,
        kind: ShadowLibrarySourceIssueKind,
        diagnostics: String
    ) throws -> ShadowLibraryStatus {
        try validate(source: source)
        guard !diagnostics.isEmpty else {
            throw SQLiteLibraryStoreError.invalidInput("source issue diagnosis is empty")
        }
        return try queue.sync {
            try transaction {
                try recordSourceIssueInternal(
                    domain: domain,
                    source: source,
                    entityIdentity: entityIdentity,
                    kind: kind,
                    diagnostics: diagnostics)
                if domain == .conversations {
                    try recordSourceIssueInternal(
                        domain: .operativeState,
                        source: source,
                        entityIdentity: entityIdentity,
                        kind: kind,
                        diagnostics: diagnostics)
                }
            }
            accountActiveReconciliation(domain: domain, sourceIdentity: source.identity)
            if domain == .conversations {
                accountActiveReconciliation(
                    domain: .operativeState,
                    sourceIdentity: source.identity)
            }
            try applyOwnerOnlyFilePermissions()
            return try makeStatus()
        }
    }

    @discardableResult
    func removeConversation(sourceIdentity: String) throws -> ShadowLibraryStatus {
        try queue.sync {
            try transaction {
                try execute(
                    """
                    UPDATE retained_byte_sources
                    SET storage_state = 'observed',
                        disposition = CASE
                          WHEN disposition = 'referenced' THEN 'reference_pending'
                          ELSE disposition
                        END
                    WHERE storage_class = 'legacy_layout'
                      AND owner_conversation_id = (
                        SELECT id FROM conversations WHERE source_identity = ?1)
                    """,
                    [.text(sourceIdentity)])
                try execute(
                    "DELETE FROM conversations WHERE source_identity = ?1",
                    [.text(sourceIdentity)])
                try execute(
                    "DELETE FROM migration_sources WHERE domain = 'conversations' AND source_identity = ?1",
                    [.text(sourceIdentity)])
                try execute(
                    "DELETE FROM migration_sources WHERE domain = 'operative_state' AND source_identity = ?1",
                    [.text(sourceIdentity)])
            }
            try applyOwnerOnlyFilePermissions()
            return try makeStatus()
        }
    }

    /// Delete a named Workspace shadow after its source is removed. If current Conversation rows
    /// still refer to it, its stable id becomes an explicit unresolved placeholder instead of
    /// silently moving those Conversations to Home.
    @discardableResult
    func removeWorkspace(sourceIdentity: String) throws -> ShadowLibraryStatus {
        try queue.sync {
            var entityID: String?
            try query(
                """
                SELECT entity_id FROM migration_sources
                WHERE domain = 'workspaces' AND source_identity = ?1
                """,
                [.text(sourceIdentity)]) { entityID = Self.optionalText($0, 0) }
            guard entityID != Self.homeWorkspaceID.uuidString else {
                throw SQLiteLibraryStoreError.invalidInput("the reserved Home Workspace cannot be removed")
            }
            try transaction {
                if let rawID = entityID, let id = UUID(uuidString: rawID),
                   try workspaceReferenceCount(id) > 0 {
                    try convertToUnresolvedWorkspace(id, staleSourceIdentity: sourceIdentity)
                } else {
                    try execute(
                        "DELETE FROM workspaces WHERE source_identity = ?1 AND kind = 'named'",
                        [.text(sourceIdentity)])
                    try execute(
                        "DELETE FROM migration_sources WHERE domain = 'workspaces' AND source_identity = ?1",
                        [.text(sourceIdentity)])
                }
            }
            try applyOwnerOnlyFilePermissions()
            return try makeStatus()
        }
    }

    @discardableResult
    func removeArtifact(sourceIdentity: String) throws -> ShadowLibraryStatus {
        try queue.sync {
            try transaction {
                try execute(
                    "DELETE FROM artifacts WHERE source_identity = ?1",
                    [.text(sourceIdentity)])
                try execute(
                    "DELETE FROM migration_sources WHERE domain = 'artifact_media' AND source_identity = ?1",
                    [.text(sourceIdentity)])
                try removeOrphanUnresolvedWorkspaces()
            }
            try applyOwnerOnlyFilePermissions()
            return try makeStatus()
        }
    }

    @discardableResult
    func removeRetainedByte(sourceIdentity: String) throws -> ShadowLibraryStatus {
        try queue.sync {
            try transaction {
                try execute(
                    "DELETE FROM retained_byte_sources WHERE source_identity = ?1",
                    [.text(sourceIdentity)])
                try execute(
                    "DELETE FROM migration_sources WHERE domain = 'artifact_media' AND source_identity = ?1",
                    [.text(sourceIdentity)])
            }
            try applyOwnerOnlyFilePermissions()
            return try makeStatus()
        }
    }

    @discardableResult
    func removeRetainedBytes(ownerConversationID: UUID) throws -> ShadowLibraryStatus {
        try queue.sync {
            var identities: [String] = []
            try query(
                "SELECT source_identity FROM retained_byte_sources WHERE owner_conversation_id = ?1",
                [.text(ownerConversationID.uuidString)]) {
                    if let identity = Self.optionalText($0, 0) { identities.append(identity) }
                }
            try transaction {
                try execute(
                    "DELETE FROM retained_byte_sources WHERE owner_conversation_id = ?1",
                    [.text(ownerConversationID.uuidString)])
                for identity in identities {
                    try execute(
                        "DELETE FROM migration_sources WHERE domain = 'artifact_media' AND source_identity = ?1",
                        [.text(identity)])
                }
            }
            try applyOwnerOnlyFilePermissions()
            return try makeStatus()
        }
    }

    func status() throws -> ShadowLibraryStatus {
        try queue.sync { try makeStatus() }
    }

    func authorityMetadata() throws -> LibraryAuthorityMetadata {
        try queue.sync { try readAuthorityMetadata() }
    }

    /// Proves that an unmarked database contains only the empty-library bootstrap shape.
    ///
    /// This is deliberately stricter than "there are no Conversations." An interrupted legacy
    /// import may have populated any adjacent authority table, and publishing a marker over that
    /// unknown generation would silently bless it. The only accepted rows are the reserved Home
    /// Workspace and, after the bootstrap has seeded it, that Workspace's one exact source receipt.
    func requirePristineBootstrapShape() throws {
        try queue.sync {
            let metadata = try readAuthorityMetadata()
            guard metadata.authorityState == .shadow
                    || metadata.authorityState == .prepared
                    || metadata.authorityState == .active,
                  metadata.rollbackID == nil else {
                throw SQLiteLibraryStoreError.protectedDatabase(
                    "unmarked database is not an empty-library bootstrap candidate")
            }

            let emptyTables = [
                "conversations", "conversation_events", "conversation_artifact_snapshots",
                "artifacts", "retained_byte_sources", "retained_byte_references",
                "ambient_authority_sources", "operations", "operation_receipts",
                "operation_retained_sources",
            ]
            for table in emptyTables where try scalarInt("SELECT COUNT(*) FROM \(table)") != 0 {
                throw SQLiteLibraryStoreError.protectedDatabase(
                    "unmarked database contains non-bootstrap rows in \(table)")
            }

            guard try scalarInt("SELECT COUNT(*) FROM workspaces") == 1,
                  try scalarInt(
                    "SELECT COUNT(*) FROM workspaces WHERE id = '\(Self.homeWorkspaceID.uuidString)' AND kind = 'home' AND tombstoned = 0") == 1 else {
                throw SQLiteLibraryStoreError.protectedDatabase(
                    "unmarked database does not contain exactly the reserved Home Workspace")
            }

            let sourceCount = try scalarInt("SELECT COUNT(*) FROM migration_sources")
            guard sourceCount == 0 || sourceCount == 1 else {
                throw SQLiteLibraryStoreError.protectedDatabase(
                    "unmarked database contains non-bootstrap source receipts")
            }
            if sourceCount == 1 {
                guard try scalarInt(
                    """
                    SELECT COUNT(*) FROM migration_sources
                    WHERE domain = 'workspaces'
                      AND source_identity = 'home-workspace.json'
                      AND entity_id = '\(Self.homeWorkspaceID.uuidString)'
                      AND dirty = 0 AND import_state = 'current'
                      AND observed_digest = imported_digest
                    """) == 1 else {
                    throw SQLiteLibraryStoreError.protectedDatabase(
                        "unmarked database contains an unexpected source receipt")
                }
            }

            guard try scalarInt(
                """
                SELECT COUNT(*) FROM domain_reconciliation
                WHERE domain NOT IN ('conversations', 'operative_state', 'workspaces')
                """) == 0 else {
                throw SQLiteLibraryStoreError.protectedDatabase(
                    "unmarked database contains a non-bootstrap reconciliation receipt")
            }
        }
    }

    func activeIntegrityReceiptIsCurrent(activationID: UUID) throws -> Bool {
        try queue.sync {
            try requireActiveAuthority(activationID)
            var current = false
            try query(
                """
                SELECT integrity_result = 'passed'
                  AND integrity_checked_sequence = committed_sequence
                  AND committed_sequence = shadow_change_sequence
                FROM library_metadata WHERE singleton = 1
                """,
                []) { statement in current = sqlite3_column_int(statement, 0) != 0 }
            return current
        }
    }

    /// Prepare the exact reconciled shadow generation for marker-last authority publication.
    /// `projections.db` is disposable and explicitly allowed to lag authoritative commits, so its
    /// durable outbox crosses activation and catches up asynchronously after the active repository
    /// opens. Search readiness is never a content-authority prerequisite.
    func prepareAuthority(activationID: UUID, minimumWriterBuild: String) throws {
        guard !minimumWriterBuild.isEmpty else {
            throw SQLiteLibraryStoreError.invalidInput("minimum writer build is empty")
        }
        try queue.sync {
            guard activeReconciliation == nil else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "authority cannot prepare during reconciliation")
            }
            let metadata = try readAuthorityMetadata()
            guard metadata.authorityState == .shadow else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "illegal authority transition from \(metadata.authorityState.rawValue) to prepared")
            }
            try transaction(tracksMutation: false, requiresShadow: false) {
                try requireAuthorityState(.shadow)
                let transactionShadowChangeSequence = try currentShadowChangeSequence()
                try execute(
                    """
                    UPDATE library_metadata
                    SET authority_state = 'prepared', activation_id = ?1,
                        minimum_writer_build = ?2, committed_sequence = ?3
                    WHERE singleton = 1
                    """,
                    [
                        .text(activationID.uuidString), .text(minimumWriterBuild),
                        .int(transactionShadowChangeSequence),
                    ])
            }
            do {
                if FileManager.default.fileExists(atPath: resetMarkerURL.path) {
                    try FileManager.default.removeItem(at: resetMarkerURL)
                }
            } catch {
                throw SQLiteLibraryStoreError.permissions(
                    "could not retire shadow reset marker: \(error.localizedDescription)")
            }
        }
    }

    func activatePreparedAuthority(activationID: UUID) throws {
        try transitionAuthority(
            from: .prepared,
            to: .active,
            activationID: activationID,
            rollbackID: nil)
    }

    func prepareRollback(activationID: UUID, rollbackID: UUID) throws {
        try transitionAuthority(
            from: .active,
            to: .rollbackPrepared,
            activationID: activationID,
            rollbackID: rollbackID)
    }

    func completeRollback(activationID: UUID, rollbackID: UUID) throws {
        try transitionAuthority(
            from: .rollbackPrepared,
            to: .rolledBack,
            activationID: activationID,
            rollbackID: rollbackID)
    }

    @discardableResult
    func advanceCommittedSequence(activationID: UUID) throws -> Int64 {
        try queue.sync {
            let metadata = try readAuthorityMetadata()
            guard metadata.authorityState == .active,
                  metadata.activationID == activationID else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "committed sequence requires the matching active authority")
            }
            let next = metadata.committedSequence + 1
            try transaction(tracksMutation: false, requiresShadow: false) {
                try execute(
                    """
                    UPDATE library_metadata
                    SET committed_sequence = ?1
                    WHERE singleton = 1 AND authority_state = 'active' AND activation_id = ?2
                    """,
                    [.int(next), .text(activationID.uuidString)])
            }
            return next
        }
    }

    func workspaceSnapshot(id: UUID) throws -> ShadowLibraryWorkspaceSnapshot? {
        try queue.sync { try readWorkspaceSnapshot(id: id) }
    }

    func conversationSnapshot(id: UUID) throws -> ShadowLibraryConversationSnapshot? {
        try queue.sync { try readConversationSnapshot(id: id) }
    }

    /// Return one receipt-gated Conversation plus its complete referenced-byte edge set from a
    /// single SQLite snapshot. This is the store boundary for A2's read rehearsal; callers still
    /// compare `conversation.source` with the exact currently authoritative legacy fingerprint
    /// before using the value and fall back to that legacy source on any error or mismatch.
    func conversationReadBundle(id: UUID) throws -> ShadowLibraryConversationReadBundle? {
        try queue.sync {
            try readTransaction {
                try readValidatedConversationBundle(id: id)
            }
        }
    }

    // MARK: - A2b2 committed-shadow projection outbox

    /// A disposable projection was absent, corrupt, foreign, or otherwise failed the exact launch
    /// comparison. Re-queue the complete live Conversation set from SQLite even when all prior
    /// incremental work had already been acknowledged. This reset changes no product authority and
    /// scans no Legacy files; it only invalidates the projection acknowledgement and coalesces one
    /// replay job per current library row.
    func prepareFullProjectionReplay(
        kind: ShadowLibraryProjectionWorkItem.Kind = .conversationSearch,
        projectionSchemaVersion: Int
    ) throws {
        guard projectionSchemaVersion > 0 else {
            throw SQLiteLibraryStoreError.invalidInput(
                "projection schema version must be positive")
        }
        try queue.sync {
            let metadata = try readAuthorityMetadata()
            guard metadata.authorityState == .shadow || metadata.authorityState == .active else {
                throw SQLiteLibraryStoreError.protectedDatabase(
                    "projection replay requires shadow or active authority state")
            }
            try transaction(tracksMutation: false, requiresShadow: false) {
                try ensureProjectionState(
                    databaseInstanceID: metadata.databaseInstanceID,
                    kind: kind,
                    schemaVersion: projectionSchemaVersion)
                try execute(
                    """
                    INSERT INTO projection_outbox (
                      database_instance_id, projection_kind, entity_id, desired_sequence,
                      force_reindex)
                    SELECT ?1, ?2, id, ?3, 1
                    FROM conversations
                    WHERE tombstoned = 0
                    ON CONFLICT(database_instance_id, projection_kind, entity_id) DO UPDATE SET
                      desired_sequence = MAX(
                        projection_outbox.desired_sequence, excluded.desired_sequence),
                      force_reindex = 1,
                      last_error = NULL
                    """,
                    [
                        .text(metadata.databaseInstanceID.uuidString), .text(kind.rawValue),
                        .int(try currentShadowChangeSequence()),
                    ])
                try execute(
                    """
                    UPDATE projection_state
                    SET projection_schema_version = ?1,
                        applied_high_water_sequence = 0,
                        health = 'queued',
                        last_error = NULL,
                        updated_at = ?2
                    WHERE database_instance_id = ?3 AND projection_kind = ?4
                    """,
                    [
                        .int(Int64(projectionSchemaVersion)),
                        .double(Date().timeIntervalSinceReferenceDate),
                        .text(metadata.databaseInstanceID.uuidString), .text(kind.rawValue),
                    ])
            }
        }
    }

    /// Claim the oldest coalesced summary/FTS job. The claimed payload is reconstructed from the
    /// same committed SQLite snapshot, never from Legacy JSON. A crash after this method merely
    /// leaves the row pending; only `acknowledgeProjectionWork` may prune it.
    func nextProjectionWork(
        kind: ShadowLibraryProjectionWorkItem.Kind = .conversationSearch,
        projectionSchemaVersion: Int
    ) throws -> ShadowLibraryProjectionWorkItem? {
        guard projectionSchemaVersion > 0 else {
            throw SQLiteLibraryStoreError.invalidInput(
                "projection schema version must be positive")
        }
        return try queue.sync {
            let metadata = try readAuthorityMetadata()
            guard metadata.authorityState == .shadow || metadata.authorityState == .active else {
                throw SQLiteLibraryStoreError.protectedDatabase(
                    "projection catch-up requires shadow or active authority state")
            }
            var rowWasRead = false
            var rawEntityID: String?
            var desiredSequence: Int64?
            var forceReindex = false
            try query(
                """
                SELECT entity_id, desired_sequence, force_reindex
                FROM projection_outbox
                WHERE database_instance_id = ?1 AND projection_kind = ?2
                ORDER BY desired_sequence, entity_id
                LIMIT 1
                """,
                [.text(metadata.databaseInstanceID.uuidString), .text(kind.rawValue)]) {
                    rowWasRead = true
                    rawEntityID = Self.optionalText($0, 0)
                    desiredSequence = sqlite3_column_int64($0, 1)
                    forceReindex = sqlite3_column_int64($0, 2) != 0
                }
            guard rowWasRead else {
                try transaction(tracksMutation: false, requiresShadow: false) {
                    try updateProjectionState(
                        databaseInstanceID: metadata.databaseInstanceID,
                        kind: kind,
                        schemaVersion: projectionSchemaVersion,
                        health: "projecting",
                        lastError: nil)
                }
                return nil
            }
            guard let rawEntityID, let entityID = UUID(uuidString: rawEntityID),
                  let desiredSequence, desiredSequence >= 0 else {
                let diagnostics = "projection outbox contains a malformed entity or sequence"
                try transaction(tracksMutation: false, requiresShadow: false) {
                    try updateProjectionState(
                        databaseInstanceID: metadata.databaseInstanceID,
                        kind: kind,
                        schemaVersion: projectionSchemaVersion,
                        health: "failed",
                        lastError: diagnostics)
                }
                throw SQLiteLibraryStoreError.invalidInput(diagnostics)
            }
            try transaction(tracksMutation: false, requiresShadow: false) {
                try ensureProjectionState(
                    databaseInstanceID: metadata.databaseInstanceID,
                    kind: kind,
                    schemaVersion: projectionSchemaVersion)
                try execute(
                    """
                    UPDATE projection_outbox
                    SET attempt_count = attempt_count + 1, last_attempt_at = ?1, last_error = NULL
                    WHERE database_instance_id = ?2 AND projection_kind = ?3
                      AND entity_id = ?4 AND desired_sequence = ?5
                    """,
                    [
                        .double(Date().timeIntervalSinceReferenceDate),
                        .text(metadata.databaseInstanceID.uuidString), .text(kind.rawValue),
                        .text(entityID.uuidString), .int(desiredSequence),
                    ])
                try updateProjectionState(
                    databaseInstanceID: metadata.databaseInstanceID,
                    kind: kind,
                    schemaVersion: projectionSchemaVersion,
                    health: "projecting",
                    lastError: nil)
            }
            let snapshot = try readTransaction {
                try readConversationSnapshot(id: entityID)
            }
            return ShadowLibraryProjectionWorkItem(
                databaseInstanceID: metadata.databaseInstanceID,
                kind: kind,
                entityID: entityID,
                desiredSequence: desiredSequence,
                forceReindex: forceReindex,
                conversation: snapshot?.tombstoned == false ? snapshot : nil)
        }
    }

    /// A projection transaction has committed. Delete only the exact desired sequence that was
    /// applied: if a newer publication coalesced while the worker ran, its larger sequence remains
    /// queued and the old acknowledgement is harmless.
    func acknowledgeProjectionWork(
        _ work: ShadowLibraryProjectionWorkItem,
        projectionSchemaVersion: Int
    ) throws {
        try queue.sync {
            let metadata = try readAuthorityMetadata()
            guard metadata.databaseInstanceID == work.databaseInstanceID else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "projection acknowledgement names a foreign database instance")
            }
            try transaction(tracksMutation: false, requiresShadow: false) {
                try execute(
                    """
                    DELETE FROM projection_outbox
                    WHERE database_instance_id = ?1 AND projection_kind = ?2
                      AND entity_id = ?3 AND desired_sequence = ?4
                    """,
                    [
                        .text(work.databaseInstanceID.uuidString), .text(work.kind.rawValue),
                        .text(work.entityID.uuidString), .int(work.desiredSequence),
                    ])
                try updateProjectionStateFromBacklog(
                    databaseInstanceID: work.databaseInstanceID,
                    kind: work.kind,
                    schemaVersion: projectionSchemaVersion,
                    failure: nil,
                    validatedThrough: nil,
                    publishesClosedFrontier: false)
            }
        }
    }

    /// Preserve a failed job and make lag visible. Retrying later is idempotent because the
    /// projection's entity transaction and this acknowledgement are deliberately separate.
    func failProjectionWork(
        _ work: ShadowLibraryProjectionWorkItem,
        projectionSchemaVersion: Int,
        diagnostics: String
    ) throws {
        try queue.sync {
            let metadata = try readAuthorityMetadata()
            guard metadata.databaseInstanceID == work.databaseInstanceID else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "projection failure names a foreign database instance")
            }
            try transaction(tracksMutation: false, requiresShadow: false) {
                try execute(
                    """
                    UPDATE projection_outbox
                    SET last_error = ?1
                    WHERE database_instance_id = ?2 AND projection_kind = ?3
                      AND entity_id = ?4
                    """,
                    [
                        .text(diagnostics), .text(work.databaseInstanceID.uuidString),
                        .text(work.kind.rawValue), .text(work.entityID.uuidString),
                    ])
                try updateProjectionStateFromBacklog(
                    databaseInstanceID: work.databaseInstanceID,
                    kind: work.kind,
                    schemaVersion: projectionSchemaVersion,
                    failure: diagnostics,
                    validatedThrough: nil,
                    publishesClosedFrontier: false)
            }
        }
    }

    /// Record a catch-up failure that is not attributable to one entity transaction (for example,
    /// snapshot reconstruction or closed-set finalization). The cache remains disposable, but Gate
    /// L and Storage Status must not inherit a stale `projecting` receipt after the worker stops.
    func failProjectionCatchUp(
        kind: ShadowLibraryProjectionWorkItem.Kind = .conversationSearch,
        projectionSchemaVersion: Int,
        diagnostics: String
    ) throws {
        try queue.sync {
            let metadata = try readAuthorityMetadata()
            try transaction(tracksMutation: false, requiresShadow: false) {
                try updateProjectionState(
                    databaseInstanceID: metadata.databaseInstanceID,
                    kind: kind,
                    schemaVersion: projectionSchemaVersion,
                    health: "failed",
                    lastError: diagnostics)
            }
        }
    }

    /// Adopt a pre-A2b2 projection only after its caller independently proved the complete row set,
    /// every persisted summary field, and every exact source-generation receipt against the same
    /// launch bundle. Newer coalesced work is retained.
    func acknowledgeExactProjectionSnapshot(
        databaseInstanceID: UUID,
        through shadowChangeSequence: Int64,
        projectionSchemaVersion: Int
    ) throws {
        try queue.sync {
            let metadata = try readAuthorityMetadata()
            let currentSequence = try currentShadowChangeSequence()
            guard metadata.databaseInstanceID == databaseInstanceID,
                  shadowChangeSequence >= 0,
                  shadowChangeSequence <= currentSequence else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "exact projection snapshot does not match the current shadow frontier")
            }
            try transaction(tracksMutation: false, requiresShadow: false) {
                try execute(
                    """
                    DELETE FROM projection_outbox
                    WHERE database_instance_id = ?1 AND projection_kind = ?2
                      AND desired_sequence <= ?3
                    """,
                    [
                        .text(databaseInstanceID.uuidString),
                        .text(ShadowLibraryProjectionWorkItem.Kind.conversationSearch.rawValue),
                        .int(shadowChangeSequence),
                    ])
                try updateProjectionStateFromBacklog(
                    databaseInstanceID: databaseInstanceID,
                    kind: .conversationSearch,
                    schemaVersion: projectionSchemaVersion,
                    failure: nil,
                    validatedThrough: shadowChangeSequence,
                    publishesClosedFrontier: true)
            }
        }
    }

    /// Called only after `nextProjectionWork` returns nil. The projection uses the closed live id set
    /// to delete cache orphans before the high-water is marked current.
    func projectionFrontier(
        kind: ShadowLibraryProjectionWorkItem.Kind = .conversationSearch
    ) throws -> ShadowLibraryProjectionFrontier? {
        try queue.sync {
            let metadata = try readAuthorityMetadata()
            guard try projectionBacklogCount(
                databaseInstanceID: metadata.databaseInstanceID,
                kind: kind) == 0 else { return nil }
            return ShadowLibraryProjectionFrontier(
                databaseInstanceID: metadata.databaseInstanceID,
                shadowChangeSequence: try currentShadowChangeSequence(),
                liveConversationIDs: Set(try readUUIDs(
                    "SELECT id FROM conversations WHERE tombstoned = 0")))
        }
    }

    func projectionBacklogCount(
        kind: ShadowLibraryProjectionWorkItem.Kind = .conversationSearch
    ) throws -> Int {
        try queue.sync {
            let metadata = try readAuthorityMetadata()
            return try projectionBacklogCount(
                databaseInstanceID: metadata.databaseInstanceID,
                kind: kind)
        }
    }

    /// A prior process may have retired projections.db before the rebuild marker existed. Only a
    /// cache-originated failure is a reason to delete the shared disposable database at launch;
    /// authority/reconstruction failures remain visible for diagnosis and must not destroy usable
    /// Conversation or Memory projections.
    func conversationProjectionCacheRequiresRebuild(
        kind: ShadowLibraryProjectionWorkItem.Kind = .conversationSearch
    ) throws -> Bool {
        try queue.sync {
            let metadata = try readAuthorityMetadata()
            var health: String?
            var diagnostics: String?
            try query(
                """
                SELECT health, last_error
                FROM projection_state
                WHERE database_instance_id = ?1 AND projection_kind = ?2
                """,
                [.text(metadata.databaseInstanceID.uuidString), .text(kind.rawValue)]) {
                    health = Self.optionalText($0, 0)
                    diagnostics = Self.optionalText($0, 1)
                }
            return health == "failed"
                && diagnostics?.hasPrefix("projections.db") == true
        }
    }

    /// Read the prior shadow's complete lightweight launch inventory without beginning a new
    /// reconcile. Only the dedicated read-only opener may call this path. All rows come from one
    /// deferred transaction; the coordinator still has to prove the independent filesystem census
    /// and every lstat generation before any value becomes a product read.
    func launchInventoryBundle() throws -> ShadowLibraryLaunchInventoryStoreBundle {
        guard isReadOnly else {
            throw SQLiteLibraryStoreError.invalidInput(
                "launch inventory requires the verified read-only shadow opener")
        }
        return try queue.sync { try readLaunchInventoryBundle(
            requiredState: .shadow, activationID: nil) }
    }

    /// SQLite-authority launch reads the relational inventory directly. No filesystem census or
    /// Legacy generation comparison participates after the root marker commits authority.
    func authoritativeLaunchInventoryBundle(
        activationID: UUID
    ) throws -> ShadowLibraryLaunchInventoryStoreBundle {
        guard !isReadOnly, activeActivationID == activationID else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "authoritative launch inventory requires the matching active opener")
        }
        return try queue.sync { try readLaunchInventoryBundle(
            requiredState: .active, activationID: activationID) }
    }

    /// The sidebar's summaries on their own. Spotlight and the App Intents entity queries need
    /// exactly these display facts and nothing else; taking the whole launch bundle to get them
    /// would reconstruct every Workspace, Artifact and resident record to answer a Siri lookup.
    func authoritativeConversationSummaries(
        activationID: UUID
    ) throws -> [ConversationSummary] {
        guard !isReadOnly, activeActivationID == activationID else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "authoritative Conversation summaries require the matching active opener")
        }
        return try queue.sync {
            try readTransaction { try readLaunchConversationRows().map(\.summary) }
        }
    }

    private func readLaunchInventoryBundle(
        requiredState: LibraryAuthorityState,
        activationID: UUID?
    ) throws -> ShadowLibraryLaunchInventoryStoreBundle {
        try readTransaction {
                let metadata = try readAuthorityMetadata()
                guard metadata.schemaVersion == Self.schemaVersion,
                      metadata.authorityState == requiredState,
                      metadata.activationID == activationID else {
                    throw SQLiteLibraryStoreError.protectedDatabase(
                        "launch inventory authority generation changed")
                }
                let shadowChangeSequence = try scalarInt(
                    "SELECT shadow_change_sequence FROM library_metadata WHERE singleton = 1")
                guard let home = try readWorkspaceSnapshot(id: Self.homeWorkspaceID),
                      home.kind == .home, !home.tombstoned else {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "launch inventory has no live Home Workspace")
                }
                var workspaces: [ShadowLibraryWorkspaceSnapshot] = []
                var workspaceIDs: [UUID] = []
                try query(
                    "SELECT id FROM workspaces WHERE kind = 'named' AND tombstoned = 0 ORDER BY id",
                    []) { statement in
                        guard let raw = Self.optionalText(statement, 0),
                              let id = UUID(uuidString: raw) else {
                            throw SQLiteLibraryStoreError.sqlite(
                                "launch Workspace identity is malformed")
                        }
                        workspaceIDs.append(id)
                    }
                workspaces.reserveCapacity(workspaceIDs.count)
                for id in workspaceIDs {
                    guard let workspace = try readWorkspaceSnapshot(id: id),
                          workspace.kind == .named, !workspace.tombstoned else {
                        throw SQLiteLibraryStoreError.sqlite(
                            "launch Workspace row disappeared during its SQLite snapshot")
                    }
                    workspaces.append(workspace)
                }

                let rows = try readLaunchConversationRows()
                var intrinsicConversations: [Conversation] = []
                intrinsicConversations.reserveCapacity(
                    rows.lazy.filter(\.requiresIntrinsicResidency).count)
                for row in rows where row.requiresIntrinsicResidency {
                    guard let readBundle = try readValidatedConversationBundle(
                        id: row.summary.id) else {
                        throw SQLiteLibraryStoreError.sqlite(
                            "intrinsic Conversation disappeared during its SQLite snapshot")
                    }
                    do {
                        intrinsicConversations.append(
                            try LibraryConversationAdapter.reconstruct(
                                from: readBundle.conversation))
                    } catch {
                        throw SQLiteLibraryStoreError.invalidInput(
                            "intrinsic Conversation \(row.summary.id.uuidString) could not reconstruct: \(error.localizedDescription)")
                    }
                }
                return ShadowLibraryLaunchInventoryStoreBundle(
                    databaseInstanceID: metadata.databaseInstanceID,
                    shadowChangeSequence: shadowChangeSequence,
                    home: home,
                    workspaces: workspaces,
                    conversations: rows,
                    intrinsicConversations: intrinsicConversations)
        }
    }

    /// Enumerate only lossless Conversation rows whose currently bound source is a preserved
    /// `.json.corrupt-*` sidecar. The query requires both its Conversation and operative-state
    /// receipts to remain current against the same exact source generation.
    func recoveredConversationBindings() throws -> [ShadowLibraryRecoveredConversationBinding] {
        try queue.sync {
            var results: [ShadowLibraryRecoveredConversationBinding] = []
            try query(
                """
                SELECT conversation.id, conversation.title, conversation.updated_at,
                       source.source_identity, source.observed_revision,
                       source.observed_digest, source.source_byte_count
                FROM conversations conversation
                JOIN migration_sources source
                  ON source.domain = 'conversations'
                 AND source.source_identity = conversation.source_identity
                 AND source.entity_id = conversation.id
                JOIN migration_sources operative
                  ON operative.domain = 'operative_state'
                 AND operative.source_identity = source.source_identity
                 AND operative.entity_id = conversation.id
                WHERE source.dirty = 0 AND source.import_state = 'current'
                  AND source.observed_digest = source.imported_digest
                  AND operative.dirty = 0 AND operative.import_state = 'current'
                  AND operative.observed_digest = operative.imported_digest
                  AND source.source_identity LIKE '%.json.corrupt-%'
                ORDER BY conversation.updated_at DESC, conversation.id
                """,
                []) { statement in
                guard let rawID = Self.optionalText(statement, 0),
                      let id = UUID(uuidString: rawID),
                      let title = Self.optionalText(statement, 1),
                      let identity = Self.optionalText(statement, 3),
                      let revision = Self.optionalText(statement, 4),
                      let digest = Self.optionalText(statement, 5),
                      identity.contains(".json.corrupt-") else {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "recovered Conversation binding is malformed")
                }
                let source = ShadowLibrarySourceFingerprint(
                    identity: identity,
                    revision: revision,
                    digest: digest,
                    byteCount: Int(sqlite3_column_int64(statement, 6)))
                try validate(source: source)
                results.append(ShadowLibraryRecoveredConversationBinding(
                    id: id,
                    title: title,
                    updatedAt: Date(
                        timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2)),
                    source: source))
            }
            return results
        }
    }

    func artifactSnapshot(id: UUID) throws -> ShadowLibraryArtifactSnapshot? {
        try queue.sync { try readArtifactSnapshot(id: id) }
    }

    // MARK: - Active SQLite authority

    func authoritativeWorkspaceSnapshot(
        id: UUID,
        activationID: UUID
    ) throws -> ShadowLibraryWorkspaceSnapshot? {
        try queue.sync {
            try requireActiveAuthority(activationID)
            return try readWorkspaceSnapshot(id: id)
        }
    }

    func authoritativeWorkspaceSnapshots(
        activationID: UUID
    ) throws -> (home: ShadowLibraryWorkspaceSnapshot, named: [ShadowLibraryWorkspaceSnapshot]) {
        try queue.sync {
            try requireActiveAuthority(activationID)
            guard let home = try readWorkspaceSnapshot(id: Self.homeWorkspaceID),
                  home.kind == .home, !home.tombstoned else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "authoritative Home Workspace is absent")
            }
            let named = try readUUIDs(
                "SELECT id FROM workspaces WHERE kind = 'named' AND tombstoned = 0 ORDER BY id")
                .compactMap { try readWorkspaceSnapshot(id: $0) }
            return (home, named)
        }
    }

    func authoritativeConversationSnapshot(
        id: UUID,
        activationID: UUID,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> ShadowLibraryConversationSnapshot? {
        try queue.sync {
            guard !isCancelled() else { throw CancellationError() }
#if DEBUG
            conversationSnapshotQueueTestHook?(id)
#endif
            // Waiting for the serialized primary queue is cancellable at admission. This is what
            // lets a selected interactive replacement abandon an obsolete background snapshot
            // before it begins reconstructing the same record.
            guard !isCancelled() else { throw CancellationError() }
            // A complete Conversation spans multiple queries. Primary reads were already
            // serialized by this queue, but the interactive read-only WAL connection can run
            // alongside a writer, so pin one snapshot before reconstructing its event/artifact
            // rows. A selected record may never combine metadata from one commit with events from
            // another.
            return try readTransaction {
                guard !isCancelled() else { throw CancellationError() }
                try requireActiveAuthority(activationID)
                let snapshot = try readConversationSnapshot(id: id)
                guard !isCancelled() else { throw CancellationError() }
                return snapshot
            }
        }
    }



    /// Cheap broad freshness fence for an already-built local authority snapshot.
    func authoritativeSnapshotGeneration(
        activationID: UUID
    ) throws -> LibraryAuthoritySnapshotGeneration {
        try queue.sync {
            try readTransaction {
                try requireActiveAuthority(activationID)
                let metadata = try readAuthorityMetadata()
                return LibraryAuthoritySnapshotGeneration(
                    databaseInstanceID: metadata.databaseInstanceID,
                    committedSequence: metadata.committedSequence)
            }
        }
    }

    /// The newest `limit` transcript entries for one Conversation, oldest-first.
    ///
    /// Reconstructing a Conversation to paint it costs what the whole record costs: the largest
    /// live record is 9,421 transcript events of which 8,349 are tool entries totalling 104 MB, and
    /// decoding all of it takes about 1.2 s before anything reaches the screen. The last hundred
    /// entries are 123 KB and read in about 1.4 ms.
    ///
    /// This deliberately carries `[TranscriptEntry]` rather than a Conversation. A truncated
    /// Conversation value could reach a save path and destroy a transcript; a plain array of
    /// entries has nowhere to be persisted back to.
    func authoritativeRecentTranscriptRead(
        id: UUID,
        limit: Int,
        activationID: UUID,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> LibraryRecentTranscriptReadResult {
        guard !isCancelled() else { throw CancellationError() }
        guard limit > 0 else {
            return LibraryRecentTranscriptReadResult(
                entries: [],
                timing: LibraryRecentTranscriptReadTiming(
                    queueWaitSeconds: 0,
                    readSeconds: 0))
        }

        let enqueuedAt = DispatchTime.now().uptimeNanoseconds
        return try queue.sync {
            let readStartedAt = DispatchTime.now().uptimeNanoseconds
            guard !isCancelled() else { throw CancellationError() }
            let entries = try readTransaction {
                try requireActiveAuthority(activationID)
                var newestFirst: [(sequence: Int64, entry: TranscriptEntry)] = []
                newestFirst.reserveCapacity(limit)
                let decoder = ConversationStore.makeDecoder()
                try query(
                    """
                    SELECT id, kind, capture_sequence, payload_version, payload
                    FROM conversation_events
                    WHERE conversation_id = ? AND kind LIKE 'transcript.%'
                    ORDER BY capture_sequence DESC
                    LIMIT ?
                    """,
                    [.text(id.uuidString), .int(Int64(limit))]) { statement in
                        guard !isCancelled() else { throw CancellationError() }
                        guard let rawID = Self.optionalText(statement, 0),
                              let entryID = UUID(uuidString: rawID),
                              let kind = Self.optionalText(statement, 1),
                              sqlite3_column_int64(statement, 3) == 1 else {
                            throw SQLiteLibraryStoreError.invalidInput(
                                "recent transcript row is malformed")
                        }
                        let entry: TranscriptEntry
                        do {
                            entry = try decoder.decode(
                                TranscriptEntry.self, from: Self.data(statement, 4))
                        } catch {
                            throw SQLiteLibraryStoreError.invalidInput(
                                "recent transcript row could not decode: \(error.localizedDescription)")
                        }
                        // The same identity/kind agreement the full reconstruction enforces. A
                        // preview that disagreed with the record would be worse than no preview.
                        guard entry.id == entryID,
                              kind == "transcript.\(entry.kind.rawValue)" else {
                            throw SQLiteLibraryStoreError.invalidInput(
                                "recent transcript row identity/kind does not match its payload")
                        }
                        newestFirst.append(
                            (sqlite3_column_int64(statement, 2), entry))
#if DEBUG
                        recentTranscriptRowTestHook?()
#endif
                    }
                return newestFirst.sorted { $0.sequence < $1.sequence }.map(\.entry)
            }
            guard !isCancelled() else { throw CancellationError() }
            let readFinishedAt = DispatchTime.now().uptimeNanoseconds
            func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
                guard end >= start else { return 0 }
                return TimeInterval(end - start) / 1_000_000_000
            }
            return LibraryRecentTranscriptReadResult(
                entries: entries,
                timing: LibraryRecentTranscriptReadTiming(
                    queueWaitSeconds: seconds(from: enqueuedAt, to: readStartedAt),
                    readSeconds: seconds(from: readStartedAt, to: readFinishedAt)))
        }
    }

    func authoritativeRecentTranscript(
        id: UUID,
        limit: Int,
        activationID: UUID
    ) throws -> [TranscriptEntry] {
        try authoritativeRecentTranscriptRead(
            id: id,
            limit: limit,
            activationID: activationID).entries
    }

#if DEBUG
    func setConversationSnapshotQueueTestHook(
        _ hook: (@Sendable (UUID) -> Void)?
    ) {
        queue.sync {
            conversationSnapshotQueueTestHook = hook
        }
    }

    func setRecentTranscriptRowTestHook(
        _ hook: (@Sendable () -> Void)?
    ) {
        queue.sync {
            recentTranscriptRowTestHook = hook
        }
    }
#endif





    /// Lightweight source receipt for an active mutation. This deliberately avoids loading any
    /// event payload merely to preserve the migrated record-size estimate and source identity.
    func authoritativeConversationSource(
        id: UUID,
        activationID: UUID
    ) throws -> ShadowLibrarySourceFingerprint? {
        try queue.sync {
            try requireActiveAuthority(activationID)
            var sourceIdentity: String?
            try query("SELECT source_identity FROM conversations WHERE id = ?1", [
                .text(id.uuidString),
            ]) { sourceIdentity = Self.optionalText($0, 0) }
            guard let sourceIdentity else { return nil }
            return try readCurrentSourceFingerprint(
                domain: .conversations,
                sourceIdentity: sourceIdentity,
                entityID: id,
                requiresOperativeState: true)
        }
    }

    func authoritativeArtifactSnapshot(
        id: UUID,
        activationID: UUID
    ) throws -> ShadowLibraryArtifactSnapshot? {
        try queue.sync {
            try requireActiveAuthority(activationID)
            return try readArtifactSnapshot(id: id)
        }
    }

    func authoritativeArtifactSnapshots(
        activationID: UUID
    ) throws -> [ShadowLibraryArtifactSnapshot] {
        try queue.sync {
            try requireActiveAuthority(activationID)
            return try readUUIDs("SELECT id FROM artifacts WHERE tombstoned = 0 ORDER BY id")
                .compactMap { try readArtifactSnapshot(id: $0) }
        }
    }

    func authoritativeAmbientSnapshots(
        activationID: UUID
    ) throws -> [ShadowLibraryAmbientSnapshot] {
        try queue.sync {
            try requireActiveAuthority(activationID)
            return try readAmbientSnapshots()
        }
    }

    func authoritativeConversationWorkEvidence(
        repositoryID: String,
        activationID: UUID
    ) throws -> [ConversationWorkEvidence] {
        try queue.sync {
            try requireActiveAuthority(activationID)
            return try readConversationWorkEvidence(repositoryID: repositoryID)
        }
    }

    func authoritativeConversationWorkEvidence(
        conversationID: UUID,
        activationID: UUID
    ) throws -> [ConversationWorkEvidence] {
        try queue.sync {
            try requireActiveAuthority(activationID)
            return try readConversationWorkEvidence(conversationID: conversationID)
        }
    }

    /// Append one exact repository boundary and its file receipts in the same authority commit.
    /// Replaying byte-for-byte equal identities is a no-op; reusing an identity for different
    /// facts fails closed instead of replacing earlier evidence.
    @discardableResult
    func commitAuthoritativeConversationWorkEvidence(
        repository: ConversationRepositoryObservation,
        files: [ConversationFileObservation],
        activationID: UUID
    ) throws -> Int64 {
        try validateConversationWorkEvidence(repository: repository, files: files)
        return try queue.sync {
            try requireActiveAuthority(activationID)
            let existingRepository = try readConversationRepositoryObservation(id: repository.id)
            if let existingRepository, existingRepository != repository {
                throw SQLiteLibraryStoreError.invalidInput(
                    "repository observation identity collides with different facts")
            }
            var missingFiles: [ConversationFileObservation] = []
            for file in files {
                if let existing = try readConversationFileObservation(id: file.id) {
                    guard existing == file else {
                        throw SQLiteLibraryStoreError.invalidInput(
                            "file observation identity collides with different facts")
                    }
                } else {
                    missingFiles.append(file)
                }
            }
            guard existingRepository == nil || !missingFiles.isEmpty else {
                return try readAuthorityMetadata().committedSequence
            }
            return try authoritativeTransaction(activationID: activationID) {
                if existingRepository == nil {
                    try insertConversationRepositoryObservation(repository)
                }
                for file in missingFiles {
                    try insertConversationFileObservation(file)
                }
            }
        }
    }

    @discardableResult
    func commitAuthoritative(
        conversation: ShadowLibraryConversationSnapshot,
        activationID: UUID
    ) throws -> Int64 {
        try validate(conversation: conversation)
        return try queue.sync {
            try authoritativeTransaction(activationID: activationID) {
                try upsertAuthoritativeConversation(conversation)
                try forceConversationSearchReindex(conversation.id)
            }
        }
    }

    @discardableResult
    func commitAuthoritativeMutation(
        conversation: ShadowLibraryConversationSnapshot,
        changedTranscriptEntryIDs: Set<UUID>?,
        liveTranscriptOrder: [UUID]? = nil,
        retainedByteMutation: LibraryAuthorityRetainedByteMutation? = nil,
        activationID: UUID
    ) throws -> LibraryAuthorityConversationCommitResult {
        try validateAuthoritativeConversationMutation(
            conversation,
            changedTranscriptEntryIDs: changedTranscriptEntryIDs,
            liveTranscriptOrder: liveTranscriptOrder)
        if let retainedByteMutation {
            try validateAuthoritativeRetainedByteMutation(
                retainedByteMutation,
                conversationID: conversation.id)
        }
        return try queue.sync {
            // An empty delta no longer implies an unchanged transcript: the live ordering can still
            // retire a row the delta never named, and the retired text must leave the search index
            // with it. The upsert reports whether it moved or removed anything.
            // Titles are projected from `summaries` and never enter `entry_fts`; the ordinary outbox
            // trigger is sufficient for them and must not force a full transcript re-tokenization.
            var searchableContentChanged = changedTranscriptEntryIDs == nil
                || changedTranscriptEntryIDs?.isEmpty == false
            let sequence = try authoritativeTransaction(activationID: activationID) {
                let result = try upsertAuthoritativeConversation(
                    conversation,
                    liveTranscriptOrder: liveTranscriptOrder)
                searchableContentChanged = searchableContentChanged || result.structureChanged
                if let retainedByteMutation {
                    for source in retainedByteMutation.sources {
                        try upsertRetainedByte(source)
                    }
                    try replaceRetainedByteReferencesInternal(
                        ownerConversationID: conversation.id,
                        references: retainedByteMutation.references)
                }
                if searchableContentChanged {
                    try forceConversationSearchReindex(conversation.id)
                }
            }
            return LibraryAuthorityConversationCommitResult(
                committedSequence: sequence,
                searchableContentChanged: searchableContentChanged)
        }
    }

    func commitAuthoritative(
        conversation: ShadowLibraryConversationSnapshot,
        operation: ShadowLibraryOperationSnapshot,
        receipt: LibraryOperationReceiptSnapshot,
        activationID: UUID
    ) throws -> LibraryAuthorityAdoptionResult {
        try validate(conversation: conversation)
        try validateAuthoritativeAdoption(
            operation: operation, receipt: receipt,
            conversationID: conversation.id, artifactID: nil)
        return try queue.sync {
            if let existing = try readConversationSnapshot(id: conversation.id) {
                guard authoritativeConversationContentMatches(existing, conversation) else {
                    return LibraryAuthorityAdoptionResult(
                        disposition: .identityCollision,
                        committedSequence: try readAuthorityMetadata().committedSequence)
                }
                let sequence = try authoritativeTransaction(activationID: activationID) {
                    try upsertOperation(operation)
                    try upsertOperationReceiptIdempotently(receipt)
                }
                return LibraryAuthorityAdoptionResult(
                    disposition: .alreadyApplied, committedSequence: sequence)
            }
            let sequence = try authoritativeTransaction(activationID: activationID) {
                try upsertAuthoritativeConversation(conversation)
                try forceConversationSearchReindex(conversation.id)
                try upsertOperation(operation)
                try upsertOperationReceiptIdempotently(receipt)
            }
            return LibraryAuthorityAdoptionResult(
                disposition: .created, committedSequence: sequence)
        }
    }

    @discardableResult
    func commitAuthoritative(
        workspace: ShadowLibraryWorkspaceSnapshot,
        activationID: UUID
    ) throws -> Int64 {
        try commitAuthoritativeWorkspaceMutation(
            workspace: workspace,
            activationID: activationID)
    }

    func commitAuthoritativeWorkspaceMutation(
        workspace: ShadowLibraryWorkspaceSnapshot,
        activationID: UUID
    ) throws -> Int64 {
        try validate(workspace: workspace)
        return try queue.sync {
            try authoritativeTransaction(activationID: activationID) {
                try upsertWorkspace(workspace)
            }
        }
    }

    @discardableResult
    func commitAuthoritative(
        artifact: ShadowLibraryArtifactSnapshot,
        activationID: UUID
    ) throws -> Int64 {
        try validate(artifact: artifact)
        return try queue.sync {
            try authoritativeTransaction(activationID: activationID) {
                try upsertArtifact(artifact)
            }
        }
    }

    @discardableResult
    func commitAuthoritative(
        artifact: ShadowLibraryArtifactSnapshot,
        operation: ShadowLibraryOperationSnapshot,
        receipt: LibraryOperationReceiptSnapshot,
        activationID: UUID
    ) throws -> Int64 {
        try validate(artifact: artifact)
        try validateAuthoritativeOperation(
            operation: operation, receipt: receipt,
            expectedArtifactID: artifact.id)
        return try queue.sync {
            try authoritativeTransaction(activationID: activationID) {
                try upsertArtifact(artifact)
                try upsertOperation(operation)
                try upsertOperationReceiptIdempotently(receipt)
            }
        }
    }

    /// Records already-published product operation facts in SQLite authority. Entity mutations
    /// should use the entity-specific overloads when they can share this transaction; this batch
    /// seam exists for multi-entity moves whose current UI mutation has already crossed each
    /// entity's commit boundary.
    @discardableResult
    func commitAuthoritativeOperations(
        _ captures: [(operation: ShadowLibraryOperationSnapshot,
                      receipt: LibraryOperationReceiptSnapshot)],
        activationID: UUID
    ) throws -> Int64 {
        guard !captures.isEmpty else {
            return try queue.sync {
                try requireActiveAuthority(activationID)
                return try readAuthorityMetadata().committedSequence
            }
        }
        for capture in captures {
            try validateAuthoritativeOperation(
                operation: capture.operation, receipt: capture.receipt)
        }
        return try queue.sync {
            try authoritativeTransaction(activationID: activationID) {
                for capture in captures {
                    try upsertOperation(capture.operation)
                    try upsertOperationReceiptIdempotently(capture.receipt)
                }
            }
        }
    }

    func adoptAuthoritativeBackgroundArtifact(
        candidate: Artifact,
        producerTaskID: String,
        source: ShadowLibrarySourceFingerprint,
        operation: ShadowLibraryOperationSnapshot,
        receipt: LibraryOperationReceiptSnapshot,
        activationID: UUID
    ) throws -> LibraryAuthorityArtifactAdoptionResult {
        guard !producerTaskID.isEmpty else {
            throw SQLiteLibraryStoreError.invalidInput(
                "background Artifact producer task identity is empty")
        }
        try validate(source: source)
        try validateAuthoritativeAdoption(
            operation: operation, receipt: receipt,
            conversationID: nil, artifactID: candidate.uuid)
        return try queue.sync {
            let priorSnapshot = try readArtifactSnapshot(id: candidate.uuid)
            let prior = try priorSnapshot.map(LibraryArtifactAdapter.reconstruct)
            let metadata = try readAuthorityMetadata()
            if let prior, let priorSnapshot {
                let taskMatches = priorSnapshot.producerTaskID == nil
                    || priorSnapshot.producerTaskID == producerTaskID
                if taskMatches, authoritativeBackgroundArtifactRevisionMatches(
                    prior, candidate) {
                    let sequence = try authoritativeTransaction(activationID: activationID) {
                        try upsertOperation(operation)
                        try upsertOperationReceiptIdempotently(receipt)
                    }
                    return LibraryAuthorityArtifactAdoptionResult(
                        disposition: .alreadyApplied,
                        artifact: prior,
                        committedSequence: sequence)
                }
                guard taskMatches,
                      prior.origin == "ambient", candidate.origin == "ambient",
                      prior.uuid == candidate.uuid,
                      prior.createdAt == candidate.createdAt,
                      prior.revisions < Int.max,
                      candidate.revisions == prior.revisions + 1,
                      candidate.updatedAt >= prior.updatedAt else {
                    return LibraryAuthorityArtifactAdoptionResult(
                        disposition: .identityCollision,
                        artifact: prior,
                        committedSequence: metadata.committedSequence)
                }
                var normalized = candidate
                normalized.title = prior.title
                normalized.favorite = prior.favorite
                normalized.workspaceID = prior.workspaceID
                normalized.cwd = prior.cwd
                let snapshot = try LibraryArtifactAdapter.capture(
                    normalized,
                    source: source,
                    preserving: priorSnapshot,
                    producerTaskID: producerTaskID)
                try validate(artifact: snapshot)
                let sequence = try authoritativeTransaction(activationID: activationID) {
                    try upsertArtifact(snapshot)
                    try upsertOperation(operation)
                    try upsertOperationReceiptIdempotently(receipt)
                }
                return LibraryAuthorityArtifactAdoptionResult(
                    disposition: .created,
                    artifact: normalized,
                    committedSequence: sequence)
            }

            let snapshot = try LibraryArtifactAdapter.capture(
                candidate,
                source: source,
                preserving: nil,
                producerTaskID: producerTaskID)
            try validate(artifact: snapshot)
            let sequence = try authoritativeTransaction(activationID: activationID) {
                try upsertArtifact(snapshot)
                try upsertOperation(operation)
                try upsertOperationReceiptIdempotently(receipt)
            }
            return LibraryAuthorityArtifactAdoptionResult(
                disposition: .created,
                artifact: candidate,
                committedSequence: sequence)
        }
    }

    @discardableResult
    func replaceAuthoritativeAmbient(
        _ snapshots: [ShadowLibraryAmbientSnapshot],
        activationID: UUID
    ) throws -> Int64 {
        for snapshot in snapshots { try validate(ambient: snapshot) }
        guard Set(snapshots.map(\.kind)).count == snapshots.count else {
            throw SQLiteLibraryStoreError.invalidInput(
                "authoritative Ambient snapshot contains duplicate kinds")
        }
        return try queue.sync {
            try authoritativeTransaction(activationID: activationID) {
                let live = Set(snapshots.map(\.source.identity))
                for snapshot in snapshots { try upsertAmbient(snapshot) }
                var stale: [String] = []
                try query(
                    "SELECT source_identity FROM migration_sources WHERE domain = 'ambient_state'",
                    []) { statement in
                        if let identity = Self.optionalText(statement, 0), !live.contains(identity) {
                            stale.append(identity)
                        }
                    }
                for identity in stale {
                    try execute(
                        "DELETE FROM ambient_authority_sources WHERE source_identity = ?1",
                        [.text(identity)])
                    try execute(
                        "DELETE FROM migration_sources WHERE domain = 'ambient_state' AND source_identity = ?1",
                        [.text(identity)])
                }
                try markFullCensus(domain: .ambientState, expected: snapshots.count)
            }
        }
    }

    @discardableResult
    func deleteAuthoritativeConversation(
        id: UUID,
        activationID: UUID
    ) throws -> Int64 {
        try queue.sync {
            try authoritativeTransaction(activationID: activationID) {
                try deleteAuthoritativeConversationRows(id: id)
            }
        }
    }

    /// Close one reversible delete over the evidence snapshot and its cascading Conversation row.
    /// Reading inside the same transaction prevents another authority mutation from landing between
    /// the undo receipt and the delete. The permanent-delete path above intentionally never reads or
    /// returns these privacy-scoped facts.
    func deleteAuthoritativeConversationForUndo(
        id: UUID,
        activationID: UUID
    ) throws -> LibraryAuthorityConversationDeleteResult {
        try queue.sync {
            var workEvidence: [ConversationWorkEvidence] = []
            let sequence = try authoritativeTransaction(activationID: activationID) {
                workEvidence = try readConversationWorkEvidence(conversationID: id)
                try deleteAuthoritativeConversationRows(id: id)
            }
            return LibraryAuthorityConversationDeleteResult(
                committedSequence: sequence,
                workEvidence: workEvidence)
        }
    }

    /// Delete the Conversation and release its media rows rather than demoting them.
    ///
    /// This used to set the rows to `reference_pending` and then delete the only Conversation that
    /// could ever claim them, in the same transaction. Nothing re-evaluates a pending row whose
    /// owner is gone, and `LibraryBackupService.readRetainedBytes` refuses the entire backup while
    /// one exists. `retained_byte_references` cascades on the source, and the files are moved by the
    /// trash. `conversation_trash_media` is deliberately excluded because those rows carry Undo.
    private func deleteAuthoritativeConversationRows(id: UUID) throws {
        try execute(
            """
            DELETE FROM retained_byte_sources
            WHERE owner_conversation_id = ?1 AND kind = 'conversation_media'
              AND storage_class = 'legacy_layout'
            """,
            [.text(id.uuidString)])
        try execute("DELETE FROM conversations WHERE id = ?1", [.text(id.uuidString)])
        try execute(
            "DELETE FROM migration_sources WHERE domain IN ('conversations', 'operative_state') AND entity_id = ?1",
            [.text(id.uuidString)])
    }

    /// Release retained-byte sources whose owning Conversation no longer exists.
    ///
    /// The repair half of the fix above. A row at `reference_pending` whose `owner_conversation_id`
    /// names no Conversation is unreachable by construction: the only thing that could reference it
    /// is gone, so no future work can resolve it and it will refuse every backup forever.
    ///
    /// Deliberately narrow. It does NOT touch a pending row with a live owner — that one is
    /// ordinary in-flight state and resolving it is the census's job, not a repair's.
    @discardableResult
    func releaseOrphanedRetainedByteSources(activationID: UUID) throws -> Int {
        try queue.sync {
            var released = 0
            _ = try authoritativeTransaction(activationID: activationID) {
                var orphans: [String] = []
                try query(
                    """
                    SELECT source_identity FROM retained_byte_sources
                    WHERE disposition = 'reference_pending'
                      AND owner_conversation_id IS NOT NULL
                      AND owner_conversation_id NOT IN (SELECT id FROM conversations)
                    """,
                    []) { if let identity = Self.optionalText($0, 0) { orphans.append(identity) } }
                for identity in orphans {
                    try execute(
                        "DELETE FROM retained_byte_sources WHERE source_identity = ?1",
                        [.text(identity)])
                }
                released = orphans.count
            }
            return released
        }
    }

    @discardableResult
    func deleteAuthoritativeWorkspace(
        id: UUID,
        activationID: UUID
    ) throws -> Int64 {
        guard id != Self.homeWorkspaceID else {
            throw SQLiteLibraryStoreError.invalidInput(
                "the reserved Home Workspace cannot be deleted")
        }
        return try queue.sync {
            try authoritativeTransaction(activationID: activationID) {
                var sourceIdentity: String?
                try query("SELECT source_identity FROM workspaces WHERE id = ?1", [
                    .text(id.uuidString),
                ]) { sourceIdentity = Self.optionalText($0, 0) }
                if try workspaceReferenceCount(id) > 0 {
                    try convertToUnresolvedWorkspace(
                        id, staleSourceIdentity: sourceIdentity ?? "workspaces/\(id.uuidString).json")
                } else {
                    try execute("DELETE FROM workspaces WHERE id = ?1", [.text(id.uuidString)])
                    try execute(
                        "DELETE FROM migration_sources WHERE domain = 'workspaces' AND entity_id = ?1",
                        [.text(id.uuidString)])
                }
            }
        }
    }

    @discardableResult
    func deleteAuthoritativeArtifact(
        id: UUID,
        activationID: UUID
    ) throws -> Int64 {
        try queue.sync {
            try authoritativeTransaction(activationID: activationID) {
                try execute("DELETE FROM artifacts WHERE id = ?1", [.text(id.uuidString)])
                try execute(
                    "DELETE FROM migration_sources WHERE domain = 'artifact_media' AND entity_id = ?1",
                    [.text(id.uuidString)])
                try removeOrphanUnresolvedWorkspaces()
            }
        }
    }

    @discardableResult
    func deleteAuthoritativeArtifact(
        id: UUID,
        operation: ShadowLibraryOperationSnapshot,
        receipt: LibraryOperationReceiptSnapshot,
        activationID: UUID
    ) throws -> Int64 {
        try validateAuthoritativeOperation(
            operation: operation, receipt: receipt,
            expectedArtifactID: id, requiresArtifactDelete: true)
        return try queue.sync {
            try authoritativeTransaction(activationID: activationID) {
                try execute("DELETE FROM artifacts WHERE id = ?1", [.text(id.uuidString)])
                try execute(
                    "DELETE FROM migration_sources WHERE domain = 'artifact_media' AND entity_id = ?1",
                    [.text(id.uuidString)])
                try removeOrphanUnresolvedWorkspaces()
                try upsertOperation(operation)
                try upsertOperationReceiptIdempotently(receipt)
            }
        }
    }

    func retainedByteInventory() throws -> [ShadowLibraryRetainedByteSnapshot] {
        try queue.sync { try readRetainedByteInventory() }
    }

    func replaceRetainedByteReferences(
        ownerConversationID: UUID,
        references: [ShadowLibraryRetainedByteReferenceSnapshot]
    ) throws {
        try validateRetainedByteReferences(
            ownerConversationID: ownerConversationID,
            references: references)
        try queue.sync {
            try transaction { try replaceRetainedByteReferencesInternal(
                ownerConversationID: ownerConversationID,
                references: references) }
        }
    }

    /// Replaces one Conversation's complete retained-byte edge set and updates the operative-state
    /// receipt in the same transaction. A non-nil diagnosis deliberately blocks readiness while
    /// preserving every successfully matched edge and adopted byte.
    @discardableResult
    func reconcileRetainedByteReferences(
        ownerConversationID: UUID,
        conversationSourceIdentity: String,
        references: [ShadowLibraryRetainedByteReferenceSnapshot],
        readiness: ShadowLibraryRetainedByteReadinessFinding?
    ) throws -> ShadowLibraryStatus {
        guard !conversationSourceIdentity.isEmpty else {
            throw SQLiteLibraryStoreError.invalidInput(
                "retained-byte assessment source identity is empty")
        }
        try validateRetainedByteReferences(
            ownerConversationID: ownerConversationID,
            references: references)
        return try queue.sync {
            if try retainedByteReferenceAssessmentIsCurrent(
                ownerConversationID: ownerConversationID,
                conversationSourceIdentity: conversationSourceIdentity,
                references: references,
                readiness: readiness
            ) {
                return try makeStatus()
            }
            try transaction {
                try replaceRetainedByteReferencesInternal(
                    ownerConversationID: ownerConversationID,
                    references: references)
                var ownsCurrentConversation = false
                try query(
                    """
                    SELECT 1 FROM migration_sources
                    WHERE domain = 'conversations' AND source_identity = ?1 AND entity_id = ?2
                      AND dirty = 0 AND import_state = 'current'
                    """,
                    [.text(conversationSourceIdentity), .text(ownerConversationID.uuidString)]) { _ in
                        ownsCurrentConversation = true
                    }
                guard ownsCurrentConversation else {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "retained-byte assessment does not own a current Conversation source")
                }
                if let readiness, readiness.isBlocking {
                    guard !readiness.diagnostics.isEmpty else {
                        throw SQLiteLibraryStoreError.invalidInput(
                            "retained-byte readiness diagnosis is empty")
                    }
                    try execute(
                        """
                        UPDATE migration_sources
                        SET imported_revision = NULL, imported_digest = NULL, dirty = 1,
                            import_state = 'quarantine', diagnostics = ?1, imported_at = NULL
                        WHERE domain = 'operative_state' AND source_identity = ?2
                          AND entity_id = ?3
                        """,
                        [
                            .text(readiness.diagnostics), .text(conversationSourceIdentity),
                            .text(ownerConversationID.uuidString),
                        ])
                } else {
                    // An accounted finding keeps its text on the row. The operative facts are
                    // trustworthy — nothing about them is in question — so the source stays current
                    // and the explanation survives for anyone reading the database later.
                    if let readiness, readiness.diagnostics.isEmpty {
                        throw SQLiteLibraryStoreError.invalidInput(
                            "retained-byte readiness diagnosis is empty")
                    }
                    try execute(
                        """
                        UPDATE migration_sources
                        SET imported_revision = observed_revision, imported_digest = observed_digest,
                            dirty = 0, import_state = 'current', diagnostics = ?4,
                            imported_at = ?1
                        WHERE domain = 'operative_state' AND source_identity = ?2
                          AND entity_id = ?3
                        """,
                        [
                            .double(Date().timeIntervalSinceReferenceDate),
                            .text(conversationSourceIdentity),
                            .text(ownerConversationID.uuidString),
                            readiness.map { SQLiteValue.text($0.diagnostics) } ?? .null,
                        ])
                }
            }
            try applyOwnerOnlyFilePermissions()
            return try makeStatus()
        }
    }

    private func validateAuthoritativeRetainedByteMutation(
        _ mutation: LibraryAuthorityRetainedByteMutation,
        conversationID: UUID
    ) throws {
        try validateRetainedByteReferences(
            ownerConversationID: conversationID,
            references: mutation.references)
        for source in mutation.sources { try validate(retainedByte: source) }
        let sourceIdentities = mutation.sources.map(\.source.identity)
        guard Set(sourceIdentities).count == sourceIdentities.count else {
            throw SQLiteLibraryStoreError.invalidInput(
                "authoritative retained-byte mutation contains duplicate sources")
        }
        let sourcesByIdentity = Dictionary(uniqueKeysWithValues: mutation.sources.map {
            ($0.source.identity, $0)
        })
        let referencedIdentities = Set(mutation.references.map(\.retainedSourceIdentity))
        guard referencedIdentities.isSubset(of: Set(sourceIdentities)) else {
            throw SQLiteLibraryStoreError.invalidInput(
                "authoritative retained-byte mutation references an uninventoried source")
        }
        guard mutation.sources.allSatisfy({ source in
            guard source.kind == .conversationMedia,
                  source.storageClass == .legacyLayout,
                  source.linkState == .current,
                  source.diagnostics == nil,
                  source.retentionState == .live else { return false }
            if referencedIdentities.contains(source.source.identity) {
                return source.ownerConversationID == conversationID
                    && (source.storageState == .adopted
                        || source.storageState == .materialized)
                    && source.disposition == .referenced
            }
            return source.ownerConversationID == nil
                && source.storageState == .observed
                && source.disposition == .unclaimedRecovery
        }) else {
            throw SQLiteLibraryStoreError.invalidInput(
                "authoritative retained-byte mutation has inconsistent ownership state")
        }
        guard mutation.references.allSatisfy({ reference in
            guard let source = sourcesByIdentity[reference.retainedSourceIdentity] else {
                return false
            }
            return source.ownerConversationID == conversationID
        }) else {
            throw SQLiteLibraryStoreError.invalidInput(
                "authoritative retained-byte reference does not name an owned source")
        }
    }

    private func validateRetainedByteReferences(
        ownerConversationID: UUID,
        references: [ShadowLibraryRetainedByteReferenceSnapshot]
    ) throws {
        guard references.allSatisfy({ $0.ownerConversationID == ownerConversationID }) else {
            throw SQLiteLibraryStoreError.invalidInput(
                "retained-byte reference owner does not match replacement owner")
        }
        guard references.allSatisfy({
            !$0.retainedSourceIdentity.isEmpty && !$0.referenceKind.isEmpty
        }) else {
            throw SQLiteLibraryStoreError.invalidInput("retained-byte reference is incomplete")
        }
        guard references.allSatisfy({
            ($0.ownerKind == .event) == ($0.ownerEventID != nil)
        }) else {
            throw SQLiteLibraryStoreError.invalidInput(
                "event retained-byte references require exactly one event id")
        }
        guard Set(references.map(\.id)).count == references.count else {
            throw SQLiteLibraryStoreError.invalidInput(
                "retained-byte reference ids are not unique")
        }
    }

    private func validateConversationReadBundle(
        conversation: ShadowLibraryConversationSnapshot,
        references: [ShadowLibraryRetainedByteReferenceSnapshot],
        retainedSources: [ShadowLibraryRetainedByteSnapshot]
    ) throws {
        try validateRetainedByteReferences(
            ownerConversationID: conversation.id,
            references: references)

        let eventIDs = Set(conversation.events.map(\.id))
        guard references.allSatisfy({ reference in
            reference.ownerEventID.map(eventIDs.contains) ?? true
        }) else {
            throw SQLiteLibraryStoreError.invalidInput(
                "Conversation read bundle contains a reference to another or missing event")
        }

        let referencedIdentities = Set(references.map(\.retainedSourceIdentity))
        let sourceIdentities = Set(retainedSources.map(\.source.identity))
        guard sourceIdentities.count == retainedSources.count else {
            throw SQLiteLibraryStoreError.sqlite(
                "Conversation read bundle contains duplicate retained-source rows")
        }
        guard sourceIdentities == referencedIdentities else {
            throw SQLiteLibraryStoreError.invalidInput(
                "Conversation read bundle reference and retained-source sets disagree")
        }
        guard retainedSources.allSatisfy({ retained in
            retained.ownerConversationID == conversation.id
                && retained.kind == .conversationMedia
                && retained.linkState == .current
                && retained.diagnostics == nil
                && retained.retentionState == .live
                && retained.disposition == .referenced
                && (retained.storageState == .adopted
                    || retained.storageState == .materialized)
        }) else {
            throw SQLiteLibraryStoreError.invalidInput(
                "Conversation read bundle contains a retained source that is not a current managed reference")
        }
    }

    private func replaceRetainedByteReferencesInternal(
        ownerConversationID: UUID,
        references: [ShadowLibraryRetainedByteReferenceSnapshot]
    ) throws {
        // Adoption is derived solely from the complete current reference set. Reset first so a
        // removed reference cannot leave a legacy source looking proven forever.
        try execute(
            """
            UPDATE retained_byte_sources
            SET storage_state = 'observed',
                disposition = CASE
                  WHEN disposition = 'referenced' THEN 'reference_pending'
                  ELSE disposition
                END
            WHERE owner_conversation_id = ?1 AND storage_class = 'legacy_layout'
            """,
            [.text(ownerConversationID.uuidString)])
        try execute(
            "DELETE FROM retained_byte_references WHERE owner_conversation_id = ?1",
            [.text(ownerConversationID.uuidString)])
        let referencedSources = Set(references.map(\.retainedSourceIdentity))
        for sourceIdentity in referencedSources {
            var currentAndOwned = false
            try query(
                """
                SELECT 1
                FROM retained_byte_sources r
                JOIN migration_sources m
                  ON m.domain = 'artifact_media'
                 AND m.source_identity = r.source_identity
                WHERE r.source_identity = ?1 AND r.owner_conversation_id = ?2
                  AND r.link_state = 'current'
                  AND m.dirty = 0 AND m.import_state = 'current'
                  AND m.observed_digest = r.digest AND m.imported_digest = r.digest
                """,
                [.text(sourceIdentity), .text(ownerConversationID.uuidString)]) { _ in
                    currentAndOwned = true
                }
            guard currentAndOwned else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "retained-byte reference source is not current and owned by its Conversation")
            }
        }
        for reference in references {
            try execute(
                """
                INSERT INTO retained_byte_references (
                  reference_id, retained_source_identity, owner_kind,
                  owner_conversation_id, owner_event_id, reference_kind)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                """,
                [
                    .text(reference.id.uuidString),
                    .text(reference.retainedSourceIdentity),
                    .text(reference.ownerKind.rawValue),
                    .text(reference.ownerConversationID.uuidString),
                    reference.ownerEventID.map { .text($0.uuidString) } ?? .null,
                    .text(reference.referenceKind),
                ])
        }
        for sourceIdentity in referencedSources {
            try execute(
                """
                UPDATE retained_byte_sources
                SET storage_state = 'adopted', disposition = 'referenced'
                WHERE source_identity = ?1 AND owner_conversation_id = ?2
                  AND storage_class = 'legacy_layout' AND link_state = 'current'
                """,
                [.text(sourceIdentity), .text(ownerConversationID.uuidString)])
        }
    }

    func retainedByteReferences(
        ownerConversationID: UUID
    ) throws -> [ShadowLibraryRetainedByteReferenceSnapshot] {
        try queue.sync { try readRetainedByteReferences(ownerConversationID: ownerConversationID) }
    }

    private func readRetainedByteReferences(
        ownerConversationID: UUID
    ) throws -> [ShadowLibraryRetainedByteReferenceSnapshot] {
        var result: [ShadowLibraryRetainedByteReferenceSnapshot] = []
        try query(
                """
                SELECT reference_id, retained_source_identity, owner_kind,
                       owner_conversation_id, owner_event_id, reference_kind
                FROM retained_byte_references
                WHERE owner_conversation_id = ?1
                ORDER BY reference_id
                """,
                [.text(ownerConversationID.uuidString)]) { statement in
                    guard let rawID = Self.optionalText(statement, 0),
                          let id = UUID(uuidString: rawID),
                          let retained = Self.optionalText(statement, 1),
                          let rawOwnerKind = Self.optionalText(statement, 2),
                          let ownerKind = ShadowLibraryRetainedByteReferenceSnapshot.OwnerKind(
                            rawValue: rawOwnerKind),
                          let rawOwnerID = Self.optionalText(statement, 3),
                          let ownerID = UUID(uuidString: rawOwnerID),
                          let referenceKind = Self.optionalText(statement, 5)
                    else {
                        throw SQLiteLibraryStoreError.sqlite(
                            "retained-byte reference row is malformed")
                    }
                    let ownerEventID = try Self.optionalUUID(
                        statement, 4, label: "retained-byte reference event id")
                    result.append(ShadowLibraryRetainedByteReferenceSnapshot(
                        id: id,
                        retainedSourceIdentity: retained,
                        ownerKind: ownerKind,
                        ownerConversationID: ownerID,
                        ownerEventID: ownerEventID,
                        referenceKind: referenceKind))
                }
        try validateRetainedByteReferences(
            ownerConversationID: ownerConversationID,
            references: result)
        return result
    }

    private func retainedByteReferenceAssessmentIsCurrent(
        ownerConversationID: UUID,
        conversationSourceIdentity: String,
        references: [ShadowLibraryRetainedByteReferenceSnapshot],
        readiness: ShadowLibraryRetainedByteReadinessFinding?
    ) throws -> Bool {
        let expected = references.sorted { $0.id.uuidString < $1.id.uuidString }
        guard try readRetainedByteReferences(ownerConversationID: ownerConversationID) == expected else {
            return false
        }
        let expectedSources = Set(references.map(\.retainedSourceIdentity))
        var adoptedSources = Set<String>()
        try query(
            """
            SELECT source_identity FROM retained_byte_sources
            WHERE owner_conversation_id = ?1 AND storage_class = 'legacy_layout'
              AND storage_state = 'adopted' AND link_state = 'current'
              AND disposition = 'referenced'
            """,
            [.text(ownerConversationID.uuidString)]) {
                if let identity = Self.optionalText($0, 0) { adoptedSources.insert(identity) }
            }
        guard adoptedSources == expectedSources else { return false }

        var operativeMatches = false
        try query(
            """
            SELECT import_state, dirty, diagnostics, observed_digest, imported_digest
            FROM migration_sources
            WHERE domain = 'operative_state' AND source_identity = ?1 AND entity_id = ?2
            """,
            [.text(conversationSourceIdentity), .text(ownerConversationID.uuidString)]) { statement in
                let state = Self.optionalText(statement, 0)
                let dirty = sqlite3_column_int(statement, 1) != 0
                let diagnostics = Self.optionalText(statement, 2)
                let observedDigest = Self.optionalText(statement, 3)
                let importedDigest = Self.optionalText(statement, 4)
                if let readiness, readiness.isBlocking {
                    operativeMatches = state == "quarantine" && dirty
                        && diagnostics == readiness.diagnostics && importedDigest == nil
                } else {
                    operativeMatches = state == "current" && !dirty
                        && diagnostics == readiness?.diagnostics
                        && observedDigest != nil && observedDigest == importedDigest
                }
            }
        return operativeMatches
    }

    /// Verify the complete candidate without trusting cached success: both SQLite page/index
    /// integrity and every foreign-key relationship must pass. The recorded success is bound to
    /// the current shadow-change sequence and becomes pending after the next mutation.
    @discardableResult
    func integrityCheck() throws -> ShadowLibraryIntegrityStatus {
        try queue.sync { try verifyIntegrityAndRecord() }
    }

    /// Verb-form compatibility for launch coordinators; identical to `integrityCheck()`.
    @discardableResult
    func verifyIntegrity() throws -> ShadowLibraryIntegrityStatus {
        try integrityCheck()
    }

    private func transitionAuthority(
        from: LibraryAuthorityState,
        to: LibraryAuthorityState,
        activationID: UUID,
        rollbackID: UUID?
    ) throws {
        try queue.sync {
            let metadata = try readAuthorityMetadata()
            guard metadata.authorityState == from,
                  metadata.activationID == activationID else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "illegal or mismatched authority transition from \(metadata.authorityState.rawValue) to \(to.rawValue)")
            }
            if from == .rollbackPrepared, metadata.rollbackID != rollbackID {
                throw SQLiteLibraryStoreError.invalidInput("rollback id does not match prepared rollback")
            }
            if to == .rollbackPrepared, rollbackID == nil {
                throw SQLiteLibraryStoreError.invalidInput("rollback id is required")
            }
            try transaction(tracksMutation: false, requiresShadow: false) {
                if to == .rollbackPrepared {
                    try execute(
                        """
                        UPDATE library_metadata
                        SET authority_state = ?1, rollback_id = ?2
                        WHERE singleton = 1 AND authority_state = ?3 AND activation_id = ?4
                        """,
                        [
                            .text(to.rawValue),
                            rollbackID.map { .text($0.uuidString) } ?? .null,
                            .text(from.rawValue), .text(activationID.uuidString),
                        ])
                } else {
                    try execute(
                        """
                        UPDATE library_metadata
                        SET authority_state = ?1
                        WHERE singleton = 1 AND authority_state = ?2 AND activation_id = ?3
                        """,
                        [.text(to.rawValue), .text(from.rawValue), .text(activationID.uuidString)])
                }
            }
        }
    }

    private func readAuthorityMetadata() throws -> LibraryAuthorityMetadata {
        var result: LibraryAuthorityMetadata?
        try query(
            """
            SELECT database_instance_id, schema_version, authority_state, activation_id,
                   rollback_id, minimum_writer_build, committed_sequence
            FROM library_metadata WHERE singleton = 1
            """,
            []) { statement in
                guard let rawInstanceID = Self.optionalText(statement, 0),
                      let instanceID = UUID(uuidString: rawInstanceID),
                      let rawState = Self.optionalText(statement, 2),
                      let state = LibraryAuthorityState(rawValue: rawState) else { return }
                result = LibraryAuthorityMetadata(
                    databaseInstanceID: instanceID,
                    schemaVersion: Int(sqlite3_column_int64(statement, 1)),
                    authorityState: state,
                    activationID: Self.optionalText(statement, 3).flatMap(UUID.init(uuidString:)),
                    rollbackID: Self.optionalText(statement, 4).flatMap(UUID.init(uuidString:)),
                    minimumWriterBuild: Self.optionalText(statement, 5),
                    committedSequence: sqlite3_column_int64(statement, 6))
            }
        guard let result else {
            throw SQLiteLibraryStoreError.sqlite("library authority metadata is invalid")
        }
        return result
    }

    private func readSourceFingerprint(
        domain: ShadowLibraryDomain,
        sourceIdentity: String
    ) throws -> ShadowLibrarySourceFingerprint? {
        var result: ShadowLibrarySourceFingerprint?
        try query(
            """
            SELECT observed_revision, observed_digest, source_byte_count
            FROM migration_sources WHERE domain = ?1 AND source_identity = ?2
            """,
            [.text(domain.rawValue), .text(sourceIdentity)]) { statement in
                guard let revision = Self.optionalText(statement, 0),
                      let digest = Self.optionalText(statement, 1) else { return }
                result = ShadowLibrarySourceFingerprint(
                    identity: sourceIdentity,
                    revision: revision,
                    digest: digest,
                    byteCount: Int(sqlite3_column_int64(statement, 2)))
            }
        return result
    }

    /// Rehearsal/authority reads may consume only a row whose exact source receipt is current.
    /// Merely retaining an entity row beside a newer quarantined source is not permission to return
    /// stale content. Conversation reads additionally require the operative-state receipt derived
    /// from the same exact source generation.
    private func readCurrentSourceFingerprint(
        domain: ShadowLibraryDomain,
        sourceIdentity: String,
        entityID: UUID,
        requiresOperativeState: Bool = false
    ) throws -> ShadowLibrarySourceFingerprint {
        let operativeClause = requiresOperativeState
            ? """
              AND EXISTS (
                SELECT 1 FROM migration_sources operative
                WHERE operative.domain = 'operative_state'
                  AND operative.source_identity = current.source_identity
                  AND operative.entity_id = current.entity_id
                  AND operative.observed_revision = current.observed_revision
                  AND operative.observed_digest = current.observed_digest
                  AND operative.source_byte_count = current.source_byte_count
                  AND operative.imported_revision = operative.observed_revision
                  AND operative.imported_digest = operative.observed_digest
                  AND operative.dirty = 0 AND operative.import_state = 'current'
              )
              """
            : ""
        var result: ShadowLibrarySourceFingerprint?
        try query(
            """
            SELECT current.observed_revision, current.observed_digest,
                   current.source_byte_count
            FROM migration_sources current
            WHERE current.domain = ?1 AND current.source_identity = ?2
              AND current.entity_id = ?3
              AND current.imported_revision = current.observed_revision
              AND current.imported_digest = current.observed_digest
              AND current.dirty = 0 AND current.import_state = 'current'
              \(operativeClause)
            """,
            [.text(domain.rawValue), .text(sourceIdentity), .text(entityID.uuidString)]) {
                statement in
                guard result == nil,
                      let revision = Self.optionalText(statement, 0),
                      let digest = Self.optionalText(statement, 1) else {
                    throw SQLiteLibraryStoreError.sqlite(
                        "duplicate or malformed current \(domain.rawValue) source receipt")
                }
                result = ShadowLibrarySourceFingerprint(
                    identity: sourceIdentity,
                    revision: revision,
                    digest: digest,
                    byteCount: Int(sqlite3_column_int64(statement, 2)))
            }
        guard let result else {
            throw SQLiteLibraryStoreError.invalidInput(
                "\(domain.rawValue) row does not have a matching current source receipt")
        }
        try validate(source: result)
        return result
    }

    private func readWorkspaceSnapshot(id: UUID) throws -> ShadowLibraryWorkspaceSnapshot? {
        struct Row {
            let kind: ShadowLibraryWorkspaceSnapshot.Kind
            let name: String
            let goal: String
            let instructions: String
            let cwd: String
            let favorite: Bool
            let sortIndex: Int?
            let iconSymbol: String?
            let colorHex: String?
            let createdAt: Date
            let updatedAt: Date
            let revision: Int64
            let sourceIdentity: String?
            let tombstoned: Bool
            let localStateVersion: Int
            let localStatePayload: Data
        }
        var row: Row?
        try query(
            """
            SELECT kind, name, goal, instructions, cwd, favorite, sort_index, icon_symbol,
                   color_hex, created_at, updated_at, revision, source_identity, tombstoned,
                   local_state_version, local_state_payload
            FROM workspaces WHERE id = ?1
            """,
            [.text(id.uuidString)]) { statement in
                guard row == nil else {
                    throw SQLiteLibraryStoreError.sqlite(
                        "duplicate Workspace row for \(id.uuidString)")
                }
                guard let rawKind = Self.optionalText(statement, 0),
                      let kind = ShadowLibraryWorkspaceSnapshot.Kind(rawValue: rawKind),
                      let name = Self.optionalText(statement, 1),
                      let goal = Self.optionalText(statement, 2),
                      let instructions = Self.optionalText(statement, 3),
                      let cwd = Self.optionalText(statement, 4) else {
                    throw SQLiteLibraryStoreError.sqlite(
                        "Workspace row \(id.uuidString) is malformed")
                }
                row = Row(
                    kind: kind, name: name, goal: goal, instructions: instructions, cwd: cwd,
                    favorite: sqlite3_column_int(statement, 5) != 0,
                    sortIndex: Self.optionalInt(statement, 6).map(Int.init),
                    iconSymbol: Self.optionalText(statement, 7),
                    colorHex: Self.optionalText(statement, 8),
                    createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 9)),
                    updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 10)),
                    revision: sqlite3_column_int64(statement, 11),
                    sourceIdentity: Self.optionalText(statement, 12),
                    tombstoned: sqlite3_column_int(statement, 13) != 0,
                    localStateVersion: Int(sqlite3_column_int64(statement, 14)),
                    localStatePayload: Self.data(statement, 15))
            }
        guard let row else { return nil }
        let source: ShadowLibrarySourceFingerprint
        if row.kind == .unresolved {
            let identity = "missing-workspace:\(id.uuidString)"
            var placeholder: ShadowLibrarySourceFingerprint?
            try query(
                """
                SELECT observed_revision, observed_digest, source_byte_count
                FROM migration_sources
                WHERE domain = 'workspaces' AND source_identity = ?1 AND entity_id = ?2
                  AND dirty = 1 AND import_state = 'mismatch'
                """,
                [.text(identity), .text(id.uuidString)]) { statement in
                    guard placeholder == nil,
                          let revision = Self.optionalText(statement, 0),
                          let digest = Self.optionalText(statement, 1) else {
                        throw SQLiteLibraryStoreError.sqlite(
                            "duplicate or malformed unresolved Workspace receipt")
                    }
                    placeholder = ShadowLibrarySourceFingerprint(
                        identity: identity,
                        revision: revision,
                        digest: digest,
                        byteCount: Int(sqlite3_column_int64(statement, 2)))
                }
            guard row.sourceIdentity == nil, !row.tombstoned, let placeholder else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "unresolved Workspace row does not have an exact missing-source receipt")
            }
            source = placeholder
        } else {
            guard let identity = row.sourceIdentity else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "Workspace row does not have a current source identity")
            }
            source = try readCurrentSourceFingerprint(
                domain: .workspaces,
                sourceIdentity: identity,
                entityID: id)
        }
        return ShadowLibraryWorkspaceSnapshot(
            id: id, kind: row.kind, name: row.name, goal: row.goal,
            instructions: row.instructions, cwd: row.cwd, favorite: row.favorite,
            sortIndex: row.sortIndex, iconSymbol: row.iconSymbol, colorHex: row.colorHex,
            createdAt: row.createdAt, updatedAt: row.updatedAt, revision: row.revision,
            tombstoned: row.tombstoned, localStateVersion: row.localStateVersion,
            localStatePayload: row.localStatePayload, source: source)
    }

    /// Missing Workspace documents are a first-class membership state, not corrupt data. This
    /// proof is intentionally exact so no other mismatch can hide behind the reverse converter's
    /// unresolved-membership allowance.
    private func acceptedUnresolvedWorkspaceCount() throws -> Int {
        Int(try scalarInt(
            """
            SELECT COUNT(*)
            FROM workspaces w
            JOIN migration_sources source
              ON source.domain = 'workspaces'
             AND source.source_identity = 'missing-workspace:' || w.id
             AND source.entity_id = w.id
            WHERE w.kind = 'unresolved' AND w.source_identity IS NULL AND w.tombstoned = 0
              AND source.observed_revision = 'missing'
              AND source.observed_digest = 'missing'
              AND source.source_byte_count = 0
              AND source.dirty = 1 AND source.import_state = 'mismatch'
            """))
    }

    // MARK: - Accounted exceptions

    /// One Conversation sidecar the app cannot read, kept as an exact record of what was there.
    ///
    /// The bytes are not in the database — `migration_sources` is a STRICT table with no payload
    /// column — so this value names the legacy file plus the generation and digest the census
    /// proved. Activation carries those exact bytes into managed storage and re-verifies this digest
    /// before it will publish an authority marker.
    struct UnreadableConversationSource: Equatable, Sendable {
        let source: ShadowLibrarySourceFingerprint
        let diagnostics: String
    }

    /// Sources whose exceptions the readiness proof may tolerate, per domain.
    struct AcceptedExceptions: Equatable, Sendable {
        var quarantine = 0
        var mismatch = 0
    }

    /// Record that an imported source contains something the current model cannot reproduce,
    /// without disturbing its receipt.
    ///
    /// The Conversation itself is fine — it decoded, and the app can open it — so the source stays
    /// `current` and the entity keeps its place. What the note buys is the guarantee that activation
    /// carries these exact bytes into managed storage, so the unreproducible part is not lost when
    /// the frozen tree is released. Quarantining instead would remove a Conversation the person
    /// reads today from their library.
    @discardableResult
    func noteSourceIsNotReproducible(
        domain: ShadowLibraryDomain,
        sourceIdentity: String,
        entityID: UUID,
        diagnostics: String
    ) throws -> ShadowLibraryStatus {
        guard !diagnostics.isEmpty else {
            throw SQLiteLibraryStoreError.invalidInput("source note is empty")
        }
        return try queue.sync {
            try execute(
                """
                UPDATE migration_sources SET diagnostics = ?1
                WHERE domain = ?2 AND source_identity = ?3 AND entity_id = ?4
                  AND dirty = 0 AND import_state = 'current'
                """,
                [
                    .text(diagnostics), .text(domain.rawValue), .text(sourceIdentity),
                    .text(entityID.uuidString),
                ])
            return try makeStatus()
        }
    }

    /// Every unreadable Conversation source the readiness proof is willing to accept.
    ///
    /// Exposed so activation can carry the bytes: accepting an unreadable source without carrying it
    /// is the one way relaxing the gate could destroy data. The legacy file is frozen after the
    /// cutover and the post-soak reclaim Trashes the tree it lives in, so a source that migrates as
    /// a bare row and nothing else is a source that is eventually gone for good.
    func unreadableConversationSources() throws -> [UnreadableConversationSource] {
        try queue.sync {
            try readConversationSources(Self.unrepresentedConversationSourceSQL)
                + readConversationSources(Self.unreproducibleConversationSourceSQL)
        }
    }

    /// Conversation rows the library holds, tombstoned ones included.
    ///
    /// The reclaim compares this against the `.json` sidecars still in the frozen tree, and that
    /// tree is a snapshot from migration time: a Conversation deleted since then still has a sidecar
    /// there and is still accounted for by its row. Counting only live rows would make an ordinary
    /// deletion look like an unaccounted source and block the reclaim forever.
    func conversationRowCount() throws -> Int {
        try queue.sync { Int(try scalarInt("SELECT COUNT(*) FROM conversations")) }
    }

    /// Sources the migrated library holds **no Conversation for**. This is the number the reclaim
    /// needs: a source that imported and was also preserved is already counted as a Conversation, so
    /// adding it again would let the frozen tree be released while something real is unaccounted.
    func unrepresentedConversationSourceCount() throws -> Int {
        try queue.sync {
            try readConversationSources(Self.unrepresentedConversationSourceSQL).count
        }
    }

    private func readConversationSources(
        _ sql: String
    ) throws -> [UnreadableConversationSource] {
        var results: [UnreadableConversationSource] = []
        try query(sql, []) { statement in
            guard let identity = Self.optionalText(statement, 0),
                  let revision = Self.optionalText(statement, 1),
                  let digest = Self.optionalText(statement, 2),
                  let diagnostics = Self.optionalText(statement, 3) else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "Conversation source row is malformed")
            }
            results.append(UnreadableConversationSource(
                source: ShadowLibrarySourceFingerprint(
                    identity: identity,
                    revision: revision,
                    digest: digest,
                    byteCount: Int(sqlite3_column_int64(statement, 4))),
                diagnostics: diagnostics))
        }
        return results
    }

    /// Sources that DID import — the Conversation is in the library and the person can open it —
    /// but whose bytes the current model cannot re-emit exactly. `noteSourceIsNotReproducible`
    /// writes these, and the only thing distinguishing them from an ordinary current row is that
    /// somebody recorded why. Their bytes are carried for the same reason as an unreadable source:
    /// once the frozen tree is released, this is the only remaining copy of the part we cannot
    /// reproduce.
    private static let unreproducibleConversationSourceSQL = """
        SELECT source_identity, observed_revision, observed_digest, diagnostics, source_byte_count
        FROM migration_sources
        WHERE domain = 'conversations'
          AND import_state = 'current'
          AND dirty = 0
          AND diagnostics IS NOT NULL AND diagnostics <> ''
          AND observed_digest IS NOT NULL AND LENGTH(observed_digest) = 64
          AND observed_revision IS NOT NULL AND observed_revision <> ''
          AND source_byte_count > 0
        ORDER BY source_identity
        """

    /// The shape a Conversation source must have before the migrated library may leave it
    /// unrepresented.
    ///
    /// One rule covers every way a sidecar can fail to become a Conversation — bytes that will not
    /// decode, a member written by a build we do not know, a filename whose identity disagrees with
    /// its contents, an empty placeholder the legacy loader already excludes, a stray file somebody
    /// dropped in the directory. In each case the app cannot show it, so refusing to migrate does
    /// not help anyone; but its bytes are real and must come with us.
    ///
    /// Every clause is a fact the importer had to record deliberately. A 64-hex digest over a
    /// non-empty file proves the census read a coherent snapshot rather than failing mid-read — note
    /// `recordMalformed` records zero bytes when it cannot read the file at all, which is exactly the
    /// case we must never claim to have preserved. Empty diagnostics means nobody wrote down why. And
    /// no `conversations` row may claim the source, which is what makes this set *unrepresented*: a
    /// Conversation that did import is never laundered through here, it goes through
    /// `unreproducibleConversationSourceSQL` and keeps its place in the library.
    ///
    /// A duplicate whose winner survives is included deliberately, even though the entity it names
    /// is represented. The loser is a real file with real content — a `.json.corrupt-*` recovery
    /// copy is exactly this shape, and the whole point of retaining one is that its owner may want
    /// it back. Being represented "as an entity" is not the same as having your bytes kept.
    private static let unrepresentedConversationSourceSQL = """
        SELECT issue.source_identity, issue.observed_revision, issue.observed_digest,
               issue.diagnostics, issue.source_byte_count
        FROM migration_sources issue
        WHERE issue.domain = 'conversations'
          AND issue.import_state IN ('quarantine', 'mismatch')
          AND issue.dirty = 1
          AND issue.imported_revision IS NULL
          AND issue.imported_digest IS NULL
          AND issue.imported_at IS NULL
          AND issue.diagnostics IS NOT NULL AND issue.diagnostics <> ''
          AND issue.observed_digest IS NOT NULL AND LENGTH(issue.observed_digest) = 64
          AND issue.observed_revision IS NOT NULL AND issue.observed_revision <> ''
          AND issue.source_byte_count > 0
          AND NOT EXISTS (
                SELECT 1 FROM conversations claimed
                WHERE claimed.source_identity = issue.source_identity)
        ORDER BY issue.source_identity
        """

    /// Which tables can claim a source as still represented, per domain.
    ///
    /// A source is only tolerated when NOTHING in the library holds it. Names come from this fixed
    /// switch, never from data, so interpolating them into SQL below is not an injection surface.
    private static func claimTables(for domain: ShadowLibraryDomain) -> [String] {
        switch domain {
        case .conversations, .operativeState: return ["conversations"]
        case .workspaces: return ["workspaces"]
        // A media source lands in one table or the other depending on what it is, and a row in
        // either means something real still names it.
        case .artifactMedia: return ["artifacts", "retained_byte_sources"]
        case .ambientState: return ["ambient_authority_sources"]
        case .operations: return ["operations"]
        }
    }

    /// Sources in one domain that are fully inventoried, never imported, and claimed by nothing.
    ///
    /// The same proof the Conversation allowance applies, with one deliberate omission: no
    /// `source_byte_count > 0`. A malformed Conversation is a file that was read and would not
    /// parse, so it has real bytes. A malformed source in these domains is frequently one the census
    /// could not read AT ALL — the scanner records the issue with empty `sourceBytes`, so the count
    /// is 0 and the digest is the digest of nothing. Requiring a positive count would make this
    /// allowance unreachable, which is exactly the state that locked a user out of her library.
    ///
    /// Everything else still has to hold. `recordSourceIssueInternal` writes every issue row with
    /// `imported_revision`, `imported_digest` and `imported_at` NULL and `dirty = 1`, and refuses to
    /// write at all without a diagnosis, so a row that fails any of these is not an inventoried
    /// imperfection — it is a source nobody can account for, and that must still refuse.
    private func unrepresentedSourceCount(
        domain: ShadowLibraryDomain,
        state: String
    ) throws -> Int {
        let unclaimed = Self.claimTables(for: domain).map { table in
            """
              AND NOT EXISTS (
                    SELECT 1 FROM \(table) claimed
                    WHERE claimed.source_identity = issue.source_identity)
            """
        }.joined(separator: "\n")
        return Int(try scalarInt(
            """
            SELECT COUNT(*)
            FROM migration_sources issue
            WHERE issue.domain = ?1
              AND issue.import_state = ?2
              AND issue.dirty = 1
              AND issue.imported_revision IS NULL
              AND issue.imported_digest IS NULL
              AND issue.imported_at IS NULL
              AND issue.diagnostics IS NOT NULL AND issue.diagnostics <> ''
              AND issue.observed_digest IS NOT NULL AND LENGTH(issue.observed_digest) = 64
              AND issue.observed_revision IS NOT NULL AND issue.observed_revision <> ''
            \(unclaimed)
            """,
            [.text(domain.rawValue), .text(state)]))
    }

    private func unrepresentedConversationCount(state: String) throws -> Int {
        Int(try scalarInt(
            """
            SELECT COUNT(*) FROM (\(Self.unrepresentedConversationSourceSQL)) accepted
            JOIN migration_sources issue
              ON issue.domain = 'conversations'
             AND issue.source_identity = accepted.source_identity
            WHERE issue.import_state = ?1
            """,
            [.text(state)]))
    }

    /// The importer mirrors every Conversation source issue into operative state. A twin counts only
    /// when the Conversation source it names is itself accepted **and in the same state**, so an
    /// operative quarantine written for another reason — a retained-byte assessment, say — cannot
    /// ride along on somebody else's allowance.
    private func unrepresentedOperativeTwinCount(state: String) throws -> Int {
        Int(try scalarInt(
            """
            SELECT COUNT(*)
            FROM migration_sources twin
            JOIN migration_sources issue
              ON issue.domain = 'conversations'
             AND issue.source_identity = twin.source_identity
             AND issue.import_state = twin.import_state
            WHERE twin.domain = 'operative_state'
              AND twin.import_state = ?1
              AND twin.dirty = 1
              AND twin.source_identity IN (
                    SELECT accepted.source_identity
                    FROM (\(Self.unrepresentedConversationSourceSQL)) accepted)
            """,
            [.text(state)]))
    }

    /// The exceptions this domain has proven, counted by SQL strictly narrower than the aggregate
    /// counter each one is compared against. Because the comparison is a two-sided equality and
    /// never `>=`, a single row that is dirty for a reason none of these predicates proves makes the
    /// readiness check fail closed.
    private func acceptedExceptions(domain: ShadowLibraryDomain) throws -> AcceptedExceptions {
        var accepted = AcceptedExceptions()
        switch domain {
        case .conversations:
            // The unrepresented set already covers duplicates, so this domain does not also add
            // `acceptedDuplicateMismatchCount` — that would count the same row twice.
            accepted.quarantine = try unrepresentedConversationCount(state: "quarantine")
            accepted.mismatch = try unrepresentedConversationCount(state: "mismatch")
            return accepted
        case .operativeState:
            accepted.quarantine = try unrepresentedOperativeTwinCount(state: "quarantine")
            accepted.mismatch = try unrepresentedOperativeTwinCount(state: "mismatch")
            return accepted
        case .workspaces, .artifactMedia, .ambientState, .operations:
            // ONE rule for every remaining domain, rather than the domain-at-a-time relaxation this
            // replaces. Quarantine means `ShadowLibrarySourceIssueKind.malformed`: a source the
            // importer could not read. This type's own policy note above already says that must not
            // block — the app cannot read those bytes either way, and refusing to migrate does not
            // make them readable — but the allowance existed only for conversations.
            //
            // Fixing that a domain at a time does not fix it. A user was refused on `artifact_media`
            // with two unreadable sources; that shipped; her very next launch refused on
            // `operations` with one, the same hardcoded zero one table over, with `ambient_state`
            // and `workspaces` still queued behind it.
            accepted.quarantine = try unrepresentedSourceCount(domain: domain, state: "quarantine")
        }
        accepted.mismatch += try acceptedDuplicateMismatchCount(domain: domain)
        if domain == .workspaces {
            // A Workspace document that is simply absent is a membership state, not a duplicate.
            // The two allowances are disjoint by `source_identity`, so they cannot double-count.
            accepted.mismatch += try acceptedUnresolvedWorkspaceCount()
        }
        return accepted
    }

    /// A duplicate identity whose winner is still represented. The loser's own bytes are not
    /// preserved by this allowance — only the fact that the entity it names survives in the library
    /// through another, current source.
    private func acceptedDuplicateMismatchCount(domain: ShadowLibraryDomain) throws -> Int {
        Int(try scalarInt(
            """
            SELECT COUNT(*)
            FROM migration_sources loser
            WHERE loser.domain = ?1
              AND loser.import_state = 'mismatch'
              AND loser.dirty = 1
              AND loser.imported_revision IS NULL
              AND loser.imported_digest IS NULL
              AND loser.imported_at IS NULL
              AND loser.diagnostics IS NOT NULL AND loser.diagnostics <> ''
              AND loser.source_identity NOT LIKE 'missing-workspace:%'
              AND EXISTS (
                    SELECT 1 FROM migration_sources winner
                    WHERE winner.domain = loser.domain
                      AND winner.entity_id = loser.entity_id
                      AND winner.source_identity <> loser.source_identity
                      AND winner.dirty = 0
                      AND winner.import_state = 'current'
                      AND winner.imported_revision = winner.observed_revision
                      AND winner.imported_digest = winner.observed_digest)
            """,
            [.text(domain.rawValue)]))
    }

    /// Activation readiness for one domain.
    ///
    /// This replaces `ShadowLibraryDomainStatus.isComplete` on the activation path. The difference
    /// is deliberate and narrow: a census that did not finish, a source the app failed to write, or
    /// a domain nobody reconciled all stay fatal, because each leaves a real question about whether
    /// the library saw the whole corpus. An imperfection the importer inventoried into an explicit,
    /// proven state does not — the app already could not read that source, and refusing to migrate
    /// does not make it readable.
    ///
    /// `errors` is named explicitly rather than left to `dirty == 0`. An import failure means a
    /// legacy mutation the app performed never reached disk, so the database and the corpus disagree
    /// about something the app believes it did. Tolerating any dirty row without naming `errors`
    /// would launder that divergence into the allowance.
    private func domainIsReadyForActivation(_ status: ShadowLibraryDomainStatus) throws -> Bool {
        try activationBlocker(status) == nil
    }

    /// Which check refused, and with what numbers. A migration that can only say *that* a domain is
    /// not ready cannot be diagnosed from the machine it failed on, which is the only machine that
    /// has the evidence. Returns nil when the domain is ready.
    private func activationBlocker(_ status: ShadowLibraryDomainStatus) throws -> String? {
        let accepted = try acceptedExceptions(domain: status.domain)
        let expectedDirty = accepted.quarantine + accepted.mismatch
        if status.phase != .shadowing { return "phase is \(status.phase.rawValue), not shadowing" }
        if !status.hasFullCensus { return "the source census is incomplete" }
        if status.errors != 0 { return "\(status.errors) source(s) failed to import" }
        if status.quarantined != accepted.quarantine {
            return "\(status.quarantined) quarantined source(s), of which \(accepted.quarantine) "
                + "are accounted for"
        }
        if status.mismatched != accepted.mismatch {
            return "\(status.mismatched) mismatched source(s), of which \(accepted.mismatch) "
                + "are accounted for"
        }
        if status.dirty != expectedDirty {
            return "\(status.dirty) unreconciled source(s), of which \(expectedDirty) "
                + "are accounted for"
        }
        if status.current != status.total - expectedDirty {
            return "\(status.current) of \(status.total) source(s) are current, expected "
                + "\(status.total - expectedDirty)"
        }
        return nil
    }

    /// The same proof the fresh-legacy capture applies, for callers that must re-check readiness
    /// against a later status snapshot without rebuilding the whole capture.
    func isReadyForActivation(_ status: ShadowLibraryStatus) throws -> Bool {
        try queue.sync {
            for domain in ShadowLibraryDomain.allCases {
                guard let domainStatus = status.domain(domain),
                      try domainIsReadyForActivation(domainStatus) else { return false }
            }
            return true
        }
    }

    private func readValidatedConversationBundle(
        id: UUID
    ) throws -> ShadowLibraryConversationReadBundle? {
        guard let conversation = try readConversationSnapshot(id: id) else { return nil }
        let references = try readRetainedByteReferences(ownerConversationID: id)
        let retainedSources = try readReferencedRetainedByteSources(ownerConversationID: id)
        try validateConversationReadBundle(
            conversation: conversation,
            references: references,
            retainedSources: retainedSources)
        return ShadowLibraryConversationReadBundle(
            conversation: conversation,
            retainedByteReferences: references,
            retainedByteSources: retainedSources)
    }

    /// Build sidebar and residency facts without reading every transcript payload. Counts are
    /// computed in SQLite; only the latest visible user/assistant payload, one metadata payload,
    /// and the small delegate/local-state projections are decoded for each Conversation.
    private func readLaunchConversationRows() throws -> [ShadowLibraryLaunchConversationRow] {
        struct Base {
            let id: UUID
            let title: String
            let cwd: String
            let workspaceID: UUID
            let updatedAt: Date
            let favorite: Bool
            let sortIndex: Int?
            let unread: Bool
            let errored: Bool
            let sourceIdentity: String
            let localStateVersion: Int
            let localStatePayload: Data
        }
        struct MessageFacts {
            var count = 0
            var hasUser = false
            var latest: TranscriptEntry?
        }

        var bases: [UUID: Base] = [:]
        try query(
            """
            SELECT id, title, cwd, workspace_id, updated_at, favorite, sort_index,
                   unread, errored, source_identity, local_state_version, local_state_payload
            FROM conversations
            WHERE tombstoned = 0 AND substr(source_identity, -5) = '.json'
            ORDER BY id
            """,
            []) { statement in
                guard let rawID = Self.optionalText(statement, 0),
                      let id = UUID(uuidString: rawID),
                      let title = Self.optionalText(statement, 1),
                      let cwd = Self.optionalText(statement, 2),
                      let rawWorkspaceID = Self.optionalText(statement, 3),
                      let workspaceID = UUID(uuidString: rawWorkspaceID),
                      let sourceIdentity = Self.optionalText(statement, 9),
                      bases[id] == nil else {
                    throw SQLiteLibraryStoreError.sqlite(
                        "launch Conversation row is malformed or duplicated")
                }
                bases[id] = Base(
                    id: id,
                    title: title,
                    cwd: cwd,
                    workspaceID: workspaceID,
                    updatedAt: Date(
                        timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 4)),
                    favorite: sqlite3_column_int(statement, 5) != 0,
                    sortIndex: Self.optionalInt(statement, 6).map(Int.init),
                    unread: sqlite3_column_int(statement, 7) != 0,
                    errored: sqlite3_column_int(statement, 8) != 0,
                    sourceIdentity: sourceIdentity,
                    localStateVersion: Int(sqlite3_column_int64(statement, 10)),
                    localStatePayload: Self.data(statement, 11))
        }

        var messages: [UUID: MessageFacts] = [:]
        try query(
            """
            WITH visible AS (
              SELECT conversation_id, id, kind, capture_sequence, payload_version, payload
              FROM conversation_events
              WHERE kind IN ('transcript.user', 'transcript.assistant')
                AND json_type(CAST(payload AS TEXT), '$.supersessionEventID') IS NULL
                AND json_type(CAST(payload AS TEXT), '$.supersededByEntryID') IS NULL
                AND json_type(CAST(payload AS TEXT), '$.supersededByFrameUUID') IS NULL
            ), ranked AS (
              SELECT conversation_id, id, kind, payload_version, payload,
                     COUNT(*) OVER (PARTITION BY conversation_id) AS message_count,
                     MAX(CASE WHEN kind = 'transcript.user' THEN 1 ELSE 0 END)
                       OVER (PARTITION BY conversation_id) AS has_user,
                     ROW_NUMBER() OVER (
                       PARTITION BY conversation_id ORDER BY capture_sequence DESC
                     ) AS newest
              FROM visible
            )
            SELECT conversation_id, id, kind, payload_version, payload,
                   message_count, has_user
            FROM ranked WHERE newest = 1
            """,
            []) { statement in
                guard let rawConversationID = Self.optionalText(statement, 0),
                      let conversationID = UUID(uuidString: rawConversationID),
                      let rawEntryID = Self.optionalText(statement, 1),
                      let entryID = UUID(uuidString: rawEntryID),
                      let kind = Self.optionalText(statement, 2),
                      sqlite3_column_int64(statement, 3) == 1 else {
                    throw SQLiteLibraryStoreError.sqlite(
                        "latest launch transcript projection is malformed")
                }
                // Retained recovery rows deliberately remain queryable in library.db but are not
                // members of the current live `.json` launch inventory selected above.
                guard bases[conversationID] != nil else { return }
                let entry: TranscriptEntry
                do {
                    entry = try ConversationStore.makeDecoder().decode(
                        TranscriptEntry.self, from: Self.data(statement, 4))
                } catch {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "latest launch transcript projection could not decode: \(error.localizedDescription)")
                }
                guard entry.id == entryID,
                      kind == "transcript.\(entry.kind.rawValue)",
                      !entry.isSuperseded,
                      entry.kind == .user || entry.kind == .assistant else {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "latest launch transcript projection does not match its columns")
                }
                messages[conversationID] = MessageFacts(
                    count: Int(sqlite3_column_int64(statement, 5)),
                    hasUser: sqlite3_column_int(statement, 6) != 0,
                    latest: entry)
            }

        var modelAccess: [UUID: ModelAccess] = [:]
        var metadataConversationIDs = Set<UUID>()
        try query(
            """
            SELECT conversation_id, payload_version, payload
            FROM conversation_events WHERE kind = 'conversation.metadata'
            ORDER BY conversation_id, capture_sequence
            """,
            []) { statement in
                guard let rawID = Self.optionalText(statement, 0),
                      let id = UUID(uuidString: rawID),
                      sqlite3_column_int64(statement, 1) == 1 else {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "Conversation launch metadata is malformed or duplicated")
                }
                guard bases[id] != nil else { return }
                guard metadataConversationIDs.insert(id).inserted else {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "Conversation launch metadata is malformed or duplicated")
                }
                do {
                    let metadata = try ConversationStore.makeDecoder().decode(
                        LibraryConversationMetadataPayload.self,
                        from: Self.data(statement, 2))
                    modelAccess[id] = metadata.modelSelection?.access
                } catch {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "Conversation launch metadata could not decode: \(error.localizedDescription)")
                }
            }
        guard metadataConversationIDs == Set(bases.keys) else {
            let missing = Set(bases.keys).subtracting(metadataConversationIDs)
            throw SQLiteLibraryStoreError.invalidInput(
                "Conversation launch metadata is absent for \(missing.count) live row(s)")
        }

        var artifactIDs: [UUID: Set<UUID>] = [:]
        try query(
            """
            SELECT conversation_id, artifact_id
            FROM conversation_artifact_snapshots ORDER BY conversation_id, ordinal
            """,
            []) { statement in
                guard let rawConversationID = Self.optionalText(statement, 0),
                      let conversationID = UUID(uuidString: rawConversationID),
                      let rawArtifactID = Self.optionalText(statement, 1),
                      let artifactID = UUID(uuidString: rawArtifactID) else {
                    throw SQLiteLibraryStoreError.sqlite(
                        "Conversation launch Artifact identity is malformed")
                }
                guard bases[conversationID] != nil else { return }
                artifactIDs[conversationID, default: []].insert(artifactID)
            }

        var subagents: [UUID: [String: SubagentRun]] = [:]
        var workflows: [UUID: [String: WorkflowRun]] = [:]
        // These rows exist only to answer one boolean per Conversation: is delegated work still
        // non-terminal. Decoding every historical subagent to learn that cost 1.3 s of a measured
        // 2.5 s launch on an 81-Conversation library (3,038 rows, 7 MB of JSON, all terminal).
        // A subagent whose stored status is terminal cannot satisfy the predicate, so SQLite
        // filters those out and Swift decodes only the rows that could still matter. The terminal
        // set is derived from `WorkflowStatus`, so the rule stays owned by the domain type.
        let terminalStatuses = WorkflowStatus.allCases.filter(\.isTerminal).map(\.rawValue)
        let terminalPlaceholders = terminalStatuses.map { _ in "?" }.joined(separator: ", ")
        // Fail-closed on malformed rows is preserved without decoding them: every delegate row
        // must still carry the current payload version, including the ones filtered out below.
        let unsupportedDelegateRows = try scalarInt(
            """
            SELECT count(*) FROM conversation_events
            WHERE kind IN (
              'legacy_projection.subagent_summary',
              'legacy_projection.workflow_summary')
              AND payload_version != 1
            """)
        guard unsupportedDelegateRows == 0 else {
            throw SQLiteLibraryStoreError.invalidInput(
                "Conversation launch delegate projection is malformed")
        }
        try query(
            """
            SELECT conversation_id, kind, payload_version, payload
            FROM conversation_events
            WHERE kind = 'legacy_projection.workflow_summary'
               OR (kind = 'legacy_projection.subagent_summary'
                   AND (json_extract(CAST(payload AS TEXT), '$.value.status') IS NULL
                        OR json_extract(CAST(payload AS TEXT), '$.value.status')
                           NOT IN (\(terminalPlaceholders))))
            ORDER BY conversation_id, capture_sequence
            """,
            terminalStatuses.map { SQLiteValue.text($0) }) { statement in
                guard let rawID = Self.optionalText(statement, 0),
                      let id = UUID(uuidString: rawID),
                      let kind = Self.optionalText(statement, 1),
                      sqlite3_column_int64(statement, 2) == 1 else {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "Conversation launch delegate projection is malformed")
                }
                guard bases[id] != nil else { return }
                do {
                    if kind == "legacy_projection.subagent_summary" {
                        let value = try ConversationStore.makeDecoder().decode(
                            LibrarySubagentPayload.self, from: Self.data(statement, 3))
                        guard subagents[id, default: [:]].updateValue(
                            value.value, forKey: value.storageKey) == nil else {
                            throw SQLiteLibraryStoreError.invalidInput(
                                "Conversation launch subagent key is duplicated")
                        }
                    } else {
                        let value = try ConversationStore.makeDecoder().decode(
                            LibraryWorkflowPayload.self, from: Self.data(statement, 3))
                        guard workflows[id, default: [:]].updateValue(
                            value.value, forKey: value.storageKey) == nil else {
                            throw SQLiteLibraryStoreError.invalidInput(
                                "Conversation launch workflow key is duplicated")
                        }
                    }
                } catch let error as SQLiteLibraryStoreError {
                    throw error
                } catch {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "Conversation launch delegate projection could not decode: \(error.localizedDescription)")
                }
            }

        var rows: [ShadowLibraryLaunchConversationRow] = []
        rows.reserveCapacity(bases.count)
        for base in bases.values {
            let source = try readCurrentSourceFingerprint(
                domain: .conversations,
                sourceIdentity: base.sourceIdentity,
                entityID: base.id,
                requiresOperativeState: true)
            let local: LibraryConversationLocalStatePayload
            do {
                guard base.localStateVersion == LibraryConversationLocalStatePayload.currentVersion,
                      base.localStatePayload.count
                        <= LibraryConversationLocalStatePayload.maximumEncodedBytes else {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "Conversation launch local-state version or size is unsupported")
                }
                local = try ConversationStore.makeDecoder().decode(
                    LibraryConversationLocalStatePayload.self,
                    from: base.localStatePayload)
            } catch let error as SQLiteLibraryStoreError {
                throw error
            } catch {
                throw SQLiteLibraryStoreError.invalidInput(
                    "Conversation launch local state could not decode: \(error.localizedDescription)")
            }
            if let legacyWorkspaceID = local.legacyProjectID,
               legacyWorkspaceID != base.workspaceID {
                throw SQLiteLibraryStoreError.invalidInput(
                    "Conversation launch membership disagrees with its relational Workspace")
            }
            let hasRunningDelegate = hasNonterminalDelegatedWork(
                workflowRuns: workflows[base.id] ?? [:],
                subagents: subagents[base.id] ?? [:])
            let facts = messages[base.id] ?? MessageFacts()
            guard (facts.count == 0) == (facts.latest == nil) else {
                throw SQLiteLibraryStoreError.sqlite(
                    "Conversation launch message count and latest row disagree")
            }
            let snippet: String
            if let latest = facts.latest {
                let prefix = latest.kind == .user ? "You: " : ""
                let bounded = Self.boundedLaunchSnippet(latest.text)
                snippet = prefix + (bounded.isEmpty ? "…" : bounded)
            } else {
                snippet = "No messages yet"
            }
            let summary = ConversationSummary(
                id: base.id,
                title: base.title,
                workspaceCWD: base.cwd,
                // Preserve the exact current runtime/sidecar value. A legacy nil may still resolve
                // through `workspaceCWD` to the normalized relational Workspace; publishing that
                // normalized id here would make SQLite and projections disagree and would silently
                // mutate membership the first time this summary hydrates.
                workspaceID: local.legacyProjectID,
                updatedAt: base.updatedAt,
                messageCount: facts.count,
                snippet: snippet,
                hasUserMessage: facts.hasUser,
                favorite: base.favorite,
                sortIndex: base.sortIndex,
                unread: base.unread,
                errored: base.errored,
                awaitingQuestion: false,
                hasRunningDelegate: hasRunningDelegate,
                providerAccessName: local.providerAccessRequest?.providerName,
                armedWaitSummary: local.armedTrigger?.summary)
            rows.append(ShadowLibraryLaunchConversationRow(
                summary: summary,
                source: source,
                artifactIDs: artifactIDs[base.id] ?? [],
                modelAccess: modelAccess[base.id],
                requiresIntrinsicResidency: !local.queuedPrompts.isEmpty
                    || local.pendingTurnPrompt != nil
                    || local.armedTrigger != nil
                    || local.providerAccessRequest != nil
                    || hasRunningDelegate))
        }
        return rows.sorted { ConversationSummary.canonicalOrder($0.summary, $1.summary) }
    }

    /// Byte-for-byte presentation parity with `ConversationSummary` without making its helper a
    /// storage API merely for this migration rehearsal.
    private static func boundedLaunchSnippet(_ raw: String) -> String {
        var characters: [Character] = []
        characters.reserveCapacity(ConversationSummary.snippetCharacterLimit + 1)
        var pendingSpace = false
        for character in raw {
            if character.isWhitespace {
                if !characters.isEmpty { pendingSpace = true }
                continue
            }
            if pendingSpace {
                characters.append(" ")
                pendingSpace = false
                if characters.count > ConversationSummary.snippetCharacterLimit { break }
            }
            characters.append(character)
            if characters.count > ConversationSummary.snippetCharacterLimit { break }
        }
        guard characters.count > ConversationSummary.snippetCharacterLimit else {
            return String(characters)
        }
        characters.removeLast(
            characters.count - ConversationSummary.snippetCharacterLimit + 1)
        characters.append("…")
        return String(characters)
    }


    private func readConversationSnapshot(
        id: UUID
    ) throws -> ShadowLibraryConversationSnapshot? {
        struct Row {
            let title: String
            let titleSource: String
            let cwd: String
            let workspaceID: UUID
            let updatedAt: Date
            let favorite: Bool
            let sortIndex: Int?
            let unread: Bool
            let errored: Bool
            let revision: Int64
            let sourceIdentity: String
            let tombstoned: Bool
            let localStateVersion: Int
            let localStatePayload: Data
        }
        var row: Row?
        try query(
            """
            SELECT title, title_source, cwd, workspace_id, updated_at, favorite, sort_index,
                   unread, errored, revision, source_identity, tombstoned,
                   local_state_version, local_state_payload
            FROM conversations WHERE id = ?1
            """,
            [.text(id.uuidString)]) { statement in
                guard row == nil else {
                    throw SQLiteLibraryStoreError.sqlite(
                        "duplicate Conversation row for \(id.uuidString)")
                }
                guard let title = Self.optionalText(statement, 0),
                      let titleSource = Self.optionalText(statement, 1),
                      let cwd = Self.optionalText(statement, 2),
                      let rawWorkspaceID = Self.optionalText(statement, 3),
                      let workspaceID = UUID(uuidString: rawWorkspaceID),
                      let sourceIdentity = Self.optionalText(statement, 10) else {
                    throw SQLiteLibraryStoreError.sqlite(
                        "Conversation row \(id.uuidString) is malformed")
                }
                row = Row(
                    title: title, titleSource: titleSource, cwd: cwd, workspaceID: workspaceID,
                    updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 4)),
                    favorite: sqlite3_column_int(statement, 5) != 0,
                    sortIndex: Self.optionalInt(statement, 6).map(Int.init),
                    unread: sqlite3_column_int(statement, 7) != 0,
                    errored: sqlite3_column_int(statement, 8) != 0,
                    revision: sqlite3_column_int64(statement, 9),
                    sourceIdentity: sourceIdentity,
                    tombstoned: sqlite3_column_int(statement, 11) != 0,
                    localStateVersion: Int(sqlite3_column_int64(statement, 12)),
                    localStatePayload: Self.data(statement, 13))
            }
        guard let row else { return nil }
        let source = try readCurrentSourceFingerprint(
            domain: .conversations,
            sourceIdentity: row.sourceIdentity,
            entityID: id,
            requiresOperativeState: true)
        let expectedEventCount = Int(try scalarInt(
            "SELECT COUNT(*) FROM conversation_events WHERE conversation_id = ?1",
            [.text(id.uuidString)]))
        var events: [ShadowLibraryEventSnapshot] = []
        events.reserveCapacity(expectedEventCount)
        try query(
            """
            SELECT id, capture_sequence, kind, actor_id, target_id, observed_at, provider_at,
                   producing_event_id, causal_event_id, payload_version, payload
            FROM conversation_events WHERE conversation_id = ?1 ORDER BY capture_sequence
            """,
            [.text(id.uuidString)]) { statement in
                guard let rawID = Self.optionalText(statement, 0),
                      let eventID = UUID(uuidString: rawID),
                      let kind = Self.optionalText(statement, 2) else {
                    throw SQLiteLibraryStoreError.sqlite(
                        "Conversation \(id.uuidString) contains a malformed event row")
                }
                let producingEventID = try Self.optionalUUID(
                    statement, 7, label: "producing event id")
                let causalEventID = try Self.optionalUUID(
                    statement, 8, label: "causal event id")
                events.append(ShadowLibraryEventSnapshot(
                    id: eventID,
                    captureSequence: sqlite3_column_int64(statement, 1),
                    kind: kind,
                    actorID: Self.optionalText(statement, 3),
                    targetID: Self.optionalText(statement, 4),
                    observedAt: Self.optionalDate(statement, 5),
                    providerAt: Self.optionalDate(statement, 6),
                    producingEventID: producingEventID,
                    causalEventID: causalEventID,
                    payloadVersion: Int(sqlite3_column_int64(statement, 9)),
                    payload: Self.data(statement, 10)))
            }
        guard events.count == expectedEventCount else {
            throw SQLiteLibraryStoreError.sqlite(
                "Conversation event read count disagrees with SQLite")
        }
        let expectedNestedArtifactCount = Int(try scalarInt(
            "SELECT COUNT(*) FROM conversation_artifact_snapshots WHERE conversation_id = ?1",
            [.text(id.uuidString)]))
        var nestedArtifacts: [ShadowLibraryNestedArtifactSnapshot] = []
        nestedArtifacts.reserveCapacity(expectedNestedArtifactCount)
        try query(
            """
            SELECT artifact_id, canonical_payload, canonical_payload_digest,
                   content_digest, content_byte_count
            FROM conversation_artifact_snapshots
            WHERE conversation_id = ?1 ORDER BY ordinal
            """,
            [.text(id.uuidString)]) { statement in
                guard let rawID = Self.optionalText(statement, 0),
                      let artifactID = UUID(uuidString: rawID),
                      let payloadDigest = Self.optionalText(statement, 2),
                      let contentDigest = Self.optionalText(statement, 3) else {
                    throw SQLiteLibraryStoreError.sqlite(
                        "Conversation \(id.uuidString) contains a malformed nested Artifact row")
                }
                nestedArtifacts.append(ShadowLibraryNestedArtifactSnapshot(
                    artifactID: artifactID,
                    canonicalPayload: Self.data(statement, 1),
                    canonicalPayloadDigest: payloadDigest,
                    contentDigest: contentDigest,
                    contentByteCount: Int(sqlite3_column_int64(statement, 4))))
            }
        guard nestedArtifacts.count == expectedNestedArtifactCount else {
            throw SQLiteLibraryStoreError.sqlite(
                "nested Artifact read count disagrees with SQLite")
        }
        return ShadowLibraryConversationSnapshot(
            id: id, title: row.title, titleSource: row.titleSource, cwd: row.cwd,
            workspaceID: row.workspaceID, updatedAt: row.updatedAt, favorite: row.favorite,
            sortIndex: row.sortIndex, unread: row.unread, errored: row.errored,
            revision: row.revision, tombstoned: row.tombstoned,
            localStateVersion: row.localStateVersion, localStatePayload: row.localStatePayload,
            source: source, events: events, nestedArtifacts: nestedArtifacts)
    }

    private func readArtifactSnapshot(id: UUID) throws -> ShadowLibraryArtifactSnapshot? {
        var result: ShadowLibraryArtifactSnapshot?
        try query(
            """
            SELECT title, artifact_type, origin, workspace_id, provenance_conversation_id,
                   conversation_title_snapshot, cwd, favorite, created_at, updated_at, revision,
                   producer_task_id, raw_source_payload, canonical_payload,
                   canonical_payload_digest, content, content_digest, content_byte_count,
                   payload_media_type, source_identity, tombstoned
            FROM artifacts WHERE id = ?1
            """,
            [.text(id.uuidString)]) { statement in
                guard result == nil else {
                    throw SQLiteLibraryStoreError.sqlite(
                        "duplicate Artifact row for \(id.uuidString)")
                }
                guard let title = Self.optionalText(statement, 0),
                      let type = Self.optionalText(statement, 1),
                      let origin = Self.optionalText(statement, 2),
                      let rawWorkspaceID = Self.optionalText(statement, 3),
                      let workspaceID = UUID(uuidString: rawWorkspaceID),
                      let titleSnapshot = Self.optionalText(statement, 5),
                      let cwd = Self.optionalText(statement, 6),
                      let payloadDigest = Self.optionalText(statement, 14),
                      let contentDigest = Self.optionalText(statement, 16),
                      let mediaType = Self.optionalText(statement, 18),
                      let sourceIdentity = Self.optionalText(statement, 19) else {
                    throw SQLiteLibraryStoreError.sqlite(
                        "Artifact row \(id.uuidString) is malformed")
                }
                let provenanceConversationID = try Self.optionalUUID(
                    statement, 4, label: "Artifact provenance Conversation id")
                let source = try readCurrentSourceFingerprint(
                    domain: .artifactMedia,
                    sourceIdentity: sourceIdentity,
                    entityID: id)
                result = ShadowLibraryArtifactSnapshot(
                    id: id, title: title, type: type, origin: origin, workspaceID: workspaceID,
                    provenanceConversationID: provenanceConversationID,
                    conversationTitleSnapshot: titleSnapshot, cwd: cwd,
                    favorite: sqlite3_column_int(statement, 7) != 0,
                    createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 8)),
                    updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 9)),
                    revision: Int(sqlite3_column_int64(statement, 10)),
                    tombstoned: sqlite3_column_int(statement, 20) != 0,
                    producerTaskID: Self.optionalText(statement, 11),
                    rawSourcePayload: Self.data(statement, 12),
                    canonicalPayload: Self.data(statement, 13),
                    canonicalPayloadDigest: payloadDigest,
                    content: Self.data(statement, 15), contentDigest: contentDigest,
                    contentByteCount: Int(sqlite3_column_int64(statement, 17)),
                    payloadMediaType: mediaType, source: source)
            }
        return result
    }

    private func readRetainedByteInventory() throws -> [ShadowLibraryRetainedByteSnapshot] {
        var result: [ShadowLibraryRetainedByteSnapshot] = []
        try query(
            """
            SELECT source_identity, kind, owner_conversation_id, storage_name, observed_revision,
                   digest, byte_count, media_type, link_state, diagnostics, storage_class,
                   storage_state, storage_identity, retention_state, managed_blob_digest,
                   disposition
            FROM retained_byte_sources ORDER BY source_identity
            """,
            []) { statement in
                result.append(try readRetainedByteSnapshot(statement))
            }
        return result
    }

    /// Read only the retained rows that claim to be live references owned by this Conversation.
    /// Comparing this complete set with the reference table catches both a dangling edge and an
    /// adopted source whose edge disappeared, without walking the full retained-byte inventory.
    private func readReferencedRetainedByteSources(
        ownerConversationID: UUID
    ) throws -> [ShadowLibraryRetainedByteSnapshot] {
        var result: [ShadowLibraryRetainedByteSnapshot] = []
        try query(
            """
            SELECT source_identity, kind, owner_conversation_id, storage_name, observed_revision,
                   digest, byte_count, media_type, link_state, diagnostics, storage_class,
                   storage_state, storage_identity, retention_state, managed_blob_digest,
                   disposition
            FROM retained_byte_sources
            WHERE owner_conversation_id = ?1 AND disposition = 'referenced'
            ORDER BY source_identity
            """,
            [.text(ownerConversationID.uuidString)]) { statement in
                result.append(try readRetainedByteSnapshot(statement))
            }
        return result
    }

    private func readRetainedByteSnapshot(
        _ statement: OpaquePointer
    ) throws -> ShadowLibraryRetainedByteSnapshot {
        guard let identity = Self.optionalText(statement, 0),
              let rawKind = Self.optionalText(statement, 1),
              let kind = ShadowLibraryRetainedByteSnapshot.Kind(rawValue: rawKind),
              let storageName = Self.optionalText(statement, 3),
              let revision = Self.optionalText(statement, 4),
              let digest = Self.optionalText(statement, 5),
              let mediaType = Self.optionalText(statement, 7),
              let rawLinkState = Self.optionalText(statement, 8),
              let linkState = ShadowLibraryRetainedByteSnapshot.LinkState(rawValue: rawLinkState),
              let rawStorageClass = Self.optionalText(statement, 10),
              let storageClass = ShadowLibraryRetainedByteSnapshot.StorageClass(rawValue: rawStorageClass),
              let rawStorageState = Self.optionalText(statement, 11),
              let storageState = ShadowLibraryRetainedByteSnapshot.StorageState(rawValue: rawStorageState),
              let storageIdentity = Self.optionalText(statement, 12),
              let rawRetentionState = Self.optionalText(statement, 13),
              let retentionState = ShadowLibraryRetainedByteSnapshot.RetentionState(rawValue: rawRetentionState),
              let rawDisposition = Self.optionalText(statement, 15),
              let disposition = ShadowLibraryRetainedByteSnapshot.Disposition(rawValue: rawDisposition)
        else {
            throw SQLiteLibraryStoreError.sqlite("retained-byte inventory row is malformed")
        }
        let ownerConversationID = try Self.optionalUUID(
            statement, 2, label: "retained-byte owner Conversation id")
        let retained = ShadowLibraryRetainedByteSnapshot(
            kind: kind,
            ownerConversationID: ownerConversationID,
            storageName: storageName, mediaType: mediaType, linkState: linkState,
            diagnostics: Self.optionalText(statement, 9),
            source: ShadowLibrarySourceFingerprint(
                identity: identity, revision: revision, digest: digest,
                byteCount: Int(sqlite3_column_int64(statement, 6))),
            storageClass: storageClass, storageState: storageState,
            storageIdentity: storageIdentity, retentionState: retentionState,
            disposition: disposition,
            managedBlobDigest: Self.optionalText(statement, 14))
        try validate(retainedByte: retained)
        return retained
    }

    // MARK: - Opening and schema

    private func openVerifiedReadOnlyShadow() throws {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw SQLiteLibraryStoreError.sqlite("library.db is absent")
        }
        do {
            try openDatabase(readOnly: true)
            try verifyExactReadOnlySchema()
            try verifyIntegrityReadOnly()
        } catch {
            closeDatabase()
            throw error
        }
    }

    private func openOrReset() throws {
        let existed = FileManager.default.fileExists(atPath: databaseURL.path)
        resetAuthorizedForOpen = false
        do {
            try openDatabase()
            if existed {
                try verifyExistingSchema()
                // Persistent connection policy is applied only after application id, authority
                // state, and schema ownership prove this is our disposable shadow database.
                try configureOwnedDatabase()
                try ensureResetMarker()
            } else {
                try configureOwnedDatabase()
                try createSchema(resetReason: nil)
            }
            _ = try verifyIntegrityAndRecord()
            try applyOwnerOnlyFilePermissions()
        } catch {
            closeDatabase()
            if case SQLiteLibraryStoreError.protectedDatabase = error { throw error }
            guard !existed || resetAuthorizedForOpen else {
                throw SQLiteLibraryStoreError.protectedDatabase(
                    "the file is not proven to be a disposable L1 shadow candidate")
            }
            try deleteDatabaseFiles()
            resetReason = existed ? Self.resetDescription(for: error) : nil
            do {
                try openDatabase()
                try configureOwnedDatabase()
                try createSchema(resetReason: resetReason)
                _ = try verifyIntegrityAndRecord()
                try applyOwnerOnlyFilePermissions()
            } catch {
                closeDatabase()
                throw error
            }
        }
    }

    private func openDatabase(
        readOnly: Bool = false,
        createIfMissing: Bool = true
    ) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            (readOnly
                ? SQLITE_OPEN_READONLY
                : SQLITE_OPEN_READWRITE | (createIfMissing ? SQLITE_OPEN_CREATE : 0))
                | SQLITE_OPEN_NOMUTEX,
            nil)
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteLibraryStoreError.sqlite("could not open \(databaseURL.lastPathComponent)")
        }
        db = handle
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 2_000)
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA trusted_schema = OFF")
        if readOnly { try execute("PRAGMA query_only = ON") }
    }

    /// Exact active-schema proof using bounded metadata and migration-ledger queries only. Page and
    /// relationship scans are deliberately deferred until after product readiness; activation
    /// itself required a current full integrity receipt, while every authoritative transaction
    /// continues to run with SQLite foreign keys enabled.
    private func verifyExactActiveSchema(marker: StorageAuthorityMarker) throws {
        guard marker.mode == .sqlite,
              marker.databaseName == StorageAuthorityProtocol.databaseName,
              marker.schemaVersion == Self.schemaVersion else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "SQLite authority marker is not supported by this repository")
        }
        try verifyExactHeaderAndMigrationLedger(label: "active")
        let metadata = try readAuthorityMetadata()
        guard metadata.databaseInstanceID == marker.databaseInstanceID,
              metadata.schemaVersion == marker.schemaVersion,
              metadata.authorityState == .active,
              metadata.activationID == marker.activationID,
              metadata.minimumWriterBuild == marker.minimumWriterBuild else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "active database metadata does not match the root marker")
        }
    }

    private func verifyExactInterruptedAuthoritySchema(
        probe: StorageAuthorityDatabaseProbe
    ) throws {
        guard probe.schemaVersion == Self.schemaVersion,
              probe.authorityState == .prepared || probe.authorityState == .active,
              let activationID = probe.activationID,
              probe.minimumWriterBuild == StorageAuthorityProtocol.recognitionID else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "interrupted authority metadata is not resumable by this repository")
        }
        try verifyExactHeaderAndMigrationLedger(label: "interrupted authority")
        let metadata = try readAuthorityMetadata()
        guard metadata.databaseInstanceID == probe.databaseInstanceID,
              metadata.schemaVersion == probe.schemaVersion,
              metadata.authorityState == probe.authorityState,
              metadata.activationID == activationID,
              metadata.minimumWriterBuild == probe.minimumWriterBuild,
              metadata.rollbackID == nil,
              metadata.committedSequence == probe.committedSequence else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "interrupted authority database changed after read-only recognition")
        }
    }

    private func verifyExactHeaderAndMigrationLedger(label: String) throws {
        guard try scalarInt("PRAGMA application_id") == Int64(Self.applicationID),
              try scalarInt("PRAGMA user_version") == Int64(Self.schemaVersion) else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "\(label) database header does not match schema v\(Self.schemaVersion)")
        }
        let expectedChecksums = [
            1: Self.schemaV2Checksum,
            2: Self.schemaV3Checksum,
            3: Self.schemaV4Checksum,
            4: Self.schemaV5Checksum,
            5: Self.schemaV6Checksum,
            6: Self.schemaV7Checksum,
            7: Self.schemaV8Checksum,
            8: Self.schemaV9Checksum,
            9: Self.schemaV10Checksum,
            10: Self.schemaV11Checksum,
            11: Self.schemaV12Checksum,
            12: Self.schemaV13Checksum,
            13: Self.schemaV14Checksum,
            14: Self.schemaV15Checksum,
        ]
        var observed: [Int: String] = [:]
        try query(
            "SELECT migration_id, checksum FROM schema_migrations ORDER BY migration_id",
            []) { statement in
                guard let checksum = Self.optionalText(statement, 1) else {
                    throw SQLiteLibraryStoreError.sqlite(
                        "\(label) schema migration checksum is malformed")
                }
                observed[Int(sqlite3_column_int64(statement, 0))] = checksum
            }
        guard observed == expectedChecksums else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "\(label) schema migration ledger does not match schema v\(Self.schemaVersion)")
        }
    }

    /// Unlike the writable opener this validator never migrates or resets. A prior/newer schema,
    /// missing reset proof, or non-shadow authority is simply unavailable to A2b launch rehearsal.
    private func verifyExactReadOnlySchema() throws {
        guard try scalarInt("PRAGMA application_id") == Int64(Self.applicationID) else {
            throw SQLiteLibraryStoreError.protectedDatabase("application id mismatch")
        }
        guard try scalarInt("PRAGMA user_version") == Int64(Self.schemaVersion) else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "launch inventory requires schema v\(Self.schemaVersion)")
        }
        var instanceID: UUID?
        var schemaVersion: Int?
        var applicationID: Int64?
        var authorityState: String?
        try query(
            """
            SELECT database_instance_id, schema_version, application_id, authority_state
            FROM library_metadata WHERE singleton = 1
            """,
            []) { statement in
                guard instanceID == nil else {
                    throw SQLiteLibraryStoreError.sqlite(
                        "library metadata singleton is duplicated")
                }
                instanceID = Self.optionalText(statement, 0).flatMap(UUID.init(uuidString:))
                schemaVersion = Int(sqlite3_column_int64(statement, 1))
                applicationID = sqlite3_column_int64(statement, 2)
                authorityState = Self.optionalText(statement, 3)
            }
        guard let instanceID,
              schemaVersion == Self.schemaVersion,
              applicationID == Int64(Self.applicationID),
              authorityState == LibraryAuthorityState.shadow.rawValue else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "library metadata is not an exact schema-v\(Self.schemaVersion) shadow")
        }
        guard resetMarkerMatches(databaseInstanceID: instanceID) else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "the disposable shadow reset marker is missing or mismatched")
        }
        let expectedChecksums = [
            1: Self.schemaV2Checksum,
            2: Self.schemaV3Checksum,
            3: Self.schemaV4Checksum,
            4: Self.schemaV5Checksum,
            5: Self.schemaV6Checksum,
            6: Self.schemaV7Checksum,
            7: Self.schemaV8Checksum,
            8: Self.schemaV9Checksum,
            9: Self.schemaV10Checksum,
            10: Self.schemaV11Checksum,
            11: Self.schemaV12Checksum,
            12: Self.schemaV13Checksum,
            13: Self.schemaV14Checksum,
            14: Self.schemaV15Checksum,
        ]
        var observed: [Int: String] = [:]
        try query(
            "SELECT migration_id, checksum FROM schema_migrations ORDER BY migration_id",
            []) { statement in
                guard let checksum = Self.optionalText(statement, 1) else {
                    throw SQLiteLibraryStoreError.sqlite(
                        "schema migration checksum is malformed")
                }
                observed[Int(sqlite3_column_int64(statement, 0))] = checksum
            }
        guard observed == expectedChecksums else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "schema migration ledger does not match schema v\(Self.schemaVersion)")
        }
    }

    private func verifyIntegrityReadOnly() throws {
        let quickCheck = try scalarText("PRAGMA quick_check")
        guard quickCheck == "ok" else {
            throw SQLiteLibraryStoreError.sqlite("quick_check failed: \(quickCheck)")
        }
        var foreignKeyViolationCount = 0
        try query("PRAGMA foreign_key_check", []) { _ in foreignKeyViolationCount += 1 }
        guard foreignKeyViolationCount == 0 else {
            throw SQLiteLibraryStoreError.sqlite(
                "foreign_key_check reported \(foreignKeyViolationCount) violation(s)")
        }
    }

    /// `journal_mode` persists in the database header. Never call this until a pre-existing file
    /// has proven shadow ownership, otherwise merely inspecting an unknown/future database can
    /// mutate it or create WAL/SHM sidecars.
    private func configureOwnedDatabase() throws {
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = FULL")
    }

    private func verifyExistingSchema() throws {
        let applicationID = try scalarInt("PRAGMA application_id")
        guard applicationID == Int64(Self.applicationID) else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "application id mismatch (found \(applicationID))")
        }
        var authorityState: String?
        var databaseInstanceID: UUID?
        try query(
            "SELECT authority_state, database_instance_id FROM library_metadata WHERE singleton = 1",
            []) {
                authorityState = Self.optionalText($0, 0)
                databaseInstanceID = Self.optionalText($0, 1).flatMap(UUID.init(uuidString:))
            }
        guard authorityState == "shadow" else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "authority state is \(authorityState ?? "unknown"), not disposable shadow")
        }
        guard let databaseInstanceID else {
            throw SQLiteLibraryStoreError.sqlite("library database instance id is invalid")
        }
        resetAuthorizedForOpen = resetMarkerMatches(databaseInstanceID: databaseInstanceID)
        var version = try scalarInt("PRAGMA user_version")
        guard version == 2 || version == 3 || version == 4 || version == 5 || version == 6
                || version == 7 || version == 8 || version == 9 || version == 10
                || version == 11 || version == 12 || version == 13
                || version == 14
                || version == Int64(Self.schemaVersion) else {
            throw SQLiteLibraryStoreError.sqlite(
                "schema version mismatch (found \(version))")
        }
        var checksum: String?
        try query(
            "SELECT checksum FROM schema_migrations WHERE migration_id = 1",
            []) { checksum = Self.optionalText($0, 0) }
        guard checksum == Self.schemaV2Checksum else {
            throw SQLiteLibraryStoreError.sqlite("schema migration 1 checksum mismatch")
        }
        if version == 2 {
            try migrateV2ToV3()
            version = 3
        }
        checksum = nil
        try query(
            "SELECT checksum FROM schema_migrations WHERE migration_id = 2",
            []) { checksum = Self.optionalText($0, 0) }
        guard checksum == Self.schemaV3Checksum else {
            throw SQLiteLibraryStoreError.sqlite("schema migration 2 checksum mismatch")
        }
        if version == 3 {
            try migrateV3ToV4()
            version = 4
        }
        checksum = nil
        try query(
            "SELECT checksum FROM schema_migrations WHERE migration_id = 3",
            []) { checksum = Self.optionalText($0, 0) }
        guard checksum == Self.schemaV4Checksum else {
            throw SQLiteLibraryStoreError.sqlite("schema migration 3 checksum mismatch")
        }
        if version == 4 {
            try migrateV4ToV5()
            version = 5
        }
        checksum = nil
        try query(
            "SELECT checksum FROM schema_migrations WHERE migration_id = 4",
            []) { checksum = Self.optionalText($0, 0) }
        guard checksum == Self.schemaV5Checksum else {
            throw SQLiteLibraryStoreError.sqlite("schema migration 4 checksum mismatch")
        }
        if version == 5 {
            try migrateV5ToV6()
            version = 6
        }
        checksum = nil
        try query(
            "SELECT checksum FROM schema_migrations WHERE migration_id = 5",
            []) { checksum = Self.optionalText($0, 0) }
        guard checksum == Self.schemaV6Checksum else {
            throw SQLiteLibraryStoreError.sqlite("schema migration 5 checksum mismatch")
        }
        if version == 6 {
            try migrateV6ToV7()
            version = 7
        }
        checksum = nil
        try query(
            "SELECT checksum FROM schema_migrations WHERE migration_id = 6",
            []) { checksum = Self.optionalText($0, 0) }
        guard checksum == Self.schemaV7Checksum else {
            throw SQLiteLibraryStoreError.sqlite("schema migration 6 checksum mismatch")
        }
        if version == 7 {
            try migrateV7ToV8()
            version = 8
        }
        checksum = nil
        try query(
            "SELECT checksum FROM schema_migrations WHERE migration_id = 7",
            []) { checksum = Self.optionalText($0, 0) }
        guard checksum == Self.schemaV8Checksum else {
            throw SQLiteLibraryStoreError.sqlite("schema migration 7 checksum mismatch")
        }
        if version == 8 {
            try migrateV8ToV9()
            version = 9
        }
        checksum = nil
        try query(
            "SELECT checksum FROM schema_migrations WHERE migration_id = 8",
            []) { checksum = Self.optionalText($0, 0) }
        guard checksum == Self.schemaV9Checksum else {
            throw SQLiteLibraryStoreError.sqlite("schema migration 8 checksum mismatch")
        }
        if version == 9 {
            try migrateV9ToV10()
            version = 10
        }
        checksum = nil
        try query(
            "SELECT checksum FROM schema_migrations WHERE migration_id = 9",
            []) { checksum = Self.optionalText($0, 0) }
        guard checksum == Self.schemaV10Checksum else {
            throw SQLiteLibraryStoreError.sqlite("schema migration 9 checksum mismatch")
        }
        if version == 10 {
            try migrateV10ToV11()
            version = 11
        }
        checksum = nil
        try query(
            "SELECT checksum FROM schema_migrations WHERE migration_id = 10",
            []) { checksum = Self.optionalText($0, 0) }
        guard checksum == Self.schemaV11Checksum else {
            throw SQLiteLibraryStoreError.sqlite("schema migration 10 checksum mismatch")
        }
        if version == 11 {
            try migrateV11ToV12()
            version = 12
        }
        checksum = nil
        try query(
            "SELECT checksum FROM schema_migrations WHERE migration_id = 11",
            []) { checksum = Self.optionalText($0, 0) }
        guard checksum == Self.schemaV12Checksum else {
            throw SQLiteLibraryStoreError.sqlite("schema migration 11 checksum mismatch")
        }
        if version == 12 {
            try migrateV12ToV13()
            version = 13
        }
        checksum = nil
        try query(
            "SELECT checksum FROM schema_migrations WHERE migration_id = 12",
            []) { checksum = Self.optionalText($0, 0) }
        guard checksum == Self.schemaV13Checksum else {
            throw SQLiteLibraryStoreError.sqlite("schema migration 12 checksum mismatch")
        }
        if version == 13 {
            try migrateV13ToV14()
            version = 14
        }
        checksum = nil
        try query(
            "SELECT checksum FROM schema_migrations WHERE migration_id = 13",
            []) { checksum = Self.optionalText($0, 0) }
        guard checksum == Self.schemaV14Checksum else {
            throw SQLiteLibraryStoreError.sqlite("schema migration 13 checksum mismatch")
        }
        if version == 14 {
            try migrateV14ToV15()
            version = 15
        }
        checksum = nil
        try query(
            "SELECT checksum FROM schema_migrations WHERE migration_id = 14",
            []) { checksum = Self.optionalText($0, 0) }
        guard checksum == Self.schemaV15Checksum else {
            throw SQLiteLibraryStoreError.sqlite("schema migration 14 checksum mismatch")
        }
        guard try scalarInt(
            "SELECT schema_version FROM library_metadata WHERE singleton = 1")
            == Int64(Self.schemaVersion) else {
            throw SQLiteLibraryStoreError.sqlite("library metadata schema version mismatch")
        }
    }

    /// Provision a fresh authority, running the ladder up to `throughVersion`.
    ///
    /// The parameter exists because the destructive v14 rung cannot be tested by merely dropping
    /// what a later schema adds. Its previous-version fixture must build the genuine historical
    /// shape before v14 removes 24 tables and 62 triggers. A fixture that hand-builds that shape is
    /// how a green suite stops meaning anything, so the production ladder can provision through a
    /// requested version for that test.
    ///
    /// It defaults to the current version and is never passed anything else outside tests. A value
    /// below `lowestUpgradableSchemaVersion`, or above the current version, is a programming error
    /// rather than a recoverable state.
    private func createSchema(
        resetReason: String?,
        throughVersion: Int = SQLiteLibraryStore.schemaVersion
    ) throws {
        precondition(
            throughVersion >= Self.lowestUpgradableSchemaVersion
                && throughVersion <= Self.schemaVersion,
            "cannot provision at schema v\(throughVersion)")
        let instanceID = UUID()
        try transaction(tracksMutation: false, requiresShadow: false) {
            for statement in Self.schemaV2Statements { try execute(statement) }
            try execute("PRAGMA application_id = \(Self.applicationID)")
            try execute("PRAGMA user_version = 2")
            try execute(
                """
                INSERT INTO library_metadata (
                  singleton, database_instance_id, schema_version, application_id,
                  authority_state, committed_sequence, shadow_change_sequence,
                  integrity_checked_sequence, integrity_checked_at, integrity_result,
                  created_at, last_reset_reason)
                VALUES (1, ?1, 2, ?2, 'shadow', 0, 0, NULL, NULL, NULL, ?3, ?4)
                """,
                [
                    .text(instanceID.uuidString), .int(Int64(Self.applicationID)),
                    .double(Date().timeIntervalSinceReferenceDate),
                    resetReason.map(SQLiteValue.text) ?? .null,
                ])
            try execute(
                """
                INSERT INTO schema_migrations (
                  migration_id, checksum, app_build, completed_at)
                VALUES (1, ?1, 'L1b1', ?2)
                """,
                [
                    .text(Self.schemaV2Checksum),
                    .double(Date().timeIntervalSinceReferenceDate),
                ])
            // The reserved Home row exists even before the first legacy Home-settings import, so
            // every imported Conversation can have exactly one non-null membership.
            try execute(
                """
                INSERT INTO workspaces (
                  id, kind, name, goal, instructions, cwd, favorite, sort_index, icon_symbol,
                  color_hex, created_at, updated_at, revision, source_identity)
                VALUES (?1, 'home', 'Home', '', '', '', 0, NULL, NULL, NULL, ?2, ?2, 0, NULL)
                """,
                [
                    .text(Self.homeWorkspaceID.uuidString),
                    .double(Date().timeIntervalSinceReferenceDate),
                ])
            if throughVersion >= 3 { try applyV3MigrationStatements() }
            if throughVersion >= 4 { try applyV4MigrationStatements() }
            if throughVersion >= 5 { try applyV5MigrationStatements() }
            if throughVersion >= 6 { try applyV6MigrationStatements() }
            if throughVersion >= 7 { try applyV7MigrationStatements() }
            if throughVersion >= 8 { try applyV8MigrationStatements() }
            if throughVersion >= 9 { try applyV9MigrationStatements() }
            if throughVersion >= 10 { try applyV10MigrationStatements() }
            if throughVersion >= 11 { try applyV11MigrationStatements() }
            if throughVersion >= 12 { try applyV12MigrationStatements() }
            if throughVersion >= 13 { try applyV13MigrationStatements() }
            if throughVersion >= 14 { try applyV14MigrationStatements() }
            if throughVersion >= 15 { try applyV15MigrationStatements() }
        }
        try writeResetMarker(databaseInstanceID: instanceID)
    }

    private func migrateV2ToV3() throws {
        try transaction(tracksMutation: false, requiresShadow: false) {
            try applyV3MigrationStatements()
        }
    }

    private func migrateV3ToV4() throws {
        try transaction(tracksMutation: false, requiresShadow: false) {
            try applyV4MigrationStatements()
        }
    }

    private func migrateV4ToV5() throws {
        try transaction(tracksMutation: false, requiresShadow: false) {
            try applyV5MigrationStatements()
        }
    }

    private func migrateV5ToV6() throws {
        try transaction(tracksMutation: false, requiresShadow: false) {
            try applyV6MigrationStatements()
        }
    }

    private func migrateV6ToV7() throws {
        try transaction(tracksMutation: false, requiresShadow: false) {
            try applyV7MigrationStatements()
        }
    }

    private func migrateV7ToV8() throws {
        try transaction(tracksMutation: false, requiresShadow: false) {
            try applyV8MigrationStatements()
        }
    }

    private func migrateV8ToV9() throws {
        try transaction(tracksMutation: false, requiresShadow: false) {
            try applyV9MigrationStatements()
        }
    }

    private func migrateV9ToV10() throws {
        try transaction(tracksMutation: false, requiresShadow: false) {
            try applyV10MigrationStatements()
        }
    }

    private func migrateV10ToV11() throws {
        try transaction(tracksMutation: false, requiresShadow: false) {
            try applyV11MigrationStatements()
        }
    }

    private func migrateV11ToV12() throws {
        try transaction(tracksMutation: false, requiresShadow: false) {
            try applyV12MigrationStatements()
        }
    }

    private func migrateV12ToV13() throws {
        try transaction(tracksMutation: false, requiresShadow: false) {
            try applyV13MigrationStatements()
        }
    }

    private func migrateV13ToV14() throws {
        try transaction(tracksMutation: false, requiresShadow: false) {
            try applyV14MigrationStatements()
        }
    }

    private func migrateV14ToV15() throws {
        try transaction(tracksMutation: false, requiresShadow: false) {
            try applyV15MigrationStatements()
        }
    }

    private func applyV3MigrationStatements() throws {
        for statement in Self.schemaV3Statements { try execute(statement) }
        try execute(
            """
            INSERT INTO schema_migrations (migration_id, checksum, app_build, completed_at)
            VALUES (2, ?1, 'A1', ?2)
            """,
            [
                .text(Self.schemaV3Checksum),
                .double(Date().timeIntervalSinceReferenceDate),
            ])
        try execute("PRAGMA user_version = 3")
    }

    private func applyV4MigrationStatements() throws {
        for statement in Self.schemaV4Statements { try execute(statement) }
        try execute(
            """
            INSERT INTO schema_migrations (migration_id, checksum, app_build, completed_at)
            VALUES (3, ?1, 'A1-complete', ?2)
            """,
            [
                .text(Self.schemaV4Checksum),
                .double(Date().timeIntervalSinceReferenceDate),
            ])
        try execute("UPDATE library_metadata SET schema_version = 4 WHERE singleton = 1")
        try execute("PRAGMA user_version = 4")
    }

    private func applyV5MigrationStatements() throws {
        for statement in Self.schemaV5Statements { try execute(statement) }
        try execute(
            """
            INSERT INTO schema_migrations (migration_id, checksum, app_build, completed_at)
            VALUES (4, ?1, 'A1-unclaimed-recovery', ?2)
            """,
            [
                .text(Self.schemaV5Checksum),
                .double(Date().timeIntervalSinceReferenceDate),
            ])
        try execute(
            "UPDATE library_metadata SET schema_version = 5 WHERE singleton = 1")
        try execute("PRAGMA user_version = 5")
    }

    private func applyV6MigrationStatements() throws {
        for statement in Self.schemaV6Statements { try execute(statement) }
        try execute(
            """
            INSERT INTO schema_migrations (migration_id, checksum, app_build, completed_at)
            VALUES (5, ?1, 'A2b2-projection-outbox', ?2)
            """,
            [
                .text(Self.schemaV6Checksum),
                .double(Date().timeIntervalSinceReferenceDate),
            ])
        try execute(
            "UPDATE library_metadata SET schema_version = 6 WHERE singleton = 1")
        // Literal 6, not `Self.schemaVersion`. This step lands a v6 database and is followed by the
        // v7 step; interpolating the current version here would stamp a half-migrated file as
        // fully current the moment a later version is added.
        try execute("PRAGMA user_version = 6")
    }

    private func applyV7MigrationStatements() throws {
        for statement in Self.schemaV7Statements { try execute(statement) }
        try execute(
            """
            INSERT INTO schema_migrations (migration_id, checksum, app_build, completed_at)
            VALUES (6, ?1, 'FR-241-memory', ?2)
            """,
            [
                .text(Self.schemaV7Checksum),
                .double(Date().timeIntervalSinceReferenceDate),
            ])
        try execute(
            "UPDATE library_metadata SET schema_version = 7 WHERE singleton = 1")
        // Literal 7 for the same reason v6's step uses a literal 6. This originally interpolated
        // `Self.schemaVersion`, which was harmless only while 7 WAS the current version; the moment
        // v8 landed it would have stamped a half-migrated v7 file as fully current.
        try execute("PRAGMA user_version = 7")
    }

    private func applyV8MigrationStatements() throws {
        for statement in Self.schemaV8Statements { try execute(statement) }
        try execute(
            """
            INSERT INTO schema_migrations (migration_id, checksum, app_build, completed_at)
            VALUES (7, ?1, 'FR-241-page-identity', ?2)
            """,
            [
                .text(Self.schemaV8Checksum),
                .double(Date().timeIntervalSinceReferenceDate),
            ])
        try execute(
            "UPDATE library_metadata SET schema_version = 8 WHERE singleton = 1")
        try execute("PRAGMA user_version = 8")
    }

    private func applyV9MigrationStatements() throws {
        for statement in Self.schemaV9Statements { try execute(statement) }
        try execute(
            """
            INSERT INTO schema_migrations (migration_id, checksum, app_build, completed_at)
            VALUES (8, ?1, 'FR-265-tombstone-statement', ?2)
            """,
            [
                .text(Self.schemaV9Checksum),
                .double(Date().timeIntervalSinceReferenceDate),
            ])
        try execute(
            "UPDATE library_metadata SET schema_version = 9 WHERE singleton = 1")
        // The LITERAL version, never `Self.schemaVersion`: when v9 was written that constant was
        // already 9, and using it would stamp a half-migrated file as current the moment v10 lands.
        try execute("PRAGMA user_version = 9")
    }

    private func applyV10MigrationStatements() throws {
        for statement in Self.schemaV10Statements { try execute(statement) }
        try execute(
            """
            INSERT INTO schema_migrations (migration_id, checksum, app_build, completed_at)
            VALUES (9, ?1, 'FR-344-memrank-feedback', ?2)
            """,
            [
                .text(Self.schemaV10Checksum),
                .double(Date().timeIntervalSinceReferenceDate),
            ])
        try execute(
            "UPDATE library_metadata SET schema_version = 10 WHERE singleton = 1")
        try execute("PRAGMA user_version = 10")
    }

    private func applyV11MigrationStatements() throws {
        for statement in Self.schemaV11Statements { try execute(statement) }
        try execute(
            """
            INSERT INTO schema_migrations (migration_id, checksum, app_build, completed_at)
            VALUES (10, ?1, 'FR-344-memory-relationships', ?2)
            """,
            [
                .text(Self.schemaV11Checksum),
                .double(Date().timeIntervalSinceReferenceDate),
            ])
        try execute(
            "UPDATE library_metadata SET schema_version = 11 WHERE singleton = 1")
        try execute("PRAGMA user_version = 11")
    }

    private func applyV12MigrationStatements() throws {
        for statement in Self.schemaV12Statements { try execute(statement) }
        try execute(
            """
            INSERT INTO schema_migrations (migration_id, checksum, app_build, completed_at)
            VALUES (11, ?1, 'FR-344-memory-archive-truth', ?2)
            """,
            [
                .text(Self.schemaV12Checksum),
                .double(Date().timeIntervalSinceReferenceDate),
            ])
        try execute(
            "UPDATE library_metadata SET schema_version = 12 WHERE singleton = 1")
        try execute("PRAGMA user_version = 12")
    }

    private func applyV13MigrationStatements() throws {
        for statement in Self.schemaV13Statements { try execute(statement) }
        try execute(
            """
            INSERT INTO schema_migrations (migration_id, checksum, app_build, completed_at)
            VALUES (12, ?1, 'learning-authority-v1', ?2)
            """,
            [
                .text(Self.schemaV13Checksum),
                .double(Date().timeIntervalSinceReferenceDate),
            ])
        try execute(
            "UPDATE library_metadata SET schema_version = 13 WHERE singleton = 1")
        try execute("PRAGMA user_version = 13")
    }

    private func applyV14MigrationStatements() throws {
        for statement in Self.schemaV14Statements { try execute(statement) }
        try execute(
            """
            INSERT INTO schema_migrations (migration_id, checksum, app_build, completed_at)
            VALUES (13, ?1, 'memory-removal-v1', ?2)
            """,
            [
                .text(Self.schemaV14Checksum),
                .double(Date().timeIntervalSinceReferenceDate),
            ])
        try execute(
            "UPDATE library_metadata SET schema_version = 14 WHERE singleton = 1")
        try execute("PRAGMA user_version = 14")
    }

    private func applyV15MigrationStatements() throws {
        for statement in Self.schemaV15Statements { try execute(statement) }
        try execute(
            """
            INSERT INTO schema_migrations (migration_id, checksum, app_build, completed_at)
            VALUES (14, ?1, 'conversation-work-evidence-v1', ?2)
            """,
            [
                .text(Self.schemaV15Checksum),
                .double(Date().timeIntervalSinceReferenceDate),
            ])
        try execute(
            "UPDATE library_metadata SET schema_version = 15 WHERE singleton = 1")
        try execute("PRAGMA user_version = 15")
    }

    // MARK: - Import implementation

    private func upsertAmbient(_ snapshot: ShadowLibraryAmbientSnapshot) throws {
        if try ambientSourceIsCurrent(snapshot) { return }
        try execute(
            """
            INSERT INTO ambient_authority_sources (
              kind, source_identity, payload_version, payload)
            VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(kind) DO UPDATE SET
              source_identity = excluded.source_identity,
              payload_version = excluded.payload_version,
              payload = excluded.payload
            """,
            [
                .text(snapshot.kind.rawValue), .text(snapshot.source.identity),
                .int(Int64(snapshot.payloadVersion)), .blob(snapshot.payload),
            ])
        try recordCurrentSource(
            domain: .ambientState,
            entityIdentity: snapshot.kind.rawValue,
            source: snapshot.source)
    }

    private func ambientSourceIsCurrent(_ snapshot: ShadowLibraryAmbientSnapshot) throws -> Bool {
        var current = false
        try query(
            """
            SELECT 1
            FROM ambient_authority_sources ambient
            JOIN migration_sources receipt
              ON receipt.domain = 'ambient_state'
             AND receipt.source_identity = ambient.source_identity
            WHERE ambient.kind = ?1 AND ambient.source_identity = ?2
              AND ambient.payload_version = ?3 AND ambient.payload = ?4
              AND receipt.entity_id = ?1
              AND receipt.observed_revision = ?5 AND receipt.observed_digest = ?6
              AND receipt.source_byte_count = ?7
              AND receipt.imported_revision = ?5 AND receipt.imported_digest = ?6
              AND receipt.dirty = 0 AND receipt.import_state = 'current'
            """,
            [
                .text(snapshot.kind.rawValue), .text(snapshot.source.identity),
                .int(Int64(snapshot.payloadVersion)), .blob(snapshot.payload),
                .text(snapshot.source.revision), .text(snapshot.source.digest),
                .int(Int64(snapshot.source.byteCount)),
            ]) { _ in current = true }
        return current
    }

    private func ambientIssueIsCurrent(_ issue: ShadowLibraryAmbientSourceIssue) throws -> Bool {
        try sourceIssueIsCurrent(
            domain: .ambientState,
            source: issue.source,
            entityIdentity: issue.entityIdentity,
            kind: issue.kind,
            diagnostics: issue.diagnostics)
    }

    private func sourceIssueIsCurrent(
        domain: ShadowLibraryDomain,
        source: ShadowLibrarySourceFingerprint,
        entityIdentity: String?,
        kind: ShadowLibrarySourceIssueKind,
        diagnostics: String
    ) throws -> Bool {
        var current = false
        try query(
            """
            SELECT 1 FROM migration_sources
            WHERE domain = ?1 AND source_identity = ?2
              AND entity_id = ?3 AND observed_revision = ?4 AND observed_digest = ?5
              AND source_byte_count = ?6 AND imported_revision IS NULL
              AND imported_digest IS NULL AND dirty = 1 AND import_state = ?7
              AND diagnostics = ?8
            """,
            [
                .text(domain.rawValue), .text(source.identity),
                .text(entityIdentity ?? "unparsed:\(source.digest)"),
                .text(source.revision), .text(source.digest),
                .int(Int64(source.byteCount)), .text(kind.rawValue), .text(diagnostics),
            ]) { _ in current = true }
        return current
    }

    private func ambientReconciliationIsCurrent(
        _ inventory: ShadowLibraryAmbientInventory,
        live: Set<String>
    ) throws -> Bool {
        for source in inventory.sources where try !ambientSourceIsCurrent(source) { return false }
        for issue in inventory.sourceIssues where try !ambientIssueIsCurrent(issue) { return false }
        guard inventory.hasCompleteCensus else { return false }
        guard try sourceCount(domain: .ambientState) == live.count else { return false }
        var markerMatches = false
        try query(
            """
            SELECT 1 FROM domain_reconciliation
            WHERE domain = 'ambient_state' AND expected_source_count = ?1
            """,
            [.int(Int64(live.count))]) { _ in markerMatches = true }
        return markerMatches
    }

    private func readAmbientSnapshots() throws -> [ShadowLibraryAmbientSnapshot] {
        var result: [ShadowLibraryAmbientSnapshot] = []
        try query(
            """
            SELECT ambient.kind, ambient.source_identity, ambient.payload_version, ambient.payload,
                   receipt.observed_revision, receipt.observed_digest, receipt.source_byte_count,
                   receipt.imported_revision, receipt.imported_digest, receipt.dirty,
                   receipt.import_state
            FROM ambient_authority_sources ambient
            JOIN migration_sources receipt
              ON receipt.domain = 'ambient_state'
             AND receipt.source_identity = ambient.source_identity
            ORDER BY ambient.kind
            """,
            []) { statement in
                guard let rawKind = Self.optionalText(statement, 0),
                      let kind = LibraryAmbientAuthoritySourceKind(rawValue: rawKind),
                      kind.requiresAuthorityRepresentation,
                      let identity = Self.optionalText(statement, 1),
                      let revision = Self.optionalText(statement, 4),
                      let digest = Self.optionalText(statement, 5),
                      let importedRevision = Self.optionalText(statement, 7),
                      let importedDigest = Self.optionalText(statement, 8),
                      let state = Self.optionalText(statement, 10),
                      revision == importedRevision, digest == importedDigest,
                      sqlite3_column_int(statement, 9) == 0, state == "current"
                else {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "ambient row does not have a matching current source receipt")
                }
                let snapshot = ShadowLibraryAmbientSnapshot(
                    kind: kind,
                    payloadVersion: Int(sqlite3_column_int64(statement, 2)),
                    payload: Self.data(statement, 3),
                    source: ShadowLibrarySourceFingerprint(
                        identity: identity, revision: revision, digest: digest,
                        byteCount: Int(sqlite3_column_int64(statement, 6))))
                try validate(ambient: snapshot)
                result.append(snapshot)
            }
        let currentKinds = Set(result.map(\.kind))
        guard currentKinds.count == result.count else {
            throw SQLiteLibraryStoreError.sqlite("duplicate ambient authority kind")
        }
        return result
    }

    private func upsertOperation(_ value: ShadowLibraryOperationSnapshot) throws {
        let operation = value.operation
        try execute(
            """
            INSERT INTO operations (
              id, kind, state, format_version, idempotency_key, payload_version, payload,
              created_at, updated_at, source_identity)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            ON CONFLICT(id) DO UPDATE SET
              kind = excluded.kind,
              state = excluded.state,
              format_version = excluded.format_version,
              idempotency_key = excluded.idempotency_key,
              payload_version = excluded.payload_version,
              payload = excluded.payload,
              created_at = excluded.created_at,
              updated_at = excluded.updated_at,
              source_identity = excluded.source_identity
            """,
            [
                .text(operation.id.uuidString), .text(operation.kind.rawValue),
                .text(operation.state.rawValue), .int(Int64(operation.formatVersion)),
                .text(operation.idempotencyKey), .int(Int64(operation.payloadVersion)),
                .blob(operation.payload), .double(operation.createdAt.timeIntervalSinceReferenceDate),
                .double(operation.updatedAt.timeIntervalSinceReferenceDate),
                .text(value.source.identity),
            ])
        try recordCurrentSource(
            domain: .operations,
            entityIdentity: operation.id.uuidString,
            source: value.source)
    }

    private func upsertOperationReceipt(_ receipt: LibraryOperationReceiptSnapshot) throws {
        try execute(
            """
            INSERT INTO operation_receipts (
              id, operation_id, operation_kind, state, format_version, attempt, recorded_at,
              payload_version, payload)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            """,
            [
                .text(receipt.id.uuidString), .text(receipt.operationID.uuidString),
                .text(receipt.operationKind.rawValue), .text(receipt.state.rawValue),
                .int(Int64(receipt.formatVersion)), .int(Int64(receipt.attempt)),
                .double(receipt.recordedAt.timeIntervalSinceReferenceDate),
                .int(Int64(receipt.payloadVersion)), .blob(receipt.payload),
            ])
    }

    private func upsertOperationReceiptIdempotently(
        _ receipt: LibraryOperationReceiptSnapshot
    ) throws {
        var exact = false
        var conflicting = false
        try query(
            """
            SELECT id = ?1 AND operation_id = ?2 AND operation_kind = ?3 AND state = ?4
              AND format_version = ?5 AND attempt = ?6 AND recorded_at = ?7
              AND payload_version = ?8 AND payload = ?9
            FROM operation_receipts
            WHERE id = ?1 OR (operation_id = ?2 AND attempt = ?6)
            """,
            [
                .text(receipt.id.uuidString), .text(receipt.operationID.uuidString),
                .text(receipt.operationKind.rawValue), .text(receipt.state.rawValue),
                .int(Int64(receipt.formatVersion)), .int(Int64(receipt.attempt)),
                .double(receipt.recordedAt.timeIntervalSinceReferenceDate),
                .int(Int64(receipt.payloadVersion)), .blob(receipt.payload),
            ]) { statement in
                if sqlite3_column_int(statement, 0) != 0 { exact = true }
                else { conflicting = true }
            }
        guard !conflicting else {
            throw SQLiteLibraryStoreError.invalidInput(
                "operation receipt identity collides with different authoritative facts")
        }
        if !exact { try upsertOperationReceipt(receipt) }
    }

    private func validateAuthoritativeAdoption(
        operation: ShadowLibraryOperationSnapshot,
        receipt: LibraryOperationReceiptSnapshot,
        conversationID: UUID?,
        artifactID: UUID?
    ) throws {
        let payload = try operation.operation.backgroundAdoptionPayload()
        guard operation.operation.kind == .backgroundAdoption,
              operation.operation.state == .committed,
              receipt.operationID == operation.operation.id,
              receipt.operationKind == .backgroundAdoption,
              receipt.state == .applied,
              payload.conversationID == conversationID,
              payload.artifactID == artifactID else {
            throw SQLiteLibraryStoreError.invalidInput(
                "background adoption operation/receipt does not match its entity")
        }
        _ = try receipt.details()
        try validate(source: operation.source)
    }

    private func validateAuthoritativeOperation(
        operation: ShadowLibraryOperationSnapshot,
        receipt: LibraryOperationReceiptSnapshot,
        expectedArtifactID: UUID? = nil,
        requiresArtifactDelete: Bool = false
    ) throws {
        guard receipt.operationID == operation.operation.id,
              receipt.operationKind == operation.operation.kind else {
            throw SQLiteLibraryStoreError.invalidInput(
                "operation receipt does not match its authoritative operation")
        }
        switch operation.operation.kind {
        case .conversationDelete:
            _ = try operation.operation.conversationDeletePayload()
            guard expectedArtifactID == nil, !requiresArtifactDelete else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "Conversation delete cannot accompany an Artifact mutation")
            }
        case .artifactDelete:
            let payload = try operation.operation.artifactDeletePayload()
            if let expectedArtifactID, payload.artifactID != expectedArtifactID {
                throw SQLiteLibraryStoreError.invalidInput(
                    "Artifact operation does not name its mutated Artifact")
            }
        case .workspaceMove:
            let payload = try operation.operation.workspaceMovePayload()
            if let expectedArtifactID {
                guard payload.memberKind == .artifact,
                      payload.memberIDs.contains(expectedArtifactID),
                      !requiresArtifactDelete else {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "Workspace move does not name its mutated Artifact")
                }
            }
        case .backgroundAdoption:
            let payload = try operation.operation.backgroundAdoptionPayload()
            if let expectedArtifactID {
                guard payload.artifactID == expectedArtifactID,
                      payload.conversationID == nil,
                      !requiresArtifactDelete else {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "Background adoption does not name its mutated Artifact")
                }
            }
        }
        if requiresArtifactDelete {
            guard operation.operation.kind == .artifactDelete,
                  operation.operation.state == .committed,
                  receipt.state == .applied else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "authoritative Artifact delete requires committed/applied facts")
            }
        }
        _ = try receipt.details()
        try validate(source: operation.source)
    }

    private func upsertOperationRetainedSource(
        _ retained: ShadowLibraryOperationRetainedSourceSnapshot
    ) throws {
        try execute(
            """
            INSERT INTO operation_retained_sources (
              source_identity, operation_id, kind, storage_identity, observed_revision,
              digest, byte_count, media_type, retention_state, reference_kind)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            ON CONFLICT(source_identity) DO UPDATE SET
              operation_id = excluded.operation_id,
              kind = excluded.kind,
              storage_identity = excluded.storage_identity,
              observed_revision = excluded.observed_revision,
              digest = excluded.digest,
              byte_count = excluded.byte_count,
              media_type = excluded.media_type,
              retention_state = excluded.retention_state,
              reference_kind = excluded.reference_kind
            """,
            [
                .text(retained.source.identity), .text(retained.operationID.uuidString),
                .text(retained.kind.rawValue), .text(retained.storageIdentity),
                .text(retained.source.revision), .text(retained.source.digest),
                .int(Int64(retained.source.byteCount)), .text(retained.mediaType),
                .text(retained.retentionState), .text(retained.referenceKind),
            ])
        try recordCurrentSource(
            domain: .operations,
            entityIdentity: retained.operationID.uuidString,
            source: retained.source)
    }

    private func operationReconciliationIsCurrent(
        _ inventory: ShadowLibraryOperationInventory,
        live: Set<String>
    ) throws -> Bool {
        for value in inventory.operations where try !operationSourceIsCurrent(value) {
            return false
        }
        for retained in inventory.retainedSources where try !operationRetainedSourceIsCurrent(retained) {
            return false
        }
        for issue in inventory.sourceIssues where try !sourceIssueIsCurrent(
            domain: .operations,
            source: issue.source,
            entityIdentity: issue.operationID?.uuidString,
            kind: issue.kind,
            diagnostics: issue.diagnostics) {
            return false
        }
        guard try operationReceiptsAreCurrent(inventory.receipts),
              inventory.hasCompleteCensus,
              try sourceCount(domain: .operations) == live.count else { return false }
        var markerMatches = false
        try query(
            """
            SELECT 1 FROM domain_reconciliation
            WHERE domain = 'operations' AND expected_source_count = ?1
            """,
            [.int(Int64(live.count))]) { _ in markerMatches = true }
        return markerMatches
    }

    private func operationSourceIsCurrent(
        _ value: ShadowLibraryOperationSnapshot
    ) throws -> Bool {
        let operation = value.operation
        var current = false
        try query(
            """
            SELECT 1
            FROM operations operation
            JOIN migration_sources receipt
              ON receipt.domain = 'operations'
             AND receipt.source_identity = operation.source_identity
            WHERE operation.id = ?1 AND operation.kind = ?2 AND operation.state = ?3
              AND operation.format_version = ?4 AND operation.idempotency_key = ?5
              AND operation.payload_version = ?6 AND operation.payload = ?7
              AND operation.created_at = ?8 AND operation.updated_at = ?9
              AND operation.source_identity = ?10
              AND receipt.entity_id = ?1 AND receipt.observed_revision = ?11
              AND receipt.observed_digest = ?12 AND receipt.source_byte_count = ?13
              AND receipt.imported_revision = ?11 AND receipt.imported_digest = ?12
              AND receipt.dirty = 0 AND receipt.import_state = 'current'
            """,
            [
                .text(operation.id.uuidString), .text(operation.kind.rawValue),
                .text(operation.state.rawValue), .int(Int64(operation.formatVersion)),
                .text(operation.idempotencyKey), .int(Int64(operation.payloadVersion)),
                .blob(operation.payload), .double(operation.createdAt.timeIntervalSinceReferenceDate),
                .double(operation.updatedAt.timeIntervalSinceReferenceDate),
                .text(value.source.identity), .text(value.source.revision),
                .text(value.source.digest), .int(Int64(value.source.byteCount)),
            ]) { _ in current = true }
        return current
    }

    private func operationRetainedSourceIsCurrent(
        _ retained: ShadowLibraryOperationRetainedSourceSnapshot
    ) throws -> Bool {
        var current = false
        try query(
            """
            SELECT 1
            FROM operation_retained_sources retained
            JOIN migration_sources receipt
              ON receipt.domain = 'operations'
             AND receipt.source_identity = retained.source_identity
            WHERE retained.source_identity = ?1 AND retained.operation_id = ?2
              AND retained.kind = ?3 AND retained.storage_identity = ?4
              AND retained.observed_revision = ?5 AND retained.digest = ?6
              AND retained.byte_count = ?7 AND retained.media_type = ?8
              AND retained.retention_state = ?9 AND retained.reference_kind = ?10
              AND receipt.entity_id = ?2 AND receipt.observed_revision = ?5
              AND receipt.observed_digest = ?6 AND receipt.source_byte_count = ?7
              AND receipt.imported_revision = ?5 AND receipt.imported_digest = ?6
              AND receipt.dirty = 0 AND receipt.import_state = 'current'
            """,
            [
                .text(retained.source.identity), .text(retained.operationID.uuidString),
                .text(retained.kind.rawValue), .text(retained.storageIdentity),
                .text(retained.source.revision), .text(retained.source.digest),
                .int(Int64(retained.source.byteCount)), .text(retained.mediaType),
                .text(retained.retentionState), .text(retained.referenceKind),
            ]) { _ in current = true }
        return current
    }

    private func operationReceiptsAreCurrent(
        _ receipts: [LibraryOperationReceiptSnapshot]
    ) throws -> Bool {
        var count = 0
        try query("SELECT COUNT(*) FROM operation_receipts", []) {
            count = Int(sqlite3_column_int64($0, 0))
        }
        guard count == receipts.count else { return false }
        for receipt in receipts {
            var current = false
            try query(
                """
                SELECT 1 FROM operation_receipts
                WHERE id = ?1 AND operation_id = ?2 AND operation_kind = ?3 AND state = ?4
                  AND format_version = ?5 AND attempt = ?6 AND recorded_at = ?7
                  AND payload_version = ?8 AND payload = ?9
                """,
                [
                    .text(receipt.id.uuidString), .text(receipt.operationID.uuidString),
                    .text(receipt.operationKind.rawValue), .text(receipt.state.rawValue),
                    .int(Int64(receipt.formatVersion)), .int(Int64(receipt.attempt)),
                    .double(receipt.recordedAt.timeIntervalSinceReferenceDate),
                    .int(Int64(receipt.payloadVersion)), .blob(receipt.payload),
                ]) { _ in current = true }
            if !current { return false }
        }
        return true
    }

    private func readOperationSnapshots() throws -> ShadowLibraryOperationReadSnapshot {
        // Use the same per-source proof that authorizes activation. The older blanket-zero check
        // contradicted that proof: a fully inventoried malformed trash entry was correctly accepted
        // as an unrepresented quarantine, then rejected here moments later. That made every retry
        // deterministically fail even though current operation rows and their receipts were sound.
        // The queries below still expose only rows joined to exact current source receipts; accepted
        // issues remain preserved in the protected legacy trash and are never manufactured as work.
        let status = try makeStatus()
        guard let operationStatus = status.domain(.operations) else {
            throw SQLiteLibraryStoreError.invalidInput(
                "operation authority has no reconciliation status")
        }
        if let blocker = try activationBlocker(operationStatus) {
            throw SQLiteLibraryStoreError.invalidInput(
                "operation authority is not ready: \(blocker)")
        }

        var operations: [LibraryOperationSnapshot] = []
        try query(
            """
            SELECT operation.id, operation.kind, operation.state, operation.format_version,
                   operation.idempotency_key, operation.created_at, operation.updated_at,
                   operation.payload_version, operation.payload,
                   receipt.observed_revision, receipt.observed_digest, receipt.source_byte_count,
                   receipt.imported_revision, receipt.imported_digest, receipt.dirty,
                   receipt.import_state
            FROM operations operation
            JOIN migration_sources receipt
              ON receipt.domain = 'operations'
             AND receipt.source_identity = operation.source_identity
            ORDER BY operation.created_at, operation.id
            """, []) { statement in
                guard let idText = Self.optionalText(statement, 0), let id = UUID(uuidString: idText),
                      let kindText = Self.optionalText(statement, 1),
                      let kind = LibraryOperationKind(rawValue: kindText),
                      let stateText = Self.optionalText(statement, 2),
                      let state = LibraryOperationState(rawValue: stateText),
                      let idempotencyKey = Self.optionalText(statement, 4),
                      let observedRevision = Self.optionalText(statement, 9),
                      let observedDigest = Self.optionalText(statement, 10),
                      let importedRevision = Self.optionalText(statement, 12),
                      let importedDigest = Self.optionalText(statement, 13),
                      observedRevision == importedRevision,
                      observedDigest == importedDigest,
                      sqlite3_column_int(statement, 14) == 0,
                      Self.optionalText(statement, 15) == "current"
                else {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "operation row does not have a matching current source receipt")
                }
                operations.append(try LibraryOperationSnapshot(
                    persistedFormatVersion: Int(sqlite3_column_int64(statement, 3)),
                    id: id,
                    kind: kind,
                    state: state,
                    idempotencyKey: idempotencyKey,
                    createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 5)),
                    updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 6)),
                    payloadVersion: Int(sqlite3_column_int64(statement, 7)),
                    payload: Self.data(statement, 8)))
            }

        let operationsByID = Dictionary(uniqueKeysWithValues: operations.map { ($0.id, $0.kind) })
        var receipts: [LibraryOperationReceiptSnapshot] = []
        try query(
            """
            SELECT id, operation_id, operation_kind, state, format_version, attempt,
                   recorded_at, payload_version, payload
            FROM operation_receipts ORDER BY operation_id, attempt, id
            """, []) { statement in
                guard let idText = Self.optionalText(statement, 0), let id = UUID(uuidString: idText),
                      let operationText = Self.optionalText(statement, 1),
                      let operationID = UUID(uuidString: operationText),
                      let kindText = Self.optionalText(statement, 2),
                      let kind = LibraryOperationKind(rawValue: kindText),
                      let stateText = Self.optionalText(statement, 3),
                      let state = LibraryOperationReceiptState(rawValue: stateText),
                      operationsByID[operationID] == kind else {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "operation receipt does not match a current operation")
                }
                receipts.append(try LibraryOperationReceiptSnapshot(
                    persistedFormatVersion: Int(sqlite3_column_int64(statement, 4)),
                    id: id,
                    operationID: operationID,
                    operationKind: kind,
                    state: state,
                    attempt: Int(sqlite3_column_int64(statement, 5)),
                    recordedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 6)),
                    payloadVersion: Int(sqlite3_column_int64(statement, 7)),
                    payload: Self.data(statement, 8)))
            }

        var retainedSources: [ShadowLibraryOperationRetainedSourceSnapshot] = []
        try query(
            """
            SELECT retained.source_identity, retained.operation_id, retained.kind,
                   retained.storage_identity, retained.observed_revision, retained.digest,
                   retained.byte_count, retained.media_type, retained.retention_state,
                   retained.reference_kind, receipt.imported_revision, receipt.imported_digest,
                   receipt.dirty, receipt.import_state
            FROM operation_retained_sources retained
            JOIN migration_sources receipt
              ON receipt.domain = 'operations'
             AND receipt.source_identity = retained.source_identity
            ORDER BY retained.source_identity
            """, []) { statement in
                guard let identity = Self.optionalText(statement, 0),
                      let operationText = Self.optionalText(statement, 1),
                      let operationID = UUID(uuidString: operationText),
                      operationsByID[operationID] != nil,
                      let kindText = Self.optionalText(statement, 2),
                      let kind = ShadowLibraryOperationRetainedSourceSnapshot.Kind(rawValue: kindText),
                      let storageIdentity = Self.optionalText(statement, 3),
                      let revision = Self.optionalText(statement, 4),
                      let digest = Self.optionalText(statement, 5),
                      let mediaType = Self.optionalText(statement, 7),
                      let retentionState = Self.optionalText(statement, 8),
                      let referenceKind = Self.optionalText(statement, 9),
                      let importedRevision = Self.optionalText(statement, 10),
                      let importedDigest = Self.optionalText(statement, 11),
                      revision == importedRevision, digest == importedDigest,
                      sqlite3_column_int(statement, 12) == 0,
                      Self.optionalText(statement, 13) == "current" else {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "operation-retained source lacks a current operation/receipt")
                }
                retainedSources.append(ShadowLibraryOperationRetainedSourceSnapshot(
                    operationID: operationID,
                    kind: kind,
                    storageIdentity: storageIdentity,
                    mediaType: mediaType,
                    retentionState: retentionState,
                    referenceKind: referenceKind,
                    source: ShadowLibrarySourceFingerprint(
                        identity: identity, revision: revision, digest: digest,
                        byteCount: Int(sqlite3_column_int64(statement, 6)))))
            }
        return ShadowLibraryOperationReadSnapshot(
            operations: operations,
            receipts: receipts,
            retainedSources: retainedSources)
    }

    private func upsertWorkspace(_ workspace: ShadowLibraryWorkspaceSnapshot) throws {
        guard try !sourceIsCurrent(
            domain: .workspaces,
            source: workspace.source,
            entityID: workspace.id)
        else { return }
        try execute(
            """
            INSERT INTO workspaces (
              id, kind, name, goal, instructions, cwd, favorite, sort_index, icon_symbol,
              color_hex, created_at, updated_at, revision, source_identity, tombstoned,
              local_state_version, local_state_payload)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
                    ?15, ?16, ?17)
            ON CONFLICT(id) DO UPDATE SET
              kind = excluded.kind,
              name = excluded.name,
              goal = excluded.goal,
              instructions = excluded.instructions,
              cwd = excluded.cwd,
              favorite = excluded.favorite,
              sort_index = excluded.sort_index,
              icon_symbol = excluded.icon_symbol,
              color_hex = excluded.color_hex,
              created_at = excluded.created_at,
              updated_at = excluded.updated_at,
              revision = excluded.revision,
              source_identity = excluded.source_identity,
              tombstoned = excluded.tombstoned,
              local_state_version = excluded.local_state_version,
              local_state_payload = excluded.local_state_payload
            """,
            [
                .text(workspace.id.uuidString), .text(workspace.kind.rawValue),
                .text(workspace.name), .text(workspace.goal), .text(workspace.instructions),
                .text(workspace.cwd), .bool(workspace.favorite),
                workspace.sortIndex.map { .int(Int64($0)) } ?? .null,
                workspace.iconSymbol.map(SQLiteValue.text) ?? .null,
                workspace.colorHex.map(SQLiteValue.text) ?? .null,
                .double(workspace.createdAt.timeIntervalSinceReferenceDate),
                .double(workspace.updatedAt.timeIntervalSinceReferenceDate),
                .int(workspace.revision), .text(workspace.source.identity),
                .bool(workspace.tombstoned), .int(Int64(workspace.localStateVersion)),
                .blob(workspace.localStatePayload),
            ])
        try recordCurrentSource(
            domain: .workspaces,
            entityID: workspace.id,
            source: workspace.source)
    }

    private func upsertConversation(_ conversation: ShadowLibraryConversationSnapshot) throws {
        if try !workspaceExists(conversation.workspaceID) {
            try ensureUnresolvedWorkspace(conversation.workspaceID)
        }
        let durableCurrent = try sourceIsCurrent(
            domain: .conversations,
            source: conversation.source,
            entityID: conversation.id)
        let operativeCurrent = try sourceIsCurrent(
            domain: .operativeState,
            source: conversation.source,
            entityID: conversation.id)
        guard !durableCurrent || !operativeCurrent else { return }
        try execute(
            """
            INSERT INTO conversations (
              id, title, title_source, cwd, workspace_id, updated_at, favorite, sort_index,
              unread, errored, revision, source_identity, tombstoned, local_state_version,
              local_state_payload)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
            ON CONFLICT(id) DO UPDATE SET
              title = excluded.title,
              title_source = excluded.title_source,
              cwd = excluded.cwd,
              workspace_id = excluded.workspace_id,
              updated_at = excluded.updated_at,
              favorite = excluded.favorite,
              sort_index = excluded.sort_index,
              unread = excluded.unread,
              errored = excluded.errored,
              revision = excluded.revision,
              source_identity = excluded.source_identity,
              tombstoned = excluded.tombstoned,
              local_state_version = excluded.local_state_version,
              local_state_payload = excluded.local_state_payload
            """,
            [
                .text(conversation.id.uuidString), .text(conversation.title),
                .text(conversation.titleSource), .text(conversation.cwd),
                .text(conversation.workspaceID.uuidString),
                .double(conversation.updatedAt.timeIntervalSinceReferenceDate),
                .bool(conversation.favorite),
                conversation.sortIndex.map { .int(Int64($0)) } ?? .null,
                .bool(conversation.unread), .bool(conversation.errored),
                .int(conversation.revision), .text(conversation.source.identity),
                .bool(conversation.tombstoned), .int(Int64(conversation.localStateVersion)),
                .blob(conversation.localStatePayload),
            ])
        try execute(
            "DELETE FROM conversation_events WHERE conversation_id = ?1",
            [.text(conversation.id.uuidString)])
        for event in conversation.events {
            try execute(
                """
                INSERT INTO conversation_events (
                  id, conversation_id, capture_sequence, kind, actor_id, target_id,
                  observed_at, provider_at, producing_event_id, causal_event_id,
                  payload_version, payload)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                """,
                [
                    .text(event.id.uuidString), .text(conversation.id.uuidString),
                    .int(event.captureSequence), .text(event.kind),
                    event.actorID.map(SQLiteValue.text) ?? .null,
                    event.targetID.map(SQLiteValue.text) ?? .null,
                    event.observedAt.map { .double($0.timeIntervalSinceReferenceDate) } ?? .null,
                    event.providerAt.map { .double($0.timeIntervalSinceReferenceDate) } ?? .null,
                    event.producingEventID.map { .text($0.uuidString) } ?? .null,
                    event.causalEventID.map { .text($0.uuidString) } ?? .null,
                    .int(Int64(event.payloadVersion)),
                    .blob(ConversationEventPayloadCodec.encode(
                        event.payload, kind: event.kind)),
                ])
        }
        try execute(
            "DELETE FROM conversation_artifact_snapshots WHERE conversation_id = ?1",
            [.text(conversation.id.uuidString)])
        for (ordinal, artifact) in conversation.nestedArtifacts.enumerated() {
            try execute(
                """
                INSERT INTO conversation_artifact_snapshots (
                  conversation_id, artifact_id, canonical_payload, canonical_payload_digest,
                  content_digest, content_byte_count, ordinal)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                """,
                [
                    .text(conversation.id.uuidString), .text(artifact.artifactID.uuidString),
                    .blob(artifact.canonicalPayload), .text(artifact.canonicalPayloadDigest),
                    .text(artifact.contentDigest), .int(Int64(artifact.contentByteCount)),
                    .int(Int64(ordinal)),
                ])
        }
        try recordCurrentSource(
            domain: .conversations,
            entityID: conversation.id,
            source: conversation.source)
        try recordCurrentSource(
            domain: .operativeState,
            entityID: conversation.id,
            source: conversation.source)
    }

    /// Active authority changes one header row and only the event rows whose canonical columns
    /// changed. The migrated shadow importer above intentionally retains its simple replace-all
    /// behavior; this hot path must not turn one appended tool result into a 100 MB SQLite rewrite.
    /// `liveTranscriptOrder` is every transcript entry id the runtime Conversation currently holds,
    /// in order. A complete capture leaves it nil and the supplied events are the whole truth.
    /// Returns whether any stored row was removed or moved, which a caller with an empty delta
    /// cannot otherwise know.
    @discardableResult
    private func upsertAuthoritativeConversation(
        _ conversation: ShadowLibraryConversationSnapshot,
        liveTranscriptOrder: [UUID]? = nil
    ) throws -> AuthoritativeConversationUpsertResult {
        if try !workspaceExists(conversation.workspaceID) {
            try ensureUnresolvedWorkspace(conversation.workspaceID)
        }
        var priorWorkspaceID: UUID?
        var priorWasTombstoned: Bool?
        try query(
            "SELECT workspace_id, tombstoned FROM conversations WHERE id = ?1",
            [.text(conversation.id.uuidString)]) { statement in
                guard priorWorkspaceID == nil,
                      let rawWorkspaceID = Self.optionalText(statement, 0),
                      let workspaceID = UUID(uuidString: rawWorkspaceID) else { return }
                priorWorkspaceID = workspaceID
                priorWasTombstoned = sqlite3_column_int64(statement, 1) != 0
            }
        try execute(
            """
            INSERT INTO conversations (
              id, title, title_source, cwd, workspace_id, updated_at, favorite, sort_index,
              unread, errored, revision, source_identity, tombstoned, local_state_version,
              local_state_payload)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
            ON CONFLICT(id) DO UPDATE SET
              title = excluded.title,
              title_source = excluded.title_source,
              cwd = excluded.cwd,
              workspace_id = excluded.workspace_id,
              updated_at = excluded.updated_at,
              favorite = excluded.favorite,
              sort_index = excluded.sort_index,
              unread = excluded.unread,
              errored = excluded.errored,
              revision = excluded.revision,
              source_identity = excluded.source_identity,
              tombstoned = excluded.tombstoned,
              local_state_version = excluded.local_state_version,
              local_state_payload = excluded.local_state_payload
            """,
            [
                .text(conversation.id.uuidString), .text(conversation.title),
                .text(conversation.titleSource), .text(conversation.cwd),
                .text(conversation.workspaceID.uuidString),
                .double(conversation.updatedAt.timeIntervalSinceReferenceDate),
                .bool(conversation.favorite),
                conversation.sortIndex.map { .int(Int64($0)) } ?? .null,
                .bool(conversation.unread), .bool(conversation.errored),
                .int(conversation.revision), .text(conversation.source.identity),
                .bool(conversation.tombstoned), .int(Int64(conversation.localStateVersion)),
                .blob(conversation.localStatePayload),
            ])

        var existingSequences: [UUID: Int64] = [:]
        var existingKinds: [UUID: String] = [:]
        try query(
            "SELECT id, capture_sequence, kind FROM conversation_events WHERE conversation_id = ?1",
            [.text(conversation.id.uuidString)]) { statement in
                guard let rawID = Self.optionalText(statement, 0),
                      let id = UUID(uuidString: rawID),
                      let kind = Self.optionalText(statement, 2),
                      existingSequences[id] == nil else {
                    throw SQLiteLibraryStoreError.sqlite(
                        "authoritative Conversation event identity is malformed or duplicated")
                }
                existingSequences[id] = sqlite3_column_int64(statement, 1)
                existingKinds[id] = kind
            }
        // A partial mutation omits unchanged transcript rows, so the supplied events alone cannot say
        // which stored rows still belong. The live transcript ordering can, and unlike the caller's
        // delta it cannot lag this database: the delta is diffed against a baseline republished on
        // the main actor after this queue has already committed, so an entry that both appeared and
        // vanished inside that window is named by neither side. Rows the ordering does not list are
        // gone; rows it lists must sit at the position it gives them, reported changed or not.
        let suppliedIDs = Set(conversation.events.map(\.id))
        var desiredSequences: [UUID: Int64] = [:]
        if let liveTranscriptOrder {
            desiredSequences.reserveCapacity(
                liveTranscriptOrder.count + conversation.events.count)
            for (index, id) in liveTranscriptOrder.enumerated() {
                desiredSequences[id] = Int64(index)
            }
        }
        for event in conversation.events {
            desiredSequences[event.id] = event.captureSequence
        }
        let removedIDs = existingSequences.keys.filter { desiredSequences[$0] == nil }
        for id in removedIDs {
            try execute(
                "DELETE FROM conversation_events WHERE conversation_id = ?1 AND id = ?2",
                [.text(conversation.id.uuidString), .text(id.uuidString)])
        }
        // Reordering can otherwise hit the unique sequence index before the displaced row moves.
        // Park every mover below zero first; the negated values stay unique because the sequences
        // they came from were, and they cannot collide with the positive slots being filled.
        let rebasedIDs = existingSequences.compactMap { entry -> UUID? in
            desiredSequences[entry.key] != entry.value ? entry.key : nil
        }
        for id in rebasedIDs {
            try execute(
                "UPDATE conversation_events SET capture_sequence = -capture_sequence - 1 WHERE conversation_id = ?1 AND id = ?2",
                [.text(conversation.id.uuidString), .text(id.uuidString)])
        }
        for event in conversation.events {
            try execute(
                """
                INSERT INTO conversation_events (
                  id, conversation_id, capture_sequence, kind, actor_id, target_id,
                  observed_at, provider_at, producing_event_id, causal_event_id,
                  payload_version, payload)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                ON CONFLICT(conversation_id, id) DO UPDATE SET
                  capture_sequence = excluded.capture_sequence,
                  kind = excluded.kind,
                  actor_id = excluded.actor_id,
                  target_id = excluded.target_id,
                  observed_at = excluded.observed_at,
                  provider_at = excluded.provider_at,
                  producing_event_id = excluded.producing_event_id,
                  causal_event_id = excluded.causal_event_id,
                  payload_version = excluded.payload_version,
                  payload = excluded.payload
                WHERE conversation_events.capture_sequence != excluded.capture_sequence
                   OR conversation_events.kind != excluded.kind
                   OR conversation_events.actor_id IS NOT excluded.actor_id
                   OR conversation_events.target_id IS NOT excluded.target_id
                   OR conversation_events.observed_at IS NOT excluded.observed_at
                   OR conversation_events.provider_at IS NOT excluded.provider_at
                   OR conversation_events.producing_event_id IS NOT excluded.producing_event_id
                   OR conversation_events.causal_event_id IS NOT excluded.causal_event_id
                   OR conversation_events.payload_version != excluded.payload_version
                   OR conversation_events.payload != excluded.payload
                """,
                [
                    .text(event.id.uuidString), .text(conversation.id.uuidString),
                    .int(event.captureSequence), .text(event.kind),
                    event.actorID.map(SQLiteValue.text) ?? .null,
                    event.targetID.map(SQLiteValue.text) ?? .null,
                    event.observedAt.map { .double($0.timeIntervalSinceReferenceDate) } ?? .null,
                    event.providerAt.map { .double($0.timeIntervalSinceReferenceDate) } ?? .null,
                    event.producingEventID.map { .text($0.uuidString) } ?? .null,
                    event.causalEventID.map { .text($0.uuidString) } ?? .null,
                    .int(Int64(event.payloadVersion)),
                    .blob(ConversationEventPayloadCodec.encode(
                        event.payload, kind: event.kind)),
                ])
        }
        // Rows the partial capture omitted but the live ordering moved. Their payload is unchanged,
        // so only the position is rewritten. They were parked below zero above and must not be left
        // there: a negative sequence fails reconstruction just as loudly as a missing row.
        for id in rebasedIDs where !suppliedIDs.contains(id) {
            guard let sequence = desiredSequences[id] else { continue }
            try execute(
                """
                UPDATE conversation_events SET capture_sequence = ?3
                WHERE conversation_id = ?1 AND id = ?2
                """,
                [.text(conversation.id.uuidString), .text(id.uuidString), .int(sequence)])
        }

        // Nested Artifact snapshots are bounded and ordinarily few. Their positional unique index
        // makes replace-all safer than inventing a second reorder protocol on this cold subdomain.
        try execute(
            "DELETE FROM conversation_artifact_snapshots WHERE conversation_id = ?1",
            [.text(conversation.id.uuidString)])
        for (ordinal, artifact) in conversation.nestedArtifacts.enumerated() {
            try execute(
                """
                INSERT INTO conversation_artifact_snapshots (
                  conversation_id, artifact_id, canonical_payload, canonical_payload_digest,
                  content_digest, content_byte_count, ordinal)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                """,
                [
                    .text(conversation.id.uuidString), .text(artifact.artifactID.uuidString),
                    .blob(artifact.canonicalPayload), .text(artifact.canonicalPayloadDigest),
                    .text(artifact.contentDigest), .int(Int64(artifact.contentByteCount)),
                    .int(Int64(ordinal)),
                ])
        }
        try recordCurrentSource(
            domain: .conversations, entityID: conversation.id, source: conversation.source)
        try recordCurrentSource(
            domain: .operativeState, entityID: conversation.id, source: conversation.source)
        let suppliedKinds = Dictionary(uniqueKeysWithValues: conversation.events.map {
            ($0.id, $0.kind)
        })
        let userActivityRowsChanged = removedIDs.contains {
            existingKinds[$0] == "transcript.user"
        } || rebasedIDs.contains {
            existingKinds[$0] == "transcript.user"
                || suppliedKinds[$0] == "transcript.user"
        } || conversation.events.contains { event in
            event.kind == "transcript.user" || existingKinds[event.id] == "transcript.user"
        }
        let activityMembershipChanged = priorWorkspaceID != conversation.workspaceID
            || priorWasTombstoned != conversation.tombstoned
        return .init(
            structureChanged: !removedIDs.isEmpty || !rebasedIDs.isEmpty,
            activityRowsChanged: userActivityRowsChanged || activityMembershipChanged)
    }

    private func forceConversationSearchReindex(_ id: UUID) throws {
        try execute(
            """
            UPDATE projection_outbox
            SET force_reindex = 1
            WHERE projection_kind = 'conversation_search' AND entity_id = ?1
            """,
            [.text(id.uuidString)])
    }

    private func authoritativeConversationContentMatches(
        _ lhs: ShadowLibraryConversationSnapshot,
        _ rhs: ShadowLibraryConversationSnapshot
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.titleSource == rhs.titleSource
            && lhs.cwd == rhs.cwd
            && lhs.workspaceID == rhs.workspaceID
            && lhs.updatedAt == rhs.updatedAt
            && lhs.favorite == rhs.favorite
            && lhs.sortIndex == rhs.sortIndex
            && lhs.unread == rhs.unread
            && lhs.errored == rhs.errored
            && lhs.revision == rhs.revision
            && lhs.tombstoned == rhs.tombstoned
            && lhs.localStateVersion == rhs.localStateVersion
            && lhs.localStatePayload == rhs.localStatePayload
            && lhs.events == rhs.events
            && lhs.nestedArtifacts == rhs.nestedArtifacts
    }

    private func authoritativeBackgroundArtifactRevisionMatches(
        _ current: Artifact,
        _ candidate: Artifact
    ) -> Bool {
        current.uuid == candidate.uuid
            && current.type == candidate.type
            && current.source == candidate.source
            && current.createdAt == candidate.createdAt
            && current.updatedAt >= candidate.updatedAt
            && current.revisions == candidate.revisions
            && current.origin == candidate.origin
            && current.conversationID == candidate.conversationID
            && current.conversationTitle == candidate.conversationTitle
    }

    private func upsertArtifact(_ artifact: ShadowLibraryArtifactSnapshot) throws {
        if try !workspaceExists(artifact.workspaceID) {
            try ensureUnresolvedWorkspace(artifact.workspaceID)
        }
        guard try !sourceIsCurrent(
            domain: .artifactMedia,
            source: artifact.source,
            entityID: artifact.id)
        else { return }
        try execute(
            """
            INSERT INTO artifacts (
              id, title, artifact_type, origin, workspace_id, provenance_conversation_id,
              conversation_title_snapshot, cwd, favorite, created_at, updated_at, revision,
              producer_task_id, raw_source_payload, canonical_payload, canonical_payload_digest, content,
              content_digest, content_byte_count, payload_media_type, source_identity, tombstoned)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
                    ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22)
            ON CONFLICT(id) DO UPDATE SET
              title = excluded.title,
              artifact_type = excluded.artifact_type,
              origin = excluded.origin,
              workspace_id = excluded.workspace_id,
              provenance_conversation_id = excluded.provenance_conversation_id,
              conversation_title_snapshot = excluded.conversation_title_snapshot,
              cwd = excluded.cwd,
              favorite = excluded.favorite,
              created_at = excluded.created_at,
              updated_at = excluded.updated_at,
              revision = excluded.revision,
              producer_task_id = excluded.producer_task_id,
              raw_source_payload = excluded.raw_source_payload,
              canonical_payload = excluded.canonical_payload,
              canonical_payload_digest = excluded.canonical_payload_digest,
              content = excluded.content,
              content_digest = excluded.content_digest,
              content_byte_count = excluded.content_byte_count,
              payload_media_type = excluded.payload_media_type,
              source_identity = excluded.source_identity,
              tombstoned = excluded.tombstoned
            """,
            [
                .text(artifact.id.uuidString), .text(artifact.title), .text(artifact.type),
                .text(artifact.origin), .text(artifact.workspaceID.uuidString),
                artifact.provenanceConversationID.map { .text($0.uuidString) } ?? .null,
                .text(artifact.conversationTitleSnapshot), .text(artifact.cwd),
                .bool(artifact.favorite),
                .double(artifact.createdAt.timeIntervalSinceReferenceDate),
                .double(artifact.updatedAt.timeIntervalSinceReferenceDate),
                .int(Int64(artifact.revision)),
                artifact.producerTaskID.map(SQLiteValue.text) ?? .null,
                .blob(artifact.rawSourcePayload),
                .blob(artifact.canonicalPayload), .text(artifact.canonicalPayloadDigest),
                .blob(artifact.content), .text(artifact.contentDigest),
                .int(Int64(artifact.contentByteCount)), .text(artifact.payloadMediaType),
                .text(artifact.source.identity), .bool(artifact.tombstoned),
            ])
        try recordCurrentSource(
            domain: .artifactMedia,
            entityID: artifact.id,
            source: artifact.source)
    }

    private func upsertRetainedByte(
        _ retained: ShadowLibraryRetainedByteSnapshot,
        normalized suppliedNormalization: NormalizedRetainedByte? = nil
    ) throws {
        let normalized = try suppliedNormalization ?? normalizedRetainedByte(retained)
        guard try !retainedByteIsCurrent(retained, normalized: normalized) else { return }
        try execute(
            """
            INSERT INTO retained_byte_sources (
              source_identity, kind, owner_conversation_id, storage_name, observed_revision,
              digest, byte_count, media_type, link_state, diagnostics, storage_class,
              storage_state, storage_identity, retention_state, managed_blob_digest, disposition)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
            ON CONFLICT(source_identity) DO UPDATE SET
              kind = excluded.kind,
              owner_conversation_id = excluded.owner_conversation_id,
              storage_name = excluded.storage_name,
              observed_revision = excluded.observed_revision,
              digest = excluded.digest,
              byte_count = excluded.byte_count,
              media_type = excluded.media_type,
              link_state = excluded.link_state,
              diagnostics = excluded.diagnostics,
              storage_class = excluded.storage_class,
              storage_state = excluded.storage_state,
              storage_identity = excluded.storage_identity,
              retention_state = excluded.retention_state,
              managed_blob_digest = excluded.managed_blob_digest,
              disposition = excluded.disposition
            """,
            [
                .text(retained.source.identity), .text(retained.kind.rawValue),
                retained.ownerConversationID.map { .text($0.uuidString) } ?? .null,
                .text(retained.storageName), .text(retained.source.revision),
                .text(retained.source.digest), .int(Int64(retained.source.byteCount)),
                .text(retained.mediaType), .text(normalized.linkState.rawValue),
                normalized.diagnostics.map(SQLiteValue.text) ?? .null,
                .text(retained.storageClass.rawValue), .text(retained.storageState.rawValue),
                .text(retained.storageIdentity), .text(retained.retentionState.rawValue),
                retained.managedBlobDigest.map(SQLiteValue.text) ?? .null,
                .text(retained.disposition.rawValue),
            ])
        try recordImportedArtifactMediaSource(
            entityIdentity: retained.ownerConversationID?.uuidString
                ?? "retained:\(retained.source.identity)",
            source: retained.source,
            state: normalized.importState,
            diagnostics: normalized.diagnostics)
    }

    private func removeStaleSources(
        domain: ShadowLibraryDomain,
        retaining live: Set<String>
    ) throws {
        var existing: [(identity: String, entityID: String)] = []
        try query(
            "SELECT source_identity, entity_id FROM migration_sources WHERE domain = ?1",
            [.text(domain.rawValue)]) { statement in
                guard let identity = Self.optionalText(statement, 0),
                      let entityID = Self.optionalText(statement, 1)
                else { return }
                existing.append((identity, entityID))
            }
        for source in existing where !live.contains(source.identity) {
            switch domain {
            case .conversations:
                try execute(
                    """
                    UPDATE retained_byte_sources
                    SET storage_state = 'observed'
                    WHERE storage_class = 'legacy_layout'
                      AND owner_conversation_id = (
                        SELECT id FROM conversations WHERE source_identity = ?1)
                    """,
                    [.text(source.identity)])
                try execute(
                    "DELETE FROM conversations WHERE source_identity = ?1",
                    [.text(source.identity)])
            case .workspaces:
                guard source.entityID != Self.homeWorkspaceID.uuidString else { continue }
                if let id = UUID(uuidString: source.entityID),
                   try workspaceReferenceCount(id) > 0 {
                    try convertToUnresolvedWorkspace(
                        id,
                        staleSourceIdentity: source.identity)
                    continue
                }
                try execute(
                    "DELETE FROM workspaces WHERE source_identity = ?1 AND kind = 'named'",
                    [.text(source.identity)])
            case .artifactMedia:
                try execute(
                    "DELETE FROM artifacts WHERE source_identity = ?1",
                    [.text(source.identity)])
                try execute(
                    "DELETE FROM retained_byte_sources WHERE source_identity = ?1",
                    [.text(source.identity)])
            case .operativeState:
                break
            case .ambientState:
                try execute(
                    "DELETE FROM ambient_authority_sources WHERE source_identity = ?1",
                    [.text(source.identity)])
            case .operations:
                try execute(
                    "DELETE FROM operation_retained_sources WHERE source_identity = ?1",
                    [.text(source.identity)])
                try execute(
                    "DELETE FROM operations WHERE source_identity = ?1",
                    [.text(source.identity)])
            }
            try execute(
                "DELETE FROM migration_sources WHERE domain = ?1 AND source_identity = ?2",
                [.text(domain.rawValue), .text(source.identity)])
        }
    }

    private func ensureUnresolvedWorkspace(_ id: UUID) throws {
        guard id != Self.homeWorkspaceID else { return }
        if try workspaceExists(id) { return }
        let identity = "missing-workspace:\(id.uuidString)"
        let now = Date().timeIntervalSinceReferenceDate
        try execute(
            """
            INSERT INTO workspaces (
              id, kind, name, goal, instructions, cwd, favorite, sort_index, icon_symbol,
              color_hex, created_at, updated_at, revision, source_identity)
            VALUES (?1, 'unresolved', 'Missing Workspace', '', '', '', 0, NULL, NULL, NULL,
                    ?2, ?2, 0, NULL)
            ON CONFLICT(id) DO NOTHING
            """,
            [.text(id.uuidString), .double(now)])
        try execute(
            """
            INSERT INTO migration_sources (
              domain, source_identity, entity_id, observed_revision, observed_digest,
              source_byte_count, imported_revision, imported_digest, dirty, import_state,
              diagnostics, imported_at)
            VALUES ('workspaces', ?1, ?2, 'missing', 'missing', 0, NULL, NULL, 1,
                    'mismatch', 'Conversation references a missing Workspace source.', NULL)
            ON CONFLICT(domain, source_identity) DO UPDATE SET
              entity_id = excluded.entity_id,
              dirty = 1,
              import_state = 'mismatch',
              diagnostics = excluded.diagnostics
            """,
            [.text(identity), .text(id.uuidString)])
    }

    private func convertToUnresolvedWorkspace(
        _ id: UUID,
        staleSourceIdentity: String
    ) throws {
        try execute(
            """
            UPDATE workspaces
            SET kind = 'unresolved', source_identity = NULL
            WHERE id = ?1 AND kind = 'named'
            """,
            [.text(id.uuidString)])
        try execute(
            "DELETE FROM migration_sources WHERE domain = 'workspaces' AND source_identity = ?1",
            [.text(staleSourceIdentity)])
        // The row already exists, so create only the source/status mismatch.
        let identity = "missing-workspace:\(id.uuidString)"
        try execute(
            """
            INSERT INTO migration_sources (
              domain, source_identity, entity_id, observed_revision, observed_digest,
              source_byte_count, imported_revision, imported_digest, dirty, import_state,
              diagnostics, imported_at)
            VALUES ('workspaces', ?1, ?2, 'missing', 'missing', 0, NULL, NULL, 1,
                    'mismatch', 'Workspace source is absent while Conversations still reference it.', NULL)
            ON CONFLICT(domain, source_identity) DO UPDATE SET
              dirty = 1, import_state = 'mismatch', diagnostics = excluded.diagnostics
            """,
            [.text(identity), .text(id.uuidString)])
    }

    private func removeOrphanUnresolvedWorkspaces() throws {
        var orphans: [(id: String, source: String)] = []
        try query(
            """
            SELECT w.id, 'missing-workspace:' || w.id
            FROM workspaces w
            WHERE w.kind = 'unresolved'
              AND NOT EXISTS (SELECT 1 FROM conversations c WHERE c.workspace_id = w.id)
              AND NOT EXISTS (SELECT 1 FROM artifacts a WHERE a.workspace_id = w.id)
            """,
            []) { statement in
                guard let id = Self.optionalText(statement, 0),
                      let source = Self.optionalText(statement, 1) else { return }
                orphans.append((id, source))
            }
        for orphan in orphans {
            try execute("DELETE FROM workspaces WHERE id = ?1", [.text(orphan.id)])
            try execute(
                "DELETE FROM migration_sources WHERE domain = 'workspaces' AND source_identity = ?1",
                [.text(orphan.source)])
        }
    }

    private func workspaceReferenceCount(_ id: UUID) throws -> Int {
        var count = 0
        try query(
            """
            SELECT
              (SELECT COUNT(*) FROM conversations WHERE workspace_id = ?1) +
              (SELECT COUNT(*) FROM artifacts WHERE workspace_id = ?1)
            """,
            [.text(id.uuidString)]) { count = Int(sqlite3_column_int64($0, 0)) }
        return count
    }

    private func missingAccountedSources(
        expected: Set<String>,
        accounted: Set<String>
    ) -> Set<String> {
        return expected.subtracting(accounted)
    }

    /// Only sources successfully handled during this exact begin/finish pass may satisfy its
    /// census. Historical migration rows remain useful diagnostics but cannot certify new work.
    private func accountActiveReconciliation(
        domain: ShadowLibraryDomain,
        sourceIdentity: String
    ) {
        activeReconciliation?.account(domain: domain, sourceIdentity: sourceIdentity)
    }

    private func markFullCensus(domain: ShadowLibraryDomain, expected: Int) throws {
        try execute(
            """
            INSERT INTO domain_reconciliation (
              domain, full_census_completed_at, expected_source_count)
            VALUES (?1, ?2, ?3)
            ON CONFLICT(domain) DO UPDATE SET
              full_census_completed_at = excluded.full_census_completed_at,
              expected_source_count = excluded.expected_source_count
            """,
            [
                .text(domain.rawValue),
                .double(Date().timeIntervalSinceReferenceDate),
                .int(Int64(expected)),
            ])
    }

    private func sourceCount(domain: ShadowLibraryDomain) throws -> Int {
        var count = 0
        try query(
            "SELECT COUNT(*) FROM migration_sources WHERE domain = ?1",
            [.text(domain.rawValue)]) { count = Int(sqlite3_column_int64($0, 0)) }
        return count
    }

    private func readUUIDs(_ sql: String) throws -> [UUID] {
        var values: [UUID] = []
        try query(sql, []) { statement in
            guard let text = Self.optionalText(statement, 0), let id = UUID(uuidString: text) else {
                throw SQLiteLibraryStoreError.invalidInput("repository contains an invalid UUID")
            }
            values.append(id)
        }
        return values
    }

    private func supportRelativeURL(_ identity: String) throws -> URL {
        let components = identity.split(separator: "/", omittingEmptySubsequences: false)
        guard !identity.isEmpty,
              !identity.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SQLiteLibraryStoreError.invalidInput(
                "retained-byte storage identity is not support-root relative")
        }
        return components.reduce(supportRoot) {
            $0.appendingPathComponent(String($1), isDirectory: false)
        }
    }

    private func recordCurrentSource(
        domain: ShadowLibraryDomain,
        entityID: UUID,
        source: ShadowLibrarySourceFingerprint
    ) throws {
        try recordCurrentSource(
            domain: domain,
            entityIdentity: entityID.uuidString,
            source: source)
    }

    private func recordCurrentSource(
        domain: ShadowLibraryDomain,
        entityIdentity: String,
        source: ShadowLibrarySourceFingerprint
    ) throws {
        if domain == .workspaces {
            try execute(
                """
                DELETE FROM migration_sources
                WHERE domain = 'workspaces' AND entity_id = ?1
                  AND source_identity LIKE 'missing-workspace:%'
                """,
                [.text(entityIdentity)])
        }
        try execute(
            """
            INSERT INTO migration_sources (
              domain, source_identity, entity_id, observed_revision, observed_digest,
              source_byte_count, imported_revision, imported_digest, dirty, import_state,
              diagnostics, imported_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?4, ?5, 0, 'current', NULL, ?7)
            ON CONFLICT(domain, source_identity) DO UPDATE SET
              entity_id = excluded.entity_id,
              observed_revision = excluded.observed_revision,
              observed_digest = excluded.observed_digest,
              source_byte_count = excluded.source_byte_count,
              imported_revision = excluded.imported_revision,
              imported_digest = excluded.imported_digest,
              dirty = 0,
              import_state = 'current',
              diagnostics = NULL,
              imported_at = excluded.imported_at
            """,
            [
                .text(domain.rawValue), .text(source.identity), .text(entityIdentity),
                .text(source.revision), .text(source.digest), .int(Int64(source.byteCount)),
                .double(Date().timeIntervalSinceReferenceDate),
            ])
    }

    private func recordImportedArtifactMediaSource(
        entityIdentity: String,
        source: ShadowLibrarySourceFingerprint,
        state: String,
        diagnostics: String?
    ) throws {
        let dirty = state == "current" ? 0 : 1
        try execute(
            """
            INSERT INTO migration_sources (
              domain, source_identity, entity_id, observed_revision, observed_digest,
              source_byte_count, imported_revision, imported_digest, dirty, import_state,
              diagnostics, imported_at)
            VALUES ('artifact_media', ?1, ?2, ?3, ?4, ?5, ?3, ?4, ?6, ?7, ?8, ?9)
            ON CONFLICT(domain, source_identity) DO UPDATE SET
              entity_id = excluded.entity_id,
              observed_revision = excluded.observed_revision,
              observed_digest = excluded.observed_digest,
              source_byte_count = excluded.source_byte_count,
              imported_revision = excluded.imported_revision,
              imported_digest = excluded.imported_digest,
              dirty = excluded.dirty,
              import_state = excluded.import_state,
              diagnostics = excluded.diagnostics,
              imported_at = excluded.imported_at
            """,
            [
                .text(source.identity), .text(entityIdentity), .text(source.revision),
                .text(source.digest), .int(Int64(source.byteCount)), .int(Int64(dirty)),
                .text(state), diagnostics.map(SQLiteValue.text) ?? .null,
                .double(Date().timeIntervalSinceReferenceDate),
            ])
    }

    private func recordSourceIssueInternal(
        domain: ShadowLibraryDomain,
        source: ShadowLibrarySourceFingerprint,
        entityIdentity: String?,
        kind: ShadowLibrarySourceIssueKind,
        diagnostics: String
    ) throws {
        if domain == .artifactMedia {
            // A source that can no longer be decoded/read must not leave stale successful inventory
            // looking current. The legacy bytes remain untouched and the issue row stays visible.
            try execute(
                "DELETE FROM artifacts WHERE source_identity = ?1",
                [.text(source.identity)])
            try execute(
                "DELETE FROM retained_byte_sources WHERE source_identity = ?1",
                [.text(source.identity)])
        }
        try execute(
            """
            INSERT INTO migration_sources (
              domain, source_identity, entity_id, observed_revision, observed_digest,
              source_byte_count, imported_revision, imported_digest, dirty, import_state,
              diagnostics, imported_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, NULL, 1, ?7, ?8, NULL)
            ON CONFLICT(domain, source_identity) DO UPDATE SET
              entity_id = excluded.entity_id,
              observed_revision = excluded.observed_revision,
              observed_digest = excluded.observed_digest,
              source_byte_count = excluded.source_byte_count,
              imported_revision = NULL,
              imported_digest = NULL,
              dirty = 1,
              import_state = excluded.import_state,
              diagnostics = excluded.diagnostics,
              imported_at = NULL
            """,
            [
                .text(domain.rawValue), .text(source.identity),
                .text(entityIdentity ?? "unparsed:\(source.digest)"),
                .text(source.revision), .text(source.digest),
                .int(Int64(source.byteCount)), .text(kind.rawValue), .text(diagnostics),
            ])
    }

    private func recordRejectedSource(
        domain: ShadowLibraryDomain,
        entityID: UUID,
        source: ShadowLibrarySourceFingerprint,
        diagnostics: String
    ) throws {
        try execute(
            """
            INSERT INTO migration_sources (
              domain, source_identity, entity_id, observed_revision, observed_digest,
              source_byte_count, imported_revision, imported_digest, dirty, import_state,
              diagnostics, imported_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, NULL, 1, 'mismatch', ?7, NULL)
            ON CONFLICT(domain, source_identity) DO UPDATE SET
              entity_id = excluded.entity_id,
              observed_revision = excluded.observed_revision,
              observed_digest = excluded.observed_digest,
              source_byte_count = excluded.source_byte_count,
              dirty = 1,
              import_state = 'mismatch',
              diagnostics = excluded.diagnostics
            """,
            [
                .text(domain.rawValue), .text(source.identity), .text(entityID.uuidString),
                .text(source.revision), .text(source.digest), .int(Int64(source.byteCount)),
                .text(diagnostics),
            ])
    }

    private func sourceIsCurrent(
        domain: ShadowLibraryDomain,
        source: ShadowLibrarySourceFingerprint,
        entityID: UUID
    ) throws -> Bool {
        var current = false
        let entityTable: String
        switch domain {
        case .conversations, .operativeState: entityTable = "conversations"
        case .workspaces: entityTable = "workspaces"
        case .artifactMedia: entityTable = "artifacts"
        case .ambientState, .operations:
            throw SQLiteLibraryStoreError.invalidInput(
                "generic entity current-check does not support \(domain.rawValue)")
        }
        try query(
            """
            SELECT 1 FROM migration_sources
            WHERE domain = ?1 AND source_identity = ?2 AND entity_id = ?3
              AND observed_revision = ?4 AND observed_digest = ?5
              AND imported_revision = ?4 AND imported_digest = ?5
              AND dirty = 0 AND import_state = 'current'
              AND EXISTS (
                SELECT 1 FROM \(entityTable)
                WHERE id = ?3 AND source_identity = ?2
              )
            """,
            [
                .text(domain.rawValue), .text(source.identity), .text(entityID.uuidString),
                .text(source.revision), .text(source.digest),
            ]) { _ in current = true }
        return current
    }

    private func normalizedRetainedByte(
        _ retained: ShadowLibraryRetainedByteSnapshot
    ) throws -> NormalizedRetainedByte {
        let ownerExists = try retained.ownerConversationID.map(conversationExists) ?? false
        let linkState: ShadowLibraryRetainedByteSnapshot.LinkState
        if retained.kind == .conversationMedia,
           retained.linkState == .current,
           retained.disposition != .unclaimedRecovery,
           !ownerExists {
            // Active media claims a live relationship, so a missing Conversation is a mismatch.
            linkState = .orphan
        } else {
            // Trash is retained historical evidence. Its former Conversation is not required to
            // remain in the live library for the retained trash bytes themselves to be current.
            linkState = retained.linkState
        }
        let diagnostics = linkState == .orphan
            ? (retained.diagnostics ?? "Retained bytes do not have a current Conversation source.")
            : retained.diagnostics
        return NormalizedRetainedByte(linkState: linkState, diagnostics: diagnostics)
    }

    private func retainedByteIsCurrent(
        _ retained: ShadowLibraryRetainedByteSnapshot,
        normalized: NormalizedRetainedByte
    ) throws -> Bool {
        let entityIdentity = retained.ownerConversationID?.uuidString
            ?? "retained:\(retained.source.identity)"
        var current = false
        try query(
            """
            SELECT 1
            FROM retained_byte_sources r
            JOIN migration_sources m
              ON m.domain = 'artifact_media' AND m.source_identity = r.source_identity
            WHERE r.source_identity = ?1
              AND r.kind = ?2
              AND (
                r.owner_conversation_id IS ?3 OR
                (?12 = 'observed' AND ?16 = 'reference_pending'
                  AND r.owner_conversation_id IS NULL
                  AND r.disposition = 'unclaimed_recovery')
              )
              AND r.storage_name = ?4
              AND r.observed_revision = ?5
              AND r.digest = ?6
              AND r.byte_count = ?7
              AND r.media_type = ?8
              AND r.link_state = ?9
              AND r.diagnostics IS ?10
              AND r.storage_class = ?11
              AND (
                (r.storage_state = ?12 AND r.retention_state = ?14
                  AND r.disposition = ?16) OR
                (?12 = 'observed' AND ?14 = 'live' AND ?16 = 'reference_pending'
                  AND r.storage_state = 'adopted' AND r.retention_state = 'live'
                  AND r.disposition = 'referenced') OR
                (?12 = 'observed' AND ?14 = 'live' AND ?16 = 'reference_pending'
                  AND r.storage_state = 'observed' AND r.retention_state = 'live'
                  AND r.disposition = 'unclaimed_recovery')
              )
              AND r.storage_identity = ?13
              AND r.managed_blob_digest IS ?15
              AND (
                m.entity_id = ?17 OR
                (?12 = 'observed' AND ?16 = 'reference_pending'
                  AND r.disposition = 'unclaimed_recovery'
                  AND m.entity_id = 'retained:' || r.source_identity)
              )
              AND m.observed_revision = ?5
              AND m.observed_digest = ?6
              AND m.source_byte_count = ?7
              AND m.imported_revision = ?5
              AND m.imported_digest = ?6
              AND m.dirty = ?18
              AND m.import_state = ?19
              AND m.diagnostics IS ?10
            """,
            [
                .text(retained.source.identity), .text(retained.kind.rawValue),
                retained.ownerConversationID.map { .text($0.uuidString) } ?? .null,
                .text(retained.storageName), .text(retained.source.revision),
                .text(retained.source.digest), .int(Int64(retained.source.byteCount)),
                .text(retained.mediaType), .text(normalized.linkState.rawValue),
                normalized.diagnostics.map(SQLiteValue.text) ?? .null,
                .text(retained.storageClass.rawValue), .text(retained.storageState.rawValue),
                .text(retained.storageIdentity), .text(retained.retentionState.rawValue),
                retained.managedBlobDigest.map(SQLiteValue.text) ?? .null,
                .text(retained.disposition.rawValue), .text(entityIdentity),
                .int(normalized.entityIsCurrent ? 0 : 1),
                .text(normalized.importState),
            ]) { _ in current = true }
        return current
    }

    private func sourceIssueIsCurrent(
        _ issue: ShadowLibraryArtifactMediaSourceIssue
    ) throws -> Bool {
        var current = false
        try query(
            """
            SELECT 1 FROM migration_sources m
            WHERE m.domain = 'artifact_media' AND m.source_identity = ?1
              AND m.entity_id = ?2
              AND m.observed_revision = ?3 AND m.observed_digest = ?4
              AND m.source_byte_count = ?5
              AND m.imported_revision IS NULL AND m.imported_digest IS NULL
              AND m.dirty = 1 AND m.import_state = ?6 AND m.diagnostics = ?7
              AND NOT EXISTS (SELECT 1 FROM artifacts a WHERE a.source_identity = ?1)
              AND NOT EXISTS (
                SELECT 1 FROM retained_byte_sources r WHERE r.source_identity = ?1)
            """,
            [
                .text(issue.source.identity),
                .text(issue.entityIdentity ?? "unparsed:\(issue.source.digest)"),
                .text(issue.source.revision), .text(issue.source.digest),
                .int(Int64(issue.source.byteCount)), .text(issue.kind.rawValue),
                .text(issue.diagnostics),
            ]) { _ in current = true }
        return current
    }

    // MARK: - Conversation work evidence

    private func insertConversationRepositoryObservation(
        _ value: ConversationRepositoryObservation
    ) throws {
        try execute(
            """
            INSERT INTO conversation_repository_observations (
              id, conversation_id, turn_id, tool_use_id, reason,
              root_prompt_entry_id, final_assistant_entry_id,
              root_prompt_excerpt, root_prompt_excerpt_was_truncated,
              final_assistant_excerpt, final_assistant_excerpt_was_truncated,
              repository_id, git_common_directory, worktree_path, workspace_id, canonical_cwd,
              head_state, symbolic_ref, head_oid, status_availability,
              index_change_count, worktree_change_count, untracked_count,
              attribution, observed_at)
            VALUES (
              ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
              ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25)
            """,
            [
                .text(value.id.uuidString), .text(value.conversationID.uuidString),
                .text(value.turnID), value.toolUseID.map(SQLiteValue.text) ?? .null,
                .text(value.reason.rawValue),
                value.rootPromptEntryID.map { .text($0.uuidString) } ?? .null,
                value.finalAssistantEntryID.map { .text($0.uuidString) } ?? .null,
                value.rootPromptExcerpt.map(SQLiteValue.text) ?? .null,
                value.rootPromptExcerptWasTruncated.map(SQLiteValue.bool) ?? .null,
                value.finalAssistantExcerpt.map(SQLiteValue.text) ?? .null,
                value.finalAssistantExcerptWasTruncated.map(SQLiteValue.bool) ?? .null,
                .text(value.repositoryID), .text(value.gitCommonDirectory),
                .text(value.worktreePath),
                value.workspaceID.map { .text($0.uuidString) } ?? .null,
                value.canonicalCWD.map(SQLiteValue.text) ?? .null,
                value.headState.map { .text($0.rawValue) } ?? .null,
                value.symbolicRef.map(SQLiteValue.text) ?? .null,
                value.headOID.map(SQLiteValue.text) ?? .null,
                .text(value.statusAvailability.rawValue),
                value.indexChangeCount.map { .int(Int64($0)) } ?? .null,
                value.worktreeChangeCount.map { .int(Int64($0)) } ?? .null,
                value.untrackedCount.map { .int(Int64($0)) } ?? .null,
                value.attribution.map { .text($0.rawValue) } ?? .null,
                .double(value.observedAt.timeIntervalSinceReferenceDate),
            ])
    }

    private func insertConversationFileObservation(
        _ value: ConversationFileObservation
    ) throws {
        try execute(
            """
            INSERT INTO conversation_file_observations (
              id, repository_observation_id, conversation_id, turn_id, tool_use_id,
              repository_id, repository_relative_path, operation, attribution,
              before_digest, after_digest, before_exists, after_exists,
              bounded_patch, patch_was_truncated, observed_at)
            VALUES (
              ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8,
              ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
            """,
            [
                .text(value.id.uuidString), .text(value.repositoryObservationID.uuidString),
                .text(value.conversationID.uuidString), .text(value.turnID),
                .text(value.toolUseID), .text(value.repositoryID),
                .text(value.repositoryRelativePath), .text(value.operation.rawValue),
                .text(value.attribution.rawValue),
                value.beforeDigest.map(SQLiteValue.text) ?? .null,
                value.afterDigest.map(SQLiteValue.text) ?? .null,
                value.beforeExists.map(SQLiteValue.bool) ?? .null,
                value.afterExists.map(SQLiteValue.bool) ?? .null,
                value.boundedPatch.map(SQLiteValue.text) ?? .null,
                .bool(value.patchWasTruncated),
                .double(value.observedAt.timeIntervalSinceReferenceDate),
            ])
    }

    private func readConversationWorkEvidence(
        repositoryID: String
    ) throws -> [ConversationWorkEvidence] {
        let repositories = try readConversationRepositoryObservations(
            whereSQL: "repository_id = ?1", values: [.text(repositoryID)])
        let files = try readConversationFileObservations(
            whereSQL: "repository_id = ?1", values: [.text(repositoryID)])
        let filesByObservation = Dictionary(grouping: files, by: \.repositoryObservationID)
        return repositories.map {
            ConversationWorkEvidence(
                repository: $0,
                files: filesByObservation[$0.id] ?? [])
        }
    }

    private func readConversationWorkEvidence(
        conversationID: UUID
    ) throws -> [ConversationWorkEvidence] {
        let repositories = try readConversationRepositoryObservations(
            whereSQL: "conversation_id = ?1", values: [.text(conversationID.uuidString)])
        let files = try readConversationFileObservations(
            whereSQL: "conversation_id = ?1", values: [.text(conversationID.uuidString)])
        let filesByObservation = Dictionary(grouping: files, by: \.repositoryObservationID)
        return repositories.map {
            ConversationWorkEvidence(
                repository: $0,
                files: filesByObservation[$0.id] ?? [])
        }
    }

    private func readConversationRepositoryObservations(
        whereSQL: String,
        values: [SQLiteValue]
    ) throws -> [ConversationRepositoryObservation] {
        var result: [ConversationRepositoryObservation] = []
        try query(
            """
            SELECT id, conversation_id, turn_id, tool_use_id, reason,
                   root_prompt_entry_id, final_assistant_entry_id,
                   root_prompt_excerpt, root_prompt_excerpt_was_truncated,
                   final_assistant_excerpt, final_assistant_excerpt_was_truncated,
                   repository_id, git_common_directory, worktree_path, workspace_id, canonical_cwd,
                   head_state, symbolic_ref, head_oid, status_availability,
                   index_change_count, worktree_change_count, untracked_count,
                   attribution, observed_at
            FROM conversation_repository_observations
            WHERE \(whereSQL)
            ORDER BY observed_at DESC, id DESC
            """,
            values) { statement in
                result.append(try Self.decodeConversationRepositoryObservation(statement))
            }
        return result
    }

    private func readConversationRepositoryObservation(
        id: UUID
    ) throws -> ConversationRepositoryObservation? {
        var result: ConversationRepositoryObservation?
        try query(
            """
            SELECT id, conversation_id, turn_id, tool_use_id, reason,
                   root_prompt_entry_id, final_assistant_entry_id,
                   root_prompt_excerpt, root_prompt_excerpt_was_truncated,
                   final_assistant_excerpt, final_assistant_excerpt_was_truncated,
                   repository_id, git_common_directory, worktree_path, workspace_id, canonical_cwd,
                   head_state, symbolic_ref, head_oid, status_availability,
                   index_change_count, worktree_change_count, untracked_count,
                   attribution, observed_at
            FROM conversation_repository_observations WHERE id = ?1
            """,
            [.text(id.uuidString)]) { statement in
                guard result == nil else {
                    throw SQLiteLibraryStoreError.sqlite(
                        "duplicate repository observation identity")
                }
                result = try Self.decodeConversationRepositoryObservation(statement)
            }
        return result
    }

    private static func decodeConversationRepositoryObservation(
        _ statement: OpaquePointer
    ) throws -> ConversationRepositoryObservation {
        guard let id = try optionalUUID(statement, 0, label: "repository observation id"),
              let conversationID = try optionalUUID(
                statement, 1, label: "repository observation Conversation id"),
              let turnID = optionalText(statement, 2),
              let reasonRaw = optionalText(statement, 4),
              let reason = ConversationRepositoryObservationReason(rawValue: reasonRaw),
              let repositoryID = optionalText(statement, 11),
              let gitCommonDirectory = optionalText(statement, 12),
              let worktreePath = optionalText(statement, 13),
              let statusRaw = optionalText(statement, 19),
              let status = ConversationRepositoryStatusAvailability(rawValue: statusRaw) else {
            throw SQLiteLibraryStoreError.sqlite(
                "malformed repository observation row")
        }
        let headState: ConversationRepositoryHeadState?
        if let raw = optionalText(statement, 16) {
            guard let decoded = ConversationRepositoryHeadState(rawValue: raw) else {
                throw SQLiteLibraryStoreError.sqlite("malformed repository HEAD state")
            }
            headState = decoded
        } else {
            headState = nil
        }
        let attribution: ConversationWorkAttribution?
        if let raw = optionalText(statement, 23) {
            guard let decoded = ConversationWorkAttribution(rawValue: raw) else {
                throw SQLiteLibraryStoreError.sqlite("malformed repository observation attribution")
            }
            attribution = decoded
        } else {
            attribution = nil
        }
        return ConversationRepositoryObservation(
            id: id,
            conversationID: conversationID,
            turnID: turnID,
            toolUseID: optionalText(statement, 3),
            reason: reason,
            rootPromptEntryID: try optionalUUID(statement, 5, label: "root prompt entry id"),
            finalAssistantEntryID: try optionalUUID(
                statement, 6, label: "final assistant entry id"),
            rootPromptExcerpt: optionalText(statement, 7),
            rootPromptExcerptWasTruncated: optionalInt(statement, 8).map { $0 != 0 },
            finalAssistantExcerpt: optionalText(statement, 9),
            finalAssistantExcerptWasTruncated: optionalInt(statement, 10).map { $0 != 0 },
            repositoryID: repositoryID,
            gitCommonDirectory: gitCommonDirectory,
            worktreePath: worktreePath,
            workspaceID: try optionalUUID(statement, 14, label: "Workspace id"),
            canonicalCWD: optionalText(statement, 15),
            headState: headState,
            symbolicRef: optionalText(statement, 17),
            headOID: optionalText(statement, 18),
            statusAvailability: status,
            indexChangeCount: try decodeConversationWorkEvidenceCount(statement, 20),
            worktreeChangeCount: try decodeConversationWorkEvidenceCount(statement, 21),
            untrackedCount: try decodeConversationWorkEvidenceCount(statement, 22),
            attribution: attribution,
            observedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 24)))
    }

    private static func decodeConversationWorkEvidenceCount(
        _ statement: OpaquePointer,
        _ column: Int32
    ) throws -> Int? {
        guard let raw = optionalInt(statement, column) else { return nil }
        guard raw >= 0, raw <= Int64(Int.max) else {
            throw SQLiteLibraryStoreError.sqlite(
                "malformed repository status count")
        }
        return Int(raw)
    }

    private func readConversationFileObservations(
        repositoryObservationID: UUID
    ) throws -> [ConversationFileObservation] {
        try readConversationFileObservations(
            whereSQL: "repository_observation_id = ?1",
            values: [.text(repositoryObservationID.uuidString)])
    }

    private func readConversationFileObservations(
        whereSQL: String,
        values: [SQLiteValue]
    ) throws -> [ConversationFileObservation] {
        var result: [ConversationFileObservation] = []
        try query(
            """
            SELECT id, repository_observation_id, conversation_id, turn_id, tool_use_id,
                   repository_id, repository_relative_path, operation, attribution,
                   before_digest, after_digest, before_exists, after_exists,
                   bounded_patch, patch_was_truncated, observed_at
            FROM conversation_file_observations
            WHERE \(whereSQL)
            ORDER BY repository_observation_id, observed_at, repository_relative_path, id
            """,
            values) { statement in
                result.append(try Self.decodeConversationFileObservation(statement))
            }
        return result
    }

    private func readConversationFileObservation(
        id: UUID
    ) throws -> ConversationFileObservation? {
        var result: ConversationFileObservation?
        try query(
            """
            SELECT id, repository_observation_id, conversation_id, turn_id, tool_use_id,
                   repository_id, repository_relative_path, operation, attribution,
                   before_digest, after_digest, before_exists, after_exists,
                   bounded_patch, patch_was_truncated, observed_at
            FROM conversation_file_observations WHERE id = ?1
            """,
            [.text(id.uuidString)]) { statement in
                guard result == nil else {
                    throw SQLiteLibraryStoreError.sqlite("duplicate file observation identity")
                }
                result = try Self.decodeConversationFileObservation(statement)
            }
        return result
    }

    private static func decodeConversationFileObservation(
        _ statement: OpaquePointer
    ) throws -> ConversationFileObservation {
        guard let id = try optionalUUID(statement, 0, label: "file observation id"),
              let repositoryObservationID = try optionalUUID(
                statement, 1, label: "repository observation id"),
              let conversationID = try optionalUUID(
                statement, 2, label: "file observation Conversation id"),
              let turnID = optionalText(statement, 3),
              let toolUseID = optionalText(statement, 4),
              let repositoryID = optionalText(statement, 5),
              let path = optionalText(statement, 6),
              let operationRaw = optionalText(statement, 7),
              let operation = ConversationFileOperation(rawValue: operationRaw),
              let attributionRaw = optionalText(statement, 8),
              let attribution = ConversationWorkAttribution(rawValue: attributionRaw) else {
            throw SQLiteLibraryStoreError.sqlite("malformed file observation row")
        }
        return ConversationFileObservation(
            id: id,
            repositoryObservationID: repositoryObservationID,
            conversationID: conversationID,
            turnID: turnID,
            toolUseID: toolUseID,
            repositoryID: repositoryID,
            repositoryRelativePath: path,
            operation: operation,
            attribution: attribution,
            beforeDigest: optionalText(statement, 9),
            afterDigest: optionalText(statement, 10),
            beforeExists: optionalInt(statement, 11).map { $0 != 0 },
            afterExists: optionalInt(statement, 12).map { $0 != 0 },
            boundedPatch: optionalText(statement, 13),
            patchWasTruncated: sqlite3_column_int64(statement, 14) != 0,
            observedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 15)))
    }

    // MARK: - Validation and status

    private func validate(_ snapshot: ShadowLibraryImportSnapshot) throws {
        try validate(workspace: snapshot.home)
        guard snapshot.home.kind == .home else {
            throw SQLiteLibraryStoreError.invalidInput("the full snapshot must contain Home")
        }
        var workspaceIDs = Set([Self.homeWorkspaceID])
        var workspaceSources = Set([snapshot.home.source.identity])
        for workspace in snapshot.workspaces {
            try validate(workspace: workspace)
            guard workspace.kind == .named else {
                throw SQLiteLibraryStoreError.invalidInput("only the reserved row may be Home")
            }
            guard workspaceIDs.insert(workspace.id).inserted else {
                throw SQLiteLibraryStoreError.invalidInput("duplicate Workspace id \(workspace.id)")
            }
            guard workspaceSources.insert(workspace.source.identity).inserted else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "duplicate Workspace source \(workspace.source.identity)")
            }
        }
        var conversationIDs = Set<UUID>()
        var conversationSources = Set<String>()
        for conversation in snapshot.conversations {
            try validate(conversation: conversation)
            guard conversationIDs.insert(conversation.id).inserted else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "duplicate Conversation id \(conversation.id)")
            }
            guard conversationSources.insert(conversation.source.identity).inserted else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "duplicate Conversation source \(conversation.source.identity)")
            }
        }
    }

    private func validate(workspace: ShadowLibraryWorkspaceSnapshot) throws {
        try validate(source: workspace.source)
        try validateLocalState(
            version: workspace.localStateVersion,
            payload: workspace.localStatePayload,
            owner: "Workspace")
        switch workspace.kind {
        case .home where workspace.id != Self.homeWorkspaceID:
            throw SQLiteLibraryStoreError.invalidInput("Home must use the reserved Workspace id")
        case .named where workspace.id == Self.homeWorkspaceID,
             .unresolved where workspace.id == Self.homeWorkspaceID:
            throw SQLiteLibraryStoreError.invalidInput("a named Workspace cannot use the Home id")
        default:
            break
        }
    }

    private func validate(conversation: ShadowLibraryConversationSnapshot) throws {
        try validate(source: conversation.source)
        try validateLocalState(
            version: conversation.localStateVersion,
            payload: conversation.localStatePayload,
            owner: "Conversation")
        guard !conversation.titleSource.isEmpty else {
            throw SQLiteLibraryStoreError.invalidInput("Conversation title source is empty")
        }
        var eventIDs = Set<UUID>()
        var sequences = Set<Int64>()
        for event in conversation.events {
            guard event.captureSequence >= 0 else {
                throw SQLiteLibraryStoreError.invalidInput("event capture sequence is negative")
            }
            guard !event.kind.isEmpty else {
                throw SQLiteLibraryStoreError.invalidInput("event kind is empty")
            }
            guard eventIDs.insert(event.id).inserted else {
                throw SQLiteLibraryStoreError.invalidInput("duplicate event id \(event.id)")
            }
            guard sequences.insert(event.captureSequence).inserted else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "duplicate capture sequence \(event.captureSequence)")
            }
        }
        var artifactIDs = Set<UUID>()
        for artifact in conversation.nestedArtifacts {
            guard artifactIDs.insert(artifact.artifactID).inserted else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "duplicate nested artifact id \(artifact.artifactID)")
            }
            guard artifact.contentByteCount >= 0 else {
                throw SQLiteLibraryStoreError.invalidInput("nested artifact byte count is negative")
            }
            guard artifact.canonicalPayloadDigest == Self.digest(artifact.canonicalPayload) else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "nested artifact canonical payload digest does not match its bytes")
            }
            guard !artifact.contentDigest.isEmpty else {
                throw SQLiteLibraryStoreError.invalidInput("nested artifact content digest is empty")
            }
        }
    }

    private func validateAuthoritativeConversationMutation(
        _ conversation: ShadowLibraryConversationSnapshot,
        changedTranscriptEntryIDs: Set<UUID>?,
        liveTranscriptOrder: [UUID]?
    ) throws {
        try validate(conversation: conversation)
        // The ordering decides which stored rows survive, so a capture that disagrees with it would
        // delete live transcript rows. Refuse before any row is touched rather than trust the pair.
        if let liveTranscriptOrder {
            var positions: [UUID: Int64] = [:]
            positions.reserveCapacity(liveTranscriptOrder.count)
            for (index, id) in liveTranscriptOrder.enumerated() {
                guard positions.updateValue(Int64(index), forKey: id) == nil else {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "live transcript order repeats entry \(id)")
                }
            }
            for event in conversation.events where event.kind.hasPrefix("transcript.") {
                guard positions[event.id] == event.captureSequence else {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "captured transcript event \(event.id) contradicts the live transcript order")
                }
            }
            for event in conversation.events where !event.kind.hasPrefix("transcript.") {
                guard positions[event.id] == nil else {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "non-transcript event \(event.id) appears in the live transcript order")
                }
            }
        }
        guard let changedTranscriptEntryIDs else { return }
        // A partial capture omits rows the record still holds, so without the ordering this write
        // cannot tell an omitted row from a removed one and would delete the transcript down to
        // whatever the delta happened to name. The two arguments are only meaningful together.
        guard liveTranscriptOrder != nil else {
            throw SQLiteLibraryStoreError.invalidInput(
                "a partial authoritative capture requires the live transcript order")
        }
        let suppliedTranscriptIDs = Set(conversation.events.compactMap { event in
            event.kind.hasPrefix("transcript.") ? event.id : nil
        })
        guard suppliedTranscriptIDs.isSubset(of: changedTranscriptEntryIDs) else {
            throw SQLiteLibraryStoreError.invalidInput(
                "partial authoritative capture supplied an unmarked transcript event")
        }
        guard conversation.events.contains(where: { $0.kind == "conversation.metadata" }) else {
            throw SQLiteLibraryStoreError.invalidInput(
                "partial authoritative capture omitted Conversation metadata")
        }
    }

    private func validate(ambient inventory: ShadowLibraryAmbientInventory) throws {
        var kinds = Set<LibraryAmbientAuthoritySourceKind>()
        var identities = Set<String>()
        for source in inventory.sources {
            try validate(ambient: source)
            guard kinds.insert(source.kind).inserted else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "duplicate ambient authority kind \(source.kind.rawValue)")
            }
            guard identities.insert(source.source.identity).inserted else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "duplicate ambient source \(source.source.identity)")
            }
        }
        for issue in inventory.sourceIssues {
            try validate(source: issue.source)
            guard !issue.diagnostics.isEmpty else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "ambient source issue diagnosis is empty")
            }
            guard identities.insert(issue.source.identity).inserted else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "duplicate ambient source \(issue.source.identity)")
            }
        }
    }

    private func validate(ambient snapshot: ShadowLibraryAmbientSnapshot) throws {
        try validate(source: snapshot.source)
        guard snapshot.kind.requiresAuthorityRepresentation else {
            throw SQLiteLibraryStoreError.invalidInput(
                "ephemeral ambient state cannot become authority")
        }
        guard snapshot.payloadVersion > 0 else {
            throw SQLiteLibraryStoreError.invalidInput(
                "ambient payload version is not positive")
        }
        guard snapshot.payload.count <= LibraryAmbientAuthorityAdapter.maximumSourceBytes else {
            throw SQLiteLibraryStoreError.invalidInput("ambient payload exceeds its bounded size")
        }
        _ = try LibraryAmbientAuthorityAdapter.freshLegacyData(
            version: snapshot.payloadVersion,
            payload: snapshot.payload,
            expectedKind: snapshot.kind)
    }

    private func validate(
        operationInventory inventory: ShadowLibraryOperationInventory
    ) throws {
        var operationIDs = Set<UUID>()
        var idempotencyKeys = Set<String>()
        var sourceIdentities = Set<String>()
        var kindsByOperation: [UUID: LibraryOperationKind] = [:]
        for value in inventory.operations {
            try validate(source: value.source)
            let operation = value.operation
            guard operationIDs.insert(operation.id).inserted else {
                throw SQLiteLibraryStoreError.invalidInput("duplicate operation identity")
            }
            guard idempotencyKeys.insert(operation.idempotencyKey).inserted else {
                throw SQLiteLibraryStoreError.invalidInput("duplicate operation idempotency key")
            }
            guard sourceIdentities.insert(value.source.identity).inserted else {
                throw SQLiteLibraryStoreError.invalidInput("duplicate operation source identity")
            }
            switch operation.kind {
            case .conversationDelete: _ = try operation.conversationDeletePayload()
            case .artifactDelete: _ = try operation.artifactDeletePayload()
            case .workspaceMove: _ = try operation.workspaceMovePayload()
            case .backgroundAdoption: _ = try operation.backgroundAdoptionPayload()
            }
            kindsByOperation[operation.id] = operation.kind
        }

        var receiptIDs = Set<UUID>()
        var receiptAttempts = Set<String>()
        var operationsWithReceipts = Set<UUID>()
        for receipt in inventory.receipts {
            guard receiptIDs.insert(receipt.id).inserted,
                  kindsByOperation[receipt.operationID] == receipt.operationKind else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "operation receipt identity or kind is invalid")
            }
            let attemptKey = "\(receipt.operationID.uuidString):\(receipt.attempt)"
            guard receiptAttempts.insert(attemptKey).inserted else {
                throw SQLiteLibraryStoreError.invalidInput("duplicate operation receipt attempt")
            }
            _ = try receipt.details()
            operationsWithReceipts.insert(receipt.operationID)
        }
        guard operationsWithReceipts == operationIDs else {
            throw SQLiteLibraryStoreError.invalidInput(
                "every operation must have at least one durable receipt")
        }

        for retained in inventory.retainedSources {
            try validate(source: retained.source)
            guard kindsByOperation[retained.operationID] != nil,
                  sourceIdentities.insert(retained.source.identity).inserted,
                  !retained.storageIdentity.isEmpty,
                  !retained.mediaType.isEmpty,
                  !retained.referenceKind.isEmpty else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "operation-retained source has an invalid owner or identity")
            }
            guard retained.retentionState == "undo_retained"
                    || retained.retentionState == "quarantined" else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "operation-retained source has an invalid retention state")
            }
        }
        for issue in inventory.sourceIssues {
            try validate(source: issue.source)
            guard sourceIdentities.insert(issue.source.identity).inserted,
                  !issue.diagnostics.isEmpty else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "operation source issue has an invalid owner or identity")
            }
        }
    }

    private func validate(artifact: ShadowLibraryArtifactSnapshot) throws {
        try validate(source: artifact.source)
        guard artifact.revision >= 0 else {
            throw SQLiteLibraryStoreError.invalidInput("Artifact revision is negative")
        }
        guard !artifact.type.isEmpty else {
            throw SQLiteLibraryStoreError.invalidInput("Artifact type is empty")
        }
        guard !artifact.payloadMediaType.isEmpty else {
            throw SQLiteLibraryStoreError.invalidInput("Artifact media type is empty")
        }
        guard artifact.contentByteCount == artifact.content.count else {
            throw SQLiteLibraryStoreError.invalidInput(
                "Artifact content byte count does not match its bytes")
        }
        guard artifact.contentDigest == Self.digest(artifact.content) else {
            throw SQLiteLibraryStoreError.invalidInput(
                "Artifact content digest does not match its bytes")
        }
        guard artifact.canonicalPayloadDigest == Self.digest(artifact.canonicalPayload) else {
            throw SQLiteLibraryStoreError.invalidInput(
                "Artifact canonical payload digest does not match its bytes")
        }
        guard artifact.source.byteCount == artifact.rawSourcePayload.count,
              artifact.source.digest == Self.digest(artifact.rawSourcePayload) else {
            throw SQLiteLibraryStoreError.invalidInput(
                "Artifact source fingerprint does not match its raw bytes")
        }
        if let producerTaskID = artifact.producerTaskID, producerTaskID.isEmpty {
            throw SQLiteLibraryStoreError.invalidInput("Artifact producer task id is empty")
        }
    }

    private func validate(retainedByte: ShadowLibraryRetainedByteSnapshot) throws {
        try validate(source: retainedByte.source)
        guard !retainedByte.storageName.isEmpty else {
            throw SQLiteLibraryStoreError.invalidInput("retained-byte storage name is empty")
        }
        guard !retainedByte.mediaType.isEmpty else {
            throw SQLiteLibraryStoreError.invalidInput("retained-byte media type is empty")
        }
        if retainedByte.linkState != .current,
           retainedByte.diagnostics?.isEmpty != false {
            throw SQLiteLibraryStoreError.invalidInput(
                "non-current retained bytes require diagnostics")
        }
        guard !retainedByte.storageIdentity.isEmpty else {
            throw SQLiteLibraryStoreError.invalidInput("retained-byte storage identity is empty")
        }
        switch (retainedByte.storageClass, retainedByte.storageState, retainedByte.managedBlobDigest) {
        case (.legacyLayout, .observed, nil), (.legacyLayout, .adopted, nil):
            break
        case (.digestAddressed, .materialized, .some(let digest))
            where digest == retainedByte.source.digest:
            break
        default:
            throw SQLiteLibraryStoreError.invalidInput(
                "retained-byte storage class/state/digest combination is invalid")
        }
        switch (retainedByte.kind, retainedByte.storageState, retainedByte.disposition) {
        case (.conversationMedia, .observed, .referencePending),
             (.conversationMedia, .observed, .unclaimedRecovery),
             (.conversationMedia, .adopted, .referenced),
             (.conversationMedia, .materialized, .referenced),
             (.conversationTrashMedia, .observed, .undoRecovery),
             (.conversationTrashMedia, .materialized, .undoRecovery):
            break
        default:
            throw SQLiteLibraryStoreError.invalidInput(
                "retained-byte disposition does not match its source class")
        }
    }

    private func validateConversationWorkEvidence(
        repository: ConversationRepositoryObservation,
        files: [ConversationFileObservation]
    ) throws {
        try validateBoundedWorkEvidenceText(
            repository.turnID, maximumBytes: 512, label: "turn id")
        if let toolUseID = repository.toolUseID {
            try validateBoundedWorkEvidenceText(
                toolUseID, maximumBytes: 512, label: "tool-use id")
        }
        try validateBoundedWorkEvidenceText(
            repository.repositoryID, maximumBytes: 2_048, label: "repository id")
        try validateCanonicalWorkEvidencePath(
            repository.gitCommonDirectory, label: "Git common directory")
        try validateCanonicalWorkEvidencePath(
            repository.worktreePath, label: "worktree")
        if let cwd = repository.canonicalCWD {
            try validateCanonicalWorkEvidencePath(cwd, label: "working directory")
        }
        guard repository.observedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SQLiteLibraryStoreError.invalidInput(
                "repository observation timestamp is not finite")
        }
        try validateConversationWorkEvidenceExcerpt(
            repository.rootPromptExcerpt,
            wasTruncated: repository.rootPromptExcerptWasTruncated,
            entryID: repository.rootPromptEntryID,
            label: "root prompt")
        try validateConversationWorkEvidenceExcerpt(
            repository.finalAssistantExcerpt,
            wasTruncated: repository.finalAssistantExcerptWasTruncated,
            entryID: repository.finalAssistantEntryID,
            label: "final assistant")
        if let symbolicRef = repository.symbolicRef {
            try validateBoundedWorkEvidenceText(
                symbolicRef, maximumBytes: 4_096, label: "symbolic ref")
            guard symbolicRef.hasPrefix("refs/") else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "repository symbolic ref is not a full ref")
            }
        }
        if let headOID = repository.headOID,
           !Self.isLowercaseHex(headOID, lengths: [40, 64]) {
            throw SQLiteLibraryStoreError.invalidInput(
                "repository HEAD is not a full lowercase object id")
        }
        switch repository.statusAvailability {
        case .unavailable:
            guard repository.indexChangeCount == nil,
                  repository.worktreeChangeCount == nil,
                  repository.untrackedCount == nil else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "an unavailable Git status cannot assert change-count facts")
            }
        case .available:
            guard let indexChangeCount = repository.indexChangeCount,
                  let worktreeChangeCount = repository.worktreeChangeCount,
                  let untrackedCount = repository.untrackedCount,
                  indexChangeCount >= 0, worktreeChangeCount >= 0, untrackedCount >= 0 else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "an available Git status requires nonnegative change counts")
            }
        }
        switch repository.headState {
        case .attached?:
            guard repository.symbolicRef != nil, repository.headOID != nil else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "an attached HEAD requires a full ref and object id")
            }
        case .detached?:
            guard repository.symbolicRef == nil, repository.headOID != nil else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "a detached HEAD requires an object id and no symbolic ref")
            }
        case .unborn?:
            guard repository.symbolicRef != nil, repository.headOID == nil else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "an unborn HEAD requires a full ref and no object id")
            }
        case nil:
            guard repository.symbolicRef == nil, repository.headOID == nil else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "an unavailable HEAD cannot assert a symbolic ref or object id")
            }
        }
        if repository.reason == .toolCompleted, repository.toolUseID == nil {
            throw SQLiteLibraryStoreError.invalidInput(
                "a tool-completed repository observation requires its tool-use id")
        }
        if repository.reason == .turnStarted,
           repository.rootPromptEntryID == nil || repository.finalAssistantEntryID != nil {
            throw SQLiteLibraryStoreError.invalidInput(
                "a turn-start observation requires only its root prompt entry")
        }
        if repository.reason == .turnCompleted,
           repository.rootPromptEntryID == nil || repository.finalAssistantEntryID == nil {
            throw SQLiteLibraryStoreError.invalidInput(
                "a turn-completed observation requires prompt and final assistant entries")
        }
        if repository.attribution != nil, repository.toolUseID == nil {
            throw SQLiteLibraryStoreError.invalidInput(
                "an attributed repository observation requires its tool-use id")
        }

        var fileIDs = Set<UUID>()
        for file in files {
            guard fileIDs.insert(file.id).inserted else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "duplicate file observation identity")
            }
            guard file.repositoryObservationID == repository.id,
                  file.conversationID == repository.conversationID,
                  file.turnID == repository.turnID,
                  file.repositoryID == repository.repositoryID else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "file observation does not match its repository/Conversation/turn edge")
            }
            guard let repositoryToolUseID = repository.toolUseID,
                  file.toolUseID == repositoryToolUseID else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "file observation does not match its repository tool edge")
            }
            try validateBoundedWorkEvidenceText(
                file.toolUseID, maximumBytes: 512, label: "file tool-use id")
            try validateRepositoryRelativeWorkEvidencePath(file.repositoryRelativePath)
            switch (file.attribution, file.operation) {
            case (.directTool, .read), (.directTool, .edit), (.directTool, .write),
                 (.directTool, .multiEdit), (.directTool, .notebookEdit),
                 (.observedDuringTool, .opaqueChange):
                break
            default:
                throw SQLiteLibraryStoreError.invalidInput(
                    "file operation does not match its attribution proof")
            }
            try validateWorkEvidenceDigest(
                file.beforeDigest, exists: file.beforeExists, label: "before")
            try validateWorkEvidenceDigest(
                file.afterDigest, exists: file.afterExists, label: "after")
            if let patch = file.boundedPatch {
                guard !patch.contains("\0"),
                      patch.utf8.count <= ConversationFileObservation.maximumBoundedPatchBytes else {
                    throw SQLiteLibraryStoreError.invalidInput(
                        "file observation patch exceeds its bounded text contract")
                }
            } else if file.patchWasTruncated {
                throw SQLiteLibraryStoreError.invalidInput(
                    "a missing file observation patch cannot be marked truncated")
            }
            guard file.observedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw SQLiteLibraryStoreError.invalidInput(
                    "file observation timestamp is not finite")
            }
        }
    }

    private func validateBoundedWorkEvidenceText(
        _ value: String,
        maximumBytes: Int,
        label: String
    ) throws {
        guard !value.isEmpty, !value.contains("\0"), value.utf8.count <= maximumBytes else {
            throw SQLiteLibraryStoreError.invalidInput(
                "conversation work evidence \(label) is empty or too large")
        }
    }

    private func validateCanonicalWorkEvidencePath(_ value: String, label: String) throws {
        try validateBoundedWorkEvidenceText(value, maximumBytes: 4_096, label: label)
        guard value.hasPrefix("/"), URL(fileURLWithPath: value).standardizedFileURL.path == value else {
            throw SQLiteLibraryStoreError.invalidInput(
                "conversation work evidence \(label) is not a canonical absolute path")
        }
    }

    private func validateRepositoryRelativeWorkEvidencePath(_ value: String) throws {
        try validateBoundedWorkEvidenceText(
            value, maximumBytes: 4_096, label: "repository-relative path")
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SQLiteLibraryStoreError.invalidInput(
                "file observation path is not repository-relative and normalized")
        }
    }

    private func validateWorkEvidenceDigest(
        _ digest: String?,
        exists: Bool?,
        label: String
    ) throws {
        guard let digest else { return }
        guard exists == true, Self.isLowercaseHex(digest, lengths: [64]) else {
            throw SQLiteLibraryStoreError.invalidInput(
                "file observation \(label) digest is not a proven SHA-256")
        }
    }

    private func validateConversationWorkEvidenceExcerpt(
        _ excerpt: String?,
        wasTruncated: Bool?,
        entryID: UUID?,
        label: String
    ) throws {
        guard (excerpt == nil) == (wasTruncated == nil) else {
            throw SQLiteLibraryStoreError.invalidInput(
                "conversation work evidence \(label) excerpt lacks its truncation fact")
        }
        guard let excerpt else { return }
        guard entryID != nil,
              !excerpt.contains("\0"),
              excerpt.utf8.count <= ConversationRepositoryObservation.maximumTranscriptExcerptBytes
        else {
            throw SQLiteLibraryStoreError.invalidInput(
                "conversation work evidence \(label) excerpt is unkeyed or too large")
        }
    }

    private static func isLowercaseHex(_ value: String, lengths: Set<Int>) -> Bool {
        lengths.contains(value.utf8.count)
            && value.unicodeScalars.allSatisfy {
                ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
            }
    }

    private func validateLocalState(version: Int, payload: Data, owner: String) throws {
        guard version > 0 else {
            throw SQLiteLibraryStoreError.invalidInput("\(owner) local-state version is not positive")
        }
        guard payload.count <= Self.maximumLocalStatePayloadBytes else {
            throw SQLiteLibraryStoreError.invalidInput(
                "\(owner) local-state payload exceeds \(Self.maximumLocalStatePayloadBytes) bytes")
        }
    }

    private func validate(source: ShadowLibrarySourceFingerprint) throws {
        guard !source.identity.isEmpty else {
            throw SQLiteLibraryStoreError.invalidInput("source identity is empty")
        }
        guard !source.revision.isEmpty else {
            throw SQLiteLibraryStoreError.invalidInput("source revision is empty")
        }
        guard !source.digest.isEmpty else {
            throw SQLiteLibraryStoreError.invalidInput("source digest is empty")
        }
        guard source.byteCount >= 0 else {
            throw SQLiteLibraryStoreError.invalidInput("source byte count is negative")
        }
    }

    private func workspaceExists(_ id: UUID) throws -> Bool {
        var exists = false
        try query("SELECT 1 FROM workspaces WHERE id = ?1", [.text(id.uuidString)]) { _ in
            exists = true
        }
        return exists
    }

    private func conversationExists(_ id: UUID) throws -> Bool {
        var exists = false
        try query("SELECT 1 FROM conversations WHERE id = ?1", [.text(id.uuidString)]) { _ in
            exists = true
        }
        return exists
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeStatus() throws -> ShadowLibraryStatus {
        var instanceID: UUID?
        var authorityState: LibraryAuthorityState?
        var shadowChangeSequence: Int64 = 0
        var integrityCheckedAt: Date?
        var integrityIsCurrent = false
        try query(
            """
            SELECT database_instance_id, authority_state, integrity_checked_at,
                   integrity_result = 'passed'
                     AND integrity_checked_sequence = shadow_change_sequence,
                   shadow_change_sequence
            FROM library_metadata WHERE singleton = 1
            """,
            []) { statement in
                instanceID = Self.optionalText(statement, 0).flatMap(UUID.init(uuidString:))
                authorityState = Self.optionalText(statement, 1)
                    .flatMap(LibraryAuthorityState.init(rawValue:))
                if sqlite3_column_type(statement, 2) != SQLITE_NULL {
                    integrityCheckedAt = Date(
                        timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2))
                }
                integrityIsCurrent = sqlite3_column_int(statement, 3) != 0
                shadowChangeSequence = sqlite3_column_int64(statement, 4)
            }
        guard let instanceID, let authorityState else {
            throw SQLiteLibraryStoreError.sqlite("library metadata is missing")
        }

        let represented: [ShadowLibraryDomain] = [
            .conversations, .workspaces, .artifactMedia, .operativeState,
            .ambientState, .operations,
        ]
        var domains: [ShadowLibraryDomainStatus] = []
        for domain in ShadowLibraryDomain.allCases {
            guard represented.contains(domain) else {
                domains.append(ShadowLibraryDomainStatus(
                    domain: domain,
                    phase: .notIncluded,
                    imported: 0,
                    total: 0,
                    current: 0,
                    dirty: 0,
                    mismatched: 0,
                    quarantined: 0,
                    errors: 0,
                    hasFullCensus: false))
                continue
            }
            var total = 0
            var imported = 0
            var current = 0
            var dirty = 0
            var mismatched = 0
            var quarantined = 0
            var errors = 0
            var hasFullCensus = false
            try query(
                """
                SELECT
                  COUNT(*),
                  COALESCE(SUM(CASE WHEN imported_digest IS NOT NULL THEN 1 ELSE 0 END), 0),
                  COALESCE(SUM(CASE WHEN dirty = 0 AND import_state = 'current' THEN 1 ELSE 0 END), 0),
                  COALESCE(SUM(dirty), 0),
                  COALESCE(SUM(CASE WHEN import_state = 'mismatch' THEN 1 ELSE 0 END), 0),
                  COALESCE(SUM(CASE WHEN import_state = 'quarantine' THEN 1 ELSE 0 END), 0),
                  COALESCE(SUM(CASE WHEN import_state = 'error' THEN 1 ELSE 0 END), 0)
                FROM migration_sources WHERE domain = ?1
                """,
                [.text(domain.rawValue)]) { statement in
                    total = Int(sqlite3_column_int64(statement, 0))
                    imported = Int(sqlite3_column_int64(statement, 1))
                    current = Int(sqlite3_column_int64(statement, 2))
                    dirty = Int(sqlite3_column_int64(statement, 3))
                    mismatched = Int(sqlite3_column_int64(statement, 4))
                    quarantined = Int(sqlite3_column_int64(statement, 5))
                    errors = Int(sqlite3_column_int64(statement, 6))
                }
            try query(
                """
                SELECT 1 FROM domain_reconciliation
                WHERE domain = ?1 AND expected_source_count = ?2
                """,
                [.text(domain.rawValue), .int(Int64(total))]) { _ in hasFullCensus = true }
            domains.append(ShadowLibraryDomainStatus(
                domain: domain,
                phase: .shadowing,
                imported: imported,
                total: total,
                current: current,
                dirty: dirty,
                mismatched: mismatched,
                quarantined: quarantined,
                errors: errors,
                hasFullCensus: hasFullCensus))
        }
        let allDomainsComplete = domains.allSatisfy(\.isComplete)
        let artifactMedia = try makeArtifactMediaStatus(
            hasFullCensus: domains.first { $0.domain == .artifactMedia }?.hasFullCensus == true)
        var recoveredConversationCount = 0
        try query(
            """
            SELECT COUNT(*)
            FROM migration_sources source
            JOIN conversations conversation
              ON conversation.id = source.entity_id
             AND conversation.source_identity = source.source_identity
            WHERE source.domain = 'conversations'
              AND source.dirty = 0 AND source.import_state = 'current'
              AND source.source_identity LIKE '%.json.corrupt-%'
            """,
            []) { recoveredConversationCount = Int(sqlite3_column_int64($0, 0)) }
        return ShadowLibraryStatus(
            currentAuthority: "Current JSON/media files and app-private stores",
            candidateState: allDomainsComplete ? .healthyShadow : .incompleteShadow,
            databaseURL: databaseURL,
            databaseBytes: databaseSize(),
            databaseInstanceID: instanceID,
            schemaVersion: Self.schemaVersion,
            shadowChangeSequence: shadowChangeSequence,
            authorityState: authorityState,
            wasResetOnOpen: resetReason != nil,
            resetReason: resetReason,
            integrity: ShadowLibraryIntegrityStatus(
                state: integrityIsCurrent ? .passed : .pending,
                verifiedAt: integrityCheckedAt),
            domains: domains,
            artifactMedia: artifactMedia,
            recoveredConversationCount: recoveredConversationCount)
    }

    private func makeArtifactMediaStatus(
        hasFullCensus: Bool
    ) throws -> ShadowLibraryArtifactMediaStatus {
        var artifactCount = 0
        try query("SELECT COUNT(*) FROM artifacts", []) {
            artifactCount = Int(sqlite3_column_int64($0, 0))
        }
        var retainedSourceCount = 0
        try query("SELECT COUNT(*) FROM retained_byte_sources", []) {
            retainedSourceCount = Int(sqlite3_column_int64($0, 0))
        }
        var payloadSourceCount = 0
        var retainedBytes: Int64 = 0
        try query(
            """
            WITH payloads(digest, bytes) AS (
              SELECT content_digest, content_byte_count FROM artifacts
              UNION ALL
              SELECT digest, byte_count FROM retained_byte_sources
            )
            SELECT COUNT(*), COALESCE(SUM(bytes), 0) FROM payloads
            """,
            []) {
                payloadSourceCount = Int(sqlite3_column_int64($0, 0))
                retainedBytes = sqlite3_column_int64($0, 1)
            }
        var uniqueCount = 0
        var uniqueBytes: Int64 = 0
        try query(
            """
            WITH payloads(digest, bytes) AS (
              SELECT content_digest, content_byte_count FROM artifacts
              UNION ALL
              SELECT digest, byte_count FROM retained_byte_sources
            )
            SELECT COUNT(*), COALESCE(SUM(bytes), 0)
            FROM (SELECT digest, MAX(bytes) AS bytes FROM payloads GROUP BY digest)
            """,
            []) {
                uniqueCount = Int(sqlite3_column_int64($0, 0))
                uniqueBytes = sqlite3_column_int64($0, 1)
            }
        var nestedCount = 0
        var nestedOnlyCount = 0
        var divergentCount = 0
        try query(
            """
            SELECT
              COUNT(*),
              COUNT(DISTINCT CASE WHEN a.id IS NULL THEN n.artifact_id END),
              COUNT(DISTINCT CASE
                WHEN a.id IS NOT NULL
                 AND a.canonical_payload_digest != n.canonical_payload_digest
                THEN n.artifact_id END)
            FROM conversation_artifact_snapshots n
            LEFT JOIN artifacts a ON a.id = n.artifact_id
            """,
            []) {
                nestedCount = Int(sqlite3_column_int64($0, 0))
                nestedOnlyCount = Int(sqlite3_column_int64($0, 1))
                divergentCount = Int(sqlite3_column_int64($0, 2))
            }
        var sourceIssueCount = 0
        try query(
            """
            SELECT COUNT(*) FROM migration_sources
            WHERE domain = 'artifact_media'
              AND NOT (dirty = 0 AND import_state = 'current')
            """,
            []) { sourceIssueCount = Int(sqlite3_column_int64($0, 0)) }
        var adoptedRetainedByteSourceCount = 0
        try query(
            """
            SELECT COUNT(*) FROM retained_byte_sources
            WHERE storage_class = 'legacy_layout' AND storage_state = 'adopted'
              AND link_state = 'current' AND disposition = 'referenced'
            """,
            []) { adoptedRetainedByteSourceCount = Int(sqlite3_column_int64($0, 0)) }
        var retainedByteReferenceCount = 0
        try query("SELECT COUNT(*) FROM retained_byte_references", []) {
            retainedByteReferenceCount = Int(sqlite3_column_int64($0, 0))
        }
        var unreferencedRetainedByteSourceCount = 0
        var unclaimedRecoveryBytes: Int64 = 0
        try query(
            """
            SELECT COUNT(*), COALESCE(SUM(r.byte_count), 0)
            FROM retained_byte_sources r
            WHERE r.disposition = 'unclaimed_recovery'
            """,
            []) {
                unreferencedRetainedByteSourceCount = Int(sqlite3_column_int64($0, 0))
                unclaimedRecoveryBytes = sqlite3_column_int64($0, 1)
            }
        var pendingRetainedByteDispositionCount = 0
        try query(
            """
            SELECT COUNT(*) FROM retained_byte_sources
            WHERE kind = 'conversation_media' AND link_state = 'current'
              AND disposition = 'reference_pending'
            """,
            []) { pendingRetainedByteDispositionCount = Int(sqlite3_column_int64($0, 0)) }
        return ShadowLibraryArtifactMediaStatus(
            artifactCount: artifactCount,
            retainedByteSourceCount: retainedSourceCount,
            retainedBytes: retainedBytes,
            uniquePayloadCount: uniqueCount,
            uniqueBytes: uniqueBytes,
            duplicateSourceCount: max(0, payloadSourceCount - uniqueCount),
            duplicateBytes: max(0, retainedBytes - uniqueBytes),
            nestedSnapshotCount: nestedCount,
            nestedOnlyCount: nestedOnlyCount,
            divergentCount: divergentCount,
            adoptedRetainedByteSourceCount: adoptedRetainedByteSourceCount,
            retainedByteReferenceCount: retainedByteReferenceCount,
            unreferencedRetainedByteSourceCount: unreferencedRetainedByteSourceCount,
            unclaimedRecoveryBytes: unclaimedRecoveryBytes,
            pendingRetainedByteDispositionCount: pendingRetainedByteDispositionCount,
            sourceIssueCount: sourceIssueCount,
            hasFullCensus: hasFullCensus)
    }

    private func databaseSize() -> Int64 {
        [databaseURL, sidecarURL("-wal"), sidecarURL("-shm")].reduce(0) { result, url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return result + bytes
        }
    }

    // MARK: - SQLite plumbing

    private enum SQLiteValue {
        case null
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
        case bool(Bool)
    }

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func execute(_ sql: String, _ values: [SQLiteValue] = []) throws {
        try statement(sql, values) { _ in }
    }

    private func query(
        _ sql: String,
        _ values: [SQLiteValue],
        row: (OpaquePointer) throws -> Void
    ) throws {
        try statement(sql, values, row: row)
    }

    private func statement(
        _ sql: String,
        _ values: [SQLiteValue],
        row: (OpaquePointer) throws -> Void
    ) throws {
        guard let db else { throw SQLiteLibraryStoreError.sqlite("database is closed") }
        var prepared: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &prepared, nil)
        guard prepareResult == SQLITE_OK, let prepared else {
            throw sqliteError(operation: "prepare")
        }
        defer { sqlite3_finalize(prepared) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(prepared, index)
            case .int(let value):
                result = sqlite3_bind_int64(prepared, index, value)
            case .double(let value):
                result = sqlite3_bind_double(prepared, index, value)
            case .text(let value):
                result = sqlite3_bind_text(prepared, index, value, -1, transient)
            case .blob(let value):
                if value.isEmpty {
                    result = sqlite3_bind_zeroblob(prepared, index, 0)
                } else {
                    result = value.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(
                            prepared, index, bytes.baseAddress, Int32(bytes.count), transient)
                    }
                }
            case .bool(let value):
                result = sqlite3_bind_int(prepared, index, value ? 1 : 0)
            }
            guard result == SQLITE_OK else { throw sqliteError(operation: "bind") }
        }
        while true {
            switch sqlite3_step(prepared) {
            case SQLITE_ROW:
                try row(prepared)
            case SQLITE_DONE:
                return
            default:
                throw sqliteError(operation: "step")
            }
        }
    }

    private func transaction(
        tracksMutation: Bool = true,
        requiresShadow: Bool = true,
        _ body: () throws -> Void
    ) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            if requiresShadow { try requireAuthorityState(.shadow) }
            try body()
            if tracksMutation {
                try execute(
                    """
                    UPDATE library_metadata
                    SET shadow_change_sequence = shadow_change_sequence + 1,
                        integrity_result = NULL
                    WHERE singleton = 1
                    """)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func requireActiveAuthority(_ activationID: UUID) throws {
        guard activeActivationID == activationID else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "repository activation does not match this process")
        }
        let metadata = try readAuthorityMetadata()
        guard metadata.authorityState == .active,
              metadata.activationID == activationID else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "library.db is no longer the matching active authority")
        }
    }

    /// One authoritative commit owns the entity mutation, its projection-outbox trigger and both
    /// sequence clocks. Keeping `shadow_change_sequence` equal to `committed_sequence` lets the
    /// already-shipped projection protocol cross activation without a second clock or schema.
    private func authoritativeTransaction(
        activationID: UUID,
        _ body: () throws -> Void
    ) throws -> Int64 {
        try requireActiveAuthority(activationID)
        let metadata = try readAuthorityMetadata()
        let currentShadow = try currentShadowChangeSequence()
        guard currentShadow == metadata.committedSequence else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "authoritative and projection sequence clocks diverged")
        }
        let next = metadata.committedSequence + 1
        try transaction(tracksMutation: false, requiresShadow: false) {
            try requireAuthorityState(.active)
            let inside = try readAuthorityMetadata()
            guard inside.activationID == activationID,
                  inside.committedSequence == metadata.committedSequence,
                  try currentShadowChangeSequence() == inside.committedSequence else {
                throw SQLiteLibraryStoreError.protectedDatabase(
                    "authority generation changed before commit")
            }
            try body()
            try execute(
                """
                UPDATE library_metadata
                SET committed_sequence = ?1,
                    shadow_change_sequence = ?1,
                    integrity_checked_sequence = NULL,
                    integrity_checked_at = NULL,
                    integrity_result = NULL
                WHERE singleton = 1 AND authority_state = 'active' AND activation_id = ?2
                  AND committed_sequence = ?3 AND shadow_change_sequence = ?3
                """,
                [.int(next), .text(activationID.uuidString), .int(metadata.committedSequence)])
            guard sqlite3_changes(db) == 1 else {
                throw SQLiteLibraryStoreError.protectedDatabase(
                    "authority sequence compare-and-swap failed")
            }
        }
        return next
    }

    private func currentShadowChangeSequence() throws -> Int64 {
        try scalarInt(
            "SELECT shadow_change_sequence FROM library_metadata WHERE singleton = 1")
    }

    private func requiredEntityID(
        domain: ShadowLibraryDomain,
        sourceIdentity: String
    ) throws -> String {
        var entityID: String?
        try query(
            """
            SELECT entity_id FROM migration_sources
            WHERE domain = ?1 AND source_identity = ?2
            """,
            [.text(domain.rawValue), .text(sourceIdentity)]) {
                entityID = Self.optionalText($0, 0)
            }
        guard let entityID else {
            throw SQLiteLibraryStoreError.invalidInput(
                "the current source receipt has no entity id")
        }
        return entityID
    }

    private func projectionBacklogCount(
        databaseInstanceID: UUID,
        kind: ShadowLibraryProjectionWorkItem.Kind
    ) throws -> Int {
        Int(try scalarInt(
            """
            SELECT COUNT(*) FROM projection_outbox
            WHERE database_instance_id = ?1 AND projection_kind = ?2
            """,
            [.text(databaseInstanceID.uuidString), .text(kind.rawValue)]))
    }

    private func ensureProjectionState(
        databaseInstanceID: UUID,
        kind: ShadowLibraryProjectionWorkItem.Kind,
        schemaVersion: Int
    ) throws {
        let now = Date().timeIntervalSinceReferenceDate
        try execute(
            """
            INSERT INTO projection_state (
              database_instance_id, projection_kind, projection_schema_version,
              applied_high_water_sequence, health, last_error, updated_at)
            VALUES (?1, ?2, ?3, 0, 'queued', NULL, ?4)
            ON CONFLICT(database_instance_id, projection_kind) DO UPDATE SET
              projection_schema_version = excluded.projection_schema_version,
              applied_high_water_sequence = CASE
                WHEN projection_state.projection_schema_version = excluded.projection_schema_version
                  THEN projection_state.applied_high_water_sequence
                ELSE 0
              END,
              health = CASE
                WHEN projection_state.projection_schema_version = excluded.projection_schema_version
                  THEN projection_state.health
                ELSE 'queued'
              END,
              last_error = CASE
                WHEN projection_state.projection_schema_version = excluded.projection_schema_version
                  THEN projection_state.last_error
                ELSE NULL
              END,
              updated_at = excluded.updated_at
            """,
            [
                .text(databaseInstanceID.uuidString), .text(kind.rawValue),
                .int(Int64(schemaVersion)), .double(now),
            ])
    }

    private func updateProjectionState(
        databaseInstanceID: UUID,
        kind: ShadowLibraryProjectionWorkItem.Kind,
        schemaVersion: Int,
        health: String,
        lastError: String?
    ) throws {
        try ensureProjectionState(
            databaseInstanceID: databaseInstanceID,
            kind: kind,
            schemaVersion: schemaVersion)
        try execute(
            """
            UPDATE projection_state
            SET health = ?1, last_error = ?2, updated_at = ?3
            WHERE database_instance_id = ?4 AND projection_kind = ?5
            """,
            [
                .text(health), lastError.map(SQLiteValue.text) ?? .null,
                .double(Date().timeIntervalSinceReferenceDate),
                .text(databaseInstanceID.uuidString), .text(kind.rawValue),
            ])
    }

    /// Coalescing discards an entity's earlier pending sequence, so the minimum remaining desired
    /// sequence cannot establish a global prefix. Preserve the prior high-water while work remains;
    /// advance only through an independently validated exact snapshot or a fully drained frontier.
    private func updateProjectionStateFromBacklog(
        databaseInstanceID: UUID,
        kind: ShadowLibraryProjectionWorkItem.Kind,
        schemaVersion: Int,
        failure: String?,
        validatedThrough: Int64?,
        publishesClosedFrontier: Bool
    ) throws {
        try ensureProjectionState(
            databaseInstanceID: databaseInstanceID,
            kind: kind,
            schemaVersion: schemaVersion)
        let hasPending = try projectionBacklogCount(
            databaseInstanceID: databaseInstanceID, kind: kind) > 0
        let mayPublishCurrent = publishesClosedFrontier && !hasPending
        let highWater = mayPublishCurrent
            ? try currentShadowChangeSequence()
            : max(0, validatedThrough ?? 0)
        let health: String
        if failure != nil {
            health = "failed"
        } else if mayPublishCurrent {
            health = "current"
        } else {
            health = hasPending ? "queued" : "projecting"
        }
        try execute(
            """
            UPDATE projection_state
            SET applied_high_water_sequence = MAX(applied_high_water_sequence, ?1),
                health = ?2, last_error = ?3, updated_at = ?4
            WHERE database_instance_id = ?5 AND projection_kind = ?6
            """,
            [
                .int(highWater), .text(health), failure.map(SQLiteValue.text) ?? .null,
                .double(Date().timeIntervalSinceReferenceDate),
                .text(databaseInstanceID.uuidString), .text(kind.rawValue),
            ])
    }

    /// Receipt-only rebinding (same digest, new inode/generation token) does not touch the
    /// Conversation row and therefore does not fire the SQL update trigger. Queue the new source
    /// revision explicitly in the same transaction as that receipt update.
    private func enqueueConversationProjection(entityID: UUID) throws {
        try execute(
            """
            INSERT INTO projection_outbox (
              database_instance_id, projection_kind, entity_id, desired_sequence)
            SELECT database_instance_id, ?1, ?2, shadow_change_sequence + 1
            FROM library_metadata WHERE singleton = 1
            ON CONFLICT(database_instance_id, projection_kind, entity_id) DO UPDATE SET
              desired_sequence = MAX(projection_outbox.desired_sequence, excluded.desired_sequence),
              last_error = NULL
            """,
            [
                .text(ShadowLibraryProjectionWorkItem.Kind.conversationSearch.rawValue),
                .text(entityID.uuidString),
            ])
        try execute(
            """
            UPDATE projection_state
            SET health = 'queued', last_error = NULL, updated_at = ?1
            WHERE database_instance_id = (
              SELECT database_instance_id FROM library_metadata WHERE singleton = 1)
              AND projection_kind = ?2
            """,
            [
                .double(Date().timeIntervalSinceReferenceDate),
                .text(ShadowLibraryProjectionWorkItem.Kind.conversationSearch.rawValue),
            ])
    }

    /// Pin a WAL snapshot across a multi-query rehearsal read without acquiring a write lock or
    /// advancing the shadow mutation sequence. The first SELECT in `body` establishes the snapshot;
    /// concurrent writers on another connection remain free to commit and become visible only to a
    /// later bundle.
    private func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN DEFERRED")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func requireAuthorityState(_ expected: LibraryAuthorityState) throws {
        let state = try scalarText(
            "SELECT authority_state FROM library_metadata WHERE singleton = 1")
        guard state == expected.rawValue else {
            throw SQLiteLibraryStoreError.protectedDatabase(
                "authority state is \(state), expected \(expected.rawValue)")
        }
    }

    private func verifyIntegrityAndRecord() throws -> ShadowLibraryIntegrityStatus {
        let quickCheck = try scalarText("PRAGMA quick_check")
        guard quickCheck == "ok" else {
            throw SQLiteLibraryStoreError.sqlite("quick_check failed: \(quickCheck)")
        }
        var foreignKeyViolationCount = 0
        try query("PRAGMA foreign_key_check", []) { _ in foreignKeyViolationCount += 1 }
        guard foreignKeyViolationCount == 0 else {
            throw SQLiteLibraryStoreError.sqlite(
                "foreign_key_check reported \(foreignKeyViolationCount) violation(s)")
        }
        let verifiedAt = Date()
        try execute(
            """
            UPDATE library_metadata
            SET integrity_checked_sequence = shadow_change_sequence,
                integrity_checked_at = ?1,
                integrity_result = 'passed'
            WHERE singleton = 1
            """,
            [.double(verifiedAt.timeIntervalSinceReferenceDate)])
        return ShadowLibraryIntegrityStatus(state: .passed, verifiedAt: verifiedAt)
    }

    private func scalarInt(
        _ sql: String,
        _ values: [SQLiteValue] = []
    ) throws -> Int64 {
        var value: Int64?
        try query(sql, values) {
            guard value == nil else {
                throw SQLiteLibraryStoreError.sqlite("multiple scalar results for \(sql)")
            }
            value = sqlite3_column_int64($0, 0)
        }
        guard let value else { throw SQLiteLibraryStoreError.sqlite("no scalar result for \(sql)") }
        return value
    }

    private func scalarText(_ sql: String) throws -> String {
        var value: String?
        try query(sql, []) { value = Self.optionalText($0, 0) }
        guard let value else { throw SQLiteLibraryStoreError.sqlite("no scalar result for \(sql)") }
        return value
    }

    private static func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private static func optionalUUID(
        _ statement: OpaquePointer,
        _ column: Int32,
        label: String
    ) throws -> UUID? {
        guard let raw = optionalText(statement, column) else { return nil }
        guard let value = UUID(uuidString: raw) else {
            throw SQLiteLibraryStoreError.sqlite("malformed \(label)")
        }
        return value
    }

    private static func optionalInt(_ statement: OpaquePointer, _ column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil
            : sqlite3_column_int64(statement, column)
    }

    private static func optionalDate(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, column))
    }

    /// Every blob column in this store is read here, which is why transparent decompression lives
    /// at this one seam rather than at each of the 42 call sites. A payload without the codec's
    /// header passes through untouched, so rows written before compression existed are unaffected.
    private static func data(_ statement: OpaquePointer, _ column: Int32) -> Data {
        ConversationEventPayloadCodec.decode(rawData(statement, column))
    }

    private static func rawData(_ statement: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func sqliteError(operation: String) -> SQLiteLibraryStoreError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
        return .sqlite("\(operation): \(message)")
    }

    private func closeDatabase() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    private func deleteDatabaseFiles() throws {
        for url in [databaseURL, sidecarURL("-wal"), sidecarURL("-shm"), resetMarkerURL] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { try FileManager.default.removeItem(at: url) }
            catch {
                throw SQLiteLibraryStoreError.sqlite(
                    "could not reset \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private func sidecarURL(_ suffix: String) -> URL {
        URL(fileURLWithPath: databaseURL.path + suffix, isDirectory: false)
    }

    private var resetMarkerURL: URL {
        URL(fileURLWithPath: databaseURL.path + ".shadow-resettable", isDirectory: false)
    }

    /// This marker is intentionally separate from SQLite. It is created only while legacy JSON is
    /// authoritative and must be removed by the future recognition/activation protocol *before*
    /// `library.db` can become authoritative. An old L1 build may reset a corrupt candidate only
    /// when this proof exists; an active or unknown database always fails closed and is preserved.
    private func ensureResetMarker() throws {
        var rawInstanceID: String?
        try query(
            "SELECT database_instance_id FROM library_metadata WHERE singleton = 1",
            []) { rawInstanceID = Self.optionalText($0, 0) }
        guard let rawInstanceID, let instanceID = UUID(uuidString: rawInstanceID) else {
            throw SQLiteLibraryStoreError.sqlite("library database instance id is invalid")
        }
        if let data = try? Data(contentsOf: resetMarkerURL),
           let marker = try? JSONDecoder().decode(ResetMarker.self, from: data),
           marker.formatVersion == 1,
           marker.databaseInstanceID == instanceID {
            return
        }
        try writeResetMarker(databaseInstanceID: instanceID)
    }

    private func writeResetMarker(databaseInstanceID: UUID) throws {
        do {
            let data = try JSONEncoder().encode(ResetMarker(
                formatVersion: 1,
                databaseInstanceID: databaseInstanceID))
            try data.write(to: resetMarkerURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: resetMarkerURL.path)
        } catch {
            throw SQLiteLibraryStoreError.permissions(
                "\(resetMarkerURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func resetMarkerMatches(databaseInstanceID: UUID) -> Bool {
        guard let data = try? Data(contentsOf: resetMarkerURL),
              let marker = try? JSONDecoder().decode(ResetMarker.self, from: data)
        else { return false }
        return marker.formatVersion == 1 && marker.databaseInstanceID == databaseInstanceID
    }

    private static func resetDescription(for error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    /// The fourth copy of the owner-only rule, and the one that never checked its own work: it
    /// chmodded and returned, so a directory that stayed group-readable — or a symlink standing in
    /// for one — passed silently. It now shares the rule with every other caller, which verifies
    /// after repairing.
    private static func prepareOwnerOnlyDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw SQLiteLibraryStoreError.permissions(error.localizedDescription)
        }
        if let reason = OwnerOnlyDirectory.makePrivateReason(url, label: "support root") {
            throw SQLiteLibraryStoreError.permissions(reason)
        }
    }

    private func applyOwnerOnlyFilePermissions() throws {
        for url in [databaseURL, sidecarURL("-wal"), sidecarURL("-shm"), resetMarkerURL]
        where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o600))],
                    ofItemAtPath: url.path)
            } catch {
                throw SQLiteLibraryStoreError.permissions(
                    "\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}
