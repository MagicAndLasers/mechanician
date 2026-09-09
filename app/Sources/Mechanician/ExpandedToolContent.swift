import SwiftUI
import AppKit

/// The expensive, expanded portion of a tool card. Keeping it in an equatable leaf means an
/// unrelated status/tool event can still update the transcript without re-parsing every unchanged
/// expanded result. The parent passes immutable entry data only; this view observes no bridge state.
struct ExpandedToolContent: View, Equatable {
    let entry: TranscriptEntry
    let capturedImage: NSImage?
    let persistedImageURL: URL?
    let chatScale: CGFloat

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry.id == rhs.entry.id
            && lhs.entry.toolName == rhs.entry.toolName
            && lhs.entry.text == rhs.entry.text
            && lhs.entry.toolResult == rhs.entry.toolResult
            && lhs.entry.toolIsError == rhs.entry.toolIsError
            && lhs.entry.toolState == rhs.entry.toolState
            && lhs.entry.toolImage == rhs.entry.toolImage
            && lhs.persistedImageURL == rhs.persistedImageURL
            && lhs.chatScale == rhs.chatScale
            && sameImage(lhs.capturedImage, rhs.capturedImage)
    }

    @ViewBuilder
    var body: some View {
        let parsedInput = parsedInput()
        let inputObject = parsedInput as? [String: Any]
        let language = languageForTool(inputObject)
        if hasToolImage {
            Divider()
            CapturedToolImagePreview(
                liveImage: capturedImage,
                fileURL: persistedImageURL,
                reference: entry.toolImage,
                isRunning: entry.resolvedToolState == .running,
                isScreenshot: isScreenshotTool,
                chatScale: chatScale)
                .padding(8)
        } else if let image = imageForTool(inputObject) {
            Divider()
            Image(nsImage: image)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 340 * chatScale)
                .padding(8)
                .textSelection(.disabled)
        } else if let editDiff = synthDiff(inputObject) {
            // Show what a file edit changed as a colored +/- diff.
            Divider()
            toolResultView(preview(editDiff), language: language, isDiff: true, isError: false)
                .padding(8)
        } else {
            // The title is a friendly summary, so surface the full input here as detail, followed
            // by the result. Both presentations are bounded to the same visible preview length.
            if let detail = toolInputDetail(parsedInput) {
                Divider()
                toolResultView(
                    preview(detail.text),
                    language: detail.language,
                    isDiff: false,
                    isError: false)
                    .padding(8)
            }
            if let result = entry.toolResult {
                let visibleResult = preview(result)
                Divider()
                toolResultView(
                    visibleResult,
                    language: language,
                    isDiff: AgentBridge.looksLikeDiff(visibleResult),
                    isError: entry.toolIsError)
                    .padding(8)
            }
        }
    }

    @ViewBuilder
    private func toolResultView(_ text: String, language: String?,
                                isDiff: Bool, isError: Bool) -> some View {
        if isDiff {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    let (attr, background) = SyntaxHighlighter.diffLine(
                        line.isEmpty ? " " : line,
                        language: language,
                        fontSize: 11 * chatScale)
                    Text(attr)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .background(background)
                }
            }
            .textSelection(.enabled)
        } else if let language, !isError {
            Text(SyntaxHighlighter.highlight(text, language: language, fontSize: 11 * chatScale))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text)
                .font(.system(size: 11 * chatScale, design: .monospaced))
                .foregroundStyle(isError ? .red : Color.nText.opacity(0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Bound before classification/highlighting. A marker beyond the visible prefix cannot affect
    /// the styling of the text actually shown, and this avoids full-result `count`/regex scans.
    private func preview(_ text: String) -> String {
        let limit = AgentBridge.toolResultPreviewCharacters
        guard let end = text.index(
            text.startIndex, offsetBy: limit, limitedBy: text.endIndex),
            end != text.endIndex else { return text }
        return String(text[..<end]) + "\n…"
    }

    private func toolInputDetail(_ parsedInput: Any?) -> ToolInputDetail? {
        let raw = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if let input = parsedInput as? [String: Any] {
            if entry.toolName == "Write", let content = input["content"] as? String {
                return ToolInputDetail(text: content, language: languageForTool(input))
            }
            if entry.toolName == "NotebookEdit", let content = input["new_source"] as? String {
                return ToolInputDetail(text: content, language: languageForTool(input))
            }
            if entry.toolName == "Bash", let command = input["command"] as? String {
                return ToolInputDetail(text: command, language: "shell")
            }
        }
        if let object = parsedInput,
           JSONSerialization.isValidJSONObject(object),
           let pretty = try? JSONSerialization.data(
               withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            return ToolInputDetail(text: text, language: "json")
        }
        return ToolInputDetail(text: raw, language: nil)
    }

    private func languageForTool(_ input: [String: Any]?) -> String? {
        let codeTools: Set<String> = ["Read", "Write", "Edit", "MultiEdit", "NotebookEdit"]
        guard let name = entry.toolName, let input else { return nil }
        if codeTools.contains(name) {
            let path = (input["file_path"] as? String)
                ?? (input["notebook_path"] as? String)
                ?? codexChangePath(input)
            guard let path else { return nil }
            return SyntaxHighlighter.canonicalLanguage((path as NSString).pathExtension)
        }
        if name == "Bash", let command = input["command"] as? String {
            return inferredCommandOutputLanguage(command)
        }
        if name == "Grep" {
            let candidate = (input["glob"] as? String) ?? (input["path"] as? String)
            if let candidate {
                return SyntaxHighlighter.canonicalLanguage((candidate as NSString).pathExtension)
            }
        }
        return nil
    }

    private func codexChangePath(_ input: [String: Any]) -> String? {
        guard let changes = input["changes"] as? [[String: Any]] else { return nil }
        return changes.compactMap { $0["path"] as? String }.first
    }

    private func synthDiff(_ input: [String: Any]?) -> String? {
        guard let name = entry.toolName, name == "Edit" || name == "MultiEdit",
              let input else { return nil }
        var output: [String] = []
        func emit(_ oldText: String, _ newText: String) {
            for line in oldText.components(separatedBy: "\n") where !(line.isEmpty && oldText.isEmpty) {
                output.append("- " + line)
            }
            for line in newText.components(separatedBy: "\n") where !(line.isEmpty && newText.isEmpty) {
                output.append("+ " + line)
            }
        }
        if let edits = input["edits"] as? [[String: Any]] {
            for edit in edits {
                emit(edit["old_string"] as? String ?? "", edit["new_string"] as? String ?? "")
            }
        } else if let oldText = input["old_string"] as? String,
                  let newText = input["new_string"] as? String {
            emit(oldText, newText)
        } else if let changes = input["changes"] as? [[String: Any]] {
            for change in changes {
                guard let diff = change["diff"] as? String, !diff.isEmpty else { continue }
                if let path = change["path"] as? String, !path.isEmpty {
                    let displayPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
                    output.append("diff --git a/\(displayPath) b/\(displayPath)")
                }
                output.append(diff)
            }
        } else {
            return nil
        }
        return output.isEmpty ? nil : output.joined(separator: "\n")
    }

    private var isScreenshotTool: Bool {
        (entry.toolName ?? "").hasSuffix("ComputerScreenshot")
    }

    private var hasToolImage: Bool {
        isScreenshotTool || entry.toolImage != nil || capturedImage != nil || persistedImageURL != nil
    }

    /// A Read of a renderable image loads a historical snapshot when the card expands. Tool-produced
    /// images use their per-conversation durable reference through CapturedToolImagePreview.
    private func imageForTool(_ input: [String: Any]?) -> NSImage? {
        guard entry.toolName == "Read",
              let path = input?["file_path"] as? String,
              AgentBridge.isRenderableImage(path) else { return nil }
        return NSImage(contentsOfFile: path)
    }

    private func parsedInput() -> Any? {
        guard let data = entry.text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func sameImage(_ lhs: NSImage?, _ rhs: NSImage?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs === rhs
        default: return false
        }
    }
}

private struct ToolInputDetail {
    let text: String
    let language: String?
}

/// Best-effort language inference for commands that print source (`sed`, `cat`, bounded grep, etc.).
/// The result remains plain when no path-like argument is present; the command itself is always
/// rendered as shell syntax above it.
func inferredCommandOutputLanguage(_ command: String) -> String? {
    let separators = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: "'\"`()[]{}<>,;|"))
    for token in command.components(separatedBy: separators).reversed() {
        let path = token.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { continue }
        if let language = SyntaxHighlighter.canonicalLanguage(ext) { return language }
    }
    return nil
}

