import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import Mechanician

@MainActor
final class SQLiteAuthorityRetainedByteTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let repository: LibraryAuthorityRepository
        let database: SQLiteLibraryStore
        let conversation: Conversation
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sqlite-authority-retained-byte-\(UUID().uuidString)",
            isDirectory: true)
        let conversation = Conversation(
            title: "Retained byte authority",
            cwd: "/tmp/retained-byte",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date(timeIntervalSinceReferenceDate: 42_000))
        let conversationBytes = try ConversationStore.makeEncoder().encode(conversation)
        let home = HomeWorkspaceSettings(
            instructions: "Home",
            updatedAt: Date(timeIntervalSinceReferenceDate: 41_000))
        let homeBytes = try ConversationStore.makeEncoder().encode(home)

        var candidate: SQLiteLibraryStore? = try SQLiteLibraryStore(supportRoot: root)
        _ = try XCTUnwrap(candidate).reconcile(ShadowLibraryImportSnapshot(
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
                    identity: "conversations/\(conversation.id.uuidString).json",
                    revision: "legacy-conversation",
                    sourceBytes: conversationBytes))]))
        let frontier = try XCTUnwrap(candidate).status()
        try XCTUnwrap(candidate).acknowledgeExactProjectionSnapshot(
            databaseInstanceID: frontier.databaseInstanceID,
            through: frontier.shadowChangeSequence,
            projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion))
        let activationID = UUID()
        try XCTUnwrap(candidate).prepareAuthority(
            activationID: activationID,
            minimumWriterBuild: StorageAuthorityProtocol.recognitionID)
        try XCTUnwrap(candidate).activatePreparedAuthority(activationID: activationID)
        let metadata = try XCTUnwrap(candidate).authorityMetadata()
        let marker = StorageAuthorityMarker(
            mode: .sqlite,
            activationID: activationID,
            databaseInstanceID: metadata.databaseInstanceID,
            schemaVersion: metadata.schemaVersion,
            createdAt: "2026-08-05T12:00:00Z")
        candidate = nil
        let database = try SQLiteLibraryStore.openActiveAuthority(
            supportRoot: root,
            marker: marker)
        return Fixture(
            root: root,
            repository: try LibraryAuthorityRepository(
                store: database,
                supportRoot: root,
                marker: marker),
            database: database,
            conversation: conversation)
    }

    func testPostActivationAttachmentCommitsSourceDigestAndMovesReferenceWithPrompt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .eager,
            libraryAuthorityRepository: fixture.repository)
        XCTAssertTrue(store.isReady, store.persistenceError ?? "SQLite authority did not load")

        let bytes = Data("post-activation attachment".utf8)
        let inputURL = fixture.root.appendingPathComponent("incoming.txt")
        try bytes.write(to: inputURL)
        let attachment = try XCTUnwrap(store.persistComposerFile(
            at: inputURL,
            conversationID: fixture.conversation.id))
        let draftCommit = expectation(description: "draft media commit")
        _ = store.updateAwaitingPersistence(fixture.conversation.id, {
            $0.draft = "Review \(attachment.promptToken)"
        }) { succeeded in
            XCTAssertTrue(succeeded)
            draftCommit.fulfill()
        }
        await fulfillment(of: [draftCommit], timeout: 3)

        let identity = "conversation-media/\(fixture.conversation.id.uuidString)/"
            + attachment.storageName
        let retained = try XCTUnwrap(try fixture.database.retainedByteInventory().first {
            $0.source.identity == identity
        })
        XCTAssertEqual(retained.ownerConversationID, fixture.conversation.id)
        XCTAssertEqual(retained.source.byteCount, bytes.count)
        XCTAssertEqual(
            retained.source.digest,
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(retained.storageState, .adopted)
        XCTAssertEqual(retained.disposition, .referenced)
        var references = try fixture.database.retainedByteReferences(
            ownerConversationID: fixture.conversation.id)
        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(references.first?.ownerKind, .localState)
        XCTAssertNil(references.first?.ownerEventID)

        // Sending the draft changes only the logical owner of the same bytes. No second physical
        // media notification occurs, so this proves the differential Conversation writer still
        // replaces the reference edge instead of leaving SQLite pointed at the retired draft.
        let entry = TranscriptEntry(kind: .user, text: "Review \(attachment.promptToken)")
        let transcriptCommit = expectation(description: "transcript media commit")
        _ = store.updateAwaitingPersistence(fixture.conversation.id, {
            $0.draft = ""
            $0.messages.append(entry)
        }) { succeeded in
            XCTAssertTrue(succeeded)
            transcriptCommit.fulfill()
        }
        await fulfillment(of: [transcriptCommit], timeout: 3)

        references = try fixture.database.retainedByteReferences(
            ownerConversationID: fixture.conversation.id)
        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(references.first?.ownerKind, .event)
        XCTAssertEqual(references.first?.ownerEventID, entry.id)
    }

    // MARK: - Retained-byte sources owned by a deleted Conversation

    private func openDatabase(_ root: URL, readOnly: Bool = false) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(
            root.appendingPathComponent("library.db").path, &db, flags, nil) == SQLITE_OK,
              let db else {
            throw NSError(domain: "retained-byte.test.sqlite", code: 1)
        }
        // A live `SQLiteLibraryStore` from an earlier case in this class still holds the file, so a
        // second connection meets its write lock and fails instantly with "database is locked"
        // rather than waiting. Reproducible: the case passes alone and fails after any sibling.
        sqlite3_busy_timeout(db, 5_000)
        return db
    }

    private func execute(_ root: URL, _ sql: String) throws {
        let db = try openDatabase(root)
        defer { sqlite3_close_v2(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(
                domain: "retained-byte.test.sqlite", code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    private func scalar(_ root: URL, _ sql: String) throws -> Int64 {
        let db = try openDatabase(root, readOnly: true)
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "retained-byte.test.sqlite", code: 3)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    /// The real daily backup, not a restatement of its verification SQL. A restatement is how this
    /// defect survived for 28 days: the lifecycle's own tests kept passing, because they never had
    /// a retained-byte source to strand.
    private func backupVerificationSucceeds(_ root: URL) -> Bool {
        (try? LibraryBackupLifecycle.createBackupIfDue(sourceSupportRoot: root, force: true)) != nil
    }

    /// The backup publishes generations as a sibling of the support root, so a temp root alone
    /// leaves them behind.
    private func removeBackupRoot(_ root: URL) {
        let backups = root.deletingLastPathComponent().appendingPathComponent(
            "\(root.lastPathComponent) Library Backups", isDirectory: true)
        guard FileManager.default.fileExists(atPath: backups.path) else { return }
        try? FileManager.default.removeItem(at: backups)
    }

    private func attachMedia(
        _ store: ConversationStore, _ fixture: Fixture, named name: String
    ) async throws {
        let bytes = Data("media \(name)".utf8)
        let inputURL = fixture.root.appendingPathComponent(name)
        try bytes.write(to: inputURL)
        let attachment = try XCTUnwrap(store.persistComposerFile(
            at: inputURL, conversationID: fixture.conversation.id))
        let committed = expectation(description: "media commit \(name)")
        _ = store.updateAwaitingPersistence(fixture.conversation.id, {
            $0.draft = "Review \(attachment.promptToken)"
        }) { XCTAssertTrue($0); committed.fulfill() }
        await fulfillment(of: [committed], timeout: 3)
    }

    /// Deleting a Conversation used to demote its media rows to `reference_pending` and then, in
    /// the same transaction, delete the only Conversation that could ever claim them. Nothing
    /// re-evaluates a pending row with no owner, and the backup refuses while one exists — so
    /// deleting a single Conversation containing an image disabled the daily backup permanently.
    /// It did, on a real machine, for 28 days and eight schema versions.
    func testDeletingAConversationReleasesItsMediaInsteadOfStrandingIt() async throws {
        let fixture = try makeFixture()
        defer {
            removeBackupRoot(fixture.root)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .eager,
            libraryAuthorityRepository: fixture.repository)
        XCTAssertTrue(store.isReady, store.persistenceError ?? "SQLite authority did not load")

        try await attachMedia(store, fixture, named: "attached.txt")
        XCTAssertGreaterThan(
            try scalar(fixture.root, """
            SELECT COUNT(*) FROM retained_byte_sources
            WHERE owner_conversation_id = '\(fixture.conversation.id.uuidString)'
            """), 0, "the fixture must actually have media to strand")
        XCTAssertTrue(backupVerificationSucceeds(fixture.root))

        _ = try fixture.repository.deleteConversation(id: fixture.conversation.id)

        XCTAssertEqual(
            try scalar(fixture.root, """
            SELECT COUNT(*) FROM retained_byte_sources
            WHERE owner_conversation_id = '\(fixture.conversation.id.uuidString)'
            """), 0, "media rows outlived the Conversation that owned them")
        XCTAssertEqual(
            try scalar(
                fixture.root,
                "SELECT COUNT(*) FROM retained_byte_sources WHERE disposition = 'reference_pending'"),
            0)
        XCTAssertTrue(
            backupVerificationSucceeds(fixture.root),
            "the backup must still be able to run after an ordinary delete")
    }

    /// The repair half, for the installs already carrying the state. Manufactured with the exact
    /// SQL the old delete path ran, so this fails if that behaviour ever returns by another route.
    func testOrphanedPendingSourcesAreReleasedAndLiveOnesAreNot() async throws {
        let fixture = try makeFixture()
        defer {
            removeBackupRoot(fixture.root)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .eager,
            libraryAuthorityRepository: fixture.repository)
        XCTAssertTrue(store.isReady, store.persistenceError ?? "SQLite authority did not load")
        try await attachMedia(store, fixture, named: "stranded.txt")

        // A pending row whose owner is still alive is ordinary in-flight state, not garbage. It
        // goes in FIRST, while there is still a Conversation row to copy a valid shape from.
        let liveOwner = UUID()
        try execute(fixture.root, """
        INSERT INTO conversations (
          id, title, title_source, cwd, workspace_id, updated_at, favorite, sort_index, unread,
          errored, revision, source_identity)
        SELECT '\(liveOwner.uuidString)', 'Live owner', title_source, cwd, workspace_id,
               updated_at, 0, NULL, 0, 0, 1, 'conversations/\(liveOwner.uuidString).json'
          FROM conversations LIMIT 1;
        INSERT INTO retained_byte_sources (
          source_identity, kind, owner_conversation_id, storage_name, observed_revision, digest,
          byte_count, media_type, link_state, storage_class, storage_state, storage_identity,
          retention_state, disposition)
        VALUES (
          'conversation-media/\(liveOwner.uuidString)/live.png', 'conversation_media',
          '\(liveOwner.uuidString)', 'live.png', 'r', 'd', 1, 'public.png', 'current',
          'legacy_layout', 'observed', 'conversation-media/\(liveOwner.uuidString)/live.png',
          'live', 'reference_pending');
        """)
        XCTAssertEqual(
            try scalar(fixture.root, """
            SELECT COUNT(*) FROM conversations WHERE id = '\(liveOwner.uuidString)'
            """), 1, "the live owner must exist or both rows would be orphans")

        // Exactly what shipped: demote to pending, then delete the owner.
        try execute(fixture.root, """
        UPDATE retained_byte_sources
           SET storage_state = 'observed', disposition = 'reference_pending'
         WHERE owner_conversation_id = '\(fixture.conversation.id.uuidString)'
           AND storage_class = 'legacy_layout';
        DELETE FROM retained_byte_references;
        DELETE FROM conversations WHERE id = '\(fixture.conversation.id.uuidString)';
        """)
        XCTAssertFalse(
            backupVerificationSucceeds(fixture.root),
            "the manufactured state must actually be the one that refuses a backup")

        let released = try fixture.repository.releaseOrphanedRetainedByteSources()

        XCTAssertEqual(released, 1, "only the row whose owner is gone may be released")
        XCTAssertEqual(
            try scalar(fixture.root, """
            SELECT COUNT(*) FROM retained_byte_sources
            WHERE source_identity = 'conversation-media/\(liveOwner.uuidString)/live.png'
            """), 1, "a pending row with a live owner is in-flight state, not garbage")
        XCTAssertEqual(try fixture.repository.releaseOrphanedRetainedByteSources(), 0)
    }
}
