import CryptoKit
import Foundation
import SQLite3

/// `projections.db` — the disposable search/summary projection of Conversation authority.
///
/// Authority rules (SQLite migration plan L1–L4): this database is a rebuildable PROJECTION of the
/// current Conversation authority — never an authority itself. During shadow and recognition builds
/// that authority remains the Conversation JSON sidecars; after the gated `library.db` activation,
/// exact SQLite inventory launches, committed `library.db` revisions feed it through a durable
/// outbox; Legacy-fallback launches retain the older successful-sidecar feed. The index may lag its
/// current authority but can never lead it. Deleting this file is never data loss; a schema-version
/// mismatch or corruption drops and rebuilds it. Exact SQLite launches disclose incomplete search
/// while rebuilding instead of decoding the Legacy corpus, while Legacy launches retain their
/// in-memory fallback. Authoritative local state belongs in `library.db`, whose lifecycle is
/// deliberately separate from this cache.
///
/// What it buys today: full-text search that covers TOOL OUTPUT (`toolResult` — measured at
/// roughly 82% of corpus text and invisible to the sidebar's substring scan over `text`), with
/// FTS5 speed instead of a linear scan of every decoded conversation. The summaries table is
/// maintained for the next slice's launch-paint work.
///
/// Threading: all SQLite access is confined to one serial utility queue. Legacy callers may fire
/// and forget; durable-library callers receive commit completion. Queries deliver on the main queue.
/// SQLite errors mark the store broken for the rest of the session; Legacy reads fall back in memory,
/// while exact SQLite reads disclose failed/incomplete search until the next launch rebuilds.
final class ConversationProjectionStore: @unchecked Sendable {


    /// Preserve the value snapshot while moving even its potentially large FTS materialization off
    /// the caller's file-publication path. A permission/answer response may resume the provider as
    /// soon as the authoritative file publishes; flattening a 10k-row transcript for SQLite must
    /// not delay that acknowledgement.
    private final class IndexInput: @unchecked Sendable {
        let conversation: Conversation
        init(_ conversation: Conversation) { self.conversation = conversation }
    }

    /// Summary-only authority commits (favorite, unread, title, ordering, wait state) must not
    /// retain or hash a corpus-sized transcript merely to repaint the sidebar.
    private final class SummaryInput: @unchecked Sendable {
        let summary: ConversationSummary
        init(_ summary: ConversationSummary) { self.summary = summary }
    }

    private struct PendingIndex {
        var input: IndexInput
        var sourceRevision: String
        var completions: [@MainActor @Sendable (Bool) -> Void]
    }

    private final class LibraryWorkInput: @unchecked Sendable {
        let conversation: Conversation?
        let entityID: UUID
        let sourceRevision: String
        let databaseInstanceID: UUID
        let desiredSequence: Int64
        let forceReindex: Bool

        init(
            conversation: Conversation?,
            entityID: UUID,
            sourceRevision: String,
            databaseInstanceID: UUID,
            desiredSequence: Int64,
            forceReindex: Bool
        ) {
            self.conversation = conversation
            self.entityID = entityID
            self.sourceRevision = sourceRevision
            self.databaseInstanceID = databaseInstanceID
            self.desiredSequence = desiredSequence
            self.forceReindex = forceReindex
        }
    }

    /// Immutable value snapshots captured on the main actor and consumed by the projection queue.
    /// `Conversation` is a COW value; wrapping the frozen array makes the intentional queue handoff
    /// explicit without doing a full-corpus record/materialization pass on the main actor.
    private final class ReconcileInput: @unchecked Sendable {
        let conversations: [Conversation]
        let sourceRevisions: [UUID: String]
        init(_ conversations: [Conversation], sourceRevisions: [UUID: String]) {
            self.conversations = conversations
            self.sourceRevisions = sourceRevisions
        }
    }

    /// Unknown schemas still drop and rebuild. Known additive migrations preserve already validated
    /// FTS bytes: adding a small memory-derived table must not re-tokenize a 500 MB conversation
    /// index.
    static let schemaVersion: Int32 = 16


    private let queue = DispatchQueue(label: "ai.mechanician.projection-io", qos: .utility)
    private let pendingIndexLock = NSLock()
    private var pendingIndexes: [UUID: PendingIndex] = [:]
    private var scheduledIndexIDs: Set<UUID> = []
    private let databaseURL: URL
    private let rebuildMarkerURL: URL
    private let rebuildBeforeOpen: Bool
    /// Queue-confined. nil after open failure → every operation is a silent no-op and every
    /// query answers nil (caller falls back to the in-memory scan).
    private var db: OpaquePointer?
    private var broken = false
    /// Queue-confined detail from the statement that retired this disposable cache. The authority
    /// worker persists it with the failed outbox row instead of replacing SQLite's useful diagnosis
    /// with a generic "transaction failed" message.
    private var lastFailureDiagnostics: String?

    static let rebuildMarkerName = "projections.db.rebuild-required"

    init(appSupportBase: URL, rebuildBeforeOpen: Bool = false) {
        databaseURL = appSupportBase.appendingPathComponent("projections.db", isDirectory: false)
        rebuildMarkerURL = appSupportBase.appendingPathComponent(
            Self.rebuildMarkerName,
            isDirectory: false)
        self.rebuildBeforeOpen = rebuildBeforeOpen
        queue.async { [self] in openOrRebuild() }
    }

    deinit {
        // Direct close (not via the queue — deinit must not capture self asynchronously).
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - Writes

    /// Legacy-fallback feed: upsert one conversation's summary row and FTS rows after its sidecar
    /// succeeds. Skipped when the content stamp is unchanged, so flag-only saves (favorite, unread)
    /// don't re-tokenize a 10k-row transcript.
    func index(
        _ conversation: Conversation,
        sourceRevision: String = "",
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        let input = IndexInput(conversation)
        let id = conversation.id
        pendingIndexLock.lock()
        if var pending = pendingIndexes[id] {
            pending.input = input
            pending.sourceRevision = sourceRevision
            if let completion { pending.completions.append(completion) }
            pendingIndexes[id] = pending
        } else {
            pendingIndexes[id] = PendingIndex(
                input: input,
                sourceRevision: sourceRevision,
                completions: completion.map { [$0] } ?? [])
        }
        let shouldSchedule = scheduledIndexIDs.insert(id).inserted
        pendingIndexLock.unlock()
        if shouldSchedule {
            queue.async { [self] in drainPendingIndexes(for: id) }
        }
    }

    /// Update the durable sidebar projection without claiming that FTS has caught up. Existing
    /// `content_stamp` and `source_revision` remain untouched; a new row starts deliberately
    /// unattested until ordinary transcript indexing follows.
    func indexSummary(
        _ summary: ConversationSummary,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        let input = SummaryInput(summary)
        queue.async { [self] in
            let succeeded = db != nil && !broken && transaction {
                upsertSummaryOnly(input.summary, sourceRevision: nil)
            }
            if let completion {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { completion(succeeded) }
                }
            }
        }
    }

