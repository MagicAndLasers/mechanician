import Foundation
import XCTest
@testable import Mechanician

/// These files are somebody's rollback material and one of them is the only surviving copy of a
/// library the current build can no longer open. So most of what matters here is what it declines
/// to do.
final class SupersededAuthorityReclaimTests: XCTestCase {

    private let day: TimeInterval = 24 * 60 * 60

    private func makeRoot() throws -> (base: URL, root: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("superseded-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Mechanician", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (base, root)
    }

    private func write(_ bytes: Int, _ name: String, in root: URL) throws {
        try Data(repeating: 5, count: bytes)
            .write(to: root.appendingPathComponent(name))
    }

    /// A copy plus its journals, as an upgrade actually leaves them.
    private func makeCopy(
        version: Int, stamp: String, bytes: Int = 4_096, sidecars: Bool = true, in root: URL
    ) throws -> String {
        let name = "library.db.superseded-v\(version)-\(stamp)"
        try write(bytes, name, in: root)
        if sidecars {
            try write(512, name + "-wal", in: root)
            try write(256, name + "-shm", in: root)
        }
        return name
    }

    private func date(_ stamp: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.date(from: stamp)!
    }

    // MARK: - What it must never touch

    /// The single most important assertion in this file.
    func testTheLiveLibraryIsNeverACandidate() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        try write(65_536, "library.db", in: root)
        try write(4_096, "library.db-wal", in: root)
        try write(1_024, "library.db-shm", in: root)
        try write(4_096, "projections.db", in: root)
        _ = try makeCopy(version: 12, stamp: "20260823T180634Z", in: root)

        let copies = SupersededAuthorityReclaimPolicy.copies(supportRoot: root)
        XCTAssertEqual(copies.map { $0.url.lastPathComponent },
                       ["library.db.superseded-v12-20260823T180634Z"])
        for live in ["library.db", "library.db-wal", "library.db-shm", "projections.db"] {
            XCTAssertFalse(
                copies.contains { $0.url.lastPathComponent == live },
                "\(live) is the live authority and must never be a reclaim candidate")
        }
    }

