import Foundation
import Combine
import CryptoKit
import Darwin
import UniformTypeIdentifiers

enum ConversationSidecarGenerationError: Error, Equatable {
    case invalidURL
    case inspectionFailed(Int32)
    case unsupportedFileType(mode_t)
    case invalidMetadata
    case byteCountMismatch(expected: Int, observed: Int64)
}

/// O(1) identity for a regular-file generation used by isolated sidecar compatibility stores.
/// Production launches read the active SQLite authority and never consult these tokens.
enum ConversationSidecarGeneration {
    private static let formatPrefix = "lstat-v1;"

    static func token(for url: URL, expectedByteCount: Int? = nil) throws -> String {
        guard url.isFileURL else { throw ConversationSidecarGenerationError.invalidURL }
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return lstat(path, &metadata)
        }
        guard result == 0 else {
            throw ConversationSidecarGenerationError.inspectionFailed(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw ConversationSidecarGenerationError.unsupportedFileType(metadata.st_mode)
        }
        guard metadata.st_size >= 0,
              (0..<1_000_000_000).contains(metadata.st_mtimespec.tv_nsec),
              (0..<1_000_000_000).contains(metadata.st_ctimespec.tv_nsec) else {
            throw ConversationSidecarGenerationError.invalidMetadata
        }
        if let expectedByteCount, metadata.st_size != Int64(expectedByteCount) {
            throw ConversationSidecarGenerationError.byteCountMismatch(
                expected: expectedByteCount,
                observed: metadata.st_size)
        }
        return formatPrefix
            + "dev=\(metadata.st_dev);"
            + "ino=\(metadata.st_ino);"
            + "gen=\(metadata.st_gen);"
            + "size=\(metadata.st_size);"
            + "mtime=\(timestamp(metadata.st_mtimespec));"
            + "ctime=\(timestamp(metadata.st_ctimespec))"
    }

    static func matches(_ expectedToken: String, for url: URL) -> Bool {
        guard expectedToken.hasPrefix(formatPrefix),
              let observed = try? token(for: url) else { return false }
        return observed == expectedToken
    }

    private static func timestamp(_ value: timespec) -> String {
        "\(value.tv_sec).\(String(format: "%09ld", value.tv_nsec))"
    }
}

/// The single source of truth for the conversation LIST and its on-disk persistence, shared by every
/// window and tab in the process.
///
/// Before this, each window's `AgentBridge` kept its OWN `conversations` array (loaded from disk once)
/// and the windows resynced only through fire-and-forget `NotificationCenter` broadcasts. That poor-
/// man's shared store had real bugs: a running new conversation whose broadcast was skipped never
/// appeared in other windows; last-writer-wins full-struct upserts could clobber newer data; a remote
/// remove could yank a conversation another window was viewing. One authoritative store eliminates
/// that whole class of divergence — a create/rename/delete/update in any window is instantly
/// consistent everywhere, no broadcast, no races. The complete lightweight `summaries` inventory
/// is the normal publication plane; full resident records remain directly readable without making
/// every streamed token invalidate every window.
///
/// Per-WINDOW view state stays on `AgentBridge`: which conversation is on screen (`currentID`), its live
/// transcript (`entries`), and the streaming/turn state. This store owns only the durable list.
/// Lock-protected save state shared between the main actor (which stages snapshots) and the
/// serial save queue (which drains them). Staging over an undrained snapshot replaces it, so the
/// drain always writes the newest state and a mutation burst costs one write. `Conversation` is a
/// value type and the lock guards every access, hence `@unchecked Sendable`.
struct ConversationSaveSnapshot {
    var conversation: Conversation
    var revision: UInt64
    /// nil means the repository has no trusted committed runtime baseline and must capture the
    /// complete transcript. A non-nil set includes every added, changed, removed, or reordered
    /// TranscriptEntry relative to the last successful SQLite COMMIT.
    var changedTranscriptEntryIDs: Set<UUID>? = nil
    /// COW value captured on the MainActor in O(1); the serial save queue performs the exact
    /// transcript comparison so a semantic save boundary never scans 8,645 entries on the UI path.
    var authorityBaseline: Conversation? = nil
}

final class ConversationSaveState: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UUID: ConversationSaveSnapshot] = [:]
    private var inFlight: Set<UUID> = []
    private var completedWrites = 0

    /// Returns true when the caller must enqueue a drain block — false means a drain for this
    /// conversation is already queued and will pick up the snapshot staged here.
    func stage(_ snapshot: ConversationSaveSnapshot) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let id = snapshot.conversation.id
        let needsDrain = pending[id] == nil
        pending[id] = snapshot
        return needsDrain
    }

    func take(_ id: UUID) -> ConversationSaveSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let snapshot = pending.removeValue(forKey: id) else { return nil }
        inFlight.insert(id)
        return snapshot
    }

    /// Drop an undrained snapshot (the conversation is being deleted; writing it would race the
    /// file removal queued behind it).
    func cancel(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        pending[id] = nil
    }

    func finish(_ id: UUID, completed: Bool) {
        lock.lock(); defer { lock.unlock() }
        inFlight.remove(id)
        if completed { completedWrites += 1 }
    }

    func hasWork(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pending[id] != nil || inFlight.contains(id)
    }

    var totalCompletedWrites: Int {
        lock.lock(); defer { lock.unlock() }
        return completedWrites
    }
}

private struct ConversationPersistenceWaiter {
    var revision: UInt64
    var completion: (Bool) -> Void
}

/// A suggestion publication mutates the resident value before its authority write completes, just
/// like every other consequential store update. Presentation must remain on the exact value that
/// was already durable until that write succeeds. Keeping the optional inside a concrete fence is
/// important: `nil` is a real expected presentation value, not the absence of a fence.
private struct SuggestedPromptPublicationFence {
    let token: UUID
    let expected: ConversationSuggestedPrompt?
    /// `nil` is an intentional retirement, not the absence of a replacement. The fence keeps the
    /// last durable prompt presented until that retirement crosses the authority COMMIT.
    let replacement: ConversationSuggestedPrompt?
}

/// The immutable record revision that actually crossed the atomic sidecar publication boundary.
/// Export consumes this value instead of reacquiring the resident conversation, which may already
/// have advanced to a newer provisional streaming revision by the time the callback runs.
struct PublishedConversationSnapshot {
    let conversation: Conversation
    let revision: UInt64
    fileprivate let storeID: UUID
    fileprivate let hydrationEpoch: UInt64
}

/// Opaque proof that one exact resident/published revision is quiescent for a synchronous
/// repository append. The token is bound to one ConversationStore and hydration generation, so a
/// snapshot from another store (or from before an eviction/reload) cannot authorize adoption.
struct AuthoritativeConversationAppendCAS {
    fileprivate let storeID: UUID
    fileprivate let conversationID: UUID
    fileprivate let revision: UInt64
    fileprivate let hydrationEpoch: UInt64
    fileprivate let priorMessageCount: Int
    let captureOrdinal: UInt64
}

enum AuthoritativeConversationAppendAdoption: Equatable {
    case appended
    case alreadyPresent
    case refused
}

enum BackgroundConversationAdoptionResult: Equatable {
    /// This call introduced the Conversation and its canonical Legacy sidecar crossed the durable
    /// publication boundary. A later coalesced mutation may be present in the published snapshot;
    /// it still contains the create this call installed.
    case published
    /// The exact normalized Conversation already exists. This is the expected replay after a crash
    /// between canonical publication and moving the immutable inbox envelope to `adopted/`.
    case alreadyPublished
    /// The UUID exists with different content. An external producer may never replace it.
    case identityCollision
    /// The canonical sidecar could not be published; the envelope must remain pending.
    case persistenceFailed
}

private enum BackgroundConversationFilePublication: Equatable {
    case created
    case existingIdentical
    case collision
}

private struct ConversationPublishedSnapshotWaiter {
    var revision: UInt64
    var completion: (PublishedConversationSnapshot?) -> Void
}

enum ConversationResidencyMode: String, Equatable {
    /// Preserve the pre-P1b behavior: every decoded Conversation remains resident for the session.
    case eager
    /// Recover a complete authoritative inventory, then keep only a bounded clean working set.
    /// The inventory comes from exact SQLite authority without decoding frozen sidecars.
    case boundedAfterRecovery
}

enum ConversationSearchIndexState: Equatable {
    case current
    case indexing
    case failed
}

/// Bounded residency is still a dogfood checkpoint. A preference written by a dogfood build must
/// never carry that experimental read path into a later public build installed over it.
enum ConversationResidencyRolloutPolicy {
    static func mode(
        provenance: BuildProvenance?,
        environmentValue: String?,
        preferenceValue: String?
    ) -> ConversationResidencyMode {
        // Bounded residency is the default for every build. Eager residency holds every record
        // resident, which on SQLite authority means decoding the whole corpus before the sidebar
        // can paint; it survives only as an explicit override.
        _ = provenance
        if let environmentValue, let mode = parse(environmentValue) {
            return mode
        }
        if let preferenceValue, let mode = parse(preferenceValue) {
            return mode
        }
        return .boundedAfterRecovery
    }

    private static func parse(_ rawValue: String) -> ConversationResidencyMode? {
        switch rawValue.lowercased() {
        case "eager": .eager
        case "boundedafterrecovery": .boundedAfterRecovery
        default: nil
        }
    }
}

struct SQLiteConversationReadMetrics: Equatable, Sendable {
    var sqliteReads = 0
    var lastSQLiteMilliseconds: Double?
    var slowestSQLiteMilliseconds: Double?
    var lastLegacyMilliseconds: Double?
}

/// Admission is explicit because a person opening a Conversation must never be queued behind
/// maintenance work which happens to need another full record. The interactive lane is still
/// serial so two selections retain their cancellation and publication fences.
enum ConversationHydrationPriority: Equatable, Sendable {
    case background
    case interactive
}

/// Content-free timing for one completed whole-record hydration. Selection diagnostics use this
/// to distinguish scheduler delay from SQLite/reconstruction work without retaining any
/// Conversation data.
struct ConversationHydrationTiming: Equatable, Sendable {
    let priority: ConversationHydrationPriority
    let queueWaitMilliseconds: Double
    let readMilliseconds: Double
}

enum ConversationHydrationError: Error, Equatable {
    case missing
    case unreadable
    case identityMismatch
    case deleted
}

/// `updateLive` serves both recoverable provider state and a few deliberately process-local UI
/// stamps. Make that persistence boundary explicit at the call site so adding bounded transcript
/// checkpoints cannot accidentally turn a polling throttle into recurring authority writes.
enum ConversationLivePersistencePolicy: Equatable {
    case checkpointed
    case runtimeOnly
}

/// Waiter-scoped ownership of one asynchronous Conversation hydration request. Multiple requests
/// for the same record still share one decode; canceling this value removes only its callback.
struct ConversationHydrationRequest: Hashable, Sendable {
    fileprivate let conversationID: UUID
    fileprivate let waiterID: UUID
}

/// One bounded, display-only transcript read. Timings contain no transcript, title, path, or other
/// Conversation content; they exist so a slow visual handoff can distinguish scheduling/queue wait
/// from the SQLite read itself without persisting telemetry.
struct ConversationTranscriptPage: Equatable, Sendable {
    let entries: [TranscriptEntry]
    let queueWaitMilliseconds: Double?
    let readMilliseconds: Double?
}

/// Waiter-scoped ownership of one bounded transcript page. Unlike whole-record hydration these
/// reads are intentionally not coalesced: every active selection owns one request, and withdrawing
/// it lets the interactive reader stop before or during row decoding.
struct ConversationTranscriptPageRequest {
    fileprivate let conversationID: UUID
    fileprivate let cancellation: ConversationTranscriptPageCancellation
    fileprivate let workItem: DispatchWorkItem
}

/// Dispatch cancellation alone is advisory. The repository also samples this lock-protected flag
/// before entering its interactive lane and while decoding rows, while the final MainActor check
/// prevents an already-enqueued completion from repainting a superseded selection.
private final class ConversationTranscriptPageCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}

private struct ConversationHydrationWaiter {
    let id: UUID
    /// A title-only mutation can trust the closed SQLite inventory's existing summary while it
    /// hydrates the full record. Ordinary consumers retain the conservative full derivation.
    let refreshesSummaryAfterHydration: Bool
    let timing: (@MainActor (ConversationHydrationTiming) -> Void)?
    let completion: @MainActor (Result<Conversation, ConversationHydrationError>) -> Void
}

/// DispatchWorkItem cancellation is advisory, so the block also checks this lock-protected flag at
/// both sides of the expensive read. The job identity on the MainActor is the final publication
/// fence; this flag merely lets abandoned queued/running work stop as early as it safely can.
private final class ConversationHydrationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}

private struct ConversationHydrationJob {
    let id: UUID
    let priority: ConversationHydrationPriority
    let cancellation: ConversationHydrationCancellation
    let workItem: DispatchWorkItem
}

/// One immutable authority append retained after its disk retries are exhausted. The identity is
/// stable, so retry is idempotent and can never replace a different observation.
private struct PendingConversationWorkEvidenceWrite: Sendable {
    let repository: ConversationRepositoryObservation
    let files: [ConversationFileObservation]

    var estimatedByteCount: Int {
        var total = 512
        func add(_ value: String?) {
            guard let value else { return }
            let (next, overflow) = total.addingReportingOverflow(value.utf8.count)
            total = overflow ? Int.max : next
        }
        add(repository.turnID)
        add(repository.toolUseID)
        add(repository.rootPromptExcerpt)
        add(repository.finalAssistantExcerpt)
        add(repository.repositoryID)
        add(repository.gitCommonDirectory)
        add(repository.worktreePath)
        add(repository.canonicalCWD)
        add(repository.symbolicRef)
        add(repository.headOID)
        for file in files {
            add(file.turnID)
            add(file.toolUseID)
            add(file.repositoryID)
            add(file.repositoryRelativePath)
            add(file.beforeDigest)
            add(file.afterDigest)
            add(file.boundedPatch)
        }
        return total
    }
}

extension ConversationHydrationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missing:
            return "The conversation file is missing. Restore or locate it, then try again."
        case .unreadable:
            return "The conversation file couldn’t be read."
        case .identityMismatch:
            return "The conversation file’s identity doesn’t match this sidebar item."
        case .deleted:
            return "The conversation is no longer available."
        }
    }
}

@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore(
        loadsAsynchronously: true,
        residencyMode: productionResidencyMode())
#if DEBUG
    /// Focused authority-ordering tests hold the repository edge without replacing the real
    /// repository. The hook runs on the serial save queue immediately before COMMIT.
    nonisolated(unsafe) static var authorityCommitTestHook: (() -> Void)?
    /// Cross-authority failure injection for consequential-write tests. It runs inside the real
    /// retry loop for both Legacy and SQLite rather than bypassing persistence acknowledgements.
    nonisolated(unsafe) static var persistenceWriteTestHook: (() throws -> Void)?
    /// Focused evidence tests fail only this writer, leaving ordinary Conversation persistence free
    /// to prove that an unrelated success cannot clear the retained evidence failure.
    nonisolated(unsafe) static var conversationWorkEvidenceWriteTestHook: (() throws -> Void)?
    nonisolated(unsafe) static var conversationWorkEvidenceReadTestHook: (() throws -> Void)?
#endif

    /// Full records currently resident in the bounded working set. `summaries` is the complete
    /// inventory; absence here means unloaded, never deleted. Provider hot paths and the current
    /// window always retain their records through the eviction guards below.
    private(set) var conversations: [Conversation] = []
    /// The lightweight, complete inventory used by every conversation-list surface. Before launch
    /// inventory validation this may be populated from `projections.db`; once ready it is replaced
    /// by the exact authority inventory and retained after eviction. Keeping summaries as a
    /// distinct type is the safety boundary for lazy hydration: an unloaded record is never
    /// represented by a fake `Conversation` whose empty transcript could later be persisted.
    @Published private(set) var summaries: [ConversationSummary] = []
    /// Process-local publication pulse for append-only Conversation repository evidence. The rows
    /// remain authoritative in library.db; this counter only tells open Changes inspectors to
    /// repeat their exact repository-key query after a successful commit.
    @Published private(set) var conversationWorkEvidenceRevision: UInt64 = 0
    /// Streaming can deliver many deltas per second. Re-deriving even a lightweight summary from
    /// a 10k-row transcript for every token is still needless main-actor work, so live-only
    /// mutations coalesce to one process-wide visible refresh per quarter-second. A durable
    /// `update`/`upsert` removes its conversation from the pending batch and publishes immediately.
    private var pendingLiveSummaryRefreshIDs: Set<UUID> = []
    private var pendingLiveSummaryRefresh: Task<Void, Never>?
    /// A separate, non-ObservableObject pulse for views that explicitly scan full resident
    /// transcripts (currently the sidebar's immediate search fallback). Transcript-bearing live
    /// updates coalesce onto the same quarter-second boundary as summaries without republishing
    /// every bridge/window for session, context, or activity-only events.
    let liveResidentContentDidChange = PassthroughSubject<Set<UUID>, Never>()
    private var pendingLiveContentRefreshIDs: Set<UUID> = []
    /// Provider streams mutate resident Conversations at token cadence, but authority writes must
    /// neither run per token nor wait exclusively for a terminal event that an abnormal process
    /// exit can skip. The first live mutation arms one fixed staging deadline; later mutations join
    /// that checkpoint without moving it. The deadline bounds when a snapshot enters the serial
    /// authority lane, not when its disk commit completes. Once staged, any subsequent live mutation
    /// arms the next interval, including while the prior snapshot is still in flight.
    private let liveCheckpointMaximumLatency: TimeInterval
    private var liveCheckpointDirtyIDs: Set<UUID> = []
    private var liveCheckpointWork: DispatchWorkItem?
    private var liveCheckpointGeneration: UInt64 = 0
    /// Queues discovered in sidecars during this process launch are crash recovery, not permission
    /// to start machine-initiated work. They stay visible but paused until the user opens that
    /// conversation or explicitly resumes it.
    @Published private(set) var pausedQueueConversationIDs: Set<UUID> = []
    /// Non-nil while at least one conversation save has exhausted its disk retries (disk full,
    /// permissions, unreadable volume). The main window shows this with a Retry button. The failed
    /// Conversation snapshot or bounded immutable work-evidence append is kept in memory, so an
    /// unrelated successful write cannot silently clear the warning.
    @Published private(set) var persistenceError: String?
    /// An inventory row whose authoritative sidecar cannot hydrate stays visible and repairable.
    /// This banner state prevents a failed selection from looking like a silent no-op.
    @Published private(set) var hydrationError: String?
    /// Content-free evidence for whole-Conversation hydration after the inventory-ready edge.
    @Published private(set) var sqliteReadMetrics = SQLiteConversationReadMetrics()
    /// A successful value means readiness came from one exact, validated `library.db` inventory.
    @Published private(set) var usedSQLiteLaunchInventory = false
    /// Exact SQLite inventory remains usable while the disposable FTS cache catches up. The sidebar
    /// discloses an incomplete/failed content index instead of returning a false complete miss or
    /// hydrating the entire Legacy corpus to compensate.
    @Published private(set) var searchIndexState: ConversationSearchIndexState = .current
    private var directProjectionWritesInFlight = 0
    private var directProjectionWriteFailed = false
    private var failedHydrationIDs: Set<UUID> = []
    /// Exact snapshots whose write exhausted its retries, by conversation. `retryFailedSaves()`
    /// re-enqueues the NEWEST in-memory state for these ids, not the stale snapshot.
    private var failedSaves: [UUID: ConversationSaveSnapshot] = [:]
    /// Evidence writes are much smaller than Conversations but still contain bounded patches. Keep
    /// retries useful without allowing a failed volume to turn the process into an unbounded queue.
    static let maximumRetainedConversationWorkEvidenceWrites = 256
    static let maximumRetainedConversationWorkEvidenceBytes = 64 * 1_024 * 1_024
    private var failedConversationWorkEvidenceWrites:
        [UUID: PendingConversationWorkEvidenceWrite] = [:]
    private var failedConversationWorkEvidenceOrder: [UUID] = []
    private var failedConversationWorkEvidenceBytes = 0
    /// A cap refusal is never presented as success. The exact value cannot be retried once refused,
    /// so this session keeps its persistence warning visible instead of silently clearing it.
    private var unretainedConversationWorkEvidenceWriteCount = 0
    private var conversationWorkEvidenceWritesInFlight: Set<UUID> = []
#if DEBUG
    var failedConversationWorkEvidenceWriteCountForTesting: Int {
        failedConversationWorkEvidenceWrites.count
    }
#endif
    private var lastPersistenceFailureDetail: String?
    /// Semantic-boundary writers can wait for the exact authoritative file revision without
    /// blocking the main actor. A newer coalesced snapshot satisfies an older waiter because it
    /// contains that mutation; a failed terminal attempt reports false and never releases the
    /// provider-side effect it guarded.
    private var persistenceWaiters: [UUID: [ConversationPersistenceWaiter]] = [:]
    /// Per-conversation presentation fences hide provisional suggestion replacements from every
    /// window while their authority write is outstanding. Resident state may lead the authority
    /// for save coalescing; `presentedSuggestedPrompt(for:)` never does.
    private var suggestedPromptPublicationFences: [UUID: SuggestedPromptPublicationFence] = [:]
    /// Experimental export needs the exact value that reached disk, not merely a Boolean followed
    /// by a fresh resident lookup. A live update can legally advance the resident revision between
    /// those operations, so snapshot waiters are resolved from `finishSave`'s written value.
    private var publishedSnapshotWaiters: [UUID: [ConversationPublishedSnapshotWaiter]] = [:]
    /// Shared with the save queue: coalesces bursts of saves per conversation and counts writes.
    private let saveState = ConversationSaveState()
    /// The disposable search/summary projection (`projections.db`). Fed strictly AFTER each
    /// successful sidecar write — the projection may lag the files, never lead them — and
    /// rebuilt from the loaded store whenever it is missing, stale, or corrupt.
    private(set) var projections: ConversationProjectionStore!

    private var dirWatch: DispatchSourceFileSystemObject?
    private var adoptPending = false
#if DEBUG
    private(set) var directoryWatcherStartCount = 0
    private(set) var directoryWatcherWasActiveAtSQLitePublication = false
