import Foundation
import XCTest
@testable import Mechanician

/// The reverted Runtime Service left 4.2 GB behind on a real machine. These tests exist because the
/// operation that removes it deletes a person's files, so the interesting cases are all the ones
/// where it must NOT act.
final class RuntimeResidueReclaimTests: XCTestCase {

    private func makeRoot() throws -> (base: URL, root: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-residue-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Mechanician", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (base, root)
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 4, count: bytes).write(to: url)
    }

    // MARK: - What must never be touched

    /// The whole safety argument is that the enumeration is exact. A name that merely *contains* or
    /// *extends* a residue name is a different directory belonging to somebody else.
    func testOnlyExactlyNamedResidueIsMatched() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        for name in [
            "runtime-resources-backup", "my-runtime", "runtime2", "runtimes",
            "runtime-service.sqlite.bak",
        ] {
            try write(1_024, to: root.appendingPathComponent("\(name)/file.bin"))
            XCTAssertFalse(
                RuntimeResidueReclaimPolicy.isResidue(
                    root.appendingPathComponent(name), supportRoot: root),
                "\(name) is not enumerated residue and must never be released")
        }
        XCTAssertEqual(
            RuntimeResidueReclaimPolicy.residueTargets(supportRoot: root), [],
            "nothing enumerated exists, so nothing may be released")
    }

    /// Case, which is not obvious and which the first version of this test got wrong.
    ///
    /// A default macOS volume is case-INSENSITIVE, so `Runtime-Resources` and `runtime-resources`
    /// are not two directories that could be confused: they are one directory. There is nothing to
    /// protect and nothing to distinguish, and `residueTargets` correctly finds it through the
    /// canonical enumerated name.
    ///
    /// `isResidue` compares paths as strings, so handed a differently-cased URL it refuses. That
    /// asymmetry is deliberate and points the safe way: the deriving path uses canonical names, and
    /// the guard declines anything it cannot match exactly rather than deleting on a maybe.
    func testCaseVariantsResolveThroughTheCanonicalNameAndTheGuardStaysStrict() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        try write(1_024, to: root.appendingPathComponent("Runtime-Resources/file.bin"))

        XCTAssertFalse(
            RuntimeResidueReclaimPolicy.isResidue(
                root.appendingPathComponent("Runtime-Resources"), supportRoot: root),
            "the guard matches exactly and declines anything it cannot")

        let targets = RuntimeResidueReclaimPolicy.residueTargets(supportRoot: root)
        let canonical = root.appendingPathComponent("runtime-resources").standardizedFileURL
        if FileManager.default.fileExists(atPath: canonical.path) {
            // Case-insensitive volume: this IS the residue directory, found canonically.
            XCTAssertEqual(targets, [canonical])
            XCTAssertTrue(RuntimeResidueReclaimPolicy.isResidue(canonical, supportRoot: root))
        } else {
            // Case-sensitive volume: a genuinely different directory, and untouched.
            XCTAssertEqual(targets, [])
        }
    }

    /// Live product storage sits beside the residue. None of it is enumerated, and this asserts the
    /// specific names whose loss would be unrecoverable.
    func testLiveDataIsNeverResidue() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        for name in [
            "library.db", "library.db-wal", "projections.db", "conversation-media", "trash",
            "conversations", "workspaces", "storage-authority.json", "claude", "codex", "ambient",
            "authority-inbox", "preserved-sources",
        ] {
            XCTAssertFalse(
                RuntimeResidueReclaimPolicy.isResidue(
                    root.appendingPathComponent(name), supportRoot: root),
                "\(name) is live product storage and must never be released")
        }
    }

    /// `runtime-service.sqlite` is a prefix of the journal names, so a sloppy `hasPrefix` match
    /// would also claim `runtime-service.sqlite-journal` or anything else beginning that way.
    func testJournalSiblingsAreEnumeratedRatherThanPrefixMatched() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        for name in ["runtime-service.sqlite", "runtime-service.sqlite-wal",
                     "runtime-service.sqlite-shm"] {
            XCTAssertTrue(
                RuntimeResidueReclaimPolicy.isResidue(
                    root.appendingPathComponent(name), supportRoot: root))
        }
        XCTAssertFalse(
            RuntimeResidueReclaimPolicy.isResidue(
                root.appendingPathComponent("runtime-service.sqlite-journal"), supportRoot: root))
    }

    /// A path outside the support root can never be residue, whatever it is called.
    func testAPathOutsideTheRootIsNeverResidue() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let sibling = base.appendingPathComponent("Mechanician-dev/runtime", isDirectory: true)
        XCTAssertFalse(RuntimeResidueReclaimPolicy.isResidue(sibling, supportRoot: root))
        let escaped = root.appendingPathComponent("../Mechanician-dev/runtime")
        XCTAssertFalse(
            RuntimeResidueReclaimPolicy.isResidue(escaped, supportRoot: root),
            "a traversal component must not resolve to residue in another root")
    }

    /// Defense in depth: even handed a live path explicitly, the executor refuses rather than
    /// skipping, so a future change that widens the enumeration fails loudly here.
    func testReclaimRefusesANonResidueTargetEvenWhenAskedDirectly() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let live = root.appendingPathComponent("library.db")
        try write(2_048, to: live)
        XCTAssertThrowsError(
            try RuntimeResidueReclaimService.reclaim(supportRoot: root, targets: [live])
        ) { error in
            XCTAssertEqual(
                error as? RuntimeResidueReclaimError, .notResidue("library.db"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
    }

    // MARK: - What it must actually do

    /// The real thing, against the real Trash, in the shape the live machine has: a build-keyed
    /// `runtime-resources` tree beside the service's SQLite stores, with live data alongside.
    func testReclaimReleasesTheResidueAndLeavesLiveDataUntouched() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = FileManager.default

        // Two build-keyed staging directories, as `runtime-resources/` accumulates them.
        try write(16_384, to: root.appendingPathComponent(
            "runtime-resources/149-1b85b0d5b65f8098/Resources/node"))
        try write(16_384, to: root.appendingPathComponent(
            "runtime-resources/150-1a1df8c025c2b63e/Resources/node"))
        try write(8_192, to: root.appendingPathComponent("runtime/runtime-control.sqlite3"))
        try write(4_096, to: root.appendingPathComponent("runtime/app-projection-inbox.sqlite3"))
        try write(0, to: root.appendingPathComponent("runtime-service.sqlite"))

        // Live storage that must survive.
        let library = root.appendingPathComponent("library.db")
        let media = root.appendingPathComponent("conversation-media/live.png")
        let codex = root.appendingPathComponent("codex/sessions/one.jsonl")
        try write(32_768, to: library)
        try write(8_192, to: media)
        try write(8_192, to: codex)

        let report = try RuntimeResidueReclaimService.reclaim(supportRoot: root)
        // This exercises the real Trash, so it puts its own debris back rather than accumulating a
        // set per gate run in the developer's Trash.
        addTeardownBlock {
            for url in report.trashedURLs { try? FileManager.default.removeItem(at: url) }
        }

        XCTAssertEqual(
            Set(report.releasedNames),
            ["runtime-resources", "runtime", "runtime-service.sqlite"])
        XCTAssertGreaterThanOrEqual(
            report.releasedBytes, 44_000,
            "bytes must be summed across the nested tree, not just the top-level entries")
        XCTAssertFalse(manager.fileExists(
            atPath: root.appendingPathComponent("runtime-resources").path))
        XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent("runtime").path))

        for survivor in [library, media, codex] {
            XCTAssertTrue(
                manager.fileExists(atPath: survivor.path),
                "\(survivor.lastPathComponent) is live storage and must survive the reclaim")
        }
    }

    /// Running twice must be safe and silent. The first pass takes everything; the second finds
    /// nothing and reports empty, so nothing is announced on every subsequent launch.
    func testASecondPassFindsNothingAndReportsEmpty() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        try write(8_192, to: root.appendingPathComponent("runtime/runtime-control.sqlite3"))

        let first = try RuntimeResidueReclaimService.reclaim(supportRoot: root)
        addTeardownBlock {
            for url in first.trashedURLs { try? FileManager.default.removeItem(at: url) }
        }
        XCTAssertFalse(first.isEmpty)

        let second = try RuntimeResidueReclaimService.reclaim(supportRoot: root)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(second.releasedNames, [])
    }

    /// An empty residue directory is zero bytes. Moving it is fine; announcing "Zero KB released"
    /// on every launch is not, which is what `isEmpty` guards.
    func testAnEmptyResidueDirectoryIsNotWorthAnnouncing() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("runtime-resources", isDirectory: true),
            withIntermediateDirectories: true)

        let report = try RuntimeResidueReclaimService.reclaim(supportRoot: root)
        addTeardownBlock {
            for url in report.trashedURLs { try? FileManager.default.removeItem(at: url) }
        }
        XCTAssertEqual(report.releasedNames, ["runtime-resources"])
        XCTAssertEqual(report.releasedBytes, 0)
        XCTAssertTrue(report.isEmpty, "zero bytes must not be announced")
    }

    /// Nothing to do on a support root that never ran the reverted design.
    func testACleanRootYieldsNoTargets() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(RuntimeResidueReclaimPolicy.residueTargets(supportRoot: root), [])
        let report = try RuntimeResidueReclaimService.reclaim(supportRoot: root)
        XCTAssertTrue(report.isEmpty)
    }
}
