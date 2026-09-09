import AppKit
import Darwin
import SwiftUI

struct TranscriptFileActionEnvironment {
    var openInDefaultApplication: @MainActor (URL) -> Bool
    var revealInFinder: @MainActor (URL) -> Void
    var copyPath: @MainActor (String) -> Void

    static let live = TranscriptFileActionEnvironment(
        openInDefaultApplication: { NSWorkspace.shared.open($0) },
        revealInFinder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        copyPath: { path in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        })
}

/// Routes links clicked in assistant transcript Markdown. Web/custom-scheme links retain SwiftUI's
/// normal system handling; path-shaped and `file:` links stay inside Mechanician.
@MainActor
enum TranscriptLinkHandler {
    static func open(_ url: URL, relativeTo cwd: String) -> OpenURLAction.Result {
        handleLocal(url, relativeTo: cwd) ? .handled : .systemAction
    }

    /// Opens a local/path link inside Mechanician (in-app preview, or hands binary files to Launch
    /// Services). Returns `false` when the link is NOT a local file, so the caller routes it to the
    /// system (web + custom-scheme links). Split out from `open` because the AppKit transcript's
    /// `clickedOnLink` delegate cannot consume SwiftUI's `.systemAction` — it must open web links
    /// itself, which is why plain web links in the transcript previously did nothing.
    @discardableResult
    static func handleLocal(
        _ url: URL,
        relativeTo cwd: String,
        actions: TranscriptFileActionEnvironment = .live
    ) -> Bool {
        guard let fileURL = localFileURL(from: url, relativeTo: cwd) else {
            return false
        }

        guard validateRegularFile(fileURL) else { return true }

        do {
            try TranscriptFilePreview.shared.show(fileURL, actions: actions)
        } catch {
            // Binary formats do not belong in the text preview. Let Launch Services hand DMGs,
            // PDFs, archives, images, and similar files to their normal Mac application.
            guard actions.openInDefaultApplication(fileURL) else {
                showError("Couldn't open this file", detail: "\(fileURL.path)\n\n\(error.localizedDescription)")
                return true
            }
        }
        return true
    }

    /// A local transcript link is one Mac object with several deliberate exits. Ordinary click
    /// keeps FR-18's in-app behavior; the link menu exposes the same external actions as Files and
    /// Artifacts instead of making the preview a dead end.
    static func contextMenu(for url: URL, relativeTo cwd: String) -> NSMenu? {
        guard let fileURL = localFileURL(from: url, relativeTo: cwd),
              regularFileExists(fileURL) else {
            return nil
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuItem(
            "Preview in Mechanician",
            action: #selector(TranscriptFileMenuController.previewInMechanician(_:)),
            fileURL: fileURL))
        menu.addItem(menuItem(
            "Open in Default App",
            action: #selector(TranscriptFileMenuController.openInDefaultApplication(_:)),
            fileURL: fileURL))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            "Reveal in Finder",
            action: #selector(TranscriptFileMenuController.revealInFinder(_:)),
            fileURL: fileURL))
        menu.addItem(menuItem(
            "Copy Path",
            action: #selector(TranscriptFileMenuController.copyPath(_:)),
            fileURL: fileURL))
        return menu
    }

    static func previewInMechanician(
        _ fileURL: URL,
        actions: TranscriptFileActionEnvironment = .live
    ) {
        guard validateRegularFile(fileURL) else { return }
        do {
            try TranscriptFilePreview.shared.show(fileURL, actions: actions)
        } catch {
            showError(
                "Mechanician can't preview this file",
                detail: "\(fileURL.path)\n\nUse Open in Default App.\n\n\(error.localizedDescription)")
        }
    }

    static func openInDefaultApplication(
        _ fileURL: URL,
        actions: TranscriptFileActionEnvironment = .live
    ) {
        guard validateRegularFile(fileURL) else { return }
        guard actions.openInDefaultApplication(fileURL) else {
            showError("Couldn't open this file", detail: fileURL.path)
            return
        }
    }

    static func revealInFinder(
        _ fileURL: URL,
        actions: TranscriptFileActionEnvironment = .live
    ) {
        guard validateRegularFile(fileURL) else { return }
        actions.revealInFinder(fileURL)
    }

    static func copyPath(
        _ fileURL: URL,
        actions: TranscriptFileActionEnvironment = .live
    ) {
        actions.copyPath(fileURL.path)
    }

    /// Absolute path-shaped Markdown destinations have no URL scheme, which is why handing them to
    /// Launch Services fails with error -50. Convert local paths explicitly; relative paths resolve
    /// against the active conversation's working directory.
    static func localFileURL(from url: URL, relativeTo cwd: String) -> URL? {
        if url.isFileURL {
            return resolvingSourceLocation(
                URL(fileURLWithPath: url.path).standardizedFileURL)
        }
        guard url.scheme == nil else { return nil }

        let path = (url.path as NSString).expandingTildeInPath
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") {
            return resolvingSourceLocation(
                URL(fileURLWithPath: path).standardizedFileURL)
        }
        guard !cwd.isEmpty else { return nil }
        return resolvingSourceLocation(URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(path)
            .standardizedFileURL)
    }

    /// Markdown source references conventionally append `:line` or `:line:column`. Prefer the
    /// exact path first so a real filename ending in digits after a colon always wins. Only strip
    /// a location suffix when the exact path is absent and the unsuffixed path is an existing file.
    private static func resolvingSourceLocation(_ exactURL: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: exactURL.path, isDirectory: &isDirectory) {
            return exactURL
        }

        let parts = exactURL.path.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let finalNumber = Int(parts[parts.count - 1]), finalNumber > 0 else {
            return exactURL
        }

        var suffixCount = 1
        if parts.count >= 3,
           let precedingNumber = Int(parts[parts.count - 2]), precedingNumber > 0 {
            suffixCount = 2
        }
        let basePath = parts.dropLast(suffixCount).joined(separator: ":")
        guard !basePath.isEmpty else { return exactURL }

        let baseURL = URL(fileURLWithPath: basePath).standardizedFileURL
        isDirectory = false
        guard FileManager.default.fileExists(atPath: baseURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return exactURL
        }
        return baseURL
    }

    private static func regularFileExists(_ fileURL: URL) -> Bool {
        var info = stat()
        let result = fileURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.fstatat(AT_FDCWD, path, &info, 0)
        }
        return result == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func validateRegularFile(_ fileURL: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            showError("File not found", detail: fileURL.path)
            return false
        }
        guard !isDirectory.boolValue else {
            showError("This link points to a folder", detail: fileURL.path)
            return false
        }
        guard regularFileExists(fileURL) else {
            showError("This link doesn't point to a regular file", detail: fileURL.path)
            return false
        }
        return true
    }

    private static func menuItem(
        _ title: String,
        action: Selector,
        fileURL: URL
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = TranscriptFileMenuController.shared
        item.representedObject = fileURL
        item.isEnabled = true
        return item
    }

    private static func showError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

