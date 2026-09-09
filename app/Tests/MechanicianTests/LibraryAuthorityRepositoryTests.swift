import Foundation
import SQLite3
import XCTest
@testable import Mechanician

/// One activated SQLite authority over an empty imported library, plus the repository that writes
/// to it. The activation dance is long enough that repeating it per test obscures what each test is
/// actually asserting.
private struct ActivatedAuthorityHarness {
    let root: URL
    let store: SQLiteLibraryStore
    let repository: LibraryAuthorityRepository
    let activationID: UUID
    let conversation: Conversation

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "library-authority-repository-\(UUID().uuidString)",
            isDirectory: true)
        let home = HomeWorkspaceSettings(
            instructions: "Home",
            updatedAt: Date(timeIntervalSinceReferenceDate: 41_000))
        let homeBytes = try ConversationStore.makeEncoder().encode(home)
        var importStore: SQLiteLibraryStore? = try SQLiteLibraryStore(supportRoot: root)
        _ = try XCTUnwrap(importStore).reconcile(ShadowLibraryImportSnapshot(
            home: LibraryWorkspaceAdapter.capture(
                home: home,
                source: ShadowLibrarySourceFingerprint(
                    identity: "home-workspace.json",
                    revision: "legacy-home",
                    sourceBytes: homeBytes)),
            workspaces: [],
            conversations: []))
        let frontier = try XCTUnwrap(importStore).status()
        try XCTUnwrap(importStore).acknowledgeExactProjectionSnapshot(
            databaseInstanceID: frontier.databaseInstanceID,
            through: frontier.shadowChangeSequence,
            projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion))
        activationID = UUID()
        try XCTUnwrap(importStore).prepareAuthority(
            activationID: activationID,
            minimumWriterBuild: StorageAuthorityProtocol.recognitionID)
        try XCTUnwrap(importStore).activatePreparedAuthority(activationID: activationID)
        let metadata = try XCTUnwrap(importStore).authorityMetadata()
        let marker = StorageAuthorityMarker(
            mode: .sqlite,
            activationID: activationID,
            databaseInstanceID: metadata.databaseInstanceID,
            schemaVersion: metadata.schemaVersion,
            createdAt: "2026-08-05T12:00:00Z")
        importStore = nil
        store = try SQLiteLibraryStore.openActiveAuthority(supportRoot: root, marker: marker)
        repository = try LibraryAuthorityRepository(
            store: store,
            supportRoot: root,
            marker: marker)
        conversation = Conversation(
            title: "Live Conversation",
            cwd: "/tmp/live",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date(timeIntervalSinceReferenceDate: 42_000))
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}

