import Foundation
import XCTest
@testable import Mechanician

final class LibraryBackupLifecycleTests: XCTestCase {
    func testCreatesDailyBackupThenSkipsWithinTwentyFourHours() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let firstDate = Date(timeIntervalSince1970: 1_787_000_000)

        XCTAssertEqual(
            LibraryBackupLifecycle.backupRoot(for: fixture.sourceRoot),
            fixture.base.appendingPathComponent("Mechanician Library Backups", isDirectory: true))
        let first = try LibraryBackupLifecycle.createBackupIfDue(
            sourceSupportRoot: fixture.sourceRoot,
            now: firstDate,
            backupID: firstID)
        XCTAssertEqual(first.disposition, .created)
        XCTAssertEqual(first.receipt?.backupID, firstID)
        XCTAssertEqual(first.receipt?.retainedByteCount, 0)
        XCTAssertEqual(first.receipt?.retainedBytes, 0)

        let skipped = try LibraryBackupLifecycle.createBackupIfDue(
            sourceSupportRoot: fixture.sourceRoot,
            now: firstDate.addingTimeInterval(86_399),
            backupID: UUID())
        XCTAssertEqual(skipped.disposition, .skippedRecentGeneration)
        XCTAssertEqual(
            skipped.generationURL.resolvingSymlinksInPath(),
            first.generationURL.resolvingSymlinksInPath())
        XCTAssertEqual(skipped.receipt, first.receipt)
        XCTAssertEqual(try generationURLs(in: first.backupRoot).count, 1)

