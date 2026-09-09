import AppKit
import Foundation

/// One bounded policy for every user-authored attachment batch (native drop, picker, or promised
/// files). The individual storage primitive still keeps its 64 MiB defensive ceiling, but a single
/// gesture must never synchronously copy an unbounded number of files on the main actor.
struct ConversationAttachmentImportBudget {
    static let maximumFiles = 4
    static let maximumBytes = 16 * 1024 * 1024
    static let limitMessage =
        "[Attachment limit reached. Add at most 4 files and 16 MB at a time]"

    private(set) var attemptedFiles = 0
    private(set) var remainingBytes = maximumBytes
    private var reportedLimit = false

    /// Reserve one authored position and return the largest copy it may commit. Failed attempts
    /// still consume a file slot, while only successfully committed bytes consume the byte budget.
    mutating func beginAttachment() -> Int? {
        guard attemptedFiles < Self.maximumFiles else { return nil }
        attemptedFiles += 1
        return remainingBytes
    }

    mutating func recordCommittedBytes(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        remainingBytes = max(0, remainingBytes - min(byteCount, remainingBytes))
    }

    /// Keep a multi-receiver/legacy promise from repeating the same limit warning for every omitted
    /// file. Callers may remove later placeholders silently once this message has been shown.
    mutating func takeLimitMessage() -> String? {
        guard !reportedLimit else { return nil }
        reportedLimit = true
        return Self.limitMessage
    }
}

/// One canonical decision point for file URLs arriving from the native text view, whole-chat drop,
/// the paperclip picker, Launch Services, or a fulfilled file promise. Keeping this classification
/// shared prevents one route from persisting a durable file token while another silently stores an
/// external path.
@MainActor
enum ConversationAttachmentIntake {
    enum Result {
        case artifact(ArtifactDragReference)
        case image(url: URL, image: NSImage)
        case file(reference: ConversationFileReference, ownedURL: URL)
        case externalFile(URL)
        case unavailable(displayName: String)

        var committedByteCount: Int {
            switch self {
            case .file(let reference, _):
                return reference.byteCount
            case .image(let url, _):
                return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            case .artifact, .externalFile, .unavailable:
                return 0
            }
        }

        var promptPayload: String {
            switch self {
            case .artifact(let reference): return reference.promptToken
            case .image(let url, _), .externalFile(let url): return url.path
            case .file(let reference, _): return reference.promptToken
            case .unavailable(let displayName):
                return "[Attachment unavailable: \(displayName)]"
            }
        }
    }

    static func ingest(
        _ url: URL,
        conversationID: UUID?,
        needsSecurityScopedAccess: Bool = false,
        sourceIsEphemeral: Bool = false,
        maximumBytes: Int = ConversationMediaStorage.maximumComposerFileBytes,
        store explicitStore: ConversationStore? = nil
    ) -> Result {
        let store = explicitStore ?? .shared
        guard url.isFileURL else {
            return .unavailable(displayName: url.lastPathComponent)
        }
        let accessed = needsSecurityScopedAccess
            ? url.startAccessingSecurityScopedResource()
            : false
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return .unavailable(displayName: url.lastPathComponent)
        }
        if let reference = ArtifactActions.reference(forExportedURL: url) {
            return .artifact(reference)
        }
        if ConversationFileReference.usesImageAttachmentBehavior(for: url) {
            if let conversationID {
                if let ownedURL = store.persistComposerImageFile(
                    at: url,
                    conversationID: conversationID,
                    maximumBytes: maximumBytes
                ) {
                    if let image = NSImage(contentsOf: ownedURL) {
                        return .image(url: ownedURL, image: image)
                    }
                    // An image-looking extension with undecodable bytes belongs on the generic-file
                    // path, not as a broken image. Remove the provisional owned image before that copy.
                    try? FileManager.default.removeItem(at: ownedURL)
                }
            } else if !sourceIsEphemeral,
                      let image = NSImage(contentsOf: url) {
                // Only isolated/test composers lack a durable conversation owner.
                return .image(url: url, image: image)
            }
        }
        guard let conversationID else {
            return sourceIsEphemeral
                ? .unavailable(displayName: url.lastPathComponent)
                : .externalFile(url)
        }
        guard let reference = store.persistComposerFile(
            at: url,
            conversationID: conversationID,
            maximumBytes: maximumBytes),
              let ownedURL = store.composerFileURL(
                conversationID: conversationID,
                reference: reference) else {
            return .unavailable(displayName: url.lastPathComponent)
        }
        return .file(reference: reference, ownedURL: ownedURL)
    }
}
