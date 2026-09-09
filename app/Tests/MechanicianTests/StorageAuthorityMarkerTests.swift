import Foundation
import XCTest
@testable import Mechanician

final class StorageAuthorityMarkerTests: XCTestCase {
    func testNoMarkerAndNoDatabaseUsesLegacyAuthority() throws {
        let fixture = try makeEmptyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        let recognition = StorageAuthorityRecognizer.inspect(supportRoot: fixture.root)

        XCTAssertEqual(recognition.marker, .absent)
        guard case .legacyUnmarked(let database) = recognition.disposition else {
            return XCTFail("expected unmarked Legacy authority, got \(recognition.disposition)")
        }
        XCTAssertNil(database)
        XCTAssertEqual(recognition.effectiveSupportRoot, fixture.root)
    }

    func testMissingOrCorruptMarkerUsesLegacyOnlyForShadowDatabase() throws {
        let fixture = try makeDatabaseFixture(state: .shadow)
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        var recognition = StorageAuthorityRecognizer.inspect(supportRoot: fixture.root)
        XCTAssertEqual(recognition.marker, .absent)
        assertLegacyUnmarked(recognition, databaseState: .shadow)

        try writeMarkerBytes(Data("not-json".utf8), in: fixture.root)
        recognition = StorageAuthorityRecognizer.inspect(supportRoot: fixture.root)
        guard case .invalid = recognition.marker else {
            return XCTFail("expected invalid marker observation")
        }
        assertLegacyUnmarked(recognition, databaseState: .shadow)
    }

    func testMissingMarkerFencesLegacyForResumablePreparedAndActiveStates() throws {
        for state in [LibraryAuthorityState.prepared, .active] {
            let fixture = try makeDatabaseFixture(state: state)
            defer { try? FileManager.default.removeItem(at: fixture.base) }

            assertInterruptedUnmarked(
                StorageAuthorityRecognizer.inspect(supportRoot: fixture.root),
                databaseState: state)

            try writeMarkerBytes(Data("not-json".utf8), in: fixture.root)
            let recognition = StorageAuthorityRecognizer.inspect(supportRoot: fixture.root)
            guard case .invalid = recognition.marker else {
                return XCTFail("expected invalid marker observation for \(state)")
            }
            assertBlocked(recognition)
        }
    }

    func testMissingOrCorruptMarkerBlocksRollbackDatabaseStates() throws {
        for state in [LibraryAuthorityState.rollbackPrepared, .rolledBack] {
            let fixture = try makeDatabaseFixture(state: state)
            defer { try? FileManager.default.removeItem(at: fixture.base) }

            assertBlocked(StorageAuthorityRecognizer.inspect(supportRoot: fixture.root))

            try writeMarkerBytes(Data("not-json".utf8), in: fixture.root)
            let recognition = StorageAuthorityRecognizer.inspect(supportRoot: fixture.root)
            guard case .invalid = recognition.marker else {
                return XCTFail("expected invalid marker observation for \(state)")
            }
            assertBlocked(recognition)
        }
    }

    func testCorruptMarkerWithoutDatabaseFailsClosed() throws {
        let fixture = try makeEmptyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        try writeMarkerBytes(Data("not-json".utf8), in: fixture.root)

        let recognition = StorageAuthorityRecognizer.inspect(supportRoot: fixture.root)

        guard case .invalid = recognition.marker else {
            return XCTFail("expected invalid marker observation")
        }
        assertBlocked(recognition)
    }

    func testUnreadableDatabaseCannotBeExcusedByShadowResetMarker() throws {
        let fixture = try makeDatabaseFixture(state: .shadow)
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let resetMarker = fixture.root.appendingPathComponent(
            StorageAuthorityProtocol.resetMarkerName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resetMarker.path))

        try replaceDatabaseWithGarbage(in: fixture.root)

        let recognition = StorageAuthorityRecognizer.inspect(supportRoot: fixture.root)

