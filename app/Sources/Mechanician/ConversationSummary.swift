import Foundation

/// The transcript-free, rebuildable view of one Conversation needed by the sidebar.
///
/// This is deliberately an inert value: it carries display facts derived from the authoritative
/// Conversation file, never provider handles, executable waits, permission state, or transcript
/// payload. `projections.db` may cache these values and may be deleted at any time.
struct ConversationSummary: Identifiable, Equatable, Sendable {
    static let snippetCharacterLimit = 240

    var id: UUID
    var title: String

    /// The legacy working-directory hint used to resolve sidecars written before explicit
    /// Workspace membership. New projection schema uses the Workspace noun even though the
    /// authoritative sidecar field is still named `cwd`/`projectID` during migration.
    var workspaceCWD: String
    var workspaceID: UUID?

    var updatedAt: Date
    /// User + assistant rows only, matching the count shown in a sidebar row.
    var messageCount: Int
    /// One-line rendering of the latest user/assistant row; never the transcript itself.
    var snippet: String
    var hasUserMessage: Bool

    var favorite: Bool
    var sortIndex: Int?
    var unread: Bool
    var errored: Bool
    var awaitingQuestion: Bool

    /// Derived presentation facts only. The operative delegate, wait, and access-request state
    /// remains outside the projection and must be loaded before an action can execute.
    var hasRunningDelegate: Bool
    var providerAccessName: String?
    var armedWaitSummary: String?

    var displayTitle: String { title.isEmpty ? "New conversation" : title }

    /// Same total order as `ConversationStore.order`, available without hydrating Conversation.
    static func canonicalOrder(_ a: Self, _ b: Self) -> Bool {
        if a.favorite != b.favorite { return a.favorite }
        let ai = a.sortIndex ?? Int.max, bi = b.sortIndex ?? Int.max
        if ai != bi { return ai < bi }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.id.uuidString > b.id.uuidString
    }

    /// Derive the complete summary from the authoritative in-memory record. Keeping this in one
    /// initializer means the live store and the SQLite projection cannot disagree about row count,
    /// snippet selection, or inert status presentation.
    init(_ conversation: Conversation) {
        id = conversation.id
        title = conversation.title
        workspaceCWD = conversation.cwd
        workspaceID = conversation.projectID
        updatedAt = conversation.updatedAt

        var count = 0
        var foundUserMessage = false
        var latestDisplayMessage: TranscriptEntry?
        for message in conversation.messages
            where !message.isSuperseded
                && (message.kind == .user || message.kind == .assistant) {
            count += 1
            latestDisplayMessage = message
            if message.kind == .user { foundUserMessage = true }
        }
        messageCount = count
        hasUserMessage = foundUserMessage
        if let latestDisplayMessage {
            let prefix = latestDisplayMessage.kind == .user ? "You: " : ""
            let text = Self.boundedSnippetText(latestDisplayMessage.text)
            snippet = prefix + (text.isEmpty ? "…" : text)
        } else {
            snippet = "No messages yet"
        }

        favorite = conversation.favorite
        sortIndex = conversation.sortIndex
        unread = conversation.unread
        errored = conversation.errored
        awaitingQuestion = conversation.awaitingQuestion
        hasRunningDelegate = conversation.hasRunningDelegate
        providerAccessName = conversation.providerAccessRequest?.providerName
        armedWaitSummary = conversation.armedTrigger?.summary
    }

    /// Produce a one-line preview without ever copying or retaining an arbitrarily large message.
    /// Whitespace collapses as the row would visually collapse it, and one extra character is read
    /// only to decide whether the bounded result needs an ellipsis.
    private static func boundedSnippetText(_ raw: String) -> String {
        var characters: [Character] = []
        characters.reserveCapacity(snippetCharacterLimit + 1)
        var pendingSpace = false
        for character in raw {
            if character.isWhitespace {
                if !characters.isEmpty { pendingSpace = true }
                continue
            }
            if pendingSpace {
                characters.append(" ")
                pendingSpace = false
                if characters.count > snippetCharacterLimit { break }
            }
            characters.append(character)
            if characters.count > snippetCharacterLimit { break }
        }
        guard characters.count > snippetCharacterLimit else { return String(characters) }
        characters.removeLast(characters.count - snippetCharacterLimit + 1)
        characters.append("…")
        return String(characters)
    }

    /// Memberwise initializer retained for decoding the disposable SQLite row.
    init(
        id: UUID,
        title: String,
        workspaceCWD: String,
        workspaceID: UUID?,
        updatedAt: Date,
        messageCount: Int,
        snippet: String,
        hasUserMessage: Bool,
        favorite: Bool,
        sortIndex: Int?,
        unread: Bool,
        errored: Bool,
        awaitingQuestion: Bool,
        hasRunningDelegate: Bool,
        providerAccessName: String?,
        armedWaitSummary: String?
    ) {
        self.id = id
        self.title = title
        self.workspaceCWD = workspaceCWD
        self.workspaceID = workspaceID
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.snippet = snippet
        self.hasUserMessage = hasUserMessage
        self.favorite = favorite
        self.sortIndex = sortIndex
        self.unread = unread
        self.errored = errored
        self.awaitingQuestion = awaitingQuestion
        self.hasRunningDelegate = hasRunningDelegate
        self.providerAccessName = providerAccessName
        self.armedWaitSummary = armedWaitSummary
    }
}
