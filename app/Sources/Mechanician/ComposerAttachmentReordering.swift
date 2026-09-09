import AppKit
import CryptoKit

/// Authenticates app-private pasteboard fields for this process lifetime.
///
/// A custom UTI and a conversation UUID identify a format, not its author. Another process can
/// advertise either one. Bind hidden attachment payloads to a random in-memory key so a copied
/// descriptor may be replayed unchanged, but cannot be forged or edited into invisible prompt text.
enum ComposerPrivatePasteboardProvenance {
    enum Domain: String {
        case composerAttachmentDrag = "ai.mechanician.private.composer-attachment.v1"
        case composerClipboard = "ai.mechanician.private.composer-selection.v1"
        case artifactDrag = "ai.mechanician.private.artifact-reference.v1"

        fileprivate var authenticatedData: Data {
            Data(rawValue.utf8)
        }
    }

    /// One process-lifetime root makes private pasteboard values intentionally non-portable across
    /// launches. Derive independent encryption and authentication keys so the inner HMAC remains a
    /// second line of defense after AES-GCM has authenticated and opened the outer envelope.
    private static let rootKey = SymmetricKey(size: .bits256)
    private static let encryptionKey = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: rootKey,
        salt: Data("ai.mechanician.private-pasteboard.encryption".utf8),
        info: Data(),
        outputByteCount: 32)
    private static let authenticationKey = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: rootKey,
        salt: Data("ai.mechanician.private-pasteboard.authentication".utf8),
        info: Data(),
        outputByteCount: 32)
    /// AES-GCM's combined representation is a 12-byte nonce, ciphertext, and 16-byte tag.
    private static let sealedBoxOverhead = 28
    private static let authenticationCodeBytes = 32
    private static let maximumSignatureBytes = 256

    static func signature(for data: Data) -> String {
        Data(HMAC<SHA256>.authenticationCode(
            for: data,
            using: authenticationKey)).base64EncodedString()
    }

    static func validates(_ signature: String?, data: Data?) -> Bool {
        guard let signature,
              signature.utf8.count <= maximumSignatureBytes,
              let code = Data(base64Encoded: signature),
              code.count == authenticationCodeBytes,
              let data else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            code,
            authenticating: data,
            using: authenticationKey)
    }

    static func seal(
        _ plaintext: Data?,
        domain: Domain,
        maximumEncodedBytes: Int
    ) -> Data? {
        guard let plaintext,
              maximumEncodedBytes >= sealedBoxOverhead,
              plaintext.count <= maximumEncodedBytes - sealedBoxOverhead,
              let box = try? AES.GCM.seal(
                plaintext,
                using: encryptionKey,
                authenticating: domain.authenticatedData),
              let combined = box.combined,
              combined.count <= maximumEncodedBytes else { return nil }
        return combined
    }

    static func open(
        _ sealedData: Data?,
        domain: Domain,
        maximumEncodedBytes: Int
    ) -> Data? {
        // Bound attacker-controlled pasteboard bytes before constructing or authenticating a box.
        guard let sealedData,
              sealedData.count >= sealedBoxOverhead,
              sealedData.count <= maximumEncodedBytes,
              let box = try? AES.GCM.SealedBox(combined: sealedData),
              let plaintext = try? AES.GCM.open(
                box,
                using: encryptionKey,
                authenticating: domain.authenticatedData),
              plaintext.count <= maximumEncodedBytes - sealedBoxOverhead else {
            return nil
        }
        return plaintext
    }
}

/// Process-wide authority for a composer drag that is happening right now.
///
/// Encryption and the inner HMAC prove that a descriptor was minted by this process, but captured
/// pasteboard bytes remain cryptographically valid until the app quits. A nonce is therefore
/// accepted only while its source `NSDraggingSession` is alive. Cross-window composers share this
/// registry; the source retires the nonce from the session-ended callback on every terminal path.
@MainActor
enum ComposerAttachmentDragRegistry {
    private static var activeNonces: Set<UUID> = []