final class LibraryAuthorityRepositoryTests: XCTestCase {
    private func executeSQL(_ databaseURL: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else {
            throw NSError(domain: "projection.worker.test.sqlite", code: 1)
        }
        defer { sqlite3_close_v2(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(
                domain: "projection.worker.test.sqlite",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    private func projectionAttempts(_ databaseURL: URL) throws -> Int64 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else { throw NSError(domain: "projection.worker.test.sqlite", code: 3) }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT COALESCE(SUM(attempt_count), 0) FROM projection_outbox",
            -1,
            &statement,
            nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "projection.worker.test.sqlite", code: 4)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "projection.worker.test.sqlite", code: 5)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func apply(
        _ work: ShadowLibraryProjectionWorkItem,
        to projection: ConversationProjectionStore
    ) async throws -> Bool {
        let conversation = try work.conversation.map(LibraryConversationAdapter.reconstruct)
        return await withCheckedContinuation { continuation in
            projection.applyLibraryWork(
                conversation: conversation,
                entityID: work.entityID,
                sourceRevision: work.conversation?.source.revision ?? "",
                databaseInstanceID: work.databaseInstanceID,
                desiredSequence: work.desiredSequence,
                forceReindex: work.forceReindex
            ) { continuation.resume(returning: $0) }
        }
    }

    private func search(
        _ projection: ConversationProjectionStore,
        _ query: String
    ) async -> Set<UUID>? {
        await withCheckedContinuation { continuation in
            projection.searchConversationIDs(matching: query) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func projectedSummaries(
        _ projection: ConversationProjectionStore
    ) async -> [ConversationSummary] {
        await withCheckedContinuation { continuation in
            projection.summaries { continuation.resume(returning: $0) }
        }
    }

    private func projectionMatches(
        _ projection: ConversationProjectionStore,
        summary: ConversationSummary,
        sourceRevision: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            projection.matchesAuthoritativeInventory(
                [summary],
                sourceRevisions: [summary.id: sourceRevision]
            ) { continuation.resume(returning: $0) }
        }
    }

    func testSQLiteRoundTripHealsReusedTerminalCardWithNewerOpenActivity() throws {
        let harness = try ActivatedAuthorityHarness()
        defer { harness.tearDown() }

        let selection = ModelSelection(
            access: .codexSubscription,
            modelID: "gpt-5")
        let newTurnStart = Date(timeIntervalSinceReferenceDate: 43_000)
        let laneEnd = newTurnStart.addingTimeInterval(7)
        let rootEnd = newTurnStart.addingTimeInterval(12)
        var child = SubagentRun(
            key: "spawn-call",
            subagentType: "Codex",
            task: "Audit the activity panel",
            status: .completed,
            startedAt: newTurnStart.addingTimeInterval(-100),
            endedAt: newTurnStart.addingTimeInterval(-90))
        child.taskId = "child-thread"
        child.startedCaptureOrdinal = 100
        child.endedCaptureOrdinal = 110

        var activity = [
            AgentActivityRecord.state(
                .model,
                turnID: "new-turn",
                at: newTurnStart)
                .attributed(to: selection),
            AgentActivityRecord.state(
                .model,
                turnID: "new-turn",
                agentID: AgentActivityIdentity.subagent("child-thread"),
                agentLabel: "Codex",
                detail: "Responding",
                at: newTurnStart.addingTimeInterval(2))
                .attributed(to: selection),
            AgentActivityRecord.tool(
                "RecallMemory",
                turnID: "new-turn",
                agentID: AgentActivityIdentity.subagent("child-thread"),
                agentLabel: "Codex",
                at: laneEnd)
                .attributed(to: selection),
            AgentActivityRecord.state(
                .completed,
                turnID: "new-turn",
                at: rootEnd)
                .attributed(to: selection),
        ]
        for index in activity.indices {
            activity[index].captureOrdinal = UInt64(200 + index)
        }

        var original = harness.conversation
        original.modelSelection = selection
        original.messages = [TranscriptEntry(kind: .user, text: "Verify the release")]
        original.updatedAt = rootEnd
        original.subagents = [child.key: child]
        original.agentActivity = activity
        original.captureOrdinalHighWatermark = 203
        _ = try harness.repository.commit(conversation: original)

        let stored = try XCTUnwrap(harness.store.authoritativeConversationSnapshot(
            id: original.id,
            activationID: harness.activationID))
        var reconstructed = try LibraryConversationAdapter.reconstruct(from: stored)
        XCTAssertEqual(reconstructed.subagents["spawn-call"]?.endedCaptureOrdinal, 110)
        XCTAssertFalse(agentActivityTurnSummaries(
            reconstructed.agentActivity,
            aliases: agentActivityAliases(subagents: reconstructed.subagents))[0].isTerminal)

        XCTAssertTrue(ConversationStore.healStaleState(&reconstructed))
        XCTAssertEqual(reconstructed.subagents["spawn-call"]?.status, .completed)
        XCTAssertEqual(reconstructed.subagents["spawn-call"]?.endedCaptureOrdinal, 110)
        let repairedAliases = agentActivityAliases(subagents: reconstructed.subagents)
        let repairedLane = canonicalizedAgentActivityGroups(
            reconstructed.agentActivity.filter { $0.turnID == "new-turn" },
            aliases: repairedAliases)[AgentActivityIdentity.subagent("spawn-call")] ?? []
        XCTAssertEqual(repairedLane.last {
            $0.kind == .state && $0.phase == .stopped
        }?.at, laneEnd)
        XCTAssertTrue(agentActivityTurnSummaries(
            reconstructed.agentActivity,
            aliases: repairedAliases)[0].isTerminal)

        _ = try harness.repository.commit(conversation: reconstructed)
        let healedSnapshot = try XCTUnwrap(harness.store.authoritativeConversationSnapshot(
            id: original.id,
            activationID: harness.activationID))
        var restarted = try LibraryConversationAdapter.reconstruct(from: healedSnapshot)
        let healedCount = restarted.agentActivity.count
        XCTAssertFalse(ConversationStore.healStaleState(&restarted))
        XCTAssertEqual(restarted.agentActivity.count, healedCount)
        XCTAssertTrue(agentActivityTurnSummaries(
            restarted.agentActivity,
            aliases: agentActivityAliases(subagents: restarted.subagents))[0].isTerminal)
    }

    func testTitleOnlyCommitAppliesSummaryWithoutReindexingTranscript() async throws {
        let harness = try ActivatedAuthorityHarness()
        defer { harness.tearDown() }

        var original = harness.conversation
        original.messages = [
            TranscriptEntry(kind: .user, text: "searchable transcript stays byte-for-byte stable"),
        ]
        _ = try harness.repository.commit(conversation: original)
        let initialWork = try XCTUnwrap(harness.store.nextProjectionWork(
            projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion)))
        let projection = ConversationProjectionStore(appSupportBase: harness.root)
        let initialApplied = try await apply(initialWork, to: projection)
        XCTAssertTrue(initialApplied)
        try harness.store.acknowledgeProjectionWork(
            initialWork,
            projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion))

        let storedBefore = try XCTUnwrap(harness.store.authoritativeConversationSnapshot(
            id: original.id,
            activationID: harness.activationID))
        var renamed = original
        renamed.title = "Renamed without touching search content"
        renamed.titleSource = .manual
        let result = try harness.repository.commit(
            conversation: renamed,
            changedTranscriptEntryIDs: [],
            priorConversation: original)

        XCTAssertFalse(result.searchableContentChanged)
        let work = try XCTUnwrap(harness.store.nextProjectionWork(
            projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion)))
        XCTAssertFalse(work.forceReindex)
        XCTAssertEqual(work.conversation?.title, renamed.title)
        XCTAssertEqual(work.conversation?.titleSource, renamed.titleSource.rawValue)
        let titleApplied = try await apply(work, to: projection)
        XCTAssertTrue(titleApplied)
        try harness.store.acknowledgeProjectionWork(
            work,
            projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion))

        let projectedConversation = try LibraryConversationAdapter.reconstruct(
            from: XCTUnwrap(work.conversation))
        let allProjectedSummaries = await projectedSummaries(projection)
        let projected = try XCTUnwrap(
            allProjectedSummaries.first(where: { $0.id == renamed.id }))
        XCTAssertEqual(projected.title, renamed.title)
        let projectedRevision = try XCTUnwrap(work.conversation?.source.revision)
        let exactMatch = await projectionMatches(
            projection,
            summary: ConversationSummary(projectedConversation),
            sourceRevision: projectedRevision)
        XCTAssertTrue(exactMatch)
        let transcriptHits = await search(projection, "searchable transcript")
        XCTAssertEqual(transcriptHits, [renamed.id])