    /// Anything this code did not write is left alone, because "unparseable" means somebody else
    /// put it there.
    func testUnrecognizedNamesAreNeverReleased() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        for name in [
            "library.db.superseded",                        // no version or stamp
            "library.db.superseded-v12",                    // no stamp
            "library.db.superseded-v12-20260823",           // truncated stamp
            "library.db.superseded-vXX-20260823T180634Z",   // non-numeric version
            "library.db.superseded-v12-20260823T180634Z.bak",  // suffixed by hand
            "my-library.db.superseded-v12-20260823T180634Z",   // different database
            "library.db.backup-v12-20260823T180634Z",       // not a superseded copy
        ] {
            try write(2_048, name, in: root)
        }
        XCTAssertEqual(SupersededAuthorityReclaimPolicy.copies(supportRoot: root), [])
    }

    /// A stamp that is well-formed but not a real date must not resolve to some nearby date and
    /// then be aged against the soak.
    func testAnImpossibleDateIsNotParsedIntoACandidate() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        try write(2_048, "library.db.superseded-v12-20261345T997061Z", in: root)
        XCTAssertEqual(SupersededAuthorityReclaimPolicy.copies(supportRoot: root), [])
    }

    /// If the library is not the recognized active authority, somebody may be about to recover from
    /// one of these. Rule 1's proof does not matter at that moment.
    func testNothingIsReleasedWhileTheAuthorityIsNotActive() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try makeCopy(version: 6, stamp: "20260814T175651Z", in: root)
        _ = try makeCopy(version: 7, stamp: "20260814T231234Z", in: root)

        XCTAssertEqual(
            SupersededAuthorityReclaimPolicy.releasable(
                supportRoot: root, authorityIsActive: false,
                now: date("20260831T180000Z")),
            [])
    }

    /// Defense in depth: handed something that is not a parseable copy, the executor refuses rather
    /// than skipping.
    func testReclaimRefusesATargetItDidNotRecognize() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        try write(65_536, "library.db", in: root)
        let impostor = SupersededAuthorityCopy(
            url: root.appendingPathComponent("library.db"),
            schemaVersion: 13, supersededAt: date("20260101T000000Z"), sidecarURLs: [])

        XCTAssertThrowsError(
            try SupersededAuthorityReclaimService.reclaim(
                supportRoot: root, authorityIsActive: true, targets: [impostor])
        ) { error in
            XCTAssertEqual(
                error as? SupersededAuthorityReclaimError, .notASupersededCopy("library.db"))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("library.db").path))
    }

    // MARK: - Rule 1: a successor is proof

    func testACopyWithANewerSiblingIsReleasedAndTheNewestIsKept() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try makeCopy(version: 6, stamp: "20260814T175651Z", in: root)
        _ = try makeCopy(version: 7, stamp: "20260814T231234Z", in: root)
        _ = try makeCopy(version: 8, stamp: "20260817T141644Z", in: root)

        // One day after the newest: inside the soak, so rule 2 does not fire.
        let releasable = SupersededAuthorityReclaimPolicy.releasable(
            supportRoot: root, authorityIsActive: true, now: date("20260818T141644Z"))
        XCTAssertEqual(
            releasable.map { $0.schemaVersion }, [6, 7],
            "every copy with a successor is released; the newest is kept until it ages")
    }

    /// Order is chronological, not by version. Restoring a copy and upgrading again produces two
    /// files carrying the same version, and only the timestamp orders them.
    func testOrderingIsChronologicalSoARepeatedVersionCannotHideTheNewest() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try makeCopy(version: 12, stamp: "20260823T180634Z", in: root)
        _ = try makeCopy(version: 12, stamp: "20260825T090000Z", in: root)
        _ = try makeCopy(version: 11, stamp: "20260824T090000Z", in: root)

        let copies = SupersededAuthorityReclaimPolicy.copies(supportRoot: root)
        XCTAssertEqual(
            copies.map { $0.url.lastPathComponent },
            ["library.db.superseded-v12-20260823T180634Z",
             "library.db.superseded-v11-20260824T090000Z",
             "library.db.superseded-v12-20260825T090000Z"])
        let releasable = SupersededAuthorityReclaimPolicy.releasable(
            supportRoot: root, authorityIsActive: true, now: date("20260826T090000Z"))
        XCTAssertEqual(
            releasable.map { $0.url.lastPathComponent },
            ["library.db.superseded-v12-20260823T180634Z",
             "library.db.superseded-v11-20260824T090000Z"],
            "the newest by time is kept even though a higher version number sits below it")
    }

    // MARK: - Rule 2: the newest is aged

    func testTheLastCopyIsKeptInsideTheSoakAndReleasedAfterIt() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try makeCopy(version: 12, stamp: "20260823T180634Z", in: root)
        let superseded = date("20260823T180634Z")

        XCTAssertEqual(
            SupersededAuthorityReclaimPolicy.releasable(
                supportRoot: root, authorityIsActive: true,
                now: superseded.addingTimeInterval(6 * day)),
            [],
            "six days in, the replacing schema has not yet proved itself")

        XCTAssertEqual(
            SupersededAuthorityReclaimPolicy.releasable(
                supportRoot: root, authorityIsActive: true,
                now: superseded.addingTimeInterval(7 * day)).map { $0.schemaVersion },
            [12],
            "the soak is a week of ordinary use, and it has elapsed")
    }

    /// A clock that moved backwards must not look like a completed soak.
    func testAFutureDatedCopyIsNotTreatedAsAged() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try makeCopy(version: 12, stamp: "20260901T000000Z", in: root)
        XCTAssertEqual(
            SupersededAuthorityReclaimPolicy.releasable(
                supportRoot: root, authorityIsActive: true, now: date("20260831T000000Z")),
            [])
    }

    // MARK: - Doing it

    /// The real thing against the real Trash, in the shape the developer machine actually had:
    /// seven copies from two weeks of schema bumps, the newest already past the soak.
    func testReleasesTheRealWorldBacklogWithJournalsAndLeavesLiveDataUntouched() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = FileManager.default
        try write(65_536, "library.db", in: root)
        try write(8_192, "projections.db", in: root)
        for (version, stamp) in [
            (6, "20260814T175651Z"), (7, "20260814T231234Z"), (8, "20260817T141644Z"),
            (9, "20260823T140444Z"), (10, "20260823T154147Z"), (11, "20260823T164940Z"),
            (12, "20260823T180634Z"),
        ] {
            _ = try makeCopy(version: version, stamp: stamp, bytes: 16_384, in: root)
        }

        let report = try SupersededAuthorityReclaimService.reclaim(
            supportRoot: root, authorityIsActive: true, now: date("20260831T180634Z"))
        addTeardownBlock {
            for url in report.trashedURLs { try? FileManager.default.removeItem(at: url) }
        }

        XCTAssertEqual(report.releasedNames.count, 7, "the newest is eight days old, so all seven go")
        XCTAssertEqual(report.retainedNames, [])
        XCTAssertGreaterThanOrEqual(
            report.releasedBytes, 7 * (16_384 + 512 + 256),
            "journals are counted with their database")
        XCTAssertEqual(SupersededAuthorityReclaimPolicy.copies(supportRoot: root), [])

        // Every journal went with its database. A half-released copy looks restorable and is not.
        let leftovers = try manager.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains("superseded") }
        XCTAssertEqual(leftovers, [], "a torn copy is worse than either keeping or releasing it")

        for live in ["library.db", "projections.db"] {
            XCTAssertTrue(
                manager.fileExists(atPath: root.appendingPathComponent(live).path),
                "\(live) must survive")
        }
    }

    /// The retained copy is named, so a launcher can say what it kept instead of reporting silence
    /// that reads the same as having found nothing.
    func testTheReportNamesWhatItKept() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try makeCopy(version: 6, stamp: "20260814T175651Z", in: root)
        _ = try makeCopy(version: 7, stamp: "20260828T000000Z", in: root)

        let report = try SupersededAuthorityReclaimService.reclaim(
            supportRoot: root, authorityIsActive: true, now: date("20260829T000000Z"))
        addTeardownBlock {
            for url in report.trashedURLs { try? FileManager.default.removeItem(at: url) }
        }
        XCTAssertEqual(report.releasedNames, ["library.db.superseded-v6-20260814T175651Z"])
        XCTAssertEqual(report.retainedNames, ["library.db.superseded-v7-20260828T000000Z"])
    }

    /// Running twice is safe and the second pass says nothing.
    func testASecondPassFindsNothingAndReportsEmpty() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try makeCopy(version: 6, stamp: "20260814T175651Z", in: root)
        _ = try makeCopy(version: 7, stamp: "20260814T231234Z", in: root)

        let first = try SupersededAuthorityReclaimService.reclaim(
            supportRoot: root, authorityIsActive: true, now: date("20260831T000000Z"))
        addTeardownBlock {
            for url in first.trashedURLs { try? FileManager.default.removeItem(at: url) }
        }
        XCTAssertFalse(first.isEmpty)

        let second = try SupersededAuthorityReclaimService.reclaim(
            supportRoot: root, authorityIsActive: true, now: date("20260831T000000Z"))
        XCTAssertTrue(second.isEmpty)
    }

    /// A copy with no journals beside it is normal after a clean checkpoint.
    func testACopyWithNoJournalsIsReleasedCleanly() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try makeCopy(version: 6, stamp: "20260814T175651Z", sidecars: false, in: root)
        _ = try makeCopy(version: 7, stamp: "20260814T231234Z", sidecars: false, in: root)

        let report = try SupersededAuthorityReclaimService.reclaim(
            supportRoot: root, authorityIsActive: true, now: date("20260831T000000Z"))
        addTeardownBlock {
            for url in report.trashedURLs { try? FileManager.default.removeItem(at: url) }
        }
        XCTAssertEqual(report.releasedNames.count, 2)
        XCTAssertEqual(SupersededAuthorityReclaimPolicy.copies(supportRoot: root), [])
    }

    /// A root that has never been upgraded has nothing to do.
    func testACleanRootYieldsNothing() throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        try write(65_536, "library.db", in: root)
        let report = try SupersededAuthorityReclaimService.reclaim(
            supportRoot: root, authorityIsActive: true)
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.retainedNames, [])
    }
}
