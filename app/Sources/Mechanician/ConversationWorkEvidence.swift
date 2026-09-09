import Foundation

/// Why Mechanician captured one mechanical repository snapshot.
///
/// These are observed boundaries, not inferred relationships. In particular, a refresh does not
/// claim that the current Conversation caused any bytes which Git reports at that instant.
enum ConversationRepositoryObservationReason: String, CaseIterable, Equatable, Sendable {
    case turnStarted = "turn_started"
    case toolCompleted = "tool_completed"
    case turnCompleted = "turn_completed"
    case changesRefresh = "changes_refresh"
    case gitMutation = "git_mutation"
}

/// The exact shape of HEAD when Git made it available.
enum ConversationRepositoryHeadState: String, CaseIterable, Equatable, Sendable {
    case attached
    case detached
    case unborn
}

/// Whether Git returned a usable status at this observation boundary.
enum ConversationRepositoryStatusAvailability: String, CaseIterable, Equatable, Sendable {
    case available
    case unavailable
}

/// The strength of the edge between a Conversation tool and a reported file fact.
enum ConversationWorkAttribution: String, CaseIterable, Equatable, Sendable {
    /// A successful provider file tool named the path directly.
    case directTool = "direct_tool"
    /// A before/after repository observation saw a delta around an otherwise opaque tool.
    case observedDuringTool = "observed_during_tool"
}

/// Exact provider tool semantics. Filesystem effects inferred from Git stay `opaqueChange`.
enum ConversationFileOperation: String, CaseIterable, Equatable, Sendable {
    case read
    case edit
    case write
    case multiEdit = "multi_edit"
    case notebookEdit = "notebook_edit"
    case opaqueChange = "opaque_change"
}

/// One immutable Git observation attached to an exact Conversation turn boundary.
struct ConversationRepositoryObservation: Equatable, Sendable, Identifiable {
    static let maximumTranscriptExcerptBytes = 4 * 1_024

    static func boundedTranscriptExcerpt(
        _ value: String
    ) -> (text: String, wasTruncated: Bool) {
        let bytes = Data(value.utf8)
        guard bytes.count > maximumTranscriptExcerptBytes else { return (value, false) }
        var end = maximumTranscriptExcerptBytes
        while end > 0 {
            if let text = String(data: bytes.prefix(end), encoding: .utf8) {
                return (text, true)
            }
            end -= 1
        }
        return ("", true)
    }

    let id: UUID
    let conversationID: UUID
    let turnID: String
    let toolUseID: String?
    let reason: ConversationRepositoryObservationReason
    /// Exact durable transcript edges when the capture boundary already knows them. They are not
    /// inferred by time or text matching; an expanded UI row may hydrate only these entry ids.
    let rootPromptEntryID: UUID?
    let finalAssistantEntryID: UUID?
    /// Exact bounded prefixes of the keyed entries, never generated summaries.
    let rootPromptExcerpt: String?
    let rootPromptExcerptWasTruncated: Bool?
    let finalAssistantExcerpt: String?
    let finalAssistantExcerptWasTruncated: Bool?
    /// Stable identity supplied by the Git probe for this canonical common directory.
    let repositoryID: String
    let gitCommonDirectory: String
    let worktreePath: String
    let workspaceID: UUID?
    let canonicalCWD: String?
    /// Nil when HEAD proof was unavailable. HEAD and status are independent Git observations: a
    /// status command can fail after `rev-parse` has already proved an attached/detached/unborn HEAD.
    let headState: ConversationRepositoryHeadState?
    /// Full symbolic ref such as `refs/heads/main`, never a shortened display branch.
    let symbolicRef: String?
    /// Full 40- or 64-character object id. Nil is honest for an unborn or unavailable HEAD.
    let headOID: String?
    let statusAvailability: ConversationRepositoryStatusAvailability
    /// Nil means status was unavailable; available status always carries all three counts.
    let indexChangeCount: Int?
    let worktreeChangeCount: Int?
    let untrackedCount: Int?
    /// Optional only because repository-boundary snapshots are mechanical observations rather
    /// than file attribution. Tool-completion capture may preserve the exact proof strength.
    let attribution: ConversationWorkAttribution?
    let observedAt: Date
}

/// One immutable path observation attached to its repository snapshot and exact tool edge.
struct ConversationFileObservation: Equatable, Sendable, Identifiable {
    static let maximumBoundedPatchBytes = 256 * 1_024

    let id: UUID
    let repositoryObservationID: UUID
    let conversationID: UUID
    let turnID: String
    /// Required for every file row, including an opaque delta observed around a shell tool.
    let toolUseID: String
    let repositoryID: String
    let repositoryRelativePath: String
    let operation: ConversationFileOperation
    let attribution: ConversationWorkAttribution
    /// SHA-256 of the directly named file when it existed and stayed below the capture ceiling.
    let beforeDigest: String?
    let afterDigest: String?
    /// Nil means capture could not prove existence. False requires the corresponding digest nil.
    let beforeExists: Bool?
    let afterExists: Bool?
    /// Bounded evidence supplied by the capture path. It is not a reconstruction of current bytes.
    let boundedPatch: String?
    let patchWasTruncated: Bool
    let observedAt: Date
}

/// Repository-first result shape used by Changes without hydrating Conversation transcripts.
struct ConversationWorkEvidence: Equatable, Sendable, Identifiable {
    var id: UUID { repository.id }
    let repository: ConversationRepositoryObservation
    let files: [ConversationFileObservation]
}

/// The exact authority facts removed with one reversible Conversation delete. Permanent deletion
/// never constructs this value; its evidence disappears with the Conversation's cascading rows.
struct LibraryAuthorityConversationDeleteResult: Equatable, Sendable {
    let committedSequence: Int64
    let workEvidence: [ConversationWorkEvidence]
}
