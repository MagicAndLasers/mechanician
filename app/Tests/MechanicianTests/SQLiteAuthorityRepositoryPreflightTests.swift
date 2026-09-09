import Foundation
import XCTest
@testable import Mechanician

final class SQLiteAuthorityRepositoryPreflightTests: XCTestCase {
    private enum ForcedFailure: LocalizedError {
        case writableOpen

        var errorDescription: String? { "forced writable-open failure" }
    }

    func testActiveSQLiteOpenFailureBecomesBlockedRecoveryWithOriginalError() throws {
        let marker = StorageAuthorityMarker(
            mode: .sqlite,
            activationID: UUID(),
            databaseInstanceID: UUID(),
            schemaVersion: SQLiteLibraryStore.schemaVersion,
            createdAt: "2026-08-05T12:00:00Z")
        let root = URL(fileURLWithPath: "/tmp/preflight-library", isDirectory: true)
        let recognition = StorageAuthorityRecognition(
            anchorRoot: root,
            effectiveSupportRoot: root,
            marker: .valid(marker),
            disposition: .sqlite(
                marker: marker,
                database: StorageAuthorityDatabaseProbe(
                    databaseInstanceID: marker.databaseInstanceID,
                    schemaVersion: SQLiteLibraryStore.schemaVersion,
                    authorityState: .active,
                    activationID: marker.activationID,
                    rollbackID: nil,
                    minimumWriterBuild: StorageAuthorityProtocol.recognitionID,
                    committedSequence: 42)))

        let checked = SQLiteAuthorityRepositoryPreflight.evaluate(recognition) { _ in
            throw ForcedFailure.writableOpen
        }

        guard case .blocked(let message) = checked.disposition else {
            return XCTFail("failed writable preflight must enter blocked recovery")
        }
        XCTAssertEqual(
            message,
            "SQLite authority repository could not open: forced writable-open failure")
        XCTAssertEqual(checked.marker, recognition.marker)
        XCTAssertEqual(checked.anchorRoot, recognition.anchorRoot)
        XCTAssertFalse(checked.disposition.allowsNormalProduct)
        XCTAssertFalse(checked.disposition.allowsLegacyWriters)
    }

    func testLegacyRecognitionDoesNotOpenSQLiteRepository() {
        let root = URL(fileURLWithPath: "/tmp/preflight-legacy", isDirectory: true)
        let recognition = StorageAuthorityRecognition.legacyDefault(root: root)
        var opened = false

        let checked = SQLiteAuthorityRepositoryPreflight.evaluate(recognition) { _ in
            opened = true
            return true
        }

        XCTAssertEqual(checked, recognition)
        XCTAssertFalse(opened)
    }

    func testPreparedSQLiteRemainsAvailableToActivationResumeWithoutWritablePreflight() {
        let marker = StorageAuthorityMarker(
            mode: .sqlite,
            activationID: UUID(),
            databaseInstanceID: UUID(),
            schemaVersion: SQLiteLibraryStore.schemaVersion,
            createdAt: "2026-08-05T12:00:00Z")
        let root = URL(fileURLWithPath: "/tmp/preflight-prepared", isDirectory: true)
        let recognition = StorageAuthorityRecognition(
            anchorRoot: root,
            effectiveSupportRoot: root,
            marker: .valid(marker),
            disposition: .sqlite(
                marker: marker,
                database: StorageAuthorityDatabaseProbe(
                    databaseInstanceID: marker.databaseInstanceID,
                    schemaVersion: SQLiteLibraryStore.schemaVersion,
                    authorityState: .prepared,
                    activationID: marker.activationID,
                    rollbackID: nil,
                    minimumWriterBuild: StorageAuthorityProtocol.recognitionID,
                    committedSequence: 42)))
        var opened = false

        let checked = SQLiteAuthorityRepositoryPreflight.evaluate(recognition) { _ in
            opened = true
            return true
        }

        XCTAssertEqual(checked, recognition)
        XCTAssertFalse(opened)
    }
}