        assertMode(first.backupRoot, equals: 0o700)
        assertMode(first.backupRoot.appendingPathComponent("generations"), equals: 0o700)
        assertMode(first.backupRoot.appendingPathComponent("objects"), equals: 0o700)
        assertMode(first.backupRoot.appendingPathComponent("latest-receipt.json"), equals: 0o600)
        assertMode(first.backupRoot.appendingPathComponent(".lifecycle.lock"), equals: 0o600)
        let receiptSize = try Data(contentsOf: first.backupRoot.appendingPathComponent(
            "latest-receipt.json")).count
        XCTAssertLessThanOrEqual(receiptSize, 16 * 1_024)
    }

    /// Retention is a SETTING now, so this proves the mechanism at a retention it states rather
    /// than at whichever default ships. It used to pin 7, and broke the moment the default became a
    /// choice — a test measuring the shipped default when it meant to measure pruning.
    func testKeepsTheChosenNumberOfGenerationsWithoutCollectingObjectPool() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let initialDate = Date(timeIntervalSince1970: 1_787_000_000)
        var result: LibraryBackupLifecycleResult?
        for offset in 0..<8 {
            result = try LibraryBackupLifecycle.createBackupIfDue(
                sourceSupportRoot: fixture.sourceRoot,
                now: initialDate.addingTimeInterval(TimeInterval(offset) * 86_400),
                backupID: UUID(),
                keeping: 7)
            XCTAssertEqual(result?.disposition, .created)
            if offset == 0 {
                let sentinel = try XCTUnwrap(result).backupRoot
                    .appendingPathComponent("objects", isDirectory: true)
                    .appendingPathComponent("unreferenced-pool-sentinel", isDirectory: false)
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: sentinel.path,
                    contents: Data("must survive generation pruning".utf8),
                    attributes: [.posixPermissions: 0o600]))
            }
        }

        let final = try XCTUnwrap(result)
        let generations = try generationURLs(in: final.backupRoot)
        XCTAssertEqual(generations.count, 7)
        XCTAssertFalse(generations.contains { $0.lastPathComponent.contains("1787000000-") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.backupRoot
            .appendingPathComponent("objects", isDirectory: true)
            .appendingPathComponent("unreferenced-pool-sentinel", isDirectory: false).path))
        XCTAssertEqual(final.receipt?.generationName, final.generationURL.lastPathComponent)
    }

    func testRecentGenerationDoesNotSuppressBackupForNewShadowSequence() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let firstDate = Date(timeIntervalSince1970: 1_787_000_000)
        let first = try LibraryBackupLifecycle.createBackupIfDue(
            sourceSupportRoot: fixture.sourceRoot,
            now: firstDate)
        let before = try fixture.store.status()
        XCTAssertEqual(first.receipt?.shadowChangeSequence, before.shadowChangeSequence)

        let changed = try fixture.store.recordSourceIssue(
            domain: .artifactMedia,
            source: ShadowLibrarySourceFingerprint(
                identity: "artifacts/unreadable.json",
                revision: "test-revision",
                digest: String(repeating: "a", count: 64),
                byteCount: 1),
            kind: .malformed,
            diagnostics: "test mutation")
        XCTAssertGreaterThan(changed.shadowChangeSequence, before.shadowChangeSequence)

        let replacement = try LibraryBackupLifecycle.createBackupIfDue(
            sourceSupportRoot: fixture.sourceRoot,
            now: firstDate.addingTimeInterval(1),
            requiring: LibraryBackupFreshnessRequirement(
                databaseInstanceID: changed.databaseInstanceID,
                schemaVersion: changed.schemaVersion,
                shadowChangeSequence: changed.shadowChangeSequence))
        XCTAssertEqual(replacement.disposition, .created)
        XCTAssertEqual(
            replacement.receipt?.shadowChangeSequence,
            changed.shadowChangeSequence)
        XCTAssertEqual(try generationURLs(in: replacement.backupRoot).count, 2)
    }

    func testOversizedReceiptFailsClosedWithoutCreatingAnotherGeneration() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let first = try LibraryBackupLifecycle.createBackupIfDue(
            sourceSupportRoot: fixture.sourceRoot,
            now: now)
        let receipt = first.backupRoot.appendingPathComponent(
            "latest-receipt.json", isDirectory: false)
        try Data(repeating: 0x41, count: 16 * 1_024 + 1).write(to: receipt)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)

        XCTAssertThrowsError(try LibraryBackupLifecycle.createBackupIfDue(
            sourceSupportRoot: fixture.sourceRoot,
            now: now.addingTimeInterval(1))) { error in
            guard case LibraryBackupServiceError.verification = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try generationURLs(in: first.backupRoot).count, 1)
    }

    func testRejectsExposedExistingBackupRoot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let root = LibraryBackupLifecycle.backupRoot(for: fixture.sourceRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)

        XCTAssertThrowsError(try LibraryBackupLifecycle.createBackupIfDue(
            sourceSupportRoot: fixture.sourceRoot)) { error in
            guard case LibraryBackupServiceError.permissions = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    /// `hasVerifiedBackup` is the post-soak reclaim's "there is still a way back" precondition, and
    /// it had exactly one production caller and no test at all. It enumerated the backup root rather
    /// than the `generations` directory the backups are written into, so it found `generations`,
    /// `objects` and the receipt, none of which carry the `generation-` prefix, and answered false
    /// on every machine. The reclaim it guards could never run.
    ///
    /// This asserts it against a backup the lifecycle actually produced, which is the only way the
    /// two halves can be caught disagreeing.
    func testRecognizesABackupItJustWrote() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        XCTAssertFalse(
            LibraryBackupLifecycle.hasVerifiedBackup(for: fixture.sourceRoot),
            "a root with no backup at all has nothing to go back to")

        let result = try LibraryBackupLifecycle.createBackupIfDue(
            sourceSupportRoot: fixture.sourceRoot,
            now: Date(timeIntervalSince1970: 1_787_000_000),
            backupID: UUID())
        XCTAssertEqual(result.disposition, .created)
        XCTAssertTrue(
            LibraryBackupLifecycle.hasVerifiedBackup(for: fixture.sourceRoot),
            "a restore-verified generation named by the receipt must be recognized")

        // Evidence, not presence: the receipt has to name a generation that is still there.
        try FileManager.default.removeItem(at: result.generationURL)
        XCTAssertFalse(
            LibraryBackupLifecycle.hasVerifiedBackup(for: fixture.sourceRoot),
            "a receipt naming a generation that is gone is not a way back")
    }
}

private extension LibraryBackupLifecycleTests {
    struct Fixture {
        let base: URL
        let sourceRoot: URL
        let store: SQLiteLibraryStore
    }

    func makeFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "library-backup-lifecycle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        let sourceRoot = base.appendingPathComponent("Mechanician", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sourceRoot.path)
        return Fixture(
            base: base,
            sourceRoot: sourceRoot,
            store: try SQLiteLibraryStore(supportRoot: sourceRoot))
    }

    func generationURLs(in backupRoot: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: backupRoot.appendingPathComponent("generations", isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.hasPrefix("generation-") }
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
}
