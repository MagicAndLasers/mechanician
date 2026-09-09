import Foundation

/// The reason Mechanician is allowed to associate one observation with a Conversation. These are
/// exact edges, not relevance estimates: a provider-confirmed file tool receipt, a Git observation
/// made for the Conversation's recorded checkout, or a weaker before/after observation bounded by
/// the Conversation's active turn.
enum ChangesEvidenceProvenance: Equatable, Sendable {
    case directFileTool(toolUseID: String?)
    case exactGitObservation
    case observedDuringConversation(toolUseID: String?)

    var label: String {
        switch self {
        case .directFileTool: return "Direct file tool"
        case .exactGitObservation: return "Git observation"
        case .observedDuringConversation:
            return "Observed while running; attribution unverified"
        }
    }
}

/// A bounded copy of one exact transcript entry. The entry identity and capture time let the
/// authority adapter prove where the text came from without loading a transcript in the inspector.
struct ChangesTranscriptEvidence: Equatable, Sendable {
    let entryID: UUID
    let text: String
    let capturedAt: Date
    let truncated: Bool

    init(entryID: UUID, text: String, capturedAt: Date, truncated: Bool = false) {
        self.entryID = entryID
        self.text = text
        self.capturedAt = capturedAt
        self.truncated = truncated
    }
}

enum ChangesObservedFileOperation: Equatable, Sendable {
    case read
    case edited
    case created
    case deleted
    case renamed(fromPath: String)

    var label: String {
        switch self {
        case .read: return "Read"
        case .edited: return "Edited"
        case .created: return "Created"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        }
    }

    var isMutation: Bool {
        if case .read = self { return false }
        return true
    }
}

/// Repository evidence for a file is deliberately time-scoped. In particular, `noCurrentDiff`
/// never means committed: it says only that the last exact Git check found no pending bytes.
enum ChangesFileRepositoryState: Equatable, Sendable {
    case uncommitted(indexStatus: String?, worktreeStatus: String?)
    case committed(commitOID: String, reachableFrom: [String])
    case noCurrentDiff
    case outsideRepository
    case notVersionControlled
    case unavailable

    var label: String {
        switch self {
        case .uncommitted(let index, let worktree):
            let parts = [index.map { "index: \($0)" }, worktree.map { "worktree: \($0)" }]
                .compactMap { $0 }
            return parts.isEmpty
                ? "Path currently modified"
                : "Path currently modified · " + parts.joined(separator: " · ")
        case .committed(let oid, let refs):
            let commit = "Commit \(shortGitOID(oid))"
            guard !refs.isEmpty else { return commit }
            return commit + " · reachable from " + refs.map(shortGitRef).joined(separator: ", ")
        case .noCurrentDiff: return "Path has no current diff; commit or revert not determined"
        case .outsideRepository: return "Path is outside this repository"
        case .notVersionControlled: return "Path is not under version control"
        case .unavailable: return "Current path state unavailable"
        }
    }
}

/// One file receipt inside one recorded unit of Conversation work. `patch` is bounded evidence,
/// never reconstructed later from a possibly different checkout.
struct ChangesObservedFileEvidence: Identifiable, Equatable, Sendable {
    let id: String
    let path: String
    let operation: ChangesObservedFileOperation
    let provenance: ChangesEvidenceProvenance
    let capturedAt: Date
    let beforeDigest: String?
    let afterDigest: String?
    let patch: String?
    let patchWasTruncated: Bool
    let repositoryState: ChangesFileRepositoryState?

    init(
        id: String,
        path: String,
        operation: ChangesObservedFileOperation,
        provenance: ChangesEvidenceProvenance,
        capturedAt: Date,
        beforeDigest: String? = nil,
        afterDigest: String? = nil,
        patch: String? = nil,
        patchWasTruncated: Bool = false,
        repositoryState: ChangesFileRepositoryState? = nil
    ) {
        self.id = id
        self.path = path
        self.operation = operation
        self.provenance = provenance
        self.capturedAt = capturedAt
        self.beforeDigest = beforeDigest
        self.afterDigest = afterDigest
        self.patch = patch
        self.patchWasTruncated = patchWasTruncated
        self.repositoryState = repositoryState
    }