    static func register(_ nonce: UUID) {
        activeNonces.insert(nonce)
    }

    static func retire(_ nonce: UUID) {
        activeNonces.remove(nonce)
    }

    static func contains(_ nonce: UUID) -> Bool {
        activeNonces.contains(nonce)
    }
}

/// Deterministic attributed-range movement for composer attachments.
///
/// AppKit represents every image, generic file, and artifact chip as one attachment character with
/// its durable/provider payload stored in `ChatInput.payloadKey`. Reordering must move that exact
/// attributed range—not recreate a chip from display text—so its image, payload, and future metadata
/// survive together and serialized/provider order continues to match visual order.
enum ComposerAttachmentReordering {
    struct Move {
        let content: NSAttributedString
        /// Collapsed caret immediately after the moved attachment.
        let selection: NSRange
        /// Insertion index in the post-removal string.
        let insertionIndex: Int
    }

    /// Return the complete attachment attribute run containing one UTF-16 character index.
    static func attachmentRange(
        at characterIndex: Int,
        in content: NSAttributedString
    ) -> NSRange? {
        guard characterIndex >= 0, characterIndex < content.length else { return nil }
        var effectiveRange = NSRange(location: NSNotFound, length: 0)
        guard content.attribute(
            .attachment,
            at: characterIndex,
            longestEffectiveRange: &effectiveRange,
            in: NSRange(location: 0, length: content.length)) != nil,
              effectiveRange.location != NSNotFound,
              effectiveRange.length > 0 else { return nil }
        return effectiveRange
    }

    /// Move one complete attachment run to an insertion index measured in the original string.
    ///
    /// A destination within/either edge of the source is an idempotent no-op. Deleting a range
    /// before the destination shifts that destination left by the removed UTF-16 length. The
    /// operation never consumes neighboring whitespace or prose; those are authored content, even
    /// when a space was originally inserted beside a chip.
    static func move(
        in content: NSAttributedString,
        attachmentRange sourceRange: NSRange,
        to proposedInsertionIndex: Int
    ) -> Move? {
        guard sourceRange.location >= 0,
              sourceRange.length > 0,
              NSMaxRange(sourceRange) <= content.length,
              proposedInsertionIndex >= 0,
              proposedInsertionIndex <= content.length,
              let completeRange = attachmentRange(
                at: sourceRange.location,
                in: content),
              NSEqualRanges(completeRange, sourceRange)
        else { return nil }

        let sourceEnd = NSMaxRange(sourceRange)
        guard proposedInsertionIndex < sourceRange.location
                || proposedInsertionIndex > sourceEnd
        else { return nil }

        let insertionIndex = proposedInsertionIndex > sourceEnd
            ? proposedInsertionIndex - sourceRange.length
            : proposedInsertionIndex
        let moved = content.attributedSubstring(from: sourceRange)
        let result = NSMutableAttributedString(attributedString: content)
        result.deleteCharacters(in: sourceRange)
        result.insert(moved, at: insertionIndex)
        return Move(
            content: result,
            selection: NSRange(
                location: insertionIndex + moved.length,
                length: 0),
            insertionIndex: insertionIndex)
    }

    /// Payload order is the provider order because `ChatInput.serialize` walks attributed runs from
    /// start to finish. Kept as a focused invariant helper rather than decoding attachment types.
    static func payloads(in content: NSAttributedString) -> [String] {
        guard content.length > 0 else { return [] }
        var payloads: [String] = []
        content.enumerateAttributes(
            in: NSRange(location: 0, length: content.length)
        ) { attributes, _, _ in
            guard attributes[.attachment] != nil,
                  let payload = attributes[ChatInput.payloadKey] as? String else { return }
            payloads.append(payload)
        }
        return payloads
    }
}

