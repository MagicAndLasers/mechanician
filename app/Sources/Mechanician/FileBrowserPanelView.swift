import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WebKit
import PDFKit
import ImageIO

struct FileEntry: Identifiable {
    let url: URL
    var id: URL { url }
    let isDir: Bool
    let size: Int
    let modified: Date
    var name: String { url.lastPathComponent }
}

/// How the browser sorts (mirrors Finder's clickable list columns).
enum FileSort: String { case name, modified, size }

/// Selection rules shared by the native outline and its context-menu actions. The outline owns the
/// actual Command/Shift-click mechanics; these helpers keep preview and bulk-action scope from
/// quietly drifting back to one item.
enum FileBrowserSelection {
    /// Inline and full-size Quick Look are intentionally single-item surfaces. Clearing the preview
    /// for a multi-selection is less surprising than showing one arbitrary member of the set.
    static func previewURL(in selection: Set<URL>) -> URL? {
        selection.count == 1 ? selection.first : nil
    }

    /// A right-click inside a multi-selection acts on the whole selection. A right-click elsewhere
    /// acts only on the row under the pointer, matching Finder without destroying the prior selection.
    static func actionTargets(clicked: URL, selectedInDisplayOrder: [URL]) -> [URL] {
        guard selectedInDisplayOrder.count > 1,
              selectedInDisplayOrder.contains(clicked) else { return [clicked] }
        return selectedInDisplayOrder
    }

    static func trashTitle(count: Int) -> String {
        count > 1 ? "Move \(count) Items to Trash" : "Move to Trash"
    }
}

/// Text passed to SwiftUI is deliberately much smaller than the maximum source file we will
/// inspect. `isTruncated` is presentation state, not an error: the preview always says when it is
/// showing only a prefix instead of building a view graph for a near-2 MB file.
struct FilePreviewTextContent: Equatable {
    let text: String
    let isTruncated: Bool
}

enum FileBrowserPreviewError: Error {
    case notRegularFile
    case tooLarge
    case notUTF8
}

/// Bounded, descriptor-based preview reads. Opening with O_NONBLOCK before checking `fstat` makes a
/// FIFO or device fail promptly instead of hanging the Files tab, and the descriptor check closes
/// the usual resource-value/read race. All callers run this off the main actor.
enum FilePreviewReader {
    static let maximumTextSourceBytes = 2_000_000
    static let maximumRenderedBytes = 128 * 1_024
    static let maximumRenderedCharacters = 40_000
    static let maximumMarkdownRenderedCharacters = 16_000
    static let maximumMarkdownRenderedLines = 400
    static let maximumMarkdownTableColumns = 32
    static let maximumMarkdownTableCells = 1_000
    static let maximumHTMLRenderedCharacters = 24_000
    static let maximumImageSourceBytes = 32 * 1_024 * 1_024
    static let maximumPDFSourceBytes = 64 * 1_024 * 1_024
    static let maximumImageDimension = 2_048
    static let maximumPDFPages = 100

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "bmp", "tiff", "webp",
    ]

    /// ImageIO and PDFKit do not cooperatively cancel once decoding begins. Two bounded media slots
    /// prevent rapid keyboard traversal from accumulating an unbounded set of 32/64 MiB decodes,
    /// while a separate text lane lets the latest cheap preview escape behind obsolete media work.
    private static let mediaPreviewQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ai.mechanician.file-preview.media"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private static let textPreviewQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ai.mechanician.file-preview.text"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    static func preview(at url: URL) async -> FilePreview {
        let cancellation = CancellationState()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let ext = url.pathExtension.lowercased()
                let queue = imageExtensions.contains(ext) || ext == "pdf"
                    ? mediaPreviewQueue : textPreviewQueue
                queue.addOperation {
                    continuation.resume(returning: previewSynchronously(
                        at: url,
                        isCancelled: { cancellation.isCancelled }))
                }
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }

    static func text(
        at url: URL,
        maximumCharacters: Int = maximumRenderedCharacters,
        maximumLines: Int? = nil
    ) throws -> FilePreviewTextContent {
        try text(
            at: url,
            maximumCharacters: maximumCharacters,
            maximumLines: maximumLines,
            isCancelled: { Task.isCancelled })
    }

    private static func text(
        at url: URL,
        maximumCharacters: Int,
        maximumLines: Int?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> FilePreviewTextContent {
        let read = try boundedRegularFileRead(
            at: url,
            maximumSourceBytes: maximumTextSourceBytes,
            maximumReadBytes: maximumRenderedBytes,
            isCancelled: isCancelled)
        guard !read.data.contains(0) else { throw FileBrowserPreviewError.notUTF8 }

        guard let decoded = decodedUTF8Prefix(
            read.data,
            allowingIncompleteTrailingScalar: read.isTruncated)
        else { throw FileBrowserPreviewError.notUTF8 }

        var renderedEnd = decoded.index(
            decoded.startIndex,
            offsetBy: maximumCharacters,
            limitedBy: decoded.endIndex) ?? decoded.endIndex
        var presentationTruncated = renderedEnd != decoded.endIndex
        if let maximumLines, maximumLines > 0 {
            var completedLines = 0
            var index = decoded.startIndex
            while index < renderedEnd {
                if decoded[index] == "\n" {
                    completedLines += 1
                    if completedLines >= maximumLines {
                        renderedEnd = index
                        presentationTruncated = true
                        break
                    }
                }
                index = decoded.index(after: index)
            }
        }
        return FilePreviewTextContent(
            text: String(decoded[..<renderedEnd]),
            isTruncated: read.isTruncated || presentationTruncated)
    }

    private static func previewSynchronously(
        at url: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> FilePreview {
        guard !isCancelled() else { return .none }
        let ext = url.pathExtension.lowercased()
        do {
            if imageExtensions.contains(ext) {
                return .image(try image(at: url, isCancelled: isCancelled))
            }
            if ext == "pdf" {
                return .pdf(try pdf(at: url, isCancelled: isCancelled))
            }
            let maximumCharacters: Int
            let maximumLines: Int?
            if ext == "md" || ext == "markdown" {
                maximumCharacters = maximumMarkdownRenderedCharacters
                maximumLines = maximumMarkdownRenderedLines
            } else if ext == "html" || ext == "htm" {
                maximumCharacters = maximumHTMLRenderedCharacters
                maximumLines = nil
            } else {
                maximumCharacters = maximumRenderedCharacters
                maximumLines = nil
            }
            let content = try text(
                at: url,
                maximumCharacters: maximumCharacters,
                maximumLines: maximumLines,
                isCancelled: isCancelled)
            if ext == "html" || ext == "htm" { return .web(content) }
            if ext == "md" || ext == "markdown" {
                // MarkdownText eagerly materializes table cells. Character and line caps alone do
                // not constrain a two-line table with thousands of columns, so keep adversarially
                // wide/dense tables in the single-Text plain preview.
                return allowsRichMarkdownPreview(content.text)
                    ? .markdown(content) : .text(content)
            }
            return .text(content)
        } catch is CancellationError {
            return .none
        } catch {
            return .unsupported
        }
    }

    private static func image(
        at url: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> NSImage {
        let read = try boundedRegularFileRead(
            at: url,
            maximumSourceBytes: maximumImageSourceBytes,
            maximumReadBytes: maximumImageSourceBytes,
            isCancelled: isCancelled)
        guard !isCancelled() else { throw CancellationError() }
        guard !read.isTruncated,
              let source = CGImageSourceCreateWithData(read.data as CFData, nil)
        else { throw FileBrowserPreviewError.tooLarge }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumImageDimension,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary)
        else { throw FileBrowserPreviewError.notUTF8 }
        return NSImage(cgImage: thumbnail, size: .zero)
    }

    private static func pdf(
        at url: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> PDFDocument {
        let read = try boundedRegularFileRead(
            at: url,
            maximumSourceBytes: maximumPDFSourceBytes,
            maximumReadBytes: maximumPDFSourceBytes,
            isCancelled: isCancelled)
        guard !isCancelled() else { throw CancellationError() }
        guard !read.isTruncated,
              let document = PDFDocument(data: read.data),
              document.pageCount <= maximumPDFPages
        else { throw FileBrowserPreviewError.tooLarge }
        return document
    }

    private struct BoundedRead {
        let data: Data
        let isTruncated: Bool
    }

    private static func boundedRegularFileRead(
        at url: URL,
        maximumSourceBytes: Int,
        maximumReadBytes: Int,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> BoundedRead {
        guard !isCancelled() else { throw CancellationError() }
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path])
        }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSFilePathErrorKey: url.path])
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw FileBrowserPreviewError.notRegularFile
        }
        // The former Files preview accepted only sources strictly below 2,000,000 bytes. Keep the
        // same boundary for text, and apply an explicit (larger) safety boundary to media.
        guard info.st_size >= 0, info.st_size < off_t(maximumSourceBytes) else {
            Darwin.close(descriptor)
            throw FileBrowserPreviewError.tooLarge
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let targetCount = maximumReadBytes + 1
        var data = Data()
        while data.count < targetCount {
            guard !isCancelled() else { throw CancellationError() }
            let count = min(64 * 1_024, targetCount - data.count)
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        let isTruncated = info.st_size > off_t(maximumReadBytes) || data.count > maximumReadBytes
        if data.count > maximumReadBytes { data.removeLast(data.count - maximumReadBytes) }
        return BoundedRead(data: data, isTruncated: isTruncated)
    }

    /// A bounded read may stop in the middle of one UTF-8 scalar. Only that incomplete tail may be
    /// removed; malformed bytes anywhere else still reject the preview as binary/non-UTF-8.
    private static func decodedUTF8Prefix(
        _ data: Data,
        allowingIncompleteTrailingScalar: Bool
    ) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        guard allowingIncompleteTrailingScalar else { return nil }
        for droppedBytes in 1 ... min(3, data.count) {
            if let text = String(data: data.dropLast(droppedBytes), encoding: .utf8) { return text }
        }
        return nil
    }

    private static func allowsRichMarkdownPreview(_ text: String) -> Bool {
        var tableCells = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let separators = line.reduce(into: 0) { count, character in
                if character == "|" { count += 1 }
            }
            guard separators <= maximumMarkdownTableColumns + 1 else { return false }
            if separators >= 2 {
                tableCells += separators - 1
                guard tableCells <= maximumMarkdownTableCells else { return false }
            }
        }
        return true
    }
}

