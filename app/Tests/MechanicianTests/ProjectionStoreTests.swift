import SQLite3
import XCTest
@testable import Mechanician

/// `projections.db` is disposable: these tests pin the promises that make it safe — it follows the
/// current authority (never leads), replays committed library work idempotently, rebuilds after
/// damage, and never substitutes stale search results for an acknowledged complete inventory.
@MainActor
final class ProjectionStoreTests: XCTestCase {
    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func executeSQL(_ databaseURL: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else { throw NSError(domain: "projection.test.sqlite", code: 1) }
        defer { sqlite3_close_v2(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(
                domain: "projection.test.sqlite",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    private func search(
        _ store: ConversationProjectionStore, _ query: String
    ) async -> Set<UUID>? {
        await withCheckedContinuation { continuation in
            store.searchConversationIDs(matching: query) { continuation.resume(returning: $0) }
        }
    }

    private func rankedSearch(
        _ store: ConversationProjectionStore, _ query: String
    ) async -> [ConversationProjectionStore.SearchHit]? {
        await withCheckedContinuation { continuation in
            store.searchConversations(matching: query) { continuation.resume(returning: $0) }
        }
    }

    private func summaries(
        _ store: ConversationProjectionStore, matching query: String? = nil
    ) async -> [ConversationSummary] {
        await withCheckedContinuation { continuation in
            store.summaries(matching: query) { continuation.resume(returning: $0) }
        }
    }

    private func reconcile(
        _ store: ConversationProjectionStore, with conversations: [Conversation]
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            store.reconcile(with: conversations) {
                XCTAssertTrue(Thread.isMainThread)
                continuation.resume(returning: $0)
            }
        }
    }

    private func inventoryMatches(
        _ store: ConversationProjectionStore,
        summaries: [ConversationSummary],
        revisions: [UUID: String]
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            store.matchesAuthoritativeInventory(
                summaries,
                sourceRevisions: revisions
            ) { continuation.resume(returning: $0) }
        }
    }

    private func applyLibraryWork(
        _ store: ConversationProjectionStore,
        conversation: Conversation?,
        entityID: UUID,
        sourceRevision: String,
        databaseInstanceID: UUID,
        desiredSequence: Int64,
        forceReindex: Bool = true
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            store.applyLibraryWork(
                conversation: conversation,
                entityID: entityID,
                sourceRevision: sourceRevision,
                databaseInstanceID: databaseInstanceID,
                desiredSequence: desiredSequence,
                forceReindex: forceReindex
            ) { continuation.resume(returning: $0) }
        }
    }

    private func applyLibraryWorkWithDiagnostics(
        _ store: ConversationProjectionStore,
        conversation: Conversation?,
        entityID: UUID,
        sourceRevision: String,
        databaseInstanceID: UUID,
        desiredSequence: Int64,
        forceReindex: Bool = true
    ) async -> (Bool, String?) {
        await withCheckedContinuation { continuation in
            store.applyLibraryWorkWithDiagnostics(
                conversation: conversation,
                entityID: entityID,
                sourceRevision: sourceRevision,
                databaseInstanceID: databaseInstanceID,
                desiredSequence: desiredSequence,
                forceReindex: forceReindex
            ) { succeeded, diagnostics in
                continuation.resume(returning: (succeeded, diagnostics))
            }
        }
    }

    private func index(
        _ store: ConversationProjectionStore,
        conversation: Conversation
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            store.index(conversation) { continuation.resume(returning: $0) }
        }
    }

