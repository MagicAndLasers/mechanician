import Darwin
import Foundation

/// The one implementation of "this directory must be private to the user who owns it".
///
/// This rule had four independent implementations: the storage-authority root privacy helper, an
/// identical `require`/`prepare` pair duplicated across `LibraryBackupLifecycle` *and*
/// `LibraryBackupService`, and a third variant in `SQLiteLibraryStore`. Two of them were taught to
/// repair rather than refuse after a refusal stranded machines at launch; the others were not,
/// because each was believed unreachable. That reasoning has now failed twice. One rule, in one
/// place, with the repair-versus-refuse distinction made explicit at every call site.
///
/// The distinction is the whole point, and it is about **ownership, not severity**:
///
/// * `makePrivateReason` — for a directory this app creates and owns. Repair it. The data is
///   already sitting there at whatever `createDirectory` left under the process umask, which is
///   0755, so refusing protects nothing and only refuses to launch.
/// * `requireReason` — for a directory this app merely writes *into*, such as the parent of the
///   support root. Refuse. `~/Library/Application Support` is shared by every app on the machine
///   and silently tightening it is overreach, not a fix.
/// * Evidence being verified — an existing backup generation, a manifest — also uses
///   `requireReason`. Mutating something while checking whether it is intact destroys the thing the
///   check is for.
///
/// Both use `lstat`, so a symlink is never mistaken for the directory it points at.
enum OwnerOnlyDirectory {
    /// Makes a directory this app owns private to this user, or says why it cannot be.
    ///
    /// Returns nil when the directory is private, has been made private, or does not exist —
    /// callers that require existence create it first, and a missing directory is not a permission
    /// problem. `label` is the caller's noun for the directory and leads the message.
    static func makePrivateReason(_ url: URL, label: String) -> String? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            return errno == ENOENT ? nil : "\(label) could not be inspected"
        }
        guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid() else {
            return "\(label) is not a directory this user owns"
        }
        guard status.st_mode & 0o077 != 0 else { return nil }
        // Re-stat after the chmod rather than trusting it: `chmod` follows symlinks, and the only
        // thing that makes that safe is proving afterwards that what we changed is still the
        // owned, non-symlink directory we looked at.
        guard chmod(url.path, 0o700) == 0,
              lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0 else {
            return "\(label) could not be made private to this user"
        }
        return nil
    }

    /// Checks a directory this app does not own, or is verifying rather than preparing.
    ///
    /// Names the path and the mode it actually found. The previous message said only that the
    /// directory "must be a 0700 non-symlink directory", which cannot be acted on without reading
    /// the source — the same diagnosability gap the activation gate had. It deliberately does not
    /// suggest a `chmod`: the parent that trips this can be a system directory such as
    /// `/private/tmp`, where following that advice would be worse than the failure.
    static func requireReason(_ url: URL, label: String) -> String? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            return "\(label) could not be inspected: \(url.path)"
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            return "\(label) is not a directory: \(url.path)"
        }
        guard status.st_mode & 0o077 == 0 else {
            let mode = String(status.st_mode & 0o7777, radix: 8)
            return "\(label) must be a directory only you can open, "
                + "but \(url.path) is mode 0\(mode)"
        }
        return nil
    }
}
