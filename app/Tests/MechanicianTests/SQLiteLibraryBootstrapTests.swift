import XCTest
@testable import Mechanician

final class SQLiteLibraryBootstrapTests: XCTestCase {
    func testPristineRootPublishesAndReopensEmptySQLiteAuthority() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let recognition = StorageAuthorityRecognizer.inspect(supportRoot: root)
        let result = try SQLiteLibraryBootstrapService.provisionIfNeeded(
            recognition: recognition,
            ownsProcessLease: true,
            now: { Date(timeIntervalSinceReferenceDate: 123) })

        guard case .sqlite(let marker, let probe) = result.disposition else {
            return XCTFail("expected SQLite authority, got \(result.disposition)")
        }
        XCTAssertEqual(probe.authorityState, .active)
        XCTAssertEqual(probe.databaseInstanceID, marker.databaseInstanceID)
        XCTAssertEqual(probe.activationID, marker.activationID)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(StorageAuthorityProtocol.markerName).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(StorageAuthorityProtocol.resetMarkerName).path))

        let repository = try XCTUnwrap(LibraryAuthorityRepository.open(recognition: result))
        let inventory = try repository.launchInventory()
        XCTAssertTrue(inventory.workspaces.isEmpty)
        XCTAssertTrue(inventory.conversations.isEmpty)
        XCTAssertTrue(inventory.artifacts.isEmpty)
        XCTAssertEqual(inventory.home, HomeWorkspaceSettings(
            updatedAt: Date(timeIntervalSinceReferenceDate: 123)))
    }

    func testEveryLegacyFactClassRefusesWithoutCreatingDatabaseOrMarker() throws {
        for name in [
            "conversations", "workspaces", "projects", "workspaces.json",
            "home-workspace.json", "artifacts", "ambient", "ambient-projection",
            "conversation-media", "trash", "authority-inbox",
        ] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let path = root.appendingPathComponent(name)
            if name.contains(".") && !name.hasSuffix("projection") {
                FileManager.default.createFile(atPath: path.path, contents: Data("fact".utf8))
            } else {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            }

            XCTAssertThrowsError(try SQLiteLibraryBootstrapService.provisionIfNeeded(
                recognition: StorageAuthorityRecognizer.inspect(supportRoot: root),
                ownsProcessLease: true
            )) { error in
                guard case SQLiteLibraryBootstrapService.Error.legacyLibrary(let observed) = error
                else { return XCTFail("unexpected error: \(error)") }
                XCTAssertEqual(observed, name)
            }
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(StorageAuthorityProtocol.databaseName).path))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(StorageAuthorityProtocol.markerName).path))
        }
    }

    func testQuarantinedHomeAndSymlinkAreLegacyFacts() throws {
        for name in ["home-workspace.json.corrupt-123", "conversations"] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let path = root.appendingPathComponent(name)
            if name == "conversations" {
                try FileManager.default.createSymbolicLink(
                    at: path, withDestinationURL: URL(fileURLWithPath: "/tmp"))
            } else {
                FileManager.default.createFile(atPath: path.path, contents: Data())
            }
            XCTAssertThrowsError(try SQLiteLibraryBootstrapService.provisionIfNeeded(
                recognition: StorageAuthorityRecognizer.inspect(supportRoot: root),
                ownsProcessLease: true))
        }
    }

    func testInterruptedShadowPreparedAndActiveEmptyBootstrapsResume() throws {
        for state in [LibraryAuthorityState.shadow, .prepared, .active] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try SQLiteLibraryStore(supportRoot: root)
            let home = try LibraryWorkspaceAdapter.capture(
                home: HomeWorkspaceSettings(updatedAt: Date(timeIntervalSinceReferenceDate: 50)),
                source: .implicitHomeWorkspace)
            _ = try store.reconcile(ShadowLibraryImportSnapshot(
                home: home, workspaces: [], conversations: []))
            let activationID = UUID()
            if state != .shadow {
                try store.prepareAuthority(
                    activationID: activationID,
                    minimumWriterBuild: StorageAuthorityProtocol.recognitionID)
            }
            if state == .active {
                try store.activatePreparedAuthority(activationID: activationID)
            }

            let before = StorageAuthorityRecognizer.inspect(supportRoot: root)
            guard case .legacyUnmarked(let probe) = before.disposition else {
                return XCTFail("expected interrupted unmarked database")
            }
            XCTAssertEqual(probe?.authorityState, state)
            let result = try SQLiteLibraryBootstrapService.provisionIfNeeded(
                recognition: before, ownsProcessLease: true)
            guard case .sqlite(_, let active) = result.disposition else {
                return XCTFail("expected resumed SQLite authority")
            }
            XCTAssertEqual(active.authorityState, .active)
            if state != .shadow { XCTAssertEqual(active.activationID, activationID) }
        }
    }

    func testUnmarkedDatabaseWithAnyUserRowIsPreservedAndRefused() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let home = try LibraryWorkspaceAdapter.capture(
            home: HomeWorkspaceSettings(), source: .implicitHomeWorkspace)
        let workspace = Project(name: "Must survive", cwd: "/tmp")
        let workspaceSource = ShadowLibrarySourceFingerprint(
            identity: "workspaces/\(workspace.id.uuidString).json",
            revision: "1", sourceBytes: Data("workspace".utf8))
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home,
            workspaces: [try LibraryWorkspaceAdapter.capture(
                workspace, source: workspaceSource)],
            conversations: []))

        XCTAssertThrowsError(try SQLiteLibraryBootstrapService.provisionIfNeeded(
            recognition: StorageAuthorityRecognizer.inspect(supportRoot: root),
            ownsProcessLease: true))
        // The database remains unmarked and the row remains readable from the original handle.
        XCTAssertNotNil(try store.workspaceSnapshot(id: workspace.id))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(StorageAuthorityProtocol.markerName).path))
    }

    func testNoLeaseDoesNotMutatePristineRoot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recognition = StorageAuthorityRecognizer.inspect(supportRoot: root)
        XCTAssertEqual(
            try SQLiteLibraryBootstrapService.provisionIfNeeded(
                recognition: recognition, ownsProcessLease: false),
            recognition)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: root.path)
        return root
    }
}
