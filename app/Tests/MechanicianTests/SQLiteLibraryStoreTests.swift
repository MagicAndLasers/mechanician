import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import Mechanician

final class SQLiteLibraryStoreTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func source(
        _ identity: String,
        revision: String = "1",
        content: String? = nil
    ) -> ShadowLibrarySourceFingerprint {
        ShadowLibrarySourceFingerprint(
            identity: identity,
            revision: revision,
            sourceBytes: Data((content ?? "\(identity)-\(revision)").utf8))
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func artifact(
        id: UUID = UUID(),
        workspaceID: UUID? = nil,
        source sourceValue: ShadowLibrarySourceFingerprint? = nil,
        content: Data = Data("artifact body".utf8),
        canonicalPayload: Data? = nil,
        rawSourcePayload: Data? = nil,
        producerTaskID: String? = nil
    ) -> ShadowLibraryArtifactSnapshot {
        let payload = canonicalPayload ?? Data("canonical-\(id.uuidString)".utf8)
        let rawPayload = rawSourcePayload
            ?? Data("{\"uuid\":\"\(id.uuidString)\",\"futureMember\":{\"preserve\":true}}".utf8)
        let artifactSource = sourceValue ?? ShadowLibrarySourceFingerprint(
            identity: "artifacts/\(id.uuidString).json",
            revision: "1",
            sourceBytes: rawPayload)
        return ShadowLibraryArtifactSnapshot(
            id: id,
            title: "Artifact \(id.uuidString.prefix(4))",
            type: "markdown",
            origin: "interactive",
            workspaceID: workspaceID,
            provenanceConversationID: nil,
            conversationTitleSnapshot: "",
            cwd: "",
            favorite: false,
            createdAt: Date(timeIntervalSinceReferenceDate: 50),
            updatedAt: Date(timeIntervalSinceReferenceDate: 60),
            revision: 1,
            producerTaskID: producerTaskID,
            rawSourcePayload: rawPayload,
            canonicalPayload: payload,
            canonicalPayloadDigest: digest(payload),
            content: content,
            contentDigest: digest(content),
            contentByteCount: content.count,
            payloadMediaType: "text/markdown",
            source: artifactSource)
    }

    private func retainedByte(
        identity: String,
        ownerConversationID: UUID?,
        content: Data,
        kind: ShadowLibraryRetainedByteSnapshot.Kind = .conversationMedia,
        linkState: ShadowLibraryRetainedByteSnapshot.LinkState = .current,
        diagnostics: String? = nil
    ) -> ShadowLibraryRetainedByteSnapshot {
        ShadowLibraryRetainedByteSnapshot(
            kind: kind,
            ownerConversationID: ownerConversationID,
            storageName: URL(fileURLWithPath: identity).lastPathComponent,
            mediaType: "image/png",
            linkState: linkState,
            diagnostics: diagnostics,
            source: ShadowLibrarySourceFingerprint(
                identity: identity,
                revision: "stat-v1",
                digest: digest(content),
                byteCount: content.count))
    }

    private func home(
        source: ShadowLibrarySourceFingerprint = .implicitHomeWorkspace
    ) -> ShadowLibraryWorkspaceSnapshot {
        .home(
            settings: HomeWorkspaceSettings(
                instructions: "Be precise",
                updatedAt: Date(timeIntervalSinceReferenceDate: 10)),
            source: source,
            revision: 1)
    }

    private func workspace(
        id: UUID = UUID(),
        source sourceValue: ShadowLibrarySourceFingerprint? = nil
    ) -> ShadowLibraryWorkspaceSnapshot {
        .named(
            Project(
                id: id,
                name: "Mechanician",
                goal: "Ship it",
                instructions: "Test first",
                cwd: "/tmp/mechanician",
                favorite: true,
                sortIndex: 3,
                iconSymbol: "hammer",
                colorHex: "#123456",
                createdAt: Date(timeIntervalSinceReferenceDate: 20),
                updatedAt: Date(timeIntervalSinceReferenceDate: 30)),
            source: sourceValue ?? source("workspaces/\(id.uuidString).json"),
            revision: 1)
    }

    private func conversation(
        id: UUID = UUID(),
        workspaceID: UUID? = nil,
        source sourceValue: ShadowLibrarySourceFingerprint? = nil,
        eventID: UUID = UUID(),
        nestedArtifacts: [ShadowLibraryNestedArtifactSnapshot] = []
    ) -> ShadowLibraryConversationSnapshot {
        ShadowLibraryConversationSnapshot(
            id: id,
            title: "Conversation \(id.uuidString.prefix(4))",
            titleSource: "legacy",
            cwd: workspaceID == nil ? "" : "/tmp/mechanician",
            workspaceID: workspaceID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 40),
            favorite: false,
            sortIndex: nil,
            unread: true,
            errored: false,
            revision: 1,
            source: sourceValue ?? source("conversations/\(id.uuidString).json"),
            events: [
                ShadowLibraryEventSnapshot(
                    id: eventID,
                    captureSequence: 1,
                    kind: "entry.user",
                    actorID: "user",
                    observedAt: Date(timeIntervalSinceReferenceDate: 40),
                    payload: Data("hello".utf8))
            ],
            nestedArtifacts: nestedArtifacts)
    }

    private func sqliteInt(_ databaseURL: URL, _ sql: String) throws -> Int64 {
        var db: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil),
            SQLITE_OK)
        guard let db else { throw NSError(domain: "test.sqlite", code: 1) }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        guard let statement else { throw NSError(domain: "test.sqlite", code: 2) }
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return sqlite3_column_int64(statement, 0)
    }

    private func sqliteText(_ databaseURL: URL, _ sql: String) throws -> String? {
        var db: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil),
            SQLITE_OK)
        guard let db else { throw NSError(domain: "test.sqlite", code: 3) }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        guard let statement else { throw NSError(domain: "test.sqlite", code: 4) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: raw)
    }

    private func sqliteBlob(_ databaseURL: URL, _ sql: String) throws -> Data? {
        var db: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil),
            SQLITE_OK)
        guard let db else { throw NSError(domain: "test.sqlite", code: 9) }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        guard let statement else { throw NSError(domain: "test.sqlite", code: 10) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func stampSchemaVersion(_ databaseURL: URL, _ version: Int32) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db else { throw NSError(domain: "test.sqlite", code: 5) }
        defer { sqlite3_close_v2(db) }
        guard sqlite3_exec(db, "PRAGMA user_version = \(version)", nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "test.sqlite", code: 6)
        }
    }

    private func executeSQL(_ databaseURL: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db else { throw NSError(domain: "test.sqlite", code: 7) }
        defer { sqlite3_close_v2(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(
                domain: "test.sqlite",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    private func createV2Fixture(at root: URL) throws -> (URL, UUID) {
        let databaseURL = root.appendingPathComponent("library.db")
        let instanceID = UUID()
        let now = Date().timeIntervalSinceReferenceDate
        let statements = SQLiteLibraryStore.schemaV2Statements.joined(separator: ";\n")
        try executeSQL(
            databaseURL,
            """
            \(statements);
            PRAGMA application_id = \(SQLiteLibraryStore.applicationID);
            PRAGMA user_version = 2;
            INSERT INTO library_metadata (
              singleton, database_instance_id, schema_version, application_id,
              authority_state, committed_sequence, shadow_change_sequence, created_at)
            VALUES (1, '\(instanceID.uuidString)', 2, \(SQLiteLibraryStore.applicationID),
                    'shadow', 0, 7, \(now));
            INSERT INTO schema_migrations (migration_id, checksum, app_build, completed_at)
            VALUES (1, '\(SQLiteLibraryStore.schemaV2Checksum)', 'L1b1', \(now));
            INSERT INTO workspaces (
              id, kind, name, goal, instructions, cwd, favorite, created_at, updated_at,
              revision, source_identity)
            VALUES ('\(SQLiteLibraryStore.homeWorkspaceID.uuidString)', 'home', 'V2 Home', '',
                    '', '', 0, \(now), \(now), 4, 'home-workspace.json');
            INSERT INTO migration_sources (
              domain, source_identity, entity_id, observed_revision, observed_digest,
              source_byte_count, imported_revision, imported_digest, dirty, import_state,
              imported_at)
            VALUES ('workspaces', 'home-workspace.json',
                    '\(SQLiteLibraryStore.homeWorkspaceID.uuidString)', '4', 'v2-digest', 10,
                    '4', 'v2-digest', 0, 'current', \(now));
            INSERT INTO domain_reconciliation (
              domain, full_census_completed_at, expected_source_count)
            VALUES ('workspaces', \(now), 1);
            """)
        let marker = try JSONSerialization.data(withJSONObject: [
            "formatVersion": 1,
            "databaseInstanceID": instanceID.uuidString,
        ])
        try marker.write(to: URL(fileURLWithPath: databaseURL.path + ".shadow-resettable"))
        return (databaseURL, instanceID)
    }

    func testCreatesChecksummedSchemaReservedHomeAndOwnerOnlyFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SQLiteLibraryStore(supportRoot: root)
        let status = try store.status()

        XCTAssertEqual(
            try sqliteInt(store.databaseURL, "PRAGMA application_id"),
            Int64(SQLiteLibraryStore.applicationID))
        XCTAssertEqual(
            try sqliteInt(store.databaseURL, "PRAGMA user_version"),
            Int64(SQLiteLibraryStore.schemaVersion))
        // The ledger holds one row per migration run: ids 1 through `schemaVersion - 1`, since the
        // step that produced v2 records id 1. Derived rather than typed, so a schema bump does not
        // surface as an unrelated-looking failure here.
        XCTAssertEqual(
            try sqliteInt(store.databaseURL, "SELECT COUNT(*) FROM schema_migrations"),
            Int64(SQLiteLibraryStore.schemaVersion - 1))
        XCTAssertEqual(
            try sqliteText(
                store.databaseURL,
                "SELECT id FROM workspaces WHERE kind = 'home'"),
            SQLiteLibraryStore.homeWorkspaceID.uuidString)
        XCTAssertEqual(status.integrity.state, .passed)
        XCTAssertFalse(status.isAuthority)
        XCTAssertFalse(status.isReadyForCutover)
        XCTAssertEqual(status.candidateState, .incompleteShadow)
        XCTAssertFalse(try XCTUnwrap(status.domain(.conversations)).hasFullCensus)
        XCTAssertEqual(status.domain(.artifactMedia)?.phase, .shadowing)
        XCTAssertEqual(status.domain(.operativeState)?.phase, .shadowing)
        XCTAssertFalse(try XCTUnwrap(status.artifactMedia).managedBlobsMaterialized)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("blobs").path))

        let rootPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)
        let databasePermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: store.databaseURL.path)[.posixPermissions]
                as? NSNumber)
        XCTAssertEqual(rootPermissions.intValue & 0o777, 0o700)
        XCTAssertEqual(databasePermissions.intValue & 0o777, 0o600)
    }

    func testArtifactAndRetainedBytesPreserveContentTaskIdentityAndDeduplicateOnlyPayloads() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let shared = Data("same retained bytes".utf8)
        let first = artifact(content: shared, producerTaskID: "ambient-task-1")
        let second = artifact(content: shared)
        let media = retainedByte(
            identity: "conversation-media/owner/image.png",
            ownerConversationID: nil,
            content: shared,
            linkState: .orphan,
            diagnostics: "Owner is absent")

        _ = try store.upsert(artifact: first)
        _ = try store.upsert(artifact: second)
        let status = try store.upsert(retainedByte: media)
        let inventory = try XCTUnwrap(status.artifactMedia)

        XCTAssertEqual(try sqliteInt(store.databaseURL, "SELECT COUNT(*) FROM artifacts"), 2)
        XCTAssertEqual(
            try sqliteText(
                store.databaseURL,
                "SELECT producer_task_id FROM artifacts WHERE id = '\(first.id.uuidString)'"),
            "ambient-task-1")
        XCTAssertEqual(
            try sqliteInt(
                store.databaseURL,
                "SELECT length(content) FROM artifacts WHERE id = '\(first.id.uuidString)'"),
            Int64(shared.count))
        XCTAssertEqual(
            try sqliteBlob(
                store.databaseURL,
                "SELECT raw_source_payload FROM artifacts WHERE id = '\(first.id.uuidString)'"),
            first.rawSourcePayload,
            "unknown raw JSON members must survive byte-for-byte")
        XCTAssertEqual(inventory.artifactCount, 2)
        XCTAssertEqual(inventory.retainedByteSourceCount, 1, "only physical retained media files")
        XCTAssertEqual(inventory.uniquePayloadCount, 1)
        XCTAssertEqual(inventory.duplicateSourceCount, 2)
        XCTAssertEqual(inventory.retainedBytes, Int64(shared.count * 3))
        XCTAssertEqual(inventory.uniqueBytes, Int64(shared.count))
        XCTAssertEqual(inventory.duplicateBytes, Int64(shared.count * 2))
        // No census claim. `reconcileArtifactMedia` was the only thing that ever published one and
        // it is gone; single-row upserts record what they were given and claim nothing about the
        // whole set, which is the honest answer for an incremental write.
        XCTAssertFalse(inventory.hasFullCensus)
        XCTAssertFalse(inventory.managedBlobsMaterialized)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("blobs").path))
    }

    func testNestedOnlyAndDivergentArtifactCachesRemainVisible() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let divergentID = UUID()
        let nestedOnlyID = UUID()
        let nestedPayload = Data("nested canonical value".utf8)
        let nested = [divergentID, nestedOnlyID].map {
            ShadowLibraryNestedArtifactSnapshot(
                artifactID: $0,
                canonicalPayload: nestedPayload,
                canonicalPayloadDigest: digest(nestedPayload),
                contentDigest: digest(Data("nested body".utf8)),
                contentByteCount: Data("nested body".utf8).count)
        }
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(),
            workspaces: [],
            conversations: [conversation(nestedArtifacts: nested)]))
        let standalone = artifact(
            id: divergentID,
            canonicalPayload: Data("standalone canonical value".utf8))

        let status = try store.upsert(artifact: standalone)
        let inventory = try XCTUnwrap(status.artifactMedia)

        XCTAssertEqual(inventory.nestedSnapshotCount, 2)
        XCTAssertEqual(inventory.nestedOnlyCount, 1)
        XCTAssertEqual(inventory.divergentCount, 1)
        XCTAssertEqual(
            try sqliteInt(store.databaseURL, "SELECT COUNT(*) FROM conversation_artifact_snapshots"),
            2)
    }



    func testRetainedCurrentLinkNormalizesToOrphanWhenConversationIsAbsent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let owner = UUID()
        let retained = retainedByte(
            identity: "conversation-media/\(owner.uuidString)/image.png",
            ownerConversationID: owner,
            content: Data("image".utf8))

        let status = try store.upsert(retainedByte: retained)

        XCTAssertEqual(
            try sqliteText(
                store.databaseURL,
                "SELECT link_state FROM retained_byte_sources WHERE source_identity = '\(retained.source.identity)'"),
            "orphan")
        XCTAssertEqual(status.domain(.artifactMedia)?.mismatched, 1)
        XCTAssertEqual(status.domain(.artifactMedia)?.imported, 1)
        XCTAssertEqual(status.artifactMedia?.sourceIssueCount, 1)
    }

    func testTrashMediaRemainsCurrentWithoutLiveOwnerWhileActiveMediaBecomesOrphan() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let missingOwner = UUID()
        let active = retainedByte(
            identity: "conversation-media/\(missingOwner.uuidString)/active.png",
            ownerConversationID: missingOwner,
            content: Data("active".utf8))
        let trash = retainedByte(
            identity: "conversation-trash/media/\(missingOwner.uuidString)/trash.png",
            ownerConversationID: missingOwner,
            content: Data("trash".utf8),
            kind: .conversationTrashMedia)

        _ = try store.upsert(retainedByte: active)
        let status = try store.upsert(retainedByte: trash)

        XCTAssertEqual(
            try sqliteText(
                store.databaseURL,
                "SELECT link_state FROM retained_byte_sources WHERE source_identity = '\(active.source.identity)'"),
            "orphan")
        XCTAssertEqual(
            try sqliteText(
                store.databaseURL,
                "SELECT link_state FROM retained_byte_sources WHERE source_identity = '\(trash.source.identity)'"),
            "current")
        XCTAssertEqual(status.domain(.artifactMedia)?.current, 1)
        XCTAssertEqual(status.domain(.artifactMedia)?.mismatched, 1)
        XCTAssertEqual(status.artifactMedia?.sourceIssueCount, 1)
    }

    func testUnchangedActiveMediaRepairsLinkStateAsOwnerAppearsAndDisappears() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let owner = conversation()
        let media = retainedByte(
            identity: "conversation-media/\(owner.id.uuidString)/active.png",
            ownerConversationID: owner.id,
            content: Data("unchanged bytes".utf8))

        _ = try store.upsert(retainedByte: media)
        XCTAssertEqual(
            try sqliteText(
                store.databaseURL,
                "SELECT link_state FROM retained_byte_sources WHERE source_identity = '\(media.source.identity)'"),
            "orphan")

        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [], conversations: [owner]))
        _ = try store.upsert(retainedByte: media)
        XCTAssertEqual(
            try sqliteText(
                store.databaseURL,
                "SELECT link_state FROM retained_byte_sources WHERE source_identity = '\(media.source.identity)'"),
            "current")

        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [], conversations: []))
        _ = try store.upsert(retainedByte: media)
        XCTAssertEqual(
            try sqliteText(
                store.databaseURL,
                "SELECT link_state FROM retained_byte_sources WHERE source_identity = '\(media.source.identity)'"),
            "orphan")
    }

    func testRepeatImportIsIdempotentAndForkLocalEventIDsDoNotCollide() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let sharedForkEntryID = UUID()
        let first = conversation(eventID: sharedForkEntryID)
        let second = conversation(eventID: sharedForkEntryID)
        let snapshot = ShadowLibraryImportSnapshot(
            home: home(),
            workspaces: [],
            conversations: [first, second])

        let initial = try store.reconcile(snapshot)
        let importedAt = try sqliteText(
            store.databaseURL,
            "SELECT printf('%.9f', imported_at) FROM migration_sources WHERE source_identity = '\(first.source.identity)'")
        let repeated = try store.reconcile(snapshot)

        XCTAssertEqual(try sqliteInt(store.databaseURL, "SELECT COUNT(*) FROM conversations"), 2)
        XCTAssertEqual(try sqliteInt(store.databaseURL, "SELECT COUNT(*) FROM conversation_events"), 2)
        XCTAssertEqual(
            try sqliteText(
                store.databaseURL,
                "SELECT printf('%.9f', imported_at) FROM migration_sources WHERE source_identity = '\(first.source.identity)'"),
            importedAt,
            "an unchanged fingerprint must not rewrite the imported source")
        XCTAssertEqual(initial.domain(.conversations)?.current, 2)
        XCTAssertEqual(repeated.domain(.conversations)?.current, 2)
        XCTAssertTrue(try XCTUnwrap(repeated.domain(.conversations)).hasFullCensus)
        XCTAssertEqual(repeated.integrity.state, .passed)
    }

    func testHomeNamedAndDanglingMembershipRemainExactAndVisible() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let namedID = UUID()
        let missingID = UUID()
        let homeConversation = conversation(workspaceID: nil)
        let namedConversation = conversation(workspaceID: namedID)
        let danglingConversation = conversation(workspaceID: missingID)

        let status = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(),
            workspaces: [workspace(id: namedID)],
            conversations: [homeConversation, namedConversation, danglingConversation]))

        XCTAssertEqual(
            try sqliteText(
                store.databaseURL,
                "SELECT workspace_id FROM conversations WHERE id = '\(homeConversation.id.uuidString)'"),
            SQLiteLibraryStore.homeWorkspaceID.uuidString,
            "nil legacy projectID maps only to the reserved Home identity")
        XCTAssertEqual(
            try sqliteText(
                store.databaseURL,
                "SELECT workspace_id FROM conversations WHERE id = '\(namedConversation.id.uuidString)'"),
            namedID.uuidString)
        XCTAssertEqual(
            try sqliteText(
                store.databaseURL,
                "SELECT workspace_id FROM conversations WHERE id = '\(danglingConversation.id.uuidString)'"),
            missingID.uuidString,
            "a dangling id must never be coerced to Home")
        XCTAssertEqual(
            try sqliteText(
                store.databaseURL,
                "SELECT kind FROM workspaces WHERE id = '\(missingID.uuidString)'"),
            "unresolved")
        XCTAssertEqual(
            try sqliteInt(store.databaseURL, "SELECT COUNT(*) FROM conversations WHERE workspace_id IS NULL"),
            0)
        let workspaceStatus = try XCTUnwrap(status.domain(.workspaces))
        XCTAssertEqual(workspaceStatus.total, 3)
        XCTAssertEqual(workspaceStatus.imported, 2)
        XCTAssertEqual(workspaceStatus.current, 2)
        XCTAssertEqual(workspaceStatus.mismatched, 1)
        XCTAssertTrue(workspaceStatus.hasFullCensus)
        XCTAssertFalse(workspaceStatus.isComplete)
    }

    func testStreamingReconcileAccountsForMalformedSourceWithoutHoldingEntity() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let malformed = source("conversations/broken.json", content: "{not-json")
        let census = ShadowLibraryReconciliationCensus(
            workspaceSourceIdentities: [
                ShadowLibrarySourceFingerprint.implicitHomeWorkspace.identity
            ],
            conversationSourceIdentities: [malformed.identity])
        let token = try store.beginReconciliation(census)

        _ = try store.upsert(workspace: home())
        _ = try store.recordSourceIssue(
            domain: .conversations,
            source: malformed,
            kind: .malformed,
            diagnostics: "JSON decoder rejected the source")
        let status = try store.finishReconciliation(token)

        let conversations = try XCTUnwrap(status.domain(ShadowLibraryDomain.conversations))
        XCTAssertEqual(conversations.total, 1)
        XCTAssertEqual(conversations.imported, 0)
        XCTAssertEqual(conversations.quarantined, 1)
        XCTAssertTrue(conversations.hasFullCensus)
        XCTAssertFalse(conversations.isComplete)
        XCTAssertEqual(try sqliteInt(store.databaseURL, "SELECT COUNT(*) FROM conversations"), 0)
    }

    func testStreamingReconcileCanDeferIntegrityUntilAdjacentImportsFinish() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let value = conversation()
        let census = ShadowLibraryReconciliationCensus(
            workspaceSourceIdentities: [home().source.identity],
            conversationSourceIdentities: [value.source.identity])
        let token = try store.beginReconciliation(census)
        _ = try store.upsert(workspace: home())
        _ = try store.upsert(conversation: value)

        let deferred = try store.finishReconciliation(token, verifyingIntegrity: false)

        XCTAssertEqual(deferred.integrity.state, .pending)
        XCTAssertTrue(try XCTUnwrap(deferred.domain(.conversations)).hasFullCensus)
        XCTAssertEqual(try store.verifyIntegrity().state, .passed)
        XCTAssertEqual(try store.status().integrity.state, .passed)
    }

    func testDirtyUpdateAndStaleRemovalReconcileBySourceIdentity() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let workspaceID = UUID()
        let workspaceSnapshot = workspace(id: workspaceID)
        let retainedID = UUID()
        let removedID = UUID()
        let retainedV1 = conversation(id: retainedID, workspaceID: workspaceID)
        let removed = conversation(id: removedID, workspaceID: workspaceID)
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(),
            workspaces: [workspaceSnapshot],
            conversations: [retainedV1, removed]))

        let updatedSource = source(retainedV1.source.identity, revision: "2", content: "changed")
        let dirty = try store.markSourceDirty(
            domain: .conversations,
            source: updatedSource,
            entityID: retainedID)
        XCTAssertEqual(dirty.domain(.conversations)?.dirty, 1)
        XCTAssertEqual(dirty.domain(.conversations)?.mismatched, 1)
        XCTAssertEqual(dirty.integrity.state, .pending)

        let retainedV2 = conversation(
            id: retainedID,
            workspaceID: workspaceID,
            source: updatedSource)
        let reconciled = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(),
            workspaces: [workspaceSnapshot],
            conversations: [retainedV2]))
        XCTAssertEqual(reconciled.domain(.conversations)?.current, 1)
        XCTAssertEqual(reconciled.domain(.conversations)?.dirty, 0)
        XCTAssertEqual(reconciled.integrity.state, .passed)
        XCTAssertEqual(
            try sqliteInt(
                store.databaseURL,
                "SELECT COUNT(*) FROM conversations WHERE id = '\(removedID.uuidString)'"),
            0)
    }

    func testRemovedWorkspaceBecomesUnresolvedUntilLastConversationDisappears() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let workspaceID = UUID()
        let member = conversation(workspaceID: workspaceID)
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(),
            workspaces: [workspace(id: workspaceID)],
            conversations: [member]))

        let unresolved = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(),
            workspaces: [],
            conversations: [member]))
        XCTAssertEqual(
            try sqliteText(
                store.databaseURL,
                "SELECT kind FROM workspaces WHERE id = '\(workspaceID.uuidString)'"),
            "unresolved")
        XCTAssertEqual(unresolved.domain(.workspaces)?.mismatched, 1)

        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(),
            workspaces: [],
            conversations: []))
        XCTAssertEqual(
            try sqliteInt(
                store.databaseURL,
                "SELECT COUNT(*) FROM workspaces WHERE id = '\(workspaceID.uuidString)'"),
            0)
    }




    func testConversationWorkspaceReconcilePreservesArtifactMediaInventoryAndReceipts() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let value = artifact()
        _ = try store.upsert(artifact: value)

        let status = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(),
            workspaces: [],
            conversations: [conversation()]))

        XCTAssertEqual(try sqliteInt(store.databaseURL, "SELECT COUNT(*) FROM artifacts"), 1)
        XCTAssertEqual(status.artifactMedia?.artifactCount, 1)
        // See above: an incremental write claims nothing about the whole set.
        XCTAssertFalse(try XCTUnwrap(status.artifactMedia).hasFullCensus)
        XCTAssertEqual(
            try store.cachedArtifactMediaFingerprints()[value.source.identity],
            value.source)
    }

    func testDatabaseSizeTracksGrowingDatabaseWALAndSHMFamilyExactly() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let before = try store.status().databaseBytes
        let content = Data(repeating: 0x41, count: 2 * 1024 * 1024)
        _ = try store.upsert(artifact: artifact(content: content, canonicalPayload: content))
        let status = try store.status()
        let family = [
            store.databaseURL,
            URL(fileURLWithPath: store.databaseURL.path + "-wal"),
            URL(fileURLWithPath: store.databaseURL.path + "-shm"),
        ]
        let exact = family.reduce(Int64(0)) { result, url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return result + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }

        XCTAssertEqual(status.databaseBytes, exact)
        XCTAssertGreaterThan(status.databaseBytes, before)
    }

    func testMatchingResetMarkerPermitsV1ShadowGenerationToRebuildAsCurrentSchema() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: SQLiteLibraryStore? = try SQLiteLibraryStore(supportRoot: root)
        let databaseURL = try XCTUnwrap(store?.databaseURL)
        store = nil
        try stampSchemaVersion(databaseURL, 1)

        let rebuilt = try SQLiteLibraryStore(supportRoot: root)
        let status = try rebuilt.status()

        XCTAssertTrue(status.wasResetOnOpen)
        XCTAssertEqual(status.schemaVersion, SQLiteLibraryStore.schemaVersion)
        XCTAssertEqual(
            try sqliteInt(databaseURL, "PRAGMA user_version"),
            Int64(SQLiteLibraryStore.schemaVersion))
        XCTAssertTrue(status.resetReason?.contains("schema version mismatch") == true)
    }

    func testV2MigratesForwardWithoutResetOrLosingRows() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (databaseURL, instanceID) = try createV2Fixture(at: root)

        let store = try SQLiteLibraryStore(supportRoot: root)
        let metadata = try store.authorityMetadata()

        XCTAssertEqual(metadata.databaseInstanceID, instanceID)
        XCTAssertEqual(metadata.schemaVersion, SQLiteLibraryStore.schemaVersion)
        XCTAssertEqual(metadata.authorityState, .shadow)
        XCTAssertEqual(
            try sqliteInt(databaseURL, "PRAGMA user_version"),
            Int64(SQLiteLibraryStore.schemaVersion))
        XCTAssertEqual(
            try sqliteInt(databaseURL, "SELECT COUNT(*) FROM schema_migrations"),
            Int64(SQLiteLibraryStore.schemaVersion - 1))
        XCTAssertEqual(
            try sqliteText(
                databaseURL,
                "SELECT name FROM workspaces WHERE id = '\(SQLiteLibraryStore.homeWorkspaceID.uuidString)'"),
            "V2 Home",
            "forward migration preserves the row even though its new local-state receipt is pending")
        XCTAssertThrowsError(
            try store.workspaceSnapshot(id: SQLiteLibraryStore.homeWorkspaceID),
            "a pending v2 receipt must not enter the rehearsal read path")
        XCTAssertEqual(
            try sqliteText(
                databaseURL,
                "SELECT import_state FROM migration_sources WHERE domain = 'workspaces'"),
            "pending",
            "v2 receipts cannot claim the newly added local-state projection is current")
        XCTAssertFalse(try store.status().wasResetOnOpen)
    }

    func testRehearsalReadsRequireMatchingCurrentReceipts() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let workspaceValue = workspace()
        let conversationValue = conversation(workspaceID: workspaceValue.id)
        let artifactValue = artifact(workspaceID: workspaceValue.id)
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [workspaceValue], conversations: [conversationValue]))
        _ = try store.upsert(artifact: artifactValue)

        XCTAssertNotNil(try store.workspaceSnapshot(id: workspaceValue.id))
        XCTAssertNotNil(try store.conversationSnapshot(id: conversationValue.id))
        XCTAssertNotNil(try store.artifactSnapshot(id: artifactValue.id))

        try executeSQL(store.databaseURL, """
            UPDATE migration_sources
            SET dirty = 1, import_state = 'quarantine', imported_revision = NULL,
                imported_digest = NULL
            WHERE domain = 'conversations'
              AND source_identity = '\(conversationValue.source.identity)';
            """)
        XCTAssertThrowsError(try store.conversationSnapshot(id: conversationValue.id))
        _ = try store.upsert(conversation: conversationValue)

        try executeSQL(store.databaseURL, """
            UPDATE migration_sources
            SET dirty = 1, import_state = 'quarantine', imported_revision = NULL,
                imported_digest = NULL
            WHERE domain = 'operative_state'
              AND source_identity = '\(conversationValue.source.identity)';
            """)
        XCTAssertThrowsError(
            try store.conversationSnapshot(id: conversationValue.id),
            "Conversation content is not current unless its exact operative receipt is current too")

        try executeSQL(store.databaseURL, """
            UPDATE migration_sources
            SET dirty = 1, import_state = 'quarantine', imported_revision = NULL,
                imported_digest = NULL
            WHERE domain = 'workspaces'
              AND source_identity = '\(workspaceValue.source.identity)';
            """)
        XCTAssertThrowsError(try store.workspaceSnapshot(id: workspaceValue.id))

        try executeSQL(store.databaseURL, """
            UPDATE migration_sources
            SET dirty = 1, import_state = 'quarantine', imported_revision = NULL,
                imported_digest = NULL
            WHERE domain = 'artifact_media'
              AND source_identity = '\(artifactValue.source.identity)';
            """)
        XCTAssertThrowsError(try store.artifactSnapshot(id: artifactValue.id))
    }

    func testRehearsalReadsRejectMalformedRowsInsteadOfSilentlyOmittingFacts() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let workspaceValue = workspace()
        let nestedPayload = Data("nested".utf8)
        let nested = ShadowLibraryNestedArtifactSnapshot(
            artifactID: UUID(), canonicalPayload: nestedPayload,
            canonicalPayloadDigest: digest(nestedPayload),
            contentDigest: digest(Data("body".utf8)), contentByteCount: 4)
        let conversationValue = conversation(
            workspaceID: workspaceValue.id,
            nestedArtifacts: [nested])
        let artifactValue = artifact(workspaceID: workspaceValue.id)
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [workspaceValue], conversations: [conversationValue]))
        _ = try store.upsert(artifact: artifactValue)

        let originalEventID = try XCTUnwrap(conversationValue.events.first?.id)
        try executeSQL(store.databaseURL, """
            UPDATE conversation_events SET id = 'not-a-uuid'
            WHERE conversation_id = '\(conversationValue.id.uuidString)';
            """)
        XCTAssertThrowsError(try store.conversationSnapshot(id: conversationValue.id))
        try executeSQL(store.databaseURL, """
            UPDATE conversation_events SET id = '\(originalEventID.uuidString)'
            WHERE conversation_id = '\(conversationValue.id.uuidString)';
            UPDATE conversation_artifact_snapshots SET artifact_id = 'not-a-uuid'
            WHERE conversation_id = '\(conversationValue.id.uuidString)';
            """)
        XCTAssertThrowsError(try store.conversationSnapshot(id: conversationValue.id))
        try executeSQL(store.databaseURL, """
            UPDATE conversation_artifact_snapshots SET artifact_id = '\(nested.artifactID.uuidString)'
            WHERE conversation_id = '\(conversationValue.id.uuidString)';
            UPDATE conversations SET workspace_id = 'not-a-uuid'
            WHERE id = '\(conversationValue.id.uuidString)';
            """)
        XCTAssertThrowsError(try store.conversationSnapshot(id: conversationValue.id))

        try executeSQL(store.databaseURL, """
            PRAGMA ignore_check_constraints = ON;
            UPDATE workspaces SET kind = 'future-workspace-kind'
            WHERE id = '\(workspaceValue.id.uuidString)';
            """)
        XCTAssertThrowsError(try store.workspaceSnapshot(id: workspaceValue.id))

        try executeSQL(store.databaseURL, """
            UPDATE artifacts SET provenance_conversation_id = 'not-a-uuid'
            WHERE id = '\(artifactValue.id.uuidString)';
            """)
        XCTAssertThrowsError(try store.artifactSnapshot(id: artifactValue.id))
    }

    func testRetainedByteReadsRejectMalformedInventoryAndReferenceRows() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let conversationValue = conversation()
        let retained = retainedByte(
            identity: "conversation-media/retained-read.png",
            ownerConversationID: conversationValue.id,
            content: Data("retained-read".utf8))
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [], conversations: [conversationValue]))
        _ = try store.upsert(retainedByte: retained)
        let reference = ShadowLibraryRetainedByteReferenceSnapshot(
            id: UUID(),
            retainedSourceIdentity: retained.source.identity,
            ownerKind: .event,
            ownerConversationID: conversationValue.id,
            ownerEventID: conversationValue.events[0].id,
            referenceKind: "tool_image")
        try store.replaceRetainedByteReferences(
            ownerConversationID: conversationValue.id,
            references: [reference])

        try executeSQL(store.databaseURL, """
            PRAGMA ignore_check_constraints = ON;
            UPDATE retained_byte_sources SET storage_state = 'future-state'
            WHERE source_identity = '\(retained.source.identity)';
            """)
        XCTAssertThrowsError(try store.retainedByteInventory())
        try executeSQL(store.databaseURL, """
            UPDATE retained_byte_sources SET storage_state = 'adopted'
            WHERE source_identity = '\(retained.source.identity)';
            UPDATE retained_byte_references SET owner_event_id = 'not-a-uuid'
            WHERE reference_id = '\(reference.id.uuidString)';
            """)
        XCTAssertThrowsError(
            try store.retainedByteReferences(ownerConversationID: conversationValue.id))
    }

    func testConversationReadBundleReturnsReceiptGatedConversationAndCompleteReferences() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let conversationValue = conversation()
        let retained = retainedByte(
            identity: "conversation-media/\(conversationValue.id.uuidString)/bundle.png",
            ownerConversationID: conversationValue.id,
            content: Data("bundle bytes".utf8))
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [], conversations: [conversationValue]))
        _ = try store.upsert(retainedByte: retained)
        let eventReference = ShadowLibraryRetainedByteReferenceSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            retainedSourceIdentity: retained.source.identity,
            ownerKind: .event,
            ownerConversationID: conversationValue.id,
            ownerEventID: conversationValue.events[0].id,
            referenceKind: "tool_image")
        let conversationReference = ShadowLibraryRetainedByteReferenceSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            retainedSourceIdentity: retained.source.identity,
            ownerKind: .conversation,
            ownerConversationID: conversationValue.id,
            ownerEventID: nil,
            referenceKind: "retained_media")
        _ = try store.reconcileRetainedByteReferences(
            ownerConversationID: conversationValue.id,
            conversationSourceIdentity: conversationValue.source.identity,
            references: [conversationReference, eventReference],
            readiness: nil)
        let sequence = try sqliteInt(
            store.databaseURL,
            "SELECT shadow_change_sequence FROM library_metadata WHERE singleton = 1")

        let bundle = try XCTUnwrap(store.conversationReadBundle(id: conversationValue.id))

        XCTAssertEqual(bundle.conversation, conversationValue)
        XCTAssertEqual(bundle.retainedByteReferences, [eventReference, conversationReference])
        XCTAssertEqual(bundle.retainedByteSources.count, 1)
        XCTAssertEqual(bundle.retainedByteSources[0].source, retained.source)
        XCTAssertEqual(bundle.retainedByteSources[0].storageState, .adopted)
        XCTAssertEqual(bundle.retainedByteSources[0].disposition, .referenced)
        XCTAssertEqual(
            try sqliteInt(
                store.databaseURL,
                "SELECT shadow_change_sequence FROM library_metadata WHERE singleton = 1"),
            sequence,
            "an atomic read bundle must not advance the shadow mutation sequence")
        XCTAssertNil(try store.conversationReadBundle(id: UUID()))
    }

    func testVerifiedReadOnlyLaunchBundleRequiresShadowAndDoesNotAdvanceSequence() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = HomeWorkspaceSettings(
            instructions: "Read only launch",
            updatedAt: Date(timeIntervalSinceReferenceDate: 70))
        let local = try LibraryWorkspaceAdapter.captureLocalState(from: settings)
        let home = ShadowLibraryWorkspaceSnapshot.home(
            settings: settings,
            source: .implicitHomeWorkspace,
            localStateVersion: local.version,
            localStatePayload: local.payload)
        var writer: SQLiteLibraryStore? = try SQLiteLibraryStore(supportRoot: root)
        _ = try writer?.reconcile(ShadowLibraryImportSnapshot(
            home: home, workspaces: [], conversations: []))
        let sequence = try XCTUnwrap(writer?.status().shadowChangeSequence)
        let instanceID = try XCTUnwrap(writer?.status().databaseInstanceID)
        writer = nil

        let reader = try SQLiteLibraryStore.openVerifiedReadOnlyShadow(supportRoot: root)
        let bundle = try reader.launchInventoryBundle()

        XCTAssertEqual(bundle.databaseInstanceID, instanceID)
        XCTAssertEqual(bundle.shadowChangeSequence, sequence)
        XCTAssertEqual(bundle.home.instructions, settings.instructions)
        XCTAssertTrue(bundle.workspaces.isEmpty)
        XCTAssertTrue(bundle.conversations.isEmpty)
        XCTAssertTrue(bundle.intrinsicConversations.isEmpty)
        XCTAssertEqual(
            try sqliteInt(
                reader.databaseURL,
                "SELECT shadow_change_sequence FROM library_metadata WHERE singleton = 1"),
            sequence)
        XCTAssertThrowsError(try reader.upsert(workspace: home),
                             "the launch reader must remain SQLite-read-only")
        XCTAssertEqual(
            try sqliteInt(
                reader.databaseURL,
                "SELECT shadow_change_sequence FROM library_metadata WHERE singleton = 1"),
            sequence)
    }

    func testLaunchInventoryRejectsLiveConversationWithoutMetadata() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversation = Conversation(
            title: "Metadata is required",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Keep the complete record")],
            updatedAt: Date(timeIntervalSinceReferenceDate: 90))
        var store: SQLiteLibraryStore? = try SQLiteLibraryStore(supportRoot: root)
        let snapshot = try LibraryConversationAdapter.capture(
            conversation,
            source: source("conversations/\(conversation.id.uuidString).json"))
        _ = try XCTUnwrap(store).reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [], conversations: [snapshot]))
        let databaseURL = try XCTUnwrap(store).databaseURL
        try executeSQL(
            databaseURL,
            "DELETE FROM conversation_events WHERE kind = 'conversation.metadata'")
        store = nil

        let reader = try SQLiteLibraryStore.openVerifiedReadOnlyShadow(supportRoot: root)
        XCTAssertThrowsError(try reader.launchInventoryBundle()) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("metadata is absent for 1 live row"),
                "unexpected launch validation error: \(error)")
        }
    }

    func testConversationReadBundleRejectsReferenceSourceAndEventDrift() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let conversationValue = conversation()
        let retained = retainedByte(
            identity: "conversation-media/\(conversationValue.id.uuidString)/drift.png",
            ownerConversationID: conversationValue.id,
            content: Data("drift bytes".utf8))
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [], conversations: [conversationValue]))
        _ = try store.upsert(retainedByte: retained)
        let reference = ShadowLibraryRetainedByteReferenceSnapshot(
            id: UUID(),
            retainedSourceIdentity: retained.source.identity,
            ownerKind: .event,
            ownerConversationID: conversationValue.id,
            ownerEventID: conversationValue.events[0].id,
            referenceKind: "tool_image")
        _ = try store.reconcileRetainedByteReferences(
            ownerConversationID: conversationValue.id,
            conversationSourceIdentity: conversationValue.source.identity,
            references: [reference],
            readiness: nil)
        XCTAssertNotNil(try store.conversationReadBundle(id: conversationValue.id))

        try executeSQL(store.databaseURL, """
            UPDATE retained_byte_sources
            SET storage_state = 'observed', disposition = 'reference_pending'
            WHERE source_identity = '\(retained.source.identity)';
            """)
        XCTAssertThrowsError(
            try store.conversationReadBundle(id: conversationValue.id),
            "an edge whose managed source stopped being referenced must fail closed")

        try executeSQL(store.databaseURL, """
            UPDATE retained_byte_sources
            SET storage_state = 'adopted', disposition = 'referenced'
            WHERE source_identity = '\(retained.source.identity)';
            UPDATE retained_byte_references
            SET owner_event_id = '\(UUID().uuidString)'
            WHERE reference_id = '\(reference.id.uuidString)';
            """)
        XCTAssertThrowsError(
            try store.conversationReadBundle(id: conversationValue.id),
            "an event edge may not escape the Conversation event spine")
    }

    func testSnapshotsRoundTripLocalStateTombstonesAndNestedArtifactOrder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let workspaceID = UUID()
        let workspaceSource = source("workspaces/roundtrip.json", revision: "9")
        let workspaceValue = ShadowLibraryWorkspaceSnapshot(
            id: workspaceID,
            kind: .named,
            name: "Round Trip",
            goal: "Keep every fact",
            instructions: "Exact",
            cwd: "/tmp/roundtrip",
            favorite: true,
            sortIndex: 2,
            iconSymbol: "arrow.triangle.2.circlepath",
            colorHex: "#123456",
            createdAt: Date(timeIntervalSinceReferenceDate: 11),
            updatedAt: Date(timeIntervalSinceReferenceDate: 12),
            revision: 9,
            tombstoned: true,
            localStateVersion: 2,
            localStatePayload: Data("workspace-local".utf8),
            source: workspaceSource)
        let firstPayload = Data("first".utf8)
        let secondPayload = Data("second".utf8)
        let first = ShadowLibraryNestedArtifactSnapshot(
            artifactID: UUID(), canonicalPayload: firstPayload,
            canonicalPayloadDigest: digest(firstPayload),
            contentDigest: "content-first", contentByteCount: 1)
        let second = ShadowLibraryNestedArtifactSnapshot(
            artifactID: UUID(), canonicalPayload: secondPayload,
            canonicalPayloadDigest: digest(secondPayload),
            contentDigest: "content-second", contentByteCount: 2)
        let base = conversation(workspaceID: workspaceID, nestedArtifacts: [second, first])
        let conversationValue = ShadowLibraryConversationSnapshot(
            id: base.id, title: base.title, titleSource: base.titleSource, cwd: base.cwd,
            workspaceID: base.workspaceID, updatedAt: base.updatedAt, favorite: base.favorite,
            sortIndex: base.sortIndex, unread: base.unread, errored: base.errored,
            revision: 8, tombstoned: true, localStateVersion: 3,
            localStatePayload: Data("conversation-local".utf8), source: base.source,
            events: base.events, nestedArtifacts: base.nestedArtifacts)

        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [workspaceValue], conversations: [conversationValue]))

        XCTAssertEqual(try store.workspaceSnapshot(id: workspaceID), workspaceValue)
        XCTAssertEqual(try store.conversationSnapshot(id: conversationValue.id), conversationValue)
        XCTAssertEqual(
            try store.conversationSnapshot(id: conversationValue.id)?.nestedArtifacts.map(\.artifactID),
            [second.artifactID, first.artifactID])
        let operative = try XCTUnwrap(store.status().domain(.operativeState))
        XCTAssertEqual(operative.phase, .shadowing)
        XCTAssertEqual(operative.total, 1)
        XCTAssertEqual(operative.current, 1)
        XCTAssertTrue(operative.hasFullCensus)
    }

    func testArtifactAndRetainedByteReadBackPreserveStorageSemantics() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let artifactValue = artifact()
        let retainedValue = retainedByte(
            identity: "conversation-trash-media/recoverable.png",
            ownerConversationID: nil,
            content: Data("recoverable".utf8),
            kind: .conversationTrashMedia)

        _ = try store.upsert(artifact: artifactValue)
        _ = try store.upsert(retainedByte: retainedValue)

        XCTAssertEqual(try store.artifactSnapshot(id: artifactValue.id), artifactValue)
        XCTAssertEqual(try store.retainedByteInventory(), [retainedValue])
        XCTAssertEqual(try store.retainedByteInventory().first?.storageState, .observed)
        XCTAssertEqual(try store.retainedByteInventory().first?.retentionState, .undoRetained)
    }

    func testRetainedByteReferencesEnforceEventOwnershipAndCascade() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let conversationValue = conversation()
        let bytes = Data("linked".utf8)
        let retained = retainedByte(
            identity: "conversation-media/linked.png",
            ownerConversationID: conversationValue.id,
            content: bytes)
        let unreferenced = retainedByte(
            identity: "conversation-media/unreferenced.png",
            ownerConversationID: conversationValue.id,
            content: Data("unreferenced".utf8))
        let mismatch = retainedByte(
            identity: "conversation-media/mismatch.png",
            ownerConversationID: conversationValue.id,
            content: Data("mismatch".utf8),
            linkState: .mismatch,
            diagnostics: "Reference did not resolve")
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [], conversations: [conversationValue]))
        _ = try store.upsert(retainedByte: retained)
        _ = try store.upsert(retainedByte: unreferenced)
        _ = try store.upsert(retainedByte: mismatch)
        let eventReference = ShadowLibraryRetainedByteReferenceSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            retainedSourceIdentity: retained.source.identity,
            ownerKind: .event,
            ownerConversationID: conversationValue.id,
            ownerEventID: conversationValue.events[0].id,
            referenceKind: "image_paths")
        let localReference = ShadowLibraryRetainedByteReferenceSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            retainedSourceIdentity: retained.source.identity,
            ownerKind: .localState,
            ownerConversationID: conversationValue.id,
            ownerEventID: nil,
            referenceKind: "draft_file_token")

        try store.replaceRetainedByteReferences(
            ownerConversationID: conversationValue.id,
            references: [eventReference, localReference])
        XCTAssertEqual(
            try store.retainedByteReferences(ownerConversationID: conversationValue.id),
            [eventReference, localReference])
        let adoptedInventory = Dictionary(
            uniqueKeysWithValues: try store.retainedByteInventory().map {
                ($0.source.identity, $0.storageState)
            })
        XCTAssertEqual(adoptedInventory[retained.source.identity], .adopted)
        XCTAssertEqual(adoptedInventory[unreferenced.source.identity], .observed)
        XCTAssertEqual(adoptedInventory[mismatch.source.identity], .observed)
        var referenceStatus = try store.status()
        XCTAssertEqual(referenceStatus.artifactMedia?.adoptedRetainedByteSourceCount, 1)
        XCTAssertEqual(referenceStatus.artifactMedia?.retainedByteReferenceCount, 2)
        XCTAssertEqual(referenceStatus.artifactMedia?.unreferencedRetainedByteSourceCount, 0)
        XCTAssertEqual(referenceStatus.artifactMedia?.pendingRetainedByteDispositionCount, 1)

        referenceStatus = try store.reconcileRetainedByteReferences(
            ownerConversationID: conversationValue.id,
            conversationSourceIdentity: conversationValue.source.identity,
            references: [eventReference, localReference],
            readiness: ShadowLibraryRetainedByteReadinessFinding(
                diagnostics: "Retained-byte readiness blocked: ambiguous inventory.",
                isBlocking: true))
        XCTAssertEqual(referenceStatus.domain(.operativeState)?.quarantined, 1)
        XCTAssertEqual(referenceStatus.domain(.operativeState)?.current, 0)

        // An accounted finding — a reference whose file is simply gone — keeps its explanation on
        // the row without costing the Conversation its operative state.
        let accounted = "Retained-byte readiness blocked: 1 missing, 0 mismatched, 0 invalid."
        referenceStatus = try store.reconcileRetainedByteReferences(
            ownerConversationID: conversationValue.id,
            conversationSourceIdentity: conversationValue.source.identity,
            references: [eventReference, localReference],
            readiness: ShadowLibraryRetainedByteReadinessFinding(
                diagnostics: accounted, isBlocking: false))
        XCTAssertEqual(referenceStatus.domain(.operativeState)?.quarantined, 0)
        XCTAssertEqual(referenceStatus.domain(.operativeState)?.current, 1)
        XCTAssertEqual(referenceStatus.domain(.operativeState)?.dirty, 0)
        XCTAssertEqual(
            try sqliteText(
                store.databaseURL,
                "SELECT diagnostics FROM migration_sources WHERE domain = 'operative_state'"),
            accounted,
            "an accounted finding must stay readable in the database")

        referenceStatus = try store.reconcileRetainedByteReferences(
            ownerConversationID: conversationValue.id,
            conversationSourceIdentity: conversationValue.source.identity,
            references: [eventReference, localReference],
            readiness: nil)
        XCTAssertEqual(referenceStatus.domain(.operativeState)?.quarantined, 0)
        XCTAssertEqual(referenceStatus.domain(.operativeState)?.current, 1)
        let stableSequence = try sqliteInt(
            store.databaseURL,
            "SELECT shadow_change_sequence FROM library_metadata WHERE singleton = 1")
        _ = try store.reconcileRetainedByteReferences(
            ownerConversationID: conversationValue.id,
            conversationSourceIdentity: conversationValue.source.identity,
            references: [eventReference, localReference],
            readiness: nil)
        XCTAssertEqual(
            try sqliteInt(
                store.databaseURL,
                "SELECT shadow_change_sequence FROM library_metadata WHERE singleton = 1"),
            stableSequence,
            "an unchanged reference assessment must not rewrite SQLite on every launch")

        let mismatchReference = ShadowLibraryRetainedByteReferenceSnapshot(
            id: UUID(), retainedSourceIdentity: mismatch.source.identity,
            ownerKind: .localState, ownerConversationID: conversationValue.id,
            ownerEventID: nil, referenceKind: "draft_file_token")
        XCTAssertThrowsError(try store.replaceRetainedByteReferences(
            ownerConversationID: conversationValue.id,
            references: [mismatchReference]))

        let invalid = ShadowLibraryRetainedByteReferenceSnapshot(
            id: UUID(), retainedSourceIdentity: retained.source.identity, ownerKind: .event,
            ownerConversationID: conversationValue.id, ownerEventID: UUID(),
            referenceKind: "tool_image")
        XCTAssertThrowsError(try store.replaceRetainedByteReferences(
            ownerConversationID: conversationValue.id,
            references: [invalid]))
        XCTAssertEqual(
            try store.retainedByteReferences(ownerConversationID: conversationValue.id),
            [eventReference, localReference],
            "failed replacement must roll back the prior reference set")

        _ = try store.removeConversation(sourceIdentity: conversationValue.source.identity)
        XCTAssertTrue(try store.retainedByteReferences(
            ownerConversationID: conversationValue.id).isEmpty)
        XCTAssertEqual(
            try store.retainedByteInventory().first {
                $0.source.identity == retained.source.identity
            }?.storageState,
            .observed)
    }

    func testAuthorityLifecycleIsDormantStrictAndMonotonic() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: SQLiteLibraryStore? = try SQLiteLibraryStore(supportRoot: root)
        let activationID = UUID()
        let rollbackID = UUID()

        XCTAssertEqual(try store?.authorityMetadata().authorityState, .shadow)
        XCTAssertThrowsError(try store?.activatePreparedAuthority(activationID: activationID))
        let projectionFrontier = try XCTUnwrap(store).status()
        try XCTUnwrap(store).acknowledgeExactProjectionSnapshot(
            databaseInstanceID: projectionFrontier.databaseInstanceID,
            through: projectionFrontier.shadowChangeSequence,
            projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion))
        try store?.prepareAuthority(activationID: activationID, minimumWriterBuild: "300")
        XCTAssertEqual(try store?.authorityMetadata().authorityState, .prepared)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("library.db.shadow-resettable").path))
        XCTAssertThrowsError(try store?.upsert(workspace: home())) { error in
            guard case SQLiteLibraryStoreError.protectedDatabase = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try store?.activatePreparedAuthority(activationID: UUID()))
        try store?.activatePreparedAuthority(activationID: activationID)
        XCTAssertEqual(try store?.advanceCommittedSequence(activationID: activationID), 1)
        XCTAssertEqual(try store?.advanceCommittedSequence(activationID: activationID), 2)
        XCTAssertThrowsError(try store?.advanceCommittedSequence(activationID: UUID()))
        try store?.prepareRollback(activationID: activationID, rollbackID: rollbackID)
        XCTAssertThrowsError(try store?.completeRollback(
            activationID: activationID,
            rollbackID: UUID()))
        try store?.completeRollback(activationID: activationID, rollbackID: rollbackID)
        XCTAssertEqual(try store?.authorityMetadata().authorityState, .rolledBack)
        XCTAssertEqual(try store?.authorityMetadata().committedSequence, 2)

        store = nil
        XCTAssertThrowsError(try SQLiteLibraryStore(supportRoot: root)) { error in
            guard case SQLiteLibraryStoreError.protectedDatabase = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testAuthorityPreparationAllowsDisposableProjectionToLag() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let resetMarkerURL = root.appendingPathComponent("library.db.shadow-resettable")

        XCTAssertEqual(try store.projectionBacklogCount(), 0)
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [], conversations: [conversation()]))
        let frontier = try store.status()
        XCTAssertGreaterThan(frontier.shadowChangeSequence, 0)
        XCTAssertEqual(try store.projectionBacklogCount(), 1)

        let activationID = UUID()
        try store.prepareAuthority(activationID: activationID, minimumWriterBuild: "300")
        let metadata = try store.authorityMetadata()
        XCTAssertEqual(metadata.authorityState, .prepared)
        XCTAssertEqual(metadata.committedSequence, frontier.shadowChangeSequence)
        XCTAssertEqual(try store.projectionBacklogCount(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resetMarkerURL.path))
    }

    func testAuthorityPreparationPreservesPendingProjectionWork() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let resetMarkerURL = root.appendingPathComponent("library.db.shadow-resettable")
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [], conversations: [conversation()]))
        let frontier = try store.status()
        try executeSQL(
            store.databaseURL,
            """
            UPDATE projection_state
            SET projection_schema_version = \(ConversationProjectionStore.schemaVersion),
                applied_high_water_sequence = \(frontier.shadowChangeSequence),
                health = 'current', last_error = NULL
            WHERE database_instance_id = '\(frontier.databaseInstanceID.uuidString)'
              AND projection_kind = 'conversation_search'
            """)

        XCTAssertEqual(try store.projectionBacklogCount(), 1)
        let activationID = UUID()
        try store.prepareAuthority(activationID: activationID, minimumWriterBuild: "300")
        let metadata = try store.authorityMetadata()
        XCTAssertEqual(metadata.authorityState, .prepared)
        XCTAssertEqual(metadata.committedSequence, frontier.shadowChangeSequence)
        XCTAssertEqual(try store.projectionBacklogCount(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resetMarkerURL.path))
    }

    func testAuthorityPreparationTransactionFailureLeavesShadowResettable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let resetMarkerURL = root.appendingPathComponent("library.db.shadow-resettable")
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [], conversations: [conversation()]))
        let frontier = try store.status()
        try store.acknowledgeExactProjectionSnapshot(
            databaseInstanceID: frontier.databaseInstanceID,
            through: frontier.shadowChangeSequence,
            projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion))
        try executeSQL(
            store.databaseURL,
            """
            CREATE TRIGGER inject_authority_prepare_failure
            BEFORE UPDATE OF authority_state ON library_metadata
            WHEN NEW.authority_state = 'prepared'
            BEGIN
              SELECT RAISE(ABORT, 'injected authority prepare failure');
            END
            """)

        XCTAssertThrowsError(
            try store.prepareAuthority(activationID: UUID(), minimumWriterBuild: "300"))

        let metadata = try store.authorityMetadata()
        XCTAssertEqual(metadata.authorityState, .shadow)
        XCTAssertEqual(metadata.committedSequence, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: resetMarkerURL.path),
            "a failed prepare transaction must not strand a markerless shadow")
    }

    func testAuthorityPreparationRebasesCommittedSequenceToCurrentShadowFrontier() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let activationID = UUID()
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [], conversations: [conversation()]))
        let frontier = try store.status()
        XCTAssertGreaterThan(frontier.shadowChangeSequence, 0)
        try store.acknowledgeExactProjectionSnapshot(
            databaseInstanceID: frontier.databaseInstanceID,
            through: frontier.shadowChangeSequence,
            projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion))
        XCTAssertEqual(try store.projectionBacklogCount(), 0)

        try store.prepareAuthority(activationID: activationID, minimumWriterBuild: "300")

        let prepared = try store.authorityMetadata()
        XCTAssertEqual(prepared.authorityState, .prepared)
        XCTAssertEqual(prepared.committedSequence, frontier.shadowChangeSequence)
        XCTAssertEqual(
            try sqliteInt(
                store.databaseURL,
                "SELECT committed_sequence FROM library_metadata WHERE singleton = 1"),
            try sqliteInt(
                store.databaseURL,
                "SELECT shadow_change_sequence FROM library_metadata WHERE singleton = 1"))
        try store.activatePreparedAuthority(activationID: activationID)
        XCTAssertEqual(
            try store.advanceCommittedSequence(activationID: activationID),
            frontier.shadowChangeSequence + 1)
    }

    func testAuthoritativeAppendPreservesUnchangedEventRowsWhileMovingMetadata() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let activationID = UUID()
        let conversationID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let metadataID = UUID()
        let firstPayload = Data("first immutable payload".utf8)
        let secondPayload = Data("second immutable payload".utf8)
        let initial = ShadowLibraryConversationSnapshot(
            id: conversationID, title: "Append proof", titleSource: "legacy", cwd: "",
            workspaceID: nil, updatedAt: Date(timeIntervalSinceReferenceDate: 40),
            favorite: false, sortIndex: nil, unread: false, errored: false, revision: 1,
            source: source("conversations/\(conversationID.uuidString).json"),
            events: [
                ShadowLibraryEventSnapshot(
                    id: firstID, captureSequence: 0, kind: "transcript.user",
                    actorID: "user", payload: firstPayload),
                ShadowLibraryEventSnapshot(
                    id: secondID, captureSequence: 1, kind: "transcript.assistant",
                    actorID: "assistant", payload: secondPayload),
                ShadowLibraryEventSnapshot(
                    id: metadataID, captureSequence: 2, kind: "conversation.metadata",
                    payload: Data("metadata-v1".utf8)),
            ])
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [], conversations: [initial]))
        let frontier = try store.status()
        try store.acknowledgeExactProjectionSnapshot(
            databaseInstanceID: frontier.databaseInstanceID,
            through: frontier.shadowChangeSequence,
            projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion))
        try store.prepareAuthority(activationID: activationID, minimumWriterBuild: "300")
        try store.activatePreparedAuthority(activationID: activationID)
        let activeMetadata = try store.authorityMetadata()
        let activeStore = try SQLiteLibraryStore.openActiveAuthority(
            supportRoot: root,
            marker: StorageAuthorityMarker(
                mode: .sqlite,
                activationID: activationID,
                databaseInstanceID: activeMetadata.databaseInstanceID,
                schemaVersion: activeMetadata.schemaVersion,
                minimumWriterBuild: "300",
                createdAt: "2026-08-05T12:00:00Z"))

        let firstRowID = try sqliteInt(
            activeStore.databaseURL,
            "SELECT rowid FROM conversation_events WHERE id = '\(firstID.uuidString)'")
        let secondRowID = try sqliteInt(
            activeStore.databaseURL,
            "SELECT rowid FROM conversation_events WHERE id = '\(secondID.uuidString)'")
        let appendedID = UUID()
        let partial = ShadowLibraryConversationSnapshot(
            id: conversationID, title: "Append proof", titleSource: "legacy", cwd: "",
            workspaceID: nil, updatedAt: Date(timeIntervalSinceReferenceDate: 41),
            favorite: false, sortIndex: nil, unread: false, errored: false, revision: 2,
            source: source(
                "conversations/\(conversationID.uuidString).json", revision: "2"),
            events: [
                ShadowLibraryEventSnapshot(
                    id: appendedID, captureSequence: 2, kind: "transcript.assistant",
                    actorID: "assistant", payload: Data("new payload".utf8)),
                ShadowLibraryEventSnapshot(
                    id: metadataID, captureSequence: 3, kind: "conversation.metadata",
                    payload: Data("metadata-v2".utf8)),
            ])
        _ = try activeStore.commitAuthoritativeMutation(
            conversation: partial,
            changedTranscriptEntryIDs: [appendedID],
            // What the record holds after the append. The omitted rows are named here and nowhere
            // else, which is the only reason this write can tell them apart from removed ones.
            liveTranscriptOrder: [firstID, secondID, appendedID],
            activationID: activationID)

        XCTAssertEqual(
            try sqliteInt(activeStore.databaseURL,
                "SELECT rowid FROM conversation_events WHERE id = '\(firstID.uuidString)'"),
            firstRowID)
        XCTAssertEqual(
            try sqliteInt(activeStore.databaseURL,
                "SELECT rowid FROM conversation_events WHERE id = '\(secondID.uuidString)'"),
            secondRowID)
        XCTAssertEqual(
            try sqliteBlob(activeStore.databaseURL,
                "SELECT payload FROM conversation_events WHERE id = '\(firstID.uuidString)'"),
            firstPayload)
        XCTAssertEqual(
            try sqliteBlob(activeStore.databaseURL,
                "SELECT payload FROM conversation_events WHERE id = '\(secondID.uuidString)'"),
            secondPayload)
        let reconstructed = try XCTUnwrap(activeStore.authoritativeConversationSnapshot(
            id: conversationID, activationID: activationID))
        XCTAssertEqual(reconstructed.events.map(\.id), [firstID, secondID, appendedID, metadataID])
        XCTAssertEqual(reconstructed.events.map(\.captureSequence), [0, 1, 2, 3])
    }

    func testLocalStatePayloadBoundIsEnforcedBeforeSQLite() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let base = conversation()
        let oversized = ShadowLibraryConversationSnapshot(
            id: base.id, title: base.title, titleSource: base.titleSource, cwd: base.cwd,
            workspaceID: base.workspaceID, updatedAt: base.updatedAt, favorite: base.favorite,
            sortIndex: base.sortIndex, unread: base.unread, errored: base.errored,
            revision: base.revision, localStateVersion: 1,
            localStatePayload: Data(repeating: 0, count: SQLiteLibraryStore.maximumLocalStatePayloadBytes + 1),
            source: base.source, events: base.events)

        XCTAssertThrowsError(try store.upsert(conversation: oversized)) { error in
            guard case SQLiteLibraryStoreError.invalidInput = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try sqliteInt(store.databaseURL, "SELECT COUNT(*) FROM conversations"), 0)
    }

    func testUnprovenCorruptDatabaseIsPreservedButKnownShadowSchemaMismatchResets() throws {
        let corruptRoot = try makeRoot()
        let mismatchRoot = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: corruptRoot)
            try? FileManager.default.removeItem(at: mismatchRoot)
        }

        var corruptStore: SQLiteLibraryStore? = try SQLiteLibraryStore(supportRoot: corruptRoot)
        let corruptURL = try XCTUnwrap(corruptStore?.databaseURL)
        corruptStore = nil
        let corruptBytes = Data("not a sqlite database".utf8)
        try corruptBytes.write(to: corruptURL)
        XCTAssertThrowsError(try SQLiteLibraryStore(supportRoot: corruptRoot)) { error in
            guard case SQLiteLibraryStoreError.protectedDatabase = error else {
                XCTFail("unexpected error: \(error)")
                return
            }
        }
        XCTAssertEqual(try Data(contentsOf: corruptURL), corruptBytes)

        var mismatchStore: SQLiteLibraryStore? = try SQLiteLibraryStore(supportRoot: mismatchRoot)
        let mismatchURL = try XCTUnwrap(mismatchStore?.databaseURL)
        mismatchStore = nil
        try stampSchemaVersion(mismatchURL, 99)
        let rebuiltMismatch = try SQLiteLibraryStore(supportRoot: mismatchRoot)
        let mismatchStatus = try rebuiltMismatch.status()
        XCTAssertTrue(mismatchStatus.wasResetOnOpen)
        XCTAssertTrue(mismatchStatus.resetReason?.contains("schema version mismatch") == true)
        XCTAssertEqual(mismatchStatus.integrity.state, .passed)
    }

    func testCurrentSourceMustAlsoOwnEntityRowAfterDuplicateWinnerChanges() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let id = UUID()
        let oldSource = source("conversations/old.json", revision: "1")
        let newSource = source("conversations/new.json", revision: "2")
        let old = conversation(id: id, source: oldSource)
        let new = conversation(id: id, source: newSource)

        _ = try store.upsert(conversation: old)
        _ = try store.recordSourceIssue(
            domain: .conversations,
            source: oldSource,
            entityIdentity: id.uuidString,
            kind: .duplicate,
            diagnostics: "older duplicate")
        _ = try store.upsert(conversation: new)

        // A later scan sees the older filename first, then the already-current winner. The winner
        // must repair the entity row instead of trusting only its historical source-registry row.
        _ = try store.upsert(conversation: old)
        _ = try store.upsert(conversation: new)
        XCTAssertEqual(
            try sqliteText(
                store.databaseURL,
                "SELECT source_identity FROM conversations WHERE id = '\(id.uuidString)'"),
            newSource.identity)
    }

    func testReconciliationCannotReuseHistoricalSourceReceipts() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let source = conversation()
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [], conversations: [source]))

        let census = ShadowLibraryReconciliationCensus(
            workspaceSourceIdentities: [home().source.identity],
            conversationSourceIdentities: [source.source.identity])
        let token = try store.beginReconciliation(census)
        _ = try store.upsert(workspace: home())
        XCTAssertThrowsError(try store.finishReconciliation(token)) { error in
            XCTAssertTrue(error.localizedDescription.contains("did not import every source"))
        }
        store.cancelReconciliation(token)
        XCTAssertFalse(try XCTUnwrap(store.status().domain(.conversations)).hasFullCensus)

        let retry = try store.beginReconciliation(census)
        _ = try store.upsert(workspace: home())
        XCTAssertTrue(try store.accountIfImportedDigestIsCurrent(
            domain: .conversations,
            source: source.source))
        XCTAssertNoThrow(try store.finishReconciliation(retry))
    }

    func testFutureAuthorityDatabaseIsNeverResetByShadowBuild() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var shadow: SQLiteLibraryStore? = try SQLiteLibraryStore(supportRoot: root)
        let databaseURL = try XCTUnwrap(shadow?.databaseURL)
        shadow = nil
        try executeSQL(
            databaseURL,
            """
            DROP TABLE library_metadata;
            CREATE TABLE library_metadata (
              singleton INTEGER PRIMARY KEY,
              authority_state TEXT NOT NULL,
              database_instance_id TEXT NOT NULL
            );
            INSERT INTO library_metadata VALUES (1, 'active', 'future-authority-sentinel');
            PRAGMA wal_checkpoint(TRUNCATE);
            PRAGMA journal_mode = DELETE;
            """)
        let databaseBytes = try Data(contentsOf: databaseURL)
        let familyBefore = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(try sqliteText(databaseURL, "PRAGMA journal_mode"), "delete")

        XCTAssertThrowsError(try SQLiteLibraryStore(supportRoot: root)) { error in
            guard case SQLiteLibraryStoreError.protectedDatabase = error else {
                XCTFail("unexpected error: \(error)")
                return
            }
        }
        XCTAssertEqual(
            try sqliteText(
                databaseURL,
                "SELECT database_instance_id FROM library_metadata WHERE singleton = 1"),
            "future-authority-sentinel",
            "an old shadow build must preserve a database it cannot own")
        XCTAssertEqual(try sqliteText(databaseURL, "PRAGMA journal_mode"), "delete")
        XCTAssertEqual(try Data(contentsOf: databaseURL), databaseBytes)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
            familyBefore,
            "inspection must not create WAL/SHM files or alter the future database family")
    }

    func testProjectionOutboxCoalescesAndOldAcknowledgementCannotPruneNewerWork() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let id = UUID()
        let first = conversation(
            id: id,
            source: source("conversations/\(id.uuidString).json", revision: "1"))
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [], conversations: [first]))

        let oldWork = try XCTUnwrap(store.nextProjectionWork(projectionSchemaVersion: 5))
        XCTAssertEqual(oldWork.entityID, id)
        XCTAssertNotNil(oldWork.conversation)

        let second = conversation(
            id: id,
            source: source("conversations/\(id.uuidString).json", revision: "2"),
            eventID: UUID())
        _ = try store.upsert(conversation: second)
        XCTAssertEqual(try store.projectionBacklogCount(), 1)

        try store.acknowledgeProjectionWork(oldWork, projectionSchemaVersion: 5)
        XCTAssertEqual(
            try store.projectionBacklogCount(), 1,
            "an acknowledgement for the replaced desired sequence must not prune newer work")
        let newest = try XCTUnwrap(store.nextProjectionWork(projectionSchemaVersion: 5))
        XCTAssertGreaterThan(newest.desiredSequence, oldWork.desiredSequence)
        XCTAssertEqual(newest.conversation?.source.revision, "2")
        try store.acknowledgeProjectionWork(newest, projectionSchemaVersion: 5)
        XCTAssertEqual(try store.projectionBacklogCount(), 0)
    }

    func testFullProjectionReplaySeedsLiveRowsAfterPriorOutboxWasAcknowledged() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let firstID = UUID()
        let secondID = UUID()
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(),
            workspaces: [],
            conversations: [
                conversation(
                    id: firstID,
                    source: source("conversations/\(firstID.uuidString).json")),
                conversation(
                    id: secondID,
                    source: source("conversations/\(secondID.uuidString).json")),
            ]))
        let accepted = try store.status()
        try store.acknowledgeExactProjectionSnapshot(
            databaseInstanceID: accepted.databaseInstanceID,
            through: accepted.shadowChangeSequence,
            projectionSchemaVersion: 5)
        XCTAssertEqual(try store.projectionBacklogCount(), 0)

        try store.prepareFullProjectionReplay(projectionSchemaVersion: 5)
        XCTAssertEqual(
            try store.projectionBacklogCount(), 2,
            "a replaced disposable cache needs every live SQLite row, not only newer mutations")
        var replayed: Set<UUID> = []
        while let work = try store.nextProjectionWork(projectionSchemaVersion: 5) {
            replayed.insert(work.entityID)
            try store.acknowledgeProjectionWork(work, projectionSchemaVersion: 5)
        }
        XCTAssertEqual(replayed, [firstID, secondID])
        XCTAssertEqual(
            try sqliteText(
                store.databaseURL,
                "SELECT health FROM projection_state WHERE projection_kind = 'conversation_search'"),
            "projecting",
            "draining entity jobs is not a closed-set acknowledgement")
        XCTAssertEqual(
            try sqliteInt(
                store.databaseURL,
                "SELECT applied_high_water_sequence FROM projection_state "
                    + "WHERE projection_kind = 'conversation_search'"),
            0,
            "the high-water cannot advance until projection orphan cleanup commits")
    }

    func testMalformedProjectionOutboxIdentityFailsInsteadOfSpinning() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let instanceID = try XCTUnwrap(store.status().databaseInstanceID)
        try executeSQL(
            store.databaseURL,
            """
            INSERT INTO projection_outbox (
              database_instance_id, projection_kind, entity_id, desired_sequence)
            VALUES ('\(instanceID.uuidString)', 'conversation_search', 'not-a-uuid', 1)
            """)

        XCTAssertThrowsError(
            try store.nextProjectionWork(projectionSchemaVersion: 5))
        XCTAssertEqual(try store.projectionBacklogCount(), 1)
        XCTAssertEqual(
            try sqliteText(
                store.databaseURL,
                "SELECT health FROM projection_state WHERE projection_kind = 'conversation_search'"),
            "failed")
    }

    func testProjectionDeleteWorkSurvivesReopenUntilAcknowledged() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let identity = "conversations/\(id.uuidString).json"
        var store: SQLiteLibraryStore? = try SQLiteLibraryStore(supportRoot: root)
        let value = conversation(id: id, source: source(identity))
        _ = try XCTUnwrap(store).reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [], conversations: [value]))
        try XCTUnwrap(store).acknowledgeExactProjectionSnapshot(
            databaseInstanceID: try XCTUnwrap(store).status().databaseInstanceID,
            through: try XCTUnwrap(store).status().shadowChangeSequence,
            projectionSchemaVersion: 5)
        XCTAssertEqual(try XCTUnwrap(store).projectionBacklogCount(), 0)

        _ = try XCTUnwrap(store).removeConversation(sourceIdentity: identity)
        let beforeCrash = try XCTUnwrap(
            try XCTUnwrap(store).nextProjectionWork(projectionSchemaVersion: 5))
        XCTAssertEqual(beforeCrash.entityID, id)
        XCTAssertNil(beforeCrash.conversation)
        store = nil

        let reopened = try SQLiteLibraryStore(supportRoot: root)
        let replayed = try XCTUnwrap(
            reopened.nextProjectionWork(projectionSchemaVersion: 5))
        XCTAssertEqual(replayed.entityID, id)
        XCTAssertEqual(replayed.desiredSequence, beforeCrash.desiredSequence)
        XCTAssertNil(replayed.conversation)
        try reopened.acknowledgeProjectionWork(replayed, projectionSchemaVersion: 5)
        XCTAssertEqual(try reopened.projectionBacklogCount(), 0)
    }

    func testExactProjectionAcknowledgementRetainsConcurrentNewerSequence() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let id = UUID()
        let identity = "conversations/\(id.uuidString).json"
        let first = conversation(id: id, source: source(identity, revision: "1"))
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [], conversations: [first]))
        let accepted = try store.status()

        let second = conversation(
            id: id,
            source: source(identity, revision: "2"),
            eventID: UUID())
        _ = try store.upsert(conversation: second)
        try store.acknowledgeExactProjectionSnapshot(
            databaseInstanceID: accepted.databaseInstanceID,
            through: accepted.shadowChangeSequence,
            projectionSchemaVersion: 5)

        XCTAssertEqual(try store.projectionBacklogCount(), 1)
        XCTAssertGreaterThan(
            try XCTUnwrap(store.nextProjectionWork(projectionSchemaVersion: 5)).desiredSequence,
            accepted.shadowChangeSequence)
    }

    func testCommittedConversationMutationMarksProjectionQueuedBeforeWorkerClaim() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let identity = "conversations/\(id.uuidString).json"
        var store: SQLiteLibraryStore? = try SQLiteLibraryStore(supportRoot: root)
        _ = try XCTUnwrap(store).reconcile(ShadowLibraryImportSnapshot(
            home: home(),
            workspaces: [],
            conversations: [conversation(id: id, source: source(identity, revision: "1"))]))
        let accepted = try XCTUnwrap(store).status()
        try XCTUnwrap(store).acknowledgeExactProjectionSnapshot(
            databaseInstanceID: accepted.databaseInstanceID,
            through: accepted.shadowChangeSequence,
            projectionSchemaVersion: 5)
        XCTAssertEqual(
            try sqliteText(
                try XCTUnwrap(store).databaseURL,
                "SELECT health FROM projection_state WHERE projection_kind = 'conversation_search'"),
            "current")

        _ = try XCTUnwrap(store).upsert(conversation: conversation(
            id: id,
            source: source(identity, revision: "2"),
            eventID: UUID()))
        XCTAssertEqual(
            try sqliteText(
                try XCTUnwrap(store).databaseURL,
                "SELECT health FROM projection_state WHERE projection_kind = 'conversation_search'"),
            "queued",
            "the entity mutation and non-current receipt must commit together")
        store = nil

        let reopened = try SQLiteLibraryStore(supportRoot: root)
        XCTAssertEqual(
            try sqliteText(
                reopened.databaseURL,
                "SELECT health FROM projection_state WHERE projection_kind = 'conversation_search'"),
            "queued")
        XCTAssertEqual(try reopened.projectionBacklogCount(), 1)
    }

    func testSupportRootsAreIsolated() throws {
        let firstRoot = try makeRoot()
        let secondRoot = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let first = try SQLiteLibraryStore(supportRoot: firstRoot)
        let second = try SQLiteLibraryStore(supportRoot: secondRoot)
        let firstConversation = conversation()
        _ = try first.reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [], conversations: [firstConversation]))
        _ = try second.reconcile(ShadowLibraryImportSnapshot(
            home: home(), workspaces: [], conversations: []))

        XCTAssertNotEqual(first.databaseURL, second.databaseURL)
        XCTAssertNotEqual(
            try first.status().databaseInstanceID,
            try second.status().databaseInstanceID)
        XCTAssertEqual(try sqliteInt(first.databaseURL, "SELECT COUNT(*) FROM conversations"), 1)
        XCTAssertEqual(try sqliteInt(second.databaseURL, "SELECT COUNT(*) FROM conversations"), 0)
    }
}
