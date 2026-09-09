import AppKit
import Foundation

/// Four Services entries, in one `Mechanician` submenu: text selected in any app becomes a
/// conversation or joins the one on screen, and a Finder selection becomes a workspace or a set of
/// attachments. The `/` in the plist's `NSMenuItem` title is what creates that submenu; Mail ships
/// `"Mail/New Email With Selection"` the same way.
///
/// **Send-only. No `NSReturnTypes` on any entry, ever.** A returning service is a synchronous
/// transformation that blocks the calling app's UI until we hand text back. The only text producer
/// here is an agent turn, which takes minutes, needs permission prompts, and can fail. A "Rewrite
/// With Mechanician" service is architecturally wrong for this app until there is a fast local path.
///
/// **Nothing here submits.** The gesture picked a destination, not a prompt, and text selected off a
/// web page is material rather than an instruction. The routes these build —
/// `newConversationDraft` and `appendToComposer` — cannot submit; the case that can
/// (`newConversation(sending:)`) is never named in this file.
///
/// The `error` out-parameter is not user-facing: AppKit writes it to the system log, not to a
/// dialog. It is filled for diagnostics, and its strings are deliberately not part of the copy
/// review because no one reads them in the app.
@MainActor
final class MechanicianServiceProvider: NSObject {
    /// Registered on `NSApp` at launch. A Services message cannot arrive before AppKit has finished
    /// launching, but every handler still routes through `ActiveWorkspace`, which parks work when no
    /// window is ready — a service can be the reason the app launched at all.
    static let shared = MechanicianServiceProvider()

    // MARK: - Text

    @objc func newConversationWithSelection(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = Self.selectedText(on: pasteboard) else {
            error.pointee = "No text in the selection." ; return
        }
        ActiveWorkspace.shared.open(.newConversationDraft(text))
    }

    @objc func addSelectionToConversation(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = Self.selectedText(on: pasteboard) else {
            error.pointee = "No text in the selection." ; return
        }
        // No target: a Services selection joins whatever is on screen, unlike a link, which names
        // the conversation it means.
        ActiveWorkspace.shared.open(.appendToComposer(text, conversationID: nil))
    }

    // MARK: - Finder

    /// Every folder in the selection, not just the first.
    ///
    /// Finder offers a service against the selection as a whole, so a folder plus a `.png` shows
    /// this item *and* Add Files to Conversation. Each takes its own half and neither drops anything
    /// silently — acting on one folder and ignoring the rest is the failure mode worth avoiding,
    /// because nothing on screen would say it happened.
    @objc func openFolderAsWorkspace(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let folders = Self.selectedFileURLs(on: pasteboard)
            .compactMap { WorkspaceFolderPath.canonical($0.path) }
        guard !folders.isEmpty else {
            error.pointee = "No folder in the selection." ; return
        }
        for folder in folders {
            guard let project = WorkspaceFolderPath.project(forCanonicalPath: folder) else { continue }
            ActiveWorkspace.shared.open(.workspace(project))
        }
    }

    @objc func addFilesToConversation(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        // The complement of the folder service: whatever it did not take. `.files` already filters
        // to existing file URLs, so this only has to exclude directories.
        let files = Self.selectedFileURLs(on: pasteboard).filter { !WorkspaceFolderPath.isDirectory($0.path) }
        guard !files.isEmpty else {
            error.pointee = "No files in the selection." ; return
        }
        ActiveWorkspace.shared.open(.files(files))
    }

    // MARK: - Pasteboard reading

    /// The selection as plain text, or nil when there is nothing usable. See `InboundComposerText`
    /// for the scrub-and-cap rule, which the `mechanician://` link path shares.
    nonisolated static func selectedText(on pasteboard: NSPasteboard) -> String? {
        pasteboard.string(forType: .string).flatMap(InboundComposerText.sanitized)
    }

    nonisolated static func selectedFileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        return objects.filter { $0.isFileURL }
    }
}