/// Owns one selection-driven load. Cancellation limits wasted work; the monotonically increasing
/// request id is the correctness fence for loaders (PDF/ImageIO included) that may finish after
/// cancellation and must never publish over a newer selection.
@MainActor
final class FilePreviewLoader: ObservableObject {
    typealias Loader = (URL) async -> FilePreview

    @Published private(set) var preview: FilePreview = .none
    private let loader: Loader
    private var loadTask: Task<Void, Never>?
    private var requestID: UInt64 = 0

    init(loader: @escaping Loader = { await FilePreviewReader.preview(at: $0) }) {
        self.loader = loader
    }

    func select(_ url: URL?) {
        requestID &+= 1
        let currentRequest = requestID
        loadTask?.cancel()
        guard let url else {
            loadTask = nil
            preview = .none
            return
        }

        preview = .loading
        loadTask = Task { [weak self, loader] in
            let loaded = await loader(url)
            guard !Task.isCancelled else { return }
            self?.publish(loaded, requestID: currentRequest)
        }
    }

    private func publish(_ loaded: FilePreview, requestID: UInt64) {
        guard requestID == self.requestID else { return }
        preview = loaded
        loadTask = nil
    }

    deinit { loadTask?.cancel() }
}

/// Real Finder icons via the document type, cached by extension so a big folder doesn't hit
/// the icon services once per row. Bundle folders (.app/.xcodeproj) get their real icon.
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for url: URL, isDir: Bool) -> NSImage {
        let ext = url.pathExtension.lowercased()
        let key = ext.isEmpty ? (isDir ? "·dir" : "·file") : ext
        if let cached = cache[key] { return cached }
        let type: UTType = (ext.isEmpty ? nil : UTType(filenameExtension: ext))
            ?? (isDir ? .folder : .data)
        let img = NSWorkspace.shared.icon(for: type)
        img.size = NSSize(width: 16, height: 16)
        cache[key] = img
        return img
    }
}

/// Column widths shared by the header and every row so they line up.
private enum Col { static let date: CGFloat = 116; static let size: CGFloat = 62 }

/// Finder-style "Apr 20, 2025, 11:53 AM".
private let fileDateFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
}()

func fileByteString(_ n: Int, isDir: Bool) -> String {
    if isDir { return "--" }
    if n >= 1 << 30 { return String(format: "%.1f GB", Double(n) / Double(1 << 30)) }
    if n >= 1 << 20 { return String(format: "%.1f MB", Double(n) / Double(1 << 20)) }
    if n >= 1 << 10 { return String(format: "%.0f KB", Double(n) / Double(1 << 10)) }
    return "\(n) B"
}

/// A Finder-like browser for the working folder: navigate, preview text/images, and
/// do basic management (new folder, rename, delete, reveal, open).
struct FileBrowserPanelView: View {
    @EnvironmentObject private var bridge: AgentBridge
    @Environment(\.openWindow) private var openWindow