    var name: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

/// Prompt, final response, and mechanically observed files remain separate so a model claim can
/// never be rendered as if Git proved it.
struct ChangesWorkEvidence: Identifiable, Equatable, Sendable {
    let id: String
    let turnID: String?
    let personAsked: ChangesTranscriptEvidence?
    let agentReported: ChangesTranscriptEvidence?
    let observedFiles: [ChangesObservedFileEvidence]
    /// The exact checkout snapshot for this turn. A Conversation can move between worktrees or
    /// branches over time, so the source location must travel with the work record rather than be
    /// inferred from the Conversation's newest observation.
    let repository: ChangesRepositoryEvidence?
    let capturedAt: Date

    init(
        id: String,
        turnID: String? = nil,
        personAsked: ChangesTranscriptEvidence? = nil,
        agentReported: ChangesTranscriptEvidence? = nil,
        observedFiles: [ChangesObservedFileEvidence] = [],
        repository: ChangesRepositoryEvidence? = nil,
        capturedAt: Date
    ) {
        self.id = id
        self.turnID = turnID
        self.personAsked = personAsked
        self.agentReported = agentReported
        self.observedFiles = observedFiles
        self.repository = repository
        self.capturedAt = capturedAt
    }
}

enum ChangesRepositoryRelationship: Equatable, Sendable {
    case sameCommit
    case includedInTarget(targetCommitsAfterSource: Int?)
    /// Git proved the source commit is not reachable from the exact frozen target tip. This says
    /// nothing about whether the source is ahead, diverged, or equivalent after a rewrite.
    case notIncludedInTarget
    case sourceAheadOfTarget(commits: Int)
    case diverged(sourceOnly: Int, targetOnly: Int)
    case unrelated
    case unknown

    var label: String {
        switch self {
        case .sameCommit: return "Source HEAD matches current checkout"
        case .includedInTarget(let count):
            guard let count else {
                return "Source HEAD included in current checkout · Git ancestry verified"
            }
            return count == 0
                ? "Source HEAD included in current checkout"
                : "Source HEAD included · current checkout is \(count) commit\(count == 1 ? "" : "s") newer"
        case .notIncludedInTarget: return "Source HEAD not included in current checkout"
        case .sourceAheadOfTarget(let count):
            return "Source HEAD is \(count) commit\(count == 1 ? "" : "s") ahead of current checkout"
        case .diverged(let sourceOnly, let targetOnly):
            return "Source HEAD diverged from current checkout · \(sourceOnly) source-only · \(targetOnly) checkout-only"
        case .unrelated: return "Source HEAD and current checkout have no common ancestor"
        case .unknown: return "Source HEAD relationship to current checkout not checked"
        }
    }

    var isIncluded: Bool {
        switch self {
        case .sameCommit, .includedInTarget: return true
        default: return false
        }
    }
}

/// Current local-ref containment for the immutable captured source HEAD. An empty available list is
/// a useful Git fact; it must not collapse into a failed or never-requested census.
enum ChangesCommitReachability: Equatable, Sendable {
    case notChecked
    case available(localBranchRefs: [String])
    case commitMissing
    case unavailable

    var label: String {
        switch self {
        case .notChecked: return "Branch reachability not checked"
        case .available(let refs):
            guard !refs.isEmpty else { return "No local branch currently contains this commit" }
            return "Reachable from local branches: "
                + refs.map(shortGitRef).joined(separator: ", ")
        case .commitMissing: return "Captured commit is no longer available locally"
        case .unavailable: return "Branch reachability unavailable"
        }
    }
}

/// A point-in-time source checkout and exact current-checkout comparison. Full refs and object IDs
/// are retained; shortening happens only in presentation.
struct ChangesRepositoryEvidence: Equatable, Sendable {
    let repositoryID: String?
    let commonDirectory: String?
    let worktreePath: String
    let symbolicRef: String?
    let headOID: String?
    let targetRef: String?
    let targetOID: String?
    let relationship: ChangesRepositoryRelationship
    let headReachability: ChangesCommitReachability
    /// Nil means the source checkout's file state was not available. It must not be rendered or
    /// reasoned about as a clean checkout.
    let indexChangeCount: Int?
    let worktreeChangeCount: Int?
    let untrackedCount: Int?
    let checkedAt: Date