/// Private descriptor carried by a composer-originated drag. The active coordinator validates the
/// nonce before moving; another composer can still reconstruct a copy from the durable payload.
struct ComposerAttachmentDragDescriptor: Codable, Equatable {
    static let pasteboardType = NSPasteboard.PasteboardType(
        "ai.mechanician.composer-attachment")
    /// Private UTIs are publicly writable. Bound the envelope before JSON decoding or HMAC work so
    /// an unrelated process cannot make a drag-enter callback parse an arbitrarily large blob on
    /// the main actor.
    static let maximumEncodedBytes = 8 * 1024 * 1024
    static let maximumPayloadBytes = maximumEncodedBytes - 1_024
    private static let maximumSignatureBytes = 256

    let nonce: UUID
    let payload: String
    let sourceConversationID: UUID?
    let provenanceSignature: String?

    init(
        nonce: UUID,
        payload: String,
        sourceConversationID: UUID?,
        provenanceSignature: String? = nil
    ) {
        self.nonce = nonce
        self.payload = payload
        self.sourceConversationID = sourceConversationID
        self.provenanceSignature = provenanceSignature
    }

    var encodedData: Data? {
        guard hasBoundedContent,
              let data = try? JSONEncoder().encode(self),
              data.count <= Self.maximumEncodedBytes else { return nil }
        return data
    }

    var signedForCurrentProcess: Self {
        Self(
            nonce: nonce,
            payload: payload,
            sourceConversationID: sourceConversationID,
            provenanceSignature: signingData.map(
                ComposerPrivatePasteboardProvenance.signature(for:)))
    }

    var processSignedEncodedData: Data? {
        guard hasBoundedContent, signingData != nil else { return nil }
        return ComposerPrivatePasteboardProvenance.seal(
            signedForCurrentProcess.encodedData,
            domain: .composerAttachmentDrag,
            maximumEncodedBytes: Self.maximumEncodedBytes)
    }

    var isTrustedForCurrentProcess: Bool {
        ComposerPrivatePasteboardProvenance.validates(
            provenanceSignature,
            data: signingData)
    }

    private var signingData: Data? {
        guard hasBoundedContent else { return nil }
        struct Fields: Codable {
            let nonce: UUID
            let payload: String
            let sourceConversationID: UUID?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(Fields(
            nonce: nonce,
            payload: payload,
            sourceConversationID: sourceConversationID))
    }

    static func decode(_ data: Data?) -> Self? {
        guard let data,
              data.count <= maximumEncodedBytes,
              let descriptor = try? JSONDecoder().decode(Self.self, from: data),
              descriptor.hasBoundedContent else { return nil }
        return descriptor
    }

    static func decodeProcessPrivate(_ data: Data?) -> Self? {
        guard let plaintext = ComposerPrivatePasteboardProvenance.open(
            data,
            domain: .composerAttachmentDrag,
            maximumEncodedBytes: Self.maximumEncodedBytes),
              let descriptor = decode(plaintext),
              descriptor.isTrustedForCurrentProcess else { return nil }
        return descriptor
    }

    private var hasBoundedContent: Bool {
        guard payload.utf8.count <= Self.maximumPayloadBytes else { return false }
        return (provenanceSignature?.utf8.count ?? 0) <= Self.maximumSignatureBytes
    }
}

/// App-private clipboard representation for an authored composer selection.
///
/// AppKit's ordinary rich-text clipboard export does not preserve Mechanician's hidden provider
/// payload attributes reliably. A mixed selection can therefore advertise both text and bitmap
/// types while losing the durable path/token that owns each attachment. Keep a bounded, ordered
/// description beside AppKit's public representations so another composer can reconstruct the
/// selection and re-home conversation-owned bytes before inserting it.
struct ComposerClipboardPayload: Codable, Equatable {
    static let pasteboardType = NSPasteboard.PasteboardType(
        "ai.mechanician.composer-selection")
    static let maximumEncodedBytes = 8 * 1024 * 1024
    static let maximumSegments = 4_096
    /// A private composer selection is one logical item. Keep a little tolerance for AppKit bridges
    /// without letting a hostile pasteboard make the main actor retrieve an unbounded item list.
    static let maximumPasteboardItems = 4
    private static let maximumSignatureBytes = 256

