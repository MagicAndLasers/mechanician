import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

/// Bounded URL→artifact identity recovery for live drags. Kept as a value type so eviction order and
/// same-artifact rename behavior can be tested without mutating the process-global registry.
struct ArtifactLiveExportIndex {
    private struct Entry {
        let reference: ArtifactDragReference
        let sequence: UInt64
    }

    let maximumCount: Int
    private var nextSequence: UInt64 = 0
    private var entries: [String: Entry] = [:]

    init(maximumCount: Int) {
        self.maximumCount = max(1, maximumCount)
    }

    var count: Int { entries.count }

    mutating func remember(_ reference: ArtifactDragReference, at url: URL) -> [URL] {
        nextSequence &+= 1
        entries[Self.key(url)] = Entry(reference: reference, sequence: nextSequence)

        let overflow = entries.count - maximumCount
        guard overflow > 0 else { return [] }
        let stale = entries
            .sorted { $0.value.sequence < $1.value.sequence }
            .prefix(overflow)
        var evicted: [URL] = []
        for (key, entry) in stale {
            entries[key] = nil
            evicted.append(entry.reference.sourceURL)
        }
        return evicted
    }

    func reference(for url: URL) -> ArtifactDragReference? {
        entries[Self.key(url)]?.reference
    }

    mutating func remove(_ url: URL) {
        entries[Self.key(url)] = nil
        if entries.isEmpty { nextSequence = 0 }
    }