    init(
        repositoryID: String? = nil,
        commonDirectory: String? = nil,
        worktreePath: String,
        symbolicRef: String? = nil,
        headOID: String? = nil,
        targetRef: String? = nil,
        targetOID: String? = nil,
        relationship: ChangesRepositoryRelationship = .unknown,
        headReachability: ChangesCommitReachability = .notChecked,
        indexChangeCount: Int? = nil,
        worktreeChangeCount: Int? = nil,
        untrackedCount: Int? = nil,
        checkedAt: Date
    ) {
        self.repositoryID = repositoryID
        self.commonDirectory = commonDirectory
        self.worktreePath = worktreePath
        self.symbolicRef = symbolicRef
        self.headOID = headOID
        self.targetRef = targetRef
        self.targetOID = targetOID
        self.relationship = relationship
        self.headReachability = headReachability
        self.indexChangeCount = indexChangeCount
        self.worktreeChangeCount = worktreeChangeCount
        self.untrackedCount = untrackedCount
        self.checkedAt = checkedAt
    }

    var uncommittedCount: Int? {
        guard let indexChangeCount, let worktreeChangeCount, let untrackedCount else { return nil }
        return indexChangeCount + worktreeChangeCount + untrackedCount
    }

    var sourceLabel: String {
        let ref = symbolicRef.map(shortGitRef) ?? (headOID == nil ? "unborn" : "detached")
        guard let headOID else { return ref }
        return "\(ref)@\(shortGitOID(headOID))"
    }

    var currentCheckoutLabel: String? {
        guard targetRef != nil || targetOID != nil else { return nil }
        let ref = targetRef.map(shortGitRef) ?? "current checkout"
        guard let targetOID else { return ref }
        return "\(ref)@\(shortGitOID(targetOID))"
    }

    /// Compatibility spelling for pure presentation callers written before the comparison was
    /// explicitly named as the current checkout rather than an implicit release target.
    var targetLabel: String? { currentCheckoutLabel }
}

/// All exact records currently known for one Conversation in a repository. A record with an empty
/// `work` array is meaningful: the repository edge is known, but older work was not captured.
struct ChangesConversationEvidence: Equatable, Sendable {
    let conversationID: UUID
    let work: [ChangesWorkEvidence]
    let repository: ChangesRepositoryEvidence?
    let checkedAt: Date?

    init(
        conversationID: UUID,
        work: [ChangesWorkEvidence] = [],
        repository: ChangesRepositoryEvidence? = nil,
        checkedAt: Date? = nil
    ) {
        self.conversationID = conversationID
        self.work = work
        self.repository = repository
        self.checkedAt = checkedAt
    }
}

/// Authority-agnostic adapter input. AgentBridge/ConversationStore can publish this immutable value
/// without giving the SwiftUI view a database or Git dependency.
struct ChangesInspectorEvidence: Equatable, Sendable {
    var conversations: [ChangesConversationEvidence]
    var checkedAt: Date?

    static let empty = ChangesInspectorEvidence(conversations: [], checkedAt: nil)

    init(conversations: [ChangesConversationEvidence], checkedAt: Date?) {
        self.conversations = conversations
        self.checkedAt = checkedAt
    }
}

struct ChangesConversationPresentation: Identifiable, Equatable {
    let summary: ConversationSummary
    let isCurrent: Bool
    let work: [ChangesWorkEvidence]
    let repository: ChangesRepositoryEvidence?
    let checkedAt: Date?

    var id: UUID { summary.id }
    var title: String { summary.displayTitle }
    var observedFileCount: Int { Set(work.flatMap(\.observedFiles).map(\.path)).count }
    var mutationFileCount: Int {
        Set(work.flatMap(\.observedFiles).filter { $0.operation.isMutation }.map(\.path)).count
    }
    var latestCapturedAt: Date? { work.map(\.capturedAt).max() }
}

struct ChangesInspectorPresentation: Equatable {
    let current: ChangesConversationPresentation?
    let others: [ChangesConversationPresentation]
    let checkedAt: Date?