    struct Segment: Codable, Equatable {
        enum Kind: String, Codable {
            case text
            case image
            case file
            case artifact
            /// A pasted-text pill or legacy attachment whose payload must remain opaque.
            case opaqueAttachment
        }

        let kind: Kind
        let content: String
    }

    let sourceConversationID: UUID?
    let segments: [Segment]
    let provenanceSignature: String?

    init(
        sourceConversationID: UUID?,
        segments: [Segment],
        provenanceSignature: String? = nil
    ) {
        self.sourceConversationID = sourceConversationID
        self.segments = segments
        self.provenanceSignature = provenanceSignature
    }

    var serializedContent: String {
        segments.map(\.content).joined()
    }

    var requiresPrivateRepresentation: Bool {
        segments.contains { $0.kind != .text }
    }

    /// Readable representation offered to apps that do not understand the private type. Never put
    /// conversation-media paths, durable file tokens, artifact tokens, or opaque hidden payloads in
    /// the public string flavor.
    var publicText: String {
        segments.map { segment in
            switch segment.kind {
            case .text:
                return Self.sanitizedPublicText(segment.content)
            case .image:
                return "[Image]"
            case .file:
                return "[File attachment]"
            case .artifact:
                return "[Artifact]"
            case .opaqueAttachment:
                return "[Pasted text]"
            }
        }.joined()
    }

    var encodedData: Data? {
        guard hasBoundedContent,
              let data = try? JSONEncoder().encode(self),
              data.count <= Self.maximumEncodedBytes else { return nil }
        return data
    }

    var processSignedEncodedData: Data? {
        guard hasBoundedContent, signingData != nil else { return nil }
        return ComposerPrivatePasteboardProvenance.seal(
            signedForCurrentProcess.encodedData,
            domain: .composerClipboard,
            maximumEncodedBytes: Self.maximumEncodedBytes)
    }

    var isTrustedForCurrentProcess: Bool {
        ComposerPrivatePasteboardProvenance.validates(
            provenanceSignature,
            data: signingData)
    }

    private var signedForCurrentProcess: Self {
        Self(
            sourceConversationID: sourceConversationID,
            segments: segments,
            provenanceSignature: signingData.map(
                ComposerPrivatePasteboardProvenance.signature(for:)))
    }

    static func decode(_ data: Data?) -> Self? {
        guard let data,
              data.count <= maximumEncodedBytes,
              let payload = try? JSONDecoder().decode(Self.self, from: data),
              payload.hasBoundedContent else { return nil }
        return payload
    }

    static func decodeProcessPrivate(_ data: Data?) -> Self? {
        guard let plaintext = ComposerPrivatePasteboardProvenance.open(
            data,
            domain: .composerClipboard,
            maximumEncodedBytes: Self.maximumEncodedBytes),
              let payload = decode(plaintext),
              payload.isTrustedForCurrentProcess else { return nil }
        return payload
    }

    private var hasBoundedContent: Bool {
        guard segments.count <= Self.maximumSegments,
              (provenanceSignature?.utf8.count ?? 0) <= Self.maximumSignatureBytes else {
            return false
        }
        var remainingBytes = Self.maximumEncodedBytes
        for segment in segments {
            let byteCount = segment.content.utf8.count
            guard byteCount <= remainingBytes else { return false }
            remainingBytes -= byteCount
        }
        return true
    }

    private var signingData: Data? {
        guard hasBoundedContent else { return nil }
        struct Fields: Codable {
            let sourceConversationID: UUID?
            let segments: [Segment]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(Fields(
            sourceConversationID: sourceConversationID,
            segments: segments))
    }

    /// Shared with the inbound paste path, which needs the same matching and overlap resolution in
    /// the other direction. See `ComposerTokenScrub`.
    private static func sanitizedPublicText(_ text: String) -> String {
        ComposerTokenScrub.publicText(text)
    }
}