    mutating func prune(root: URL) {
        entries = entries.filter {
            !ArtifactFileExport.contains($0.value.reference.sourceURL, in: root)
        }
        if entries.isEmpty { nextSequence = 0 }
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// User-facing artifact file actions shared by both artifact surfaces (FR-102): dragging an artifact
/// OUT to Finder, opening, sharing, saving, revealing in Finder, and importing dropped files IN.
/// Centralized so the manager window (`GlobalArtifactsView`, standalone store) and the inspector
/// panel (`ArtifactsPanelView`, conversation store) behave identically and never drift — the same
/// lesson as `ArtifactFileExport`.
enum ArtifactActions {
    /// App-private pasteboard representation layered beside the public file URL. Other apps still
    /// receive an ordinary typed file; Mechanician's composer receives durable artifact identity.
    static let referencePasteboardType =
        NSPasteboard.PasteboardType("ai.mechanician.artifact-reference")

    /// Retain the system picker while its service menu is open. A local picker can disappear as the
    /// context menu closes, before AppKit has had a chance to present the sharing-service submenu.
    private static var sharingPicker: NSSharingServicePicker?
    /// SwiftUI's window-level URL drop can resolve the public file representation before it sees the
    /// app-private one. Remember exports created for a live drag so either destination can recover
    /// the same artifact reference rather than degrading it to a detached temporary file.
    static let maximumLiveExportReferences = 128
    private static var liveExportReferences = ArtifactLiveExportIndex(
        maximumCount: maximumLiveExportReferences)

    static var liveExportReferenceCount: Int { liveExportReferences.count }

    /// One dropped file resolved into the fields needed to create an artifact.
    struct Import: Equatable {
        let title: String
        let type: String
        let source: String
    }

    /// The artifact types a user can create by dropping a file — used in the "nothing imported" note.
    static let supportedImportSummary = "html, svg, mermaid, csv, markdown, txt"
    static let maximumImportFiles = 32
    static let maximumImportFileBytes = 8 * 1_024 * 1_024
    static let maximumImportBatchBytes = 32 * 1_024 * 1_024

    /// Read dropped files into importable artifacts. Skips unsupported extensions and non-UTF-8
    /// (binary) files, returning their names so the caller can tell the user honestly what didn't come
    /// in rather than failing silently.
    static func imports(from urls: [URL]) -> (ready: [Import], skipped: [String]) {
        var ready: [Import] = []
        var skipped: [String] = []
        var remainingBytes = maximumImportBatchBytes
        for (index, url) in urls.enumerated() {
            guard index < maximumImportFiles,
                  remainingBytes > 0,
                  let type = ArtifactFileExport.artifactType(forFileExtension: url.pathExtension)
            else {
                skipped.append(url.lastPathComponent)
                continue
            }
            guard let data = boundedRegularFileData(
                at: url,
                maximumBytes: min(maximumImportFileBytes, remainingBytes)) else {
                skipped.append(url.lastPathComponent)
                continue
            }
            remainingBytes -= data.count
            guard let source = String(data: data, encoding: .utf8) else {
                skipped.append(url.lastPathComponent)
                continue
            }
            let base = url.deletingPathExtension().lastPathComponent
            ready.append(Import(title: base.isEmpty ? url.lastPathComponent : base,
                                type: type, source: source))
        }
        return (ready, skipped)
    }

    /// File I/O for a drop never belongs on AppKit's drag event. Keep the synchronous helper for
    /// deterministic unit tests, and give UI surfaces this off-main entry point.
    static func importsAsync(
        from urls: [URL]
    ) async -> (ready: [Import], skipped: [String]) {
        await Task.detached(priority: .userInitiated) {
            imports(from: urls)
        }.value
    }

    /// Open without following a symlink, verify the descriptor is a regular file, and stop before a
    /// file that changes underneath the read can exceed the declared import budget.
    private static func boundedRegularFileData(at url: URL, maximumBytes: Int) -> Data? {
        guard maximumBytes > 0 else { return nil }
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return nil }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= off_t(maximumBytes) else {
            Darwin.close(descriptor)
            return nil
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard remaining > 0 else { break }
            do {
                guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                      !chunk.isEmpty else { break }
                data.append(chunk)
            } catch {
                return nil
            }
        }
        guard data.count <= maximumBytes else { return nil }
        return data
    }

    /// The SF Symbol for an artifact type — shared so the row list, the proxy-icon drag handle, and any
    /// other surface show the same glyph for a given type.
    static func symbol(forType type: String) -> String {
        switch type {
        case "html":     return "globe"
        case "svg":      return "photo"
        case "mermaid":  return "flowchart"
        case "csv":      return "tablecells"
        case "markdown": return "doc.richtext"
        default:         return "doc"
        }
    }

    /// A durable artifact drag carries a typed file for Finder/other apps and an app-private
    /// reference for chat composers. A cache whose UUID no longer exists durably gets only its
    /// ordinary file representation, preserving export without granting artifact identity.
    @MainActor
    static func itemProvider(
        for artifact: Artifact,
        temporaryRoot: URL = ArtifactFileExport.temporaryExportsRoot,
        artifactStore: ArtifactStore? = nil
    ) -> NSItemProvider {
        let artifactStore = artifactStore ?? .shared
        let durableReference = durableExportReference(
            for: artifact.uuid,
            temporaryRoot: temporaryRoot,
            artifactStore: artifactStore)
        let exportedArtifact = artifactStore.artifacts.first {
            $0.uuid == artifact.uuid
        } ?? artifact
        if let url = durableReference?.sourceURL
            ?? (try? exportedFile(
                for: exportedArtifact,
                temporaryRoot: temporaryRoot)),
           let provider = NSItemProvider(contentsOf: url) {
            // Extension-less: the loader appends the registered type's preferred extension when it
            // materializes the file, so passing "Badge.svg" here delivers "Badge.svg.svg".
            provider.suggestedName = url.deletingPathExtension().lastPathComponent
            // A cached conversation preview without an exact durable UUID can still leave the app
            // as an ordinary file. It must not advertise process-trusted artifact identity: doing
            // so would turn arbitrary restored token metadata into authority to link local bytes.
            if durableReference == nil {
                // The same UUID may have had a live export before its durable record was deleted.
                // Do not let that stale mapping reinterpret this plain fallback file as an artifact.
                liveExportReferences.remove(url)
            }
            if let durableReference,
               let data = durableReference.processSignedEncodedData {
                provider.registerDataRepresentation(
                    forTypeIdentifier: referencePasteboardType.rawValue,
                    visibility: .ownProcess
                ) { completion in
                    completion(data, nil)
                    return nil
                }
            }
            return provider
        }
        return NSItemProvider()
    }

    /// A native AppKit table drag cannot return `NSItemProvider` from
    /// `tableView(_:pasteboardWriterForRow:)`. Publish the exact same two representations as a
    /// pasteboard item instead: an ordinary typed file URL for Finder and other apps, plus the
    /// process-private signed artifact reference understood by Mechanician composers.
    @MainActor
    static func pasteboardItem(
        for artifact: Artifact,
        temporaryRoot: URL = ArtifactFileExport.temporaryExportsRoot,
        artifactStore: ArtifactStore? = nil
    ) -> NSPasteboardItem? {
        guard let reference = durableExportReference(
            for: artifact.uuid,
            temporaryRoot: temporaryRoot,
            artifactStore: artifactStore) else {
            return nil
        }

        let item = NSPasteboardItem()
        item.setString(reference.sourceURL.absoluteString, forType: .fileURL)
        if let privateData = reference.processSignedEncodedData {
            item.setData(privateData, forType: referencePasteboardType)
        }
        return item
    }

    /// Resolve one exact durable artifact and materialize its current source for a native drag.
    /// Both the private UTI and the live public-file recovery table must originate here so neither
    /// can accidentally authenticate a path carried only by a serialized conversation token.
    @MainActor
    static func durableExportReference(
        for artifactID: UUID,
        temporaryRoot: URL = ArtifactFileExport.temporaryExportsRoot,
        artifactStore: ArtifactStore? = nil
    ) -> ArtifactDragReference? {
        let artifactStore = artifactStore ?? .shared
        guard let durableArtifact = artifactStore.artifacts.first(where: {
            $0.uuid == artifactID
        }),
              let url = try? exportedFile(
                for: durableArtifact,
                temporaryRoot: temporaryRoot) else {
            return nil
        }
        let reference = ArtifactDragReference(
            artifact: durableArtifact,
            sourceURL: url)
        rememberLiveExport(reference, at: url)
        return reference
    }

    /// Decode app-private representations from a native drag pasteboard. One artifact is the common
    /// case, but preserving item order makes multi-selection drags work if either panel adds them.
    static func references(from pasteboard: NSPasteboard) -> [ArtifactDragReference] {
        var itemReferences: [ArtifactDragReference] = []
        for item in (pasteboard.pasteboardItems ?? [])
            .prefix(maximumLiveExportReferences) {
            guard let data = item.data(forType: referencePasteboardType),
                  let reference = ArtifactDragReference.decodeProcessPrivate(data) else { continue }
            itemReferences.append(reference)
        }
        if !itemReferences.isEmpty { return itemReferences }

        // SwiftUI can bridge a single NSItemProvider directly onto the dragging pasteboard without
        // exposing `pasteboardItems` during every lifecycle callback. The pasteboard-level accessor
        // still resolves the advertised representation at perform time.
        guard let data = pasteboard.data(forType: referencePasteboardType),
              let reference = ArtifactDragReference.decodeProcessPrivate(data) else { return [] }
        return [reference]
    }

    /// Recover identity when a SwiftUI ancestor accepted the drag's public file URL representation.
    @MainActor
    static func reference(forExportedURL url: URL) -> ArtifactDragReference? {
        guard let reference = liveExportReferences.reference(for: url) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            liveExportReferences.remove(url)
            return nil
        }
        return reference
    }

