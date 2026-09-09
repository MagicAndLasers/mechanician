import AppKit
import Foundation

/// Turning a conversation into something printable.
///
/// Built from `[TranscriptEntry]` directly, **not** from `AgentBridge.transcriptMarkdown`. That
/// function joins entries with `\n\n---\n\n` and bakes speaker prefixes into the text, so recovering
/// per-entry sections would mean splitting on a joiner the markdown parser reads as a horizontal
/// rule. It also truncates tool results at 2000 characters. It is the right shape for a clipboard
/// copy and the wrong one for a document.
///
/// Prose is rendered by `NativeMarkdownRenderer` — **the same renderer the transcript cells use**.
/// That is the point rather than a convenience: a second markdown path would let the page and the
/// screen disagree about the same conversation, and nothing would catch it.
@MainActor
enum TranscriptPrintDocument {
    /// Point size for body text. Independent of the on-screen zoom: a printed page is not a window,
    /// and inheriting someone's ⌘+ setting would make the same conversation print differently on two
    /// machines.
    static let bodyScale: CGFloat = 1.0

    /// Entries that belong in a printed document, in transcript order.
    ///
    /// Two exclusions, and they are different kinds of rule:
    ///
    /// - **Retracted content is policy.** A superseded tool row stays on screen as audit evidence,
    ///   but the provider withdrew it, and a document is a record of what was said.
    ///   `transcriptMarkdown` already refuses to export these; print refuses for the same reason.
    /// - **`permission` and `question` are transient UI.** They are prompts the app raised and the
    ///   user answered in the moment, not part of the conversation. `transcriptMarkdown` drops them
    ///   through its `default` branch; this drops them by name so the choice is visible and a new
    ///   `Kind` case cannot join them silently.
    nonisolated static func printableEntries(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        entries.filter { entry in
            guard !entry.isSuperseded else { return false }
            switch entry.kind {
            case .user, .assistant, .system, .tool, .compaction, .review:
                return !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || entry.toolName != nil
                    || claudeContinuitySummary(for: entry) != nil
            case .permission, .question:
                return false
            }
        }
    }

    /// Claude's PostCompact payload is a continuity summary, not a serialization of every item in
    /// effective provider context. Keep the provenance check at the export boundary so an unknown
    /// future payload cannot silently acquire that stronger label.
    nonisolated static func claudeContinuitySummary(for entry: TranscriptEntry) -> String? {
        guard entry.kind == .compaction,
              entry.compactionSummarySource == "claude_post_compact",
              let summary = entry.compactionSummary?.trimmingCharacters(
                in: .whitespacesAndNewlines),
              !summary.isEmpty else { return nil }
        return summary
    }

    /// The label above an entry, or `nil` for entries that read as continuous prose.
    ///
    /// Deliberately **not** `transcriptMarkdown`'s "Claude": this app drives more than one provider,
    /// and a Codex conversation printed under Claude's name is simply wrong. That the clipboard copy
    /// still says Claude is a defect there, not a convention to reproduce here.
    nonisolated static func speakerLabel(for entry: TranscriptEntry) -> String? {
        switch entry.kind {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .review: return entry.review?.title ?? "Code Review"
        case .tool, .system, .compaction, .permission, .question: return nil
        }
    }

    /// The whole conversation as one attributed string, ready for an `NSTextView` to paginate.
    static func attributedDocument(title: String, entries: [TranscriptEntry]) -> NSAttributedString {
        let document = NSMutableAttributedString()
        document.append(titleBlock(title))

        for entry in printableEntries(entries) {
            if let label = speakerLabel(for: entry) {
                document.append(labelBlock(label))
            }
            switch entry.kind {
            case .tool:
                document.append(toolBlock(entry))
            case .compaction:
                document.append(compactionBlock(entry))
            case .system:
                document.append(asideBlock(entry.text))
            default:
                document.append(NativeMarkdownRenderer.render(entry.text, scale: bodyScale))
                document.append(NSAttributedString(string: "\n"))
            }
            document.append(NSAttributedString(string: "\n"))
        }
        return document
    }

    // MARK: - Blocks

    private static func titleBlock(_ title: String) -> NSAttributedString {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 14
        return NSAttributedString(
            string: (text.isEmpty ? "Conversation" : text) + "\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
                .paragraphStyle: paragraph,
                // Explicit black rather than `labelColor`: a printed page has no appearance, and a
                // dynamic colour resolved in Dark Mode is what makes today's Save as PDF print
                // white on white (FR-177).
                .foregroundColor: NSColor.black,
            ])
    }

    private static func labelBlock(_ label: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 3
        paragraph.paragraphSpacingBefore = 8
        return NSAttributedString(
            string: label + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .paragraphStyle: paragraph,
                .foregroundColor: NSColor.black,
                .kern: 0.6,
            ])
    }

    /// One compact line per tool call, matching what the transcript shows with an activity group
    /// collapsed. Tool *results* are omitted: they are frequently tens of thousands of characters of
    /// machine output, and a document nobody can read is not a better record than a short one.
    private static func toolBlock(_ entry: TranscriptEntry) -> NSAttributedString {
        let name = entry.toolName ?? "tool"
        let summary = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 12
        paragraph.headIndent = 12
        paragraph.paragraphSpacing = 2
        return NSAttributedString(
            string: summary.isEmpty ? "▸ \(name)\n" : "▸ \(name) — \(summary)\n",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                .paragraphStyle: paragraph,
                .foregroundColor: NSColor.black,
            ])
    }

    private static func compactionBlock(_ entry: TranscriptEntry) -> NSAttributedString {
        let block = NSMutableAttributedString()
        let marker = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !marker.isEmpty { block.append(asideBlock(marker)) }
        guard let summary = claudeContinuitySummary(for: entry) else { return block }

        let label = entry.compactionSummaryTruncated == true
            ? "Claude continuity summary (truncated)"
            : "Claude continuity summary"
        block.append(labelBlock(label))
        block.append(NativeMarkdownRenderer.render(summary, scale: bodyScale))
        block.append(NSAttributedString(string: "\n"))
        return block
    }

    private static func asideBlock(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 6
        return NSAttributedString(
            string: text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10).withItalic(),
                .paragraphStyle: paragraph,
                .foregroundColor: NSColor.black,
            ])
    }
}

private extension NSFont {
    func withItalic() -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