/// Loads saved tool-image bytes only when the user opens that Activity action. The preview keeps a
/// stable bounded height while disk I/O runs, so loading cannot make the native row jump.
private struct CapturedToolImagePreview: View {
    let liveImage: NSImage?
    let fileURL: URL?
    let reference: ToolImageReference?
    let isRunning: Bool
    let isScreenshot: Bool
    let chatScale: CGFloat

    @State private var loadedImage: NSImage?
    @State private var finishedLoading = false

    private var previewHeight: CGFloat { 340 * chatScale }

    @ViewBuilder
    var body: some View {
        Group {
            if let image = liveImage ?? loadedImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: previewHeight)
            } else if fileURL != nil, !finishedLoading {
                VStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(isScreenshot ? "Loading screenshot…" : "Loading image…")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: previewHeight)
            } else if isRunning {
                Label(
                    isScreenshot ? "Capturing screenshot…" : "Generating image…",
                    systemImage: isScreenshot ? "camera.viewfinder" : "photo")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 84 * chatScale)
            } else {
                VStack(spacing: 6) {
                    Label("Preview unavailable", systemImage: "photo.badge.exclamationmark")
                        .font(.system(size: 12 * chatScale, weight: .semibold))
                    Text(reference == nil
                         ? (isScreenshot
                             ? "This screenshot was created before Mechanician saved transcript previews."
                             : "This image was created before Mechanician saved transcript previews.")
                         : (isScreenshot
                             ? "The saved screenshot file could not be loaded."
                             : "The saved image file could not be loaded."))
                        .font(.system(size: 11 * chatScale))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 84 * chatScale)
            }
        }
        .background(Color.nSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .textSelection(.disabled)
        .task(id: fileURL?.path) {
            loadedImage = nil
            finishedLoading = liveImage != nil || fileURL == nil
            guard liveImage == nil, let fileURL else { return }
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: fileURL, options: [.mappedIfSafe])
            }.value
            guard !Task.isCancelled else { return }
            loadedImage = data.flatMap(NSImage.init(data:))
            finishedLoading = true
        }
    }
}