    /// Expand compact, UI-renderable reference tokens only at the provider boundary. This keeps
    /// conversation JSON and transcript bubbles small and readable while giving every provider lane
    /// the latest complete source without relying on that lane being allowed to read `/tmp`.
    @MainActor
    static func providerPrompt(
        from prompt: String,
        artifactStore: ArtifactStore? = nil
    ) -> String {
        let matches = ArtifactDragReference.matches(in: prompt)
        guard !matches.isEmpty else { return prompt }
        let artifacts = (artifactStore ?? .shared).artifacts

        let expanded = NSMutableString(string: prompt)
        for match in matches.reversed() {
            let reference = match.reference
            let exact = artifacts.first {
                $0.uuid == reference.artifactID
            }
            let replacement: String
            if let exact {
                // UUID is identity. All provider-facing metadata and source come from the durable
                // record, never from token-supplied title/type/path fields.
                let durableReference = ArtifactDragReference(
                    artifactID: exact.uuid,
                    title: exact.title,
                    type: exact.type,
                    currentSourcePath: "")
                replacement = durableReference.providerContext(
                    currentSource: exact.source)
            } else {
                replacement = "[Artifact unavailable. Attach it again]"
            }
            expanded.replaceCharacters(
                in: match.range,
                with: replacement)
        }
        return expanded as String
    }

    /// Materialize the artifact as the same typed file used by drag, share, open, and reveal.
    /// Internal (rather than private) so the non-UI contract can be covered by unit tests.
    static func exportedFile(
        for artifact: Artifact,
        temporaryRoot: URL = ArtifactFileExport.temporaryExportsRoot
    ) throws -> URL {
        try ArtifactFileExport.temporaryFile(for: artifact, root: temporaryRoot)
    }

