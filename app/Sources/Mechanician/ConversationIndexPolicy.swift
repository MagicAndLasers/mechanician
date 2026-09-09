import Foundation

/// How much of a transcript row goes into the conversation search index.
///
/// **The problem this solves.** `entry_fts` stored every row whole, so the index grew with the
/// VOLUME OF TOOL OUTPUT rather than with the number of messages. Measured on a real library:
/// 64,127 rows carrying 449.6 MB of text plus an 843 MB inverted index, where 510 rows (0.8%) held
/// 40% of the text and the largest single row was 1,049,025 characters. One `grep` could add as much
/// index as five hundred ordinary messages.
///
/// A per-entry cap changes the shape of that growth:
///
///     before:  size = Σ len(entry)              unbounded per entry
///     after:   size = Σ min(len(entry), cap)  ≤ rows × cap
///
/// The point is not that the average falls. It is that the marginal cost of one message acquires a
/// **ceiling**, so the total becomes predictable from message count alone. That is what makes
/// rebuild time, migration cost and disk use possible to reason about in advance.
///
/// **Why truncating here is safe.** `projections.db` is a disposable cache. `library.db` keeps every
/// complete transcript, so nothing is lost that cannot be recovered, and a person who needs a string
/// from the middle of a megabyte build log can still find it in the conversation itself.
///
/// **Why the head.** The identifying content leads. A tool row begins with its command or file path
/// and continues into bulk output, which was verified against the real index rather than assumed:
/// the five largest rows all began `{"command":"/bin/zsh -lc \"grep -R ...`. Truncating the tail
/// therefore keeps what people search for and drops what they do not.
enum ConversationIndexPolicy {

    /// Bumped whenever this policy would produce different text for the same conversation.
    ///
    /// Mixed into the content stamp, so changing a cap re-indexes every conversation exactly once,
    /// incrementally, in the background. Without it old rows indexed under a previous rule would sit
    /// beside new ones and the index would quietly mean two different things.
    ///
    /// Version 1 was the original uncapped behaviour.
    static let recipeVersion = 2

    /// Longer than any prompt a person types, so this is a safety bound rather than a cap.
    static let userCap = 4_000
    /// A long answer, kept whole.
    static let assistantCap = 8_000
    /// The command and path lead; the output is bulk.
    static let toolCap = 2_000
    /// Everything else is already short.
    static let defaultCap = 2_000

    static func cap(for kind: TranscriptEntry.Kind) -> Int {
        switch kind {
        case .user: userCap
        case .assistant: assistantCap
        case .tool: toolCap
        case .system, .permission, .question, .compaction, .review: defaultCap
        }
    }

    /// The indexed form of one composed transcript row.
    ///
    /// `String.prefix` rather than any byte slicing, so a cap can never split a character. A
    /// composed row that already fits is returned unchanged, including its identity, so the common
    /// case costs nothing.
    static func indexableText(_ composed: String, kind: TranscriptEntry.Kind) -> String {
        let limit = cap(for: kind)
        guard composed.count > limit else { return composed }
        return String(composed.prefix(limit))
    }
}