#endif
    private let appSupportBaseOverride: URL?
    /// Non-nil only when the process-wide marker selected SQLite authority (or a focused test
    /// injected the matching repository). Every structured read/write branches on this once at
    /// construction; a marked root can never drift back into Legacy because a later query failed.
    private let authorityRepository: LibraryAuthorityRepository?
    /// Process-local provenance for immutable publication snapshots and compound-append tokens.
    private let storeID = UUID()

    /// The newest transcript entries for one Conversation, for painting it before its whole record
    /// has been reconstructed. Reconstructing the largest live record costs about 1.2 s; this page
    /// is ~123 KB and reads in about 1.4 ms.
    ///
    /// Entries only, deliberately. This must never be mistaken for the record: a truncated
    /// Conversation on a save path destroys a transcript, and `AgentBridge.entries` is itself on
    /// that path, so the result of this call belongs in display state that nothing persists.
    /// Yields an empty page when this installation is not on SQLite authority, where there is
    /// nothing cheaper to read than the record itself.
    @discardableResult
    func recentTranscriptPage(
        _ id: UUID,
        limit: Int = 100,
        completion: @escaping @MainActor (ConversationTranscriptPage) -> Void
    ) -> ConversationTranscriptPageRequest? {
        guard let repository = authorityRepository else {
            completion(ConversationTranscriptPage(
                entries: [],
                queueWaitMilliseconds: nil,
                readMilliseconds: nil))
            return nil
        }

        let cancellation = ConversationTranscriptPageCancellation()
        let workItem = DispatchWorkItem {
            guard !cancellation.isCancelled else { return }
#if DEBUG
            Self.transcriptPageWillReadTestHook?(id)
#endif
            guard !cancellation.isCancelled else { return }
            let page: ConversationTranscriptPage
            do {
                let result = try repository.recentTranscriptRead(
                    id: id,
                    limit: limit,
                    isCancelled: { cancellation.isCancelled })
                page = ConversationTranscriptPage(
                    entries: result.entries,
                    queueWaitMilliseconds: result.timing.queueWaitSeconds * 1_000,
                    readMilliseconds: result.timing.readSeconds * 1_000)
            } catch is CancellationError {
                return
            } catch {
                page = ConversationTranscriptPage(
                    entries: [],
                    queueWaitMilliseconds: nil,
                    readMilliseconds: nil)
            }
#if DEBUG
            Self.transcriptPageDidReadTestHook?(id)
#endif
            guard !cancellation.isCancelled else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !cancellation.isCancelled else { return }
                    completion(page)
                }
            }
        }
        let request = ConversationTranscriptPageRequest(
            conversationID: id,
            cancellation: cancellation,
            workItem: workItem)
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
        return request
    }

    /// Withdraw a superseded visual page without affecting any whole-record hydration for the same
    /// Conversation. The content-free request identity is scoped to this store API and never enters
    /// authority or projection state.
    func cancelRecentTranscriptPage(_ request: ConversationTranscriptPageRequest) {
        request.cancellation.cancel()
        request.workItem.cancel()
    }
    private let authorityRepositoryOpenFailure: String?
    private let selectedSQLiteAuthority: Bool

    /// Operation provenance is committed atomically with active SQLite authority updates.
    /// The publisher uses this capability gate before joining member persistence acknowledgements.
    var recordsTransientOperations: Bool { authorityRepository != nil }
    var usesSQLiteAuthority: Bool { selectedSQLiteAuthority }

    func recordTransientOperations(
        _ captures: [LibraryTransientOperationCaptureFactory.Capture]
    ) {
        guard let authorityRepository else { return }
        saveQueue.async { [weak self] in
            do {
                _ = try authorityRepository.commit(captures: captures)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        NSLog(
                            "[persistence] operation receipt could not be committed: %@",
                            error.localizedDescription)
                        self?.persistenceError =
                            "Mechanician couldn’t finish recording a recent change. Your "
                            + "conversations are safe."
                    }
                }
            }
        }
    }

    /// Preserve exact repository/file evidence behind any Conversation snapshot already queued on
    /// the same authority lane. This ordering matters for a newly-created Conversation because the
    /// evidence tables hold a real foreign-key edge to its row.
    func recordConversationWorkEvidence(
        repository: ConversationRepositoryObservation,
        files: [ConversationFileObservation]
    ) {
        enqueueConversationWorkEvidenceWrite(PendingConversationWorkEvidenceWrite(
            repository: repository,
            files: files))
    }

    func conversationWorkEvidence(
        repositoryID: String
    ) throws -> [ConversationWorkEvidence] {
        try authorityRepository?.conversationWorkEvidence(repositoryID: repositoryID) ?? []
    }

    func conversationWorkEvidence(
        conversationID: UUID
    ) throws -> [ConversationWorkEvidence] {
        try authorityRepository?.conversationWorkEvidence(conversationID: conversationID) ?? []
    }

    /// Read behind the same serial authority lane as writes, then publish on the MainActor. This
    /// keeps SQLite work out of SwiftUI rendering and guarantees the result includes every evidence
    /// append queued before this request.
    func loadConversationWorkEvidence(
        repositoryID: String,
        completion: @escaping @MainActor (Result<[ConversationWorkEvidence], Error>) -> Void
    ) {
        guard let authorityRepository else {
            completion(.success([]))
            return
        }
        saveQueue.async {
            let result = Result {
#if DEBUG
                try Self.conversationWorkEvidenceReadTestHook?()
#endif
                return try authorityRepository.conversationWorkEvidence(
                    repositoryID: repositoryID)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    private func enqueueConversationWorkEvidenceWrite(
        _ write: PendingConversationWorkEvidenceWrite
    ) {
        guard !deletedIDs.contains(write.repository.conversationID),
              let authorityRepository,
              conversationWorkEvidenceWritesInFlight.insert(write.repository.id).inserted else {
            return
        }
        saveQueue.async { [weak self] in
            let failure = Self.retryingDiskOperation {
#if DEBUG
                try Self.conversationWorkEvidenceWriteTestHook?()
#endif
                _ = try authorityRepository.recordConversationWorkEvidence(
                    repository: write.repository,
                    files: write.files)
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.finishConversationWorkEvidenceWrite(write, failure: failure)
                }
            }
        }
    }

    private func finishConversationWorkEvidenceWrite(
        _ write: PendingConversationWorkEvidenceWrite,
        failure: Error?
    ) {
        conversationWorkEvidenceWritesInFlight.remove(write.repository.id)
        guard !deletedIDs.contains(write.repository.conversationID) else {
            removeFailedConversationWorkEvidenceWrite(write.repository.id)
            refreshPersistenceError()
            return
        }
        if let failure {
            retainFailedConversationWorkEvidenceWrite(write)
            lastPersistenceFailureDetail = failure.localizedDescription
            NSLog(
                "[persistence] Conversation work evidence could not be committed: %@",
                failure.localizedDescription)
        } else {
            removeFailedConversationWorkEvidenceWrite(write.repository.id)
            conversationWorkEvidenceRevision &+= 1
        }
        refreshPersistenceError()
    }

    private func retainFailedConversationWorkEvidenceWrite(
        _ write: PendingConversationWorkEvidenceWrite
    ) {
        if let existing = failedConversationWorkEvidenceWrites[write.repository.id] {
            if existing.repository != write.repository || existing.files != write.files {
                unretainedConversationWorkEvidenceWriteCount += 1
            }
            return
        }
        let byteCount = write.estimatedByteCount
        let (nextBytes, overflow) = failedConversationWorkEvidenceBytes
            .addingReportingOverflow(byteCount)
        guard !overflow,
              failedConversationWorkEvidenceWrites.count
                < Self.maximumRetainedConversationWorkEvidenceWrites,
              nextBytes <= Self.maximumRetainedConversationWorkEvidenceBytes else {
            unretainedConversationWorkEvidenceWriteCount += 1
            return
        }
        failedConversationWorkEvidenceWrites[write.repository.id] = write
        failedConversationWorkEvidenceOrder.append(write.repository.id)
        failedConversationWorkEvidenceBytes = nextBytes
    }

    private func removeFailedConversationWorkEvidenceWrite(_ id: UUID) {
        guard let removed = failedConversationWorkEvidenceWrites.removeValue(forKey: id) else {
            return
        }
        failedConversationWorkEvidenceBytes = max(
            0,
            failedConversationWorkEvidenceBytes - removed.estimatedByteCount)
        failedConversationWorkEvidenceOrder.removeAll { $0 == id }
    }

    private func discardFailedConversationWorkEvidenceWrites(conversationID: UUID) {
        let ids = failedConversationWorkEvidenceWrites.compactMap { id, write in
            write.repository.conversationID == conversationID ? id : nil
        }
        for id in ids { removeFailedConversationWorkEvidenceWrite(id) }
        refreshPersistenceError()
    }

    /// Where a conversation actually lives when that is NOT `<id.uuidString>.json` — a Finder
    /// duplicate ("… copy.json"), a restored backup, or a file an external integration named its own
    /// way. Deleting by canonical name alone leaves such a file on disk, and the directory watcher
    /// then re-adopts it: the conversation comes back, immediately or on the next launch.
    private var nonCanonicalFiles: [UUID: URL] = [:]
    /// Ids the user deleted this session. `deleteFile` is asynchronous (it runs behind any queued
    /// save), so the watcher can see the still-present file before the delete lands; without a
    /// tombstone `adoptExternalConversations` would read it straight back in. Ambient/external runs
    /// always mint a fresh UUID, so an id is never legitimately re-created.
    private var deletedIDs: Set<UUID> = []

    /// True once the complete inventory and every intrinsic operative record have been published.
    /// The synchronous Legacy path is ready when init returns. The asynchronous production path
    /// flips this after the authority inventory is ready. Isolated compatibility stores still
    /// finish after their sidecar inventory loads. Everything
    /// that assumes a closed store inventory (session restore, wait/queue adoption, the routing
    /// chokepoint, the directory watcher)
    /// gates on it via `whenReady`.
    @Published private(set) var isReady = false
    private var readyCallbacks: [@MainActor () -> Void] = []
    /// Fires for either a complete authoritative inventory or a fail-closed launch. Unlike
    /// `whenReady`, this lets the app construct a visible error surface when readiness is
    /// intentionally never published.
    private var launchInventoryResolutionCallbacks: [@MainActor () -> Void] = []
    private var launchProjectionSettled = false
    private var launchProjectionCallbacks: [@MainActor () -> Void] = []
    /// Projected rows may paint only until the exact authoritative inventory publishes. Maintenance
    /// can finish later; without this separate gate, a late startup query could merge a stale
    /// SQLite orphan back into the just-rebuilt inventory before `isReady` flips.
    private var authoritativeInventoryLoaded = false

    private let requestedResidencyMode: ConversationResidencyMode
    @Published private(set) var activeResidencyMode: ConversationResidencyMode = .eager
    /// A selection is latency-sensitive and has a dedicated serial lane. It shares no admission
    /// queue with inventory warmup, exports, or sidebar batch mutations, but remains serial so a
    /// newer selected record can cancel an obsolete one before it reconstructs.
    private let interactiveHydrationQueue = DispatchQueue(
        label: "ai.mechanician.conversation-interactive-hydration", qos: .userInitiated)
    /// Whole-record work that is not directly opening a Conversation. Keeping it off the
    /// interactive lane prevents an eager fallback or background operation from delaying UI.
    private let hydrationQueue = DispatchQueue(
        label: "ai.mechanician.conversation-hydration", qos: .utility)
    private var hydrationWaiters: [UUID: [ConversationHydrationWaiter]] = [:]
    private struct PendingSidebarMutation {
        var sortIndex: Int? = nil
        var favorite: Bool? = nil
        var unread: Bool? = nil
    }
    /// Coalesces sidebar state for an evicted row into one hydration owner. Summaries intentionally
    /// remain unchanged until the authority record hydrates, so they cannot arbitrate a later
    /// reorder, favorite, or read-state command. One shared slot preserves request order even when
    /// those commands interleave while the same record is being decoded.
    private var pendingSidebarMutations: [UUID: PendingSidebarMutation] = [:]
    /// A canceled job is removed before its replacement is enqueued. The UUID prevents a late block
    /// from consuming that replacement's waiters or publishing its obsolete result.
    private var hydrationJobs: [UUID: ConversationHydrationJob] = [:]
#if DEBUG
    /// Deterministic seams for cancellation/identity tests. Both run off-main on the hydration queue.
    nonisolated(unsafe) static var hydrationWillReadTestHook: ((UUID) -> Void)?
    nonisolated(unsafe) static var hydrationDidReadTestHook: ((UUID) -> Void)?
    /// Deterministic seams for the independent bounded transcript reader. Tests may suspend either
    /// side of the repository call without placing test-only timing or transcript data in product
    /// state.
    nonisolated(unsafe) static var transcriptPageWillReadTestHook: ((UUID) -> Void)?
    nonisolated(unsafe) static var transcriptPageDidReadTestHook: ((UUID) -> Void)?
#endif
    /// Invalidates an off-main decode when a synchronous repair, mutation, upsert, or delete wins
    /// while its completion is waiting for the main actor. The stale payload may satisfy waiters
    /// from the newer resident value, but may never overwrite it.
    private var hydrationEpochs: [UUID: UInt64] = [:]
    private var sourceByteCounts: [UUID: Int] = [:]
    /// O(1) filesystem-generation receipts for the exact authoritative sidecars represented by
    /// the current inventory. SQLite may supply a value only while this token still matches.
    private var sourceGenerationTokens: [UUID: String] = [:]
    private var artifactIDsByConversation: [UUID: Set<UUID>] = [:]
    private var modelAccessByConversation: [UUID: ModelAccess] = [:]
    private var residentRevisions: [UUID: UInt64] = [:]
    private var persistedRevisions: [UUID: UInt64] = [:]
    /// COW runtime baselines for resident SQLite records. They advance only after COMMIT, so a
    /// coalesced successor may over-report dirty rows against an older baseline but cannot omit one.
    private var authorityCommittedBaselines: [UUID: Conversation] = [:]
    /// In-memory high-water marks let several windows allocate one record-local chronology without
    /// writing a counter by itself. Every allocated ordinal is attached to an event and follows the
    /// next existing save boundary; a crash may leave a harmless gap, never a fabricated event.
    private var captureOrdinalHighWater: [UUID: UInt64] = [:]
    /// A numeric entry alone is not proof that retained evidence was examined: callers can reserve
    /// an ordinal for an as-yet unknown id while an asynchronous launch inventory is still loading.
    /// Keep that provisional state distinct so later publication must still seed the durable record.
    private var captureOrdinalSeededIDs: Set<UUID> = []
    /// Regression seam for the allocation hot path. A resident record is scanned once when it is
    /// installed (or lazily once for an unexpected legacy caller), never once per provider event.
    private(set) var captureOrdinalSeedScanCount = 0
    /// Main-actor transcript walks performed to build a complete sidebar summary. Title-only
    /// mutations patch the already-authoritative summary and leave this count unchanged.
    private(set) var fullSummaryDerivationCount = 0
    /// Main-actor transcript walks performed at a generic save boundary to prove the retained
    /// capture high-watermark. A title-only mutation preserves the seeded chronology verbatim.
    private(set) var saveCaptureOrdinalScanCount = 0
    private var lastAccessTicks: [UUID: UInt64] = [:]
    /// Short-lived multi-record operations claim every required record before their first
    /// mutation. A claim prevents the bounded cache from evicting an early hydration while a later
    /// member is still decoding. Counts let overlapping operations safely share a resident value.
    private var temporaryResidencyClaims: [UUID: Int] = [:]
    /// One short-lived predecessor per live window. Large records can exceed the ordinary idle
    /// byte budget by themselves; evicting the record the instant A→B completes makes the common
    /// B→A correction pay another full decode. This is a bounded navigation lease, not a second
    /// cache: another departure from the same window replaces it and the deadline releases it.
    private struct BackNavigationRetention {
        var conversationID: UUID
        var expiresAt: Date
        var token: UUID
    }
    private var backNavigationRetentions: [UUID: BackNavigationRetention] = [:]
    private var backNavigationExpiryWork: [UUID: DispatchWorkItem] = [:]
    static let backNavigationRetentionInterval: TimeInterval = 30
    private var accessTick: UInt64 = 0
    private(set) var hydrationDecodeCounts: [UUID: Int] = [:]
    private(set) var evictionCount = 0
    private static let maximumIdleResidentCount = 4
    // Encoded JSON understates Swift's object-graph footprint by several times. A 128 MB source
    // allowance could therefore retain the 86 MB/10k-row record plus three peers and erase the
    // checkpoint's physical-memory win. Current/operative records are pinned separately; idle
    // convenience residency gets the deliberately tighter source-byte ceiling.
    private static let maximumIdleResidentBytes = 32 * 1_024 * 1_024
    private static let memoryReclaimQueue = DispatchQueue(
        label: "ai.mechanician.conversation-memory-reclaim", qos: .utility)
    /// Dogfood defaults to bounded residency, with a relaunch kill switch that does not require a
    /// replacement build. Public builds stay eager until this checkpoint graduates.
    nonisolated private static func productionResidencyMode() -> ConversationResidencyMode {
        ConversationResidencyRolloutPolicy.mode(
            provenance: BuildProvenance.current,
            environmentValue: ProcessInfo.processInfo.environment[
                "MECHANICIAN_CONVERSATION_RESIDENCY"],
            preferenceValue: UserDefaults.standard.string(forKey: "conversation.residencyMode"))
    }

    /// Run `block` after the complete inventory and operative records are ready. It runs immediately
    /// and inline when already ready, preserving synchronous-path ordering for tests and callers.
    func whenReady(_ block: @escaping @MainActor () -> Void) {
        if isReady { block() } else { readyCallbacks.append(block) }
    }

    /// Run after launch inventory resolution, including the fail-closed path. Callers must inspect
    /// `isReady` before treating the inventory as usable.
    func whenLaunchInventoryResolved(_ block: @escaping @MainActor () -> Void) {
        if isReady || authoritativeInventoryLoaded {
            block()
        } else {
            launchInventoryResolutionCallbacks.append(block)
        }
    }

    /// Heavy launch maintenance is serialized without delaying the product-ready edge. The
    /// disposable search projection and rollback reclaimer use this gate after first paint.
    func whenLaunchProjectionSettles(_ block: @escaping @MainActor () -> Void) {
        if launchProjectionSettled { block() } else { launchProjectionCallbacks.append(block) }
    }

    /// The override/watcher switch keeps persistence recovery testable without touching the user's
    /// real Application Support directory. Production uses the defaults through `shared`, which
    /// opts into asynchronous inventory recovery so a full corpus decode never blocks first paint.
    init(
        appSupportBaseOverride: URL? = nil,
        watchesDirectory: Bool = true,
        loadsAsynchronously: Bool = false,
        residencyMode: ConversationResidencyMode = .eager,
        libraryAuthorityRepository: LibraryAuthorityRepository? = nil,
        selectsSQLiteAuthorityForTesting: Bool? = nil,
        liveCheckpointMaximumLatency: TimeInterval = 15
    ) {
        self.appSupportBaseOverride = appSupportBaseOverride
        self.liveCheckpointMaximumLatency = max(0, liveCheckpointMaximumLatency)
        if selectsSQLiteAuthorityForTesting == true {
            selectedSQLiteAuthority = true
            authorityRepository = libraryAuthorityRepository
            authorityRepositoryOpenFailure = libraryAuthorityRepository == nil
                ? "The injected SQLite authority repository is unavailable."
                : nil
        } else if let libraryAuthorityRepository {
            selectedSQLiteAuthority = true
            authorityRepository = libraryAuthorityRepository
            authorityRepositoryOpenFailure = nil
        } else if appSupportBaseOverride == nil,
                  NSClassFromString("XCTestCase") == nil,
                  case .sqlite = StorageAuthorityBootstrap.current.disposition {
            selectedSQLiteAuthority = true
            authorityRepository = LibraryAuthorityRepository.sharedIfActive
            authorityRepositoryOpenFailure = authorityRepository == nil
                ? "The SQLite authority repository was not available for the selected root."
                : nil
        } else {
            selectedSQLiteAuthority = false
            authorityRepository = nil
            authorityRepositoryOpenFailure = nil
        }
        requestedResidencyMode = residencyMode
        // Runtime projection failures are session-terminal so search can fall back truthfully. On
        // the next launch, rebuild the shared disposable cache before its first queued reader. The
        // authority check also repairs installs whose failure predates the content-free marker.
        let projectionCacheRequiresRebuild = authorityRepository.flatMap {
            try? $0.conversationProjectionCacheRequiresRebuild()
        } ?? false
        projections = ConversationProjectionStore(
            appSupportBase: appSupportBase,
            rebuildBeforeOpen: projectionCacheRequiresRebuild)
        // Paint the same typed rows the ready store will publish, straight from the disposable
        // projection while the authoritative sidecars decode. A late projection result must never
        // overwrite rows created in memory during launch or the authoritative post-load inventory.
        projections.summaries { [weak self] projected in
            self?.acceptProjectedSummaries(projected)
        }
        if selectedSQLiteAuthority {
            guard let authorityRepository else {
                persistenceError = authorityRepositoryOpenFailure
                    ?? "The SQLite authority repository could not be opened."
                searchIndexState = .failed
                authoritativeInventoryLoaded = true
                return
            }
            LaunchMetrics.shared.mark(.storeOpen)
            let loadAuthority = { [requestedResidencyMode = self.requestedResidencyMode] () throws
                -> (LibraryAuthorityLaunchInventory, [Conversation]) in
                let inventory = try authorityRepository.launchInventory()
                LaunchMetrics.markFromBackground(.libraryRead)
                var residents = inventory.intrinsicConversations
                if requestedResidencyMode == .eager {
                    let residentIDs = Set(residents.map(\.id))
                    for binding in inventory.conversations
                    where !residentIDs.contains(binding.summary.id) {
                        guard let conversation = try authorityRepository.conversation(
                            id: binding.summary.id) else {
                            throw ConversationHydrationError.missing
                        }
                        residents.append(conversation)
                    }
                }
                return (inventory, residents)
            }
            if loadsAsynchronously {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    do {
                        let (inventory, residents) = try loadAuthority()
                        LaunchMetrics.markFromBackground(.residentsLoaded)
                        Task { @MainActor [weak self] in
                            self?.applyAuthorityLaunchInventory(
                                inventory,
                                residents: residents)
                        }
                    } catch {
                        Task { @MainActor [weak self] in
                            self?.failAuthorityLaunch(error)
                        }
                    }
                }
            } else {
                do {
                    let (inventory, residents) = try loadAuthority()
                    LaunchMetrics.shared.mark(.residentsLoaded)
                    applyAuthorityLaunchInventory(inventory, residents: residents)
                } catch {
                    failAuthorityLaunch(error)
                }
            }
            return
        }
        // Undo is a within-session affordance, so trashed conversations do not accumulate
        // forever. Deliberately at launch rather than on a timer: nothing can be mid-undo yet.
        if trashesDeletes {
            let trash = self.trash
            let retention = Self.trashRetention
            saveQueue.async {
                trash.reap(olderThan: retention)
            }
        }
        let dir = storeDir
        if loadsAsynchronously {
            startLegacyLaunchFallback(
                storeDir: dir,
                watchesDirectory: watchesDirectory)
        } else {
            applyLoadResult(Self.scanDisk(storeDir: dir))
            finishBecomingReady(watchesDirectory: watchesDirectory)
        }
    }

    /// Publish a SQLite-authority launch without touching the frozen Legacy census, generation
    /// tokens, or directory watcher. The repository inventory is already one transactionally
    /// consistent closed set; only in-process creations/deletes that raced async launch may amend it.
    private func applyAuthorityLaunchInventory(
        _ inventory: LibraryAuthorityLaunchInventory,
        residents originalResidents: [Conversation]
    ) {
        let bindings = inventory.conversations
        let bindingIDs = Set(bindings.map(\.summary.id))
        guard bindingIDs.count == bindings.count else {
            failAuthorityLaunch(ConversationHydrationError.unreadable)
            return
        }
        let originalResidentIDs = Set(originalResidents.map(\.id))
        guard originalResidentIDs.count == originalResidents.count,
              originalResidentIDs.isSubset(of: bindingIDs) else {
            failAuthorityLaunch(ConversationHydrationError.unreadable)
            return
        }

        let preReadyResidents = conversations
        let preReadyIDs = Set(preReadyResidents.map(\.id))
        var launchResidents: [Conversation] = []
        var healedIDs = Set<UUID>()
        for original in originalResidents
        where !deletedIDs.contains(original.id) && !preReadyIDs.contains(original.id) {
            var conversation = original
            if Self.healStaleState(&conversation) { healedIDs.insert(conversation.id) }
            launchResidents.append(conversation)
        }
        launchResidents.append(contentsOf: preReadyResidents)
        let residentsByID = Dictionary(uniqueKeysWithValues: launchResidents.map { ($0.id, $0) })
        let preReadySummaries = Dictionary(uniqueKeysWithValues: preReadyResidents.map {
            ($0.id, deriveSummary(from: $0))
        })

        var launchSummaries = bindings.compactMap { binding -> ConversationSummary? in
            guard !deletedIDs.contains(binding.summary.id),
                  preReadySummaries[binding.summary.id] == nil else { return nil }
            if let resident = residentsByID[binding.summary.id] {
                return deriveSummary(from: resident)
            }
            return binding.summary
        }
        launchSummaries.append(contentsOf: preReadySummaries.values)
        launchSummaries.sort(by: ConversationSummary.canonicalOrder)

        for conversation in launchResidents where !preReadyIDs.contains(conversation.id) {
            seedCaptureOrdinalHighWaterFromDurableRecord(conversation)
        }
        conversations = launchResidents.sorted(by: Self.order)
        summaries = launchSummaries
        authorityCommittedBaselines = Dictionary(uniqueKeysWithValues: originalResidents.compactMap {
            conversation in
            guard !deletedIDs.contains(conversation.id),
                  !preReadyIDs.contains(conversation.id) else { return nil }
            return (conversation.id, conversation)
        })
        sourceByteCounts = Dictionary(uniqueKeysWithValues: bindings.compactMap { binding in
            deletedIDs.contains(binding.summary.id)
                ? nil : (binding.summary.id, binding.sourceByteCount)
        })
        sourceByteCounts.merge(Dictionary(uniqueKeysWithValues: preReadyResidents.map {
            ($0.id, Self.estimatedResidentByteCount($0))
        })) { _, current in current }
        artifactIDsByConversation = Dictionary(uniqueKeysWithValues: bindings.compactMap { binding in
            deletedIDs.contains(binding.summary.id)
                ? nil : (binding.summary.id, binding.artifactIDs)
        })
        modelAccessByConversation = Dictionary(uniqueKeysWithValues: bindings.compactMap { binding in
            guard !deletedIDs.contains(binding.summary.id), let access = binding.modelAccess else {
                return nil
            }
            return (binding.summary.id, access)
        })
        nonCanonicalFiles.removeAll()
        sourceGenerationTokens.removeAll()
        authoritativeInventoryLoaded = true
        usedSQLiteLaunchInventory = true
        activeResidencyMode = requestedResidencyMode
        // The inventory is authoritative immediately, but content search is not current until the
        // disposable cache proves an exact binding or replays the durable library outbox. This
        // catch-up runs after first paint and never reopens the frozen Legacy corpus.
        searchIndexState = .indexing

        for conversation in launchResidents where !preReadyIDs.contains(conversation.id) {
            residentRevisions[conversation.id] = 0
            persistedRevisions[conversation.id] = 0
            markAccess(conversation.id)
            if !conversation.queuedPrompts.isEmpty {
                pausedQueueConversationIDs.insert(conversation.id)
            }
        }
        // Stale operative launch state is healed through SQLite, never a frozen sidecar.
        for conversation in launchResidents where healedIDs.contains(conversation.id) {
            advanceRevision(conversation.id)
            save(conversation)
        }

        publishReady(watchesDirectory: false)
        authorityRepository?.reconcileProjection(
            projections,
            inventory: inventory
        ) { [weak self] succeeded in
            guard let self else { return }
            self.searchIndexState = succeeded ? .current : .failed
            self.publishLaunchProjectionSettled()
        }
        if inventory.requiresDeferredIntegrityCheck, let authorityRepository {
            DispatchQueue.global(qos: .utility).async {
                try? authorityRepository.verifyIntegrityAfterReady()
            }
        }
    }

    private func failAuthorityLaunch(_ error: Error) {
        NSLog("[persistence] conversation library could not be opened: %@", error.localizedDescription)
        persistenceError = "Mechanician couldn’t open your conversations. Nothing on disk was "
            + "changed. Quit and reopen Mechanician to try again."
        searchIndexState = .failed
        authoritativeInventoryLoaded = true
        publishLaunchInventoryResolved()
    }

    /// The fallback publishes nothing from SQLite. `scanDisk` remains the one recovery path, so an
    /// incomplete inventory cannot create a hybrid sidebar even for a single run-loop.
    private func startLegacyLaunchFallback(
        storeDir: URL,
        watchesDirectory: Bool
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.scanDisk(storeDir: storeDir)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyLoadResult(result)
                self.finishBecomingReady(watchesDirectory: watchesDirectory)
            }
        }
    }

    private func finishBecomingReady(watchesDirectory: Bool) {
        // Reconciling after load is the projection's entire recovery story: new/changed
        // conversations index, orphans drop, and a fresh file backfills from scratch.
        if requestedResidencyMode == .boundedAfterRecovery {
            // File recovery is already complete, so publish readiness now. Projection catch-up can
            // take seconds on the 86 MB corpus case and must not hold navigation/provider startup
            // hostage. Full records remain eagerly resident until reconciliation proves the
            // disposable summary/FTS inventory usable; only that success edge activates eviction.
            activeResidencyMode = .eager
            searchIndexState = .indexing
            publishReady(watchesDirectory: watchesDirectory)
            projections.reconcile(
                with: conversations,
                sourceRevisions: sourceGenerationTokens
            ) { [weak self] succeeded in
                guard let self else { return }
                self.searchIndexState = succeeded ? .current : .failed
                if succeeded {
                    self.activeResidencyMode = .boundedAfterRecovery
                    self.trimResidencyIfNeeded()
                }
                self.publishLaunchProjectionSettled()
            }
            return
        }
        searchIndexState = .indexing
        projections.reconcile(
            with: conversations,
            sourceRevisions: sourceGenerationTokens
        ) { [weak self] succeeded in
            self?.searchIndexState = succeeded ? .current : .failed
            self?.publishLaunchProjectionSettled()
        }
        activeResidencyMode = .eager
        publishReady(watchesDirectory: watchesDirectory)
    }

    private func publishReady(watchesDirectory: Bool) {
        if watchesDirectory {
            _ = startWatchingDir()  // idempotent when SQLite launch armed it before validation
        }
        isReady = true
        let callbacks = readyCallbacks
        readyCallbacks = []
        for callback in callbacks { callback() }
        publishLaunchInventoryResolved()
        // Recovery/adoption callbacks run first. They claim operative records and restore the
        // visible selection; only then may clean idle records leave the resident working set.
        if activeResidencyMode == .boundedAfterRecovery {
            DispatchQueue.main.async { [weak self] in self?.trimResidencyIfNeeded() }
        }
    }

    private func publishLaunchInventoryResolved() {
        let callbacks = launchInventoryResolutionCallbacks
        launchInventoryResolutionCallbacks = []
        for callback in callbacks { callback() }
    }

    private func publishLaunchProjectionSettled() {
        guard !launchProjectionSettled else { return }
        launchProjectionSettled = true
        let callbacks = launchProjectionCallbacks
        launchProjectionCallbacks = []
        for callback in callbacks { callback() }
    }

    private func acceptProjectedSummaries(_ projected: [ConversationSummary]) {
        guard !isReady, !authoritativeInventoryLoaded else { return }
        let currentIDs = Set(summaries.map(\.id))
        var merged = projected.filter {
            !deletedIDs.contains($0.id) && !currentIDs.contains($0.id)
        }
        merged.append(contentsOf: summaries)
        merged.sort(by: ConversationSummary.canonicalOrder)
        if merged != summaries { summaries = merged }
    }

    private func deriveSummary(from conversation: Conversation) -> ConversationSummary {
        fullSummaryDerivationCount += 1
        return ConversationSummary(conversation)
    }

    @discardableResult
    private func refreshSummary(for conversation: Conversation) -> Bool {
        artifactIDsByConversation[conversation.id] = Set(conversation.artifacts.map(\.uuid))
        modelAccessByConversation[conversation.id] = conversation.modelSelection?.access
        let summary = deriveSummary(from: conversation)
        var refreshed = summaries
        if let index = refreshed.firstIndex(where: { $0.id == conversation.id }) {
            guard refreshed[index] != summary else { return false }
            refreshed[index] = summary
        } else {
            refreshed.append(summary)
        }
        refreshed.sort(by: ConversationSummary.canonicalOrder)
        summaries = refreshed
        return true
    }

    /// Summary-neutral full-record facts (artifacts, provider sessions, residency) still need one
    /// semantic notification at durable/cache boundaries. This happens after in-place mutation so
    /// a long transcript keeps unique storage instead of paying an O(transcript) copy merely to
    /// stage ObservableObject's notification; bridge/SwiftUI consumers read on the next run-loop.
    private func refreshSummaryOrPublishResidentChange(for conversation: Conversation) {
        if !refreshSummary(for: conversation) { objectWillChange.send() }
    }

    private func rebuildSummaries() {
        artifactIDsByConversation = Dictionary(uniqueKeysWithValues: conversations.map {
            ($0.id, Set($0.artifacts.map(\.uuid)))
        })
        modelAccessByConversation = Dictionary(uniqueKeysWithValues: conversations.compactMap { conversation in
            conversation.modelSelection.map { (conversation.id, $0.access) }
        })
        let rebuilt = conversations
            .map { deriveSummary(from: $0) }
            .sorted(by: ConversationSummary.canonicalOrder)
        if rebuilt != summaries { summaries = rebuilt }
    }

    private func cancelLiveSummaryRefresh(_ id: UUID) {
        pendingLiveContentRefreshIDs.remove(id)
        pendingLiveSummaryRefreshIDs.remove(id)
        if pendingLiveSummaryRefreshIDs.isEmpty {
            pendingLiveSummaryRefresh?.cancel()
            pendingLiveSummaryRefresh = nil
        }
    }

    private func scheduleLiveSummaryRefresh(_ id: UUID) {
        pendingLiveSummaryRefreshIDs.insert(id)
        guard pendingLiveSummaryRefresh == nil else { return }
        pendingLiveSummaryRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            let ids = self.pendingLiveSummaryRefreshIDs
            self.pendingLiveSummaryRefreshIDs.removeAll()
            self.pendingLiveSummaryRefresh = nil
            self.refreshLivePresentation(for: ids)
        }
    }

    private func refreshLivePresentation(for ids: Set<UUID>) {
        var refreshedSummaries = summaries
        var summaryDidChange = false
        var contentRefreshIDs: Set<UUID> = []
        for id in ids {
            if pendingLiveContentRefreshIDs.remove(id) != nil {
                contentRefreshIDs.insert(id)
            }
            guard let conversation = conversation(id) else { continue }
            artifactIDsByConversation[id] = Set(conversation.artifacts.map(\.uuid))
            modelAccessByConversation[id] = conversation.modelSelection?.access
            let summary = deriveSummary(from: conversation)
            if let index = refreshedSummaries.firstIndex(where: { $0.id == id }) {
                if refreshedSummaries[index] != summary {
                    refreshedSummaries[index] = summary
                    summaryDidChange = true
                }
            } else {
                refreshedSummaries.append(summary)
                summaryDidChange = true
            }
        }
        if summaryDidChange {
            refreshedSummaries.sort(by: ConversationSummary.canonicalOrder)
            summaries = refreshedSummaries
        } else if !contentRefreshIDs.isEmpty {
            liveResidentContentDidChange.send(contentRefreshIDs)
        }
    }

    /// Deterministic test/diagnostic drain for the presentation coalescer. This does not write
    /// files or projections; terminal durable mutations already publish synchronously.
    func flushLiveSummaryRefreshes() {
        pendingLiveSummaryRefresh?.cancel()
        pendingLiveSummaryRefresh = nil
        let ids = pendingLiveSummaryRefreshIDs
        pendingLiveSummaryRefreshIDs.removeAll()
        refreshLivePresentation(for: ids)
    }

    // MARK: - Lookup

    /// Complete inventory membership. This remains true while a full record is evicted.
    func hasConversation(_ id: UUID) -> Bool {
        summaries.contains { $0.id == id }
    }

    func summary(_ id: UUID?) -> ConversationSummary? {
        guard let id else { return nil }
        return summaries.first { $0.id == id }
    }

    var conversationIDs: Set<UUID> { Set(summaries.map(\.id)) }

    func conversationHasArtifacts(_ id: UUID) -> Bool {
        artifactIDsByConversation[id]?.isEmpty == false
    }

    func conversationIDs(referencingArtifactIDs artifactIDs: Set<UUID>) -> Set<UUID> {
        guard !artifactIDs.isEmpty else { return [] }
        return Set(artifactIDsByConversation.compactMap { id, known in
            known.isDisjoint(with: artifactIDs) ? nil : id
        })
    }

    func conversationIDs(using access: ModelAccess) -> [UUID] {
        modelAccessByConversation.compactMap { $0.value == access ? $0.key : nil }
    }

    /// Cache-only lookup. Inventory-only callers must use `hasConversation`/`summary`; callers that
    /// require transcript bytes use `acquireConversation` so decoding never blocks the main actor.
    func residentConversation(_ id: UUID?) -> Conversation? {
        guard let id, let conversation = conversations.first(where: { $0.id == id }) else {
            return nil
        }
        markAccess(id)
        return conversation
    }

    /// Compatibility during the call-site migration. Semantics are intentionally cache-only.
    func conversation(_ id: UUID?) -> Conversation? {
        residentConversation(id)
    }
    func contains(_ id: UUID) -> Bool { hasConversation(id) }

    private struct HydratedPayload {
        enum ReadSource {
            case sqlite(milliseconds: Double)
            case legacy(milliseconds: Double)

            var milliseconds: Double {
                switch self {
                case .sqlite(let milliseconds), .legacy(let milliseconds): milliseconds
                }
            }
        }

        var conversation: Conversation
        var sourceBytes: Int
        /// Computed beside decode/reconstruction on the hydration queue. Installation can seed
        /// chronology without walking a legacy transcript on the MainActor.
        var captureOrdinalHighWatermark: UInt64
        var scannedRetainedCaptureOrdinals: Bool
        var healed: Bool
        var readSource: ReadSource
        /// Measured from scheduler admission to the first instruction on the worker. Synchronous
        /// legacy callers leave this at zero; all async acquisitions replace it before publishing.
        var queueWaitMilliseconds: Double = 0
    }

    /// Coalesced, serial, off-main hydration. Every waiter receives the same validated value; a
    /// missing/corrupt file leaves its summary in the inventory and can never create or save an
    /// empty replacement record.
    @discardableResult
    func acquireConversation(
        _ id: UUID,
        priority: ConversationHydrationPriority = .background,
        timing: (@MainActor (ConversationHydrationTiming) -> Void)? = nil,
        completion: @escaping @MainActor (Result<Conversation, ConversationHydrationError>) -> Void
    ) -> ConversationHydrationRequest? {
        acquireConversation(
            id,
            refreshesSummaryAfterHydration: true,
            priority: priority,
            timing: timing,
            completion: completion)
    }

    /// Title-only acquisition is the one safe exception to a conservative summary rebuild. The
    /// SQLite launch inventory and hydrated record come from the same single-writer authority, and
    /// the mutation immediately patches the only changed summary field. If another waiter joins
    /// the coalesced read and asks for a rebuild, that stronger request wins in `finishHydration`.
    @discardableResult
    private func acquireConversation(
        _ id: UUID,
        refreshesSummaryAfterHydration: Bool,
        priority: ConversationHydrationPriority = .background,
        timing: (@MainActor (ConversationHydrationTiming) -> Void)? = nil,
        completion: @escaping @MainActor (Result<Conversation, ConversationHydrationError>) -> Void
    ) -> ConversationHydrationRequest? {
        if let conversation = residentConversation(id) {
            timing?(ConversationHydrationTiming(
                priority: priority,
                queueWaitMilliseconds: 0,
                readMilliseconds: 0))
            completion(.success(conversation))
            return nil
        }
        guard hasConversation(id), !deletedIDs.contains(id) else {
            completion(.failure(.deleted))
            return nil
        }
        let request = ConversationHydrationRequest(
            conversationID: id,
            waiterID: UUID())
        let waiter = ConversationHydrationWaiter(
            id: request.waiterID,
            refreshesSummaryAfterHydration: refreshesSummaryAfterHydration,
            timing: timing,
            completion: completion)
        if hydrationWaiters[id] != nil {
            hydrationWaiters[id, default: []].append(waiter)
            // A selection can arrive after maintenance already began loading the same record.
            // Keep every waiter, but replace that job with an interactive admission so the selected
            // Conversation never inherits the background lane's backlog. `finishHydration` fences
            // the canceled block by job ID, and its cancellation flag stops it before duplicate
            // reconstruction/publication whenever it has not crossed the repository boundary.
            if priority == .interactive,
               hydrationJobs[id]?.priority == .background {
                cancelHydrationJob(id)
                startHydrationJob(id, priority: .interactive)
            } else if hydrationJobs[id] == nil {
                // Keep the coalescing invariant defensively even if a future cancellation path
                // removes a job before it can remove its waiters.
                startHydrationJob(id, priority: priority)
            }
            return request
        }
        hydrationWaiters[id] = [waiter]
        startHydrationJob(id, priority: priority)
        return request
    }

    /// Start exactly one off-main whole-record read for the current waiters. The job identity is
    /// stored before dispatch so a cancellation/promotion can make a late worker result inert.
    private func startHydrationJob(
        _ id: UUID,
        priority: ConversationHydrationPriority
    ) {
        let epoch = hydrationEpochs[id] ?? 0
        let jobID = UUID()
        let cancellation = ConversationHydrationCancellation()
        let enqueuedAt = ContinuousClock.now
        let repository = authorityRepository
        let legacyURL = repository == nil ? sourceURL(for: id) : nil
        let workItem = DispatchWorkItem { [weak self] in
            let queueWaitMilliseconds = Self.milliseconds(since: enqueuedAt)
            guard !cancellation.isCancelled else { return }
#if DEBUG
            Self.hydrationWillReadTestHook?(id)
#endif
            guard !cancellation.isCancelled else { return }
            let rawResult: Result<HydratedPayload, ConversationHydrationError>
            if let repository {
                rawResult = Self.hydrateAuthorityConversation(
                    id: id,
                    repository: repository,
                    usesInteractiveReader: priority == .interactive,
                    isCancelled: { cancellation.isCancelled })
            } else if let legacyURL {
                rawResult = Self.decodeHydratedConversation(
                    id: id,
                    from: legacyURL,
                    isCancelled: { cancellation.isCancelled })
            } else {
                rawResult = .failure(.unreadable)
            }
            let result = rawResult.map { payload in
                var payload = payload
                payload.queueWaitMilliseconds = queueWaitMilliseconds
                return payload
            }
            guard !cancellation.isCancelled else { return }
#if DEBUG
            Self.hydrationDidReadTestHook?(id)
#endif
            guard !cancellation.isCancelled else { return }
            Task { @MainActor [weak self] in
                guard !cancellation.isCancelled else { return }
                self?.finishHydration(
                    id: id,
                    jobID: jobID,
                    epoch: epoch,
                    result: result)
            }
        }
        hydrationJobs[id] = ConversationHydrationJob(
            id: jobID,
            priority: priority,
            cancellation: cancellation,
            workItem: workItem)
        switch priority {
        case .interactive:
            interactiveHydrationQueue.async(execute: workItem)
        case .background:
            hydrationQueue.async(execute: workItem)
        }
    }

    /// Withdraw exactly one caller from a coalesced hydration. If it was the last waiter, abandon the
    /// job and remove its identity before a replacement can be enqueued for the same Conversation.
    func cancelConversationAcquisition(_ request: ConversationHydrationRequest) {
        let id = request.conversationID
        guard var waiters = hydrationWaiters[id],
              let index = waiters.firstIndex(where: { $0.id == request.waiterID }) else { return }
        waiters.remove(at: index)
        guard !waiters.isEmpty else {
            hydrationWaiters[id] = nil
            cancelHydrationJob(id)
            return
        }
        hydrationWaiters[id] = waiters
    }

    private func cancelHydrationJob(_ id: UUID) {
        guard let job = hydrationJobs.removeValue(forKey: id) else { return }
        job.cancellation.cancel()
        job.workItem.cancel()
    }

    /// Hydrate a complete operation set off-main, then run one synchronous main-actor transaction
    /// while every member is pinned. Failure is all-or-nothing: `completion` receives the first
    /// load error and no mutation has happened. Claims are always released after the callback.
    ///
    /// The callback may finish inline when all records are already resident. It must perform all
    /// reads and mutations synchronously and must not retain resident values as later write inputs.
    /// A caller that discovers more required ids may start a larger nested acquisition before this
    /// callback returns; reference-counted claims preserve the already-loaded members without a gap.
    func withAcquiredConversations(
        _ ids: Set<UUID>,
        completion: @escaping @MainActor (Result<Void, ConversationHydrationError>) -> Void
    ) {
        let ordered = ids.sorted { $0.uuidString < $1.uuidString }
        guard !ordered.isEmpty else {
            completion(.success(()))
            return
        }
        for id in ordered {
            temporaryResidencyClaims[id, default: 0] += 1
        }
        acquireClaimedConversations(ordered, at: 0) { [self] result in
            defer {
                for id in ordered {
                    let remaining = (temporaryResidencyClaims[id] ?? 1) - 1
                    if remaining > 0 {
                        temporaryResidencyClaims[id] = remaining
                    } else {
                        temporaryResidencyClaims[id] = nil
                    }
                }
                trimResidencyIfNeeded()
            }
            completion(result)
        }
    }

    private func acquireClaimedConversations(
        _ ids: [UUID],
        at index: Int,
        completion: @escaping @MainActor (Result<Void, ConversationHydrationError>) -> Void
    ) {
        guard index < ids.count else {
            for id in ids {
                guard residentConversation(id) != nil else {
                    completion(.failure(.deleted))
                    return
                }
            }
            completion(.success(()))
            return
        }
        acquireConversation(ids[index]) { [self] result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                acquireClaimedConversations(ids, at: index + 1, completion: completion)
            }
        }
    }

    nonisolated private static func decodeHydratedConversation(
        id: UUID,
        from url: URL,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> Result<HydratedPayload, ConversationHydrationError> {
        let started = ContinuousClock.now
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing) }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return .failure(.unreadable)
        }
        // The mapped read and JSON reconstruction are separate costs. A superseding click that
        // lands between them should never spend the serial hydration lane decoding obsolete bytes.
        guard !isCancelled(),
              var conversation = try? makeDecoder().decode(Conversation.self, from: data) else {
            return .failure(.unreadable)
        }
        guard !isCancelled() else { return .failure(.unreadable) }
        guard conversation.id == id else { return .failure(.identityMismatch) }
        let healed = healStaleState(&conversation)
        let scannedRetainedCaptureOrdinals = conversation.captureOrdinalHighWatermark == nil
        let captureOrdinalHighWatermark = conversation.captureOrdinalHighWatermark
            ?? retainedCaptureOrdinalMaximum(in: conversation)
        guard !isCancelled() else { return .failure(.unreadable) }
        return .success(HydratedPayload(
            conversation: conversation,
            sourceBytes: data.count,
            captureOrdinalHighWatermark: captureOrdinalHighWatermark,
            scannedRetainedCaptureOrdinals: scannedRetainedCaptureOrdinals,
            healed: healed,
            readSource: .legacy(milliseconds: milliseconds(since: started))))
    }

    /// SQLite authority has no source-generation fallback: one repository snapshot is the complete
    /// record, and a failed/malformed row stays failed instead of consulting frozen Legacy bytes.
    nonisolated private static func hydrateAuthorityConversation(
        id: UUID,
        repository: LibraryAuthorityRepository,
        usesInteractiveReader: Bool = false,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> Result<HydratedPayload, ConversationHydrationError> {
        let started = ContinuousClock.now
        do {
            let conversation: Conversation?
            if usesInteractiveReader {
                conversation = try repository.interactiveConversation(
                    id: id,
                    isCancelled: isCancelled)
            } else {
                conversation = try repository.conversation(
                    id: id,
                    isCancelled: isCancelled)
            }
            guard var conversation else {
                return .failure(.missing)
            }
            guard !isCancelled() else { return .failure(.unreadable) }
            guard conversation.id == id else { return .failure(.identityMismatch) }
            let healed = healStaleState(&conversation)
            let scannedRetainedCaptureOrdinals = conversation.captureOrdinalHighWatermark == nil
            let captureOrdinalHighWatermark = conversation.captureOrdinalHighWatermark
                ?? retainedCaptureOrdinalMaximum(in: conversation)
            guard !isCancelled() else { return .failure(.unreadable) }
            return .success(HydratedPayload(
                conversation: conversation,
                sourceBytes: estimatedResidentByteCount(conversation),
                captureOrdinalHighWatermark: captureOrdinalHighWatermark,
                scannedRetainedCaptureOrdinals: scannedRetainedCaptureOrdinals,
                healed: healed,
                readSource: .sqlite(milliseconds: milliseconds(since: started))))
        } catch {
            return .failure(.unreadable)
        }
    }

    /// Bounded residency still needs a weight after the JSON source disappears. Counting retained
    /// transcript and compaction-summary strings is linear but allocation-free and tracks the
    /// dominant corpus bytes much more honestly than treating a reconstructed 100 MB record as
    /// weight zero. Internal visibility lets the focused residency test pin this accounting rule.
    nonisolated static func estimatedResidentByteCount(_ conversation: Conversation) -> Int {
        conversation.messages.reduce(0) { partial, entry in
            let entryBytes = estimatedResidentByteCount(entry)
            let (sum, overflow) = partial.addingReportingOverflow(entryBytes)
            return overflow ? Int.max : sum
        }
    }

    nonisolated private static func estimatedResidentByteCount(_ entry: TranscriptEntry) -> Int {
        let summaryBytes = entry.compactionSummary?.utf8.count ?? 0
        let (bytes, overflow) = entry.text.utf8.count.addingReportingOverflow(summaryBytes)
        return overflow ? Int.max : bytes
    }

    nonisolated private static func milliseconds(
        since started: ContinuousClock.Instant
    ) -> Double {
        let duration = started.duration(to: .now)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private func finishHydration(
        id: UUID,
        jobID: UUID,
        epoch: UInt64,
        result: Result<HydratedPayload, ConversationHydrationError>
    ) {
        // A cancellation removes this identity before a replacement request can install its own job.
        // The old block may still leave the serial queue, but it cannot consume the new waiters.
        guard let job = hydrationJobs[id], job.id == jobID else { return }
        hydrationJobs[id] = nil
        let waiters = hydrationWaiters.removeValue(forKey: id) ?? []
        guard hasConversation(id), !deletedIDs.contains(id) else {
            for waiter in waiters { waiter.completion(.failure(.deleted)) }
            return
        }
        if hydrationEpochs[id] != nil, hydrationEpochs[id] != epoch {
            if let current = residentConversation(id) {
                for waiter in waiters { waiter.completion(.success(current)) }
            } else {
                for waiter in waiters { waiter.completion(.failure(.unreadable)) }
            }
            return
        }
        switch result {
        case .failure(let error):
            failedHydrationIDs.insert(id)
            refreshHydrationError()
            for waiter in waiters { waiter.completion(.failure(error)) }
        case .success(let payload):
            failedHydrationIDs.remove(id)
            refreshHydrationError()
            hydrationDecodeCounts[id, default: 0] += 1
            let timing = ConversationHydrationTiming(
                priority: job.priority,
                queueWaitMilliseconds: payload.queueWaitMilliseconds,
                readMilliseconds: payload.readSource.milliseconds)
            switch payload.readSource {
            case .sqlite(let milliseconds):
                sqliteReadMetrics.sqliteReads += 1
                sqliteReadMetrics.lastSQLiteMilliseconds = milliseconds
                sqliteReadMetrics.slowestSQLiteMilliseconds = max(
                    sqliteReadMetrics.slowestSQLiteMilliseconds ?? 0,
                    milliseconds)
            case .legacy(let milliseconds):
                sqliteReadMetrics.lastLegacyMilliseconds = milliseconds
            }
            let refreshesSummary = payload.healed
                || waiters.isEmpty
                || waiters.contains(where: \.refreshesSummaryAfterHydration)
            installResident(
                payload.conversation,
                sourceBytes: payload.sourceBytes,
                captureOrdinalHighWatermark: payload.captureOrdinalHighWatermark,
                refreshesSummary: refreshesSummary)
            if payload.healed {
                if selectedSQLiteAuthority { authorityCommittedBaselines[id] = nil }
                advanceRevision(id)
                save(payload.conversation)
            }
            for waiter in waiters {
                waiter.timing?(timing)
                waiter.completion(.success(payload.conversation))
            }
            trimResidencyIfNeeded()
        }
    }

    /// Safety fallback for legacy synchronous mutation/export seams. Selection uses the async API;
    /// this path is deliberately counted so remaining main-thread loads stay visible in tests and
    /// diagnostics while call sites move to temporary acquisitions.
    private(set) var synchronousHydrationCount = 0
    @discardableResult
    func hydrateImmediately(_ id: UUID) -> Conversation? {
        if let resident = residentConversation(id) { return resident }
        guard hasConversation(id), !deletedIDs.contains(id) else { return nil }
        synchronousHydrationCount += 1
        let result = hydrationQueue.sync { [authorityRepository] in
            if let authorityRepository {
                return Self.hydrateAuthorityConversation(
                    id: id,
                    repository: authorityRepository)
            }
            return Self.decodeHydratedConversation(id: id, from: sourceURL(for: id))
        }
        guard case .success(let payload) = result,
              hasConversation(id), !deletedIDs.contains(id) else { return nil }
        advanceHydrationEpoch(id)
        hydrationDecodeCounts[id, default: 0] += 1
        if payload.scannedRetainedCaptureOrdinals {
            captureOrdinalSeedScanCount += 1
        }
        installResident(
            payload.conversation,
            sourceBytes: payload.sourceBytes,
            captureOrdinalHighWatermark: payload.captureOrdinalHighWatermark)
        if payload.healed {
            if selectedSQLiteAuthority { authorityCommittedBaselines[id] = nil }
            advanceRevision(id)
            save(payload.conversation)
        }
        return payload.conversation
    }

    private func sourceURL(for id: UUID) -> URL {
        let canonical = storeDir.appendingPathComponent("\(id.uuidString).json")
        guard let nonCanonical = nonCanonicalFiles[id] else { return canonical }
        // This map names the load-time dedupe winner, but a later in-app save always publishes the
        // canonical path and advances `sourceGenerationTokens`. Prefer whichever candidate still
        // owns that exact generation. Otherwise a record evicted after its first canonical save can
        // hydrate the stale Finder/ambient duplicate merely because deletion cleanup has not run.
        if let expectedGeneration = sourceGenerationTokens[id] {
            if ConversationSidecarGeneration.matches(expectedGeneration, for: canonical) {
                return canonical
            }
            if ConversationSidecarGeneration.matches(expectedGeneration, for: nonCanonical) {
                return nonCanonical
            }
        }
        // No exact generation is available (legacy decode raced an external write). Preserve the
        // prior fail-safe winner rather than guessing from timestamps; hydration will decode it and
        // the normal identity fence still refuses an unrelated record.
        return nonCanonical
    }

    /// Show a Conversation the authority already holds, without saving it again.
    ///
    /// Recovery commits the record before calling this. Re-saving it would republish a value the
    /// runtime has just healed and normalized, over bytes a person recovered precisely because the
    /// app could not read them — so this marks the record as already published rather than dirty.
    func adoptRestoredConversation(_ conversation: Conversation) {
        guard !hasConversation(conversation.id) else { return }
        deletedIDs.remove(conversation.id)
        advanceHydrationEpoch(conversation.id)
        installResident(
            conversation,
            sourceBytes: Self.estimatedResidentByteCount(conversation))
        persistedRevisions[conversation.id] = residentRevisions[conversation.id] ?? 0
    }

    private func installResident(
        _ conversation: Conversation,
        sourceBytes: Int,
        captureOrdinalHighWatermark: UInt64? = nil,
        refreshesSummary: Bool = true
    ) {
        if let captureOrdinalHighWatermark {
            installCaptureOrdinalHighWater(
                captureOrdinalHighWatermark,
                for: conversation.id)
        } else {
            seedCaptureOrdinalHighWaterFromDurableRecord(conversation)
        }
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.append(conversation)
        }
        conversations.sort(by: Self.order)
        sourceByteCounts[conversation.id] = sourceBytes
        if residentRevisions[conversation.id] == nil { residentRevisions[conversation.id] = 0 }
        if persistedRevisions[conversation.id] == nil { persistedRevisions[conversation.id] = 0 }
        if selectedSQLiteAuthority {
            authorityCommittedBaselines[conversation.id] = conversation
        }
        markAccess(conversation.id)
        if refreshesSummary || summary(conversation.id) == nil {
            refreshSummaryOrPublishResidentChange(for: conversation)
        }
    }

    private func markAccess(_ id: UUID) {
        accessTick &+= 1
        lastAccessTicks[id] = accessTick
    }

    private func advanceHydrationEpoch(_ id: UUID) {
        hydrationEpochs[id] = (hydrationEpochs[id] ?? 0) &+ 1
    }

    @discardableResult
    private func advanceRevision(_ id: UUID) -> UInt64 {
        let next = (residentRevisions[id] ?? 0) &+ 1
        residentRevisions[id] = next
        return next
    }

    /// Rehydrate the complete inventory when the disposable projection becomes unavailable. This
    /// restores the pre-P1 search fallback for the remainder of the session before any cache trim.
    func fallBackToEagerResidency() {
        guard activeResidencyMode == .boundedAfterRecovery else { return }
        activeResidencyMode = .eager
        hydrateInventorySequentially(Array(conversationIDs))
    }

    func noteSearchProjectionUnavailable() {
        if usedSQLiteLaunchInventory {
            searchIndexState = .failed
        } else {
            fallBackToEagerResidency()
        }
    }

    private func hydrateInventorySequentially(_ ids: [UUID]) {
        guard let id = ids.first else { return }
        acquireConversation(id) { [weak self] _ in
            self?.hydrateInventorySequentially(Array(ids.dropFirst()))
        }
    }

    /// Apply a rare corpus-wide mutation without materializing the corpus. Records hydrate one at a
    /// time on the serial loader, commit through the ordinary file-first save path, then become
    /// eligible for eviction again.
    func updateSequentially(
        _ ids: [UUID],
        mutation: @escaping (inout Conversation) -> Void,
        completion: (() -> Void)? = nil
    ) {
        guard let id = ids.first else { completion?(); return }
        acquireConversation(id) { [weak self] result in
            guard let self else { return }
            if case .success = result { _ = self.update(id, mutation) }
            self.updateSequentially(
                Array(ids.dropFirst()),
                mutation: mutation,
                completion: completion)
        }
    }

    /// Main-actor-safe mutation seam for an inventory row whose full record may be evicted. The
    /// eager/test path remains synchronous; bounded mode decodes off-main and applies the mutation
    /// only after the exact authoritative record is resident.
    func updateAfterAcquiring(
        _ id: UUID,
        mutation: @escaping (inout Conversation) -> Void,
        completion: ((Conversation?) -> Void)? = nil
    ) {
        if residentConversation(id) != nil {
            let updated = update(id, mutation)
            completion?(updated)
            return
        }
        acquireConversation(id) { [weak self] result in
            guard let self, case .success = result else {
                completion?(nil)
                return
            }
            let updated = self.update(id, mutation)
            completion?(updated)
            self.trimResidencyIfNeeded()
        }
    }

    /// Acquire before removal so an unloaded row can still produce an exact undo receipt. A
    /// missing or corrupt source remains in the inventory and reports nil instead of becoming an
    /// irreversible delete.
    func removeAfterAcquiring(
        _ id: UUID,
        permanently: Bool = false,
        completion: @escaping (ConversationDeleteReceipt?) -> Void
    ) {
        if residentConversation(id) != nil {
            completion(remove(id, permanently: permanently))
            return
        }
        acquireConversation(id) { [weak self] result in
            guard let self, case .success = result else {
                completion(nil)
                return
            }
            completion(self.remove(id, permanently: permanently))
        }
    }

    func removeSequentially(
        _ ids: [UUID],
        receipts: [ConversationDeleteReceipt] = [],
        completion: @escaping ([ConversationDeleteReceipt]) -> Void
    ) {
        guard let id = ids.first else { completion(receipts); return }
        removeAfterAcquiring(id) { [weak self] receipt in
            guard let self else { return }
            var next = receipts
            if let receipt { next.append(receipt) }
            self.removeSequentially(
                Array(ids.dropFirst()),
                receipts: next,
                completion: completion)
        }
    }

    func retryFailedHydrations() {
        for id in failedHydrationIDs {
            acquireConversation(id) { [weak self] result in
                guard let self, case .success = result else { return }
                self.failedHydrationIDs.remove(id)
                self.refreshHydrationError()
                self.trimResidencyIfNeeded()
            }
        }
    }

    private func refreshHydrationError() {
        let refreshed: String?
        if failedHydrationIDs.isEmpty {
            refreshed = nil
        } else {
            let count = failedHydrationIDs.count
            refreshed =
                "\(count) conversation file\(count == 1 ? "" : "s") couldn’t be opened. "
                + "\(count == 1 ? "It remains" : "They remain") visible so the binding can be repaired; restore the file and retry."
        }
        if hydrationError != refreshed { hydrationError = refreshed }
    }

    var residentConversationIDs: Set<UUID> { Set(conversations.map(\.id)) }
    /// Avoid touching the process-global singleton merely to decide whether live UI synchronization
    /// applies; isolated tests and import/recovery stores always provide an override.
    var usesApplicationSupportStore: Bool { appSupportBaseOverride == nil }
    var inventorySourceBytes: Int { sourceByteCounts.values.reduce(0, +) }
    var residentSourceBytes: Int {
        conversations.reduce(0) { $0 + (sourceByteCounts[$1.id] ?? 0) }
    }

    /// Preserve the validated predecessor long enough for one immediate Back-like navigation.
    /// `owner` is the window's stable bridge identity, which bounds the exception to one record per
    /// live window. `now` is injectable so eviction behavior is deterministic in tests.
    func retainForBackNavigation(
        _ conversationID: UUID,
        owner: UUID,
        now: Date = Date()
    ) {
        guard hasConversation(conversationID), !deletedIDs.contains(conversationID) else {
            releaseBackNavigationRetention(owner: owner)
            return
        }
        backNavigationExpiryWork.removeValue(forKey: owner)?.cancel()
        let token = UUID()
        backNavigationRetentions[owner] = BackNavigationRetention(
            conversationID: conversationID,
            expiresAt: now.addingTimeInterval(Self.backNavigationRetentionInterval),
            token: token)

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.expireBackNavigationRetention(owner: owner, token: token)
            }
        }
        backNavigationExpiryWork[owner] = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.backNavigationRetentionInterval,
            execute: work)
        // `select` trims again after its hydration callback, but direct navigation paths (New,
        // Fork, adoption and fallbacks) do not. Replacing A's lease with B must therefore make A
        // eligible immediately instead of accumulating every predecessor until B's timer expires.
        trimResidencyIfNeeded()
    }

    /// Release one window's navigation lease, normally when its bridge shuts down.
    func releaseBackNavigationRetention(owner: UUID) {
        backNavigationExpiryWork.removeValue(forKey: owner)?.cancel()
        guard backNavigationRetentions.removeValue(forKey: owner) != nil else { return }
        trimResidencyIfNeeded()
    }

    /// The production timer is monotonic. A generation token makes a cancelled predecessor timer
    /// inert even if Dispatch has already dequeued it, and avoids wall-clock changes extending a
    /// lease beyond its one scheduled interval.
    private func expireBackNavigationRetention(owner: UUID, token: UUID) {
        guard backNavigationRetentions[owner]?.token == token else { return }
        backNavigationRetentions.removeValue(forKey: owner)
        backNavigationExpiryWork.removeValue(forKey: owner)
        trimResidencyIfNeeded()
    }

    /// The scheduled expiry and deterministic tests share one edge. Expired leases stop protecting
    /// values even if the main queue delivered the timer late; the follow-up trim reclaims them.
    func expireBackNavigationRetentions(asOf now: Date = Date()) {
        let expiredOwners = backNavigationRetentions.compactMap { owner, retention in
            retention.expiresAt <= now ? owner : nil
        }
        guard !expiredOwners.isEmpty else { return }
        for owner in expiredOwners {
            backNavigationRetentions.removeValue(forKey: owner)
            backNavigationExpiryWork.removeValue(forKey: owner)?.cancel()
        }
        trimResidencyIfNeeded()
    }

    /// Enforce the bounded idle working set. Inventory rows are untouched; only exact full values
    /// that are clean, persisted, unowned, and non-operative can leave memory.
    func trimResidencyIfNeeded(evictAllEligible: Bool = false) {
        guard activeResidencyMode == .boundedAfterRecovery else { return }
        let evictionCountBefore = evictionCount
        let now = Date()
        var eligible = conversations.filter { canEvict($0, asOf: now) }.sorted {
            (lastAccessTicks[$0.id] ?? 0) < (lastAccessTicks[$1.id] ?? 0)
        }
        var eligibleBytes = eligible.reduce(0) { $0 + (sourceByteCounts[$1.id] ?? 0) }
        var announcedResidentChange = false
        while let victim = eligible.first,
              evictAllEligible
                || eligible.count > Self.maximumIdleResidentCount
                || eligibleBytes > Self.maximumIdleResidentBytes {
            if !announcedResidentChange {
                objectWillChange.send()
                announcedResidentChange = true
            }
            eligible.removeFirst()
            eligibleBytes -= sourceByteCounts[victim.id] ?? 0
            conversations.removeAll { $0.id == victim.id }
            residentRevisions[victim.id] = nil
            persistedRevisions[victim.id] = nil
            authorityCommittedBaselines[victim.id] = nil
            lastAccessTicks[victim.id] = nil
            evictionCount += 1
        }
        if evictionCount > evictionCountBefore {
            // Swift/Foundation allocators often retain the freed 10k-row graph until later memory
            // pressure. Ask malloc to return unused pages on a utility queue so the checkpoint's
            // physical-footprint win appears while the app is idle, not only after another large
            // allocation happens to force it.
            Self.memoryReclaimQueue.async {
                _ = malloc_zone_pressure_relief(nil, 0)
            }
        }
    }

    private func canEvict(_ conversation: Conversation, asOf now: Date) -> Bool {
        let id = conversation.id
        guard hydrationWaiters[id] == nil,
              temporaryResidencyClaims[id] == nil,
              !backNavigationRetentions.values.contains(where: {
                  $0.conversationID == id && $0.expiresAt > now
              }),
              !pendingLiveSummaryRefreshIDs.contains(id),
              failedSaves[id] == nil,
              !saveState.hasWork(id),
              residentRevisions[id] == persistedRevisions[id],
              !Self.hasIntrinsicResidencyReason(conversation),
              !AgentBridge.requiresResidentConversation(id)
        else { return false }
        return true
    }

    nonisolated private static func hasIntrinsicResidencyReason(_ conversation: Conversation) -> Bool {
        !conversation.queuedPrompts.isEmpty
            || conversation.pendingTurnPrompt != nil
            || conversation.armedTrigger != nil
            || conversation.providerAccessRequest != nil
            || conversation.awaitingQuestion
            || conversation.hasRunningDelegate
    }
    func isQueuePaused(_ id: UUID?) -> Bool {
        id.map(pausedQueueConversationIDs.contains) ?? false
    }

    /// Quarantine recovered work after a provider generation had to be forcibly retired.
    ///
    /// This is intentionally session-only, matching launch recovery: any nonempty queue is paused
    /// again when it is loaded after a relaunch. Call only after pending starts/guidance have been
    /// materialized, because ordinary updates remove a pause from an empty queue.
    @discardableResult
    func pauseQueue(_ id: UUID) -> Bool {
        guard conversation(id)?.queuedPrompts.isEmpty == false else { return false }
        pausedQueueConversationIDs.insert(id)
        return true
    }

    /// Whether the currently resident revision is known to have crossed the authority boundary.
    /// A Stop recovery lane may not be relaunched while any retired-session mutation is queued or
    /// failed; resident nil session ids alone are not proof that relaunch cannot resurrect them.
    func isDurablyCurrent(_ id: UUID) -> Bool {
        guard residentConversation(id) != nil else { return false }
        return (persistedRevisions[id] ?? 0) >= (residentRevisions[id] ?? 0)
            && failedSaves[id] == nil
            && !saveState.hasWork(id)
    }

    /// Release one recovered queue after an explicit user-visible action. Returns true only for a
    /// queue that was actually quarantined, so callers can avoid spuriously starting provider lanes.
    @discardableResult
    func resumeQueue(_ id: UUID) -> Bool {
        guard pausedQueueConversationIDs.remove(id) != nil else { return false }
        return true
    }

    /// The canonical sidebar order, shared by every sort site: favorites pinned on top, then the
    /// hand-ordered position (once dragged) or most-recent activity. A single Int sort key keeps this a
    /// strict weak ordering so Swift's sort can't hit an intransitive comparator.
    static func order(_ a: Conversation, _ b: Conversation) -> Bool {
        if a.favorite != b.favorite { return a.favorite }
        let ai = a.sortIndex ?? Int.max, bi = b.sortIndex ?? Int.max
        if ai != bi { return ai < bi }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        // Final total-order tiebreak: without it, two same-timestamp conversations tie and the
        // stable sort falls back to input order — which after relaunch is arbitrary APFS directory
        // enumeration, so the sidebar visibly reshuffled across launches. `id` is deterministic.
        return a.id.uuidString > b.id.uuidString
    }

    /// Apply one explicit favorite state without hydrating any already-matching evicted row. If a
    /// different sidebar mutation is already waiting on that row's hydration, this command merges
    /// into the same pending slot so the most recent requested fields win together.
    func setConversationsFavorite(_ ids: Set<UUID>, to favorite: Bool) {
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let summary = summary(id) else { continue }
            let pending = pendingSidebarMutations[id]
            guard pending != nil || summary.favorite != favorite else { continue }
            stageSidebarMutation(id, favorite: favorite)
        }
    }

    /// Read state follows the same explicit, latest-request-wins path as favorite state. Consulting
    /// only the summary here drops Mark Unread when an earlier Mark Read is still hydrating and the
    /// summary has not published that first mutation yet.
    func setConversationsUnread(_ ids: Set<UUID>, to unread: Bool) {
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let summary = summary(id) else { continue }
            let pending = pendingSidebarMutations[id]
            guard pending != nil || summary.unread != unread else { continue }
            stageSidebarMutation(id, unread: unread)
        }
    }

    private func stageSidebarMutation(
        _ id: UUID,
        sortIndex: Int? = nil,
        favorite: Bool? = nil,
        unread: Bool? = nil
    ) {
        guard sortIndex != nil || favorite != nil || unread != nil else { return }
        if let resident = residentConversation(id) {
            let changes = sortIndex.map { resident.sortIndex != $0 } == true
                || favorite.map { resident.favorite != $0 } == true
                || unread.map { resident.unread != $0 } == true
            guard changes else { return }
            updateAfterAcquiring(id) { conversation in
                if let sortIndex { conversation.sortIndex = sortIndex }
                if let favorite { conversation.favorite = favorite }
                if let unread { conversation.unread = unread }
            }
            return
        }

        let beginsHydration = pendingSidebarMutations[id] == nil
        var pending = pendingSidebarMutations[id] ?? PendingSidebarMutation()
        if let sortIndex { pending.sortIndex = sortIndex }
        if let favorite { pending.favorite = favorite }
        if let unread { pending.unread = unread }
        pendingSidebarMutations[id] = pending
        guard beginsHydration else { return }

        acquireConversation(id) { [weak self] result in
            guard let self else { return }
            guard case .success = result else {
                self.pendingSidebarMutations[id] = nil
                return
            }
            guard let desired = self.pendingSidebarMutations.removeValue(forKey: id),
                  let resident = self.residentConversation(id) else { return }
            let changes = desired.sortIndex.map { resident.sortIndex != $0 } == true
                || desired.favorite.map { resident.favorite != $0 } == true
                || desired.unread.map { resident.unread != $0 } == true
            guard changes else { return }
            self.update(id) { conversation in
                if let sortIndex = desired.sortIndex { conversation.sortIndex = sortIndex }
                if let favorite = desired.favorite { conversation.favorite = favorite }
                if let unread = desired.unread { conversation.unread = unread }
            }
        }
    }

    /// Persist one complete unfiltered sidebar order. The pinning and unpinning sets are explicit
    /// desired states, not toggles: favorite state and position are written through the same resident
    /// mutation, including when the record must first be hydrated off the main actor.
    func applySidebarOrder(
        _ orderedIDs: [UUID],
        orderChanged: Bool = true,
        pinning pinningIDs: Set<UUID> = [],
        unpinning unpinningIDs: Set<UUID> = []
    ) {
        precondition(
            pinningIDs.isDisjoint(with: unpinningIDs),
            "A sidebar reorder cannot pin and unpin the same conversation.")
        let favoriteStateDiffers = orderedIDs.contains { id in
            guard let summary = summary(id) else { return false }
            if pinningIDs.contains(id) { return !summary.favorite }
            if unpinningIDs.contains(id) { return summary.favorite }
            return false
        }
        // An apparent no-op may be a rapid reversal against a stale UI snapshot. In that case a
        // pending mutation (or the already-published opposite favorite state) proves that the full
        // visible order is meaningful. An ordinary no-op must not turn nil recency order into fixed
        // numeric indexes merely because AppKit accepted the drop.
        let hasRelevantPendingOrder = orderedIDs.contains {
            pendingSidebarMutations[$0]?.sortIndex != nil
        }
        let appliesOrder = orderChanged || hasRelevantPendingOrder || favoriteStateDiffers
        for (index, id) in orderedIDs.enumerated() {
            guard let summary = summary(id) else { continue }
            let shouldPin = pinningIDs.contains(id)
            let shouldUnpin = unpinningIDs.contains(id)
            let desiredFavorite = shouldPin ? true : (shouldUnpin ? false : nil)
            let favoriteChanges = desiredFavorite.map { $0 != summary.favorite } ?? false
            let orderChanges = appliesOrder && summary.sortIndex != index

            let pending = pendingSidebarMutations[id]
            guard pending != nil || orderChanges || favoriteChanges else { continue }
            stageSidebarMutation(
                id,
                sortIndex: appliesOrder ? index : nil,
                favorite: desiredFavorite)
        }
    }

    // One tolerant ISO-8601 coder pair for sidecars. Encoding carries fractional seconds so
    // sub-second-apart conversations keep their true recency order; decoding accepts both the
    // fractional form and the legacy plain form, so files written by any past/future build still
    // parse (a date the decoder can't read would throw and silently drop the whole conversation —
    // exactly the data-loss class this store must never hit).
    // Saves run on `saveQueue` and loads off the main actor, so these coders must be buildable and
    // usable from any thread — hence `nonisolated`, and a shared formatter that is genuinely safe
    // to use concurrently rather than a main-actor `static let` read from a background queue.
    nonisolated static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(SendableISO8601Formatter.fractional.string(from: date))
        }
        return e
    }
    nonisolated static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = SendableISO8601Formatter.fractional.date(from: s)
                ?? SendableISO8601Formatter.plain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Unparseable ISO-8601 date: \(s)"))
        }
        return d
    }

    // MARK: - Mutations (persist + republish to every window)

    nonisolated static func retainedCaptureOrdinalMaximum(
        in conversation: Conversation
    ) -> UInt64 {
        var maximum: UInt64 = 0
        for entry in conversation.messages {
            maximum = max(maximum, entry.captureOrdinal ?? 0)
            maximum = max(maximum, entry.toolResultCaptureOrdinal ?? 0)
            maximum = max(maximum, entry.toolTerminalCaptureOrdinal ?? 0)
            maximum = max(maximum, entry.interactionResponseCaptureOrdinal ?? 0)
            maximum = max(maximum, entry.interactionAcknowledgedCaptureOrdinal ?? 0)
            maximum = max(maximum, entry.interactionClosure?.captureOrdinal ?? 0)
            maximum = max(maximum, entry.supersessionCaptureOrdinal ?? 0)
        }
        for record in conversation.agentActivity {
            maximum = max(maximum, record.captureOrdinal ?? 0)
        }
        for subagent in conversation.subagents.values {
            maximum = max(maximum, subagent.startedCaptureOrdinal ?? 0)
            maximum = max(maximum, subagent.endedCaptureOrdinal ?? 0)
        }
        return maximum
    }

    /// Seed from every retained ordinal for an in-memory replacement whose durable invariants are
    /// not yet established. Never lower an in-process value: allocations which have not reached
    /// their save boundary are still authoritative chronology.
    private func seedCaptureOrdinalHighWater(from conversation: Conversation) {
        captureOrdinalSeedScanCount += 1
        let retainedMaximum = Self.retainedCaptureOrdinalMaximum(in: conversation)
        let seed = max(retainedMaximum, conversation.captureOrdinalHighWatermark ?? 0)
        installCaptureOrdinalHighWater(seed, for: conversation.id)
    }

    /// A record read from one of the durable stores carries a save-time high-watermark that already
    /// covers every retained field. Legacy records predate it and pay one full scan on installation.
    private func seedCaptureOrdinalHighWaterFromDurableRecord(_ conversation: Conversation) {
        if let durableHighWatermark = conversation.captureOrdinalHighWatermark {
            installCaptureOrdinalHighWater(durableHighWatermark, for: conversation.id)
        } else {
            seedCaptureOrdinalHighWater(from: conversation)
        }
    }

    private func installCaptureOrdinalHighWater(_ value: UInt64, for id: UUID) {
        captureOrdinalHighWater[id] = max(
            captureOrdinalHighWater[id] ?? 0,
            value)
        captureOrdinalSeededIDs.insert(id)
    }

    /// Exact transcript delta against the last committed runtime value. Reordering changes each
    /// affected row's capture sequence even when its payload is equal, so every id from the first
    /// order divergence onward is dirty. Removed ids are included so SQLite can tombstone them.
    nonisolated private static func changedTranscriptEntryIDs(
        from before: Conversation,
        to after: Conversation
    ) -> Set<UUID> {
        let beforeByID = Dictionary(uniqueKeysWithValues: before.messages.map { ($0.id, $0) })
        let afterByID = Dictionary(uniqueKeysWithValues: after.messages.map { ($0.id, $0) })
        var changed = Set(beforeByID.keys).symmetricDifference(afterByID.keys)
        for (id, entry) in afterByID where beforeByID[id] != entry {
            changed.insert(id)
        }
        let beforeOrder = before.messages.map(\.id)
        let afterOrder = after.messages.map(\.id)
        if beforeOrder != afterOrder {
            let sharedCount = min(beforeOrder.count, afterOrder.count)
            let firstDifference = (0..<sharedCount).first {
                beforeOrder[$0] != afterOrder[$0]
            } ?? sharedCount
            changed.formUnion(beforeOrder.dropFirst(firstDifference))
            changed.formUnion(afterOrder.dropFirst(firstDifference))
        }
        return changed
    }

    /// Allocate the next record-local capture ordinal on the MainActor. Installation seeds the
    /// retained recovery evidence once, making the provider-event path O(1). The lazy branch is a
    /// fail-safe for a legacy/test caller that made a resident visible without an install seam.
    func nextCaptureOrdinal(for id: UUID) -> UInt64 {
        if !captureOrdinalSeededIDs.contains(id) {
            if let resident = residentConversation(id) {
                seedCaptureOrdinalHighWaterFromDurableRecord(resident)
            } else if hasConversation(id), let hydrated = hydrateImmediately(id) {
                if !captureOrdinalSeededIDs.contains(id) {
                    seedCaptureOrdinalHighWaterFromDurableRecord(hydrated)
                }
            } else {
                // Do not mark an unknown id seeded. An asynchronous inventory may still publish a
                // durable record with this identity and must be allowed to advance the provisional
                // reservation above all retained evidence before another allocation is used.
                captureOrdinalHighWater[id] = captureOrdinalHighWater[id] ?? 0
            }
        }
        let current = captureOrdinalHighWater[id] ?? 0
        let next = current == UInt64.max ? UInt64.max : current + 1
        captureOrdinalHighWater[id] = next
        return next
    }

    /// Replace-or-append `c` by id, keep the list sorted, and persist. The single write path for
    /// create / rename / any field change.
    func upsert(_ c: Conversation) {
        cancelLiveSummaryRefresh(c.id)
        advanceHydrationEpoch(c.id)
        failedHydrationIDs.remove(c.id)
        refreshHydrationError()
        seedCaptureOrdinalHighWater(from: c)
        if let idx = conversations.firstIndex(where: { $0.id == c.id }) {
            conversations[idx] = c
        } else {
            conversations.append(c)
        }
        conversations.sort(by: Self.order)
        markAccess(c.id)
        refreshSummaryOrPublishResidentChange(for: c)
        if c.queuedPrompts.isEmpty, pausedQueueConversationIDs.contains(c.id) {
            pausedQueueConversationIDs.remove(c.id)
        }
        advanceRevision(c.id)
        save(c)
    }

    /// Create-only Legacy adoption for one validated immutable background envelope.
    ///
    /// General `upsert` is intentionally replace-capable and therefore unsafe at this boundary.
    /// This seam refuses an existing different UUID, compares an existing exact record for crash
    /// replay, and acknowledges a new record only after its canonical sidecar publication succeeds.
    func adoptBackgroundConversation(
        _ candidate: Conversation,
        authorityCapture: LibraryTransientOperationCaptureFactory.Capture? = nil,
        completion: @escaping (BackgroundConversationAdoptionResult) -> Void
    ) {
        var normalized = candidate
        _ = Self.healStaleState(&normalized)
        let retainedMaximum = Self.retainedCaptureOrdinalMaximum(in: normalized)
        if retainedMaximum > 0 {
            normalized.captureOrdinalHighWatermark = max(
                normalized.captureOrdinalHighWatermark ?? 0,
                retainedMaximum)
        }
        if selectedSQLiteAuthority {
            adoptBackgroundConversationToAuthority(
                normalized,
                capture: authorityCapture,
                completion: completion)
            return
        }
        guard normalized.hasDurableContent,
              let expected = try? Self.makeEncoder().encode(normalized) else {
            completion(.identityCollision)
            return
        }

        // Capture the authoritative Legacy source while still on the MainActor. A record already
        // represented by the closed inventory may live under a non-canonical Finder/restore name;
        // an inbox operation is never allowed to use a missing canonical path to replace it.
        let wasKnown = hasConversation(normalized.id)
        let knownSource = wasKnown ? sourceURL(for: normalized.id) : nil
        let destination = storeDir.appendingPathComponent("\(normalized.id.uuidString).json")
        let projectionStore = projections
        let saveQueue = saveQueue
        saveQueue.async { [weak self] in
            let publication: BackgroundConversationFilePublication
            do {
                if let knownSource {
                    publication = try Self.backgroundConversationBytes(
                        at: knownSource, equal: expected) ? .existingIdentical : .collision
                } else {
                    publication = try Self.publishBackgroundConversationCreateOnly(
                        expected, to: destination)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.persistenceFailed)
                }
                return
            }

            guard publication != .collision else {
                DispatchQueue.main.async { completion(.identityCollision) }
                return
            }

            let publishedURL = knownSource ?? destination
            let generation = try? ConversationSidecarGeneration.token(for: publishedURL)
            // A known record may have advanced provisionally in memory after these already-durable
            // bytes were captured. Exact replay acknowledges the file but must not regress search
            // or SQLite with the older envelope snapshot. Unknown/create-only publication is new
            // truth and follows the ordinary post-file projection ordering.
            if !wasKnown {
                SpotlightIndex.indexConversation(
                    id: normalized.id,
                    title: normalized.title,
                    cwd: normalized.cwd,
                    snippet: Self.spotlightSnippet(for: normalized))
                if let projectionStore {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.beginDirectProjectionWrite() }
                    }
                    projectionStore.index(
                        normalized,
                        sourceRevision: generation ?? ""
                    ) { [weak self] succeeded in
                        self?.finishDirectProjectionWrite(succeeded: succeeded)
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, !self.deletedIDs.contains(normalized.id) else {
                    completion(.identityCollision)
                    return
                }
                // The file crossed its create-only publication boundary before it enters the
                // resident/list state. Never route this through `upsert`: that path is deliberately
                // replace-capable and would reopen the check-then-write race this seam closes.
                if !self.hasConversation(normalized.id) {
                    self.advanceHydrationEpoch(normalized.id)
                    self.installResident(normalized, sourceBytes: expected.count)
                    if !normalized.queuedPrompts.isEmpty {
                        self.pausedQueueConversationIDs.insert(normalized.id)
                    }
                }
                if !wasKnown { self.sourceGenerationTokens[normalized.id] = generation }
                self.persistedRevisions[normalized.id] = max(
                    self.persistedRevisions[normalized.id] ?? 0,
                    self.residentRevisions[normalized.id] ?? 0)
                completion(publication == .created ? .published : .alreadyPublished)
            }
        }
    }

    /// The producer envelope and its applied receipt share the create-only entity transaction.
    /// A receipt replay may acknowledge an evolved Conversation without replacing it; a UUID
    /// collision never reaches the resident model. Frozen Legacy files are not consulted or written.
    private func adoptBackgroundConversationToAuthority(
        _ conversation: Conversation,
        capture: LibraryTransientOperationCaptureFactory.Capture?,
        completion: @escaping (BackgroundConversationAdoptionResult) -> Void
    ) {
        guard conversation.hasDurableContent,
              let capture,
              let authorityRepository else {
            completion(.persistenceFailed)
            return
        }
        saveQueue.async { [weak self] in
            let result: LibraryAuthorityAdoptionResult
            do {
                result = try authorityRepository.commit(
                    conversation: conversation,
                    adopting: capture)
            } catch {
                DispatchQueue.main.async { completion(.persistenceFailed) }
                return
            }

            switch result.disposition {
            case .identityCollision:
                DispatchQueue.main.async { completion(.identityCollision) }
                return
            case .created:
                SpotlightIndex.indexConversation(
                    id: conversation.id,
                    title: conversation.title,
                    cwd: conversation.cwd,
                    snippet: Self.spotlightSnippet(for: conversation))
            case .alreadyApplied:
                break
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    completion(.persistenceFailed)
                    return
                }
                if self.deletedIDs.contains(conversation.id) {
                    self.saveQueue.async {
                        _ = try? authorityRepository.deleteConversation(id: conversation.id)
                    }
                    completion(.identityCollision)
                    return
                }
                if result.disposition == .created,
                   !self.hasConversation(conversation.id) {
                    self.advanceHydrationEpoch(conversation.id)
                    self.installResident(
                        conversation,
                        sourceBytes: Self.estimatedResidentByteCount(conversation))
                    if !conversation.queuedPrompts.isEmpty {
                        self.pausedQueueConversationIDs.insert(conversation.id)
                    }
                    self.persistedRevisions[conversation.id] =
                        self.residentRevisions[conversation.id] ?? 0
                }
                completion(result.disposition == .created ? .published : .alreadyPublished)
            }
        }
    }

    /// Mutate one conversation in place (persisting the result), or no-op if it isn't present. Returns
    /// the mutated copy so callers can read back the result.
    @discardableResult
    func update(_ id: UUID, _ mutate: (inout Conversation) -> Void) -> Conversation? {
        if residentConversation(id) == nil { _ = hydrateImmediately(id) }
        return updateResident(id, mutate)
    }

    /// Change only the two title fields on an already-resident record. Title and provenance do not
    /// affect canonical order, summary content other than `title`, or retained chronology, so this
    /// narrow path deliberately avoids the generic mutation's transcript derivation and list sort.
    /// `ifCurrent` and the mutation execute in one MainActor turn, closing the delayed-generated-
    /// title race without asking arbitrary callers to assert that their mutation is metadata-only.
    @discardableResult
    func updateTitleResident(
        _ id: UUID,
        to title: String,
        source: ConversationTitleSource,
        ifCurrent shouldUpdate: (Conversation) -> Bool = { _ in true }
    ) -> Conversation? {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == id }),
              shouldUpdate(conversations[conversationIndex]) else { return nil }
        let prior = conversations[conversationIndex]
        if prior.title == title, prior.titleSource == source { return prior }

        // The title is the only provenance-bearing field present in ConversationSummary. A
        // same-text fallback→manual transition therefore leaves the @Published summary value
        // equal, but store observers still need the ordinary will-change edge for the resident
        // Conversation mutation.
        if prior.title == title, prior.titleSource != source {
            objectWillChange.send()
        }

        // Do not cancel a pending live-summary refresh. It may carry transcript/status changes
        // from an active turn; its later full derivation reads this new title and preserves both.
        advanceHydrationEpoch(id)
        conversations[conversationIndex].title = title
        conversations[conversationIndex].titleSource = source
        advanceRevision(id)
        let conversation = conversations[conversationIndex]

        if let summaryIndex = summaries.firstIndex(where: { $0.id == id }) {
            if summaries[summaryIndex].title != title {
                // Assign through the @Published collection's mutation coroutine so every window
                // sees the title, without reconstructing or reordering any sidebar row.
                summaries[summaryIndex].title = title
            }
        } else {
            // A resident without an inventory row is an invariant-recovery edge (for example a
            // pre-ready injected record), not the ordinary rename path. Preserve correctness even
            // though that malformed state cannot take the zero-derivation fast path.
            _ = refreshSummary(for: conversation)
        }

        savePreservingCaptureOrdinalChronology(conversation)
        return conversation
    }

    /// Hydrate an unloaded record off-main before applying the atomic title mutation. SQLite's
    /// closed launch summary remains authoritative during this title-only acquisition; if a normal
    /// waiter joins the read, its request for a conservative full summary refresh still wins.
    func updateTitleAfterAcquiring(
        _ id: UUID,
        to title: String,
        source: ConversationTitleSource,
        ifCurrent shouldUpdate: @escaping (Conversation) -> Bool = { _ in true },
        completion: ((Conversation?) -> Void)? = nil
    ) {
        if residentConversation(id) != nil {
            completion?(updateTitleResident(
                id,
                to: title,
                source: source,
                ifCurrent: shouldUpdate))
            return
        }
        acquireConversation(
            id,
            refreshesSummaryAfterHydration: authorityRepository == nil
                || !authoritativeInventoryLoaded
        ) { [weak self] result in
            guard let self, case .success = result else {
                completion?(nil)
                return
            }
            let updated = self.updateTitleResident(
                id,
                to: title,
                source: source,
                ifCurrent: shouldUpdate)
            completion?(updated)
            self.trimResidencyIfNeeded()
        }
    }

    /// Mutate one resident conversation and call `completion` only after an atomic sidecar
    /// publication containing at least this revision succeeds or terminally exhausts retries.
    /// This is the file-first acknowledgement seam for consequential provider interactions.
    @discardableResult
    func updateAwaitingPersistence(
        _ id: UUID,
        _ mutate: (inout Conversation) -> Void,
        completion: @escaping (Bool) -> Void
    ) -> Conversation? {
        if residentConversation(id) == nil { _ = hydrateImmediately(id) }
        cancelLiveSummaryRefresh(id)
        guard let index = conversations.firstIndex(where: { $0.id == id }) else {
            completion(false)
            return nil
        }
        advanceHydrationEpoch(id)
        mutate(&conversations[index])
        let revision = advanceRevision(id)
        conversations.sort(by: Self.order)
        let conversation = conversations.first { $0.id == id }
        if conversation?.queuedPrompts.isEmpty != false,
           pausedQueueConversationIDs.contains(id) {
            pausedQueueConversationIDs.remove(id)
        }
        guard let conversation else {
            completion(false)
            return nil
        }
        refreshSummaryOrPublishResidentChange(for: conversation)
        persistenceWaiters[id, default: []].append(ConversationPersistenceWaiter(
            revision: revision,
            completion: completion))
        save(conversation)
        return conversation
    }

    /// The suggestion value that UI and generation policy may observe. A normal consequential
    /// update installs its resident mutation before the authority write, so reading the raw
    /// Conversation during that interval would leak an uncommitted replacement across navigation
    /// and into every other window.
    func presentedSuggestedPrompt(for id: UUID?) -> ConversationSuggestedPrompt? {
        guard let id else { return nil }
        let resident = residentConversation(id)?.suggestedPrompt
        if let fence = suggestedPromptPublicationFences[id],
           resident == fence.replacement {
            return fence.expected
        }
        // A later clear or replacement changed the resident value after this fence was installed.
        // That newer intent is visible immediately; the stale completion may not hide it.
        return resident
    }

    /// Eligibility may suppress redundant local work while a provider-authored replacement is
    /// crossing authority, without exposing that provisional prompt's text to presentation or to
    /// the local replacement compare.
    func isPublishingSuggestedPrompt(for id: UUID, assistantEntryID: UUID) -> Bool {
        guard let fence = suggestedPromptPublicationFences[id],
              residentConversation(id)?.suggestedPrompt == fence.replacement else { return false }
        return fence.replacement?.assistantEntryID == assistantEntryID
    }

    /// A later user-owned transition can intentionally produce the same resident value as a
    /// provisional retirement (`nil`). Value comparison alone cannot distinguish that newer intent,
    /// so its owner explicitly retires the presentation fence before staging its durable mutation.
    /// The older authority waiter then resolves false by token absence and can never re-project or
    /// roll back over the newer state.
    func supersedeSuggestedPromptPublication(for id: UUID) {
        guard suggestedPromptPublicationFences[id] != nil else { return }
        objectWillChange.send()
        suggestedPromptPublicationFences[id] = nil
    }

    /// Persist a suggestion replacement while presenting the exact prior value process-wide until
    /// the authority write completes. Only one replacement may own a conversation fence at a time.
    /// A failed write restores the resident value without staging another write; Retry then saves
    /// that restored value and can never publish the rejected replacement.
    @discardableResult
    func updateAwaitingSuggestedPromptPublication(
        _ id: UUID,
        expected: ConversationSuggestedPrompt?,
        replacement: ConversationSuggestedPrompt?,
        mutation: (inout Conversation) -> Void,
        completion: @escaping (Bool) -> Void
    ) -> Conversation? {
        if residentConversation(id) == nil { _ = hydrateImmediately(id) }
        guard conversations.contains(where: { $0.id == id }),
              presentedSuggestedPrompt(for: id) == expected else {
            completion(false)
            return nil
        }

        let token = UUID()
        // Latest intent wins. The older waiter remains attached to its own store revision; when it
        // resolves, its token mismatch reports false exactly once without touching this fence.
        suggestedPromptPublicationFences[id] = SuggestedPromptPublicationFence(
            token: token,
            expected: expected,
            replacement: replacement)
        return updateAwaitingPersistence(
            id,
            { conversation in
                mutation(&conversation)
                conversation.suggestedPrompt = replacement
            },
            completion: { [weak self] persisted in
                guard let self else {
                    completion(false)
                    return
                }
                guard let fence = self.suggestedPromptPublicationFences[id],
                      fence.token == token else {
                    completion(false)
                    return
                }

                if !persisted {
                    // Roll back only the value this fence installed. A later genuine clear or
                    // superseding publication is newer intent and may never be overwritten by an
                    // older failed write.
                    if self.residentConversation(id)?.suggestedPrompt == fence.replacement {
                        _ = self.updateLive(id, publishResidentChange: true) {
                            $0.suggestedPrompt = fence.expected
                        }
                    }
                    self.suggestedPromptPublicationFences[id] = nil
                    completion(false)
                    return
                }

                let replacementIsCurrent = self.residentConversation(id)?.suggestedPrompt
                    == fence.replacement
                // Send before changing the presentation source, matching ObservableObject's
                // will-change contract. Subscribers render after the fence has been removed.
                self.objectWillChange.send()
                self.suggestedPromptPublicationFences[id] = nil
                completion(replacementIsCurrent)
            })
    }

    /// Return the exact immutable snapshot that satisfies the currently selected resident revision.
    /// A newer coalesced write may satisfy an older target, in which case its actual written snapshot
    /// is returned. A terminal write failure or deletion returns nil. Unlike reacquiring after a
    /// Boolean acknowledgement, this cannot accidentally hand export newer provisional live state.
    func awaitPublishedSnapshot(
        _ id: UUID,
        completion: @escaping (PublishedConversationSnapshot?) -> Void
    ) {
        guard let conversation = residentConversation(id) else {
            completion(nil)
            return
        }
        let revision = residentRevisions[id] ?? 0
        if (persistedRevisions[id] ?? 0) >= revision,
           failedSaves[id] == nil,
           !saveState.hasWork(id) {
            completion(PublishedConversationSnapshot(
                conversation: conversation,
                revision: revision,
                storeID: storeID,
                hydrationEpoch: hydrationEpochs[id] ?? 0))
            return
        }
        publishedSnapshotWaiters[id, default: []].append(
            ConversationPublishedSnapshotWaiter(
                revision: revision,
                completion: completion))
        // The current revision may be live-only (for example a streaming delta that arrived while
        // an older write was completing). Stage the captured value even when another drain exists;
        // `ConversationSaveState` coalesces a pending value and otherwise queues the one follow-up
        // publication needed to guarantee this waiter cannot become stranded.
        save(conversation)
    }

    /// Prepare one synchronous compound SQLite append while the exact snapshot it examined is
    /// still resident and published, with no older save queued or in flight. The returned token
    /// reserves no state: its ordinal is the next value after the process-local high-watermark, and
    /// the caller must remain on the MainActor without yielding through commit and adoption.
    func prepareAuthoritativeAppend(
        against snapshot: PublishedConversationSnapshot
    ) -> AuthoritativeConversationAppendCAS? {
        let id = snapshot.conversation.id
        guard snapshot.storeID == storeID,
              selectedSQLiteAuthority,
              !deletedIDs.contains(id),
              hydrationJobs[id] == nil,
              hydrationEpochs[id] ?? 0 == snapshot.hydrationEpoch,
              residentConversation(id) != nil,
              residentRevisions[id] == snapshot.revision,
              persistedRevisions[id] == snapshot.revision,
              failedSaves[id] == nil,
              !saveState.hasWork(id),
              authorityCommittedBaselines[id] != nil,
              sourceByteCounts[id] != nil else { return nil }
        let highWatermark = captureOrdinalHighWater[id] ?? 0
        guard highWatermark < UInt64.max else { return nil }
        return AuthoritativeConversationAppendCAS(
            storeID: storeID,
            conversationID: id,
            revision: snapshot.revision,
            hydrationEpoch: snapshot.hydrationEpoch,
            priorMessageCount: snapshot.conversation.messages.count,
            captureOrdinal: highWatermark + 1)
    }

    /// Compatibility/readability seam for tests and diagnostics that only need the fence result.
    func isExactlyPublished(_ snapshot: PublishedConversationSnapshot) -> Bool {
        prepareAuthoritativeAppend(against: snapshot) != nil
    }

    /// Reconcile one exact append that a narrow repository transaction has already committed. A
    /// replay may return an already-durable row while this process still has the pre-transaction
    /// resident value, so adoption is based on exact resident shape rather than claim creation.
    /// This advances resident *and committed* baselines together and deliberately schedules no save.
    /// Only trusted repository results may use this seam; all checks and accounting remain O(1).
    @discardableResult
    func adoptAlreadyAuthoritativeAppend(
        _ authoritative: Conversation,
        entry: TranscriptEntry,
        using token: AuthoritativeConversationAppendCAS
    ) -> AuthoritativeConversationAppendAdoption {
        let id = token.conversationID
        guard token.storeID == storeID,
              selectedSQLiteAuthority,
              !deletedIDs.contains(id),
              hydrationJobs[id] == nil,
              hydrationEpochs[id] ?? 0 == token.hydrationEpoch,
              residentRevisions[id] == token.revision,
              persistedRevisions[id] == token.revision,
              failedSaves[id] == nil,
              !saveState.hasWork(id),
              authorityCommittedBaselines[id] != nil,
              authoritative.id == id,
              authoritative.messages.last == entry,
              let index = conversations.firstIndex(where: { $0.id == id }),
              let priorBytes = sourceByteCounts[id] else { return .refused }

        let resident = conversations[index]
        if let residentEntry = resident.messages.first(where: { $0.id == entry.id }),
           residentEntry == entry,
           resident.messages.count == authoritative.messages.count,
           authoritative.messages.count == token.priorMessageCount {
            return .alreadyPresent
        }
        // The repository result is reconstructed and re-proved from SQLite before COMMIT returns.
        // With the token still valid, authority is therefore the safe repair even if a future
        // direct writer made the resident shape differ by more than the expected single append.
        let isPlainAppend = resident.messages.count == token.priorMessageCount
            && authoritative.messages.count == token.priorMessageCount + 1
            && !resident.messages.contains(where: { $0.id == entry.id })

        cancelLiveSummaryRefresh(id)
        advanceHydrationEpoch(id)
        conversations[index] = authoritative
        let revision = advanceRevision(id)
        persistedRevisions[id] = revision
        authorityCommittedBaselines[id] = authoritative
        let entryBytes = Self.estimatedResidentByteCount(entry)
        let (updatedBytes, byteOverflow) = priorBytes.addingReportingOverflow(entryBytes)
        sourceByteCounts[id] = isPlainAppend && !byteOverflow ? updatedBytes : Int.max
        let highWatermark = max(
            captureOrdinalHighWater[id] ?? 0,
            max(authoritative.captureOrdinalHighWatermark ?? 0, entry.captureOrdinal ?? 0))
        installCaptureOrdinalHighWater(highWatermark, for: id)
        conversations.sort(by: Self.order)
        markAccess(id)
        refreshSummaryOrPublishResidentChange(for: authoritative)
        trimResidencyIfNeeded()
        return .appended
    }

    /// Persist a mutation only when its complete record is already resident. Scoped multi-record
    /// coordinators use this strict form so a missed acquisition cannot silently reintroduce a
    /// main-actor decode halfway through an otherwise atomic operation.
    @discardableResult
    func updateResident(_ id: UUID, _ mutate: (inout Conversation) -> Void) -> Conversation? {
        cancelLiveSummaryRefresh(id)
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return nil }
        advanceHydrationEpoch(id)
        mutate(&conversations[idx])
        advanceRevision(id)
        conversations.sort(by: Self.order)
        // firstIndex again — the sort may have moved it.
        let c = conversations.first { $0.id == id }
        if c?.queuedPrompts.isEmpty != false, pausedQueueConversationIDs.contains(id) {
            pausedQueueConversationIDs.remove(id)
        }
        if let c {
            refreshSummaryOrPublishResidentChange(for: c)
            save(c)
        }
        return c
    }

    /// Mutate without per-mutation persistence or re-sorting — the hot streaming-accumulation path
    /// (a BACKGROUND turn's per-chunk deltas / tool results). The optional resident-change signal is
    /// reserved for runtime-only facts with a standing full-record UI, not provider stream deltas.
    /// `searchableTextChanged` requests only the sidebar search fallback's coalesced content pulse
    /// when the ordinary summary remains equal. agentd emits a delta per streamed chunk, so routing
    /// those through `update` would re-encode and re-write the whole conversation JSON on every
    /// chunk. The first live mutation instead arms one fixed checkpoint interval; its deadline
    /// bounds snapshot staging, while the serial authority lane may commit later. Terminal events
    /// still call `update` and immediately supersede any partial snapshot. Only safe for
    /// fields that don't affect sort order (messages / tool results / sdkSessionId / workflowRuns /
    /// subagents) — anything touching favorite/sortIndex/updatedAt must use `update`. Sidebar
    /// presentation follows through a bounded coalescer rather than rescanning the transcript for
    /// every streamed token; the terminal `update` publishes the exact final state immediately.
    @discardableResult
    func updateLive(
        _ id: UUID,
        publishResidentChange: Bool = false,
        searchableTextChanged: Bool = false,
        persistence: ConversationLivePersistencePolicy = .checkpointed,
        _ mutate: (inout Conversation) -> Void
    ) -> Conversation? {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return nil }
        advanceHydrationEpoch(id)
        if publishResidentChange { objectWillChange.send() }
        mutate(&conversations[idx])
        advanceRevision(id)
        markAccess(id)
        let conversation = conversations[idx]
        if searchableTextChanged { pendingLiveContentRefreshIDs.insert(id) }
        scheduleLiveSummaryRefresh(id)
        if persistence == .checkpointed { scheduleLiveCheckpoint(id) }
        return conversation
    }

    /// The bridge uses the same snapshot-staging interval for its presentation-owned foreground
    /// buffer, so foreground and background turns have one recovery contract even though their hot
    /// state lives in two different places. This is not a hard bound on completion of queued I/O.
    var transcriptCheckpointMaximumLatency: TimeInterval { liveCheckpointMaximumLatency }

    private func scheduleLiveCheckpoint(_ id: UUID) {
        liveCheckpointDirtyIDs.insert(id)
        guard liveCheckpointWork == nil else { return }
        liveCheckpointGeneration &+= 1
        let generation = liveCheckpointGeneration
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.liveCheckpointGeneration == generation else { return }
                self.liveCheckpointWork = nil
                self.checkpointLiveMutationsNow()
            }
        }
        liveCheckpointWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + liveCheckpointMaximumLatency,
            execute: work)
    }

    /// A semantic save already contains the newest resident value, so its conversation no longer
    /// needs the pending live-only checkpoint. Cancel the shared timer only when no other live
    /// conversation is waiting for that same fixed boundary.
    private func retireLiveCheckpoint(_ id: UUID) {
        liveCheckpointDirtyIDs.remove(id)
        guard liveCheckpointDirtyIDs.isEmpty else { return }
        liveCheckpointGeneration &+= 1
        liveCheckpointWork?.cancel()
        liveCheckpointWork = nil
    }

    /// Stage every resident value dirtied by `updateLive` without blocking the MainActor on encode
    /// or SQLite. Clearing the dirty set before staging is the generation boundary: a mutation that
    /// arrives after this point creates a new deadline and cannot be mistaken for part of the
    /// in-flight snapshot.
    func checkpointLiveMutationsNow() {
        liveCheckpointGeneration &+= 1
        liveCheckpointWork?.cancel()
        liveCheckpointWork = nil
        let ids = liveCheckpointDirtyIDs
        liveCheckpointDirtyIDs.removeAll()
        for id in ids {
            guard let conversation = conversations.first(where: { $0.id == id }) else { continue }
            savePreservingCaptureOrdinalChronology(conversation)
        }
    }

    /// Process termination is a stronger boundary than the periodic timer. Callers first fold each
    /// foreground bridge, then invoke this once so every background turn's resident live state is
    /// staged before `flushSaves()` drains the serial authority lane.
    func prepareForTermination() {
        checkpointLiveMutationsNow()
    }

    /// Remove a conversation and its file.
    ///
    /// Returns everything undo needs to put it back, or nil when there was nothing to remove or the
    /// caller asked for a permanent delete.
    ///
    /// `permanently` exists for test cleanup. Several suites call this against the developer's real
    /// store to tidy up after themselves, because `AgentBridge` has no store injection; without the
    /// escape hatch they would stop deleting and start depositing fixtures in the real trash.
    @discardableResult
    func remove(_ id: UUID, permanently: Bool = false) -> ConversationDeleteReceipt? {
        cancelLiveSummaryRefresh(id)
        if hasConversation(id), residentConversation(id) == nil, hydrateImmediately(id) == nil {
            // Undo needs the exact record. A missing/corrupt unloaded file remains visible and is
            // never converted into a permanent delete merely because its bytes could not load.
            return nil
        }
        let removed = conversations.first { $0.id == id }
        let willOfferUndo = !permanently && trashesDeletes
        var deletedWorkEvidence: [ConversationWorkEvidence] = []
        if selectedSQLiteAuthority {
            guard let deleteResult = commitAuthorityDelete(
                id,
                preservesWorkEvidenceForUndo: willOfferUndo) else { return nil }
            deletedWorkEvidence = deleteResult.workEvidence
            discardFailedConversationWorkEvidenceWrites(conversationID: id)
        }
        let abandonedWaiters = hydrationWaiters.removeValue(forKey: id) ?? []
        cancelHydrationJob(id)
        let abandonedPersistenceWaiters = persistenceWaiters.removeValue(forKey: id) ?? []
        let abandonedPublishedSnapshotWaiters =
            publishedSnapshotWaiters.removeValue(forKey: id) ?? []
        let wasQueuePaused = pausedQueueConversationIDs.contains(id)
        conversations.removeAll { $0.id == id }
        summaries.removeAll { $0.id == id }
        artifactIDsByConversation[id] = nil
        modelAccessByConversation[id] = nil
        if wasQueuePaused { pausedQueueConversationIDs.remove(id) }
        deletedIDs.insert(id)
        residentRevisions[id] = nil
        persistedRevisions[id] = nil
        authorityCommittedBaselines[id] = nil
        captureOrdinalHighWater[id] = nil
        captureOrdinalSeededIDs.remove(id)
        lastAccessTicks[id] = nil
        sourceByteCounts[id] = nil
        sourceGenerationTokens[id] = nil
        advanceHydrationEpoch(id)
        for waiter in abandonedWaiters { waiter.completion(.failure(.deleted)) }
        for waiter in abandonedPersistenceWaiters { waiter.completion(false) }
        for waiter in abandonedPublishedSnapshotWaiters { waiter.completion(nil) }
        failedHydrationIDs.remove(id)
        refreshHydrationError()

        guard !permanently, trashesDeletes, let removed else {
            deleteFile(id, into: nil)
            return nil
        }
        guard let slot = try? trash.makeSlot(for: id) else {
            // No slot means no undo, but the delete itself must still happen.
            deleteFile(id, into: nil)
            return nil
        }
        deleteFile(id, into: slot)
        return ConversationDeleteReceipt(
            conversation: removed,
            slot: slot,
            wasQueuePaused: wasQueuePaused,
            workEvidence: deletedWorkEvidence)
    }

    /// Put a deleted conversation back, media included.
    ///
    /// Re-pauses the prompt queue whenever there is anything queued. Undo reverses what Mechanician
    /// stored; it must never start an agent turn. `remove` clears `pausedQueueConversationIDs` and
    /// `upsert` only ever removes from that set, so without this a restored conversation with queued
    /// prompts would come back **unpaused** and selecting it would send to the provider.
    @discardableResult
    func restore(_ receipt: ConversationDeleteReceipt) -> Bool {
        let id = receipt.conversation.id
        let mediaDestination = mediaStorage.root.appendingPathComponent(
            id.uuidString, isDirectory: true)
        let trash = self.trash
        let slot = receipt.slot
        saveQueue.sync {
            try? trash.give(id.uuidString, from: slot, to: mediaDestination)
        }
        if FileManager.default.fileExists(atPath: mediaDestination.path) {
            noteConversationMediaSourcesChanged(id)
        }
        deletedIDs.remove(id)
        upsert(receipt.conversation)
        for work in receipt.workEvidence {
            recordConversationWorkEvidence(
                repository: work.repository,
                files: work.files)
        }
        if receipt.wasQueuePaused || !receipt.conversation.queuedPrompts.isEmpty {
            pausedQueueConversationIDs.insert(id)
        }
        trash.discard(slot)
        return true
    }

    // MARK: - Persistence

    private var appSupportBase: URL {
        // Dev isolation: dev.sh sets MECHANICIAN_SUPPORT_DIR to a separate folder so the dev build
        // never shares the stable app's conversation store (both carry bundle id ai.mechanician.app).
        let base = appSupportBaseOverride ?? MechanicianEnvironment.currentSupportRoot()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private var storeDir: URL {
        let dir = appSupportBase.appendingPathComponent("conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Deleted conversations wait here so undo can put them back. Derived from `appSupportBase`
    /// like every other directory, never hardcoded, or a dev build would trash into the real store.
    private var trash: ConversationTrash {
        let root = appSupportBase.appendingPathComponent("trash", isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ConversationTrash(root: root)
    }

    /// Undo is a within-session affordance, so trashed conversations do not need to live forever.
    /// Called once at load; a week is long enough that no plausible undo is lost to it.
    private static let trashRetention: TimeInterval = 7 * 24 * 60 * 60

    /// Whether a delete on this store goes to the trash rather than straight out.
    ///
    /// Tests reach the SHARED store through `AgentBridge`, which has no store injection, so a
    /// delete inside a test moves fixtures into the developer's real Application Support — 26 of
    /// them landed there before this existed, and converting the direct
    /// `ConversationStore.shared.remove` cleanup sites did not catch it, because the leak came
    /// through the bridge.
    ///
    /// An isolated store always trashes, so the undo tests are unaffected. The shared store only
    /// trashes outside XCTest.
    private var trashesDeletes: Bool {
        if appSupportBaseOverride != nil { return true }
        return NSClassFromString("XCTestCase") == nil
    }

    private var mediaStorage: ConversationMediaStorage {
        ConversationMediaStorage(root: appSupportBase
            .appendingPathComponent("conversation-media", isDirectory: true))
    }

    private func noteConversationMediaSourcesChanged(_ conversationID: UUID) {
        authorityRepository?.conversationMediaSourcesChanged(conversationID: conversationID)
    }

    // Conversation writes run off the main thread on a SERIAL queue, so a large encode + write doesn't
    // hitch the UI at turn-end, and saves/deletes for a conversation stay ordered. Conversation is a
    // value type, so the snapshot handed to the queue is a safe copy. `flushSaves()` (on app
    // termination) barrier-waits so no in-flight write is lost on quit.
    private let saveQueue = DispatchQueue(label: "ai.mechanician.conversation-io", qos: .utility)

    /// Persist a tool-produced transcript image on the same serial queue as its conversation. The
    /// provider may release temporary image output as soon as its terminal item arrives, so callers
    /// copy normalized bytes here before attaching the lightweight durable reference to the row.
    func persistToolImage(
        _ data: Data,
        conversationID: UUID,
        entryID: UUID,
        width: Int?,
        height: Int?
    ) async -> ToolImageReference? {
        let storage = mediaStorage
        let authorityRepository = authorityRepository
        return await withCheckedContinuation { continuation in
            saveQueue.async {
                let reference = try? storage.persistScreenshot(
                    data,
                    conversationID: conversationID,
                    entryID: entryID,
                    width: width,
                    height: height)
                if reference != nil {
                    authorityRepository?.conversationMediaSourcesChanged(
                        conversationID: conversationID)
                }
                continuation.resume(returning: reference)
            }
        }
    }

    func toolImageURL(
        conversationID: UUID,
        reference: ToolImageReference
    ) -> URL? {
        mediaStorage.imageURL(conversationID: conversationID, reference: reference)
    }

    /// Persist a user-pasted composer image beside the conversation immediately. Paste handling
    /// already has to encode the clipboard bitmap before inserting its NSTextAttachment; writing
    /// those same bytes here gives the marker a durable path that survives navigation/relaunch and
    /// is removed with the conversation. Provider prompts continue to receive an ordinary path.
    func persistComposerImage(
        _ data: Data,
        conversationID: UUID,
        width: Int?,
        height: Int?
    ) -> URL? {
        let entryID = UUID()
        guard let reference = try? mediaStorage.persistScreenshot(
            data,
            conversationID: conversationID,
            entryID: entryID,
            width: width,
            height: height)
        else { return nil }
        noteConversationMediaSourcesChanged(conversationID)
        return mediaStorage.imageURL(conversationID: conversationID, reference: reference)
    }

    func persistComposerImageFile(
        at sourceURL: URL,
        conversationID: UUID,
        maximumBytes: Int = ConversationMediaStorage.maximumComposerFileBytes
    ) -> URL? {
        guard let url = try? mediaStorage.persistComposerImageFile(
            at: sourceURL,
            conversationID: conversationID,
            maximumBytes: maximumBytes) else { return nil }
        noteConversationMediaSourcesChanged(conversationID)
        return url
    }

    /// Generic files use a copy-on-attach policy: the durable draft token points at this
    /// conversation-owned copy, never at a Finder location that may move, be unmounted, or disappear
    /// before a queued prompt is delivered.
    func persistComposerFile(
        at sourceURL: URL,
        conversationID: UUID,
        maximumBytes: Int = ConversationMediaStorage.maximumComposerFileBytes
    ) -> ConversationFileReference? {
        let mailMetadata = RFC822MessageParser.metadata(at: sourceURL)
        guard let reference = try? mediaStorage.persistComposerFile(
            at: sourceURL,
            conversationID: conversationID,
            displayName: mailMetadata?.safeDisplayName(
                fallback: sourceURL.lastPathComponent),
            typeIdentifier: mailMetadata == nil ? nil : UTType.emailMessage.identifier,
            maximumBytes: maximumBytes) else { return nil }
        noteConversationMediaSourcesChanged(conversationID)
        return reference
    }

    func composerFileURL(
        conversationID: UUID,
        reference: ConversationFileReference
    ) -> URL? {
        mediaStorage.availableComposerFileURL(
            conversationID: conversationID,
            reference: reference)
    }

    /// Expand only validated references to existing files inside this conversation's media
    /// directory. Malformed, cross-conversation, missing, or symlinked references remain inert text.
    func providerPrompt(
        from prompt: String,
        conversationID: UUID
    ) -> String {
        let matches = ConversationFileReference.matches(in: prompt)
        guard !matches.isEmpty else { return prompt }
        let expanded = NSMutableString(string: prompt)
        for match in matches.reversed() {
            guard let url = mediaStorage.availableComposerFileURL(
                conversationID: conversationID,
                reference: match.reference) else { continue }
            expanded.replaceCharacters(
                in: match.range,
                with: match.reference.providerContext(
                    fileURL: url,
                    mailContext: RFC822MessageParser.readableContext(at: url)))
        }
        return expanded as String
    }

    /// Rewrite app-owned pasted images and generic-file tokens while moving a draft between
    /// conversations. Build the result once from detector ranges so paths containing spaces remain
    /// exact and a prompt with many repeated references stays linear.
    func cloneComposerMediaPaths(
        in prompt: String,
        from sourceConversationID: UUID,
        to destinationConversationID: UUID
    ) -> String {
        cloneComposerMediaPaths(
            in: [prompt],
            from: sourceConversationID,
            to: destinationConversationID).first ?? prompt
    }

    /// Re-home an entire logical operation—such as every retained turn in a conversation fork—
    /// under one deduplication map and one 4-file/16-MiB budget. Calling the single-prompt helper
    /// once per historical entry resets both safeguards and can copy the same bytes hundreds of
    /// times on the main actor.
    func cloneComposerMediaPaths(
        in prompts: [String],
        from sourceConversationID: UUID,
        to destinationConversationID: UUID
    ) -> [String] {
        var batch = ComposerMediaCloneBatch()
        return prompts.map {
            cloneComposerMediaPaths(
                in: $0,
                from: sourceConversationID,
                to: destinationConversationID,
                batch: &batch)
        }
    }

    /// Clone a fork's current prompt before its replayed transcript. A fork re-sends the current
    /// prompt after restoring history, so its user-authored attachments are the operation's primary
    /// payload and must not be displaced by four older unique files exhausting the shared budget.
    /// Re-home every tool-captured screenshot a fork inherits.
    ///
    /// `cloneForkComposerMediaPaths` only rewrites media named inside prompt *text*. A `.tool` row
    /// carries its screenshot in the structured `toolImage` field instead, and that reference
    /// resolves against whichever Conversation is asking — so a fork kept a reference pointing into
    /// its own empty directory and the card read "Preview unavailable" permanently. The bytes are
    /// copied under the same name, which makes the inherited reference resolve untouched.
    func cloneForkToolImages(
        in entries: [TranscriptEntry],
        from sourceConversationID: UUID,
        to destinationConversationID: UUID
    ) {
        var cloned = false
        for entry in entries {
            guard let reference = entry.toolImage else { continue }
            cloned = mediaStorage.cloneToolImage(
                reference,
                from: sourceConversationID,
                to: destinationConversationID) || cloned
        }
        if cloned { noteConversationMediaSourcesChanged(destinationConversationID) }
    }

    func cloneForkComposerMediaPaths(
        currentPrompt: String,
        replayedHistoryPrompts: [String],
        from sourceConversationID: UUID,
        to destinationConversationID: UUID
    ) -> (currentPrompt: String, replayedHistoryPrompts: [String]) {
        let cloned = cloneComposerMediaPaths(
            in: [currentPrompt] + replayedHistoryPrompts,
            from: sourceConversationID,
            to: destinationConversationID)
        return (
            currentPrompt: cloned.first ?? currentPrompt,
            replayedHistoryPrompts: Array(cloned.dropFirst()))
    }

    /// Clone one known image attachment under a caller-owned batch budget. Clipboard intake uses
    /// this narrower API so image and generic-file copies share one authored-order count/byte cap
    /// instead of independently resetting the recovery helper's limits.
    func cloneComposerImagePath(
        _ path: String,
        from sourceConversationID: UUID,
        to destinationConversationID: UUID,
        maximumBytes: Int
    ) -> (path: String, byteCount: Int)? {
        guard contains(sourceConversationID),
              contains(destinationConversationID),
              let clone = try? mediaStorage.cloneComposerImage(
                at: path,
                from: sourceConversationID,
                to: destinationConversationID,
                maximumBytes: maximumBytes) else { return nil }
        noteConversationMediaSourcesChanged(destinationConversationID)
        return (clone.url.path, clone.byteCount)
    }

    /// Clone one known generic-file token under the same caller-owned batch budget as images.
    func cloneComposerFileReference(
        _ reference: ConversationFileReference,
        from sourceConversationID: UUID,
        to destinationConversationID: UUID,
        maximumBytes: Int
    ) -> ConversationFileReference? {
        guard contains(sourceConversationID),
              contains(destinationConversationID) else { return nil }
        guard let clone = try? mediaStorage.cloneComposerFile(
            reference,
            from: sourceConversationID,
            to: destinationConversationID,
            maximumBytes: maximumBytes) else { return nil }
        noteConversationMediaSourcesChanged(destinationConversationID)
        return clone
    }

    func hasAvailableComposerImagePath(
        _ path: String,
        conversationID: UUID
    ) -> Bool {
        guard contains(conversationID) else { return false }
        do {
            return try mediaStorage.composerImageFileSize(
                at: path,
                conversationID: conversationID) != nil
        } catch {
            return false
        }
    }

    private struct ComposerMediaCloneBatch {
        var budget = ConversationAttachmentImportBudget()
        var imageReplacements: [String: String] = [:]
        var fileReplacements: [ConversationFileReference: String] = [:]
    }

    private enum ComposerMediaCloneCandidate {
        case image(canonicalPath: String)
        case file(ConversationFileReference)
    }

    private struct PositionedComposerMediaCloneCandidate {
        let range: NSRange
        let candidate: ComposerMediaCloneCandidate
    }

    /// Clone image paths and generic-file tokens in their authored order. The four-file/16-MiB
    /// budget is shared across both attachment kinds and across every prompt in the operation.
    /// Scanning all images before all files silently changed which attachments survived the cap.
    private func cloneComposerMediaPaths(
        in prompt: String,
        from sourceConversationID: UUID,
        to destinationConversationID: UUID,
        batch: inout ComposerMediaCloneBatch
    ) -> String {
        let storage = mediaStorage
        let imageUnavailable = "[Pasted image unavailable. Attach it again]"
        let fileUnavailable = "[Attached file unavailable. Attach it again]"
        var positioned = ImagePathDetector.matches(in: prompt).compactMap {
            match -> PositionedComposerMediaCloneCandidate? in
            let canonical = URL(fileURLWithPath: match.path).standardizedFileURL.path
            guard storage.ownsComposerImagePath(
                canonical,
                conversationID: sourceConversationID) else { return nil }
            return PositionedComposerMediaCloneCandidate(
                range: match.range,
                candidate: .image(canonicalPath: canonical))
        }
        positioned.append(contentsOf: ConversationFileReference.matches(in: prompt).map {
            PositionedComposerMediaCloneCandidate(
                range: $0.range,
                candidate: .file($0.reference))
        })
        guard !positioned.isEmpty else { return prompt }
        positioned.sort {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            return $0.range.length > $1.range.length
        }
        var ordered: [PositionedComposerMediaCloneCandidate] = []
        ordered.reserveCapacity(positioned.count)
        var occupiedThrough = 0
        var persistedMedia = false
        for item in positioned where item.range.location >= occupiedThrough {
            ordered.append(item)
            occupiedThrough = NSMaxRange(item.range)
        }

        for item in ordered {
            switch item.candidate {
            case .image(let path):
                guard batch.imageReplacements[path] == nil else { continue }
                // Canonical paths are the identity: lexical variants of one owned file consume one
                // slot and share one destination clone.
                guard let maximumBytes = batch.budget.beginAttachment() else {
                    batch.imageReplacements[path] = imageUnavailable
                    continue
                }
                guard let clone = try? storage.cloneComposerImage(
                    at: path,
                    from: sourceConversationID,
                    to: destinationConversationID,
                    maximumBytes: maximumBytes) else {
                    batch.imageReplacements[path] = imageUnavailable
                    continue
                }
                batch.imageReplacements[path] = clone.url.path
                batch.budget.recordCommittedBytes(clone.byteCount)
                persistedMedia = true
            case .file(let reference):
                guard batch.fileReplacements[reference] == nil else { continue }
                guard let maximumBytes = batch.budget.beginAttachment() else {
                    batch.fileReplacements[reference] = fileUnavailable
                    continue
                }
                guard let clone = try? storage.cloneComposerFile(
                    reference,
                    from: sourceConversationID,
                    to: destinationConversationID,
                    maximumBytes: maximumBytes) else {
                    batch.fileReplacements[reference] = fileUnavailable
                    continue
                }
                batch.fileReplacements[reference] = clone.promptToken
                batch.budget.recordCommittedBytes(clone.byteCount)
                persistedMedia = true
            }
        }

        // Rebuild once from ordered non-overlapping ranges. Repeated replacements on an
        // NSMutableString shift its tail each time and can become quadratic for a huge prompt.
        var pieces: [String] = []
        pieces.reserveCapacity(ordered.count * 2 + 1)
        let original = prompt as NSString
        var cursor = 0
        for item in ordered {
            if item.range.location > cursor {
                pieces.append(original.substring(
                    with: NSRange(
                        location: cursor,
                        length: item.range.location - cursor)))
            }
            switch item.candidate {
            case .image(let path):
                pieces.append(batch.imageReplacements[path] ?? imageUnavailable)
            case .file(let reference):
                pieces.append(batch.fileReplacements[reference] ?? fileUnavailable)
            }
            cursor = NSMaxRange(item.range)
        }
        if cursor < original.length {
            pieces.append(original.substring(
                with: NSRange(location: cursor, length: original.length - cursor)))
        }
        if persistedMedia {
            noteConversationMediaSourcesChanged(destinationConversationID)
        }
        return pieces.joined()
    }

    /// A title-only mutation cannot introduce, remove, or reorder capture evidence. Every resident
    /// record is seeded at installation, so the process-local high-water is already an upper bound
    /// over retained chronology and any ordinals allocated since the last publication.
    private func savePreservingCaptureOrdinalChronology(_ conversation: Conversation) {
        guard captureOrdinalSeededIDs.contains(conversation.id) else {
            // Fail safe for an unexpected test/integration caller that bypassed every install seam.
            save(conversation)
            return
        }
        let knownHighWatermark = max(
            conversation.captureOrdinalHighWatermark ?? 0,
            captureOrdinalHighWater[conversation.id] ?? 0)
        save(
            conversation,
            retainedCaptureOrdinalUpperBound: knownHighWatermark)
    }

    private func save(_ c: Conversation) {
        save(c, retainedCaptureOrdinalUpperBound: nil)
    }

    private func save(
        _ c: Conversation,
        retainedCaptureOrdinalUpperBound knownRetainedMaximum: UInt64?
    ) {
        retireLiveCheckpoint(c.id)
        // Coalescing: staging over an undrained snapshot replaces it and returns false, so a burst
        // of mutations to one conversation (session events, flag flips, heal passes) costs one
        // encode + one disk write of the final state instead of one per mutation.
        var durableConversation = c
        let retainedMaximum: UInt64
        if let knownRetainedMaximum {
            retainedMaximum = knownRetainedMaximum
        } else {
            saveCaptureOrdinalScanCount += 1
            retainedMaximum = Self.retainedCaptureOrdinalMaximum(in: durableConversation)
        }
        let highWatermark = max(
            durableConversation.captureOrdinalHighWatermark ?? 0,
            max(captureOrdinalHighWater[c.id] ?? 0, retainedMaximum))
        if highWatermark > 0 {
            durableConversation.captureOrdinalHighWatermark = highWatermark
            captureOrdinalHighWater[c.id] = highWatermark
        }
        let staged = ConversationSaveSnapshot(
            conversation: durableConversation,
            revision: residentRevisions[c.id] ?? 0,
            authorityBaseline: selectedSQLiteAuthority
                ? authorityCommittedBaselines[c.id] : nil)
        guard saveState.stage(staged) else { return }
        if selectedSQLiteAuthority {
            saveToAuthority(c.id)
            return
        }
        let state = saveState
        let projectionStore = projections
        let id = c.id
        let url = storeDir.appendingPathComponent("\(id.uuidString).json")
        saveQueue.async { [weak self] in
            guard let snapshot = state.take(id) else { return }
            let conversation = snapshot.conversation
            var writtenByteCount: Int?
            var writtenGenerationToken: String?
            let failure = Self.retryingDiskOperation {
#if DEBUG
                try Self.persistenceWriteTestHook?()
#endif
                let data = try Self.makeEncoder().encode(conversation)
                writtenByteCount = data.count
                // .atomic (temp + rename) so a crash/power-loss mid-write can't truncate a live
                // sidecar — a truncated 30–40 MB conversation JSON would fail to decode and the
                // conversation would silently vanish on next launch.
                try data.write(to: url, options: .atomic)
            }
            if failure == nil {
                writtenGenerationToken = try? ConversationSidecarGeneration.token(for: url)
            }
            state.finish(id, completed: failure == nil)
            // Capture this before the serial queue advances to the next drain. By the time the
            // MainActor handles a failed older snapshot, a queued newer publication may already
            // have finished; consulting only the then-current state would falsely fail waiters
            // whose guarded mutation the newer snapshot contains.
            let newerWorkWasQueued = state.hasWork(id)
            if failure == nil {
                // Spotlight and the FTS projection follow the sidecar and must never lead it:
                // index only after the durable write succeeds, never before it is attempted.
                SpotlightIndex.indexConversation(
                    id: conversation.id, title: conversation.title, cwd: conversation.cwd,
                    snippet: Self.spotlightSnippet(for: conversation))
                if let projectionStore {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.beginDirectProjectionWrite() }
                    }
                    projectionStore.index(
                        conversation,
                        sourceRevision: writtenGenerationToken ?? ""
                    ) { [weak self] succeeded in
                        self?.finishDirectProjectionWrite(succeeded: succeeded)
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.searchIndexState = .failed }
                    }
                }
            }
            // This serial producer enqueues results onto the serial main queue, preserving disk
            // attempt order. Independent MainActor Tasks have no FIFO contract and could apply an
            // older failure after a newer success, reviving a stale banner or misresolving waiters.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.finishSave(
                        snapshot,
                        writtenByteCount: writtenByteCount,
                        writtenGenerationToken: writtenGenerationToken,
                        failure: failure,
                        newerWorkWasQueued: newerWorkWasQueued)
                }
            }
        }
    }

    /// Drain one coalesced Conversation snapshot through the sole active repository. This mirrors
    /// the Legacy drain's waiter/error semantics, but the successful SQLite COMMIT is the durable
    /// publication edge. No sidecar URL is constructed and no frozen Legacy byte is touched.
    private func saveToAuthority(_ id: UUID) {
        let state = saveState
        let repository = authorityRepository
        saveQueue.async { [weak self] in
            guard var snapshot = state.take(id) else { return }
            let conversation = snapshot.conversation
            let authorityBaseline = snapshot.authorityBaseline
            snapshot.changedTranscriptEntryIDs = authorityBaseline.map {
                Self.changedTranscriptEntryIDs(from: $0, to: conversation)
            }
            snapshot.authorityBaseline = nil
            let failure = Self.retryingDiskOperation {
                guard let repository else {
                    throw CocoaError(.fileNoSuchFile)
                }
#if DEBUG
                try Self.persistenceWriteTestHook?()
                Self.authorityCommitTestHook?()
#endif
                _ = try repository.commit(
                    conversation: conversation,
                    changedTranscriptEntryIDs: snapshot.changedTranscriptEntryIDs,
                    priorConversation: authorityBaseline)
            }
            state.finish(id, completed: failure == nil)
            let newerWorkWasQueued = state.hasWork(id)
            let writtenByteCount = failure == nil
                ? Self.estimatedResidentByteCount(conversation) : nil
            if failure == nil {
                SpotlightIndex.indexConversation(
                    id: conversation.id,
                    title: conversation.title,
                    cwd: conversation.cwd,
                    snippet: Self.spotlightSnippet(for: conversation))
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.finishSave(
                        snapshot,
                        writtenByteCount: writtenByteCount,
                        writtenGenerationToken: nil,
                        failure: failure,
                        newerWorkWasQueued: newerWorkWasQueued)
                }
            }
        }
    }

    /// Retry short-lived filesystem failures without blocking the main actor. The sleeps run
    /// inline on the serial save queue, so `flushSaves()`'s barrier waits for every retry —
    /// termination cannot outrun a pending attempt. (Same pattern as `ArtifactStore`.)
    nonisolated private static func retryingDiskOperation(_ operation: () throws -> Void) -> Error? {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                try operation()
                return nil
            } catch {
                lastError = error
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.08 * Double(attempt + 1)) }
            }
        }
        return lastError
    }

    /// Atomically publish one already-validated background Conversation without ever replacing an
    /// existing Legacy source. The complete bytes are staged and fsynced before `RENAME_EXCL`
    /// makes them visible. A same-byte destination is an idempotent crash replay; different bytes
    /// are an identity collision. The directory fsync makes the name publication the durable point.
    nonisolated private static func publishBackgroundConversationCreateOnly(
        _ bytes: Data,
        to destination: URL
    ) throws -> BackgroundConversationFilePublication {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).adoption-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600))
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var temporaryExists = true
        defer {
            _ = Darwin.close(descriptor)
            if temporaryExists { _ = Darwin.unlink(temporary.path) }
        }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(
                    descriptor,
                    raw.baseAddress?.advanced(by: offset),
                    raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let renameResult = temporary.path.withCString { temporaryPath in
            destination.path.withCString { destinationPath in
                renameatx_np(
                    AT_FDCWD,
                    temporaryPath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL))
            }
        }
        if renameResult == 0 {
            temporaryExists = false
            try syncBackgroundConversationDirectory(directory)
            return .created
        }
        let renameErrno = errno
        guard renameErrno == EEXIST else {
            throw POSIXError(.init(rawValue: renameErrno) ?? .EIO)
        }
        let identical = try backgroundConversationBytes(at: destination, equal: bytes)
        // A prior attempt may have crossed the rename boundary but failed its directory fsync.
        // Re-sync on exact replay before acknowledging it.
        if identical { try syncBackgroundConversationDirectory(directory) }
        return identical ? .existingIdentical : .collision
    }

    /// Descriptor-based comparison rejects a symlink or non-regular destination and avoids a
    /// path-check/read race at the producer trust boundary.
    nonisolated private static func backgroundConversationBytes(
        at url: URL,
        equal expected: Data
    ) throws -> Bool {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_size >= 0,
              metadata.st_size == expected.count else {
            return false
        }
        var actual = Data(count: expected.count)
        let completed = actual.withUnsafeMutableBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.read(
                    descriptor,
                    raw.baseAddress?.advanced(by: offset),
                    raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        return completed && actual == expected
    }

    nonisolated private static func syncBackgroundConversationDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    /// The Spotlight snippet: first non-empty user message, else first non-empty message.
    nonisolated static func spotlightSnippet(for c: Conversation) -> String {
        c.messages.first {
            !$0.isSuperseded && $0.kind == .user && !$0.text.isEmpty
        }?.text
            ?? c.messages.first { !$0.isSuperseded && !$0.text.isEmpty }?.text ?? ""
    }

    private func finishSave(
        _ snapshot: ConversationSaveSnapshot,
        writtenByteCount: Int?,
        writtenGenerationToken: String?,
        failure: Error?,
        newerWorkWasQueued: Bool
    ) {
        let conversation = snapshot.conversation
        let persistenceSucceeded = failure == nil
        if let failure {
            let publishedRevision = persistedRevisions[conversation.id] ?? 0
            if snapshot.revision > publishedRevision,
               snapshot.revision >= (failedSaves[conversation.id]?.revision ?? 0) {
                failedSaves[conversation.id] = snapshot
                lastPersistenceFailureDetail = failure.localizedDescription
                // The banner says what happened to the person's work, not what the store said.
                // This is the only place the engine's own words survive, so log them: a save that
                // keeps failing leaves no other trace once the banner clears.
                NSLog(
                    "[persistence] conversation %@ could not be saved: %@",
                    conversation.id.uuidString, failure.localizedDescription)
            }
        } else {
            let priorPublishedRevision = persistedRevisions[conversation.id] ?? 0
            persistedRevisions[conversation.id] = max(priorPublishedRevision, snapshot.revision)
            if selectedSQLiteAuthority, snapshot.revision >= priorPublishedRevision {
                authorityCommittedBaselines[conversation.id] = conversation
            }
            if (failedSaves[conversation.id]?.revision ?? 0) <= snapshot.revision {
                failedSaves.removeValue(forKey: conversation.id)
            }
            if snapshot.revision >= priorPublishedRevision, let writtenByteCount {
                sourceByteCounts[conversation.id] = writtenByteCount
            }
            if snapshot.revision >= priorPublishedRevision, let writtenGenerationToken {
                sourceGenerationTokens[conversation.id] = writtenGenerationToken
            }
        }
        refreshPersistenceError()
        trimResidencyIfNeeded()
        if persistenceSucceeded
            || (!newerWorkWasQueued && !saveState.hasWork(conversation.id)) {
            resolvePersistenceWaiters(
                conversation.id,
                through: snapshot.revision,
                succeeded: persistenceSucceeded)
            resolvePublishedSnapshotWaiters(
                conversation.id,
                through: snapshot.revision,
                published: persistenceSucceeded ? snapshot : nil)
        }
    }

    private func resolvePersistenceWaiters(
        _ id: UUID,
        through revision: UInt64,
        succeeded: Bool
    ) {
        guard let waiters = persistenceWaiters[id] else { return }
        let completed = waiters.filter { $0.revision <= revision }
        let remaining = waiters.filter { $0.revision > revision }
        persistenceWaiters[id] = remaining.isEmpty ? nil : remaining
        for waiter in completed { waiter.completion(succeeded) }
    }

    private func resolvePublishedSnapshotWaiters(
        _ id: UUID,
        through revision: UInt64,
        published snapshot: ConversationSaveSnapshot?
    ) {
        guard let waiters = publishedSnapshotWaiters[id] else { return }
        let completed = waiters.filter { $0.revision <= revision }
        let remaining = waiters.filter { $0.revision > revision }
        publishedSnapshotWaiters[id] = remaining.isEmpty ? nil : remaining
        let published = snapshot.map {
            PublishedConversationSnapshot(
                conversation: $0.conversation,
                revision: $0.revision,
                storeID: storeID,
                hydrationEpoch: hydrationEpochs[id] ?? 0)
        }
        for waiter in completed { waiter.completion(published) }
    }

    private func refreshPersistenceError() {
        let hasWorkEvidenceFailure = !failedConversationWorkEvidenceWrites.isEmpty
            || unretainedConversationWorkEvidenceWriteCount > 0
        guard !failedSaves.isEmpty || hasWorkEvidenceFailure else {
            persistenceError = nil
            lastPersistenceFailureDetail = nil
            return
        }
        // Deliberately no error detail. This banner used to interpolate `localizedDescription`
        // straight from the store, which is how a person came to be shown
        // "UNIQUE constraint failed: conversation_events.conversation_id" in their sidebar. The
        // engine's words are not the user's situation. The detail is still recorded in
        // `lastPersistenceFailureDetail` and logged for diagnosis.
        if failedSaves.isEmpty {
            persistenceError = String(localized:
                "Mechanician couldn’t finish recording recent repository work. Retry before quitting.")
        } else {
            let subject = failedSaves.count == 1
                ? "this conversation" : "\(failedSaves.count) conversations"
            persistenceError =
                "Mechanician couldn’t save \(subject). Your messages are still on screen but not yet "
                + "on disk, so don’t quit until this clears."
        }
    }

    /// Re-enqueue every failed Conversation save and immutable work-evidence append. Later
    /// Conversation mutations supersede their failed snapshot; evidence retries reuse their exact
    /// identity. A Conversation deleted since failure is dropped, never resurrected.
    func retryFailedSaves() {
        for id in Array(failedSaves.keys) {
            if let current = conversations.first(where: { $0.id == id }) {
                if let failed = failedSaves[id],
                   failed.revision == residentRevisions[id] {
                    // This exact resident revision already crossed a save boundary that proved the
                    // retained chronology. Retry its known bound instead of walking a 15k-entry
                    // transcript again on the MainActor. A newer revision stays conservative.
                    save(
                        current,
                        retainedCaptureOrdinalUpperBound:
                            failed.conversation.captureOrdinalHighWatermark ?? 0)
                } else {
                    save(current)
                }
            } else {
                failedSaves.removeValue(forKey: id)
            }
        }
        for id in failedConversationWorkEvidenceOrder {
            guard let write = failedConversationWorkEvidenceWrites[id] else { continue }
            enqueueConversationWorkEvidenceWrite(write)
        }
        refreshPersistenceError()
    }

    /// Successful sidecar writes since launch — a test seam for the coalescing behavior. Reading
    /// after `flushSaves()` is race-free (the barrier orders every queued drain before the read).
    var completedDiskWrites: Int { saveState.totalCompletedWrites }

    /// With a slot, the sidecar and media are moved there so undo can retrieve them. Without one,
    /// this is the old unlink — used for a permanent delete and when no slot could be made.
    private func deleteFile(_ id: UUID, into slot: URL?) {
        // A queued-but-undrained save for this conversation must not land after the delete; a
        // failed-save snapshot for it is moot once the user has deleted the conversation.
        saveState.cancel(id)
        if failedSaves.removeValue(forKey: id) != nil { refreshPersistenceError() }
        if selectedSQLiteAuthority {
            let storage = mediaStorage
            let trash = self.trash
            let mediaDirectory = storage.root.appendingPathComponent(
                id.uuidString,
                isDirectory: true)
            saveQueue.async {
                if let slot {
                    try? trash.take(mediaDirectory, into: slot)
                } else {
                    try? storage.removeConversation(id)
                }
            }
            return
        }
        let url = storeDir.appendingPathComponent("\(id.uuidString).json")
        // Delete the file this conversation was actually loaded from as well. On a case-INSENSITIVE
        // volume the two paths can resolve to the same file; the second remove simply fails, which
        // is why this is a best-effort remove of both rather than a choice between them.
        let extra = nonCanonicalFiles.removeValue(forKey: id)
        let storage = mediaStorage
        let trash = self.trash
        let projectionStore = projections
        let mediaDirectory = storage.root.appendingPathComponent(id.uuidString, isDirectory: true)
        saveQueue.async { [weak self] in
            let sourceURLs = [url, extra].compactMap { $0 }
            if let slot {
                try? trash.take(url, into: slot)
                if let extra { try? FileManager.default.removeItem(at: extra) }
                try? trash.take(mediaDirectory, into: slot)
            } else {
                try? FileManager.default.removeItem(at: url)
                if let extra { try? FileManager.default.removeItem(at: extra) }
                try? storage.removeConversation(id)
            }
            // Search must not lead a failed Legacy unlink. Only the closed successful deletion may
            // remove direct indexes; exact SQLite mode waits for the library delete/outbox commit.
            if sourceURLs.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) {
                SpotlightIndex.deindexConversation(id)
                if let projectionStore {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.beginDirectProjectionWrite() }
                    }
                    projectionStore.remove(id) { [weak self] succeeded in
                        self?.finishDirectProjectionWrite(succeeded: succeeded)
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.searchIndexState = .failed }
                    }
                }
            }
        } // after any queued save/media write
    }

    /// Delete is rare and must not be optimistic: synchronously cross the SQLite COMMIT edge before
    /// removing the row from the shared UI or handing back an undo receipt. The serial queue first
    /// drains any older in-flight save; cancelling the undrained snapshot prevents resurrection.
    private func commitAuthorityDelete(
        _ id: UUID,
        preservesWorkEvidenceForUndo: Bool
    ) -> LibraryAuthorityConversationDeleteResult? {
        saveState.cancel(id)
        let repository = authorityRepository
        var result: LibraryAuthorityConversationDeleteResult?
        var failure: Error?
        saveQueue.sync {
            failure = Self.retryingDiskOperation {
                guard let repository else { throw CocoaError(.fileNoSuchFile) }
                if preservesWorkEvidenceForUndo {
                    result = try repository.deleteConversationForUndo(id: id)
                } else {
                    result = LibraryAuthorityConversationDeleteResult(
                        committedSequence: try repository.deleteConversation(id: id),
                        workEvidence: [])
                }
            }
        }
        guard failure == nil, let result else {
            lastPersistenceFailureDetail = failure?.localizedDescription
            persistenceError = "The conversation couldn’t be deleted from library.db. Nothing was removed."
            return nil
        }
        failedSaves[id] = nil
        SpotlightIndex.deindexConversation(id)
        // Keep the sequence visible in the disposable projection ordering even though remove has
        // no source-revision column of its own; the authoritative transaction already advanced it.
        _ = result.committedSequence
        return result
    }

    /// Block until every queued write/delete completes — called on app termination.
    func flushSaves() { saveQueue.sync {} }

    private func beginDirectProjectionWrite() {
        directProjectionWritesInFlight += 1
        searchIndexState = .indexing
    }

    private func finishDirectProjectionWrite(succeeded: Bool) {
        directProjectionWritesInFlight = max(0, directProjectionWritesInFlight - 1)
        if !succeeded { directProjectionWriteFailed = true }
        guard directProjectionWritesInFlight == 0 else { return }
        searchIndexState = directProjectionWriteFailed ? .failed : .current
        directProjectionWriteFailed = false
    }

    /// Remove one sidecar file by URL on the serial IO queue (after any queued save).
    private func removeFileAsync(_ url: URL) {
        saveQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Move an undecodable sidecar aside (non-`.json` suffix so it is never re-read) instead of
    /// leaving it to sit invisibly on disk. Best-effort and unique-per-attempt.
    private func quarantineCorruptSidecar(_ url: URL) {
        saveQueue.async { Self.quarantineCorruptSidecarFile(url) }
    }

    nonisolated static func quarantineCorruptSidecarFile(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = url.appendingPathExtension("corrupt-\(stamp)")
        let fm = FileManager.default
        let final = fm.fileExists(atPath: dest.path)
            ? url.appendingPathExtension("corrupt-\(stamp)-\(UUID().uuidString.prefix(4))")
            : dest
        try? fm.moveItem(at: url, to: final)
    }

    /// Adopt a conversation that isn't loaded yet by reading its sidecar from disk — e.g. one an
    /// ambient/external process wrote after this process launched, which Spotlight / the "Open
    /// Conversation" App Intent can target. Heals stale spinners like `load` does. Returns whether
    /// the conversation is present afterward (already-loaded ids short-circuit to `true`).
    @discardableResult
    func reloadFromDisk(_ id: UUID) -> Bool {
        if contains(id) { return true }
        let url = storeDir.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url),
              var c = try? Self.makeDecoder().decode(Conversation.self, from: data) else { return false }
        _ = Self.healStaleState(&c)
        if !c.queuedPrompts.isEmpty { pausedQueueConversationIDs.insert(c.id) }
        upsert(c)
        return true
    }

    /// Everything the disk scan produces, computed off the main actor for the async path.
    struct LoadResult {
        var loaded: [Conversation]          // deduped + healed, unsorted
        var healedIDs: Set<UUID>
        var nonCanonicalFiles: [UUID: URL]
        var staleURLs: [URL]
        var sourceByteCounts: [UUID: Int]
        var sourceGenerationTokens: [UUID: String]
        var captureOrdinalHighWatermarks: [UUID: UInt64]
    }

    nonisolated private static func scanDisk(storeDir: URL) -> LoadResult {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: storeDir, includingPropertiesForKeys: nil)) ?? []
        let decoder = Self.makeDecoder()
        // Dedupe by conversation id. A non-canonically-named sidecar (e.g. ambientd's lowercase
        // UUID stem on a case-sensitive volume, or a Finder-duplicated "… copy.json") could load a
        // SECOND copy of the same id → duplicate sidebar rows that resurrect after deletion. Keep
        // the newest updatedAt per id; the loser files (and non-canonical survivors) are cleaned up.
        var byID: [UUID: (
            conversation: Conversation,
            url: URL,
            sourceBytes: Int,
            sourceGenerationToken: String?
        )] = [:]
        var staleURLs: [URL] = []          // duplicate / empty non-canonical files to delete
        for f in files where f.pathExtension == "json" {
            let generationBeforeRead = try? ConversationSidecarGeneration.token(for: f)
            guard let data = try? Data(contentsOf: f) else { continue }
            let generationAfterRead = try? ConversationSidecarGeneration.token(
                for: f, expectedByteCount: data.count)
            let stableGeneration = generationBeforeRead == generationAfterRead
                ? generationAfterRead
                : nil
            guard let c = try? decoder.decode(Conversation.self, from: data) else {
                // Undecodable at cold start (no daemon writing yet) = genuinely corrupt. Preserve
                // the bytes under a non-.json name instead of silently abandoning them, so a
                // truncated/incompatible sidecar is recoverable rather than an invisible loss.
                // Inline move: at load time the save queue is empty, so ordering is unchanged.
                Self.quarantineCorruptSidecarFile(f)
                continue
            }
            // Drop empty placeholders left by earlier sessions — but a conversation with only
            // QUEUED prompts (no messages yet) is NOT empty; deleting it here silently dropped
            // queued work on the next launch. Keep it if it has real messages OR pending queued
            // prompts (mirrors the emptiness test used everywhere else).
            guard c.hasDurableContent else { staleURLs.append(f); continue }
            if let existing = byID[c.id] {
                if c.updatedAt > existing.conversation.updatedAt {
                    staleURLs.append(existing.url)
                    byID[c.id] = (
                        c,
                        f,
                        data.count,
                        stableGeneration)
                } else {
                    staleURLs.append(f)
                }
            } else {
                byID[c.id] = (
                    c,
                    f,
                    data.count,
                    stableGeneration)
            }
        }
        var loaded = Array(byID.values.map(\.conversation))
        // Remember any survivor that does NOT live under its canonical name, so deleting it later
        // removes the file that actually holds it.
        let nonCanonical = byID.compactMapValues { entry in
            entry.url.lastPathComponent == "\(entry.conversation.id.uuidString).json" ? nil : entry.url
        }
        // Cold start: this store loads exactly once at process launch (before any daemon runs), so any
        // persisted `.running` workflow/subagent run is definitely stale → heal it to `.stopped`.
        var healedIDs = Set<UUID>()
        for i in loaded.indices {
            if Self.healStaleState(&loaded[i]) { healedIDs.insert(loaded[i].id) }
        }
        let captureOrdinalHighWatermarks = Dictionary(uniqueKeysWithValues: loaded.map {
            (
                $0.id,
                max(
                    $0.captureOrdinalHighWatermark ?? 0,
                    Self.retainedCaptureOrdinalMaximum(in: $0)))
        })
        return LoadResult(
            loaded: loaded,
            healedIDs: healedIDs,
            nonCanonicalFiles: nonCanonical,
            staleURLs: staleURLs,
            sourceByteCounts: byID.mapValues(\.sourceBytes),
            sourceGenerationTokens: byID.compactMapValues(\.sourceGenerationToken),
            captureOrdinalHighWatermarks: captureOrdinalHighWatermarks)
    }

    private func applyLoadResult(_ result: LoadResult) {
        nonCanonicalFiles = result.nonCanonicalFiles
        sourceGenerationTokens = result.sourceGenerationTokens
        // Delete only the genuine duplicate/placeholder LOSERS — files whose id is represented by a
        // different, newer file (case-sensitive-volume twins, or a Finder "… copy.json" on any
        // volume). We deliberately do NOT rewrite-then-delete a survivor's own non-canonically-named
        // file: on a case-INSENSITIVE volume `<lowercase>.json` and `<UPPERCASE>.json` are the SAME
        // file, so that would delete the file we just rewrote. The in-memory dedupe already removes
        // the duplicate row and its resurrect-after-delete, and the daemon now writes canonical
        // uppercase names, so no rewrite is needed here.
        for url in result.staleURLs { removeFileAsync(url) }
        // Merge, don't assign: while the async decode ran, the user may already have created a
        // conversation (⌘N and typing during launch is real) or deleted one via a queued
        // tombstone. Wiping either with the disk snapshot would be the state-loss invariant
        // failing in its most literal form.
        let preReady = conversations
        let preReadyIDs = Set(preReady.map(\.id))
        var merged = result.loaded.filter {
            !deletedIDs.contains($0.id) && !preReadyIDs.contains($0.id)
        }
        merged.append(contentsOf: preReady)
        for conversation in result.loaded
        where !deletedIDs.contains(conversation.id) && !preReadyIDs.contains(conversation.id) {
            installCaptureOrdinalHighWater(
                result.captureOrdinalHighWatermarks[conversation.id] ?? 0,
                for: conversation.id)
        }
        conversations = merged.sorted(by: Self.order)
        for conversation in result.loaded where !preReadyIDs.contains(conversation.id) {
            sourceByteCounts[conversation.id] = result.sourceByteCounts[conversation.id] ?? 0
            residentRevisions[conversation.id] = 0
            persistedRevisions[conversation.id] = 0
            markAccess(conversation.id)
        }
        rebuildSummaries()
        authoritativeInventoryLoaded = true
        pausedQueueConversationIDs.formUnion(result.loaded.compactMap {
            preReadyIDs.contains($0.id) || $0.queuedPrompts.isEmpty ? nil : $0.id
        })
        // Healing only in memory resurrects the same spinner (or ambiguous guidance) after every
        // launch. Persist each changed sidecar once; the serial save queue preserves write ordering.
        for conversation in result.loaded
        where healedIDs(result, contain: conversation.id) && !preReadyIDs.contains(conversation.id) {
            advanceRevision(conversation.id)
            save(conversation)
        }
    }

    nonisolated private func healedIDs(_ result: LoadResult, contain id: UUID) -> Bool {
        result.healedIDs.contains(id)
    }

    // MARK: - Live ingest of externally-written conversations (ambient runs)

    /// Watch the conversations directory so a run written by the ambient daemon (a separate process)
    /// appears in the sidebar live, without a relaunch — the same pattern ArtifactStore uses for
    /// ambient artifacts. Files are written atomically (temp + rename), which fires a dir vnode event.
    @discardableResult
    private func startWatchingDir() -> Bool {
        if dirWatch != nil { return true }
        let fd = open(storeDir.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        src.setEventHandler { [weak self] in self?.debouncedAdopt() }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirWatch = src
#if DEBUG
        directoryWatcherStartCount += 1
#endif
        return true
    }

#if DEBUG
    @discardableResult
    func ensureDirectoryWatcherForTesting() -> Bool { startWatchingDir() }
#endif

    private func debouncedAdopt() {
        guard !adoptPending else { return }
        adoptPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.adoptPending = false
            self?.adoptExternalConversations()
        }
    }

    /// Adopt conversation files whose id we DON'T already hold — i.e. ones an external process (the
    /// ambient daemon) wrote after launch. Deliberately never re-reads or overwrites conversations
    /// already in memory: a window may be actively driving one, and `load()`'s cold-start heal would
    /// stomp its live `.running` runs. Ambient runs always write a NEW id, so new-only is exactly right.
    /// The watcher's adopt pass, reachable from tests without running a real directory watcher.
    func adoptExternalConversationsForTesting() { adoptExternalConversations() }

    private func adoptExternalConversations() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: storeDir, includingPropertiesForKeys: nil)) ?? []
        // `conversations` is only the resident working set in bounded mode. The summary inventory
        // is the closed set: treating an evicted sidecar as a newcomer would synchronously decode
        // the whole corpus again after every save and could overwrite a newer in-memory mutation.
        let known = conversationIDs
        let decoder = Self.makeDecoder()
        for f in files where f.pathExtension == "json" {
            // Our own saves also fire the directory watcher. Conversation sidecars use their UUID
            // as the filename, so reject already-loaded files before reading and decoding them.
            // This matters for long transcripts: without the filename gate, every durable save
            // synchronously re-read every conversation (including the just-written multi-MB one)
            // on the main actor merely to discover that its decoded id was already known. Keep the
            // decode fallback for legacy/nonstandard filenames written by external integrations.
            if let fileID = UUID(uuidString: f.deletingPathExtension().lastPathComponent),
               known.contains(fileID) || deletedIDs.contains(fileID) {
                continue
            }
            guard let data = try? Data(contentsOf: f),
                  var c = try? decoder.decode(Conversation.self, from: data),
                  !known.contains(c.id) else { continue }
            // A conversation the user deleted must not be read back in because its file is named
            // something other than `<id>.json` and the asynchronous delete hasn't landed yet.
            guard !deletedIDs.contains(c.id) else { continue }
            // Only real conversations (ambient runs have messages); skip empty placeholders.
            guard c.hasDurableContent else { continue }
            _ = Self.healStaleState(&c)
            if !c.queuedPrompts.isEmpty { pausedQueueConversationIDs.insert(c.id) }
            // Adopting leaves the original file in place (upsert writes the canonical name), so
            // record it — otherwise deleting this conversation would strand the file it came from.
            if f.lastPathComponent != "\(c.id.uuidString).json" { nonCanonicalFiles[c.id] = f }
            upsert(c)   // persist-through is a no-op re-write of the same content; republishes to all windows
        }
    }

    // MARK: - Stale-spinner heal (a persisted `.running` run from a dead process is stopped)

    /// A sidecar has no live process owner while it is being loaded. Stop every process-owned
    /// lifecycle and move undelivered guidance into visible, quarantined queued work. Historical
    /// queued/cancelled guidance rows are removed so one pending prompt never appears twice.
    @discardableResult
    nonisolated static func healStaleState(_ conversation: inout Conversation) -> Bool {
        var changed = conversation.needsStaleStatePersistence
        conversation.needsStaleStatePersistence = false
        changed = stopUnfinishedToolEntries(&conversation.messages) || changed
        // A sidecar loaded without a live bridge has lost the process that owned every open
        // delegate. Use the same reducer as explicit Stop/runtime-exit recovery so aggregate runs,
        // nested workflow agents, standalone subagents, and their activity tails settle together.
        changed = terminalizeDelegatedWorkState(
            workflowRuns: &conversation.workflowRuns,
            subagents: &conversation.subagents,
            agentActivity: &conversation.agentActivity,
            outcome: .userStopped,
            turnID: nil,
            selection: conversation.modelSelection,
            boundary: .lastPersistedObservation) || changed
        // A reusable Codex child can keep a terminal cumulative card while publishing a new
        // per-turn activity generation. Older builds then had no nonterminal card for the reducer
        // above to settle, so the persisted trace remained falsely active after every restart.
        // Cold load has no surviving provider owner; close those activity-only tails at their last
        // persisted observation without rewriting the older card lifecycle.
        changed = terminalizeColdLoadedAgentActivity(
            &conversation.agentActivity,
            aliases: agentActivityAliases(
                subagents: conversation.subagents,
                workflowRuns: conversation.workflowRuns)) || changed
        let pendingGuidance = conversation.messages.filter {
            $0.guidanceState == .sending || $0.guidanceState == .queued
        }
        for entry in pendingGuidance.reversed() {
            let prompt = entry.text
            if !conversation.queuedPrompts.contains(prompt) {
                conversation.queuedPrompts.insert(prompt, at: 0)
            }
        }
        let oldCount = conversation.messages.count
        conversation.messages.removeAll {
            $0.guidanceState == .sending
                || $0.guidanceState == .queued
                || $0.guidanceState == .cancelled
        }
        if conversation.messages.count != oldCount {
            changed = true
        }
        // A pendingTurnPrompt in a loaded sidecar is crash evidence: the send was accepted and
        // committed before the provider request, but no acknowledged turn durably landed the user
        // entry (acknowledgement clears this slot in the same write). Recover the words to the
        // front of the queue — which load quarantines as paused, so nothing auto-sends — unless
        // the durable transcript already ends with this exact user text (the entry landed but a
        // pre-clear snapshot won; queueing it again would duplicate the visible message). Queue
        // text is not identity: two deliberate identical actions must both survive a crash.
        if let recovered = conversation.pendingTurnPrompt {
            conversation.pendingTurnPrompt = nil
            // A real user turn retires the older follow-up. A synthetic wait continuation is an
            // app-owned lifecycle event, so preserve the bar until that resumed turn publishes a
            // valid replacement.
            if SuggestedPromptFallback.shouldRetireExistingSuggestion(for: recovered) {
                conversation.suggestedPrompt = nil
            }
            let alreadyLanded = conversation.messages.last {
                $0.kind == .user
            }?.text == recovered
            if !alreadyLanded {
                conversation.queuedPrompts.insert(recovered, at: 0)
            }
            changed = true
        }
        return changed
    }
}