/// Text handed to a composer by something outside the app — a Services selection, or the `text`
/// query on a `mechanician://` link.
///
/// One rule, two callers, deliberately: these are the two doors foreign text comes through, and a
/// second copy of the rule is how one of them ends up unscrubbed.
enum InboundComposerText {
    /// More text than anyone meant as a message — a select-all in a long document, say.
    ///
    /// Truncation rather than refusal, because truncation is the *visible* failure: the text lands
    /// in the composer where its length can be seen. Refusing looks identical to the app ignoring
    /// you, and neither door here can raise a dialog to say otherwise.
    static let characterLimit = 100_000

    /// Capped, scrubbed, and `nil` if nothing usable is left.
    ///
    /// The scrub matters more here than at paste: `ConversationFileReference.matches` decodes
    /// attachment tokens out of plain text with no authentication, so a token arriving from another
    /// app — or from a web page's link — is a reference somebody else chose.
    ///
    /// Whitespace-only reads as nothing. An empty draft in a focused composer is indistinguishable
    /// from the request having silently failed.
    static func sanitized(_ raw: String) -> String? {
        let capped = raw.count > characterLimit ? String(raw.prefix(characterLimit)) : raw
        let text = ComposerTokenScrub.neutralizingForgedTokens(capped)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

/// Normalizing a folder path that arrived from outside the app.
///
/// `ProjectStore.projectID(forCwd:)` matches on an **exact trimmed string** and mints a new Project
/// otherwise. A Services payload is a raw path, so without this `~/dev/x`, `/dev/x/`, and the
/// firmlinked `/System/Volumes/Data/Users/…/dev/x` would each mint a duplicate workspace with its
/// own window, pointing at one folder.
///
/// Two steps, because neither is sufficient alone — both measured on macOS 27 rather than assumed:
///
/// - `resolvingSymlinksInPath` follows an actual symlink to its target. `canonicalPath` does **not**;
///   a symlinked folder comes back under its own name, which is a duplicate workspace waiting to
///   happen.
/// - `canonicalPath` collapses the firmlinked `/System/Volumes/Data/Users/…` spelling back to the
///   conventional `/Users/…` form — rather than expanding the other way, which would have made every
///   normalized path *miss* the workspaces already stored. That is what makes it safe to store.
///
/// Both deliberately leave `/tmp`, `/var`, and `/etc` alone, which is the documented AppKit behavior
/// and the reason a temporary directory keeps its `/private` prefix here.
enum WorkspaceFolderPath {
    static func isDirectory(_ path: String, fileManager: FileManager = .default) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    /// One spelling for one folder, or nil when the path is not an existing directory.
    static func canonical(_ raw: String, fileManager: FileManager = .default) -> String? {
        let expanded = (raw as NSString).expandingTildeInPath
        guard !expanded.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL
        guard isDirectory(standardized.path, fileManager: fileManager) else { return nil }
        let resolved = standardized.resolvingSymlinksInPath()
        if let canonical = try? resolved.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath,
           !canonical.isEmpty {
            return canonical
        }
        return resolved.path
    }

    /// The workspace for a folder: an existing one whose stored `cwd` names the same folder however
    /// it was spelled at the time, else a new one recorded under the canonical spelling.
    ///
    /// Matching canonicalizes **both** sides. A project stored years ago under an odd spelling still
    /// matches, which is the whole point — normalizing only the incoming path would swap one
    /// duplicate-minting bug for another.
    /// A default argument would be evaluated outside the main actor, so the production spelling is a
    /// wrapper rather than `store: ProjectStore = .shared`.
    @MainActor static func project(forCanonicalPath path: String) -> UUID? {
        project(forCanonicalPath: path, store: .shared)
    }

    @MainActor static func project(forCanonicalPath path: String, store: ProjectStore) -> UUID? {
        if let existing = store.projects.first(where: {
            !$0.cwd.isEmpty && canonical($0.cwd) == path
        }) {
            return existing.id
        }
        return store.projectID(forCwd: path)
    }
}
