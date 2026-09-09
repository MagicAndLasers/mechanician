import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Mechanician

final class LibraryBackupServiceTests: XCTestCase {
    func testOnlineBackupIncludesAdoptedBytesAndRestoresInIsolation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        let sourceBytesBefore = try Data(contentsOf: fixture.mediaURL)
        let sourceAttributesBefore = try FileManager.default.attributesOfItem(
            atPath: fixture.mediaURL.path)
        let backupURL = fixture.base.appendingPathComponent("backup", isDirectory: true)
        let backupID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let receipt = try LibraryBackupService.createBackup(
            sourceSupportRoot: fixture.sourceRoot,
            destinationURL: backupURL,
            backupID: backupID,
            createdAt: Date(timeIntervalSince1970: 1_787_000_000))

        XCTAssertEqual(receipt.manifest.formatVersion, LibraryBackupManifest.currentFormatVersion)
        XCTAssertEqual(receipt.manifest.backupID, backupID)
        XCTAssertEqual(receipt.manifest.database.databaseInstanceID, fixture.databaseInstanceID)
        XCTAssertEqual(receipt.manifest.database.schemaVersion, SQLiteLibraryStore.schemaVersion)
        XCTAssertEqual(receipt.manifest.database.applicationID, SQLiteLibraryStore.applicationID)
        XCTAssertEqual(receipt.manifest.database.authorityState, "shadow")
        XCTAssertNil(receipt.manifest.database.activationID)
        XCTAssertEqual(receipt.manifest.database.committedSequence, 0)
        XCTAssertEqual(receipt.manifest.retainedBytes.count, 1)
        let retained = try XCTUnwrap(receipt.manifest.retainedBytes.first)
        XCTAssertEqual(retained.sourceIdentity, fixture.mediaIdentity)
        XCTAssertEqual(retained.storageIdentity, fixture.mediaIdentity)
        XCTAssertEqual(retained.sha256, digest(fixture.mediaBytes))
        XCTAssertEqual(retained.byteCount, Int64(fixture.mediaBytes.count))
        XCTAssertEqual(retained.references.map(\.referenceID), [fixture.referenceID])
        XCTAssertEqual(try Data(contentsOf: fixture.mediaURL), sourceBytesBefore)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: fixture.mediaURL.path)[.posixPermissions]
                as? NSNumber,
            sourceAttributesBefore[.posixPermissions] as? NSNumber,
            "backup must not mutate the live retained byte")

        assertMode(backupURL, equals: 0o700)
        assertMode(backupURL.appendingPathComponent("library.db"), equals: 0o600)
        assertMode(backupURL.appendingPathComponent("manifest.json"), equals: 0o600)
        assertMode(backupURL.appendingPathComponent("manifest.sha256"), equals: 0o600)
        let backupObject = backupURL.appendingPathComponent(retained.backupRelativePath)
        assertMode(backupObject, equals: 0o600)

        // Destroying the live source after the complete backup demonstrates that restore consumes
        // the manifest-bound backup object, not a path back into the live support root.
        try Data("live-source-now-different".utf8).write(to: fixture.mediaURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.mediaURL.path)
        let restoredRoot = fixture.base.appendingPathComponent("isolated-restore", isDirectory: true)
        let report = try LibraryBackupService.verifyAndRestore(
            backupURL: backupURL,
            isolatedSupportRoot: restoredRoot)

        XCTAssertEqual(report.databaseInstanceID, fixture.databaseInstanceID)
        XCTAssertEqual(report.schemaVersion, SQLiteLibraryStore.schemaVersion)
        XCTAssertEqual(report.authorityState, .shadow)
        XCTAssertNil(report.activationID)
        XCTAssertEqual(report.committedSequence, 0)
        XCTAssertEqual(report.retainedByteCount, 1)
        XCTAssertEqual(report.retainedBytes, Int64(fixture.mediaBytes.count))
        XCTAssertEqual(report.manifestSHA256, receipt.manifestSHA256)
        XCTAssertEqual(
            try Data(contentsOf: restoredRoot.appendingPathComponent(fixture.mediaIdentity)),
            fixture.mediaBytes)
        assertMode(restoredRoot, equals: 0o700)
        assertMode(restoredRoot.appendingPathComponent("library.db"), equals: 0o600)
        assertMode(restoredRoot.appendingPathComponent(fixture.mediaIdentity), equals: 0o600)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: restoredRoot.appendingPathComponent("library.db-wal").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: restoredRoot.appendingPathComponent("library.db.shadow-resettable").path))
    }

    func testRestoreRejectsTamperedOrMetadataOnlyBackup() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let backupURL = fixture.base.appendingPathComponent("backup", isDirectory: true)
        let receipt = try LibraryBackupService.createBackup(
            sourceSupportRoot: fixture.sourceRoot,
            destinationURL: backupURL)
        let retained = try XCTUnwrap(receipt.manifest.retainedBytes.first)
        let object = backupURL.appendingPathComponent(retained.backupRelativePath)
        try Data("tampered".utf8).write(to: object)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: object.path)

        let restored = fixture.base.appendingPathComponent("rejected-restore", isDirectory: true)
        XCTAssertThrowsError(try LibraryBackupService.verifyAndRestore(
            backupURL: backupURL,
            isolatedSupportRoot: restored)) { error in
            guard case LibraryBackupServiceError.verification = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.path))
    }

    func testBackupRejectsNonOwnerOnlyAdoptedSourceWithoutChangingIt() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: fixture.mediaURL.path)
        let backupURL = fixture.base.appendingPathComponent("backup", isDirectory: true)

        XCTAssertThrowsError(try LibraryBackupService.createBackup(
            sourceSupportRoot: fixture.sourceRoot,
            destinationURL: backupURL)) { error in
            guard case LibraryBackupServiceError.permissions = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.mediaURL.path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(mode & 0o777, 0o644)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testSharedObjectPoolHardLinksVerifiedBytesAcrossGenerations() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let pool = fixture.base.appendingPathComponent("shared-objects", isDirectory: true)
        let first = try LibraryBackupService.createBackup(
            sourceSupportRoot: fixture.sourceRoot,
            destinationURL: fixture.base.appendingPathComponent("backup-one", isDirectory: true),
            sharedObjectPoolURL: pool)
        let firstRetained = try XCTUnwrap(first.manifest.retainedBytes.first)
        let poolObject = pool
            .appendingPathComponent(String(firstRetained.sha256.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(firstRetained.sha256).blob", isDirectory: false)
        let firstObject = first.backupURL.appendingPathComponent(firstRetained.backupRelativePath)

        assertMode(pool, equals: 0o700)
        assertMode(poolObject.deletingLastPathComponent(), equals: 0o700)
        assertMode(poolObject, equals: 0o400)
        assertMode(firstObject, equals: 0o400)
        assertOwnerWriteRefused(poolObject)
        assertOwnerWriteRefused(firstObject)
        XCTAssertEqual(try Data(contentsOf: poolObject), fixture.mediaBytes)

        // A later generation reuses the protected inode without needing to make it writable.
        let second = try LibraryBackupService.createBackup(
            sourceSupportRoot: fixture.sourceRoot,
            destinationURL: fixture.base.appendingPathComponent("backup-two", isDirectory: true),
            sharedObjectPoolURL: pool)
        let secondRetained = try XCTUnwrap(second.manifest.retainedBytes.first)
        let secondObject = second.backupURL.appendingPathComponent(secondRetained.backupRelativePath)
        assertMode(secondObject, equals: 0o400)
        let poolIdentity = try fileIdentity(poolObject)
        XCTAssertEqual(try fileIdentity(firstObject), poolIdentity)
        XCTAssertEqual(try fileIdentity(secondObject), poolIdentity)
        XCTAssertGreaterThanOrEqual(try linkCount(poolObject), 3)

        // A generation is independently restorable even after another generation is removed; its
        // hard link owns the bytes and never resolves through a mutable pointer back to the pool.
        try FileManager.default.removeItem(at: first.backupURL)
        let restored = fixture.base.appendingPathComponent("pooled-restore", isDirectory: true)
        let report = try LibraryBackupService.verifyAndRestore(
            backupURL: second.backupURL,
            isolatedSupportRoot: restored)
        XCTAssertEqual(report.retainedByteCount, 1)
        XCTAssertEqual(
            try Data(contentsOf: restored.appendingPathComponent(fixture.mediaIdentity)),
            fixture.mediaBytes)
    }

    func testSharedObjectPoolUpgradesVerifiedLegacyWritableObjectBeforeReuse() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let pool = fixture.base.appendingPathComponent("shared-objects", isDirectory: true)
        try FileManager.default.createDirectory(at: pool, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pool.path)
        let expectedDigest = digest(fixture.mediaBytes)
        let shard = pool.appendingPathComponent(String(expectedDigest.prefix(2)), isDirectory: true)
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shard.path)
        let object = shard.appendingPathComponent("\(expectedDigest).blob", isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: object.path,
            contents: fixture.mediaBytes,
            attributes: [.posixPermissions: 0o600]))

        let backup = try LibraryBackupService.createBackup(
            sourceSupportRoot: fixture.sourceRoot,
            destinationURL: fixture.base.appendingPathComponent("upgraded-backup", isDirectory: true),
            sharedObjectPoolURL: pool)
        let retained = try XCTUnwrap(backup.manifest.retainedBytes.first)
        let generationObject = backup.backupURL.appendingPathComponent(retained.backupRelativePath)

        assertMode(object, equals: 0o400)
        assertMode(generationObject, equals: 0o400)
        assertOwnerWriteRefused(object)
        XCTAssertEqual(try fileIdentity(object), try fileIdentity(generationObject))
        XCTAssertEqual(try Data(contentsOf: generationObject), fixture.mediaBytes)
    }

    func testSharedObjectPoolRefusesCorruptExistingObject() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let pool = fixture.base.appendingPathComponent("shared-objects", isDirectory: true)
        try FileManager.default.createDirectory(at: pool, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pool.path)
        let expectedDigest = digest(fixture.mediaBytes)
        let shard = pool.appendingPathComponent(String(expectedDigest.prefix(2)), isDirectory: true)
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shard.path)
        let object = shard.appendingPathComponent("\(expectedDigest).blob", isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: object.path,
            contents: Data("wrong bytes".utf8),
            attributes: [.posixPermissions: 0o600]))
        let destination = fixture.base.appendingPathComponent("rejected-backup", isDirectory: true)

        XCTAssertThrowsError(try LibraryBackupService.createBackup(
            sourceSupportRoot: fixture.sourceRoot,
            destinationURL: destination,
            sharedObjectPoolURL: pool)) { error in
            guard case LibraryBackupServiceError.verification = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: object), Data("wrong bytes".utf8))
    }

    /// Opt-in full-corpus proof over an isolated, explicitly marked support-root copy. The backup
    /// and restore are created under a separate owner-only temporary directory and removed after
    /// verification; the source copy is opened read-only by the service.
    func testCopiedCorpusBackupAndIsolatedRestoreProbe() throws {
        guard let rawRoot = ProcessInfo.processInfo.environment[
            "MECHANICIAN_LIBRARY_BACKUP_PROBE_COPY"] else {
            throw XCTSkip("Set MECHANICIAN_LIBRARY_BACKUP_PROBE_COPY to an isolated marked copy.")
        }
        let sourceRoot = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent(
            ".mechanician-shadow-probe-copy").path) else {
            XCTFail("Refusing to read an unmarked support root")
            return
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mechanician-backup-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        defer { try? FileManager.default.removeItem(at: base) }

        let started = ContinuousClock.now
        let receipt = try LibraryBackupService.createBackup(
            sourceSupportRoot: sourceRoot,
            destinationURL: base.appendingPathComponent("backup", isDirectory: true))
        let report = try LibraryBackupService.verifyAndRestore(
            backupURL: receipt.backupURL,
            isolatedSupportRoot: base.appendingPathComponent("restore", isDirectory: true))
        let elapsed = started.duration(to: .now)

        XCTAssertEqual(report.databaseInstanceID, receipt.manifest.database.databaseInstanceID)
        XCTAssertEqual(report.retainedByteCount, receipt.manifest.retainedBytes.count)
        XCTAssertGreaterThan(report.retainedByteCount, 0)
        XCTAssertGreaterThan(report.retainedBytes, 0)
        XCTAssertEqual(report.manifestSHA256, receipt.manifestSHA256)
        print(
            "LIBRARY_BACKUP_PROBE retained=\(report.retainedByteCount) "
                + "bytes=\(report.retainedBytes) elapsed=\(elapsed)")
    }
}