        XCTAssertEqual(recognition.marker, .absent)
        assertBlocked(recognition)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: resetMarker.path),
            "recognition must preserve reset evidence while failing closed")
    }

    func testMatchingSQLiteMarkerRecognizesPreparedActiveAndRollbackPreparedStates() throws {
        for state in [
            LibraryAuthorityState.prepared,
            .active,
            .rollbackPrepared,
        ] {
            let fixture = try makeDatabaseFixture(state: state)
            defer { try? FileManager.default.removeItem(at: fixture.base) }
            let marker = try sqliteMarker(for: fixture)
            try StorageAuthorityMarkerStore.publish(marker, in: fixture.root)

            let recognition = StorageAuthorityRecognizer.inspect(supportRoot: fixture.root)

            XCTAssertEqual(recognition.marker, .valid(marker))
            guard case .sqlite(let recognized, let database) = recognition.disposition else {
                return XCTFail("expected SQLite recognition for \(state)")
            }
            XCTAssertEqual(recognized, marker)
            XCTAssertEqual(database.authorityState, state)
            XCTAssertFalse(recognition.disposition.allowsLegacyWriters)
            XCTAssertEqual(
                recognition.disposition.allowsNormalProduct,
                state == .active,
                "only a marker naming an active database may enter the normal product")
        }
    }

    func testActiveMarkerOpensTheSingleSQLiteAuthorityRepository() throws {
        let fixture = try makeDatabaseFixture(state: .active)
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let marker = try sqliteMarker(for: fixture)
        try StorageAuthorityMarkerStore.publish(marker, in: fixture.root)
        let recognition = StorageAuthorityRecognizer.inspect(supportRoot: fixture.root)

        let repository = try XCTUnwrap(LibraryAuthorityRepository.open(recognition: recognition))

        XCTAssertEqual(repository.activationID, marker.activationID)
        XCTAssertEqual(repository.databaseInstanceID, marker.databaseInstanceID)
    }

    func testSQLiteMarkerRejectsMissingMismatchedAndRolledBackDatabase() throws {
        do {
            let fixture = try makeEmptyFixture()
            defer { try? FileManager.default.removeItem(at: fixture.base) }
            try StorageAuthorityMarkerStore.publish(
                StorageAuthorityMarker(
                    mode: .sqlite,
                    activationID: UUID(),
                    databaseInstanceID: UUID(),
                    createdAt: Self.timestamp),
                in: fixture.root)
            assertBlocked(StorageAuthorityRecognizer.inspect(supportRoot: fixture.root))
        }

        do {
            let fixture = try makeDatabaseFixture(state: .active)
            defer { try? FileManager.default.removeItem(at: fixture.base) }
            let metadata = try XCTUnwrap(fixture.metadata)
            let mismatched = StorageAuthorityMarker(
                mode: .sqlite,
                activationID: try XCTUnwrap(fixture.activationID),
                databaseInstanceID: UUID(),
                schemaVersion: metadata.schemaVersion,
                createdAt: Self.timestamp)
            try StorageAuthorityMarkerStore.publish(mismatched, in: fixture.root)
            assertBlocked(StorageAuthorityRecognizer.inspect(supportRoot: fixture.root))
        }

        do {
            let fixture = try makeDatabaseFixture(state: .rolledBack)
            defer { try? FileManager.default.removeItem(at: fixture.base) }
            try StorageAuthorityMarkerStore.publish(
                try sqliteMarker(for: fixture), in: fixture.root)
            assertBlocked(StorageAuthorityRecognizer.inspect(supportRoot: fixture.root))
        }
    }

    func testLegacyMarkerRequiresMatchingRollbackStateIDAndGeneration() throws {
        for state in [LibraryAuthorityState.rollbackPrepared, .rolledBack] {
            let fixture = try makeDatabaseFixture(state: state)
            defer { try? FileManager.default.removeItem(at: fixture.base) }
            let generation = try makeGeneration(beside: fixture.root)
            let marker = try legacyMarker(for: fixture, generation: generation)
            try StorageAuthorityMarkerStore.publish(marker, in: fixture.root)

            let recognition = StorageAuthorityRecognizer.inspect(supportRoot: fixture.root)

            XCTAssertEqual(recognition.marker, .valid(marker))
            guard case .legacyGeneration(let recognized, let root) = recognition.disposition else {
                return XCTFail("expected matching rollback Legacy generation for \(state)")
            }
            XCTAssertEqual(recognized, marker)
            XCTAssertEqual(root, generation)
            XCTAssertEqual(recognition.effectiveSupportRoot, generation)
            XCTAssertTrue(recognition.disposition.allowsLegacyWriters)
        }
    }

    func testLegacyMarkerRejectsActiveDatabaseWrongRollbackIDAndMissingGeneration() throws {
        do {
            let fixture = try makeDatabaseFixture(state: .active)
            defer { try? FileManager.default.removeItem(at: fixture.base) }
            let generation = try makeGeneration(beside: fixture.root)
            let metadata = try XCTUnwrap(fixture.metadata)
            let marker = StorageAuthorityMarker(
                mode: .legacy,
                activationID: try XCTUnwrap(fixture.activationID),
                databaseInstanceID: metadata.databaseInstanceID,
                generationName: generation.lastPathComponent,
                rollbackID: UUID(),
                schemaVersion: metadata.schemaVersion,
                createdAt: Self.timestamp)
            try StorageAuthorityMarkerStore.publish(marker, in: fixture.root)
            assertBlocked(StorageAuthorityRecognizer.inspect(supportRoot: fixture.root))
        }

        do {
            let fixture = try makeDatabaseFixture(state: .rollbackPrepared)
            defer { try? FileManager.default.removeItem(at: fixture.base) }
            let generation = try makeGeneration(beside: fixture.root)
            var marker = try legacyMarker(for: fixture, generation: generation)
            marker = StorageAuthorityMarker(
                mode: .legacy,
                activationID: marker.activationID,
                databaseInstanceID: marker.databaseInstanceID,
                generationName: marker.generationName,
                rollbackID: UUID(),
                schemaVersion: marker.schemaVersion,
                createdAt: marker.createdAt)
            try StorageAuthorityMarkerStore.publish(marker, in: fixture.root)
            assertBlocked(StorageAuthorityRecognizer.inspect(supportRoot: fixture.root))
        }

        do {
            let fixture = try makeDatabaseFixture(state: .rolledBack)
            defer { try? FileManager.default.removeItem(at: fixture.base) }
            let missing = fixture.base.appendingPathComponent(
                "missing-generation-\(UUID().uuidString)", isDirectory: true)
            let marker = try legacyMarker(for: fixture, generation: missing)
            try StorageAuthorityMarkerStore.publish(marker, in: fixture.root)
            assertBlocked(StorageAuthorityRecognizer.inspect(supportRoot: fixture.root))
        }

        do {
            let fixture = try makeDatabaseFixture(state: .rolledBack)
            defer { try? FileManager.default.removeItem(at: fixture.base) }
            let marker = try legacyMarker(for: fixture, generation: fixture.root)
            try StorageAuthorityMarkerStore.publish(marker, in: fixture.root)
            assertBlocked(
                StorageAuthorityRecognizer.inspect(supportRoot: fixture.root),
                file: #filePath,
                line: #line)
        }
    }

    func testMarkerPublicationAtomicallyRoundTripsAndReplaces() throws {
        let fixture = try makeDatabaseFixture(state: .prepared)
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let first = try sqliteMarker(for: fixture, createdAt: Self.timestamp)
        try StorageAuthorityMarkerStore.publish(first, in: fixture.root)

        let markerURL = fixture.root.appendingPathComponent(StorageAuthorityProtocol.markerName)
        assertMode(markerURL, equals: 0o600)
        XCTAssertEqual(
            try JSONDecoder().decode(
                StorageAuthorityMarker.self, from: Data(contentsOf: markerURL)),
            first)
        XCTAssertEqual(
            StorageAuthorityRecognizer.inspect(supportRoot: fixture.root).marker,
            .valid(first))

        let replacement = try sqliteMarker(
            for: fixture, createdAt: "2026-08-05T12:00:01Z")
        try StorageAuthorityMarkerStore.publish(replacement, in: fixture.root)

        XCTAssertEqual(
            try JSONDecoder().decode(
                StorageAuthorityMarker.self, from: Data(contentsOf: markerURL)),
            replacement)
        XCTAssertEqual(
            StorageAuthorityRecognizer.inspect(supportRoot: fixture.root).marker,
            .valid(replacement))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .contains { $0.hasPrefix(".storage-authority.json.") && $0.hasSuffix(".tmp") })
    }

    func testMarkerPublisherRejectsInvalidFieldsWithoutReplacingCurrentMarker() throws {
        let fixture = try makeDatabaseFixture(state: .prepared)
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let valid = try sqliteMarker(for: fixture)
        try StorageAuthorityMarkerStore.publish(valid, in: fixture.root)
        let markerURL = fixture.root.appendingPathComponent(StorageAuthorityProtocol.markerName)
        let original = try Data(contentsOf: markerURL)
        let invalid = StorageAuthorityMarker(
            mode: .legacy,
            activationID: valid.activationID,
            databaseInstanceID: valid.databaseInstanceID,
            schemaVersion: valid.schemaVersion,
            minimumWriterBuild: valid.minimumWriterBuild,
            createdAt: "not-a-timestamp")

        XCTAssertThrowsError(try StorageAuthorityMarkerStore.publish(invalid, in: fixture.root)) {
            error in
            guard case StorageAuthorityRecognitionError.publication = error else {
                return XCTFail("unexpected invalid-marker publication error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: markerURL), original)
        XCTAssertEqual(
            StorageAuthorityRecognizer.inspect(supportRoot: fixture.root).marker,
            .valid(valid))
    }

    func testMarkerPublisherRejectsAContradictoryShadowResetReceipt() throws {
        let fixture = try makeDatabaseFixture(state: .prepared)
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let resetReceipt = fixture.root.appendingPathComponent(
            StorageAuthorityProtocol.resetMarkerName)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: resetReceipt.path,
            contents: Data("{}".utf8),
            attributes: [.posixPermissions: NSNumber(value: 0o600)]))

        XCTAssertThrowsError(
            try StorageAuthorityMarkerStore.publish(
                try sqliteMarker(for: fixture), in: fixture.root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(
            StorageAuthorityProtocol.markerName).path))
    }

    func testMarkerReaderRejectsMalformedExposedOversizedAndSymlinkFiles() throws {
        let cases: [(String, (Fixture) throws -> Void)] = [
            ("malformed", { fixture in
                try self.writeMarkerBytes(Data("not-json".utf8), in: fixture.root)
            }),
            ("exposed", { fixture in
                try self.writeMarkerBytes(Data("{}".utf8), in: fixture.root, mode: 0o644)
            }),
            ("oversized", { fixture in
                try self.writeMarkerBytes(
                    Data(repeating: 0x41, count: StorageAuthorityProtocol.maximumMarkerBytes + 1),
                    in: fixture.root)
            }),
            ("symlink", { fixture in
                let target = fixture.base.appendingPathComponent("marker-target.json")
                try Data("{}".utf8).write(to: target)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: target.path)
                try FileManager.default.createSymbolicLink(
                    at: fixture.root.appendingPathComponent(StorageAuthorityProtocol.markerName),
                    withDestinationURL: target)
            }),
            ("dangling-symlink", { fixture in
                try FileManager.default.createSymbolicLink(
                    at: fixture.root.appendingPathComponent(StorageAuthorityProtocol.markerName),
                    withDestinationURL: fixture.base.appendingPathComponent("missing-marker"))
            }),
        ]

        for (name, arrange) in cases {
            let fixture = try makeEmptyFixture()
            defer { try? FileManager.default.removeItem(at: fixture.base) }
            try arrange(fixture)

            let recognition = StorageAuthorityRecognizer.inspect(supportRoot: fixture.root)

            guard case .invalid = recognition.marker else {
                return XCTFail("expected \(name) marker to be invalid")
            }
            assertBlocked(recognition)
        }
    }

    func testMarkerAndDatabaseHardLinksFailStrictValidation() throws {
        do {
            let fixture = try makeDatabaseFixture(state: .prepared)
            defer { try? FileManager.default.removeItem(at: fixture.base) }
            let marker = try sqliteMarker(for: fixture)
            let target = fixture.base.appendingPathComponent("linked-marker-target.json")
            let encoder = JSONEncoder()
            try encoder.encode(marker).write(to: target)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: target.path)
            try FileManager.default.linkItem(
                at: target,
                to: fixture.root.appendingPathComponent(StorageAuthorityProtocol.markerName))

            let recognition = StorageAuthorityRecognizer.inspect(supportRoot: fixture.root)
            guard case .invalid = recognition.marker else {
                return XCTFail("expected a hard-linked marker to be invalid")
            }
            assertBlocked(recognition)
        }

        do {
            let fixture = try makeDatabaseFixture(state: .shadow)
            defer { try? FileManager.default.removeItem(at: fixture.base) }
            let database = fixture.root.appendingPathComponent(
                StorageAuthorityProtocol.databaseName)
            try FileManager.default.linkItem(
                at: database,
                to: fixture.base.appendingPathComponent("linked-library.db"))

            assertBlocked(StorageAuthorityRecognizer.inspect(supportRoot: fixture.root))
        }
    }

    func testRecognizerRejectsUnsafeSupportRoot() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "storage-authority-root-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: base.path)
        let target = base.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: target.path)
        let link = base.appendingPathComponent("linked-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        assertBlocked(StorageAuthorityRecognizer.inspect(supportRoot: link))

        // A group-readable root is repaired, not refused. Only the migration ever tightened this
        // directory and only on the machine that ran it, so every other installation has the 0755
        // one `createDirectory` leaves under the default umask — refusing that is refusing to
        // launch, with the data already sitting there at those permissions.
        let exposed = base.appendingPathComponent("exposed-root", isDirectory: true)
        try FileManager.default.createDirectory(at: exposed, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: exposed.path)

        let recognition = StorageAuthorityRecognizer.inspect(supportRoot: exposed)

        guard case .legacyUnmarked = recognition.disposition else {
            return XCTFail("an ordinary 0755 root must be repaired, not blocked")
        }
        assertMode(exposed, equals: 0o700)
    }

    /// Recognition and the lease must repair identically, so a launch that recognizes the root
    /// without taking the lease first — a notification-relay launch does — is not blocked by
    /// ordering alone.
    /// The third copy of the owner-only rule lived in marker publication, the last step of a
    /// migration, and it refused rather than repaired — the same shape that blocked two
    /// installations from launching at all. It was only survivable because an earlier step happened
    /// to have repaired the root already, which is precisely the reasoning that failed before.
    func testMarkerPublicationRepairsTheRootRatherThanRefusing() throws {
        let fixture = try makeDatabaseFixture(state: .active)
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let marker = try sqliteMarker(for: fixture)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: fixture.root.path)

        XCTAssertNoThrow(try StorageAuthorityMarkerStore.publish(marker, in: fixture.root))
        assertMode(fixture.root, equals: 0o700)
    }

    func testRecognitionRepairsTheRootWithoutTheLease() throws {
        let fixture = try makeEmptyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: fixture.root.path)

        guard case .legacyUnmarked = StorageAuthorityRecognizer
            .inspect(supportRoot: fixture.root).disposition else {
            return XCTFail("recognition must repair the root on its own")
        }
        assertMode(fixture.root, equals: 0o700)
    }

    func testProcessLeaseContendsUntilOwnerReleasesIt() throws {
        let fixture = try makeEmptyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        var first: StorageAuthorityProcessLease? = try StorageAuthorityProcessLease.acquire(
            in: fixture.root)
        XCTAssertNotNil(first)
        let leaseURL = fixture.root.appendingPathComponent(
            StorageAuthorityProtocol.processLeaseName)
        assertMode(leaseURL, equals: 0o600)

        XCTAssertThrowsError(try StorageAuthorityProcessLease.acquire(in: fixture.root)) { error in
            guard case StorageAuthorityRecognitionError.lease = error else {
                return XCTFail("unexpected contention error: \(error)")
            }
        }

        first = nil
        let successor = try StorageAuthorityProcessLease.acquire(in: fixture.root)
        withExtendedLifetime(successor) {}
    }

    /// Only the migration ever tightened the support root, and only on the machine that ran it.
    /// Every other installation still has the 0755 directory `createDirectory` produces under the
    /// default umask — and refusing that root made the app unopenable, with no in-app remedy. The
    /// data is already there at those permissions, so the lease repairs the directory instead.
    func testProcessLeaseTightensAGroupReadableRootInsteadOfRefusingToLaunch() throws {
        let fixture = try makeEmptyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: fixture.root.path)

        var lease: StorageAuthorityProcessLease? = try StorageAuthorityProcessLease.acquire(
            in: fixture.root)
        XCTAssertNotNil(lease)
        assertMode(fixture.root, equals: 0o700)
        lease = nil
    }

    /// A root this user does not own is not ours to repair, and must still fail closed.
    func testProcessLeaseStillRefusesARootThisUserDoesNotOwn() throws {
        let fixture = try makeEmptyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let foreign = fixture.base.appendingPathComponent("not-a-directory", isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: foreign.path, contents: Data()))

        XCTAssertThrowsError(try StorageAuthorityProcessLease.acquire(in: foreign)) { error in
            guard case StorageAuthorityRecognitionError.lease = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testProcessLeaseRejectsUnsafeExistingInodeWithoutChangingPermissions() throws {
        do {
            let fixture = try makeEmptyFixture()
            defer { try? FileManager.default.removeItem(at: fixture.base) }
            let lease = fixture.root.appendingPathComponent(
                StorageAuthorityProtocol.processLeaseName)
            XCTAssertTrue(FileManager.default.createFile(
                atPath: lease.path,
                contents: Data(),
                attributes: [.posixPermissions: NSNumber(value: 0o644)]))

            XCTAssertThrowsError(try StorageAuthorityProcessLease.acquire(in: fixture.root))
            assertMode(lease, equals: 0o644)
        }

        do {
            let fixture = try makeEmptyFixture()
            defer { try? FileManager.default.removeItem(at: fixture.base) }
            let target = fixture.base.appendingPathComponent("lease-hard-link-target")
            XCTAssertTrue(FileManager.default.createFile(
                atPath: target.path,
                contents: Data(),
                attributes: [.posixPermissions: NSNumber(value: 0o600)]))
            try FileManager.default.linkItem(
                at: target,
                to: fixture.root.appendingPathComponent(
                    StorageAuthorityProtocol.processLeaseName))

            XCTAssertThrowsError(try StorageAuthorityProcessLease.acquire(in: fixture.root))
            assertMode(target, equals: 0o600)
        }
    }
}

