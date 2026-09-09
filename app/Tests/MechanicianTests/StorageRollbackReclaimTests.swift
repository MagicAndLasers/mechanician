import Foundation
import XCTest
@testable import Mechanician

final class StorageRollbackReclaimTests: XCTestCase {
    private let migratedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func inputs(
        state: LibraryAuthorityState = .active,
        markerCreatedAt: Date? = nil,
        hasMarkerDate: Bool = true,
        afterDays: Double = 8,
        integrity: Bool = true,
        backup: Bool = true,
        sqliteCount: Int = 81,
        legacyCount: Int = 81
    ) -> StorageRollbackReclaimInputs {
        StorageRollbackReclaimInputs(
            authorityState: state,
            markerCreatedAt: hasMarkerDate ? (markerCreatedAt ?? migratedAt) : nil,
            now: migratedAt.addingTimeInterval(afterDays * 24 * 60 * 60),
            integrityPassed: integrity,
            hasVerifiedBackup: backup,
            sqliteConversationCount: sqliteCount,
            legacyConversationFileCount: legacyCount)
    }

    func testAHealthyLibraryReleasesItsPredecessorOnlyAfterTheSoak() {
        XCTAssertEqual(StorageRollbackReclaimPolicy.decide(inputs(afterDays: 8)), .reclaim)
        guard case .waitForSoak(let remaining) =
            StorageRollbackReclaimPolicy.decide(inputs(afterDays: 6)) else {
            return XCTFail("six days in is still the soak")
        }
        XCTAssertEqual(remaining, 24 * 60 * 60, accuracy: 1)
        XCTAssertEqual(
            StorageRollbackReclaimPolicy.decide(inputs(afterDays: 0)),
            .waitForSoak(remaining: StorageRollbackReclaimPolicy.soak))
    }

    func testNothingIsReleasedUntilTheNewLibraryHasProvedItself() {
        for state: LibraryAuthorityState in [.shadow, .prepared, .rollbackPrepared, .rolledBack] {
            guard case .blocked = StorageRollbackReclaimPolicy.decide(inputs(state: state)) else {
                return XCTFail("\(state) must not release the rollback material")
            }
        }
        guard case .blocked = StorageRollbackReclaimPolicy.decide(inputs(integrity: false)) else {
            return XCTFail("an unproven database keeps its predecessor")
        }
        guard case .blocked = StorageRollbackReclaimPolicy.decide(inputs(backup: false)) else {
            return XCTFail("releasing the rollback with no verified backup leaves no way back")
        }
        guard case .blocked = StorageRollbackReclaimPolicy.decide(
            inputs(sqliteCount: 80, legacyCount: 81)) else {
            return XCTFail("a library accounting for fewer Conversations than the frozen sources "
                           + "must never release those sources")
        }
        guard case .blocked = StorageRollbackReclaimPolicy.decide(
            inputs(hasMarkerDate: false)) else {
            return XCTFail("without a marker date there is no soak to have completed")
        }
    }

    /// A clock that moved backwards must not read as a completed soak.
    func testAFutureDatedMarkerIsRefusedRatherThanTreatedAsAged() {
        guard case .blocked = StorageRollbackReclaimPolicy.decide(
            inputs(markerCreatedAt: migratedAt.addingTimeInterval(60 * 60), afterDays: 0)) else {
            return XCTFail("a marker dated ahead of now is not an aged one")
        }
    }