private extension LibraryBackupServiceTests {
    struct Fixture {
        let base: URL
        let sourceRoot: URL
        let mediaURL: URL
        let mediaIdentity: String
        let mediaBytes: Data
        let referenceID: UUID
        let databaseInstanceID: UUID
        // Retain the live connection through backup so the test actually exercises SQLite's
        // online-backup API against the same WAL-capable state used by the app.
        let store: SQLiteLibraryStore
    }

    func makeFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-backup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        let sourceRoot = base.appendingPathComponent("live-support", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sourceRoot.path)

        let store = try SQLiteLibraryStore(supportRoot: sourceRoot)
        let conversationID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let eventID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let home = ShadowLibraryWorkspaceSnapshot.home(
            settings: HomeWorkspaceSettings(
                instructions: "Keep exact facts",
                updatedAt: Date(timeIntervalSinceReferenceDate: 1)),
            source: .implicitHomeWorkspace,
            revision: 1)
        let conversation = ShadowLibraryConversationSnapshot(
            id: conversationID,
            title: "Backup fixture",
            titleSource: "legacy",
            cwd: "",
            workspaceID: nil,
            updatedAt: Date(timeIntervalSinceReferenceDate: 2),
            favorite: false,
            sortIndex: nil,
            unread: false,
            errored: false,
            revision: 1,
            source: ShadowLibrarySourceFingerprint(
                identity: "conversations/\(conversationID.uuidString).json",
                revision: "1",
                sourceBytes: Data("conversation".utf8)),
            events: [
                ShadowLibraryEventSnapshot(
                    id: eventID,
                    captureSequence: 0,
                    kind: "entry.user",
                    actorID: "user",
                    observedAt: Date(timeIntervalSinceReferenceDate: 2),
                    payload: Data("hello".utf8)),
            ])
        _ = try store.reconcile(ShadowLibraryImportSnapshot(
            home: home, workspaces: [], conversations: [conversation]))

