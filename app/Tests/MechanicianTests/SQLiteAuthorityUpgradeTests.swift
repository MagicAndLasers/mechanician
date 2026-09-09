import Foundation
import SQLite3
import XCTest
@testable import Mechanician

/// Opening a REAL, pre-existing, older-version active authority with the current binary.
///
/// Every other storage test in this suite provisions a fresh database at the current
/// `schemaVersion` and exercises it. None of them could fail when schema v7 shipped, because a
/// fresh-provision test and an upgrade test look almost identical and prove completely different
/// things. 2239 of them were green while the app refused to launch on every machine that already
/// had a library.
///
/// So this file does the one thing they do not: it builds an authority at the previous schema
/// version, the way a real installation would have it on disk, and asserts the current binary
/// carries it forward and opens it.
final class SQLiteAuthorityUpgradeTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("authority-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        return root
    }

    private func databaseURL(_ root: URL) -> URL {
        root.appendingPathComponent(StorageAuthorityProtocol.databaseName)
    }

    private func markerURL(_ root: URL) -> URL {
        root.appendingPathComponent(StorageAuthorityProtocol.markerName)
    }

    private func withDatabase<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database = handle else {
            throw NSError(domain: "authority.upgrade.test", code: 1)
        }
        defer { sqlite3_close_v2(handle) }
        return try body(database)
    }

    @discardableResult
    private func execute(_ database: OpaquePointer, _ sql: String) -> Int32 {
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    private func scalar(_ database: OpaquePointer, _ sql: String) -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int64(statement, 0)
    }

    private func text(_ database: OpaquePointer, _ sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: raw)
    }

    // MARK: - Fixture

    /// Provision a current-version active authority, then wind it back to the previous schema so it
    /// is byte-for-byte the shape a real installation running the previous release would have.
    ///
    /// The objects removed here are exactly the ones the newest migration creates. If a future
    /// schema changes that list, this fixture must change with it — and the assertions below will
    /// say so rather than passing on a fiction.
    private func makePreviousVersionAuthority(
        at root: URL
    ) throws -> (marker: StorageAuthorityMarker, previousVersion: Int) {
        let current = SQLiteLibraryStore.schemaVersion
        let previous = current - 1
        let provisioned = try SQLiteLibraryBootstrapService.provisionIfNeeded(
            recognition: StorageAuthorityRecognizer.inspect(supportRoot: root),
            ownsProcessLease: true,
            now: { Date(timeIntervalSinceReferenceDate: 0) })
        guard case .sqlite(let marker, _) = provisioned.disposition else {
            throw NSError(domain: "authority.upgrade.test", code: 2)
        }

        _ = try windBackToPreviousVersion(at: root)
        let older = StorageAuthorityMarker(
            mode: .sqlite,
            activationID: marker.activationID,
            databaseInstanceID: marker.databaseInstanceID,
            schemaVersion: previous,
            minimumWriterBuild: marker.minimumWriterBuild,
            createdAt: marker.createdAt)
        return (older, previous)
    }

    /// What the NEWEST migration changes, as the statements that put a current-version database
    /// back into the previous version's shape.
    ///
    /// v15 is additive. Drop the child before the parent so this is the exact v14 shape a real
    /// installed library has. The probes below keep this list loud on every later schema bump.
    private static var windBackToPreviousShapeStatements: String {
        """
        DROP TABLE IF EXISTS conversation_file_observations;
        DROP TABLE IF EXISTS conversation_repository_observations;
        """
    }

    /// One probe per authority table v15 adds. The older schema must have none; the upgraded schema
    /// must have all of them. A fixture that produced neither shape cannot pass both readings.
    private static let newestSchemaShapeProbes: [(label: String, sql: String)] = [
        (
            "Conversation repository observations",
            """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'table' AND name = 'conversation_repository_observations'
            """
        ),
        (
            "Conversation file observations",
            """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'table' AND name = 'conversation_file_observations'
            """
        ),
    ]

    /// Remove exactly what the newest migration added, so the root holds the shape a real
    /// installation running the previous release would have — database AND marker.
    @discardableResult
    private func windBackToPreviousVersion(at root: URL) throws -> Int {
        let current = SQLiteLibraryStore.schemaVersion
        let previous = current - 1
        // A freshly provisioned root has to be wound back. A real installed v14 library already
        // lacks these objects, so there is nothing to remove.
        let alreadyPrevious = try withDatabase(databaseURL(root)) { database in
            Self.newestSchemaShapeProbes.allSatisfy { scalar(database, $0.sql) == 0 }
        }
        try withDatabase(databaseURL(root)) { database in
            XCTAssertEqual(execute(database, """
                \(alreadyPrevious ? "" : Self.windBackToPreviousShapeStatements)
                -- The receipt for the step that PRODUCED the current version. Migration ids trail
                -- schema versions by one: the v7 step records migration_id 6.
                DELETE FROM schema_migrations WHERE migration_id = \(current - 1);
                UPDATE library_metadata SET schema_version = \(previous) WHERE singleton = 1;
                PRAGMA user_version = \(previous);
                """), SQLITE_OK)
        }
        // The marker records the version too, and a real older installation's marker says so.
        let existing = try JSONDecoder().decode(
            StorageAuthorityMarker.self, from: try Data(contentsOf: markerURL(root)))
        try StorageAuthorityMarkerStore.publish(
            StorageAuthorityMarker(
                mode: .sqlite,
                activationID: existing.activationID,
                databaseInstanceID: existing.databaseInstanceID,
                schemaVersion: previous,
                minimumWriterBuild: existing.minimumWriterBuild,
                createdAt: existing.createdAt),
            in: root)
        return previous
    }

    func testTheUpgradeCreatesTheNewestSchemaObjects() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, previous) = try makePreviousVersionAuthority(at: root)
        XCTAssertEqual(previous, 14, "this fixture must exercise the real v14 to v15 step")

        try withDatabase(databaseURL(root)) { database in
            for probe in Self.newestSchemaShapeProbes {
                XCTAssertEqual(
                    scalar(database, probe.sql), 0,
                    "fixture precondition: the older schema must genuinely lack — \(probe.label)")
            }
        }

        let result = SQLiteLibraryAuthorityUpgrade.upgradeIfNeeded(
            supportRoot: root, ownsProcessLease: true)
        XCTAssertEqual(
            result.outcome,
            .upgraded(from: previous, to: SQLiteLibraryStore.schemaVersion))

        try withDatabase(databaseURL(root)) { database in
            for probe in Self.newestSchemaShapeProbes {
                XCTAssertEqual(
                    scalar(database, probe.sql), 1,
                    "the upgrade did not create — \(probe.label)")
            }
            // The destructive v14 rung remains permanent history and must stay effective while
            // v15 adds its new authority tables.
            for name in SQLiteLibraryStore.retiredAuthorityTables {
                XCTAssertEqual(
                    scalar(database, """
                        SELECT COUNT(*) FROM sqlite_master
                        WHERE type = 'table' AND name = '\(name)'
                        """), 0, "\(name) survived the upgrade")
            }
            // The thirteen on `conversations`, `conversation_events` and `workspaces` are the ones
            // that matter: one left behind means the next ordinary write to a surviving table tries
            // to bump a table that is gone, and fails.
            for name in SQLiteLibraryStore.retiredAuthorityTriggers {
                XCTAssertEqual(
                    scalar(database, """
                        SELECT COUNT(*) FROM sqlite_master
                        WHERE type = 'trigger' AND name = '\(name)'
                        """), 0, "\(name) survived the upgrade")
            }
            // What must NOT have gone with them.
            XCTAssertEqual(
                scalar(database, """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE type = 'trigger' AND name LIKE 'conversation_projection_%'
                    """), 3, "the projection outbox triggers are not memory's")
        }

        // And the library still opens and still has its conversations.
        let repository = try XCTUnwrap(
            LibraryAuthorityRepository.open(recognition: result.recognition),
            "the library must open after the migration")
        _ = try repository.launchInventory()
    }

    func testAnOrdinaryWriteStillSucceedsAfterTheMigration() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, previous) = try makePreviousVersionAuthority(at: root)
        let result = SQLiteLibraryAuthorityUpgrade.upgradeIfNeeded(
            supportRoot: root, ownsProcessLease: true)
        XCTAssertEqual(
            result.outcome,
            .upgraded(from: previous, to: SQLiteLibraryStore.schemaVersion))

        try withDatabase(databaseURL(root)) { database in
            XCTAssertEqual(execute(database, """
                UPDATE workspaces SET updated_at = updated_at + 1;
                UPDATE conversations SET updated_at = updated_at + 1;
                """), SQLITE_OK,
                "a memory trigger left on a surviving table fails the next ordinary write")
        }
    }

    // MARK: - The test that would have caught the brick

    func testCurrentBinaryCarriesAPreviousVersionActiveLibraryForwardAndOpensIt() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (older, previous) = try makePreviousVersionAuthority(at: root)

        // Precondition: this really is an older active authority, and the OLD gate would refuse it.
        XCTAssertEqual(older.schemaVersion, previous)
        XCTAssertThrowsError(
            try SQLiteLibraryStore.openActiveAuthority(supportRoot: root, marker: older),
            "an older active authority must not open directly; if it does, this test proves nothing")

        let result = SQLiteLibraryAuthorityUpgrade.upgradeIfNeeded(
            supportRoot: root,
            ownsProcessLease: true,
            now: { Date(timeIntervalSinceReferenceDate: 500) })

        XCTAssertEqual(
            result.outcome,
            .upgraded(from: previous, to: SQLiteLibraryStore.schemaVersion))

        guard case .sqlite(let marker, let probe) = result.recognition.disposition else {
            return XCTFail("expected SQLite authority after upgrade, got \(result.recognition.disposition)")
        }
        XCTAssertEqual(probe.authorityState, .active)
        XCTAssertEqual(probe.schemaVersion, SQLiteLibraryStore.schemaVersion)
        XCTAssertEqual(marker.schemaVersion, SQLiteLibraryStore.schemaVersion)
        // Same authority, not a new one: a fresh identity here would look like a replaced library.
        XCTAssertEqual(marker.activationID, older.activationID)
        XCTAssertEqual(marker.databaseInstanceID, older.databaseInstanceID)
        XCTAssertEqual(probe.databaseInstanceID, older.databaseInstanceID)

        // The actual claim: the product opens. This is what Storage Recovery replaced.
        let repository = try XCTUnwrap(LibraryAuthorityRepository.open(recognition: result.recognition))
        let inventory = try repository.launchInventory()
        XCTAssertEqual(inventory.databaseInstanceID, older.databaseInstanceID)

        // And the exact predicate launch uses to choose between the product and the recovery
        // screen. `evaluate` is what turned the version mismatch into `.blocked` on 2026-08-14, so
        // asserting on it is as close to "the app starts" as a test without a GUI gets.
        let preflighted = SQLiteAuthorityRepositoryPreflight.evaluate(result.recognition) {
            try LibraryAuthorityRepository.open(recognition: $0) != nil
        }
        XCTAssertFalse(preflighted.disposition.isBlocked,
                       "launch would still land on Storage Recovery")
        XCTAssertTrue(preflighted.disposition.allowsNormalProduct)
        XCTAssertNil(preflighted.disposition.blockingMessage)
    }

    /// The additive rung's direction, asserted both ways round.
    func testTheUpgradeAddsTheObjectsTheOlderSchemaLacked() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makePreviousVersionAuthority(at: root)

        try withDatabase(databaseURL(root)) { database in
            for probe in Self.newestSchemaShapeProbes {
                XCTAssertEqual(
                    scalar(database, probe.sql), 0,
                    "fixture precondition: the older schema must genuinely lack — \(probe.label)")
            }
        }

        let result = SQLiteLibraryAuthorityUpgrade.upgradeIfNeeded(
            supportRoot: root, ownsProcessLease: true)
        XCTAssertEqual(
            result.outcome, .upgraded(from: SQLiteLibraryStore.schemaVersion - 1,
                                      to: SQLiteLibraryStore.schemaVersion))

        try withDatabase(databaseURL(root)) { database in
            for probe in Self.newestSchemaShapeProbes {
                XCTAssertEqual(
                    scalar(database, probe.sql), 1,
                    "the upgrade did not create — \(probe.label)")
            }
            XCTAssertEqual(scalar(database, "PRAGMA user_version"),
                           Int64(SQLiteLibraryStore.schemaVersion))
        }
    }

    func testTheSupersededLibraryIsRetainedRatherThanDeleted() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, previous) = try makePreviousVersionAuthority(at: root)

        _ = SQLiteLibraryAuthorityUpgrade.upgradeIfNeeded(
            supportRoot: root,
            ownsProcessLease: true,
            now: { Date(timeIntervalSinceReferenceDate: 0) })

        // The journals move with their database, so `-wal`/`-shm` may sit beside it; the database
        // itself is the thing that must be there.
        let retained = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.contains(".superseded-v\(previous)-") }
            .filter { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
        XCTAssertEqual(retained.count, 1,
                       "the pre-upgrade library must survive as evidence, not be deleted")
        // And nothing half-finished is left behind.
        let working = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.contains(".upgrade-") }
        XCTAssertTrue(working.isEmpty, "a working copy was left in the support root")
    }

    // MARK: - Idempotence and refusal

    func testACurrentVersionLibraryIsLeftCompletelyAlone() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try SQLiteLibraryBootstrapService.provisionIfNeeded(
            recognition: StorageAuthorityRecognizer.inspect(supportRoot: root),
            ownsProcessLease: true)

        let before = try Data(contentsOf: markerURL(root))
        let result = SQLiteLibraryAuthorityUpgrade.upgradeIfNeeded(
            supportRoot: root, ownsProcessLease: true)

        XCTAssertEqual(result.outcome, .notNeeded)
        XCTAssertEqual(try Data(contentsOf: markerURL(root)), before,
                       "an up-to-date library must not be republished on every launch")
        XCTAssertTrue(try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.contains(".superseded-") || $0.contains(".upgrade-") }
            .isEmpty)
    }

    func testUpgradingTwiceIsIdempotent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makePreviousVersionAuthority(at: root)

        let first = SQLiteLibraryAuthorityUpgrade.upgradeIfNeeded(
            supportRoot: root, ownsProcessLease: true)
        XCTAssertEqual(first.outcome,
                       .upgraded(from: SQLiteLibraryStore.schemaVersion - 1,
                                 to: SQLiteLibraryStore.schemaVersion))
        let second = SQLiteLibraryAuthorityUpgrade.upgradeIfNeeded(
            supportRoot: root, ownsProcessLease: true)
        XCTAssertEqual(second.outcome, .notNeeded)
    }

    func testALibraryFromANewerBuildIsRefusedWithAnExplanationRatherThanMigrated() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provisioned = try SQLiteLibraryBootstrapService.provisionIfNeeded(
            recognition: StorageAuthorityRecognizer.inspect(supportRoot: root),
            ownsProcessLease: true)
        guard case .sqlite(let marker, _) = provisioned.disposition else {
            return XCTFail("expected a provisioned authority")
        }

        let future = SQLiteLibraryStore.schemaVersion + 1
        try withDatabase(databaseURL(root)) { database in
            XCTAssertEqual(execute(database, """
                UPDATE library_metadata SET schema_version = \(future) WHERE singleton = 1;
                PRAGMA user_version = \(future);
                """), SQLITE_OK)
        }
        try StorageAuthorityMarkerStore.publish(
            StorageAuthorityMarker(
                mode: .sqlite,
                activationID: marker.activationID,
                databaseInstanceID: marker.databaseInstanceID,
                schemaVersion: future,
                minimumWriterBuild: marker.minimumWriterBuild,
                createdAt: marker.createdAt),
            in: root)

        let result = SQLiteLibraryAuthorityUpgrade.upgradeIfNeeded(
            supportRoot: root, ownsProcessLease: true)
        guard case .unsupported(let message) = result.outcome else {
            return XCTFail("a newer library must be refused, got \(result.outcome)")
        }
        XCTAssertTrue(message.contains("newer version"), message)
        // Refusing must not have touched it.
        try withDatabase(databaseURL(root)) { database in
            XCTAssertEqual(scalar(database, "PRAGMA user_version"), Int64(future))
        }
    }

    func testWithoutTheProcessLeaseNothingIsTouched() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makePreviousVersionAuthority(at: root)

        let result = SQLiteLibraryAuthorityUpgrade.upgradeIfNeeded(
            supportRoot: root, ownsProcessLease: false)

        XCTAssertEqual(result.outcome, .notNeeded)
        try withDatabase(databaseURL(root)) { database in
            XCTAssertEqual(scalar(database, "PRAGMA user_version"),
                           Int64(SQLiteLibraryStore.schemaVersion - 1),
                           "an upgrade must never run without the writer lease")
        }
    }

    // MARK: - The interruption window

    func testAnUpgradeInterruptedBeforeTheMarkerWasRepublishedIsFinished() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (older, previous) = try makePreviousVersionAuthority(at: root)

        // Reproduce the only reachable intermediate state: the database was swapped in at the new
        // version, and the process died before the marker was rewritten.
        let result = SQLiteLibraryAuthorityUpgrade.upgradeIfNeeded(
            supportRoot: root, ownsProcessLease: true)
        XCTAssertEqual(result.outcome, .upgraded(from: previous, to: SQLiteLibraryStore.schemaVersion))
        try StorageAuthorityMarkerStore.publish(older, in: root)

        // That state must be recognized as an unfinished upgrade, not as corruption.
        guard case .republishMarker = StorageAuthorityRecognizer.assessUpgrade(supportRoot: root) else {
            return XCTFail("a stale marker over an upgraded database must be recognized as resumable")
        }

        let resumed = SQLiteLibraryAuthorityUpgrade.upgradeIfNeeded(
            supportRoot: root, ownsProcessLease: true)
        XCTAssertEqual(
            resumed.outcome,
            .markerRepublished(from: previous, to: SQLiteLibraryStore.schemaVersion))
        guard case .sqlite(let marker, let probe) = resumed.recognition.disposition else {
            return XCTFail("expected SQLite authority, got \(resumed.recognition.disposition)")
        }
        XCTAssertEqual(marker.schemaVersion, SQLiteLibraryStore.schemaVersion)
        XCTAssertEqual(probe.authorityState, .active)
        XCTAssertNotNil(try LibraryAuthorityRepository.open(recognition: resumed.recognition))
    }

    // MARK: - Rehearsal against a real library

    /// Opt-in, because it needs a real installed library and copies it.
    ///
    ///     MECHANICIAN_REAL_LIBRARY_REHEARSAL=1 swift test --arch arm64 \
    ///       --filter testARealInstalledLibraryIsCarriedForwardWithItsContentsIntact
    ///
    /// Deliberately not in `check.sh`: it depends on a machine's own data. It exists because the
    /// synthetic fixtures above prove the mechanism on an empty authority, and the thing that
    /// actually broke was a 786 MB library with real content in it.
    func testARealInstalledLibraryIsCarriedForwardWithItsContentsIntact() throws {
        guard ProcessInfo.processInfo.environment["MECHANICIAN_REAL_LIBRARY_REHEARSAL"] == "1" else {
            throw XCTSkip("set MECHANICIAN_REAL_LIBRARY_REHEARSAL=1 to rehearse against a real library")
        }
        let live = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Mechanician")
        let liveDatabase = live.appendingPathComponent(StorageAuthorityProtocol.databaseName)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: liveDatabase.path),
            "no installed library to rehearse against")

        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // The live corpus is only ever read, and only through SQLite's backup API.
        try LibraryBackupService.copyDatabase(source: liveDatabase, destination: databaseURL(root))
        try FileManager.default.copyItem(
            at: live.appendingPathComponent(StorageAuthorityProtocol.markerName),
            to: markerURL(root))

        let (conversationRowsBefore, workspaceRowsBefore) = try withDatabase(databaseURL(root)) { database in
            (scalar(database, "SELECT COUNT(*) FROM conversations"),
             scalar(database, "SELECT COUNT(*) FROM workspaces"))
        }
        XCTAssertGreaterThan(conversationRowsBefore, 0, "the rehearsal needs a library with content")

        let instanceBefore = try withDatabase(databaseURL(root)) { database in
            text(database, "SELECT database_instance_id FROM library_metadata WHERE singleton = 1")
        }

        // The baseline is raw SQL, not the launch inventory, and it has to be: an installed library
        // sits at the PREVIOUS schema version, and this binary's active opener refuses that by
        // design. Reading the inventory first would need the very upgrade under test to have
        // already happened.
        let previous = try windBackToPreviousVersion(at: root)
        let result = SQLiteLibraryAuthorityUpgrade.upgradeIfNeeded(
            supportRoot: root, ownsProcessLease: true)
        XCTAssertEqual(
            result.outcome, .upgraded(from: previous, to: SQLiteLibraryStore.schemaVersion))

        let repository = try XCTUnwrap(
            LibraryAuthorityRepository.open(recognition: result.recognition),
            "a real library must open after being carried forward")
        let inventory = try repository.launchInventory()
        XCTAssertGreaterThan(
            inventory.conversations.count + inventory.intrinsicConversations.count, 0,
            "the upgraded library must still present its conversations")

        try withDatabase(databaseURL(root)) { database in
            // Nothing the migration did may add, drop, or renumber a row.
            XCTAssertEqual(scalar(database, "SELECT COUNT(*) FROM conversations"), conversationRowsBefore)
            XCTAssertEqual(scalar(database, "SELECT COUNT(*) FROM workspaces"), workspaceRowsBefore)
            XCTAssertEqual(
                text(database, "SELECT database_instance_id FROM library_metadata WHERE singleton = 1"),
                instanceBefore,
                "the upgraded library must still be the same authority")
            // And the new schema is genuinely present, not merely stamped.
            for probe in Self.newestSchemaShapeProbes {
                XCTAssertEqual(
                    scalar(database, probe.sql), 1,
                    "missing after a real-library upgrade — \(probe.label)")
            }
        }

        // The decision launch actually makes. `evaluate` is what turned the version mismatch into
        // `.blocked` and put a real 786 MB library on the Storage Recovery screen, so running it
        // here against that same library is the closest safe equivalent to launching the app.
        let preflighted = SQLiteAuthorityRepositoryPreflight.evaluate(result.recognition) {
            try LibraryAuthorityRepository.open(recognition: $0) != nil
        }
        XCTAssertFalse(preflighted.disposition.isBlocked, "a real library would still show Storage Recovery")
        XCTAssertTrue(preflighted.disposition.allowsNormalProduct)
        XCTAssertNil(preflighted.disposition.blockingMessage)
    }

    // MARK: - The ladder itself

    func testEverySchemaVersionThisBuildClaimsToUpgradeHasALadderStep() throws {
        // The next schema bump's failure mode is forgetting the ladder step. `upgradeCopiedActiveAuthority`
        // refuses a version it has no step for, so walking the claimed range here turns that
        // omission into a test failure instead of a brick.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try SQLiteLibraryBootstrapService.provisionIfNeeded(
            recognition: StorageAuthorityRecognizer.inspect(supportRoot: root),
            ownsProcessLease: true)

        for version in SQLiteLibraryStore.lowestUpgradableSchemaVersion
            ..< SQLiteLibraryStore.schemaVersion {
            let copy = root.appendingPathComponent("ladder-\(version).db")
            try? FileManager.default.removeItem(at: copy)
            try LibraryBackupService.copyDatabase(source: databaseURL(root), destination: copy)
            defer { try? FileManager.default.removeItem(at: copy) }

            var probe: StorageAuthorityDatabaseProbe?
            try withDatabase(copy) { database in
                XCTAssertEqual(execute(database, "PRAGMA user_version = \(version)"), SQLITE_OK)
                probe = StorageAuthorityDatabaseProbe(
                    databaseInstanceID: UUID(), schemaVersion: version,
                    authorityState: .active, activationID: UUID(), rollbackID: nil,
                    minimumWriterBuild: StorageAuthorityProtocol.recognitionID,
                    committedSequence: 0)
            }
            // The identity check fails first (the probe is synthetic), which is fine: what must NOT
            // happen is a "no migration step from schema vN" refusal, and that is what we assert.
            XCTAssertThrowsError(
                try SQLiteLibraryStore.upgradeCopiedActiveAuthority(
                    at: copy, expecting: try XCTUnwrap(probe))
            ) { error in
                XCTAssertFalse(
                    "\(error)".contains("no migration step"),
                    "schema v\(version) has no ladder step; a library at that version cannot launch")
            }
        }
    }
}
