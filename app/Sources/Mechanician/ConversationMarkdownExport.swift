import Foundation

/// The single Markdown representation used by Save, Share, and drag-to-Finder. Keeping filename
/// policy and document construction here prevents the three export surfaces from drifting apart.
struct ConversationMarkdownDocument: Equatable, Sendable {
    /// APFS limits one filename component to 255 UTF-8 bytes. Leave room for Finder's collision
    /// suffixes instead of counting Swift Characters (one extended grapheme may be many bytes).
    static let maximumFilenameUTF8Bytes = 200

    let filename: String
    let contents: String

    init(conversation: Conversation) {
        let title = conversation.displayTitle
        filename = Self.filename(for: title)

        let oneLineTitle = title
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = oneLineTitle.isEmpty ? "Conversation" : oneLineTitle
        let transcript = AgentBridge.transcriptMarkdown(conversation.messages)
        contents = transcript.isEmpty
            ? "# \(heading)\n"
            : "# \(heading)\n\n\(transcript)\n"
    }

    static func filename(for title: String) -> String {
        let forbidden = CharacterSet.controlCharacters
            .union(.newlines)
            .union(CharacterSet(charactersIn: "/:"))
        let mapped = title.unicodeScalars.map { scalar -> String in
            forbidden.contains(scalar) ? "-" : String(scalar)
        }.joined()
        var base = mapped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))

        while base.contains(" -") || base.contains("- ") {
            base = base
                .replacingOccurrences(of: " -", with: "-")
                .replacingOccurrences(of: "- ", with: "-")
        }
        while base.contains("--") {
            base = base.replacingOccurrences(of: "--", with: "-")
        }
        if base.lowercased().hasSuffix(".md") {
            base.removeLast(3)
            base = base.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        }
        if base.isEmpty { base = "Conversation" }
        let suffix = ".md"
        let contentBudget = maximumFilenameUTF8Bytes - suffix.utf8.count
        var bounded = ""
        var bytes = 0
        for character in base {
            let width = String(character).utf8.count
            guard bytes + width <= contentBudget else { break }
            bounded.append(character)
            bytes += width
        }
        if bounded.isEmpty { bounded = "Conversation" }
        return bounded + suffix
    }
}

enum ConversationMarkdownExport {
    /// Rendering a 10,000-row transcript can be as expensive as decoding it. Share, Save, and file
    /// promises all pass through this serial queue so none of those surfaces moves the stall back
    /// onto the main actor after off-main hydration succeeds.
    private static let renderingQueue = DispatchQueue(
        label: "ai.mechanician.conversation-markdown-render",
        qos: .userInitiated)

    /// Resolve an inventory-only conversation without blocking AppKit. Concurrent requests
    /// coalesce in `ConversationStore`, rendering stays off-main, and a failed binding produces no
    /// placeholder document for an export surface to write.
    @MainActor
    static func document(
        for conversationID: UUID,
        in store: ConversationStore,
        completion: @escaping @MainActor (
            Result<ConversationMarkdownDocument, ConversationHydrationError>
        ) -> Void
    ) {
        store.acquireConversation(conversationID) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
                store.trimResidencyIfNeeded()
            case .success(let conversation):
                renderingQueue.async {
                    let document = ConversationMarkdownDocument(conversation: conversation)
                    Task { @MainActor in
                        completion(.success(document))
                        store.trimResidencyIfNeeded()
                    }
                }
            }
        }
    }

    static func write(_ document: ConversationMarkdownDocument, to url: URL) throws {
        try document.contents.write(to: url, atomically: true, encoding: .utf8)
    }

    static func temporaryFile(
        for document: ConversationMarkdownDocument,
        conversationID: UUID
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mechanician Conversation Exports", isDirectory: true)
            .appendingPathComponent(conversationID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(document.filename, isDirectory: false)
        try write(document, to: url)
        return url
    }

}
