import Foundation

/// The piece of a conversation that explains why it matched a search.
///
/// FTS5 ships `snippet()` for exactly this, and it is not usable here. Measured on a real
/// 64,127-entry index: `snippet()` on its own is fast and `ORDER BY bm25()` on its own is fast,
/// but **together they cost 15 seconds** for a common prefix term, because ranking forces the
/// query to re-seek every output row to locate the matched tokens. Two-phasing it did not help
/// either: 81 snippets by rowid still took 6.3 seconds, about 80 ms each.
///
/// So SQLite does what it is good at — matching and ranking — and the excerpt is cut here, from
/// content already fetched, in microseconds.
///
/// The excerpt is deliberately allowed to be nil. Entries reach a megabyte (tool output), the
/// fetch is capped, and a match can sit past the cap. Showing the beginning of an entry as though
/// it were the reason for the match would be a confident lie; showing nothing keeps the row's
/// ordinary summary, which is honest.
enum SearchExcerpt {
    /// How much of an entry is searched for the terms. Entries average 7 KB and peak near 1 MB,
    /// and this runs per keystroke, so the window is bounded rather than the whole document.
    static let contentWindow = 8_000

    static let radius = 60
    static let ellipsis = "…"

    /// The first place any query term appears, with surrounding context.
    ///
    /// `terms` are matched case- and diacritic-insensitively, mirroring the FTS tokenizer
    /// (`unicode61 remove_diacritics 2`), and by prefix, mirroring the `"token"*` query the store
    /// builds — so a search for "test" finds the "testing" that actually matched.
    static func make(from content: String, matching terms: [String]) -> String? {
        let haystack = String(content.prefix(contentWindow))
        guard !haystack.isEmpty else { return nil }
        let folded = haystack.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                      locale: nil)
        var best: Range<String.Index>?
        for term in terms {
            let needle = term.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                      locale: nil)
            guard !needle.isEmpty, let found = folded.range(of: needle) else { continue }
            if best == nil || found.lowerBound < best!.lowerBound { best = found }
        }
        guard let best else { return nil }

        // Folding can change length (ß → ss), so map back by offset rather than reusing the index.
        let offset = folded.distance(from: folded.startIndex, to: best.lowerBound)
        guard offset <= haystack.count else { return nil }
        let hit = haystack.index(haystack.startIndex, offsetBy: offset)

        let start = haystack.index(hit, offsetBy: -radius, limitedBy: haystack.startIndex)
            ?? haystack.startIndex
        let end = haystack.index(hit, offsetBy: radius * 2, limitedBy: haystack.endIndex)
            ?? haystack.endIndex
        var text = String(haystack[start..<end])
        // Collapse whitespace so a multi-line tool result reads as one line in a table row.
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        if start > haystack.startIndex { text = ellipsis + text }
        if end < haystack.endIndex { text += ellipsis }
        return text
    }
}
