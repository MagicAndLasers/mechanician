import Foundation

/// File representation for an artifact, shared by drag-to-Finder and Save… (FR-95). An artifact is
/// a `source` string plus a `type`; getting it *out* of the app means writing that source to a real
/// file with the extension the type implies, so Finder/Mail/other apps treat it natively. Keeping
/// extension + filename policy here stops the export surfaces from drifting apart — the same lesson
/// as `ConversationMarkdownExport`.
enum ArtifactFileExport {
    static var temporaryExportsRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Mechanician Artifact Exports", isDirectory: true)
    }

    /// Map an artifact type to the file extension a Mac would expect. Unknown/plain types fall back
    /// to `.txt` so the file is still openable rather than extensionless.
    static func fileExtension(for type: String) -> String {
        switch type.lowercased() {
        case "html":     return "html"
        case "svg":      return "svg"
        case "mermaid":  return "mmd"
        case "csv":      return "csv"
        case "markdown", "md": return "md"
        default:         return "txt"
        }
    }

    /// Inverse of `fileExtension(for:)` for drag-and-drop IN (FR-102): map a dropped file's extension
    /// to the artifact type that renders it natively. Returns nil for extensions Mechanician can't
    /// render as an artifact, so an import silently skips (and reports) files it can't honor rather
    /// than creating a mis-typed artifact. Keeping the mapping beside its inverse stops the import and
    /// export sides from drifting apart.
    static func artifactType(forFileExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "html", "htm":              return "html"
        case "svg":                      return "svg"
        case "mmd", "mermaid":           return "mermaid"
        case "csv":                      return "csv"
        case "md", "markdown", "mdown", "txt", "text": return "markdown"
        default:                         return nil
        }
    }

    static func filename(for artifact: Artifact) -> String {
        let forbidden = CharacterSet.controlCharacters
            .union(.newlines)
            .union(CharacterSet(charactersIn: "/:"))
        var base = artifact.title.unicodeScalars
            .map { forbidden.contains($0) ? " " : String($0) }
            .joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        if base.isEmpty { base = "Artifact" }
        base = String(base.prefix(120))
        return base + "." + fileExtension(for: artifact.type)
    }

    static func write(_ artifact: Artifact, to url: URL) throws {
        try artifact.source.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Finder requires a file-backed pasteboard item. Each artifact gets a stable temporary
    /// directory keyed by its id, so repeated drags refresh the contents in place rather than
    /// proliferating anonymous files. Mirrors `ConversationMarkdownExport.temporaryFile`.
    static func temporaryFile(
        for artifact: Artifact,
        root exportsRoot: URL = temporaryExportsRoot
    ) throws -> URL {
        let root = exportsRoot
            .appendingPathComponent(artifact.uuid.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(filename(for: artifact), isDirectory: false)
        try write(artifact, to: url)
        return url
    }

    /// The exports root is app-owned scratch space. Removing it at launch clears files left by a
    /// crash; removing it on clean quit prevents ordinary sessions from accumulating them.
    static func removeTemporaryExports(
        root: URL = temporaryExportsRoot,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: root)
    }

    /// Evict one old mapping without recursively removing its UUID directory when a newer renamed
    /// export for the same artifact is still present beside it.
    static func removeTemporaryExport(
        at url: URL,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: url)
        let parent = url.deletingLastPathComponent()
        guard let remaining = try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil),
            remaining.isEmpty else { return }
        try? fileManager.removeItem(at: parent)
    }

    static func contains(_ url: URL, in root: URL = temporaryExportsRoot) -> Bool {
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        let parent = root.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == parent || candidate.hasPrefix(parent + "/")
    }
}