private extension StorageAuthorityMarkerTests {
    static let timestamp = "2026-08-05T12:00:00Z"

    struct Fixture {
        let base: URL
        let root: URL
        let store: SQLiteLibraryStore?
        let metadata: LibraryAuthorityMetadata?
        let activationID: UUID?
        let rollbackID: UUID?
    }

    func makeEmptyFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "storage-authority-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: base.path)
        let root = base.appendingPathComponent("Mechanician", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: root.path)
        return Fixture(
            base: base,
            root: root,
            store: nil,
            metadata: nil,
            activationID: nil,
            rollbackID: nil)
    }

    func makeDatabaseFixture(state: LibraryAuthorityState) throws -> Fixture {
        let empty = try makeEmptyFixture()
        let store = try SQLiteLibraryStore(supportRoot: empty.root)
        let activationID = state == .shadow ? nil : UUID()
        let rollbackID = state == .rollbackPrepared || state == .rolledBack ? UUID() : nil
        if let activationID {
            let status = try store.status()
            try store.acknowledgeExactProjectionSnapshot(
                databaseInstanceID: status.databaseInstanceID,
                through: status.shadowChangeSequence,
                projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion))
            try store.prepareAuthority(
                activationID: activationID,
                minimumWriterBuild: StorageAuthorityProtocol.recognitionID)
        }
        if state == .active || state == .rollbackPrepared || state == .rolledBack {
            try store.activatePreparedAuthority(activationID: try XCTUnwrap(activationID))
        }
        if state == .rollbackPrepared || state == .rolledBack {
            try store.prepareRollback(
                activationID: try XCTUnwrap(activationID),
                rollbackID: try XCTUnwrap(rollbackID))
        }
        if state == .rolledBack {
            try store.completeRollback(
                activationID: try XCTUnwrap(activationID),
                rollbackID: try XCTUnwrap(rollbackID))
        }
        return Fixture(
            base: empty.base,
            root: empty.root,
            store: store,
            metadata: try store.authorityMetadata(),
            activationID: activationID,
            rollbackID: rollbackID)
    }

    func sqliteMarker(
        for fixture: Fixture,
        createdAt: String = StorageAuthorityMarkerTests.timestamp
    ) throws -> StorageAuthorityMarker {
        let metadata = try XCTUnwrap(fixture.metadata)
        return StorageAuthorityMarker(
            mode: .sqlite,
            activationID: try XCTUnwrap(fixture.activationID),
            databaseInstanceID: metadata.databaseInstanceID,
            schemaVersion: metadata.schemaVersion,
            minimumWriterBuild: try XCTUnwrap(metadata.minimumWriterBuild),
            createdAt: createdAt)
    }

    func legacyMarker(
        for fixture: Fixture,
        generation: URL
    ) throws -> StorageAuthorityMarker {
        let metadata = try XCTUnwrap(fixture.metadata)
        return StorageAuthorityMarker(
            mode: .legacy,
            activationID: try XCTUnwrap(fixture.activationID),
            databaseInstanceID: metadata.databaseInstanceID,
            generationName: generation.lastPathComponent,
            rollbackID: try XCTUnwrap(fixture.rollbackID),
            schemaVersion: metadata.schemaVersion,
            minimumWriterBuild: try XCTUnwrap(metadata.minimumWriterBuild),
            createdAt: Self.timestamp)
    }

    func makeGeneration(beside root: URL) throws -> URL {
        let generation = root.deletingLastPathComponent().appendingPathComponent(
            "Mechanician-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: generation, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: generation.path)
        return generation
    }

    func writeMarkerBytes(
        _ data: Data,
        in root: URL,
        mode: Int = 0o600
    ) throws {
        let url = root.appendingPathComponent(StorageAuthorityProtocol.markerName)
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }

    func replaceDatabaseWithGarbage(in root: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(
                StorageAuthorityProtocol.databaseName + suffix))
        }
        let database = root.appendingPathComponent(StorageAuthorityProtocol.databaseName)
        try Data("not-a-sqlite-database".utf8).write(to: database)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: database.path)
    }

    func assertLegacyUnmarked(
        _ recognition: StorageAuthorityRecognition,
        databaseState: LibraryAuthorityState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .legacyUnmarked(let database) = recognition.disposition else {
            return XCTFail(
                "expected unmarked Legacy authority, got \(recognition.disposition)",
                file: file,
                line: line)
        }
        XCTAssertEqual(database?.authorityState, databaseState, file: file, line: line)
        XCTAssertTrue(recognition.disposition.allowsLegacyWriters, file: file, line: line)
    }

    func assertBlocked(
        _ recognition: StorageAuthorityRecognition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .blocked = recognition.disposition else {
            return XCTFail(
                "expected blocked recognition, got \(recognition.disposition)",
                file: file,
                line: line)
        }
        XCTAssertFalse(recognition.disposition.allowsLegacyWriters, file: file, line: line)
    }

    func assertInterruptedUnmarked(
        _ recognition: StorageAuthorityRecognition,
        databaseState: LibraryAuthorityState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .legacyUnmarked(let database) = recognition.disposition else {
            return XCTFail(
                "expected an interrupted unmarked authority, got \(recognition.disposition)",
                file: file,
                line: line)
        }
        XCTAssertEqual(database?.authorityState, databaseState, file: file, line: line)
        XCTAssertFalse(recognition.disposition.allowsLegacyWriters, file: file, line: line)
        XCTAssertFalse(recognition.disposition.allowsNormalProduct, file: file, line: line)
        XCTAssertNotNil(recognition.disposition.blockingMessage, file: file, line: line)
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