    func remove(
        _ id: UUID,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        let key = id.uuidString
        queue.async { [self] in
            guard db != nil, !broken else {
                if let completion {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { completion(false) }
                    }
                }
                return
            }
            let succeeded = transaction {
                run("DELETE FROM summaries WHERE id = ?1", bind: { bind($0, 1, key) })
                    && run(
                        "DELETE FROM entry_fts WHERE conversation_id = ?1",
                        bind: { bind($0, 1, key) })
            }
            if let completion {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { completion(succeeded) }
                }
            }
        }
    }







    /// Apply one durable library outbox job. The entity row/FTS rows and the database-instance/
    /// sequence binding commit together; a false completion must never be acknowledged in
    /// `library.db`. Reapplying the same job after a crash is intentionally idempotent.
    func applyLibraryWork(
        conversation: Conversation?,
        entityID: UUID,
        sourceRevision: String,
        databaseInstanceID: UUID,
        desiredSequence: Int64,
        forceReindex: Bool = false,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        applyLibraryWorkWithDiagnostics(
            conversation: conversation,
            entityID: entityID,
            sourceRevision: sourceRevision,
            databaseInstanceID: databaseInstanceID,
            desiredSequence: desiredSequence,
            forceReindex: forceReindex
        ) { succeeded, _ in
            completion(succeeded)
        }
    }

    /// Diagnostic-reporting form used by the durable authority worker. The callback stays on the
    /// projection queue, just like `applyLibraryWork`, so the worker can serialize acknowledgement,
    /// recovery, and retry without blocking the main actor.
    func applyLibraryWorkWithDiagnostics(
        conversation: Conversation?,
        entityID: UUID,
        sourceRevision: String,
        databaseInstanceID: UUID,
        desiredSequence: Int64,
        forceReindex: Bool = false,
        completion: @escaping @Sendable (Bool, String?) -> Void
    ) {
        let input = LibraryWorkInput(
            conversation: conversation,
            entityID: entityID,
            sourceRevision: sourceRevision,
            databaseInstanceID: databaseInstanceID,
            desiredSequence: desiredSequence,
            forceReindex: forceReindex)
        queue.async { [self] in
            guard db != nil, !broken else {
                completion(
                    false,
                    lastFailureDiagnostics ?? "projections.db is unavailable for this session")
                return
            }
            lastFailureDiagnostics = nil
            let succeeded = transaction {
                guard prepareLibraryBinding(input.databaseInstanceID) else { return false }
                if let conversation = input.conversation {
                    // A queued summary-only mutation may legitimately reuse existing FTS rows,
                    // but a missing/rebuilt projections.db has no rows to reuse. Treat absence of
                    // the entity's content stamp as an implicit full replay so a disposable-cache
                    // rebuild cannot finish "current" with an empty search index.
                    if input.forceReindex || stamp(for: input.entityID.uuidString) == nil {
                        let record = Self.record(
                            for: conversation,
                            sourceRevision: input.sourceRevision)
                        guard upsertStatements(record, reindexEntries: true) else { return false }
                    } else {
                        guard upsertSummaryOnly(
                            ConversationSummary(conversation),
                            sourceRevision: input.sourceRevision) else { return false }
                    }
                } else {
                    let key = input.entityID.uuidString
                    guard run(
                        "DELETE FROM summaries WHERE id = ?1",
                        bind: { bind($0, 1, key) }),
                          run(
                            "DELETE FROM entry_fts WHERE conversation_id = ?1",
                            bind: { bind($0, 1, key) }) else { return false }
                }
                return true
            }
            completion(succeeded, succeeded ? nil : lastFailureDiagnostics)
        }
    }

    /// Bind already-existing rows only after the caller proved their complete closed set and exact
    /// source revisions against one library launch bundle. This migrates A2b1's trustworthy v4
    /// projection without re-tokenizing 500 MB of unchanged transcript data.
    func bindExactLibrarySnapshot(
        databaseInstanceID: UUID,
        appliedSequence: Int64,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async { [self] in
            guard db != nil, !broken else { completion(false); return }
            completion(transaction {
                guard prepareLibraryBinding(databaseInstanceID, preserveValidatedRows: true) else {
                    return false
                }
                return writeLibraryBinding(
                    databaseInstanceID: databaseInstanceID,
                    appliedSequence: appliedSequence)
            })
        }
    }

    /// Close a replay pass by deleting cache-only orphans and publishing the exact library frontier
    /// in the same projection transaction.
    func finalizeLibraryCatchUp(
        _ frontier: ShadowLibraryProjectionFrontier,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async { [self] in
            guard db != nil, !broken else { completion(false); return }
            completion(transaction {
                guard prepareLibraryBinding(frontier.databaseInstanceID) else { return false }
                let live = Set(frontier.liveConversationIDs.map(\.uuidString))
                for orphan in allProjectionIDs().subtracting(live) {
                    guard run(
                        "DELETE FROM summaries WHERE id = ?1",
                        bind: { bind($0, 1, orphan) }),
                          run(
                            "DELETE FROM entry_fts WHERE conversation_id = ?1",
                            bind: { bind($0, 1, orphan) }) else { return false }
                }
                return writeLibraryBinding(
                    databaseInstanceID: frontier.databaseInstanceID,
                    appliedSequence: frontier.shadowChangeSequence)
            })
        }
    }

    /// Launch reconciliation: index new/changed conversations, drop rows whose conversation no
    /// longer exists. This is also the whole rebuild path after a drop — the projection's only
    /// recovery story is "read the authoritative store again."
    func reconcile(
        with conversations: [Conversation],
        sourceRevisions: [UUID: String] = [:]
    ) {
        reconcile(with: conversations, sourceRevisions: sourceRevisions) { _ in }
    }

    /// Completion-reporting form used by launch gates. The callback runs on the main actor only
    /// after every queued reconciliation statement has completed. `false` means the disposable
    /// projection failed closed for this session; callers must retain their authoritative-file
    /// fallback and may retry by rebuilding on a later launch.
    func reconcile(
        with conversations: [Conversation],
        sourceRevisions: [UUID: String] = [:],
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let input = ReconcileInput(conversations, sourceRevisions: sourceRevisions)
        queue.async { [self] in
            guard db != nil, !broken else {
                // One more queue turn releases the captured full-corpus input before the store
                // receives the activation edge and evicts its own references.
                queue.async { Task { @MainActor in completion(false) } }
                return
            }
            // Do not materialize the whole corpus's FTS strings at once. The authoritative input
            // already holds every decoded record during recovery; creating a second array of all
            // transcript/tool-output strings can preserve the very RSS spike bounded residency is
            // meant to retire. Build, upsert, and release one projection record at a time.
            let live = Set(input.conversations.map { $0.id.uuidString })
            for orphan in allProjectionIDs().subtracting(live) {
                _ = transaction {
                    run("DELETE FROM summaries WHERE id = ?1", bind: { bind($0, 1, orphan) })
                        && run(
                            "DELETE FROM entry_fts WHERE conversation_id = ?1",
                            bind: { bind($0, 1, orphan) })
                }
            }
            for conversation in input.conversations {
                autoreleasepool {
                    let record = Self.record(
                        for: conversation,
                        sourceRevision: input.sourceRevisions[conversation.id] ?? "")
                    // Summary-only facts (unread, wait state, Workspace resolution) must refresh
                    // even when transcript bytes are unchanged. Only FTS tokenization is gated.
                    upsert(record, reindexEntries: stamp(for: record.id) != record.contentStamp)
                }
            }
            let succeeded = !broken
            // Do not deliver while this closure still retains `input.conversations`: bounded
            // eviction would remove only the store's copy and leave the entire graph alive here.
            queue.async { Task { @MainActor in completion(succeeded) } }
        }
    }

    // MARK: - Search

    /// One matching conversation, with how well it matched and the text that matched.
    struct SearchHit: Sendable, Equatable {
        let id: UUID
        /// FTS5 `bm25()`. Negative, and **more negative is a better match** — that is SQLite's
        /// convention, not a mistake, so ascending order is best-first.
        let score: Double
        /// nil when the match sits past the fetched content window; see `SearchExcerpt`.
        let excerpt: String?
    }

    /// How many ranked entries are considered before collapsing to one row per conversation.
    ///
    /// Entries, not conversations: a single conversation can own many matching entries, so this
    /// has to be comfortably larger than the library's conversation count. Measured at 400 on a
    /// 64,127-entry index, the worst common term ranks in 0.17 s.
    static let rankedEntryLimit = 400

    /// Conversations matching `query`, best first, with the text that matched.
    ///
    /// Two queries on purpose. Ranking and excerpting in one statement is the pathological case:
    /// `ORDER BY bm25()` with `snippet()` in the same SELECT measured **15 seconds** for a common
    /// prefix term, because ranking makes the query re-seek every output row to find the tokens.
    /// Ranking alone is 0.17 s and fetching content by rowid is 0.01 s, so the two are kept apart
    /// and the excerpt is cut in Swift.
    func searchConversations(
        matching query: String,
        completion: @escaping @MainActor @Sendable ([SearchHit]?) -> Void
    ) {
        guard let match = Self.ftsQuery(from: query) else {
            Task { @MainActor in completion([]) }
            return
        }
        let terms = Self.searchTerms(from: query)
        queue.async { [self] in
            guard db != nil, !broken else {
                Task { @MainActor in completion(nil) }
                return
            }
            // Phase 1: rank, and keep only the best-scoring entry per conversation.
            var order: [UUID] = []
            var bestRow: [UUID: (rowid: Int64, score: Double)] = [:]
            var ok = run(
                """
                SELECT rowid, conversation_id, bm25(entry_fts) FROM entry_fts
                WHERE entry_fts MATCH ?1 ORDER BY bm25(entry_fts) LIMIT ?2
                """,
                bind: { bind($0, 1, match); bind($0, 2, Self.rankedEntryLimit) },
                row: { statement in
                    guard let raw = sqlite3_column_text(statement, 1),
                          let id = UUID(uuidString: String(cString: raw)) else { return }
                    let score = sqlite3_column_double(statement, 2)
                    // Rows arrive best-first, so the first sighting of a conversation is its best.
                    if bestRow[id] == nil {
                        bestRow[id] = (sqlite3_column_int64(statement, 0), score)
                        order.append(id)
                    }
                })

            // Phase 2: content for those rows only, by rowid and without MATCH, which is the part
            // that stays cheap. Capped because entries reach a megabyte.
            var excerpts: [UUID: String] = [:]
            if ok, !order.isEmpty {
                for id in order {
                    guard let row = bestRow[id] else { continue }
                    var content = ""
                    ok = run(
                        "SELECT substr(content, 1, ?2) FROM entry_fts WHERE rowid = ?1",
                        bind: { bind($0, 1, Int(row.rowid)); bind($0, 2, SearchExcerpt.contentWindow) },
                        row: { statement in
                            if let raw = sqlite3_column_text(statement, 0) {
                                content = String(cString: raw)
                            }
                        })
                    guard ok else { break }
                    if let excerpt = SearchExcerpt.make(from: content, matching: terms) {
                        excerpts[id] = excerpt
                    }
                }
            }

            let hits = order.compactMap { id -> SearchHit? in
                guard let row = bestRow[id] else { return nil }
                return SearchHit(id: id, score: row.score, excerpt: excerpts[id])
            }
            let result: [SearchHit]? = ok ? hits : nil
            Task { @MainActor in completion(result) }
        }
    }

    /// The raw words a query asked for, for locating the match inside content. Kept beside
    /// `ftsQuery` so the terms searched and the terms highlighted cannot drift apart.
    static func searchTerms(from text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
    }

    /// Conversation ids whose content matches `query` (prefix-matched, all terms required),
    /// delivered on the main queue. nil = index unavailable → the caller must fall back to its
    /// in-memory scan. An empty query answers an empty set immediately.
    func searchConversationIDs(
        matching query: String,
        completion: @escaping @MainActor @Sendable (Set<UUID>?) -> Void
    ) {
        guard let match = Self.ftsQuery(from: query) else {
            Task { @MainActor in completion([]) }
            return
        }
        queue.async { [self] in
            guard db != nil, !broken else {
                Task { @MainActor in completion(nil) }
                return
            }
            var ids = Set<UUID>()
            let ok = run(
                "SELECT DISTINCT conversation_id FROM entry_fts WHERE entry_fts MATCH ?1",
                bind: { bind($0, 1, match) },
                row: { statement in
                    if let raw = sqlite3_column_text(statement, 0),
                       let id = UUID(uuidString: String(cString: raw)) {
                        ids.insert(id)
                    }
                })
            let result: Set<UUID>? = ok ? ids : nil
            Task { @MainActor in completion(result) }
        }
    }

    /// Sanitize free text into an FTS5 MATCH expression: every whitespace-separated token is
    /// double-quoted (operators like NEAR/AND/OR/- become literals) with embedded quotes doubled,
    /// and prefix-matched so type-ahead behaves like the substring search users already know.
    static func ftsQuery(from text: String) -> String? {
        let tokens = text
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// The same text as a QUESTION rather than as something being typed into a search box.
    ///
    /// Two differences from `ftsQuery`, and both were measured against a real 272-claim library
    /// before being written:
    ///
    /// **Tokens are OR'd, not AND'd.** FTS5 treats a space as an implicit AND, which is right for
    /// type-ahead — every keystroke should narrow. It is wrong for a question, because a model asks
    /// "how does David want the wiki built" and no single statement contains all six words. Measured:
    /// that query returned 0 of 272 claims while the single word "AppKit" returned matches, so recall
    /// looked wired and working and answered "Nothing remembered about that" to every real question.
    /// BM25 is what makes OR safe: a claim matching four terms outranks one matching one, and the
    /// caller takes the top few.
    ///
    /// **The page summary is excluded.** It is a derived paragraph shared by every claim on the page,
    /// so any word in it makes the whole page match. Measured: "AppKit" matched 144 of 272 claims
    /// across all columns and 9 in the statement bodies — the other 135 arrived because a summary
    /// somewhere mentioned it, which is how a question about AppKit came back holding "LinkedIn is
    /// the only social network the user participates in". Title and aliases stay: a page name is
    /// short, deliberate, and matching one is the strong evidence the ranking weights already say it
    /// is.
    static func ftsQuestion(from text: String) -> String? {
        let tokens = text
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        let terms = tokens.map { "\"\($0)\"*" }.joined(separator: " OR ")
        return "{title aliases body} : (\(terms))"
    }

    // MARK: - Record shape

    struct Record {
        var summary: ConversationSummary
        var contentStamp: String
        /// Exact authoritative-file generation paired with this summary and FTS transaction.
        /// Empty values remain useful as a cache but can never attest a SQLite inventory launch.
        var sourceRevision: String
        /// One string per indexed entry: text, tool name/output, and a labeled Claude continuity
        /// summary when a compaction boundary retained one — the fields a human would expect ⌥⌘F
        /// to find. Delegate-internal transcripts are deliberately out of scope for schema v1 (a
        /// bump + rebuild adds them later; the file is disposable).
        var entries: [String]

        var id: String { summary.id.uuidString }
    }

    static func record(for c: Conversation, sourceRevision: String = "") -> Record {
        var entries: [String] = []
        entries.reserveCapacity(c.messages.count)
        var contentDigest = SHA256()
        for message in c.messages where !message.isSuperseded {
            var parts = message.text
            if let name = message.toolName { parts += "\n" + name }
            if let result = message.toolResult { parts += "\n" + result }
            if message.kind == .compaction,
               message.compactionSummarySource == "claude_post_compact",
               let summary = message.compactionSummary?.trimmingCharacters(
                in: .whitespacesAndNewlines),
               !summary.isEmpty {
                parts += "\nClaude continuity summary\n" + summary
            }
            let bytes = Data(parts.utf8)
            var byteCount = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &byteCount) { contentDigest.update(data: Data($0)) }
            contentDigest.update(data: bytes)
            // Index a bounded prefix, not the whole row. The digest above still covers the COMPLETE
            // text, so a change beyond the cap still re-indexes; erring toward extra work rather
            // than toward a stale index.
            let indexed = ConversationIndexPolicy.indexableText(parts, kind: message.kind)
            if !indexed.isEmpty { entries.append(indexed) }
        }
        // The recipe version is part of the stamp, so changing a cap invalidates every conversation
        // and each re-indexes once in the background. Without this, rows written under two different
        // policies would coexist and the index would mean two different things.
        contentDigest.update(data: Data("index-recipe-\(ConversationIndexPolicy.recipeVersion)".utf8))
        // A real content digest catches equal-byte replacements (`failed` → `passed`) that the old
        // count/last-id/byte-total stamp missed forever. Length-prefixing each entry prevents two
        // different row boundaries from producing the same input stream; flag-only saves still
        // skip FTS retokenization.
        let stamp = contentDigest.finalize().map { String(format: "%02x", $0) }.joined()
        return Record(
            summary: ConversationSummary(c),
            contentStamp: stamp,
            sourceRevision: sourceRevision,
            entries: entries)
    }

    /// Typed, transcript-free sidebar rows. A nil/blank query returns the complete canonical list;
    /// a query filters by title plus the transcript/tool-output FTS projection. This lets a caller
    /// paint and search the sidebar without constructing placeholder `Conversation` values.
    func summaries(
        matching query: String? = nil,
        completion: @escaping @MainActor @Sendable ([ConversationSummary]) -> Void
    ) {
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let match = Self.ftsQuery(from: trimmedQuery)
        queue.async { [self] in
            guard db != nil, !broken else {
                Task { @MainActor in completion([]) }
                return
            }
            var contentMatches = Set<UUID>()
            var ok = true
            if let match {
                ok = run(
                    "SELECT DISTINCT conversation_id FROM entry_fts WHERE entry_fts MATCH ?1",
                    bind: { bind($0, 1, match) },
                    row: { statement in
                        if let raw = sqlite3_column_text(statement, 0),
                           let id = UUID(uuidString: String(cString: raw)) {
                            contentMatches.insert(id)
                        }
                    })
            }
            var rows = ok ? readSummaries() : []
            if !trimmedQuery.isEmpty {
                rows = rows.filter {
                    $0.displayTitle.localizedCaseInsensitiveContains(trimmedQuery)
                        || contentMatches.contains($0.id)
                }
            }
            rows.sort(by: ConversationSummary.canonicalOrder)
            let result = broken ? [] : rows
            Task { @MainActor in completion(result) }
        }
    }

    /// Compatibility for the first launch-paint slice. New callers should consume
    /// `ConversationSummary` directly through `summaries(matching:completion:)`.
    typealias LaunchSummary = ConversationSummary

    func launchSummaries(
        completion: @escaping @MainActor @Sendable ([LaunchSummary]) -> Void
    ) {
        summaries(completion: completion)
    }

    /// Prove that this disposable database can safely answer search for an exact authoritative
    /// inventory. Summary and FTS rows publish in the same transaction, so equality of every
    /// persisted summary field and the closed id set is the cheap launch receipt for that commit.
    /// Live-only presentation flags are intentionally excluded because this projection never
    /// persists them. A mismatch leaves the exact SQLite inventory in place and activates durable
    /// library-outbox catch-up; only content search is temporarily disclosed as incomplete.
    func matchesAuthoritativeInventory(
        _ authoritative: [ConversationSummary],
        sourceRevisions: [UUID: String],
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        queue.async { [self] in
            guard db != nil, !broken else {
                Task { @MainActor in completion(false) }
                return
            }
            let projected = readSummaries()
            let projectedByID = Dictionary(uniqueKeysWithValues: projected.map { ($0.id, $0) })
            let projectedRevisions = readSourceRevisions()
            let authoritativeIDs = Set(authoritative.map(\.id.uuidString))
            let matches = !broken
                && projectedByID.count == authoritative.count
                && sourceRevisions.count == authoritative.count
                && allFTSConversationIDs().isSubset(of: authoritativeIDs)
                && authoritative.allSatisfy { expected in
                    guard let actual = projectedByID[expected.id],
                          let expectedRevision = sourceRevisions[expected.id],
                          !expectedRevision.isEmpty,
                          projectedRevisions[expected.id] == expectedRevision else { return false }
                    return Self.persistedSummaryFieldsMatch(actual, expected)
                }
            Task { @MainActor in completion(matches) }
        }
    }

    private static func persistedSummaryFieldsMatch(
        _ lhs: ConversationSummary,
        _ rhs: ConversationSummary
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.workspaceCWD == rhs.workspaceCWD
            && lhs.workspaceID == rhs.workspaceID
            // Incremental shadow capture may retain an in-memory sub-millisecond value while a
            // later projection rebuild decodes the exact legacy JSON milliseconds. The source
            // generation above proves both rows describe the same bytes, so compare the actual
            // encoding quantum rather than Foundation's hidden Date remainder.
            && SendableISO8601Formatter.fractional.string(from: lhs.updatedAt)
                == SendableISO8601Formatter.fractional.string(from: rhs.updatedAt)
            && lhs.messageCount == rhs.messageCount
            && lhs.snippet == rhs.snippet
            && lhs.hasUserMessage == rhs.hasUserMessage
            && lhs.favorite == rhs.favorite
            && lhs.sortIndex == rhs.sortIndex
            && lhs.unread == rhs.unread
            && lhs.errored == rhs.errored
            && lhs.providerAccessName == rhs.providerAccessName
            && lhs.armedWaitSummary == rhs.armedWaitSummary
    }

    // MARK: - Queue-confined plumbing

    private func drainPendingIndexes(for id: UUID) {
        while true {
            pendingIndexLock.lock()
            let pending = pendingIndexes.removeValue(forKey: id)
            if pending == nil { scheduledIndexIDs.remove(id) }
            pendingIndexLock.unlock()
            guard let pending else { return }

            let succeeded: Bool
            if db != nil, !broken {
                let record = Self.record(
                    for: pending.input.conversation,
                    sourceRevision: pending.sourceRevision)
                succeeded = upsert(
                    record,
                    reindexEntries: stamp(for: record.id) != record.contentStamp)
            } else {
                succeeded = false
            }
            if !pending.completions.isEmpty {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        for completion in pending.completions { completion(succeeded) }
                    }
                }
            }
        }
    }

    private func openOrRebuild() {
        let markerExists = FileManager.default.fileExists(atPath: rebuildMarkerURL.path)
        if rebuildBeforeOpen || markerExists {
            rebuildRequiredProjection(markerAlreadyExists: markerExists)
            return
        }

        if openDatabase(), !broken, verifySchema(), !broken {
            guard !broken else {
                rebuildRequiredProjection(markerAlreadyExists: true)
                return
            }
            lastFailureDiagnostics = nil
            return
        }

        // Anything wrong with a disposable cache has exactly one remedy, but it happens only at
        // open. A runtime failure remains terminal for that process so Conversation and Memory
        // readers keep falling back instead of observing an empty or partially replayed cache.
        rebuildRequiredProjection(
            markerAlreadyExists: FileManager.default.fileExists(atPath: rebuildMarkerURL.path))
    }

    /// Delete and recreate the complete shared projection cache before any queued reader can use
    /// it. The marker survives every incomplete attempt, including a process exit between deleting
    /// the database and creating its schema. It is cleared only after the fresh schema and the
    /// receipt snapshot have both been read successfully.
    private func rebuildRequiredProjection(markerAlreadyExists: Bool) {
        if !markerAlreadyExists, !markRebuildRequired() {
            broken = true
            return
        }
        guard closeAndDeleteRequiringSuccess() else { return }

        broken = false
        lastFailureDiagnostics = nil
        guard openDatabase(), !broken, verifySchema(), !broken else {
            broken = true
            _ = markRebuildRequired()
            closeDatabase()
            return
        }
        guard !broken else {
            _ = markRebuildRequired()
            closeDatabase()
            return
        }
        guard clearRebuildMarker() else {
            broken = true
            closeDatabase()
            return
        }
        lastFailureDiagnostics = nil
    }

    private func openDatabase() -> Bool {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? String(cString: sqlite3_errstr(result))
            lastFailureDiagnostics = Self.sqliteFailureDiagnostics(
                operation: "open", code: result, message: message)
            if let handle { sqlite3_close_v2(handle) }
            return false
        }
        db = handle
        // A cache needs no durability: NORMAL keeps WAL cheap, and a torn write just means a
        // rebuild on the next open.
        _ = run("PRAGMA journal_mode=WAL")
        _ = run("PRAGMA synchronous=NORMAL")
        return true
    }

    private func verifySchema() -> Bool {
        guard db != nil else { return false }
        var version: Int32 = -1
        _ = run("PRAGMA user_version", row: { version = sqlite3_column_int($0, 0) })
        if version == 0 {
            // Fresh file: create the schema. FTS5 availability is proven here at runtime; a
            // system SQLite without it just leaves the store broken and every caller on the
            // in-memory fallback.
            guard run("""
                CREATE TABLE IF NOT EXISTS summaries (
                  id TEXT PRIMARY KEY,
                  title TEXT NOT NULL,
                  workspace_cwd TEXT NOT NULL DEFAULT '',
                  workspace_id TEXT,
                  updated_at REAL NOT NULL,
                  message_count INTEGER NOT NULL,
                  snippet TEXT NOT NULL,
                  has_user_message INTEGER NOT NULL DEFAULT 0,
                  favorite INTEGER NOT NULL DEFAULT 0,
                  sort_index INTEGER,
                  unread INTEGER NOT NULL DEFAULT 0,
                  errored INTEGER NOT NULL DEFAULT 0,
                  provider_access_name TEXT,
                  armed_wait_summary TEXT,
                  content_stamp TEXT NOT NULL,
                  source_revision TEXT NOT NULL
                )
                """),
                run("""
                CREATE VIRTUAL TABLE IF NOT EXISTS entry_fts USING fts5(
                  conversation_id UNINDEXED,
                  content,
                  tokenize='unicode61 remove_diacritics 2'
                )
                """),
                run("""
                CREATE TABLE IF NOT EXISTS library_binding (
                  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                  database_instance_id TEXT,
                  applied_sequence INTEGER NOT NULL DEFAULT 0 CHECK (applied_sequence >= 0)
                )
                """),
                run("""
                INSERT OR IGNORE INTO library_binding (
                  singleton, database_instance_id, applied_sequence)
                VALUES (1, NULL, 0)
                """),
                run("PRAGMA user_version = \(Self.schemaVersion)")
            else { return false }
            return reclaimAfterMigration()
        }
        // v16 drops the retired memory, Memrank and learning-observation tables.
        //
        // **It does NOT discard the conversation index**, and that is the whole reason
        // `discardPreCapConversationIndex()` had to stop being inherited: nothing about dropping
        // these tables invalidates a single indexed transcript row, and re-tokenizing 212,509
        // events to remove a table nothing reads would be minutes of work for nothing. A v15 cache
        // keeps its index, its library binding and its applied sequence, and loses only the tables.
        if version == 15 {
            guard transaction({
                guard dropRetiredMemoryObjects(),
                      run("PRAGMA user_version = \(Self.schemaVersion)")
                else { return false }
                return true
            }) else { return false }
            return reclaimAfterMigration()
        }
        // v15 discards the pre-cap conversation index and reclaims the disk; v14 additionally
        // creates the learning-observation table. Both preserve the library binding.
        //
        // **v14 MUST be listed here.** 0.26.43 shipped `schemaVersion = 14`, so it is the version
        // most existing installs are actually on. Without this rung a v14 cache matches nothing,
        // falls through to the equality check at the end, and `openOrRebuild` deletes the whole
        // file: not data loss, since everything here is derived, but a full memory profile re-read
        // for every user, which is exactly the cost this design exists to avoid. It shipped that
        // way in 0.26.44 and was caught by testing the release rather than by any test.
        if version == 13 || version == 14 {
            guard transaction({
                guard createLatestAdditiveObjects(),
                      discardPreCapConversationIndex(),
                      dropRetiredMemoryObjects(),
                      run("PRAGMA user_version = \(Self.schemaVersion)")
                else { return false }
                return true
            }) else { return false }
            return reclaimAfterMigration()
        }
        // v13 adds the content-free activity-coordinate fence to the two disposable Memrank
        // tables. Preserve the expensive Conversation FTS and its library binding, but discard
        // the old graph and dormancy rows: a v12 graph could not prove which ordinary user turns
        // participated in its activity windows. The all-zero transitional default exists only so
        // SQLite can add a nonnull column in place before those rows are cleared.
        if version == 12 {
            guard transaction({
                guard run(
                    """
                    ALTER TABLE memrank_graph_generation
                    ADD COLUMN activity_signature TEXT NOT NULL
                      DEFAULT '0000000000000000000000000000000000000000000000000000000000000000'
                      CHECK (length(activity_signature) = 64)
                    """),
                      run(
                    """
                    ALTER TABLE memrank_context_dormancy
                    ADD COLUMN activity_signature TEXT NOT NULL
                      DEFAULT '0000000000000000000000000000000000000000000000000000000000000000'
                      CHECK (length(activity_signature) = 64)
                    """),
                      run("DELETE FROM memrank_graph_generation"),
                      run("DELETE FROM memrank_context_dormancy"),
                      createLatestAdditiveObjects(),
                      discardPreCapConversationIndex(),
                      dropRetiredMemoryObjects(),
                      run("PRAGMA user_version = \(Self.schemaVersion)")
                else { return false }
                return true
            }) else { return false }
            return reclaimAfterMigration()
        }
        // v12 adds only content-free, disposable Memrank context-dormancy state. Existing graph
        // and Conversation FTS bytes remain valid; a missing state row means every edge is active.
        if version == 11 {
            guard transaction({
                // The v11 graph has no activity fence. Preserve FTS and the library binding, but
                // discard that single disposable graph while adding the v13 column in place.
                // Creating v13 dormancy from scratch is safe because v11 had none.
                guard run(
                    """
                    ALTER TABLE memrank_graph_generation
                    ADD COLUMN activity_signature TEXT NOT NULL
                      DEFAULT '0000000000000000000000000000000000000000000000000000000000000000'
                      CHECK (length(activity_signature) = 64)
                    """),
                      run("DELETE FROM memrank_graph_generation"),
                      run(Self.memrankContextDormancyStatement),
                      createLatestAdditiveObjects(),
                      discardPreCapConversationIndex(),
                      dropRetiredMemoryObjects(),
                      run("PRAGMA user_version = \(Self.schemaVersion)")
                else { return false }
                return true
            }) else { return false }
            return reclaimAfterMigration()
        }
        // v11 adds one content-free, disposable Memrank graph generation. It is deliberately
        // independent of the Conversation FTS binding: both derive from the same authority clock,
        // but either cache may rebuild while the other remains usable.
        if version == 10 {
            guard transaction({
                guard run(Self.memrankGraphGenerationStatement),
                      run(Self.memrankContextDormancyStatement),
                      createLatestAdditiveObjects(),
                      discardPreCapConversationIndex(),
                      dropRetiredMemoryObjects(),
                      run("PRAGMA user_version = \(Self.schemaVersion)")
                else { return false }
                return true
            }) else { return false }
            return reclaimAfterMigration()
        }
        // v10 adds only a bounded, disposable observation journal. Preserve the expensive FTS and
        // existing library binding while starting the journal empty.
        if version == 9 {
            guard transaction({
                guard run(Self.memrankShadowJournalStatement),
                      run(Self.memrankGraphGenerationStatement),
                      run(Self.memrankContextDormancyStatement),
                      createLatestAdditiveObjects(),
                      discardPreCapConversationIndex(),
                      dropRetiredMemoryObjects(),
                      run("PRAGMA user_version = \(Self.schemaVersion)")
                else { return false }
                return true
            }) else { return false }
            return reclaimAfterMigration()
        }
        // v9 gains only small memory-safety caches. They are derived from authoritative memory
        // claims and starts empty, so adding it in place preserves the unrelated conversation FTS
        // bytes rather than forcing a full replay to create one small table.
        if version == 8 {
            guard transaction({
                guard run(Self.memoryRelationshipVerdictStatement),
                      run(Self.memorySummaryReceiptStatement),
                      run(Self.memrankShadowJournalStatement),
                      run(Self.memrankGraphGenerationStatement),
                      run(Self.memrankContextDormancyStatement),
                      createLatestAdditiveObjects(),
                      discardPreCapConversationIndex(),
                      dropRetiredMemoryObjects(),
                      run("PRAGMA user_version = \(Self.schemaVersion)")
                else { return false }
                return true
            }) else { return false }
            return reclaimAfterMigration()
        }
        // v7 gains only the build watermark, empty and rebuilt on demand. In place for the same
        // reason as every step below it.
        if version == 7 {
            guard transaction({
                guard run(Self.memoryBuildSeenStatement),
                      run(Self.memoryRelationshipVerdictStatement),
                      run(Self.memorySummaryReceiptStatement),
                      run(Self.memrankShadowJournalStatement),
                      run(Self.memrankGraphGenerationStatement),
                      run(Self.memrankContextDormancyStatement),
                      createLatestAdditiveObjects(),
                      discardPreCapConversationIndex(),
                      dropRetiredMemoryObjects(),
                      run("PRAGMA user_version = \(Self.schemaVersion)")
                else { return false }
                return true
            }) else { return false }
            return reclaimAfterMigration()
        }
        // v6 gains only the memory VECTOR table, empty and rebuilt from library.db on demand. In
        // place for the same reason as every step below it: dropping the file would rebuild a
        // 500 MB conversation index to add a table that has nothing to do with conversations.
        if version == 6 {
            guard transaction({
                guard run(Self.memoryVectorStatement),
                run(Self.memoryEntitySummaryStatement),
                run(Self.memoryRelationshipVerdictStatement),
                run(Self.memorySummaryReceiptStatement),
                run(Self.memrankShadowJournalStatement),
                run(Self.memrankGraphGenerationStatement),
                run(Self.memrankContextDormancyStatement),
                      createLatestAdditiveObjects(),
                      discardPreCapConversationIndex(),
                      dropRetiredMemoryObjects(),
                      run("PRAGMA user_version = \(Self.schemaVersion)")
                else { return false }
                return true
            }) else { return false }
            return reclaimAfterMigration()
        }
        // v5 gains only the memory index, which starts empty and is rebuilt from library.db on
        // demand. Creating it in place keeps the conversation index untouched, for the same reason
        // the v4 step preserves its rows: a 500 MB FTS rebuild is not an acceptable upgrade cost
        // for a table that has nothing to do with conversations.
        if version == 5 {
            guard transaction({
                guard run(Self.memoryIndexStatement),
                run(Self.memoryVectorStatement),
                run(Self.memoryEntitySummaryStatement),
                run(Self.memoryBuildSeenStatement),
                run(Self.memoryRelationshipVerdictStatement),
                run(Self.memorySummaryReceiptStatement),
                run(Self.memrankShadowJournalStatement),
                run(Self.memrankGraphGenerationStatement),
                run(Self.memrankContextDormancyStatement),
                      createLatestAdditiveObjects(),
                      discardPreCapConversationIndex(),
                      dropRetiredMemoryObjects(),
                      run("PRAGMA user_version = \(Self.schemaVersion)")
                else { return false }
                return true
            }) else { return false }
            return reclaimAfterMigration()
        }
        // v4 rows were already transactionally paired with exact Legacy source revisions. Preserve
        // them and add only the library-instance binding; the launch validator decides whether they
        // may be adopted, avoiding an automatic 500 MB FTS rebuild on upgrade.
        if version == 4 {
            guard transaction({
                guard run("""
                CREATE TABLE library_binding (
                  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                  database_instance_id TEXT,
                  applied_sequence INTEGER NOT NULL DEFAULT 0 CHECK (applied_sequence >= 0)
                )
                """),
                run("""
                INSERT INTO library_binding (
                  singleton, database_instance_id, applied_sequence)
                VALUES (1, NULL, 0)
                """),
                // v4 jumps straight to the current version, so it must land every object the
                // current version requires. Without this the stamp would claim a schema the file
                // does not have, and `currentSchemaIsUsable` would discard rows this branch exists
                // to preserve.
                run(Self.memoryIndexStatement),
                run(Self.memoryVectorStatement),
                run(Self.memoryEntitySummaryStatement),
                run(Self.memoryBuildSeenStatement),
                run(Self.memoryRelationshipVerdictStatement),
                run(Self.memorySummaryReceiptStatement),
                run(Self.memrankShadowJournalStatement),
                run(Self.memrankGraphGenerationStatement),
                run(Self.memrankContextDormancyStatement),
                createLatestAdditiveObjects(),
                discardPreCapConversationIndex(),
                dropRetiredMemoryObjects(),
                run("PRAGMA user_version = \(Self.schemaVersion)")
                else { return false }
                return true
            }) else { return false }
            return reclaimAfterMigration()
        }
        return version == Self.schemaVersion && currentSchemaIsUsable()
    }

    /// The memory search index.
    ///
    /// Disposable like everything else here: `library.db` owns every claim, and this is rebuilt
    /// from it. Deleting `projections.db` must stay zero data loss for memory exactly as it is for
    /// conversations, so nothing may live in this table that is not derived from the authority.
    ///
    /// Columns are separate rather than one blob so ranking can weight them. A title or an alias
    /// matching is much stronger evidence than the same word appearing in a claim body, and BM25
    /// can only express that if the fields are distinct. `prefix='2 3'` is what makes typing part
    /// of a word find the page before the word is finished.
    static let memoryIndexStatement = """
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
          claim_id UNINDEXED,
          page_id UNINDEXED,
          scope UNINDEXED,
          workspace_id UNINDEXED,
          title,
          aliases,
          summary,
          body,
          tokenize='unicode61 remove_diacritics 2',
          prefix='2 3'
        )
        """

    /// The same claims as vectors, for the half of retrieval a word index cannot do.
    ///
    /// Derived exactly like `memory_fts` and disposable for the same reason: `library.db` owns the
    /// text and a vector is recomputable from it. Keeping it here is what lets this ship without
    /// moving a schema version in the authority.
    ///
    /// Scope and workspace are carried so the filter runs in SQL BEFORE anything is ranked, which is
    /// the rule the lexical index already follows: an out-of-scope claim never enters a ranked list
    /// where a later bug could leak it.
    ///
    /// No index on the vector and none wanted. A library is a few hundred short claims, so this is
    /// scanned; a vector index would be a second thing to keep correct in exchange for microseconds.
    /// Which conversations a profile build has already read, and what they looked like.
    ///
    /// Derived and disposable like everything else here: losing it costs one full re-read and never
    /// a fact, which is exactly why it does not belong in the authority.
    static let memoryBuildSeenStatement = """
        CREATE TABLE IF NOT EXISTS memory_build_seen (
          conversation_id TEXT PRIMARY KEY,
          stamp TEXT NOT NULL
        )
        """

    static let memoryVectorStatement = """
        CREATE TABLE IF NOT EXISTS memory_vector (
          claim_id TEXT PRIMARY KEY,
          page_id TEXT NOT NULL,
          scope TEXT NOT NULL,
          workspace_id TEXT NOT NULL,
          vector BLOB NOT NULL
        )
        """

    /// An ENTITY page's summary, keyed by the entity's derived id.
    ///
    /// Derived twice over — the page is a view assembled from statements, and its prose is written
    /// from those statements — so losing it costs one regeneration and never a fact. That is exactly
    /// what the disposable database is for, and it is why entity pages needed no schema move in the
    /// authority to gain a summary.
    ///
    /// `revision` is the library revision the prose was written from, so a stale summary is visibly
    /// stale rather than silently wrong.
    static let memoryEntitySummaryStatement = """
        CREATE TABLE IF NOT EXISTS memory_entity_summary (
          entity_id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          summary TEXT NOT NULL,
          statement_count INTEGER NOT NULL
        )
        """

    /// A model's typed answer about one pair of authoritative memory claims.
    ///
    /// This is a disposable safety cache, not a new fact about the person. The claim ids and
    /// fingerprints bind an answer to the exact two authority revisions it classified; no claim
    /// text is copied here. Deleting this table costs another classification and no product data.
    ///
    /// One row per unordered pair. `MemoryRelationshipPair` produces this order in Swift and the
    /// CHECK keeps a hand-written or damaged row from giving the reverse ordering a second answer.
    static let memoryRelationshipVerdictStatement = """
        CREATE TABLE IF NOT EXISTS memory_relationship_verdict (
          first_claim_id TEXT NOT NULL,
          second_claim_id TEXT NOT NULL,
          first_fingerprint TEXT NOT NULL,
          second_fingerprint TEXT NOT NULL,
          classifier_version INTEGER NOT NULL CHECK (classifier_version > 0),
          relationship TEXT NOT NULL CHECK (
            relationship IN ('duplicate', 'conflict', 'distinct', 'unknown')),
          classified_at REAL NOT NULL,
          PRIMARY KEY (first_claim_id, second_claim_id),
          CHECK (first_claim_id < second_claim_id)
        ) STRICT
        """

    /// Proof that one stored summary was produced from one exact canonical provider view.
    ///
    /// The prose remains in its existing owner (`memory_page` in the authority, or the entity
    /// projection). This table carries only hashes, so deleting it makes summaries local-only until
    /// regenerated; it can never lose a fact or expose unproved legacy prose.
    static let memorySummaryReceiptStatement = """
        CREATE TABLE IF NOT EXISTS memory_summary_receipt (
          subject_kind TEXT NOT NULL CHECK (subject_kind IN ('page', 'entity')),
          subject_id TEXT NOT NULL,
          prose_fingerprint TEXT NOT NULL,
          input_signature TEXT NOT NULL,
          recorded_at REAL NOT NULL,
          PRIMARY KEY (subject_kind, subject_id)
        ) STRICT
        """

    /// A bounded, content-free trace of Memrank's shadow decisions under real work.
    ///
    /// This is not feedback and not a learned fact. It is safe to delete with the rest of
    /// `projections.db`; its only purpose is to compare rankings before Memrank is allowed to alter
    /// disclosure. The JSON payload's Swift type contains only typed UUIDs, numeric scores/ranks,
    /// and closed reason enums. No prompt, statement, page, excerpt, or vector is accepted.
    static let memrankShadowJournalStatement = """
        CREATE TABLE IF NOT EXISTS memrank_shadow_journal (
          sequence INTEGER PRIMARY KEY,
          recorded_at REAL NOT NULL,
          path TEXT NOT NULL CHECK (path IN ('automatic', 'explicit')),
          workspace_id TEXT,
          conversation_id TEXT,
          entry_id TEXT,
          provider_access TEXT NOT NULL,
          format_version INTEGER NOT NULL CHECK (format_version = 1),
          payload_json TEXT NOT NULL CHECK (length(payload_json) > 0)
        ) STRICT
        """

    /// One exact, content-free Memrank graph generation.
    ///
    /// The graph is a disposable derivation from `library.db`. Its source identity, graph-input
    /// generation, and content-free activity signature are an exact-use fence, while
    /// `recipe_version` makes a scoring-recipe change an ordinary cache miss. One singleton keeps
    /// replacement atomic and prevents a slow older build from becoming the apparent newest
    /// generation.
    static let memrankGraphGenerationStatement = """
        CREATE TABLE IF NOT EXISTS memrank_graph_generation (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          database_instance_id TEXT NOT NULL,
          input_generation INTEGER NOT NULL CHECK (input_generation >= 0),
          activity_signature TEXT NOT NULL CHECK (length(activity_signature) = 64),
          recipe_version INTEGER NOT NULL CHECK (recipe_version > 0),
          payload_json TEXT NOT NULL CHECK (length(payload_json) > 0)
        ) STRICT
        """

    /// One content-free dormancy snapshot fenced to the exact graph it was learned against.
    /// Absence, corruption, a future recipe, or any coordinate mismatch means all edges are active.
    static let memrankContextDormancyStatement = """
        CREATE TABLE IF NOT EXISTS memrank_context_dormancy (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          database_instance_id TEXT NOT NULL,
          input_generation INTEGER NOT NULL CHECK (input_generation >= 0),
          activity_signature TEXT NOT NULL CHECK (length(activity_signature) = 64),
          graph_recipe_version INTEGER NOT NULL CHECK (graph_recipe_version > 0),
          dormancy_recipe_version INTEGER NOT NULL CHECK (dormancy_recipe_version > 0),
          payload_json TEXT NOT NULL CHECK (length(payload_json) > 0)
        ) STRICT
        """

    /// Objects the CURRENT schema requires that a lower rung must also land.
    ///
    /// Empty at v16: the only additive object left was the learning-observation table, and that
    /// went with the subsystem. Kept as the seam rather than deleted, because every rung calls it
    /// and the next additive schema move needs exactly one place to land — which is also why it
    /// must never touch `entry_fts`. See `discardPreCapConversationIndex()`.
    private func createLatestAdditiveObjects() -> Bool {
        true
    }

    /// Release the retired memory, Memrank and learning-observation tables.
    ///
    /// Idempotent and called by every rung, so a cache arriving from any older version lands in the
    /// same shape. The historical rungs above still CREATE these tables before this drops them, and
    /// that is deliberate: the v11 and v12 rungs `ALTER` them, so removing the create would break a
    /// rung's own next statement. Creating and dropping in one transaction costs microseconds.
    ///
    /// `memory_fts` is a virtual table; dropping it removes its shadow tables with it.
    private func dropRetiredMemoryObjects() -> Bool {
        for object in Self.retiredMemoryObjects where !run("DROP TABLE IF EXISTS \(object)") {
            return false
        }
        return true
    }

    /// Named rather than discovered. A `DROP` driven by a `sqlite_master` pattern would release
    /// whatever happened to match, including a future table this list has never heard of.
    static let retiredMemoryObjects = [
        "memory_fts", "memory_vector", "memory_entity_summary", "memory_build_seen",
        "memory_relationship_verdict", "memory_summary_receipt",
        "memrank_shadow_journal", "memrank_graph_generation", "memrank_context_dormancy",
        "learning_observation",
    ]

    /// Discard a conversation index built before the per-entry cap existed.
    ///
    /// Correct and free for any rung arriving from **below v15**: the cap is folded into
    /// `content_stamp`, so every conversation re-indexes anyway and these rows are about to be
    /// replaced. Clearing them is what lets the `VACUUM` afterwards actually return the disk. The
    /// rest of the cache, the memory build watermark and the library binding in particular, is
    /// preserved, so no conversation is re-read by memory.
    ///
    /// **It must not become automatic.** It lived inside `createLatestAdditiveObjects()` when the
    /// cap shipped in 0.26.44, which meant every rung inherited it and therefore that *any* future
    /// projection schema bump would re-tokenize the entire transcript corpus, whether or not the
    /// change had anything to do with the index. That is the exact cost the ladder above is written
    /// to avoid, and its own comment warns about it. A v15-or-later rung that wants this must say
    /// so; on a 1.3 GB index, inheriting it by accident is minutes of work for nothing.
    private func discardPreCapConversationIndex() -> Bool {
        run("DELETE FROM entry_fts")
    }

    /// Give the freed pages back to the filesystem, once, after a migration.
    ///
    /// SQLite keeps deleted pages on a free list and the file never shrinks without this. Clearing
    /// a 1.3 GB conversation index without vacuuming would leave a 1.8 GB file that merely had room
    /// to grow into, which is not what anyone means by reclaiming space.
    ///
    /// Cheap in exactly this situation: `VACUUM` copies only LIVE content into a fresh file, and
    /// after the clear above there is very little of it, so the temporary space needed is a few
    /// megabytes rather than the size of the old file. It cannot run inside a transaction, which is
    /// why it sits here rather than in a rung.
    private func reclaimAfterMigration() -> Bool {
        _ = run("VACUUM")
        return currentSchemaIsUsable()
    }

    /// `user_version` alone is not a schema. Check the required objects and columns cheaply so a
    /// structurally damaged but correctly stamped disposable cache is deleted and rebuilt now,
    /// rather than tripping the session breaker on every launch.
    private func currentSchemaIsUsable() -> Bool {
        var objectCount: Int32 = 0
        guard run(
            """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'table'
              AND name IN ('summaries', 'entry_fts', 'library_binding')
            """,
            row: { objectCount = sqlite3_column_int($0, 0) }), objectCount == 3,
            run("SELECT id, content_stamp, source_revision FROM summaries LIMIT 0"),
            run("SELECT conversation_id, content FROM entry_fts LIMIT 0"),
            run("SELECT database_instance_id, applied_sequence FROM library_binding LIMIT 0")
        else { return false }
        var bindingCount: Int32 = 0
        guard run(
            "SELECT COUNT(*) FROM library_binding WHERE singleton = 1",
            row: { bindingCount = sqlite3_column_int($0, 0) }) else { return false }
        return bindingCount == 1
    }

    private var databaseFamilyURLs: [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
    }

    private func closeDatabase() {
        if let db { _ = sqlite3_close_v2(db) }
        db = nil
    }

    /// Required rebuilds never reopen a cache whose prior generation may still be present. A
    /// failed removal leaves the marker in place and the store broken so the next launch can retry
    /// without ever blessing mixed database/WAL bytes as a fresh projection.
    private func closeAndDeleteRequiringSuccess() -> Bool {
        if let db {
            let result = sqlite3_close_v2(db)
            self.db = nil
            guard result == SQLITE_OK else {
                lastFailureDiagnostics = Self.sqliteFailureDiagnostics(
                    operation: "close for rebuild",
                    code: result,
                    message: String(cString: sqlite3_errstr(result)))
                broken = true
                _ = markRebuildRequired()
                return false
            }
        }
        let fm = FileManager.default
        do {
            for url in databaseFamilyURLs where fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        } catch {
            lastFailureDiagnostics = "projections.db rebuild could not remove its cache files"
            broken = true
            _ = markRebuildRequired()
            return false
        }
        guard !databaseFamilyURLs.contains(where: { fm.fileExists(atPath: $0.path) }) else {
            lastFailureDiagnostics = "projections.db rebuild left prior cache files in place"
            broken = true
            _ = markRebuildRequired()
            return false
        }
        return true
    }

    @discardableResult
    private func markRebuildRequired() -> Bool {
        do {
            try Data("projection-rebuild-v1\n".utf8).write(
                to: rebuildMarkerURL,
                options: .atomic)
            return true
        } catch {
            if let diagnostics = lastFailureDiagnostics {
                lastFailureDiagnostics = diagnostics + "; rebuild marker write failed"
            } else {
                lastFailureDiagnostics = "projections.db rebuild marker write failed"
            }
            return false
        }
    }

    private func clearRebuildMarker() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rebuildMarkerURL.path) else { return true }
        do {
            try fm.removeItem(at: rebuildMarkerURL)
            guard !fm.fileExists(atPath: rebuildMarkerURL.path) else {
                lastFailureDiagnostics = "projections.db rebuild marker remained after removal"
                return false
            }
            return true
        } catch {
            lastFailureDiagnostics = "projections.db rebuild marker could not be cleared"
            return false
        }
    }

    @discardableResult
    private func upsert(_ record: Record, reindexEntries: Bool) -> Bool {
        transaction { upsertStatements(record, reindexEntries: reindexEntries) }
    }

    private func upsertStatements(_ record: Record, reindexEntries: Bool) -> Bool {
        let summary = record.summary
        guard run("""
            INSERT INTO summaries (
              id, title, workspace_cwd, workspace_id, updated_at, message_count, snippet,
              has_user_message, favorite, sort_index, unread, errored, provider_access_name,
              armed_wait_summary, content_stamp, source_revision)
            VALUES (
              ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
            ON CONFLICT(id) DO UPDATE SET
              title = ?2, workspace_cwd = ?3, workspace_id = ?4, updated_at = ?5,
              message_count = ?6, snippet = ?7, has_user_message = ?8, favorite = ?9,
              sort_index = ?10, unread = ?11, errored = ?12, provider_access_name = ?13,
              armed_wait_summary = ?14, content_stamp = ?15, source_revision = ?16
            """,
            bind: {
                bind($0, 1, record.id)
                bind($0, 2, summary.title)
                bind($0, 3, summary.workspaceCWD)
                if let workspaceID = summary.workspaceID { bind($0, 4, workspaceID.uuidString) }
                else { sqlite3_bind_null($0, 4) }
                bind($0, 5, summary.updatedAt.timeIntervalSinceReferenceDate)
                bind($0, 6, summary.messageCount)
                bind($0, 7, summary.snippet)
                bind($0, 8, summary.hasUserMessage ? 1 : 0)
                bind($0, 9, summary.favorite ? 1 : 0)
                if let sortIndex = summary.sortIndex { bind($0, 10, sortIndex) }
                else { sqlite3_bind_null($0, 10) }
                bind($0, 11, summary.unread ? 1 : 0)
                bind($0, 12, summary.errored ? 1 : 0)
                if let providerAccessName = summary.providerAccessName {
                    bind($0, 13, providerAccessName)
                } else { sqlite3_bind_null($0, 13) }
                if let armedWaitSummary = summary.armedWaitSummary {
                    bind($0, 14, armedWaitSummary)
                } else { sqlite3_bind_null($0, 14) }
                bind($0, 15, record.contentStamp)
                bind($0, 16, record.sourceRevision)
            }) else { return false }
        if reindexEntries {
            guard run(
                "DELETE FROM entry_fts WHERE conversation_id = ?1",
                bind: { bind($0, 1, record.id) }) else { return false }
            for entry in record.entries {
                guard run(
                    "INSERT INTO entry_fts (conversation_id, content) VALUES (?1, ?2)",
                    bind: { bind($0, 1, record.id); bind($0, 2, entry) }) else { return false }
            }
        }
        return true
    }

    private func upsertSummaryOnly(
        _ summary: ConversationSummary,
        sourceRevision: String?
    ) -> Bool {
        run("""
            INSERT INTO summaries (
              id, title, workspace_cwd, workspace_id, updated_at, message_count, snippet,
              has_user_message, favorite, sort_index, unread, errored, provider_access_name,
              armed_wait_summary, content_stamp, source_revision)
            VALUES (
              ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, '',
              COALESCE(?15, ''))
            ON CONFLICT(id) DO UPDATE SET
              title = ?2, workspace_cwd = ?3, workspace_id = ?4, updated_at = ?5,
              message_count = ?6, snippet = ?7, has_user_message = ?8, favorite = ?9,
              sort_index = ?10, unread = ?11, errored = ?12, provider_access_name = ?13,
              armed_wait_summary = ?14,
              source_revision = CASE WHEN ?15 IS NULL
                THEN summaries.source_revision ELSE ?15 END
            """, bind: {
                bind($0, 1, summary.id.uuidString)
                bind($0, 2, summary.title)
                bind($0, 3, summary.workspaceCWD)
                if let workspaceID = summary.workspaceID { bind($0, 4, workspaceID.uuidString) }
                else { sqlite3_bind_null($0, 4) }
                bind($0, 5, summary.updatedAt.timeIntervalSinceReferenceDate)
                bind($0, 6, summary.messageCount)
                bind($0, 7, summary.snippet)
                bind($0, 8, summary.hasUserMessage ? 1 : 0)
                bind($0, 9, summary.favorite ? 1 : 0)
                if let sortIndex = summary.sortIndex { bind($0, 10, sortIndex) }
                else { sqlite3_bind_null($0, 10) }
                bind($0, 11, summary.unread ? 1 : 0)
                bind($0, 12, summary.errored ? 1 : 0)
                if let providerAccessName = summary.providerAccessName {
                    bind($0, 13, providerAccessName)
                } else { sqlite3_bind_null($0, 13) }
                if let armedWaitSummary = summary.armedWaitSummary {
                    bind($0, 14, armedWaitSummary)
                } else { sqlite3_bind_null($0, 14) }
                if let sourceRevision { bind($0, 15, sourceRevision) }
                else { sqlite3_bind_null($0, 15) }
            })
    }

    private func readSummaries() -> [ConversationSummary] {
        var rows: [ConversationSummary] = []
        _ = run(
            """
            SELECT id, title, workspace_cwd, workspace_id, updated_at, message_count, snippet,
              has_user_message, favorite, sort_index, unread, errored, provider_access_name,
              armed_wait_summary
            FROM summaries
            """,
            row: { statement in
                guard let rawID = sqlite3_column_text(statement, 0),
                      let id = UUID(uuidString: String(cString: rawID)),
                      let rawTitle = sqlite3_column_text(statement, 1),
                      let rawWorkspaceCWD = sqlite3_column_text(statement, 2),
                      let rawSnippet = sqlite3_column_text(statement, 6) else { return }
                rows.append(ConversationSummary(
                    id: id,
                    title: String(cString: rawTitle),
                    workspaceCWD: String(cString: rawWorkspaceCWD),
                    workspaceID: sqlite3_column_text(statement, 3).flatMap {
                        UUID(uuidString: String(cString: $0))
                    },
                    updatedAt: Date(
                        timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 4)),
                    messageCount: Int(sqlite3_column_int64(statement, 5)),
                    snippet: String(cString: rawSnippet),
                    hasUserMessage: sqlite3_column_int(statement, 7) != 0,
                    favorite: sqlite3_column_int(statement, 8) != 0,
                    sortIndex: sqlite3_column_type(statement, 9) == SQLITE_NULL
                        ? nil : Int(sqlite3_column_int64(statement, 9)),
                    unread: sqlite3_column_int(statement, 10) != 0,
                    errored: sqlite3_column_int(statement, 11) != 0,
                    // Neither live-only state has an operative owner before the authoritative
                    // record loads, so neither is stored in this cross-launch projection.
                    awaitingQuestion: false,
                    hasRunningDelegate: false,
                    providerAccessName: sqlite3_column_text(statement, 12).map {
                        String(cString: $0)
                    },
                    armedWaitSummary: sqlite3_column_text(statement, 13).map {
                        String(cString: $0)
                    }))
            })
        return rows
    }

    private func stamp(for id: String) -> String? {
        var found: String?
        _ = run(
            "SELECT content_stamp FROM summaries WHERE id = ?1",
            bind: { bind($0, 1, id) },
            row: { if let raw = sqlite3_column_text($0, 0) { found = String(cString: raw) } })
        return found
    }

    private func readSourceRevisions() -> [UUID: String] {
        var revisions: [UUID: String] = [:]
        _ = run(
            "SELECT id, source_revision FROM summaries",
            row: { statement in
                guard let rawID = sqlite3_column_text(statement, 0),
                      let id = UUID(uuidString: String(cString: rawID)),
                      let rawRevision = sqlite3_column_text(statement, 1) else { return }
                revisions[id] = String(cString: rawRevision)
            })
        return revisions
    }

    private func allSummaryIDs() -> Set<String> {
        var ids = Set<String>()
        _ = run(
            "SELECT id FROM summaries",
            row: { if let raw = sqlite3_column_text($0, 0) { ids.insert(String(cString: raw)) } })
        return ids
    }

    private func allProjectionIDs() -> Set<String> {
        allSummaryIDs().union(allFTSConversationIDs())
    }

    private func allFTSConversationIDs() -> Set<String> {
        var ids = Set<String>()
        _ = run("SELECT DISTINCT conversation_id FROM entry_fts", row: {
            if let raw = sqlite3_column_text($0, 0) { ids.insert(String(cString: raw)) }
        })
        return ids
    }

    private func prepareLibraryBinding(
        _ databaseInstanceID: UUID,
        preserveValidatedRows: Bool = false
    ) -> Bool {
        var existing: UUID?
        var rowWasRead = false
        guard run(
            "SELECT database_instance_id FROM library_binding WHERE singleton = 1",
            row: { statement in
                rowWasRead = true
                existing = sqlite3_column_text(statement, 0).flatMap {
                    UUID(uuidString: String(cString: $0))
                }
            }), rowWasRead else { return false }
        if existing != databaseInstanceID {
            // A foreign authority invalidates every derived row that names one of its entities.
            // `preserveValidatedRows` is the one exception, and it is earned: the caller proved the
            // exact Conversation inventory matches, so the index it validated is adoptable.
            if existing != nil, !preserveValidatedRows {
                guard run("DELETE FROM summaries"),
                      run("DELETE FROM entry_fts") else { return false }
            }
            guard run(
                """
                UPDATE library_binding
                SET database_instance_id = ?1, applied_sequence = 0
                WHERE singleton = 1
                """,
                bind: { bind($0, 1, databaseInstanceID.uuidString) }) else { return false }
        }
        return true
    }

    private func writeLibraryBinding(
        databaseInstanceID: UUID,
        appliedSequence: Int64
    ) -> Bool {
        guard appliedSequence >= 0 else { return false }
        return run(
            """
            UPDATE library_binding
            SET applied_sequence = CASE
                  WHEN database_instance_id = ?1 THEN MAX(applied_sequence, ?2)
                  ELSE ?2
                END,
                database_instance_id = ?1
            WHERE singleton = 1
            """,
            bind: {
                bind($0, 1, databaseInstanceID.uuidString)
                sqlite3_bind_int64($0, 2, appliedSequence)
            })
    }

    private func transaction(_ body: () -> Bool) -> Bool {
        guard run("BEGIN IMMEDIATE") else { return false }
        guard body(), run("COMMIT") else {
            if let db { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            return false
        }
        return true
    }

    /// Optional diagnostics never inherit the cache-wide session breaker. A trigger, malformed
    /// row, or future-format mismatch in this path drops that observation and rolls back only its
    /// transaction; it cannot turn off conversation search or memory recall for the session.
    private func bestEffortTransaction(_ body: () -> Bool) -> Bool {
        guard bestEffortRun("BEGIN IMMEDIATE") else { return false }
        guard body(), bestEffortRun("COMMIT") else {
            if let db { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            return false
        }
        return true
    }

    @discardableResult
    private func bestEffortRun(
        _ sql: String,
        bind bindings: (OpaquePointer) -> Void = { _ in },
        row: (OpaquePointer) -> Void = { _ in }
    ) -> Bool {
        guard let db, !broken else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        bindings(statement)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(statement)
            case SQLITE_DONE: return true
            default: return false
            }
        }
    }

    /// Prepare/bind/step one statement. Any SQLite failure marks the store broken — a cache that
    /// misbehaves once is retired for the session and rebuilt on the next launch, never trusted
    /// while wounded and never allowed to interrupt the user.
    @discardableResult
    private func run(
        _ sql: String,
        bind bindings: (OpaquePointer) -> Void = { _ in },
        row: (OpaquePointer) -> Void = { _ in }
    ) -> Bool {
        guard let db, !broken else { return false }
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            recordSQLiteFailure(operation: "prepare", code: prepareResult, database: db)
            return false
        }
        defer { sqlite3_finalize(statement) }
        bindings(statement)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(statement)
            case SQLITE_DONE: return true
            case let result:
                recordSQLiteFailure(operation: "step", code: result, database: db)
                return false
            }
        }
    }

    private func recordSQLiteFailure(
        operation: String,
        code: Int32,
        database: OpaquePointer
    ) {
        lastFailureDiagnostics = Self.sqliteFailureDiagnostics(
            operation: operation,
            code: code,
            message: String(cString: sqlite3_errmsg(database)))
        broken = true
        _ = markRebuildRequired()
    }

    private static func sqliteFailureDiagnostics(
        operation: String,
        code: Int32,
        message: String
    ) -> String {
        "projections.db SQLite \(operation) failed (\(code)): \(message)"
    }

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }
    private func bindOptional(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            bind(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(statement, index, value)
    }
    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int) {
        sqlite3_bind_int64(statement, index, Int64(value))
    }
    /// `transient` because SQLite must copy: the `Data` is a Swift value whose buffer does not
    /// outlive this call, and binding it as static would hand the engine freed memory.
    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Data) {
        value.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(raw.count), transient)
        }
    }

    // MARK: - Test seams

    /// Block until every queued operation has run (queries and writes are queue-ordered).
    func drain() { queue.sync {} }
    var isBroken: Bool { queue.sync { broken } }
    var failureDiagnostics: String? { queue.sync { lastFailureDiagnostics } }
}