        let mediaBytes = Data("immutable retained bytes".utf8)
        let mediaName = "99999999-8888-7777-6666-555555555555.png"
        let mediaIdentity = "conversation-media/\(conversationID.uuidString)/\(mediaName)"
        let mediaRoot = sourceRoot.appendingPathComponent("conversation-media", isDirectory: true)
        let ownerRoot = mediaRoot.appendingPathComponent(conversationID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mediaRoot.path)
        try FileManager.default.createDirectory(at: ownerRoot, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ownerRoot.path)
        let mediaURL = ownerRoot.appendingPathComponent(mediaName, isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: mediaURL.path,
            contents: mediaBytes,
            attributes: [.posixPermissions: 0o600]))
        let retained = ShadowLibraryRetainedByteSnapshot(
            kind: .conversationMedia,
            ownerConversationID: conversationID,
            storageName: mediaName,
            mediaType: "image/png",
            linkState: .current,
            diagnostics: nil,
            source: ShadowLibrarySourceFingerprint(
                identity: mediaIdentity,
                revision: "fixture-v1",
                digest: digest(mediaBytes),
                byteCount: mediaBytes.count))
        _ = try store.upsert(retainedByte: retained)
        let referenceID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        try store.replaceRetainedByteReferences(
            ownerConversationID: conversationID,
            references: [ShadowLibraryRetainedByteReferenceSnapshot(
                id: referenceID,
                retainedSourceIdentity: mediaIdentity,
                ownerKind: .event,
                ownerConversationID: conversationID,
                ownerEventID: eventID,
                referenceKind: "image_paths")])
        return Fixture(
            base: base,
            sourceRoot: sourceRoot,
            mediaURL: mediaURL,
            mediaIdentity: mediaIdentity,
            mediaBytes: mediaBytes,
            referenceID: referenceID,
            databaseInstanceID: try store.authorityMetadata().databaseInstanceID,
            store: store)
    }

    func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func assertMode(
        _ url: URL,
        equals expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            XCTAssertEqual(mode & 0o777, expected, file: file, line: line)
        } catch {
            XCTFail("could not read permissions: \(error)", file: file, line: line)
        }
    }

    func assertOwnerWriteRefused(
        _ url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        errno = 0
        let descriptor = Darwin.open(url.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        let failure = errno
        if descriptor >= 0 {
            Darwin.close(descriptor)
            XCTFail("owner-read-only object unexpectedly opened for writing", file: file, line: line)
        } else {
            XCTAssertTrue(
                failure == EACCES || failure == EPERM,
                "unexpected write-open errno: \(failure)",
                file: file,
                line: line)
        }
    }

    func fileIdentity(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let device = try XCTUnwrap(attributes[.systemNumber] as? NSNumber)
        let inode = try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber)
        return "\(device):\(inode)"
    }

    func linkCount(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.referenceCount] as? NSNumber).intValue
    }
}
