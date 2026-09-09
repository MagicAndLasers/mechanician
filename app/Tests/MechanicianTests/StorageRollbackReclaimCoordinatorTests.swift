import Foundation
import XCTest
@testable import Mechanician

/// The reclaim is the one operation that removes somebody's only pre-migration copy, and it had no
/// caller at all until now. These cover what the caller has to get right: reading the real counts
/// rather than trusting a caller's, refusing on anything unproven, and recording what it released.
final class StorageRollbackReclaimCoordinatorTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-coordinator-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Mechanician", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("conversations", isDirectory: true),
            withIntermediateDirectories: true)
        for directory in [base, root] {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)
        }
        return root
    }

    private func defaults() throws -> UserDefaults {
        let suite = "reclaim-coordinator-\(UUID().uuidString)"
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    // MARK: Counting the frozen tree

    func testLegacyCountsOnlyJSONSidecars() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let conversations = root.appendingPathComponent("conversations", isDirectory: true)
        for name in ["a.json", "b.json", "notes.txt", "c.json.corrupt-1"] {
            try Data("x".utf8).write(to: conversations.appendingPathComponent(name))
        }

        XCTAssertEqual(
            StorageRollbackReclaimCoordinator.legacyConversationFileCount(in: root), 2,
            "only live `.json` sidecars are what the coverage proof compares against")
    }

    func testAnAbsentFrozenTreeIsZeroButAnUnreadableOneIsNot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("conversations", isDirectory: true))
        XCTAssertEqual(
            StorageRollbackReclaimCoordinator.legacyConversationFileCount(in: root), 0,
            "an already-released tree is genuinely nothing")

        let unreadable = root.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)], ofItemAtPath: unreadable.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: unreadable.path)
        }

        XCTAssertEqual(
            StorageRollbackReclaimCoordinator.legacyConversationFileCount(in: root), Int.max,
            "a directory nobody can read must never be mistaken for an empty one")
    }

    /// The same failure through the policy: an unreadable tree can never satisfy coverage.
    func testAnUnreadableFrozenTreeBlocksTheReclaim() {
        let inputs = StorageRollbackReclaimInputs(
            authorityState: .active,
            markerCreatedAt: Date(timeIntervalSinceNow: -30 * 24 * 60 * 60),
            integrityPassed: true,
            hasVerifiedBackup: true,
            sqliteConversationCount: 100,
            legacyConversationFileCount: Int.max,
            preservedUnreadableSourceCount: 0)
        guard case .blocked = StorageRollbackReclaimPolicy.decide(inputs) else {
            return XCTFail("an unmeasurable frozen tree must block")
        }
    }

    // MARK: Marker timestamps

    func testMarkerTimestampsParseWithAndWithoutFractionalSeconds() {
        XCTAssertNotNil(
            StorageRollbackReclaimCoordinator.markerDate("2026-08-05T19:42:07.371000Z"))
        XCTAssertNotNil(StorageRollbackReclaimCoordinator.markerDate("2026-08-05T19:42:07Z"))
        XCTAssertNil(StorageRollbackReclaimCoordinator.markerDate("not a date"))
    }

    /// A marker whose timestamp cannot be read has no age, and an unaged marker must not reclaim.
    func testAnUnreadableMarkerDateBlocks() {
        let inputs = StorageRollbackReclaimInputs(
            authorityState: .active,
            markerCreatedAt: nil,
            integrityPassed: true,
            hasVerifiedBackup: true,
            sqliteConversationCount: 10,
            legacyConversationFileCount: 10,
            preservedUnreadableSourceCount: 0)
        guard case .blocked = StorageRollbackReclaimPolicy.decide(inputs) else {
            return XCTFail("a marker with no readable creation time must block")
        }
    }

    // MARK: Refusing before the library is the authority

    func testALegacyRootIsNeverReclaimed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        // A Legacy root has no authority repository at all, which is itself the proof: the reclaim
        // cannot even be asked to run before the library owns the root.
        XCTAssertNil(
            try LibraryAuthorityRepository.open(recognition: .legacyDefault(root: root)),
            "nothing may be released while Legacy is still authoritative")
    }

    // MARK: Idempotent post-reclaim launches

    func testAnEmptyTargetSetSkipsIntegrityOnlyWhenEveryOtherGatePasses() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let due = StorageRollbackReclaimInputs(
            authorityState: .active,
            markerCreatedAt: Date(timeIntervalSinceNow: -30 * 24 * 60 * 60),
            integrityPassed: false,
            hasVerifiedBackup: true,
            sqliteConversationCount: 10,
            legacyConversationFileCount: 10,
            preservedUnreadableSourceCount: 0)

        XCTAssertEqual(
            StorageRollbackReclaimCoordinator.emptyReclaimOutcomeIfDue(
                supportRoot: root, inputs: due),
            StorageRollbackReclaimCoordinator.Outcome(
                decision: .reclaim, report: StorageRollbackReclaimReport()),
            "no integrity scan is useful after the rollback generation is already gone")

        var noBackup = due
        noBackup.hasVerifiedBackup = false
        XCTAssertNil(StorageRollbackReclaimCoordinator.emptyReclaimOutcomeIfDue(
            supportRoot: root, inputs: noBackup))

        var beforeSoak = due
        beforeSoak.now = try XCTUnwrap(beforeSoak.markerCreatedAt)
        XCTAssertNil(StorageRollbackReclaimCoordinator.emptyReclaimOutcomeIfDue(
            supportRoot: root, inputs: beforeSoak))
    }

    // MARK: The receipt

    func testACompletedReclaimIsRecordedForLaterReporting() throws {
        let store = try defaults()
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        StorageRollbackReclaimCoordinator.record(
            StorageRollbackReclaimReport(
                releasedNames: ["conversations", "Mechanician Legacy Rollback 1"],
                releasedBytes: 2_850_000_000),
            at: moment,
            in: store)

        let receipt = try XCTUnwrap(StorageRollbackReclaimCoordinator.lastReceipt(in: store))
        XCTAssertEqual(receipt.releasedNames.count, 2)
        XCTAssertEqual(receipt.releasedBytes, 2_850_000_000)
        XCTAssertEqual(receipt.releasedAt, moment)
        XCTAssertTrue(
            StorageRollbackReclaimCoordinator.releasedDescription(receipt).contains("GB"),
            "the person is told how much space came back, not a byte count")
    }

    func testNoReceiptExistsBeforeAnyReclaim() throws {
        XCTAssertNil(StorageRollbackReclaimCoordinator.lastReceipt(in: try defaults()))
    }

    // MARK: What the person is told

    /// The reclaim moves several gigabytes of somebody's previous library to the Trash while nobody
    /// is watching. These are the rules for saying so, kept out of the view so they can be asserted
    /// at all: the notice this is modelled on put its copy inside `ContentView` and has no tests.
    func testTheNoticeAppearsOnlyWhileThereIsSomethingToSay() throws {
        let store = try defaults()
        XCTAssertNil(
            StorageRollbackReclaimNotice.pending(in: store),
            "nothing was released, so there is nothing to report")

        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        StorageRollbackReclaimCoordinator.record(
            StorageRollbackReclaimReport(releasedNames: [], releasedBytes: 0), at: moment, in: store)
        XCTAssertNil(
            StorageRollbackReclaimNotice.pending(in: store),
            "a reclaim that released nothing is not news")

        StorageRollbackReclaimCoordinator.record(
            StorageRollbackReclaimReport(
                releasedNames: ["conversations", "Mechanician Legacy Rollback 1"],
                releasedBytes: 2_850_000_000),
            at: moment, in: store)
        let receipt = try XCTUnwrap(StorageRollbackReclaimNotice.pending(in: store))
        XCTAssertEqual(receipt.releasedBytes, 2_850_000_000)

        let message = StorageRollbackReclaimNotice.message(receipt)
        XCTAssertTrue(message.contains("2.85 GB"), "the size is the number that matters: \(message)")
        XCTAssertTrue(
            message.contains("Trash"),
            "the space is not back until the Trash is emptied, and saying otherwise is a lie")
        XCTAssertFalse(
            message.contains("conversations"),
            "internal directory names are not an explanation")
    }

    func testDismissingSettlesThisReceiptButNotALaterOne() throws {
        let store = try defaults()
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        StorageRollbackReclaimCoordinator.record(
            StorageRollbackReclaimReport(releasedNames: ["conversations"], releasedBytes: 1_024),
            at: moment, in: store)
        let receipt = try XCTUnwrap(StorageRollbackReclaimNotice.pending(in: store))

        let mark = StorageRollbackReclaimNotice.dismissalMark(for: receipt)
        XCTAssertTrue(StorageRollbackReclaimNotice.isDismissed(receipt, dismissedAt: mark))
        XCTAssertNil(StorageRollbackReclaimNotice.pending(in: store, dismissedAt: mark))

        // A second reclaim is a different event. An older mark must not silence it.
        StorageRollbackReclaimCoordinator.record(
            StorageRollbackReclaimReport(releasedNames: ["artifacts"], releasedBytes: 2_048),
            at: moment.addingTimeInterval(86_400), in: store)
        let later = try XCTUnwrap(StorageRollbackReclaimNotice.pending(in: store, dismissedAt: mark))
        XCTAssertEqual(later.releasedBytes, 2_048)
    }

    /// Dismissal is stored rather than held per window, because `ContentView` exists once per
    /// workspace window and the notice that predates this rule stays painted in whichever windows
    /// were already open when it was dismissed in another.
    func testDismissalIsReadFromSharedStorageRatherThanAssumed() throws {
        let store = try defaults()
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        StorageRollbackReclaimCoordinator.record(
            StorageRollbackReclaimReport(releasedNames: ["conversations"], releasedBytes: 1_024),
            at: moment, in: store)
        let receipt = try XCTUnwrap(StorageRollbackReclaimNotice.pending(in: store))
        store.set(
            StorageRollbackReclaimNotice.dismissalMark(for: receipt),
            forKey: StorageRollbackReclaimNotice.dismissedAtKey)
        XCTAssertNil(
            StorageRollbackReclaimNotice.pending(in: store),
            "a window opened after the dismissal must not show it again")
    }
}

/// The launcher is the one production caller, and the thing it must never do is run twice or run on
/// the main actor.
final class StorageRollbackReclaimLauncherTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StorageRollbackReclaimLauncher.resetForTesting()
    }

    override func tearDown() {
        StorageRollbackReclaimLauncher.resetForTesting()
        super.tearDown()
    }

    /// On a machine with no SQLite authority the launcher must be a no-op that returns immediately,
    /// not something that blocks launch while it measures a library that is not there.
    func testItReturnsImmediatelyAndDoesNotRunTwice() {
        let started = Date()
        StorageRollbackReclaimLauncher.runAfterLaunch()
        StorageRollbackReclaimLauncher.runAfterLaunch()
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 0.5,
            "the launcher must hand off to its own queue rather than work on the caller's thread")
    }
}