    @State private var dir = URL(fileURLWithPath: NSHomeDirectory())
    @State private var selection: Set<URL> = []
    @State private var selectedIsFile = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @AppStorage("filesPreviewHeight") private var previewHeight = 320.0
    // Bumped after a mutation (rename/trash/new folder) to force the lazy outline — whose
    // child lists live in per-node state — to reload from disk.
    @State private var treeToken = 0
    @StateObject private var quickLook = QuickLookController()
    @StateObject private var previewLoader = FilePreviewLoader()

    /// Preview remains a single-file affordance even though the browser itself supports native
    /// multiple selection.
    private var selected: URL? { FileBrowserSelection.previewURL(in: selection) }

    var body: some View {
        InspectorPreviewSplit(previewHeight: $previewHeight, minimumTopHeight: 200) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                FinderOutlineView(
                    root: dir,
                    selection: $selection,
                    // A mutation (rename/trash/new folder/drop) bumps this; the outline reloads from
                    // disk IN PLACE, keeping which folders are open, instead of being torn down.
                    reloadToken: treeToken,
                    // Native selection supports ordinary click, Command-toggle and Shift-range.
                    // Double click opens a file / navigates into a folder (breadcrumb follows).
                    onActivate: { url, isDir in
                        if isDir { dir = url; load() } else { NSWorkspace.shared.open(url) }
                    },
                    onRename: { entry, newName in renameFile(entry, to: newName) },
                    onChanged: { treeToken += 1 },
                    // The native row already knows whether the sole selected item is a file. Use
                    // that fact instead of doing synchronous URL metadata I/O during `body`.
                    onPreviewSelection: { url in
                        selectedIsFile = url != nil
                        previewLoader.select(url)
                    },
                    onQuickLook: { quickLook.preview($0) },
                    onInject: { bridge.inject($0) },
                    onWatch: { requestWatch($0) })
                // Only the ROOT change recreates the outline (a whole new tree); mutations within it
                // reload in place via reloadToken so expansion state survives.
                .id(dir.path)
            }
            // Folder-level actions (Finder-style), for right-clicks on empty space; per-row
            // menus still take precedence over their own rows.
            .contextMenu {
                Button { showNewFolder = true; newFolderName = "" } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([dir]) } label: {
                    Label("Reveal in Finder", systemImage: "arrow.up.forward.app")
                }
                Button { requestWatch(dir) } label: {
                    Label("Watch This Folder…", systemImage: "eye")
                }
                Divider()
                Button { reloadTree() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        } preview: {
            previewPane
                // Any inline preview is width-capped by the inspector; this expands it to the
                // full-size native Quick Look panel.
                .overlay(alignment: .topTrailing) {
                    if selectedIsFile {
                        Button { quickLook.toggle() } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }
                        .buttonStyle(.borderless)
                        .padding(6)
                        .help("Quick Look at full size (Space)")
                        .accessibilityLabel("Quick Look, full size")
                    }
                }
        }
        // Native Quick Look (Space, like Finder) — a top-level system window, so it escapes
        // the inspector's width entirely and previews far more types than the inline peek.
        // The bridge takes key focus on file selection and handles Space itself.
        .background(QuickLookHost(selected: selectedIsFile ? selected : nil, controller: quickLook)
            .frame(width: 0, height: 0))
        .onAppear { if bridge.cwd.isEmpty == false { dir = URL(fileURLWithPath: bridge.cwd) }; load() }
        .onChange(of: bridge.cwd) { _, new in dir = URL(fileURLWithPath: new); load() }
        .onDisappear { previewLoader.select(nil) }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Trailing path components as a Finder-style breadcrumb.
    private var breadcrumb: [URL] {
        var comps: [URL] = []
        var u = dir.standardizedFileURL
        var guardCount = 0
        while guardCount < 64 {
            guardCount += 1
            comps.insert(u, at: 0)
            if u.path == "/" || u.path.isEmpty { break } // never walk past root (/.. loops)
            let parent = u.deletingLastPathComponent().standardizedFileURL
            if parent.path == u.path { break }
            u = parent
        }
        return Array(comps.suffix(4))
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            ForEach(Array(breadcrumb.enumerated()), id: \.element) { idx, comp in
                Button(comp.lastPathComponent.isEmpty ? "/" : comp.lastPathComponent) {
                    dir = comp; load()
                }
                .buttonStyle(.plain)
                .foregroundStyle(comp == dir ? .primary : .secondary)
                .fontWeight(comp == dir ? .semibold : .regular)
                .lineLimit(1)
                if idx < breadcrumb.count - 1 {
                    Image(systemName: "chevron.right").scaledFont(10).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            // Occasional actions live in the right-click menu, Finder-style, instead of a
            // row of loose icons.
            Button { quickLook.toggle() } label: { Image(systemName: "eye") }
                .buttonStyle(.borderless).help("Quick Look (Space)")
                .accessibilityLabel("Quick Look")
                .disabled(!selectedIsFile)
            Button { reloadTree() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh")
                .accessibilityLabel("Refresh")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var previewPane: some View {
        switch previewLoader.preview {
        case .image(let img):
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding()
            }
        case .markdown(let content):
            VStack(spacing: 0) {
                truncationNotice(for: content)
                ScrollView {
                    MarkdownText(text: content.text)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .web(let content):
            VStack(spacing: 0) {
                truncationNotice(for: content)
                FileWebView(source: content.text)
            }
        case .pdf(let document):
            PDFPreview(document: document)
        case .text(let content):
            VStack(spacing: 0) {
                truncationNotice(for: content)
                ScrollView {
                    textPreview(content.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
        case .loading:
            ProgressView("Loading preview…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unsupported:
            VStack(spacing: 8) {
                Image(systemName: "eye").scaledFont(20).foregroundStyle(.secondary)
                Text("No inline preview for this type").scaledFont(11).foregroundStyle(.secondary)
                Button { quickLook.toggle() } label: { Label("Quick Look", systemImage: "eye") }
                    .buttonStyle(PillButtonStyle(kind: .neutral))
                    .help("Open in Quick Look (Space)")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .none:
            placeholder(selection.count > 1 ? "Multiple items selected" : "Select a file to preview")
        }
    }

    @ViewBuilder
    private func truncationNotice(for content: FilePreviewTextContent) -> some View {
        if content.isTruncated {
            Label("Preview truncated to keep it responsive", systemImage: "scissors")
                .scaledFont(10)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).scaledFont(11).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Syntax-highlight the previewed file by its extension's language; plain monospaced for
    /// non-code text (.txt, .log, unknown types).
    @ViewBuilder
    private func textPreview(_ text: String) -> some View {
        if let lang = SyntaxHighlighter.canonicalLanguage(selected?.pathExtension) {
            Text(SyntaxHighlighter.highlight(text, language: lang, fontSize: 11.5))
        } else {
            Text(text).scaledFont(11, design: .monospaced)
        }
    }

    // MARK: Actions

    /// Reset selection + preview after navigating or a mutation; the outline itself rebuilds
    /// its contents from `dir` / `treeToken`.
    private func load() {
        selection = []
        selectedIsFile = false
        previewLoader.select(nil)
    }

    /// Refresh: re-read the tree from disk in place, keeping open folders open and the selection —
    /// so it also picks up changes made outside the app (e.g. in the terminal).
    private func reloadTree() {
        treeToken += 1
        // Refresh is also an explicit request to reread the selected file. The native selection
        // path is unchanged, so the coordinator correctly de-duplicates it; restart the bounded
        // loader directly to avoid leaving a same-path overwrite stale in the preview pane.
        previewLoader.select(selectedIsFile ? selected : nil)
    }

    /// "Watch This File/Folder…" → open the Schedule window with a pre-filled watch task; the
    /// standing instruction runs the full agent whenever the target changes.
    private func requestWatch(_ url: URL) {
        AmbientStore.shared.pendingWatchPath = url.path
        openWindow(id: "ambient")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Rename `entry` to `newName` on disk, Finder-style. Validates, refuses to clobber an
    /// existing item, keeps the selection on the renamed file, and beeps on a rejected rename.
    private func renameFile(_ entry: FileEntry, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != entry.name else { return }                 // no change → silent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            NSSound.beep(); return
        }
        let dest = entry.url.deletingLastPathComponent().appendingPathComponent(name)
        // Allow case-only renames on case-insensitive volumes; block real collisions.
        if FileManager.default.fileExists(atPath: dest.path),
           dest.path.caseInsensitiveCompare(entry.url.path) != .orderedSame {
            NSSound.beep(); return
        }
        do {
            try FileManager.default.moveItem(at: entry.url, to: dest)
            load()
            selection = [dest]
            treeToken += 1
        } catch {
            NSSound.beep()
        }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        load()
        treeToken += 1
    }
}

/// What the browser's preview pane is currently showing.
enum FilePreview {
    case none
    case loading
    case unsupported
    case image(NSImage)
    case markdown(FilePreviewTextContent)
    case text(FilePreviewTextContent)
    case web(FilePreviewTextContent)   // static, sandboxed HTML source
    case pdf(PDFDocument)
}

/// Renders untrusted local HTML without JavaScript, network access, or access to neighboring files.
struct FileWebView: NSViewRepresentable {
    let source: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: SafeHTMLPreview.makeConfiguration())
        web.navigationDelegate = context.coordinator.navigationDelegate
        web.setValue(false, forKey: "drawsBackground")
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let html = SafeHTMLPreview.fileDocument(source)
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        web.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator {
        var loadedHTML: String?
        let navigationDelegate = SafePreviewNavigationDelegate()
    }
}

/// Renders a PDF document via PDFKit.
struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.backgroundColor = .clear
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        if v.document !== document {
            v.document = document
        }
    }
}

/// A reference-type file tree node for NSOutlineView (which keys off object identity).
/// Children load lazily — nil means "not read yet".
final class FileNode {
    let url: URL
    let isDir: Bool
    var size: Int          // var so an in-place refresh can update a reused folder's metadata
    var modified: Date
    var children: [FileNode]?

    init(url: URL, isDir: Bool, size: Int = 0, modified: Date = .distantPast) {
        self.url = url; self.isDir = isDir; self.size = size; self.modified = modified
    }

    var name: String { url.lastPathComponent }
    var fileEntry: FileEntry { FileEntry(url: url, isDir: isDir, size: size, modified: modified) }

    /// Read this directory's contents into `children` (unsorted — the coordinator sorts).
    func loadChildren() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        children = urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return FileNode(url: u, isDir: v?.isDirectory ?? false, size: v?.fileSize ?? 0,
                            modified: v?.contentModificationDate ?? .distantPast)
        }
    }
}

/// NSOutlineView subclass that adds Finder keyboard affordances: Space → Quick Look the
/// selected row, Return → rename it inline.
final class FinderOutline: NSOutlineView {
    var onSpace: (() -> Void)?
    var onReturn: (() -> Void)?
    var onTrash: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49 where selectedRow >= 0: onSpace?(); return          // space
        case 36 where selectedRow >= 0: onReturn?(); return         // return
        case 51, 117:                                               // ⌫ / ⌦
            guard selectedRow >= 0,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
            else { return super.keyDown(with: event) }
            onTrash?(); return                                     // Finder-style ⌘⌫
        default: super.keyDown(with: event)
        }
    }
}

/// Session-scoped file-tree expansion state, keyed by the browsed folder's path. Switching inspector
/// tabs tears down and rebuilds the browser view; restoring this on rebuild keeps the folders you had
/// open instead of collapsing back to the root. In-memory only — within a session, not across launches
/// (durable-across-restart would be a follow-up). [FR-97]
@MainActor final class FileBrowserSession {
    static let shared = FileBrowserSession()
    private var expandedByRoot: [String: Set<String>] = [:]
    func expanded(root: String) -> Set<String> { expandedByRoot[root] ?? [] }
    func setExpanded(_ paths: Set<String>, root: String) {
        if paths.isEmpty { expandedByRoot.removeValue(forKey: root) } else { expandedByRoot[root] = paths }
    }
}

/// The working folder as a native Finder "list view": a multi-column NSOutlineView with
/// disclosure triangles (folders expand inline, lazily), alternating row tints, real file
/// icons, native inline rename, drag-out, clickable sort headers, and Quick Look — the true
/// Mac file-browser feel SwiftUI's List can't quite reproduce.
struct FinderOutlineView: NSViewRepresentable {
    let root: URL
    @Binding var selection: Set<URL>
    let reloadToken: Int                   // bumped to reload contents without losing expansion
    let onActivate: (URL, Bool) -> Void    // double click: open file / navigate into folder
    let onRename: (FileEntry, String) -> Void
    let onChanged: () -> Void
    let onPreviewSelection: (URL?) -> Void // sole selected file, from already-loaded row metadata
    let onQuickLook: (URL) -> Void
    let onInject: (String) -> Void
    let onWatch: (URL) -> Void             // "Watch This File/Folder…" → a scheduled watch task

    /// Keep the native AppKit selection model intact: it supplies ordinary replacement,
    /// Command-toggle, Shift-range, keyboard extension, and Select All without a gesture shim.
    static func configureSelection(on outline: NSOutlineView) {
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = FinderOutline()
        let coord = context.coordinator
        coord.outline = outline

        let name = NSTableColumn(identifier: .init("name"))
        name.title = "Name"; name.minWidth = 140; name.width = 240
        let date = NSTableColumn(identifier: .init("date"))
        date.title = "Date Modified"; date.width = Col.date; date.minWidth = 96
        let size = NSTableColumn(identifier: .init("size"))
        size.title = "Size"; size.width = Col.size; size.minWidth = 48
        name.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        date.sortDescriptorPrototype = NSSortDescriptor(key: "modified", ascending: true)
        size.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
        outline.addTableColumn(name)
        outline.addTableColumn(date)
        outline.addTableColumn(size)
        outline.outlineTableColumn = name

        outline.dataSource = coord
        outline.delegate = coord
        outline.rowSizeStyle = .small                       // dense, Finder-like rows
        outline.usesAlternatingRowBackgroundColors = true   // alternating tints
        outline.indentationPerLevel = 14
        Self.configureSelection(on: outline)
        outline.allowsColumnResizing = true
        outline.autoresizesOutlineColumn = true
        outline.backgroundColor = .clear                    // blend into the panel material
        outline.headerView = NSTableHeaderView()
        outline.sortDescriptors = [name.sortDescriptorPrototype!]
        outline.target = coord
        outline.doubleAction = #selector(Coordinator.doubleClicked)
        // Drag OUT to Finder/apps = copy. `.delete` is what makes the Trash a legal destination:
        // Finder does not move the file itself, it completes the drag with `.delete` and leaves
        // removing the original to the source. Without it the Trash refuses the drop entirely.
        outline.setDraggingSourceOperationMask([.copy, .delete], forLocal: false)
        outline.setDraggingSourceOperationMask([.move], forLocal: true)    // drag WITHIN the tree = move
        outline.registerForDraggedTypes([.fileURL])                        // accept files dragged IN

        let menu = NSMenu(); menu.delegate = coord
        outline.menu = menu

        outline.onSpace = { [weak coord] in coord?.quickLookSelected() }
        outline.onReturn = { [weak coord] in coord?.renameSelected() }
        outline.onTrash = { [weak coord] in coord?.trashSelected() }

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        coord.rebuild(root: root)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // SwiftUI recreates this struct each update — keep the coordinator's callbacks current.
        let coord = context.coordinator
        coord.parent = self
        // A bumped token means the folder contents changed (rename/trash/new folder/drop). Reload
        // from disk while preserving expansion, instead of tearing the whole outline down.
        if coord.lastToken != reloadToken {
            coord.lastToken = reloadToken
            coord.reloadKeepingExpansion()
        }
        coord.syncSelection(selection)  // reflect a programmatic selection change (e.g. after rename)
    }

    /// Torn down when the browser leaves the hierarchy (e.g. switching inspector tabs). Record the
    /// open folders so the next mount restores them instead of collapsing the tree. [FR-97]
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.saveExpansionState()
        coordinator.cancelPendingPreviewSelectionDelivery()
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        var parent: FinderOutlineView
        weak var outline: FinderOutline?
        private var rootNode: FileNode?
        private var sortKey: FileSort = .name
        private var sortAsc = true
        private var syncing = false
        private var loadedNodesByPath: [String: FileNode] = [:]
        private var previewSelectionWasPublished = false
        private var publishedPreviewPath: String?
        private var previewSelectionDeliveryID: UInt64 = 0
        private(set) var indexedSelectionLookupCount = 0
        var lastToken = 0

        init(_ parent: FinderOutlineView) { self.parent = parent }

        func rebuild(root: URL) {
            let node = FileNode(url: root, isDir: true)
            loadedNodesByPath.removeAll(keepingCapacity: true)
            rootNode = node
            index(node)
            node.children = sorted(load(node))
            outline?.reloadData()
            restoreExpansion()
            syncSelection(parent.selection)
        }

        // MARK: session expansion state (survives inspector tab switches — FR-97)

        private var sessionRootKey: String { parent.root.standardizedFileURL.path }

        /// Re-open the folders the user had expanded before the view was torn down. Walk shallow→deep
        /// so each folder's parent is expanded (and lazily loaded) before it.
        private func restoreExpansion() {
            guard let ov = outline, let root = rootNode else { return }
            let key = sessionRootKey
            let saved = MainActor.assumeIsolated { FileBrowserSession.shared.expanded(root: key) }
            guard !saved.isEmpty else { return }
            for path in saved.sorted(by: { $0.count < $1.count }) {
                if let node = node(atPath: path, from: root) { ov.expandItem(node) }
            }
        }

        /// Record which folders are currently open, so the next mount restores them.
        func saveExpansionState() {
            guard let ov = outline, let root = rootNode else { return }
            var set = Set<String>()
            collectExpanded(root, ov: ov, into: &set)
            let key = sessionRootKey
            MainActor.assumeIsolated { FileBrowserSession.shared.setExpanded(set, root: key) }
        }

        private func collectExpanded(_ node: FileNode, ov: NSOutlineView, into set: inout Set<String>) {
            guard let kids = node.children else { return }   // only loaded folders can be expanded
            for k in kids where k.isDir {
                if ov.isItemExpanded(k) {
                    set.insert(k.url.standardizedFileURL.path)
                    collectExpanded(k, ov: ov, into: &set)
                }
            }
        }

        /// Walk from the root to `target`, loading each level lazily; nil if the path no longer exists.
        private func node(atPath target: String, from root: FileNode) -> FileNode? {
            if let loaded = loadedNodesByPath[target] { return loaded }
            let rootPath = root.url.standardizedFileURL.path
            if target == rootPath { return root }
            let prefix = rootPath == "/" ? "/" : rootPath + "/"
            guard target.hasPrefix(prefix) else { return nil }
            let rel = String(target.dropFirst(prefix.count)).split(separator: "/").map(String.init)
            var current = root
            for comp in rel {
                if current.children == nil { current.children = sorted(load(current)) }
                guard let next = current.children?.first(where: { $0.url.lastPathComponent == comp }) else { return nil }
                current = next
            }
            return current
        }

        // MARK: sorting

        private func load(_ node: FileNode) -> [FileNode] {
            node.loadChildren()
            for child in node.children ?? [] { index(child) }
            return node.children ?? []
        }

        private func index(_ node: FileNode) {
            loadedNodesByPath[node.url.standardizedFileURL.path] = node
        }

        private func rebuildLoadedNodeIndex() {
            loadedNodesByPath.removeAll(keepingCapacity: true)
            func visit(_ node: FileNode) {
                index(node)
                for child in node.children ?? [] { visit(child) }
            }
            if let rootNode { visit(rootNode) }
        }

        /// Exposed at module scope for deterministic selection-index regression tests.
        func loadedNode(for url: URL) -> FileNode? {
            loadedNodesByPath[url.standardizedFileURL.path]
        }

        private func sorted(_ nodes: [FileNode]) -> [FileNode] {
            let s = nodes.sorted { a, b in
                switch sortKey {
                case .name: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                case .modified: return a.modified < b.modified
                case .size: return a.size < b.size
                }
            }
            return sortAsc ? s : s.reversed()
        }

        private func resort(_ node: FileNode) {
            guard let kids = node.children else { return }
            node.children = sorted(kids)
            for k in kids where k.children != nil { resort(k) }
        }

        func outlineView(_ ov: NSOutlineView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard let d = ov.sortDescriptors.first, let key = d.key else { return }
            sortKey = FileSort(rawValue: key) ?? .name
            sortAsc = d.ascending
            if let rootNode { resort(rootNode) }
            ov.reloadData()   // item identity is stable, so expansion state is preserved
            syncSelection(parent.selection) // row indexes changed; keep every selected URL selected
        }

        // MARK: in-place reload (keeps folders open across a mutation)

        /// Re-scan every already-loaded folder from disk, REUSING the existing node object wherever the
        /// URL still exists so NSOutlineView keeps that row's expansion (it tracks expansion by object
        /// identity). New entries become fresh nodes; vanished ones fall out; unloaded (collapsed,
        /// never-opened) folders are left lazy.
        private func refresh(_ node: FileNode) {
            guard node.children != nil else { return }
            let existing = Dictionary((node.children ?? []).map { ($0.url.standardizedFileURL, $0) },
                                      uniquingKeysWith: { a, _ in a })
            node.loadChildren()
            node.children = sorted((node.children ?? []).map { fresh -> FileNode in
                // Keep the existing object only for a surviving FOLDER, so its open subtree +
                // expansion survive — but copy the fresh metadata onto it so Date Modified stays
                // current. Files (and any file<->folder type change) take the fresh node, so Size /
                // Date / kind always reflect what's on disk.
                if fresh.isDir, let kept = existing[fresh.url.standardizedFileURL], kept.isDir {
                    kept.size = fresh.size
                    kept.modified = fresh.modified
                    refresh(kept)
                    return kept
                }
                return fresh
            })
        }

        /// Reload the tree from disk without collapsing open folders — the shared path for every
        /// mutation (rename, trash, new folder, drop).
        func reloadKeepingExpansion() {
            guard let rootNode, let ov = outline else { return }
            refresh(rootNode)
            rebuildLoadedNodeIndex()
            ov.reloadData()   // same object identities → expansion + selection survive
            syncSelection(parent.selection)
        }

        private func findLoaded(byPath path: String) -> FileNode? {
            loadedNodesByPath[path]
        }

        private func loadedFolder(_ dir: URL) -> FileNode? {
            let p = dir.standardizedFileURL.path
            if let r = rootNode, r.url.standardizedFileURL.path == p { return r }
            return findLoaded(byPath: p)
        }

        // MARK: data source

        func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            let node = (item as? FileNode) ?? rootNode
            guard let node, node.isDir else { return 0 }
            if node.children == nil { node.children = sorted(load(node)) }
            return node.children?.count ?? 0
        }

        func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            let node = (item as? FileNode) ?? rootNode
            return node!.children![index]
        }

        func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileNode)?.isDir ?? false
        }

        func outlineView(_ ov: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            (item as? FileNode)?.url as NSURL?   // native drag-out to Finder / apps / the composer
        }

        /// A drag onto the Trash ends with `operation == .delete`: the destination performed no
        /// drop, and removing the original is the source's job. Everything else — a copy into a
        /// Finder folder, a drop into the composer, a cancelled drag — leaves the file alone.
        func outlineView(
            _ ov: NSOutlineView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            guard operation == .delete,
                  let urls = session.draggingPasteboard.readObjects(
                    forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]) as? [URL]
            else { return }

            let trashed = Self.trashDraggedItems(urls)
            guard !trashed.isEmpty else { return }
            finishTrash(trashed)
        }

        /// Trash each dragged file, returning the ones that actually moved.
        ///
        /// Recoverable (`trashItem`), never `removeItem` — a drag to the Trash is undoable in
        /// Finder and must be here too. A failure leaves that file in place and out of the result,
        /// so a refusal cannot read as a successful delete.
        static func trashDraggedItems(
            _ urls: [URL],
            using trash: (URL) throws -> Void = {
                try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
            }
        ) -> [URL] {
            var trashed: [URL] = []
            for url in urls {
                do {
                    try trash(url)
                    trashed.append(url)
                } catch {
                    continue
                }
            }
            return trashed
        }

        /// Finder's keyboard shortcut applies to the complete native selection, in row order.
        func trashSelected() {
            let trashed = Self.trashDraggedItems(selectedNodes().map(\.url))
            guard !trashed.isEmpty else { return }
            finishTrash(trashed)
        }

        private func finishTrash(_ trashed: [URL]) {
            let gone = Set(trashed.map(\.standardizedFileURL))
            parent.selection = Set(parent.selection.filter {
                !gone.contains($0.standardizedFileURL)
            })
            parent.onChanged()
        }

        // MARK: drag IN (drop)

        /// Where a drop lands: onto a folder row drops INTO that folder; anywhere else (on a file,
        /// between rows, or empty space) drops into the browser's current root folder.
        private func dropTarget(_ item: Any?) -> URL {
            if let node = item as? FileNode, node.isDir { return node.url }
            return parent.root
        }

        func outlineView(_ ov: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                        options: [.urlReadingFileURLsOnly: true]) else { return [] }
            // Retarget onto a whole folder row (or the root) rather than a between-rows insertion, so
            // the highlight reads as "drop into this folder" — files have no order here. Dropping onto
            // a FILE targets the folder that contains it (Finder behavior), not the root.
            if let node = item as? FileNode {
                if node.isDir {
                    ov.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
                } else if let parent = ov.parent(forItem: node) as? FileNode {
                    ov.setDropItem(parent, dropChildIndex: NSOutlineViewDropOnItemIndex)
                } else {
                    ov.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)   // file at root
                }
            } else {
                ov.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            }
            // Files dragged from elsewhere are copied in; files dragged within the tree are moved.
            let isLocal = (info.draggingSource as? NSOutlineView) === outline
            return isLocal ? .move : .copy
        }

        func outlineView(_ ov: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            guard let urls = info.draggingPasteboard.readObjects(
                    forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  !urls.isEmpty else { return false }
            let destDir = dropTarget(item).standardizedFileURL
            let isLocal = (info.draggingSource as? NSOutlineView) === outline
            let fm = FileManager.default
            var firstDest: URL?
            for src in urls {
                let source = src.standardizedFileURL
                if isLocal {
                    // No-op if it's already here; never move a folder into itself or its own subtree.
                    if source.deletingLastPathComponent().path == destDir.path { continue }
                    if destDir.path == source.path || destDir.path.hasPrefix(source.path + "/") { NSSound.beep(); continue }
                }
                let srcIsDir = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let dest = uniqueDestination(for: source, in: destDir, isDir: srcIsDir)
                do {
                    if isLocal { try fm.moveItem(at: source, to: dest) }
                    else       { try fm.copyItem(at: source, to: dest) }
                    if firstDest == nil { firstDest = dest }
                } catch { NSSound.beep() }
            }
            guard firstDest != nil else { return false }
            revealDrop(into: destDir, select: firstDest)
            return true
        }

        /// After a drop: reload the changed folder in place (open folders stay open), reveal the
        /// destination, and select the first item that landed so it previews.
        private func revealDrop(into destDir: URL, select: URL?) {
            reloadKeepingExpansion()
            guard let ov = outline else { return }
            if let folder = loadedFolder(destDir), folder !== rootNode { ov.expandItem(folder) }
            if let sel = select, let node = findLoaded(byPath: sel.standardizedFileURL.path) {
                let row = ov.row(forItem: node)
                if row >= 0 {
                    ov.selectRowIndexes([row], byExtendingSelection: false)   // fires onSelect → preview
                    ov.scrollRowToVisible(row)
                }
            }
        }

        /// A collision-free destination in `dir`, Finder-style: "report.pdf" → "report 2.pdf".
        private func uniqueDestination(for src: URL, in dir: URL, isDir: Bool) -> URL {
            var candidate = dir.appendingPathComponent(src.lastPathComponent)
            guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
            // A folder has no extension to preserve ("2024.backup" → "2024.backup 2"); a file keeps
            // its extension ("report.pdf" → "report 2.pdf").
            let base = isDir ? src.lastPathComponent : src.deletingPathExtension().lastPathComponent
            let ext = isDir ? "" : src.pathExtension
            var n = 2
            repeat {
                let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                candidate = dir.appendingPathComponent(name)
                n += 1
            } while FileManager.default.fileExists(atPath: candidate.path)
            return candidate
        }

        // MARK: cells

        func outlineView(_ ov: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileNode, let col = tableColumn else { return nil }
            switch col.identifier.rawValue {
            case "name": return nameCell(ov, node)
            case "date":
                return textCell(ov, id: "date",
                                node.isDir && node.modified == .distantPast ? "--"
                                    : fileDateFormatter.string(from: node.modified), align: .left)
            case "size":
                return textCell(ov, id: "size", fileByteString(node.size, isDir: node.isDir), align: .right)
            default: return nil
            }
        }

        private func nameCell(_ ov: NSOutlineView, _ node: FileNode) -> NSView {
            let id = NSUserInterfaceItemIdentifier("nameCell")
            let cell = (ov.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
                let c = NSTableCellView(); c.identifier = id
                let iv = NSImageView(); iv.translatesAutoresizingMaskIntoConstraints = false
                let tf = NSTextField(); tf.translatesAutoresizingMaskIntoConstraints = false
                tf.isBordered = false; tf.drawsBackground = false; tf.isEditable = true
                tf.font = .systemFont(ofSize: 12); tf.lineBreakMode = .byTruncatingMiddle
                tf.cell?.usesSingleLineMode = true; tf.delegate = self
                c.addSubview(iv); c.addSubview(tf); c.imageView = iv; c.textField = tf
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16),
                    iv.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.imageView?.image = FileIcons.icon(for: node.url, isDir: node.isDir)
            cell.textField?.stringValue = node.name
            return cell
        }

        private func textCell(_ ov: NSOutlineView, id: String, _ text: String,
                              align: NSTextAlignment) -> NSView {
            let ident = NSUserInterfaceItemIdentifier(id)
            let cell = (ov.makeView(withIdentifier: ident, owner: self) as? NSTableCellView) ?? {
                let c = NSTableCellView(); c.identifier = ident
                let tf = NSTextField(); tf.translatesAutoresizingMaskIntoConstraints = false
                tf.isBordered = false; tf.drawsBackground = false; tf.isEditable = false
                tf.font = .systemFont(ofSize: 11); tf.textColor = .secondaryLabelColor
                tf.lineBreakMode = .byTruncatingTail; tf.alignment = align
                c.addSubview(tf); c.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = text
            cell.textField?.alignment = align
            return cell
        }

        // MARK: selection + activation

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncing else { return }
            let nodes = selectedNodes()
            parent.selection = Set(nodes.map(\.url))
            publishPreviewSelection(nodes)
        }

        /// Selected nodes in visible row order. Keeping the native order makes multi-file pasteboard,
        /// reveal, agent, and Trash operations deterministic instead of inheriting Set iteration.
        private func selectedNodes() -> [FileNode] {
            guard let ov = outline else { return [] }
            return ov.selectedRowIndexes.compactMap { ov.item(atRow: $0) as? FileNode }
        }

        private func publishPreviewSelection(_ nodes: [FileNode]) {
            let url = nodes.count == 1 && nodes[0].isDir == false ? nodes[0].url : nil
            let path = url?.standardizedFileURL.path
            guard !previewSelectionWasPublished || path != publishedPreviewPath else { return }
            previewSelectionWasPublished = true
            publishedPreviewPath = path
            previewSelectionDeliveryID &+= 1
            let deliveryID = previewSelectionDeliveryID
            // `syncSelection` is called from `updateNSView`; delivering synchronously from there
            // would mutate SwiftUI state during an active representable update. The delivery id
            // preserves ordering when several native selection changes arrive before this block.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.previewSelectionDeliveryID == deliveryID else { return }
                self.parent.onPreviewSelection(url)
            }
        }

        func cancelPendingPreviewSelectionDelivery() {
            previewSelectionDeliveryID &+= 1
        }

        @objc func doubleClicked() {
            guard let ov = outline, ov.clickedRow >= 0,
                  let node = ov.item(atRow: ov.clickedRow) as? FileNode else { return }
            let selected = selectedNodes()
            if selected.count > 1,
               selected.contains(where: { $0 === node }),
               selected.allSatisfy({ !$0.isDir }) {
                selected.forEach { parent.onActivate($0.url, false) }
                return
            }
            parent.onActivate(node.url, node.isDir)
        }

        /// Reflect a programmatic selection (e.g. keep the renamed file selected) without
        /// re-triggering onSelect. Only searches already-loaded nodes.
        func syncSelection(_ urls: Set<URL>) {
            guard let ov = outline else { return }
            let normalizedURLs = Set(urls.map { $0.standardizedFileURL.path })
            let nativeNodes = selectedNodes()
            let nativeURLs = Set(nativeNodes.map { $0.url.standardizedFileURL.path })
            // The usual SwiftUI update is the echo of AppKit's own selection callback. In that
            // case the native rows are already authoritative and no URL lookup is necessary.
            guard nativeURLs != normalizedURLs else {
                // Publishing is independently de-duplicated. This covers a reload that replaces a
                // renamed row at the same selected index without AppKit sending a delegate callback.
                publishPreviewSelection(nativeNodes)
                return
            }
            let target = IndexSet(urls.compactMap { url -> Int? in
                indexedSelectionLookupCount += 1
                guard let node = loadedNode(for: url) else { return nil }
                let row = ov.row(forItem: node)
                return row >= 0 ? row : nil
            })
            syncing = true
            if !target.isEmpty { ov.selectRowIndexes(target, byExtendingSelection: false) }
            else { ov.deselectAll(nil) }
            syncing = false
            publishPreviewSelection(selectedNodes())
        }

        // MARK: inline rename

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, let ov = outline else { return }
            let row = ov.row(for: field)
            guard row >= 0, let node = ov.item(atRow: row) as? FileNode else { return }
            let newName = field.stringValue
            field.stringValue = node.name    // onRename re-reads from disk + bumps the token
            if newName != node.name { parent.onRename(node.fileEntry, newName) }
        }

        func renameSelected() {
            guard let ov = outline, ov.selectedRowIndexes.count == 1, ov.selectedRow >= 0 else { return }
            ov.editColumn(0, row: ov.selectedRow, with: nil, select: true)
        }

        func quickLookSelected() {
            guard let ov = outline, ov.selectedRowIndexes.count == 1, ov.selectedRow >= 0,
                  let node = ov.item(atRow: ov.selectedRow) as? FileNode, !node.isDir else { return }
            parent.onQuickLook(node.url)
        }

        // MARK: context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let ov = outline, ov.clickedRow >= 0,
                  let node = ov.item(atRow: ov.clickedRow) as? FileNode else { return }
            let selectedNodes = selectedNodes()
            let targets = FileBrowserSelection.actionTargets(
                clicked: node.url,
                selectedInDisplayOrder: selectedNodes.map(\.url))
            let isBulk = targets.count > 1
            let canOpenInBatch = isBulk && selectedNodes.allSatisfy { !$0.isDir }

            func add(_ title: String, _ sel: Selector, _ object: Any) {
                let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                i.target = self; i.representedObject = object; menu.addItem(i)
            }
            add(isBulk ? "Ask your agent about these items" : "Ask your agent about this",
                #selector(miAsk(_:)), targets)
            add(node.isDir ? "Watch This Folder…" : "Watch This File…", #selector(miWatch(_:)), node)
            menu.addItem(.separator())
            if !node.isDir { add("Quick Look", #selector(miQuickLook(_:)), node) }
            if canOpenInBatch {
                add("Open \(targets.count) Items", #selector(miOpen(_:)), FileOpenTargets(urls: targets))
            } else {
                add(node.isDir ? "Open as Root" : "Open", #selector(miOpen(_:)),
                    FileOpenTargets(urls: [node.url], opensFolderAsRoot: node.isDir))
            }
            add(isBulk ? "Reveal \(targets.count) Items in Finder" : "Reveal in Finder",
                #selector(miReveal(_:)), targets)
            // Beside Reveal, where Finder puts it. `NSSharingServicePicker` rather than a list we
            // build: it carries every service this Mac actually has, including ones the person
            // added, and it is the control a Mac user already knows.
            add(isBulk ? "Share \(targets.count) Items…" : "Share…", #selector(miShare(_:)), targets)
            menu.addItem(.separator())
            add(isBulk ? "Copy \(targets.count) Items" : "Copy", #selector(miCopy(_:)), targets)
            add(isBulk ? "Copy \(targets.count) Paths" : "Copy Path", #selector(miCopyPath(_:)), targets)
            if !isBulk { add("Rename", #selector(miRename(_:)), node) }
            menu.addItem(.separator())
            add(FileBrowserSelection.trashTitle(count: targets.count), #selector(miTrash(_:)), targets)
        }

        private struct FileOpenTargets {
            let urls: [URL]
            var opensFolderAsRoot = false
        }

        private func node(_ s: Any?) -> FileNode? { (s as? NSMenuItem)?.representedObject as? FileNode }
        private func urls(_ s: Any?) -> [URL] {
            (s as? NSMenuItem)?.representedObject as? [URL] ?? []
        }

        @objc private func miAsk(_ s: NSMenuItem) {
            let targets = urls(s)
            guard !targets.isEmpty else { return }
            if targets.count == 1, let target = targets.first {
                parent.onInject("Take a look at \(target.path) and tell me about it.")
                return
            }
            let paths = targets.map(\.path).joined(separator: "\n")
            parent.onInject("Take a look at these files and folders:\n\(paths)\nTell me about them.")
        }
        /// Anchored on the row that was clicked, so the popover comes out of the file rather than
        /// the corner of the window. Falls back to the outline view when the row cannot be resolved,
        /// which is better than a picker that appears to belong to nothing.
        @objc private func miShare(_ s: NSMenuItem) {
            let targets = urls(s)
            guard !targets.isEmpty, let outline else { return }
            let picker = NSSharingServicePicker(items: targets as [Any])
            let row = outline.clickedRow
            let anchor: NSView = row >= 0 ? (outline.rowView(atRow: row, makeIfNecessary: false) ?? outline) : outline
            picker.show(
                relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        }

        @objc private func miWatch(_ s: NSMenuItem) { if let n = node(s) { parent.onWatch(n.url) } }
        @objc private func miQuickLook(_ s: NSMenuItem) { if let n = node(s) { parent.onQuickLook(n.url) } }
        @objc private func miOpen(_ s: NSMenuItem) {
            guard let targets = s.representedObject as? FileOpenTargets else { return }
            if targets.opensFolderAsRoot, let folder = targets.urls.first {
                parent.onActivate(folder, true)
            } else {
                targets.urls.forEach { parent.onActivate($0, false) }
            }
        }
        @objc private func miReveal(_ s: NSMenuItem) {
            let targets = urls(s)
            if !targets.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(targets) }
        }
        @objc private func miCopy(_ s: NSMenuItem) {
            let targets = urls(s)
            guard !targets.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(targets.map { $0 as NSURL })
        }
        @objc private func miCopyPath(_ s: NSMenuItem) {
            let targets = urls(s)
            guard !targets.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(targets.map(\.path).joined(separator: "\n"), forType: .string)
        }
        @objc private func miRename(_ s: NSMenuItem) {
            guard let n = node(s), let ov = outline else { return }
            let row = ov.row(forItem: n); guard row >= 0 else { return }
            ov.selectRowIndexes([row], byExtendingSelection: false)
            ov.editColumn(0, row: row, with: nil, select: true)
        }
        @objc private func miTrash(_ s: NSMenuItem) {
            let trashed = Self.trashDraggedItems(urls(s))
            guard !trashed.isEmpty else { return }
            finishTrash(trashed)
        }
    }
}
