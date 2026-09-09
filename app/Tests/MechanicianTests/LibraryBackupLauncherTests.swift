import Foundation
import XCTest
@testable import Mechanician

/// The daily library backup has a production caller again.
///
/// It had none for fifteen days. `createBackupIfDue` is the only thing that creates a backup, and
/// its two call sites lived inside the migration — `4ea5560`, "retire completed migration", removed
/// them with the migration they sat in. The lifecycle's own tests kept passing throughout, which is
/// what made a total loss of backups invisible.
///
/// So this suite tests the WIRING, not the lifecycle: whether anything calls it, in what order, and
/// how often. That is the half nothing was checking.
final class LibraryBackupLauncherTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LibraryBackupLauncher.resetForTesting()
    }

    override func tearDown() {
        LibraryBackupLauncher.resetForTesting()
        super.tearDown()
    }

    private func appSource() throws -> String {
        try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/MechanicianTests/LibraryBackupLauncherTests.swift",
                with: "Sources/Mechanician/MechanicianApp.swift"),
            encoding: .utf8)
    }

    private func settingsSource() throws -> String {
        try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/MechanicianTests/LibraryBackupLauncherTests.swift",
                with: "Sources/Mechanician/LibraryBackupSettingsSection.swift"),
            encoding: .utf8)
    }

    /// THE REGRESSION, PINNED. Launch must call the backup launcher at all.
    func testLaunchCallsTheBackupLauncher() throws {
        XCTAssertTrue(
            try appSource().contains("LibraryBackupLauncher.runAfterLaunch"),
            "nothing called the daily backup for fifteen days; launch must call it")
    }

    /// And BEFORE the reclaim. `hasVerifiedBackup` is the reclaim's precondition, so a launch that
    /// reclaims first can never satisfy it — the reclaim would wait for a backup taken after it.
    func testTheBackupIsTakenBeforeTheReclaim() throws {
        let source = try appSource()
        let backup = try XCTUnwrap(source.range(of: "LibraryBackupLauncher.runAfterLaunch"))
        let reclaim = try XCTUnwrap(
            source.range(of: "StorageRollbackReclaimLauncher.runAfterLaunch"))
        XCTAssertLessThan(
            backup.lowerBound, reclaim.lowerBound,
            "the reclaim's way back is the backup, so the backup goes first")
    }

    /// The continuation must run even when the backup does nothing, or a refusal silently disables
    /// the reclaim behind it — one broken thing becoming two.
    func testTheReclaimStillRunsWhenTheBackupDoesNothing() {
        let followed = expectation(description: "continuation")
        // No writer lease and no active repository in a test process, so the body returns early.
        LibraryBackupLauncher.runAfterLaunch { followed.fulfill() }
        wait(for: [followed], timeout: 5)
    }

    /// At most once per launch: copying gigabytes twice because two windows opened would be worse
    /// than not copying at all.
    func testItRunsAtMostOncePerLaunch() {
        let first = expectation(description: "first")
        let second = expectation(description: "second")
        LibraryBackupLauncher.runAfterLaunch { first.fulfill() }
        wait(for: [first], timeout: 5)
        // The second call must still hand on, or whatever follows it never happens.
        LibraryBackupLauncher.runAfterLaunch { second.fulfill() }
        wait(for: [second], timeout: 5)
    }

    /// Daily, and the number of copies is now the person's to choose.
    ///
    /// It was a hard-coded 7. Measured on a real library one generation is about 2.4 GB, of which
    /// only 651 MB is the database — the rest is retained media copied whole into every copy
    /// because the shared object pool beside them is empty. Seven copies is roughly 17 GB spent on
    /// a policy nobody was ever shown, so the default is 3 and the choice is in Settings.
    func testTheCadenceIsDailyAndTheDefaultKeepsThree() {
        XCTAssertEqual(LibraryBackupLifecycle.minimumInterval, 24 * 60 * 60)
        XCTAssertEqual(LibraryBackupSettings.defaultGenerations, 3)
        XCTAssertEqual(LibraryBackupLifecycle.maximumGenerations, LibraryBackupSettings.generations())
    }

    /// A choice outside what is offered is ignored rather than clamped. Zero would read as a policy
    /// and is really a way to lose everything, and this is the one setting whose failure has no undo.
    func testAnUnofferedRetentionIsRefused() {
        let store = UserDefaults(suiteName: "backup-retention-\(UUID().uuidString)")!
        for bad in [0, -3, 2, 30, 365] {
            store.set(bad, forKey: LibraryBackupSettings.key)
            XCTAssertEqual(LibraryBackupSettings.generations(store: store), 3, "\(bad)")
            LibraryBackupSettings.setGenerations(bad, store: store)
            XCTAssertEqual(LibraryBackupSettings.generations(store: store), 3, "\(bad)")
        }
        for good in LibraryBackupSettings.choices {
            LibraryBackupSettings.setGenerations(good, store: store)
            XCTAssertEqual(LibraryBackupSettings.generations(store: store), good)
        }
    }

    /// On unless somebody says otherwise. The alternative is what shipped for fifteen days by
    /// accident, and a person who turns it off has decided rather than been defaulted.
    func testBackupsAreOnUntilSomebodyTurnsThemOff() {
        let store = UserDefaults(suiteName: "backup-enabled-\(UUID().uuidString)")!
        XCTAssertTrue(LibraryBackupSettings.isEnabled(store: store))
        LibraryBackupSettings.setEnabled(false, store: store)
        XCTAssertFalse(LibraryBackupSettings.isEnabled(store: store))
    }

    /// "Back up now" must not be silently swallowed by the 24-hour cadence: a person pressing it is
    /// saying something a clock cannot know.
    func testBackUpNowIgnoresTheCadence() throws {
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/MechanicianTests/LibraryBackupLauncherTests.swift",
                with: "Sources/Mechanician/LibraryBackupLauncher.swift"),
            encoding: .utf8)
        let now = try XCTUnwrap(source.range(of: "static func backUpNow"))
        let forced = try XCTUnwrap(source.range(of: "force: true"))
        XCTAssertLessThan(
            now.lowerBound, forced.lowerBound,
            "pressing the button must take a copy, not report one from this morning")
        // And the scheduled path must NOT force, or the cadence means nothing.
        let scheduled = try XCTUnwrap(source.range(of: "static func runAfterLaunch"))
        XCTAssertLessThan(
            scheduled.lowerBound, now.lowerBound,
            "the scheduled path is declared first and is the one that honours the cadence")
        XCTAssertEqual(
            source.components(separatedBy: "force: true").count - 1, 1,
            "exactly one caller ignores the cadence")
    }

    /// These two actions shipped as stock macOS push buttons even though every neighboring
    /// Settings action speaks Mechanician's capsule language. Keep their visible and accessibility
    /// contracts together so a future Settings refactor cannot silently restore the stock bezel.
    func testBackupSettingsActionsUseMechanicianPills() throws {
        let source = try settingsSource()

        let backUp = try XCTUnwrap(source.range(of: "Button(busy ? \"Backing up…\" : \"Back up now\")"))
        let reveal = try XCTUnwrap(source.range(of: "Button(\"Show in Finder\")"))
        let backUpBody = String(source[backUp.lowerBound..<reveal.lowerBound])
        let revealBody = String(source[reveal.lowerBound...])

        XCTAssertTrue(backUpBody.contains(".buttonStyle(PillButtonStyle(kind: .accent))"))
        XCTAssertTrue(backUpBody.contains(".accessibilityLabel(busy ? \"Backing up library\" : \"Back up library now\")"))
        XCTAssertTrue(revealBody.contains(".buttonStyle(PillButtonStyle(kind: .plain))"))
        XCTAssertTrue(revealBody.contains(".accessibilityLabel(\"Show backups in Finder\")"))
    }
}
