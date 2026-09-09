import Foundation
import XCTest
@testable import Mechanician

/// The owner-only directory rule, and the distinction that used to be lost between its four copies.
///
/// The rule was hand-written in four places. Two were taught to repair rather than refuse after a
/// refusal stranded machines at launch; the other two were left refusing because they were believed
/// unreachable. One of those sat at the end of every migration. Whether a directory is repaired or
/// refused is now a decision made at the call site, against one implementation.
final class OwnerOnlyDirectoryTests: XCTestCase {
    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "owner-only-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        return base
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: - Repair, for directories the app owns

    /// The case that stranded machines: a directory left at the process umask's 0755. The data is
    /// already sitting there at those permissions, so refusing protects nothing.
    func testAnOwnedDirectoryIsTightenedRatherThanRefused() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)

        XCTAssertNil(OwnerOnlyDirectory.makePrivateReason(root, label: "support root"))
        XCTAssertEqual(try mode(root), 0o700, "the directory must actually have been repaired")
    }

    /// A directory that is missing is not a permission problem. Callers that need it create it.
    func testAMissingDirectoryIsNotAProblem() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertNil(OwnerOnlyDirectory.makePrivateReason(
            base.appendingPathComponent("absent", isDirectory: true), label: "support root"))
    }

    /// Repair must never follow a symlink. `lstat` sees the link itself, so this is refused rather
    /// than silently chmodding whatever it points at.
    func testASymlinkIsRefusedRatherThanFollowed() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertNotNil(OwnerOnlyDirectory.makePrivateReason(link, label: "support root"))
        XCTAssertEqual(try mode(target), 0o755, "the symlink's target must not have been touched")
    }

    /// The message wording is the one 0.25.3 shipped, because it reaches users on a blocked launch.
    func testTheSupportRootWordingIsUnchanged() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("not-a-directory", isDirectory: false)
        try Data().write(to: file)
        XCTAssertEqual(
            StorageAuthorityRootPrivacy.makePrivateReason(file),
            "support root is not a directory this user owns")
    }

    // MARK: - Refuse, for directories the app does not own

    func testACheckedDirectoryNamesThePathAndTheModeItFound() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let parent = base.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)

        let reason = OwnerOnlyDirectory.requireReason(parent, label: "backup parent")
        let unwrapped = try XCTUnwrap(reason)
        XCTAssertTrue(unwrapped.contains(parent.path), "must name the directory: \(unwrapped)")
        XCTAssertTrue(unwrapped.contains("0755"), "must report the mode found: \(unwrapped)")
        XCTAssertEqual(try mode(parent), 0o755, "a checked directory must not be modified")
    }

    func testACheckedDirectoryPassesWhenItIsAlreadyPrivate() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertNil(OwnerOnlyDirectory.requireReason(base, label: "backup parent"))
    }

    // MARK: - The backup path, which carried two of the four copies

    /// A backup used to refuse outright when the support root was not already 0700 — the same check
    /// that stranded a machine at launch, in a path the 0.25.3 fix did not reach. It survived only
    /// because recognition happens to repair the root earlier in launch.
    func testABackupRepairsTheSupportRootInsteadOfRefusing() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let sourceRoot = base.appendingPathComponent("Mechanician", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        _ = try SQLiteLibraryStore(supportRoot: sourceRoot)
        // Loosen it after the store has built its database, the way a restore or a stray chmod
        // would leave it on a real machine.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: sourceRoot.path)

        let result = try LibraryBackupLifecycle.createBackupIfDue(
            sourceSupportRoot: sourceRoot,
            now: Date(timeIntervalSince1970: 1_787_000_000),
            backupID: UUID())

        XCTAssertEqual(result.disposition, .created)
        XCTAssertEqual(try mode(sourceRoot), 0o700, "the support root should have been repaired")
    }

    /// The parent is not ours to repair. `~/Library/Application Support` is shared with every other
    /// app, so a backup refuses rather than tightening it — and says which directory it means.
    func testABackupRefusesAParentItDoesNotOwnAndNamesIt() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let sourceRoot = base.appendingPathComponent("Mechanician", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        _ = try SQLiteLibraryStore(supportRoot: sourceRoot)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.path)

        XCTAssertThrowsError(try LibraryBackupLifecycle.createBackupIfDue(
            sourceSupportRoot: sourceRoot,
            now: Date(timeIntervalSince1970: 1_787_000_000),
            backupID: UUID())
        ) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains(base.path), "must name the parent: \(message)")
            XCTAssertTrue(message.contains("0755"), "must report the mode found: \(message)")
        }
        XCTAssertEqual(try mode(base), 0o755, "the shared parent must not have been modified")
    }
}