    /// The most important test here. `conversation-media` holds the live attachments, adopted in
    /// place at migration rather than copied, so the active library references those exact files.
    /// Releasing them would destroy user data that nothing else holds.
    func testLiveDataIsNeverReclaimable() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Mechanician", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = FileManager.default
        for directory in ["conversations", "workspaces", "artifacts", "conversation-media",
                          "trash", "ambient", "claude"] {
            try manager.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true)
        }
        for file in ["library.db", "projections.db", "storage-authority.json",
                     "home-workspace.json"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(file))
        }
        try manager.createDirectory(
            at: base.appendingPathComponent("Mechanician Legacy Rollback abc123", isDirectory: true),
            withIntermediateDirectories: true)
        try manager.createDirectory(
            at: base.appendingPathComponent("Mechanician Library Backups", isDirectory: true),
            withIntermediateDirectories: true)

        let targets = StorageRollbackReclaimPolicy.reclaimableTargets(supportRoot: root)
        let names = Set(targets.map(\.lastPathComponent))

        XCTAssertEqual(names, ["Mechanician Legacy Rollback abc123"])

        // The frozen structured sources are held back, not released. App Intents no longer depend
        // on them, but `conversations/` holds the `.json.corrupt-*` sidecars that are the only
        // remaining copy of conversations the app could not read, and the onboarding probe still
        // decides "this installation has data" by listing these directories.
        for stillRead in ["conversations", "workspaces", "artifacts", "home-workspace.json"] {
            XCTAssertFalse(
                names.contains(stillRead),
                "\(stillRead) still holds the last copy of unreadable sources, or is still probed")
        }
        for live in ["conversation-media", "trash", "library.db", "projections.db",
                     "storage-authority.json", "ambient", "claude",
                     "Mechanician Library Backups"] {
            XCTAssertFalse(
                names.contains(live),
                "\(live) is live or independently managed and must never be reclaimed")
        }
        for target in targets {
            XCTAssertFalse(
                StorageRollbackReclaimPolicy.isProtected(target, supportRoot: root),
                "\(target.lastPathComponent) is protected and must not be a target")
        }
    }

    func testOnlyExactlyNamedRollbackSiblingsAreMatched() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-siblings-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Mechanician", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for sibling in ["Mechanician Legacy Rollback 1", "Mechanician Legacy Rollback 2",
                        "Mechanician Library Backups", "Mechanician-dev", "Legacy Rollback",
                        "Mechanician Legacy Rollbacks Elsewhere"] {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent(sibling, isDirectory: true),
                withIntermediateDirectories: true)
        }

        let matched = StorageRollbackReclaimPolicy.rollbackGenerations(besides: root)
            .map(\.lastPathComponent)
        XCTAssertEqual(
            matched, ["Mechanician Legacy Rollback 1", "Mechanician Legacy Rollback 2"])
    }

    func testReclaimTrashesTheLeftoversAndLeavesLiveDataUntouched() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-run-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Mechanician", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = FileManager.default
        for directory in ["conversations", "conversation-media"] {
            try manager.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true)
        }
        let frozen = root.appendingPathComponent("conversations/one.json")
        let live = root.appendingPathComponent("conversation-media/live.png")
        try Data(repeating: 7, count: 4_096).write(to: frozen)
        try Data(repeating: 9, count: 8_192).write(to: live)
        let rollback = base.appendingPathComponent(
            "Mechanician Legacy Rollback abc", isDirectory: true)
        try manager.createDirectory(at: rollback, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 16_384).write(
            to: rollback.appendingPathComponent("copy.json"))

        let report = try StorageRollbackReclaimService.reclaim(supportRoot: root)
        // This exercises the real Trash, so it has to put its own debris back. Before the report
        // named where things landed, every gate run left another `conversations` and
        // `Mechanician Legacy Rollback abc` behind; twenty-seven pairs had piled up.
        addTeardownBlock {
            for url in report.trashedURLs { try? FileManager.default.removeItem(at: url) }
        }

        XCTAssertEqual(report.releasedNames, ["Mechanician Legacy Rollback abc"])
        XCTAssertGreaterThanOrEqual(report.releasedBytes, 16_384)
        XCTAssertFalse(manager.fileExists(atPath: rollback.path))
        XCTAssertTrue(
            manager.fileExists(atPath: live.path),
            "the live attachments the active library references must survive a reclaim")
        // The frozen structured sources are no longer released. `conversations/` still holds the
        // preserved bytes of sidecars the app could not read, and releasing it would take an
        // unreadable conversation's last copy with it.
        XCTAssertTrue(
            manager.fileExists(atPath: frozen.path),
            "the frozen sources holding unreadable originals must survive a reclaim")
    }

    /// Defense in depth: even handed a protected path explicitly, the executor refuses.
    func testReclaimRefusesAProtectedTargetEvenWhenAskedDirectly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-guard-\(UUID().uuidString)/Mechanician",
                                    isDirectory: true)
        let media = root.appendingPathComponent("conversation-media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        XCTAssertThrowsError(
            try StorageRollbackReclaimService.reclaim(supportRoot: root, targets: [media])
        ) { error in
            XCTAssertEqual(
                error as? StorageRollbackReclaimError, .protectedTarget("conversation-media"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
    }

    func testTargetsAreAbsentUntilTheyExist() {
        let root = URL(fileURLWithPath: "/tmp/reclaim-nonexistent-\(UUID().uuidString)")
        XCTAssertTrue(StorageRollbackReclaimPolicy.reclaimableTargets(supportRoot: root).isEmpty)
    }
}