        let storedAfter = try XCTUnwrap(harness.store.authoritativeConversationSnapshot(
            id: original.id,
            activationID: harness.activationID))
        XCTAssertEqual(storedAfter.events, storedBefore.events)
        XCTAssertEqual(storedAfter.nestedArtifacts, storedBefore.nestedArtifacts)
    }

    func testProjectionWorkerRetiresFailedCacheForSessionWithoutRetryAmplification() async throws {
        let harness = try ActivatedAuthorityHarness()
        defer { harness.tearDown() }

        var first = harness.conversation
        first.messages = [
            TranscriptEntry(kind: .user, text: "automatic projection recovery sentinel"),
        ]
        var second = first
        second.id = UUID()
        second.title = "Second live conversation"
        second.messages = [
            TranscriptEntry(kind: .user, text: "second replay sentinel"),
        ]
        _ = try harness.repository.commit(conversation: first)
        _ = try harness.repository.commit(conversation: second)
        let projection = ConversationProjectionStore(appSupportBase: harness.root)
        projection.drain()
        try executeSQL(
            harness.root.appendingPathComponent("projections.db"),
            """
            CREATE TRIGGER inject_projection_worker_failure
            BEFORE INSERT ON summaries
            BEGIN
              SELECT RAISE(ABORT, 'injected projection worker failure');
            END
            """)

        let inventory = try harness.repository.launchInventory()
        let reconciled = await withCheckedContinuation { continuation in
            harness.repository.reconcileProjection(
                projection,
                inventory: inventory
            ) { succeeded in
                continuation.resume(returning: succeeded)
            }
        }
        XCTAssertFalse(reconciled)
        XCTAssertTrue(projection.isBroken)
        let brokenHits = await search(projection, "automatic projection recovery")
        XCTAssertNil(brokenHits)
        XCTAssertEqual(try harness.store.projectionBacklogCount(), 2)
        XCTAssertTrue(try harness.store.conversationProjectionCacheRequiresRebuild())
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.root.appendingPathComponent(
            ConversationProjectionStore.rebuildMarkerName).path))

        let attemptsBefore = try projectionAttempts(
            harness.root.appendingPathComponent("library.db"))
        let beforeRename = first
        first.title = "Rename after projection retirement"
        _ = try harness.repository.commit(
            conversation: first,
            changedTranscriptEntryIDs: [],
            priorConversation: beforeRename)
        let refreshedInventory = try harness.repository.launchInventory()
        let retried = await withCheckedContinuation { continuation in
            harness.repository.reconcileProjection(
                projection,
                inventory: refreshedInventory
            ) { succeeded in
                continuation.resume(returning: succeeded)
            }
        }
        XCTAssertFalse(retried)
        XCTAssertEqual(
            try projectionAttempts(harness.root.appendingPathComponent("library.db")),
            attemptsBefore,
            "a session-terminal projection must not reconstruct or claim another authority row")
        XCTAssertTrue(try harness.store.conversationProjectionCacheRequiresRebuild())
    }

    /// A partial transcript delta is computed against the caller's idea of the last committed value.
    /// That value can lag the database, because it is republished on the main actor after the commit
    /// queue has already moved on. A transcript entry that appeared and vanished inside that window
    /// is in neither the caller's baseline nor its new value, so the delta never names it and the
    /// stored row is neither removed nor moved. The write must still land, and must not strand it.
    func testPartialCommitRemovesRowsAbsentFromAnUnderReportedDelta() throws {
        let harness = try ActivatedAuthorityHarness()
        defer { harness.tearDown() }

        let first = TranscriptEntry(kind: .user, text: "first")
        let second = TranscriptEntry(kind: .assistant, text: "second")
        var conversation = harness.conversation
        conversation.messages = [first, second]
        _ = try harness.repository.commit(conversation: conversation)

        // The window: an entry is appended and committed while the caller still believes the last
        // committed value is the two-message record.
        let transient = TranscriptEntry(kind: .assistant, text: "streamed then withdrawn")
        var withTransient = conversation
        withTransient.messages = [first, second, transient]
        _ = try harness.repository.commit(
            conversation: withTransient,
            changedTranscriptEntryIDs: [transient.id],
            priorConversation: conversation)

        // The entry is withdrawn. The delta is taken against the stale baseline, so it is empty and
        // never names the stored row that is about to be displaced.
        let result = try harness.repository.commit(
            conversation: conversation,
            changedTranscriptEntryIDs: [],
            priorConversation: conversation)
        XCTAssertTrue(
            result.searchableContentChanged,
            "the withdrawn text must leave the search index with its row")

        let reloaded = try XCTUnwrap(harness.store.authoritativeConversationSnapshot(
            id: conversation.id,
            activationID: harness.activationID))
        XCTAssertEqual(
            reloaded.events.filter { $0.kind.hasPrefix("transcript.") }.map(\.id),
            [first.id, second.id],
            "the withdrawn entry must not survive as a stored row")
        XCTAssertEqual(
            reloaded.events.map(\.captureSequence),
            Array(0..<Int64(reloaded.events.count)),
            "capture sequences must stay dense so the record can be reconstructed")
        XCTAssertEqual(
            try LibraryConversationAdapter.reconstruct(from: reloaded).messages.map(\.id),
            [first.id, second.id])
    }

    /// The same under-reported delta, but with the stranded row far beyond the new event range so it
    /// collides with nothing. Left in place it opens a gap in the capture sequence, which fails
    /// reconstruction later instead of at the write. The write must close it now.
    func testPartialCommitRemovesStrandedRowsBeyondTheNewEventRange() throws {
        let harness = try ActivatedAuthorityHarness()
        defer { harness.tearDown() }

        let retained = TranscriptEntry(kind: .user, text: "retained")
        var conversation = harness.conversation
        conversation.messages = [retained]
        _ = try harness.repository.commit(conversation: conversation)

        let withdrawn = (0..<6).map { TranscriptEntry(kind: .assistant, text: "withdrawn \($0)") }
        var grown = conversation
        grown.messages = [retained] + withdrawn
        _ = try harness.repository.commit(
            conversation: grown,
            changedTranscriptEntryIDs: Set(withdrawn.map(\.id)),
            priorConversation: conversation)

        _ = try harness.repository.commit(
            conversation: conversation,
            changedTranscriptEntryIDs: [],
            priorConversation: conversation)

        let reloaded = try XCTUnwrap(harness.store.authoritativeConversationSnapshot(
            id: conversation.id,
            activationID: harness.activationID))
        XCTAssertEqual(
            reloaded.events.filter { $0.kind.hasPrefix("transcript.") }.map(\.id),
            [retained.id])
        XCTAssertEqual(
            reloaded.events.map(\.captureSequence),
            Array(0..<Int64(reloaded.events.count)))
        XCTAssertEqual(
            try LibraryConversationAdapter.reconstruct(from: reloaded).messages.map(\.id),
            [retained.id])
    }

    /// An under-reported delta must not be read as permission to drop rows the record still holds.
    /// Only entries the live Conversation no longer lists may be removed.
    func testPartialCommitKeepsUnchangedRowsTheDeltaOmits() throws {
        let harness = try ActivatedAuthorityHarness()
        defer { harness.tearDown() }

        let entries = (0..<4).map { TranscriptEntry(kind: .user, text: "entry \($0)") }
        var conversation = harness.conversation
        conversation.messages = entries
        _ = try harness.repository.commit(conversation: conversation)

        var edited = conversation
        edited.messages[2].text = "edited"
        _ = try harness.repository.commit(
            conversation: edited,
            changedTranscriptEntryIDs: [entries[2].id],
            priorConversation: conversation)

        let reloaded = try XCTUnwrap(harness.store.authoritativeConversationSnapshot(
            id: conversation.id,
            activationID: harness.activationID))
        let rebuilt = try LibraryConversationAdapter.reconstruct(from: reloaded)
        XCTAssertEqual(rebuilt.messages.map(\.id), entries.map(\.id))
        XCTAssertEqual(rebuilt.messages[2].text, "edited")
        XCTAssertEqual(rebuilt.messages[0].text, "entry 0")
    }

    /// An under-reported delta can also leave a row that must move without naming it. The stored
    /// payload is still correct, so only its position is rewritten, and it must not be left parked
    /// at the negative sequence the reorder uses to clear the unique index.
    func testPartialCommitMovesUnchangedRowsTheDeltaDidNotName() throws {
        let harness = try ActivatedAuthorityHarness()
        defer { harness.tearDown() }

        let existing = (0..<3).map { TranscriptEntry(kind: .user, text: "existing \($0)") }
        var conversation = harness.conversation
        conversation.messages = existing
        _ = try harness.repository.commit(conversation: conversation)

        let inserted = TranscriptEntry(kind: .user, text: "inserted at the front")
        var reordered = conversation
        reordered.messages = [inserted] + existing
        // Only the new entry is named, so the three displaced rows are unreported movers.
        _ = try harness.repository.commit(
            conversation: reordered,
            changedTranscriptEntryIDs: [inserted.id],
            priorConversation: conversation)

        let reloaded = try XCTUnwrap(harness.store.authoritativeConversationSnapshot(
            id: conversation.id,
            activationID: harness.activationID))
        XCTAssertEqual(
            reloaded.events.map(\.captureSequence),
            Array(0..<Int64(reloaded.events.count)))
        let rebuilt = try LibraryConversationAdapter.reconstruct(from: reloaded)
        XCTAssertEqual(rebuilt.messages.map(\.id), [inserted.id] + existing.map(\.id))
        XCTAssertEqual(rebuilt.messages.map(\.text), reordered.messages.map(\.text))
    }

    /// A delta names the rows that changed; the ordering names the rows that exist. Given only the
    /// first, the write cannot tell a row the capture omitted from a row the record dropped, and it
    /// would delete the transcript down to whatever the delta happened to name. Refuse instead.
    func testPartialCaptureWithoutTheLiveOrderIsRefusedRatherThanGuessed() throws {
        let harness = try ActivatedAuthorityHarness()
        defer { harness.tearDown() }

        let entries = (0..<3).map { TranscriptEntry(kind: .user, text: "entry \($0)") }
        var conversation = harness.conversation
        conversation.messages = entries
        _ = try harness.repository.commit(conversation: conversation)

        var edited = conversation
        edited.messages[1].text = "edited"
        let capture = try LibraryConversationAdapter.capture(
            edited,
            source: ShadowLibrarySourceFingerprint(
                identity: "conversations/\(conversation.id.uuidString).json",
                revision: "2",
                sourceBytes: Data("x".utf8)),
            changedTranscriptEntryIDs: [entries[1].id])
        XCTAssertThrowsError(
            try harness.store.commitAuthoritativeMutation(
                conversation: capture,
                changedTranscriptEntryIDs: [entries[1].id],
                activationID: harness.activationID))

        let reloaded = try XCTUnwrap(harness.store.authoritativeConversationSnapshot(
            id: conversation.id,
            activationID: harness.activationID))
        XCTAssertEqual(
            try LibraryConversationAdapter.reconstruct(from: reloaded).messages.map(\.id),
            entries.map(\.id),
            "the refused write must leave every row in place")
    }

    /// The same cross-owner media reference that blocked a migration also refused every save that
    /// touched it, once the library was migrated. Forking a Conversation that contains an image
    /// produces one, so this is an ordinary record, not a damaged one.
    func testAConversationSharingAnotherOnesMediaCanStillBeSaved() throws {
        let harness = try ActivatedAuthorityHarness()
        defer { harness.tearDown() }

        let otherOwner = UUID()
        let mediaDirectory = harness.root
            .appendingPathComponent("conversation-media", isDirectory: true)
            .appendingPathComponent(otherOwner.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: mediaDirectory, withIntermediateDirectories: true)
        let image = mediaDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try Data(repeating: 5, count: 128).write(to: image)

        var conversation = harness.conversation
        conversation.messages = [
            TranscriptEntry(kind: .user, text: "carried over by a fork", imagePaths: [image.path]),
        ]
        XCTAssertNoThrow(try harness.repository.commit(conversation: conversation))

        let reloaded = try XCTUnwrap(harness.store.authoritativeConversationSnapshot(
            id: conversation.id,
            activationID: harness.activationID))
        let rebuilt = try LibraryConversationAdapter.reconstruct(from: reloaded)
        XCTAssertEqual(
            rebuilt.messages.first?.imagePaths, [image.path],
            "the transcript keeps the path verbatim, which is what the renderer resolves")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: image.path),
            "and the bytes it names are untouched")
    }

    /// Spotlight and the App Intents entity queries read these summaries. A conversation created
    /// after the cutover exists only in the database, so if this read ever missed one, Siri could
    /// not open it and Spotlight could not find it — which is exactly what reading the frozen
    /// legacy directory did.
    func testConversationSummariesSeeWorkDoneAfterActivation() throws {
        let harness = try ActivatedAuthorityHarness()
        defer { harness.tearDown() }

        var first = harness.conversation
        first.title = "Created after activation"
        first.messages = [
            TranscriptEntry(kind: .user, text: "the first thing I asked"),
            TranscriptEntry(kind: .assistant, text: "the reply"),
        ]
        _ = try harness.repository.commit(conversation: first)

        let second = Conversation(
            title: "Also after activation",
            cwd: "/tmp/second",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "second conversation")],
            updatedAt: Date(timeIntervalSinceReferenceDate: 50_000))
        _ = try harness.repository.commit(conversation: second)

        let summaries = try harness.repository.conversationSummaries()
        XCTAssertEqual(Set(summaries.map(\.id)), [first.id, second.id])
        let firstSummary = try XCTUnwrap(summaries.first { $0.id == first.id })
        XCTAssertEqual(firstSummary.title, "Created after activation")
        XCTAssertEqual(firstSummary.messageCount, 2)
        XCTAssertFalse(firstSummary.snippet.isEmpty)

        // These summaries are what the index is built from, so the mapping must carry the facts a
        // picker shows.
        let indexed = summaries.map(IndexedConversation.init)
        XCTAssertEqual(
            indexed.first { $0.id == first.id }?.displayTitle,
            "Created after activation")

        _ = try harness.repository.deleteConversation(id: second.id)
        let afterDelete = try harness.repository.conversationSummaries()
        XCTAssertEqual(
            afterDelete.map(\.id),
            [first.id],
            "a deleted conversation must stop being offered")
    }

    /// The rule the readers depend on, stated once: the legacy directories may answer a read
    /// exactly when they may still be written.
    func testLegacyDirectoriesAnswerReadsOnlyWhileTheyMayStillBeWritten() throws {
        let root = URL(fileURLWithPath: "/tmp/mechanician-index-source", isDirectory: true)
        let marker = StorageAuthorityMarker(
            mode: .sqlite,
            activationID: UUID(),
            databaseInstanceID: UUID(),
            schemaVersion: 6,
            createdAt: "2026-08-05T12:00:00Z")

        func recognition(
            _ disposition: StorageAuthorityLaunchDisposition
        ) -> StorageAuthorityRecognition {
            StorageAuthorityRecognition(
                anchorRoot: root,
                effectiveSupportRoot: root,
                marker: .absent,
                disposition: disposition)
        }

        XCTAssertEqual(
            IndexedLibrarySource.legacyDirectoryRoot(
                for: recognition(.legacyUnmarked(database: nil))),
            root,
            "a pre-migration install still reads its files")
        XCTAssertEqual(
            IndexedLibrarySource.legacyDirectoryRoot(
                for: recognition(.legacyGeneration(marker: marker, root: root))),
            root,
            "a selected rollback generation is a live legacy library")
        XCTAssertNil(
            IndexedLibrarySource.legacyDirectoryRoot(
                for: recognition(.blocked("uncertain"))),
            "a blocked launch has not established which library is real")
        XCTAssertNil(
            IndexedLibrarySource.legacyDirectoryRoot(for: recognition(.sqlite(
                marker: marker,
                database: StorageAuthorityDatabaseProbe(
                    databaseInstanceID: marker.databaseInstanceID,
                    schemaVersion: marker.schemaVersion,
                    authorityState: .active,
                    activationID: marker.activationID,
                    rollbackID: nil,
                    minimumWriterBuild: nil,
                    committedSequence: 1)))),
            "under SQLite authority the directories are a frozen snapshot, never a read source")
    }

    func testConversationMutationPreservesImportedSourceIdentityAndByteCount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "library-authority-repository-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let conversation = Conversation(
            title: "Imported Conversation",
            cwd: "/tmp/imported",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "original prompt")],
            updatedAt: Date(timeIntervalSinceReferenceDate: 42_000))
        let sourceIdentity = "conversations/imported-source.json"
        let sourceBytes = try ConversationStore.makeEncoder().encode(conversation)
        let home = HomeWorkspaceSettings(
            instructions: "Home",
            updatedAt: Date(timeIntervalSinceReferenceDate: 41_000))
        let homeBytes = try ConversationStore.makeEncoder().encode(home)

        var shadowStore: SQLiteLibraryStore? = try SQLiteLibraryStore(supportRoot: root)
        _ = try XCTUnwrap(shadowStore).reconcile(ShadowLibraryImportSnapshot(
            home: LibraryWorkspaceAdapter.capture(
                home: home,
                source: ShadowLibrarySourceFingerprint(
                    identity: "home-workspace.json",
                    revision: "legacy-home",
                    sourceBytes: homeBytes)),
            workspaces: [],
            conversations: [try LibraryConversationAdapter.capture(
                conversation,
                source: ShadowLibrarySourceFingerprint(
                    identity: sourceIdentity,
                    revision: "legacy-conversation",
                    sourceBytes: sourceBytes))]))
        let frontier = try XCTUnwrap(shadowStore).status()
        try XCTUnwrap(shadowStore).acknowledgeExactProjectionSnapshot(
            databaseInstanceID: frontier.databaseInstanceID,
            through: frontier.shadowChangeSequence,
            projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion))
        let activationID = UUID()
        try XCTUnwrap(shadowStore).prepareAuthority(
            activationID: activationID,
            minimumWriterBuild: StorageAuthorityProtocol.recognitionID)
        try XCTUnwrap(shadowStore).activatePreparedAuthority(activationID: activationID)
        let metadata = try XCTUnwrap(shadowStore).authorityMetadata()
        let marker = StorageAuthorityMarker(
            mode: .sqlite,
            activationID: activationID,
            databaseInstanceID: metadata.databaseInstanceID,
            schemaVersion: metadata.schemaVersion,
            createdAt: "2026-08-05T12:00:00Z")
        shadowStore = nil
        let activeStore = try SQLiteLibraryStore.openActiveAuthority(
            supportRoot: root,
            marker: marker)
        let repository = try LibraryAuthorityRepository(
            store: activeStore,
            supportRoot: root,
            marker: marker)

        var changed = conversation
        changed.title = "Edited after activation"
        _ = try repository.commit(conversation: changed)

        let receipt = try XCTUnwrap(try activeStore.authoritativeConversationSource(
            id: conversation.id,
            activationID: activationID))
        XCTAssertEqual(receipt.identity, sourceIdentity)
        XCTAssertEqual(receipt.byteCount, sourceBytes.count)
        XCTAssertTrue(receipt.revision.hasPrefix("sqlite:"))
    }

    func testConversationWorkEvidenceRoundTripsByRepositoryAndConversation() throws {
        let harness = try ActivatedAuthorityHarness()
        defer { harness.tearDown() }
        _ = try harness.repository.commit(conversation: harness.conversation)

        let observationID = UUID()
        let promptID = UUID()
        let finalID = UUID()
        let observedAt = Date(timeIntervalSinceReferenceDate: 52_000)
        let repositoryID = "git-common-dir:mechanician-tests"
        let observation = ConversationRepositoryObservation(
            id: observationID,
            conversationID: harness.conversation.id,
            turnID: "turn-1",
            toolUseID: "tool-1",
            reason: .turnCompleted,
            rootPromptEntryID: promptID,
            finalAssistantEntryID: finalID,
            rootPromptExcerpt: "Please update the feature.",
            rootPromptExcerptWasTruncated: false,
            finalAssistantExcerpt: "Updated the feature and verified it.",
            finalAssistantExcerptWasTruncated: false,
            repositoryID: repositoryID,
            gitCommonDirectory: "/tmp/mechanician-tests/.git",
            worktreePath: "/tmp/mechanician-tests",
            workspaceID: nil,
            canonicalCWD: "/tmp/mechanician-tests/app",
            headState: .attached,
            symbolicRef: "refs/heads/dev",
            headOID: String(repeating: "a", count: 40),
            statusAvailability: .available,
            indexChangeCount: 1,
            worktreeChangeCount: 2,
            untrackedCount: 0,
            attribution: .directTool,
            observedAt: observedAt)
        let file = ConversationFileObservation(
            id: UUID(),
            repositoryObservationID: observationID,
            conversationID: harness.conversation.id,
            turnID: "turn-1",
            toolUseID: "tool-1",
            repositoryID: repositoryID,
            repositoryRelativePath: "app/Sources/Feature.swift",
            operation: .edit,
            attribution: .directTool,
            beforeDigest: String(repeating: "b", count: 64),
            afterDigest: String(repeating: "c", count: 64),
            beforeExists: true,
            afterExists: true,
            boundedPatch: "- old\n+ new",
            patchWasTruncated: false,
            observedAt: observedAt)

        let committed = try harness.repository.recordConversationWorkEvidence(
            repository: observation,
            files: [file])
        XCTAssertEqual(
            try harness.repository.conversationWorkEvidence(repositoryID: repositoryID),
            [ConversationWorkEvidence(repository: observation, files: [file])])
        XCTAssertEqual(
            try harness.repository.conversationWorkEvidence(
                conversationID: harness.conversation.id),
            [ConversationWorkEvidence(repository: observation, files: [file])])

        // Exact replay neither replaces the immutable rows nor advances authority generation.
        XCTAssertEqual(
            try harness.repository.recordConversationWorkEvidence(
                repository: observation,
                files: [file]),
            committed)
        XCTAssertEqual(
            try harness.repository.authoritySnapshotGeneration().committedSequence,
            committed)
    }

    func testConversationWorkEvidenceRejectsIdentityCollisionsAndUnprovenDigests() throws {
        let harness = try ActivatedAuthorityHarness()
        defer { harness.tearDown() }
        _ = try harness.repository.commit(conversation: harness.conversation)

        let observationID = UUID()
        let promptID = UUID()
        let base = ConversationRepositoryObservation(
            id: observationID,
            conversationID: harness.conversation.id,
            turnID: "turn-2",
            toolUseID: nil,
            reason: .turnStarted,
            rootPromptEntryID: promptID,
            finalAssistantEntryID: nil,
            rootPromptExcerpt: "Start the work.",
            rootPromptExcerptWasTruncated: false,
            finalAssistantExcerpt: nil,
            finalAssistantExcerptWasTruncated: nil,
            repositoryID: "git-common-dir:collision-test",
            gitCommonDirectory: "/tmp/collision-test/.git",
            worktreePath: "/tmp/collision-test",
            workspaceID: nil,
            canonicalCWD: "/tmp/collision-test",
            headState: .unborn,
            symbolicRef: "refs/heads/main",
            headOID: nil,
            statusAvailability: .available,
            indexChangeCount: 0,
            worktreeChangeCount: 0,
            untrackedCount: 0,
            attribution: nil,
            observedAt: Date(timeIntervalSinceReferenceDate: 53_000))
        _ = try harness.repository.recordConversationWorkEvidence(repository: base, files: [])

        let collision = ConversationRepositoryObservation(
            id: observationID,
            conversationID: harness.conversation.id,
            turnID: "turn-2",
            toolUseID: nil,
            reason: .turnStarted,
            rootPromptEntryID: promptID,
            finalAssistantEntryID: nil,
            rootPromptExcerpt: "Start the work.",
            rootPromptExcerptWasTruncated: false,
            finalAssistantExcerpt: nil,
            finalAssistantExcerptWasTruncated: nil,
            repositoryID: "git-common-dir:collision-test",
            gitCommonDirectory: "/tmp/collision-test/.git",
            worktreePath: "/tmp/collision-test",
            workspaceID: nil,
            canonicalCWD: "/tmp/collision-test",
            headState: .attached,
            symbolicRef: "refs/heads/main",
            headOID: String(repeating: "d", count: 40),
            statusAvailability: .available,
            indexChangeCount: 0,
            worktreeChangeCount: 0,
            untrackedCount: 0,
            attribution: nil,
            observedAt: Date(timeIntervalSinceReferenceDate: 53_000))
        XCTAssertThrowsError(
            try harness.repository.recordConversationWorkEvidence(
                repository: collision,
                files: []))

        let toolObservation = ConversationRepositoryObservation(
            id: UUID(),
            conversationID: harness.conversation.id,
            turnID: "turn-3",
            toolUseID: "tool-3",
            reason: .toolCompleted,
            rootPromptEntryID: promptID,
            finalAssistantEntryID: nil,
            rootPromptExcerpt: "Start the work.",
            rootPromptExcerptWasTruncated: false,
            finalAssistantExcerpt: nil,
            finalAssistantExcerptWasTruncated: nil,
            repositoryID: "git-common-dir:collision-test",
            gitCommonDirectory: "/tmp/collision-test/.git",
            worktreePath: "/tmp/collision-test",
            workspaceID: nil,
            canonicalCWD: "/tmp/collision-test",
            headState: .attached,
            symbolicRef: "refs/heads/main",
            headOID: String(repeating: "d", count: 40),
            statusAvailability: .available,
            indexChangeCount: 0,
            worktreeChangeCount: 1,
            untrackedCount: 0,
            attribution: .directTool,
            observedAt: Date(timeIntervalSinceReferenceDate: 53_001))
        let unproven = ConversationFileObservation(
            id: UUID(),
            repositoryObservationID: toolObservation.id,
            conversationID: harness.conversation.id,
            turnID: "turn-3",
            toolUseID: "tool-3",
            repositoryID: toolObservation.repositoryID,
            repositoryRelativePath: "Feature.swift",
            operation: .edit,
            attribution: .directTool,
            beforeDigest: String(repeating: "e", count: 64),
            afterDigest: nil,
            beforeExists: nil,
            afterExists: false,
            boundedPatch: nil,
            patchWasTruncated: false,
            observedAt: toolObservation.observedAt)
        XCTAssertThrowsError(
            try harness.repository.recordConversationWorkEvidence(
                repository: toolObservation,
                files: [unproven]))
        XCTAssertEqual(
            try harness.repository.conversationWorkEvidence(
                conversationID: harness.conversation.id).count,
            1,
            "failed admission must not publish its repository parent")
    }

    func testConversationWorkEvidenceRetainsHeadWhenStatusCountsAreUnavailable() throws {
        let harness = try ActivatedAuthorityHarness()
        defer { harness.tearDown() }
        _ = try harness.repository.commit(conversation: harness.conversation)

        let observation = ConversationRepositoryObservation(
            id: UUID(),
            conversationID: harness.conversation.id,
            turnID: "turn-status-unavailable",
            toolUseID: nil,
            reason: .changesRefresh,
            rootPromptEntryID: nil,
            finalAssistantEntryID: nil,
            rootPromptExcerpt: nil,
            rootPromptExcerptWasTruncated: nil,
            finalAssistantExcerpt: nil,
            finalAssistantExcerptWasTruncated: nil,
            repositoryID: "/tmp/status-unavailable/.git",
            gitCommonDirectory: "/tmp/status-unavailable/.git",
            worktreePath: "/tmp/status-unavailable",
            workspaceID: nil,
            canonicalCWD: "/tmp/status-unavailable",
            headState: .attached,
            symbolicRef: "refs/heads/dev",
            headOID: String(repeating: "a", count: 40),
            statusAvailability: .unavailable,
            indexChangeCount: nil,
            worktreeChangeCount: nil,
            untrackedCount: nil,
            attribution: nil,
            observedAt: Date(timeIntervalSinceReferenceDate: 53_100))

        _ = try harness.repository.recordConversationWorkEvidence(
            repository: observation,
            files: [])
        XCTAssertEqual(
            try harness.repository.conversationWorkEvidence(
                conversationID: harness.conversation.id),
            [ConversationWorkEvidence(repository: observation, files: [])])
    }

    func testConversationWorkEvidenceRejectsAFileWithoutTheExactParentToolEdge() throws {
        let harness = try ActivatedAuthorityHarness()
        defer { harness.tearDown() }
        _ = try harness.repository.commit(conversation: harness.conversation)

        let observation = ConversationRepositoryObservation(
            id: UUID(),
            conversationID: harness.conversation.id,
            turnID: "turn-boundary",
            toolUseID: nil,
            reason: .changesRefresh,
            rootPromptEntryID: nil,
            finalAssistantEntryID: nil,
            rootPromptExcerpt: nil,
            rootPromptExcerptWasTruncated: nil,
            finalAssistantExcerpt: nil,
            finalAssistantExcerptWasTruncated: nil,
            repositoryID: "/tmp/exact-tool-edge/.git",
            gitCommonDirectory: "/tmp/exact-tool-edge/.git",
            worktreePath: "/tmp/exact-tool-edge",
            workspaceID: nil,
            canonicalCWD: "/tmp/exact-tool-edge",
            headState: .attached,
            symbolicRef: "refs/heads/main",
            headOID: String(repeating: "b", count: 40),
            statusAvailability: .available,
            indexChangeCount: 0,
            worktreeChangeCount: 1,
            untrackedCount: 0,
            attribution: nil,
            observedAt: Date(timeIntervalSinceReferenceDate: 53_200))
        let file = ConversationFileObservation(
            id: UUID(),
            repositoryObservationID: observation.id,
            conversationID: observation.conversationID,
            turnID: observation.turnID,
            toolUseID: "unrelated-tool",
            repositoryID: observation.repositoryID,
            repositoryRelativePath: "Feature.swift",
            operation: .edit,
            attribution: .directTool,
            beforeDigest: nil,
            afterDigest: nil,
            beforeExists: true,
            afterExists: true,
            boundedPatch: nil,
            patchWasTruncated: false,
            observedAt: observation.observedAt)

        XCTAssertThrowsError(
            try harness.repository.recordConversationWorkEvidence(
                repository: observation,
                files: [file]))
        XCTAssertTrue(
            try harness.repository.conversationWorkEvidence(
                conversationID: harness.conversation.id).isEmpty,
            "failed edge admission must not publish its repository parent")
    }

    func testConversationFileObservationForeignKeyContainsTheExactToolEdge() throws {
        let harness = try ActivatedAuthorityHarness()
        defer { harness.tearDown() }
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                harness.root.appendingPathComponent("library.db").path,
                &database,
                SQLITE_OPEN_READONLY,
                nil),
            SQLITE_OK)
        let opened = try XCTUnwrap(database)
        defer { sqlite3_close_v2(opened) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                opened,
                "PRAGMA foreign_key_list(conversation_file_observations)",
                -1,
                &statement,
                nil),
            SQLITE_OK)
        let prepared = try XCTUnwrap(statement)
        defer { sqlite3_finalize(prepared) }
        var edges: Set<String> = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            guard let from = sqlite3_column_text(prepared, 3),
                  let to = sqlite3_column_text(prepared, 4) else { continue }
            edges.insert("\(String(cString: from))->\(String(cString: to))")
        }
        XCTAssertTrue(edges.contains("tool_use_id->tool_use_id"))
        XCTAssertTrue(edges.contains("turn_id->turn_id"))
        XCTAssertTrue(edges.contains("conversation_id->conversation_id"))
    }

    func testConversationWorkEvidenceExcerptUsesAnExactUTF8Prefix() {
        let source = String(repeating: "évidence ", count: 1_000)
        let bounded = ConversationRepositoryObservation.boundedTranscriptExcerpt(source)

        XCTAssertTrue(bounded.wasTruncated)
        XCTAssertLessThanOrEqual(
            bounded.text.utf8.count,
            ConversationRepositoryObservation.maximumTranscriptExcerptBytes)
        XCTAssertTrue(source.hasPrefix(bounded.text))
        XCTAssertNotNil(bounded.text.data(using: .utf8))
    }
}
