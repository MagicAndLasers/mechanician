import SQLite3
import XCTest
@testable import Mechanician

@MainActor
final class TransientOperationCaptureTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let repository: LibraryAuthorityRepository
    }

    private struct OperationRow {
        let id: UUID
        let kind: String
        let state: String
    }

    private func fixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "transient-operation-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var store: SQLiteLibraryStore? = try SQLiteLibraryStore(supportRoot: url)
        let home = try LibraryWorkspaceAdapter.capture(
            home: HomeWorkspaceSettings(), source: .implicitHomeWorkspace)
        _ = try XCTUnwrap(store).reconcile(ShadowLibraryImportSnapshot(
            home: home, workspaces: [], conversations: []))
        let frontier = try XCTUnwrap(store).status()
        try XCTUnwrap(store).acknowledgeExactProjectionSnapshot(
            databaseInstanceID: frontier.databaseInstanceID,
            through: frontier.shadowChangeSequence,
            projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion))
        let activationID = UUID()
        try XCTUnwrap(store).prepareAuthority(
            activationID: activationID,
            minimumWriterBuild: StorageAuthorityProtocol.recognitionID)
        try XCTUnwrap(store).activatePreparedAuthority(activationID: activationID)
        let metadata = try XCTUnwrap(store).authorityMetadata()
        let marker = StorageAuthorityMarker(
            mode: .sqlite,
            activationID: activationID,
            databaseInstanceID: metadata.databaseInstanceID,
            schemaVersion: metadata.schemaVersion,
            createdAt: "2026-08-12T12:00:00Z")
        store = nil
        return Fixture(
            root: url,
            repository: try LibraryAuthorityRepository(
                store: SQLiteLibraryStore.openActiveAuthority(
                    supportRoot: url, marker: marker),
                supportRoot: url,
                marker: marker))
    }

    private func operationRows(_ fixture: Fixture) throws -> [OperationRow] {
        var database: OpaquePointer?
        let databaseURL = fixture.root.appendingPathComponent("library.db")
        guard sqlite3_open_v2(
            databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { throw NSError(domain: "test.sqlite", code: 1) }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT id, kind, state FROM operations ORDER BY created_at, id",
            -1,
            &statement,
            nil) == SQLITE_OK,
              let statement else { throw NSError(domain: "test.sqlite", code: 2) }
        defer { sqlite3_finalize(statement) }
        var rows: [OperationRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawID = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: rawID)),
                  let rawKind = sqlite3_column_text(statement, 1),
                  let rawState = sqlite3_column_text(statement, 2) else {
                throw NSError(domain: "test.sqlite", code: 3)
            }
            rows.append(OperationRow(
                id: id,
                kind: String(cString: rawKind),
                state: String(cString: rawState)))
        }
        return rows
    }

    private func receiptStates(_ fixture: Fixture) throws -> [String] {
        var database: OpaquePointer?
        let databaseURL = fixture.root.appendingPathComponent("library.db")
        guard sqlite3_open_v2(
            databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { throw NSError(domain: "test.sqlite", code: 4) }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT state FROM operation_receipts ORDER BY recorded_at, id",
            -1,
            &statement,
            nil) == SQLITE_OK,
              let statement else { throw NSError(domain: "test.sqlite", code: 5) }
        defer { sqlite3_finalize(statement) }
        var states: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else {
                throw NSError(domain: "test.sqlite", code: 6)
            }
            states.append(String(cString: raw))
        }
        return states
    }

    private func conversation(id: UUID = UUID(), workspaceID: UUID? = nil) -> Conversation {
        Conversation(
            id: id,
            title: "Writer capture",
            cwd: workspaceID == nil ? "" : "/tmp/writer-capture",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Durable content")],
            updatedAt: Date(timeIntervalSinceReferenceDate: 900),
            projectID: workspaceID)
    }

    func testBackgroundAdoptionCapturesOnlyAfterCanonicalPublication() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertTrue(try operationRows(fixture).isEmpty)
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            libraryAuthorityRepository: fixture.repository)
        let source = conversation()
        let capture = try LibraryTransientOperationCaptureFactory.backgroundAdoption(
            sourceIdentity: "authority-inbox/v1/adopted/ambientd/fixture.json",
            sourceRevision: "fixture-v1",
            sourceDigest: String(repeating: "a", count: 64),
            conversationID: source.id,
            recordedAt: source.updatedAt,
            operationID: UUID())
        let completed = expectation(description: "background adoption committed")
        store.adoptBackgroundConversation(source, authorityCapture: capture) { result in
            XCTAssertEqual(result, .published)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        let rows = try operationRows(fixture)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, capture.operation.id)
        XCTAssertEqual(rows.first?.kind, "background_adoption")
        XCTAssertEqual(try receiptStates(fixture), ["applied"])
    }

    func testArtifactDeleteAndRestoreCaptureAtDurableCompletionEdges() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let conversations = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            libraryAuthorityRepository: fixture.repository)
        let artifacts = ArtifactStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            libraryAuthorityRepository: fixture.repository)
        let artifact = artifacts.create(title: "Delete me", type: "text", source: "body")
        artifacts.flushSaves()
        await Task.yield()

        let receipt = try XCTUnwrap(artifacts.delete(
            artifact.id,
            conversations: conversations,
            synchronizeLiveState: false))
        artifacts.flushSaves()
        await Task.yield()
        var rows = try operationRows(fixture)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.kind, "artifact_delete")
        XCTAssertEqual(rows.first?.state, "committed")
        XCTAssertEqual(try receiptStates(fixture), ["applied"])

        XCTAssertTrue(artifacts.restore(receipt, conversations: conversations))
        artifacts.flushSaves()
        await Task.yield()
        rows = try operationRows(fixture)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.state)), ["committed", "reversed"])
        XCTAssertEqual(Set(try receiptStates(fixture)), ["applied", "reversed"])
    }

    func testWorkspaceMoveCapturesIdentityGroupsAfterConversationPublication() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let conversations = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            libraryAuthorityRepository: fixture.repository)
        let source = conversation()
        conversations.upsert(source)
        conversations.flushSaves()
        await Task.yield()

        let destination = Project(
            name: "Destination",
            cwd: "/tmp/writer-capture",
            createdAt: Date(timeIntervalSinceReferenceDate: 800),
            updatedAt: Date(timeIntervalSinceReferenceDate: 800))
        let result = WorkspaceAdoption.adopt(
            conversation: source.id,
            into: destination,
            conversations: conversations,
            artifactStore: nil,
            synchronizeLiveState: false)
        XCTAssertTrue(result.succeeded)

        conversations.flushSaves()
        await Task.yield()
        let operationDeadline = Date().addingTimeInterval(2)
        while try operationRows(fixture).isEmpty, Date() < operationDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let rows = try operationRows(fixture)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.kind, "workspace_move")
        XCTAssertEqual(rows.first?.state, "committed")
        XCTAssertEqual(try receiptStates(fixture), ["applied"])
        XCTAssertEqual(
            try fixture.repository.conversation(id: source.id)?.projectID,
            destination.id)
    }
}