    /// The sole adapter entry point for the Changes UI. `summaries` supplies the exact saved title;
    /// an authority record without a matching Conversation summary is not displayed under an
    /// invented title. `liveObservedFiles` keeps session file-tool receipts useful during rollout.
    static func make(
        currentConversationID: UUID?,
        summaries: [ConversationSummary],
        evidence: ChangesInspectorEvidence,
        liveObservedFiles: [UUID: [ChangesObservedFileEvidence]] = [:]
    ) -> ChangesInspectorPresentation {
        let summaryByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        var evidenceByID: [UUID: ChangesConversationEvidence] = [:]

        for value in evidence.conversations {
            if let existing = evidenceByID[value.conversationID] {
                let repositories = [existing.repository, value.repository].compactMap { $0 }
                let newestRepository = repositories.max { $0.checkedAt < $1.checkedAt }
                evidenceByID[value.conversationID] = ChangesConversationEvidence(
                    conversationID: value.conversationID,
                    work: existing.work + value.work,
                    repository: newestRepository,
                    checkedAt: [existing.checkedAt, value.checkedAt].compactMap { $0 }.max())
            } else {
                evidenceByID[value.conversationID] = value
            }
        }

        if let currentConversationID, summaryByID[currentConversationID] != nil,
           evidenceByID[currentConversationID] == nil {
            evidenceByID[currentConversationID] = ChangesConversationEvidence(
                conversationID: currentConversationID)
        }

        var rows: [ChangesConversationPresentation] = []
        for (conversationID, base) in evidenceByID {
            guard let summary = summaryByID[conversationID] else { continue }
            var work = base.work
            if let live = liveObservedFiles[conversationID], !live.isEmpty {
                let latestRecordedByPath = Dictionary(
                    grouping: work.flatMap(\.observedFiles),
                    by: \.path)
                    .mapValues { files in files.map(\.capturedAt).max() ?? .distantPast }
                let newerLiveEvidence = live.filter { file in
                    guard let recordedAt = latestRecordedByPath[file.path] else { return true }
                    return file.capturedAt > recordedAt
                }
                if !newerLiveEvidence.isEmpty {
                    work.append(ChangesWorkEvidence(
                        id: "session-live-fallback",
                        observedFiles: newerLiveEvidence,
                        capturedAt: newerLiveEvidence.map(\.capturedAt).max() ?? summary.updatedAt))
                }
            }
            work.sort {
                if $0.capturedAt != $1.capturedAt { return $0.capturedAt > $1.capturedAt }
                return $0.id < $1.id
            }
            rows.append(ChangesConversationPresentation(
                summary: summary,
                isCurrent: conversationID == currentConversationID,
                work: work,
                repository: base.repository,
                checkedAt: base.checkedAt))
        }

        let current = rows.first(where: \.isCurrent)
        let others = rows.filter { !$0.isCurrent }.sorted {
            let left = $0.latestCapturedAt ?? $0.summary.updatedAt
            let right = $1.latestCapturedAt ?? $1.summary.updatedAt
            if left != right { return left > right }
            if $0.title != $1.title {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        return ChangesInspectorPresentation(current: current, others: others, checkedAt: evidence.checkedAt)
    }
}

/// A mutation is proven in the exact current checkout only when Git found the captured bytes in a
/// commit which the exact checkout ref contains (or when that commit is the checkout tip itself).
/// Path-only dirty state, a clean path, and an unscanned other worktree remain unproved.
func changesFileMutationIsProvenInCurrentCheckout(
    _ file: ChangesObservedFileEvidence,
    repository: ChangesRepositoryEvidence?
) -> Bool {
    guard file.operation.isMutation else { return true }
    guard let repository,
          case .committed(let commitOID, let reachableFrom) = file.repositoryState else {
        return false
    }
    if commitOID == repository.targetOID { return true }
    guard let currentRef = repository.targetRef else { return false }
    return reachableFrom.contains(currentRef)
}

func changesWorkHasUnprovedMutation(
    _ work: ChangesWorkEvidence,
    fallbackRepository: ChangesRepositoryEvidence? = nil
) -> Bool {
    let repository = work.repository ?? fallbackRepository
    return work.observedFiles.contains {
        $0.operation.isMutation
            && !changesFileMutationIsProvenInCurrentCheckout($0, repository: repository)
    }
}

func changesRepositoryCanShowIncludedCheck(
    _ repository: ChangesRepositoryEvidence,
    hasUnprovedMutationWork: Bool
) -> Bool {
    repository.relationship.isIncluded
        // Unknown source file state is not clean source file state.
        && repository.uncommittedCount == 0
        && !hasUnprovedMutationWork
}

func shortGitOID(_ oid: String, length: Int = 8) -> String {
    String(oid.prefix(max(1, length)))
}

func shortGitRef(_ ref: String) -> String {
    for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where ref.hasPrefix(prefix) {
        return String(ref.dropFirst(prefix.count))
    }
    return ref
}
