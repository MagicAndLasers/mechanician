import SwiftUI

/// Lightweight, dependency-free markdown rendering: fenced code blocks render as
/// monospace boxes; headings, bullet/numbered lists, and paragraphs render with
/// block styling; inline markdown (bold/italic/inline-code/links) is applied within.
/// Tolerates an unterminated fence mid-stream.
struct MarkdownText: View {
    let text: String
    var scale: CGFloat = 1 // ⌘+/- font zoom for the chat transcript

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            ForEach(Self.blocks(from: text)) { block in
                view(for: block)
            }
        }
        .font(.system(size: 13 * scale)) // base size; headings/code override below
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(Self.inline(block.content))
                .font(headingFont(level))
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .bullet:
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                Text(Self.inline(block.content)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
        case .numbered(let marker):
            HStack(alignment: .top, spacing: 6) {
                Text(marker).monospacedDigit()
                Text(Self.inline(block.content)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
        case .paragraph:
            Text(Self.inline(block.content))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code:
            // Soft-wrap long lines instead of forcing a horizontal scroll — the previous
            // ScrollView(.horizontal) meant wide code / long strings needed heavy side-scrolling.
            Text(SyntaxHighlighter.highlight(block.content, language: block.language, fontSize: 12 * scale))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.nBg))
        case .rule:
            Divider().padding(.vertical, 3)
        case .table:
            if let rows = block.tableRows, !rows.isEmpty { tableView(rows) }
        }
    }

    /// A GFM table: first row is the header, the rest are data. Rendered with a native Grid.
    private func tableView(_ rows: [[String]]) -> some View {
        let cols = rows.map(\.count).max() ?? 0
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    ForEach(0..<cols, id: \.self) { c in
                        Text(Self.inline(c < rows[0].count ? rows[0][c] : ""))
                            .font(.system(size: 12 * scale, weight: .semibold))
                    }
                }
                Divider()
                ForEach(Array(rows.dropFirst().enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<cols, id: \.self) { c in
                            Text(Self.inline(c < row.count ? row[c] : ""))
                                .font(.system(size: 12 * scale))
                        }
                    }
                }
            }
            .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.nSurface))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.nMuted.opacity(0.4)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 20 * scale, weight: .semibold)
        case 2: return .system(size: 16 * scale, weight: .semibold)
        default: return .system(size: 14 * scale, weight: .semibold)
        }
    }

    // MARK: Parsing

    struct Block: Identifiable {
        enum Kind: Equatable {
            case heading(Int), bullet, numbered(String), paragraph, code, rule, table
        }
        let id: Int
        let kind: Kind
        let content: String
        var language: String? = nil       // fence tag for code blocks (```swift)
        var tableRows: [[String]]? = nil  // parsed rows for a table block
    }

    // MARK: Table helpers

    private static func looksLikeTableRow(_ s: String) -> Bool {
        s.contains("|") && !s.hasPrefix("```")
    }
    private static func isTableSeparator(_ s: String) -> Bool {
        let body = s.replacingOccurrences(of: " ", with: "")
        return !body.isEmpty && body.contains("-")
            && body.allSatisfy { "|:-".contains($0) }
    }
    private static func parseTableRow(_ s: String) -> [String] {
        var cells = s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    static func blocks(from text: String) -> [Block] {
        var blocks: [Block] = []
        var inCode = false
        var codeBuf: [String] = []
        var codeLang: String? // language tag from the opening fence
        var paraBuf: [String] = []

        func flushParagraph() {
            let joined = paraBuf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paraBuf.removeAll()
            if !joined.isEmpty {
                blocks.append(Block(id: blocks.count, kind: .paragraph, content: joined))
            }
        }
        func flushCode() {
            let joined = codeBuf.joined(separator: "\n")
            codeBuf.removeAll()
            let lang = codeLang
            codeLang = nil
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(Block(id: blocks.count, kind: .code, content: joined, language: lang))
            }
        }

        let lines = text.components(separatedBy: "\n")
        var idx = 0
        while idx < lines.count {
            let line = lines[idx]
            defer { idx += 1 }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    flushCode()
                } else {
                    flushParagraph()
                    codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                inCode.toggle()
                continue
            }
            if inCode { codeBuf.append(line); continue }

            // Table: a row line immediately followed by a |---|---| separator.
            if looksLikeTableRow(trimmed), idx + 1 < lines.count,
               isTableSeparator(lines[idx + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                var rows = [parseTableRow(trimmed)]
                var j = idx + 2
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    guard looksLikeTableRow(t) else { break }
                    rows.append(parseTableRow(t))
                    j += 1
                }
                blocks.append(Block(id: blocks.count, kind: .table, content: "", tableRows: rows))
                idx = j - 1 // defer bumps to j
                continue
            }

            // Horizontal rule: a line of only ---, ***, or ___ (3+).
            if trimmed.count >= 3, let f = trimmed.first, "-*_".contains(f),
               trimmed.allSatisfy({ $0 == f }) {
                flushParagraph()
                blocks.append(Block(id: blocks.count, kind: .rule, content: ""))
                continue
            }

            // Heading: #, ##, ### …
            if let hash = trimmed.firstIndex(where: { $0 != "#" }),
               trimmed.hasPrefix("#"),
               trimmed.distance(from: trimmed.startIndex, to: hash) <= 6,
               trimmed[hash] == " " {
                flushParagraph()
                let level = trimmed.distance(from: trimmed.startIndex, to: hash)
                let content = String(trimmed[trimmed.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
                blocks.append(Block(id: blocks.count, kind: .heading(level), content: content))
                continue
            }

            // Bullet: -, *, +
            if let m = trimmed.first, "-*+".contains(m), trimmed.dropFirst().first == " " {
                flushParagraph()
                let content = String(trimmed.dropFirst(2))
                blocks.append(Block(id: blocks.count, kind: .bullet, content: content))
                continue
            }

            // Numbered: 1. 2) …
            if let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }),
               trimmed[trimmed.startIndex..<dot].allSatisfy(\.isNumber),
               dot != trimmed.startIndex,
               trimmed.index(after: dot) < trimmed.endIndex,
               trimmed[trimmed.index(after: dot)] == " " {
                flushParagraph()
                let marker = String(trimmed[...dot])
                let content = String(trimmed[trimmed.index(dot, offsetBy: 2)...])
                blocks.append(Block(id: blocks.count, kind: .numbered(marker), content: content))
                continue
            }

            // Blank line ends a paragraph; otherwise accumulate.
            if trimmed.isEmpty { flushParagraph() } else { paraBuf.append(line) }
        }
        if inCode { flushCode() } else { flushParagraph() }
        return blocks
    }

    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}
