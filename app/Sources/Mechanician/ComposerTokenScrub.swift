import Foundation

/// Replacing attachment tokens in composer text, in both directions.
///
/// The composer carries attachments as tagged JSON inline in the draft:
/// `<mechanician-file-reference>{…}</…>` and `<mechanician-artifact-reference>{…}</…>`. Those tags
/// are structural, not prose, and this is the one place that rewrites them.
///
/// Two directions, deliberately different:
///
/// - **Outbound** (`publicText`): what other apps see when a draft selection is copied or dragged
///   out. Tokens and local image paths both become labels, so nothing about this machine's
///   filesystem or conversation storage leaves the app.
/// - **Inbound** (`neutralizingForgedTokens`): text arriving from another app. Tokens become labels
///   because `ConversationFileReference.matches` decodes them with no authentication, so a token in
///   foreign text is a reference somebody else chose. Image paths are deliberately **kept**: they
///   only ever render locally, and pasting a path to your own screenshot to have it show inline is
///   a real thing people do.
///
/// This was one `private static` function inside `ComposerAttachmentReordering`. It is shared now
/// so the inbound path cannot drift into a fourth ad-hoc tag stripper — and a naive one would be
/// wrong, because literal removal of a tag pair can leave a dangling opening tag behind.
enum ComposerTokenScrub {
    struct Replacement {
        let range: NSRange
        let text: String
    }

    /// Tokens only. These are the forgeable ones: both decode straight out of plain text with no
    /// signature, unlike a dragged composer payload, which carries an HMAC and a live nonce.
    static func attachmentTokenReplacements(in text: String) -> [Replacement] {
        var replacements = ConversationFileReference.matches(in: text).map {
            Replacement(range: $0.range, text: "[File attachment]")
        }
        replacements.append(contentsOf: ArtifactDragReference.matches(in: text).map {
            Replacement(range: $0.range, text: "[Artifact]")
        })
        return replacements
    }

    /// Absolute image paths that exist on disk. Outbound only: these disclose the filesystem.
    static func imagePathReplacements(in text: String) -> [Replacement] {
        ImagePathDetector.matches(in: text).map {
            Replacement(range: $0.range, text: "[Image]")
        }
    }

    /// Whether `text` carries an attachment token at all. A cheap substring test first, so an
    /// ordinary paste does not pay for JSON decoding.
    static func containsAttachmentToken(_ text: String) -> Bool {
        guard text.contains(ConversationFileReference.openingTag)
            || text.contains(ArtifactDragReference.openingTag) else { return false }
        return !attachmentTokenReplacements(in: text).isEmpty
    }

    /// What another app sees: tokens and local paths both reduced to labels.
    static func publicText(_ text: String) -> String {
        apply(
            attachmentTokenReplacements(in: text) + imagePathReplacements(in: text),
            to: text)
    }

    /// What lands in the draft when plain text arrives from another app.
    ///
    /// Our own copies never put a raw token on the public pasteboard string: a single-token payload
    /// projects to "[File attachment]" and a multi-segment one goes through `publicText` above. So
    /// plain text that does contain a raw token did not come from us, and inserting it verbatim
    /// would let the sender pick a reference that the draft later re-scans into a real attachment.
    ///
    /// Bounded either way — such a reference resolves against the current conversation's own
    /// storage — but a reference nobody in this app created should not survive the paste.
    static func neutralizingForgedTokens(_ text: String) -> String {
        apply(attachmentTokenReplacements(in: text), to: text)
    }

    /// Right-to-left range replacement with overlapping matches dropped, so a nested or repeated
    /// token cannot corrupt the offsets of the ones after it.
    static func apply(_ replacements: [Replacement], to text: String) -> String {
        guard !replacements.isEmpty else { return text }
        var sorted = replacements
        sorted.sort {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            return $0.range.length > $1.range.length
        }
        var nonOverlapping: [Replacement] = []
        var cursor = 0
        for replacement in sorted where replacement.range.location >= cursor {
            nonOverlapping.append(replacement)
            cursor = NSMaxRange(replacement.range)
        }
        let result = NSMutableString(string: text)
        for replacement in nonOverlapping.reversed() {
            result.replaceCharacters(in: replacement.range, with: replacement.text)
        }
        return result as String
    }
}