@MainActor
private final class TranscriptFileMenuController: NSObject {
    static let shared = TranscriptFileMenuController()

    @objc func previewInMechanician(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        TranscriptLinkHandler.previewInMechanician(url)
    }

    @objc func openInDefaultApplication(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        TranscriptLinkHandler.openInDefaultApplication(url)
    }

    @objc func revealInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        TranscriptLinkHandler.revealInFinder(url)
    }

    @objc func copyPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        TranscriptLinkHandler.copyPath(url)
    }
}

enum TranscriptFilePreviewError: LocalizedError {
    case tooLarge(maxBytes: Int)
    case notUTF8
    case notRegularFile

    var errorDescription: String? {
        switch self {
        case .tooLarge(let maxBytes):
            let limit = ByteCountFormatter.string(
                fromByteCount: Int64(maxBytes),
                countStyle: .file)
            return "Text previews are limited to \(limit)."
        case .notUTF8:
            return "This file is not UTF-8 text."
        case .notRegularFile:
            return "This path does not point to a regular file."
        }
    }
}

/// A reusable in-app text/Markdown window for local transcript links. The represented URL and
/// visible path make its file identity explicit; normal Mac exits remain one click away.
@MainActor
final class TranscriptFilePreview {
    static let shared = TranscriptFilePreview()
    static let maxPreviewBytes = 2 * 1_024 * 1_024
    private var window: NSWindow?

    static func text(at url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > maxPreviewBytes {
            throw TranscriptFilePreviewError.tooLarge(maxBytes: maxPreviewBytes)
        }

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
            throw TranscriptFilePreviewError.notRegularFile
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxPreviewBytes + 1) ?? Data()
        guard data.count <= maxPreviewBytes else {
            throw TranscriptFilePreviewError.tooLarge(maxBytes: maxPreviewBytes)
        }
        guard !data.prefix(8_192).contains(0),
              let text = String(data: data, encoding: .utf8) else {
            throw TranscriptFilePreviewError.notUTF8
        }
        return text
    }

    func show(
        _ url: URL,
        actions: TranscriptFileActionEnvironment = .live
    ) throws {
        let text = try Self.text(at: url)
        let root = TranscriptFilePreviewView(
            url: url,
            text: text,
            isMarkdown: QuickLookController.isMarkdown(url),
            baseDirectory: url.deletingLastPathComponent().path,
            actions: actions
        )
        let host = NSHostingController(rootView: root)

        let previewWindow: NSWindow
        if let window {
            previewWindow = window
        } else {
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
            let width = min(1_000, visible.width * 0.75)
            let height = min(900, visible.height * 0.82)
            previewWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            previewWindow.isReleasedWhenClosed = false
            previewWindow.minSize = NSSize(width: 600, height: 420)
            previewWindow.setFrameAutosaveName("TranscriptFilePreviewWindow")
            previewWindow.center()
            window = previewWindow
        }

        previewWindow.title = url.lastPathComponent
        previewWindow.representedURL = url
        previewWindow.contentViewController = host
        previewWindow.makeKeyAndOrderFront(nil)
    }
}

private struct TranscriptFilePreviewView: View {
    let url: URL
    let text: String
    let isMarkdown: Bool
    let baseDirectory: String
    let actions: TranscriptFileActionEnvironment

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(url.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .textSelection(.enabled)
                        .accessibilityLabel("File location")
                        .accessibilityValue(url.path)
                }
                .help(url.path)

                HStack(spacing: 8) {
                    Button("Open in Default App") {
                        TranscriptLinkHandler.openInDefaultApplication(url, actions: actions)
                    }
                    Button("Reveal in Finder") {
                        TranscriptLinkHandler.revealInFinder(url, actions: actions)
                    }
                    Button("Copy Path") {
                        TranscriptLinkHandler.copyPath(url, actions: actions)
                    }
                    Spacer()
                }
                .buttonStyle(PillButtonStyle(kind: .neutral))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if isMarkdown {
                            MarkdownText(text: text)
                        } else {
                            Text(text).font(.system(size: 12, design: .monospaced))
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .id(Self.topAnchor)
                }
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo(Self.topAnchor, anchor: .top) }
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            TranscriptLinkHandler.open(url, relativeTo: baseDirectory)
        })
        .frame(minWidth: 600, minHeight: 420)
        .background(Color.nBg)
    }

    private static let topAnchor = "transcript-file-preview-top"
}