    private func indexSummary(
        _ store: ConversationProjectionStore,
        summary: ConversationSummary
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            store.indexSummary(summary) { continuation.resume(returning: $0) }
        }
    }

    private func bindExactLibrarySnapshot(
        _ store: ConversationProjectionStore,
        databaseInstanceID: UUID,
        appliedSequence: Int64
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            store.bindExactLibrarySnapshot(
                databaseInstanceID: databaseInstanceID,
                appliedSequence: appliedSequence
            ) { continuation.resume(returning: $0) }
        }
    }

    private func finalizeLibraryCatchUp(
        _ store: ConversationProjectionStore,
        frontier: ShadowLibraryProjectionFrontier
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            store.finalizeLibraryCatchUp(frontier) {
                continuation.resume(returning: $0)
            }
        }
    }

    /// cwd stays empty so these resolve to Home under the FR-181 membership rules (a nil-id
    /// conversation with a non-empty cwd and no matching Project is dangling, not Home).
    private func conversation(
        title: String, userText: String, toolOutput: String? = nil
    ) -> Conversation {
        var messages = [TranscriptEntry(kind: .user, text: userText)]
        if let toolOutput {
            var tool = TranscriptEntry(kind: .tool, text: "Bash")
            tool.toolName = "Bash"
            tool.toolResult = toolOutput
            messages.append(tool)
        }
        return Conversation(
            title: title, cwd: "", sdkSessionId: nil, messages: messages, updatedAt: Date())
    }

    func testIndexesMessageTextAndToolOutput() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        let c = conversation(
            title: "Notarize", userText: "please ship the build",
            toolOutput: "notarization ticket 7F2A accepted by Apple")
        store.index(c)
        store.drain()

        let byMessage = await search(store, "ship the build")
        XCTAssertEqual(byMessage, [c.id])
        // The headline capability: tool OUTPUT is searchable — the sidebar substring scan over
        // `text` never saw this content at all.
        let byToolOutput = await search(store, "notarization ticket")
        XCTAssertEqual(byToolOutput, [c.id])
        let miss = await search(store, "kubernetes")
        XCTAssertEqual(miss, [])
        // Prefix matching keeps type-ahead feel; quoting keeps FTS operators inert.
        let prefix = await search(store, "notari")
        XCTAssertEqual(prefix, [c.id])
        let operators = await search(store, "NEAR AND \"quoted")
        XCTAssertNotNil(operators, "hostile operator input must sanitize, not error the index")
    }

    func testIndexesLabeledClaudeContinuitySummary() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        var boundary = TranscriptEntry(kind: .compaction, text: "Summarized earlier messages")
        boundary.compactionSummary = "Continue with the QUARTZ-COMPACTION-SENTINEL invariant."
        boundary.compactionSummarySource = "claude_post_compact"
        let conversation = Conversation(
            title: "Context boundary", cwd: "", sdkSessionId: nil,
            messages: [boundary], updatedAt: Date())

        let record = ConversationProjectionStore.record(for: conversation)
        XCTAssertEqual(record.entries.count, 1)
        XCTAssertTrue(record.entries[0].contains("Claude continuity summary"))
        let indexed = await index(store, conversation: conversation)
        XCTAssertTrue(indexed)
        let hits = await search(store, "QUARTZ-COMPACTION-SENTINEL")
        XCTAssertEqual(hits, [conversation.id])
    }

    func testInventoryAttestationRejectsToolOnlyCommitWithNewSourceRevision() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        var indexed = conversation(
            title: "Build", userText: "run checks", toolOutput: "old tool result")
        indexed.updatedAt = Date(timeIntervalSinceReferenceDate: 50_000)
        store.index(indexed, sourceRevision: "lstat-v1:old")
        store.drain()

        var committed = indexed
        committed.messages[1].toolResult = "new authoritative needle"
        // Tool-only mutations do not necessarily change any persisted sidebar summary field.
        XCTAssertEqual(ConversationSummary(indexed), ConversationSummary(committed))
        let oldRevisionMatches = await inventoryMatches(
            store,
            summaries: [ConversationSummary(committed)],
            revisions: [committed.id: "lstat-v1:old"])
        let newRevisionMatches = await inventoryMatches(
            store,
            summaries: [ConversationSummary(committed)],
            revisions: [committed.id: "lstat-v1:new"])
        XCTAssertTrue(oldRevisionMatches)
        XCTAssertFalse(newRevisionMatches)
    }

    func testSummaryOnlyUpdateDoesNotRehashOrClaimNewTranscriptContent() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        var conversation = conversation(
            title: "Before", userText: "original searchable needle",
            toolOutput: "old tool output")
        let indexed = await withCheckedContinuation { continuation in
            store.index(conversation, sourceRevision: "sqlite:41") {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(indexed)

        conversation.title = "After"
        conversation.favorite = true
        conversation.messages[1].toolResult = "unindexed replacement needle"
        let summaryIndexed = await indexSummary(
            store, summary: ConversationSummary(conversation))
        XCTAssertTrue(summaryIndexed)

        let projectedRows = await summaries(store)
        let projected = try XCTUnwrap(projectedRows.first)
        XCTAssertEqual(projected.title, "After")
        XCTAssertTrue(projected.favorite)
        let originalHits = await search(store, "original searchable")
        let replacementHits = await search(store, "unindexed replacement")
        XCTAssertEqual(originalHits, [conversation.id])
        XCTAssertEqual(replacementHits, [])
        let oldRevisionStillAttested = await inventoryMatches(
            store,
            summaries: [ConversationSummary(conversation)],
            revisions: [conversation.id: "sqlite:41"])
        let newRevisionUnattested = await inventoryMatches(
            store,
            summaries: [ConversationSummary(conversation)],
            revisions: [conversation.id: "sqlite:42"])
        XCTAssertTrue(oldRevisionStillAttested)
        XCTAssertFalse(newRevisionUnattested)
    }

    func testLibraryWorkFailureStaysBrokenUntilNextStoreRebuildsMarkedCache() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let instance = UUID()
        var value = conversation(title: "Before", userText: "failure diagnostics sentinel")
        let marker = base.appendingPathComponent(
            ConversationProjectionStore.rebuildMarkerName,
            isDirectory: false)

        do {
            let store = ConversationProjectionStore(appSupportBase: base)
            let inserted = await applyLibraryWork(
                store,
                conversation: value,
                entityID: value.id,
                sourceRevision: "one",
                databaseInstanceID: instance,
                desiredSequence: 1)
            XCTAssertTrue(inserted)
            store.drain()

            try executeSQL(
                base.appendingPathComponent("projections.db"),
                """
                CREATE TRIGGER inject_projection_failure
                BEFORE UPDATE ON summaries
                BEGIN
                  SELECT RAISE(ABORT, 'injected projection summary failure');
                END
                """)
            value.title = "After"
            let (succeeded, diagnostics) = await applyLibraryWorkWithDiagnostics(
                store,
                conversation: value,
                entityID: value.id,
                sourceRevision: "two",
                databaseInstanceID: instance,
                desiredSequence: 2,
                forceReindex: false)

            XCTAssertFalse(succeeded)
            XCTAssertTrue(store.isBroken)
            XCTAssertTrue(diagnostics?.contains("SQLite step failed") == true)
            XCTAssertTrue(diagnostics?.contains("injected projection summary failure") == true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
            let brokenHits = await search(store, "failure diagnostics")
            XCTAssertNil(brokenHits)
        }

        let replacement = ConversationProjectionStore(appSupportBase: base)
        replacement.drain()
        XCTAssertFalse(replacement.isBroken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let emptyHits = await search(replacement, "failure diagnostics")
        XCTAssertEqual(emptyHits, [])

        let replayed = await applyLibraryWork(
            replacement,
            conversation: value,
            entityID: value.id,
            sourceRevision: "two",
            databaseInstanceID: instance,
            desiredSequence: 2,
            forceReindex: false)
        XCTAssertTrue(replayed)
        let replayedHits = await search(replacement, "failure diagnostics")
        XCTAssertEqual(replayedHits, [value.id])
    }

    func testAuthorityRequestedLaunchRebuildRunsBeforeTheFirstProjectionRead() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let value = conversation(title: "Prior cache", userText: "authority requested rebuild")

        do {
            let prior = ConversationProjectionStore(appSupportBase: base)
            prior.index(value)
            prior.drain()
            let priorHits = await search(prior, "authority requested rebuild")
            XCTAssertEqual(priorHits, [value.id])
        }

        let rebuilt = ConversationProjectionStore(
            appSupportBase: base,
            rebuildBeforeOpen: true)
        let firstHits = await search(rebuilt, "authority requested rebuild")

        XCTAssertEqual(firstHits, [])
        XCTAssertFalse(rebuilt.isBroken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent(
            ConversationProjectionStore.rebuildMarkerName).path))
    }

    func testSupersededContentIsNotMaterializedIntoFTS() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        let withdrawn = TranscriptEntry(
            kind: .assistant,
            text: "WITHDRAWN-SUPERSESSION-SENTINEL")
        var conversation = Conversation(
            title: "Supersession", cwd: "", sdkSessionId: nil,
            messages: [
                TranscriptEntry(kind: .user, text: "ordinary retained prompt"),
                withdrawn,
            ],
            updatedAt: Date())

        store.index(conversation)
        store.drain()
        let initialHits = await search(store, "WITHDRAWN-SUPERSESSION-SENTINEL")
        XCTAssertEqual(initialHits, [conversation.id])

        conversation.messages[1].supersessionEventID = UUID()
        store.index(conversation)
        store.drain()

        let withdrawnHits = await search(store, "WITHDRAWN-SUPERSESSION-SENTINEL")
        let retainedHits = await search(store, "ordinary retained")
        XCTAssertEqual(withdrawnHits, [])
        XCTAssertEqual(retainedHits, [conversation.id])
        let projected = await summaries(store)
        let summary = try XCTUnwrap(projected.first)
        XCTAssertEqual(summary.snippet, "You: ordinary retained prompt")
        XCTAssertEqual(summary.messageCount, 1)
    }

    func testTypedSummaryCarriesCompleteInertSidebarFacts() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        let workspaceID = UUID()
        var c = conversation(
            title: "", userText: "first line\nsecond line",
            toolOutput: "transcript payload stays in FTS")
        c.cwd = "/tmp/Legacy Workspace"
        c.projectID = workspaceID
        c.favorite = true
        c.sortIndex = 7
        c.unread = true
        c.errored = true
        c.awaitingQuestion = true
        c.subagents["child"] = SubagentRun(
            key: "child", subagentType: "Explore", task: "Keep working")
        c.providerAccessRequest = ProviderAccessRequest(
            maker: .openAI,
            reason: "Continue the task",
            resumePrompts: ["resume"])
        c.armedTrigger = ArmedTrigger(
            note: "waiting for notarization",
            check: nil,
            deadline: nil,
            armedAt: Date(timeIntervalSinceReferenceDate: 100),
            expiresAt: Date(timeIntervalSinceReferenceDate: 200))

        let live = ConversationSummary(c)
        XCTAssertTrue(live.awaitingQuestion)
        XCTAssertTrue(live.hasRunningDelegate)

        store.index(c)
        store.drain()
        let projected = await summaries(store)
        let row = try XCTUnwrap(projected.first)
        XCTAssertEqual(row.id, c.id)
        XCTAssertEqual(row.displayTitle, "New conversation")
        XCTAssertEqual(row.workspaceCWD, "/tmp/Legacy Workspace")
        XCTAssertEqual(row.workspaceID, workspaceID)
        XCTAssertEqual(row.messageCount, 1, "tool/system rows are not sidebar messages")
        XCTAssertEqual(row.snippet, "You: first line second line")
        XCTAssertTrue(row.hasUserMessage)
        XCTAssertTrue(row.favorite)
        XCTAssertEqual(row.sortIndex, 7)
        XCTAssertTrue(row.unread)
        XCTAssertTrue(row.errored)
        XCTAssertEqual(row.providerAccessName, "OpenAI")
        XCTAssertEqual(row.armedWaitSummary, "for notarization")
        // Projection rows paint before authoritative load. They must never resurrect operative
        // activity whose process owner disappeared in the previous run.
        XCTAssertFalse(row.awaitingQuestion)
        XCTAssertFalse(row.hasRunningDelegate)
    }

    func testTypedSummarySearchesTitleAndFTSWithoutTranscriptPayload() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        let titleHit = conversation(
            title: "Release Train", userText: "ordinary conversation")
        let toolHit = conversation(
            title: "Diagnostics", userText: "ordinary conversation",
            toolOutput: "notarization ticket accepted")
        store.reconcile(with: [titleHit, toolHit])
        store.drain()

        let titleMatches = await summaries(store, matching: "release train")
        let toolMatches = await summaries(store, matching: "notarization ticket")
        let misses = await summaries(store, matching: "missing")
        XCTAssertEqual(titleMatches.map(\.id), [titleHit.id])
        XCTAssertEqual(toolMatches.map(\.id), [toolHit.id])
        XCTAssertEqual(misses, [])
    }

    func testReconcileRefreshesSummaryFactsWithoutRetokenizingRequirement() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        var c = conversation(title: "Before", userText: "unchanged transcript")
        store.index(c)
        store.drain()

        let workspaceID = UUID()
        c.title = "After"
        c.cwd = "/tmp/after"
        c.projectID = workspaceID
        c.unread = true
        c.favorite = true
        // Reconcile sees the same message count/id/byte stamp. Every summary field must still move.
        store.reconcile(with: [c])
        store.drain()

        let projected = await summaries(store)
        let row = try XCTUnwrap(projected.first)
        XCTAssertEqual(row.title, "After")
        XCTAssertEqual(row.workspaceCWD, "/tmp/after")
        XCTAssertEqual(row.workspaceID, workspaceID)
        XCTAssertTrue(row.unread)
        XCTAssertTrue(row.favorite)
        let hits = await search(store, "unchanged")
        XCTAssertEqual(hits, [c.id])
    }

    func testRemoveStopsMatching() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        let c = conversation(title: "Gone", userText: "ephemeral words")
        store.index(c)
        store.remove(c.id)
        store.drain()
        let hits = await search(store, "ephemeral")
        XCTAssertEqual(hits, [])
    }

    func testInPlaceToolResultMutationReindexes() async throws {
        // The content stamp must catch a tool result arriving on an EXISTING row (count and last
        // id unchanged) — only the byte length moves.
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        var c = conversation(title: "Mutating", userText: "run it", toolOutput: "started")
        store.index(c)
        store.drain()
        c.messages[1].toolResult = "started\nfinished with exit code 0"
        store.index(c)
        store.drain()
        let hits = await search(store, "exit code")
        XCTAssertEqual(hits, [c.id])
    }

    func testEqualByteContentReplacementReindexes() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        var c = conversation(title: "Equal bytes", userText: "alpha")
        store.index(c)
        store.drain()

        c.messages[0].text = "bravo" // same UTF-8 byte count; different searchable truth
        store.index(c)
        store.drain()

        let oldHits = await search(store, "alpha")
        let newHits = await search(store, "bravo")
        XCTAssertEqual(oldHits, [])
        XCTAssertEqual(newHits, [c.id])
    }

    func testReconcileBackfillsAndDropsOrphans() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let keep = conversation(title: "Keep", userText: "alpha bravo")
        let orphan = conversation(title: "Orphan", userText: "charlie delta")

        let first = ConversationProjectionStore(appSupportBase: base)
        first.index(orphan)
        first.drain()

        let second = ConversationProjectionStore(appSupportBase: base)
        second.reconcile(with: [keep])
        second.drain()
        let kept = await search(second, "alpha")
        XCTAssertEqual(kept, [keep.id], "reconcile must backfill conversations it has never seen")
        let dropped = await search(second, "charlie")
        XCTAssertEqual(dropped, [], "reconcile must drop rows whose conversation no longer exists")
    }

    func testReconcileCompletionReportsSuccessOnMainActorAfterQueuedWork() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        let c = conversation(title: "Completed", userText: "completion gate indexed this")

        let succeeded = await reconcile(store, with: [c])
        let hits = await search(store, "completion gate")

        XCTAssertTrue(succeeded)
        XCTAssertEqual(hits, [c.id])
    }

    func testReconcileCompletionReportsFailureWhenProjectionFailsClosed() async throws {
        let parent = try makeBase()
        defer { try? FileManager.default.removeItem(at: parent) }
        let nonDirectoryBase = parent.appendingPathComponent("not-a-directory")
        try Data("regular file".utf8).write(to: nonDirectoryBase)
        let store = ConversationProjectionStore(appSupportBase: nonDirectoryBase)

        let succeeded = await reconcile(
            store,
            with: [conversation(title: "Unavailable", userText: "must not be trusted")])
        let hits = await search(store, "trusted")

        XCTAssertFalse(succeeded)
        XCTAssertTrue(store.isBroken, "an unavailable projection must remain failed closed")
        XCTAssertNil(hits, "callers must receive the fallback signal")
    }

    func testDirectIndexCompletionReportsFailedClosedCache() async throws {
        let parent = try makeBase()
        defer { try? FileManager.default.removeItem(at: parent) }
        let nonDirectoryBase = parent.appendingPathComponent("not-a-directory")
        try Data("regular file".utf8).write(to: nonDirectoryBase)
        let store = ConversationProjectionStore(appSupportBase: nonDirectoryBase)

        let succeeded = await index(
            store,
            conversation: conversation(title: "Unavailable", userText: "callback sentinel"))
        XCTAssertFalse(succeeded)
        XCTAssertTrue(store.isBroken)
    }

    func testCorruptDatabaseFileIsDroppedAndRebuilt() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("projections.db")
        try Data("this is not a sqlite database".utf8).write(to: url)

        let store = ConversationProjectionStore(appSupportBase: base)
        let c = conversation(title: "Reborn", userText: "phoenix from garbage")
        store.reconcile(with: [c])
        store.drain()
        XCTAssertFalse(store.isBroken, "a corrupt cache has one remedy: drop and start over")
        let hits = await search(store, "phoenix")
        XCTAssertEqual(hits, [c.id])
    }

    func testSchemaVersionMismatchRebuilds() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = ConversationProjectionStore(appSupportBase: base)
        first.index(conversation(title: "Old", userText: "stale schema content"))
        first.drain()
        // Simulate a future/foreign schema by stamping an unknown user_version straight into
        // the SQLite header: offset 60, big-endian, per the documented file-format layout —
        // dependency-free and exactly what a future build's file would look like to this one.
        let url = base.appendingPathComponent("projections.db")
        var bytes = try Data(contentsOf: url)
        bytes.replaceSubrange(60..<64, with: [0, 0, 0, 99])
        try bytes.write(to: url)

        let second = ConversationProjectionStore(appSupportBase: base)
        second.reconcile(with: [conversation(title: "New", userText: "fresh schema content")])
        second.drain()
        XCTAssertFalse(second.isBroken)
        let stale = await search(second, "stale")
        XCTAssertEqual(stale, [], "a version-mismatched file must be dropped, not reused")
        let fresh = await search(second, "fresh")
        XCTAssertEqual(fresh?.count, 1)
    }

    func testCorrectlyStampedButStructurallyDamagedCacheRebuilds() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        var first: ConversationProjectionStore? = ConversationProjectionStore(appSupportBase: base)
        let old = conversation(title: "Old", userText: "damaged cache sentinel")
        first?.index(old)
        first?.drain()
        first = nil

        let url = base.appendingPathComponent("projections.db")
        try executeSQL(url, "DROP TABLE library_binding")
        let replacement = ConversationProjectionStore(appSupportBase: base)
        let fresh = conversation(title: "Fresh", userText: "structural rebuild sentinel")
        replacement.index(fresh)
        replacement.drain()

        XCTAssertFalse(replacement.isBroken)
        let damagedHits = await search(replacement, "damaged cache")
        let rebuiltHits = await search(replacement, "structural rebuild")
        XCTAssertEqual(damagedHits, [])
        XCTAssertEqual(rebuiltHits, [fresh.id])
    }

    func testLibraryCatchUpBindsInstanceAndRemovesOrphansOnlyAtClosedFrontier() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        let current = conversation(title: "Current", userText: "current library needle")
        let orphan = conversation(title: "Orphan", userText: "stale orphan needle")
        store.index(current, sourceRevision: "current-revision")
        store.index(orphan, sourceRevision: "orphan-revision")
        store.drain()

        let instance = UUID()
        let bound = await bindExactLibrarySnapshot(
            store,
            databaseInstanceID: instance,
            appliedSequence: 4)
        let orphanBeforeFinalize = await search(store, "stale orphan")
        XCTAssertTrue(bound)
        XCTAssertEqual(orphanBeforeFinalize, [orphan.id])

        let finalized = await finalizeLibraryCatchUp(
            store,
            frontier: ShadowLibraryProjectionFrontier(
                databaseInstanceID: instance,
                shadowChangeSequence: 5,
                liveConversationIDs: [current.id]))
        let currentHits = await search(store, "current library")
        let orphanAfterFinalize = await search(store, "stale orphan")
        XCTAssertTrue(finalized)
        XCTAssertEqual(currentHits, [current.id])
        XCTAssertEqual(orphanAfterFinalize, [])
    }

    func testForeignLibraryInstanceClearsPriorRowsBeforeApplyingWork() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        let old = conversation(title: "Old", userText: "foreign instance sentinel")
        let firstInstance = UUID()
        let firstApplied = await applyLibraryWork(
            store,
            conversation: old,
            entityID: old.id,
            sourceRevision: "old",
            databaseInstanceID: firstInstance,
            desiredSequence: 1)
        let oldHits = await search(store, "foreign instance")
        XCTAssertTrue(firstApplied)
        XCTAssertEqual(oldHits, [old.id])

        let replacement = conversation(title: "Replacement", userText: "new instance sentinel")
        let replacementApplied = await applyLibraryWork(
            store,
            conversation: replacement,
            entityID: replacement.id,
            sourceRevision: "new",
            databaseInstanceID: UUID(),
            desiredSequence: 1)
        let oldAfterReplacement = await search(store, "foreign instance")
        let replacementHits = await search(store, "new instance")
        XCTAssertTrue(replacementApplied)
        XCTAssertEqual(oldAfterReplacement, [])
        XCTAssertEqual(replacementHits, [replacement.id])
    }

    func testLibraryDeleteWorkIsIdempotent() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        let value = conversation(title: "Delete", userText: "delete replay sentinel")
        let instance = UUID()
        let inserted = await applyLibraryWork(
            store,
            conversation: value,
            entityID: value.id,
            sourceRevision: "one",
            databaseInstanceID: instance,
            desiredSequence: 1)
        XCTAssertTrue(inserted)
        for sequence in [2, 2] {
            let deleted = await applyLibraryWork(
                store,
                conversation: nil,
                entityID: value.id,
                sourceRevision: "",
                databaseInstanceID: instance,
                desiredSequence: Int64(sequence))
            XCTAssertTrue(deleted)
        }
        let hits = await search(store, "delete replay")
        XCTAssertEqual(hits, [])
        XCTAssertFalse(store.isBroken)
    }

    func testReconcileRemovesFTSOnlyGhostRows() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        store.drain()
        let ghostID = UUID()
        try executeSQL(
            base.appendingPathComponent("projections.db"),
            "INSERT INTO entry_fts (conversation_id, content) "
                + "VALUES ('\(ghostID.uuidString)', 'private ghost sentinel')")
        let ghostHits = await search(store, "private ghost")
        XCTAssertEqual(ghostHits, [ghostID])

        let reconciled = await reconcile(store, with: [])
        let clearedHits = await search(store, "private ghost")
        XCTAssertTrue(reconciled)
        XCTAssertEqual(clearedHits, [])
    }

    func testSidebarSnapshotUnionsContentMatchesAndSurvivesNil() {
        let tooled = conversation(
            title: "Tooled", userText: "unrelated words",
            toolOutput: "the only place SECRETWORD appears")
        let plain = conversation(title: "Plain", userText: "SECRETWORD in the message")
        let snapshotWithIndex = ConversationSidebarSnapshot.make(
            orderedConversations: [tooled, plain].map(ConversationSummary.init),
            scope: .home,
            projects: [],
            query: "secretword",
            contentMatches: [tooled.id])
        XCTAssertEqual(
            Set(snapshotWithIndex.visibleConversations.map(\.id)), [tooled.id, plain.id],
            "FTS adds the tool-output hit; the substring scan still finds the message hit")

        let snapshotWithoutIndex = ConversationSidebarSnapshot.make(
            orderedConversations: [tooled, plain].map(ConversationSummary.init),
            scope: .home,
            projects: [],
            query: "secretword",
            contentMatches: nil)
        XCTAssertEqual(
            snapshotWithoutIndex.visibleConversations.map(\.id), [plain.id],
            "with the index unavailable, behavior is exactly the pre-P1 substring scan")
    }

    func testConversationStoreFeedsProjectionAfterSave() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        let c = conversation(
            title: "Wired", userText: "hello there",
            toolOutput: "grep found 3 matches in AgentBridge.swift")
        store.upsert(c)
        store.flushSaves()          // sidecar write completes (projection enqueued after it)
        store.projections.drain()   // projection write completes
        let hits = await search(store.projections, "AgentBridge")
        XCTAssertEqual(hits, [c.id], "a saved conversation must become searchable, tool output included")

        _ = store.remove(c.id, permanently: true)
        store.flushSaves()
        store.projections.drain()
        let afterDelete = await search(store.projections, "AgentBridge")
        XCTAssertEqual(afterDelete, [], "deletion must drop projection rows with the sidecar")
    }

    // MARK: - Relevance

    /// Search used to answer an unordered `Set`, so the sidebar could only fall back to its
    /// pin-and-recency order: the conversation that mentioned a term once outranked the one that
    /// is about it, purely because it was newer. `bm25()` was already available and never called.
    func testRanksTheBetterMatchFirst() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        let passing = conversation(
            title: "Passing mention", userText: "we should look at the flaky test sometime")
        let about = conversation(
            title: "All about it",
            userText: "the flaky test is flaky because the flaky test races",
            toolOutput: "flaky test flaky test flaky test")
        store.index(passing)
        store.index(about)
        store.drain()

        let found = await rankedSearch(store, "flaky test")
        let hits = try XCTUnwrap(found)
        XCTAssertEqual(hits.map(\.id), [about.id, passing.id],
                       "the conversation the search is actually about must come first")
        // SQLite's convention: bm25 is negative and more negative is better, so best-first is
        // ascending. Getting this backwards would silently invert every search.
        XCTAssertLessThan(hits[0].score, hits[1].score)
    }

    /// One row per conversation, chosen as its best-scoring entry — not one row per matching entry.
    func testCollapsesManyMatchingEntriesToOneHitPerConversation() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        let c = conversation(
            title: "Repeats", userText: "needle in the first message",
            toolOutput: "needle again in tool output")
        store.index(c)
        store.drain()

        let found = await rankedSearch(store, "needle")
        let hits = try XCTUnwrap(found)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.id, c.id)
    }

    /// The excerpt is the point: a conversation can match on tool output from weeks ago while the
    /// row shows its most recent message, which explains nothing.
    func testCarriesTheTextThatMatched() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        let c = conversation(
            title: "Notarize", userText: "please ship the build",
            toolOutput: "notarization ticket 7F2A accepted by Apple")
        store.index(c)
        store.drain()

        let found = await rankedSearch(store, "ticket")
        let hits = try XCTUnwrap(found)
        let excerpt = try XCTUnwrap(hits.first?.excerpt)
        XCTAssertTrue(excerpt.contains("ticket 7F2A"),
                      "the excerpt must show the matched text, not the newest message")
    }

    func testAnEmptyOrUnmatchedQueryIsNotAnError() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationProjectionStore(appSupportBase: base)
        store.index(conversation(title: "Anything", userText: "hello"))
        store.drain()

        let blank = await rankedSearch(store, "   ")
        XCTAssertEqual(blank, [])
        let miss = await rankedSearch(store, "kubernetes")
        XCTAssertEqual(miss, [])
        let hostile = await rankedSearch(store, "NEAR AND \"quoted")
        XCTAssertNotNil(hostile, "hostile operator input must sanitize, not error the index")
    }

    /// The boundary, not the two methods that crossed it.
    ///
    /// `run` takes the connection without serializing — every caller is expected to be on the
    /// store's queue already, which is true of the private helpers and was silently untrue of two
    /// methods callers outside this file could reach. One `sqlite3` connection used from two
    /// threads segfaulted inside `sqlite3Prepare` on a click.
    ///
    /// This reads the source because the failure is structural: nothing about a bare `run(` is
    /// wrong in isolation, and a test that exercised either method alone passed.
    func testEveryReachableStoreMethodTakesTheQueueBeforeTheConnection() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Mechanician/ProjectionStore.swift"),
            encoding: .utf8)

        var offenders: [String] = []
        var name: String?
        var body = ""
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            // Method declarations at type scope, which is four spaces in this file.
            if let range = text.range(of: #"^    (?:@discardableResult )?(?:private |fileprivate )?func (\w+)"#,
                                      options: .regularExpression) {
                if let previous = name, previous != "run",
                   body.contains("run("), !body.contains("queue.sync"), !body.contains("queue.async") {
                    offenders.append(previous)
                }
                let declaration = String(text[range])
                name = declaration.contains("private") ? nil : String(declaration.split(separator: " ").last ?? "")
                body = ""
            } else {
                body += text
            }
        }
        if let last = name, last != "run", body.contains("run("),
           !body.contains("queue.sync"), !body.contains("queue.async") {
            offenders.append(last)
        }

        XCTAssertEqual(
            offenders, [],
            "these are reachable from outside the store and touch the connection without taking "
            + "its queue first")
    }
}