    /// Bound the process-local URL recovery table even during a long session. Files whose identity
    /// mapping ages out stay alive until the session-level export prune: they may still back a
    /// Finder drag that began before a later multi-item drag filled the identity cache.
    @MainActor
    private static func rememberLiveExport(_ reference: ArtifactDragReference, at url: URL) {
        _ = liveExportReferences.remember(reference, at: url)
    }

    /// Launch/quit pruning owns both halves of the temporary session: disk files and URL→identity
    /// recovery entries. The root parameter keeps focused tests isolated from other app instances.
    @MainActor
    static func pruneTemporaryExports(
        root: URL = ArtifactFileExport.temporaryExportsRoot
    ) {
        ArtifactFileExport.removeTemporaryExports(root: root)
        liveExportReferences.prune(root: root)
    }

    /// Open the exported artifact in the user's default app for its file type.
    static func openInDefaultApp(_ artifact: Artifact) {
        guard let url = try? exportedFile(for: artifact) else {
            presentError(
                String(localized: "Couldn’t Open Artifact"),
                String(localized: "Mechanician could not write a temporary file for this artifact."))
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func openInDefaultApp(_ artifacts: [Artifact]) {
        artifacts.forEach(openInDefaultApp)
    }

    /// Present the native macOS sharing-service picker, anchored where the context-menu action was
    /// invoked. Deferring one run loop lets the context menu close before its replacement appears.
    static func share(_ artifact: Artifact) {
        share([artifact])
    }

    /// Share one or more artifacts through the services installed on this Mac. A native browser
    /// passes the clicked row so the picker is visually attached to its file; the older SwiftUI
    /// surfaces fall back to the mouse location in the active window.
    static func share(_ artifacts: [Artifact], relativeTo anchorView: NSView? = nil) {
        guard !artifacts.isEmpty else { return }
        let urls: [URL]
        do {
            urls = try artifacts.map { try exportedFile(for: $0) }
        } catch {
            presentError(String(localized: "Couldn’t Share Artifact"), error.localizedDescription)
            return
        }
        guard let window = anchorView?.window ?? NSApp.keyWindow ?? NSApp.mainWindow,
              let contentView = window.contentView else {
            presentError(
                String(localized: "Couldn’t Share Artifact"),
                String(localized: "Mechanician could not find a window for the Share menu."))
            return
        }

        let picker = NSSharingServicePicker(items: urls)
        sharingPicker = picker
        let sourceView = anchorView ?? contentView
        let anchor: NSRect
        if anchorView != nil {
            anchor = sourceView.bounds
        } else {
            let mouseInView = contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            anchor = NSRect(origin: mouseInView, size: NSSize(width: 1, height: 1))
        }
        DispatchQueue.main.async {
            guard sharingPicker === picker else { return }
            picker.show(relativeTo: anchor, of: sourceView, preferredEdge: .maxY)
        }
    }

    /// Write an artifact to a user-chosen file (shares filename/extension policy with drag-out).
    static func save(_ artifact: Artifact) {
        let panel = NSSavePanel()
        panel.title = "Save Artifact"
        panel.prompt = "Save"
        panel.nameFieldStringValue = ArtifactFileExport.filename(for: artifact)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let type = UTType(filenameExtension: ArtifactFileExport.fileExtension(for: artifact.type)) {
            panel.allowedContentTypes = [type]
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try ArtifactFileExport.write(artifact, to: url)
            } catch {
                presentError(String(localized: "Couldn’t Save Artifact"), error.localizedDescription)
            }
        }
    }

    /// Render an HTML artifact through the same locked-down document as its preview and save the
    /// finished page as a PDF. PDF export is intentionally HTML-only until the other artifact
    /// types have canonical printable renderers.
    @MainActor
    static func saveAsPDF(_ artifact: Artifact) {
        let panel = NSSavePanel()
        panel.title = "Save Artifact as PDF"
        panel.prompt = "Save"
        panel.nameFieldStringValue = ArtifactPDFExport.filename(for: artifact)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.pdf]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await ArtifactPDFExport.write(artifact, to: url)
                } catch {
                    presentError(String(localized: "Couldn’t Save PDF"), error.localizedDescription)
                }
            }
        }
    }

    /// Reveal an artifact in Finder by exporting it to its stable temp file and selecting it — an
    /// artifact has no canonical on-disk location, so "reveal" targets the same file drag-out uses.
    static func revealInFinder(_ artifact: Artifact) {
        revealInFinder([artifact])
    }

    static func revealInFinder(_ artifacts: [Artifact]) {
        guard !artifacts.isEmpty,
              let urls = try? artifacts.map({ try exportedFile(for: $0) }),
              urls.count == artifacts.count else {
            presentError(
                String(localized: "Couldn’t Reveal Artifact"),
                String(localized: "Mechanician could not write a temporary file for this artifact."))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func copySource(_ artifact: Artifact) {
        copySources([artifact])
    }

    static func copySources(_ artifacts: [Artifact]) {
        guard !artifacts.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            artifacts.map(\.source).joined(separator: "\n\n"),
            forType: .string)
    }

    /// Finder-style Copy for virtual artifact files. Pasting into Finder writes the exported files;
    /// pasting into a Mechanician composer retains durable artifact identity.
    @MainActor
    static func copyFiles(_ artifacts: [Artifact]) {
        let items = artifacts.compactMap { pasteboardItem(for: $0) }
        guard items.count == artifacts.count, !items.isEmpty else {
            reportCopyFailure(count: artifacts.count)
            return
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects(items) else {
            reportCopyFailure(count: artifacts.count)
            return
        }
    }

    private static func reportCopyFailure(count: Int) {
        presentError(
            count == 1
                ? String(localized: "Couldn’t Copy Artifact")
                : String(localized: "Couldn’t Copy Artifacts"),
            count == 1
                ? String(localized: "Mechanician could not write a temporary file for this artifact.")
                : String(localized: "Mechanician could not write temporary files for these artifacts."))
    }

    private static func presentError(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    private static func importFailureDetail(skipped: [String]) -> String {
        let maximumFileMegabytes = maximumImportFileBytes / (1_024 * 1_024)
        let maximumBatchMegabytes = maximumImportBatchBytes / (1_024 * 1_024)
        return String(localized: "Artifact imports must be supported regular UTF-8 files no larger than \(maximumFileMegabytes) MB, with at most \(maximumImportFiles) files and \(maximumBatchMegabytes) MB total per drop (\(supportedImportSummary)):\n")
            + skipped.joined(separator: ", ")
    }

    /// A drop that resolved to no importable files is a dead-end for the user; explain every
    /// requirement because unsupported extensions, unsafe file kinds, encoding, and budgets all
    /// intentionally share this bounded intake path.
    static func reportNothingImported(skipped: [String]) {
        guard !skipped.isEmpty else { return }
        presentError(
            String(localized: "Couldn’t Import"),
            importFailureDetail(skipped: skipped))
    }

    static func reportSkippedImports(_ skipped: [String]) {
        guard !skipped.isEmpty else { return }
        presentError(
            String(localized: "Some Files Weren’t Imported"),
            String(localized: "These files were skipped. ")
                + importFailureDetail(skipped: skipped))
    }

    static func reportImportWorkspaceUnavailable() {
        presentError(
            String(localized: "Couldn’t Import"),
            String(localized: "The workspace that received these files is no longer available. No artifacts were imported."))
    }
}

/// The standard file commands shown for an artifact in every context menu. Surface-specific
/// commands (favorite, rename, open in a Mechanician window, delete, etc.) wrap these items.
struct ArtifactFileContextMenuItems: View {
    let artifact: Artifact

    var body: some View {
        ArtifactWorkspaceMoveMenu(artifact: artifact)
        Divider()
        Button { ArtifactActions.openInDefaultApp(artifact) } label: {
            Label("Open in Default App", systemImage: "arrow.up.forward.app")
        }
        Divider()
        Button { ArtifactActions.share(artifact) } label: {
            Label("Share…", systemImage: "square.and.arrow.up")
        }
        Button { ArtifactActions.save(artifact) } label: {
            Label("Save to File…", systemImage: "square.and.arrow.down")
        }
        if artifact.type.lowercased() == "html" {
            Button { ArtifactActions.saveAsPDF(artifact) } label: {
                Label("Save as PDF…", systemImage: "doc.richtext")
            }
        }
        Divider()
        Button { ArtifactActions.copySource(artifact) } label: {
            Label("Copy Source", systemImage: "doc.on.doc")
        }
        Button { ArtifactActions.revealInFinder(artifact) } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
    }
}
