import Foundation
import SwiftUI

/// Finding text in the conversation you are reading.
///
/// Searches the **model** — the transcript entries — rather than the rendered rows, for two reasons.
/// The rendered list is a projection that drops and merges things (consecutive groupable tool
/// entries collapse into one row, subsumed compaction chunks are not rendered at all, provisional
/// entries are never matched), so searching it would silently make some of the conversation
/// unfindable. And rows are realized lazily, so a row-based search could only ever find what is
/// currently on screen.
///
/// The cost of that choice is that a match can name an entry the transcript cannot currently
/// reveal. That is deliberate and handled one layer up: reveal reports an explicit failure and the
/// find bar steps past it, which is strictly better than pretending the text is not there.
enum TranscriptSearch {
    struct Match: Equatable {
        /// Position in the entries array at the time of the search.
        let entryIndex: Int
        /// Stable identity, so a match survives the array shifting under a streaming turn.
        let entryID: UUID
        /// UTF-16 range within that entry's `text` — the units an `NSTextView` selection wants.
        let range: NSRange
        /// Which hit this is *within its own entry*, counting from zero.
        ///
        /// The highlight needs this rather than `range`, because an assistant row renders markdown:
        /// the cell's text has had `**`, backticks and heading marks consumed, so an offset into the
        /// raw entry text points somewhere else entirely on screen. Counting occurrences survives
        /// that, since the rendered text is what the user was reading when they searched.
        var occurrenceInEntry: Int = 0
    }

    /// Every match, in reading order: transcript order, then position within an entry.
    ///
    /// Case- and diacritic-insensitive, which is what every Mac find bar does unless told otherwise;
    /// nobody typing ⌘F is asking for an exact-case search by default.
    static func matches(of query: String, in entries: [TranscriptEntry]) -> [Match] {
        // A whitespace-only query matches almost everything and helps no one; an empty one is the
        // find bar at rest.
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var results: [Match] = []
        for (index, entry) in entries.enumerated() {
            let haystack = entry.text
            guard !haystack.isEmpty else { continue }
            let text = haystack as NSString
            var searchStart = 0
            var occurrence = 0
            while searchStart < text.length {
                let remaining = NSRange(location: searchStart, length: text.length - searchStart)
                let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                       range: remaining)
                guard found.location != NSNotFound else { break }
                results.append(Match(entryIndex: index, entryID: entry.id, range: found,
                                     occurrenceInEntry: occurrence))
                occurrence += 1
                // Advance past this match. A zero-length hit would otherwise spin forever — it
                // cannot happen with a non-empty query, but the guard costs nothing and the loop is
                // the kind that hangs the app rather than failing a test.
                searchStart = found.location + max(found.length, 1)
            }
        }
        return results
    }

    /// The match to land on when the bar steps forward, wrapping at the end.
    ///
    /// Wrapping rather than stopping is the Mac behavior, and it is what makes ⌘G usable as a
    /// "cycle through these" key rather than something that quietly dead-ends at the last hit.
    static func index(after current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        return (current + 1) % count
    }

    static func index(before current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return count - 1 }
        return (current - 1 + count) % count
    }

    /// The match nearest a re-run of the same search, so retyping a character does not throw away
    /// where the user was. Matched by entry identity first because a streaming turn shifts indices
    /// under the search while the user is reading.
    static func index(of previous: Match?, in matches: [Match]) -> Int? {
        guard let previous, !matches.isEmpty else { return matches.isEmpty ? nil : 0 }
        if let exact = matches.firstIndex(where: {
            $0.entryID == previous.entryID && $0.range.location == previous.range.location
        }) { return exact }
        if let sameEntry = matches.firstIndex(where: { $0.entryID == previous.entryID }) {
            return sameEntry
        }
        return 0
    }

    /// `text` with the `occurrence`-th hit of `query` marked, for SwiftUI rows that draw a plain
    /// string rather than a text view.
    ///
    /// Word-level, not row-level. A whole-row wash is useless on a long pasted message — the point
    /// of Find is *which words*, and a band behind five paragraphs does not answer that.
    ///
    /// Returns nil when there is nothing to mark, so callers keep their plain fast path.
    @MainActor
    static func highlighted(_ text: String, query: String, occurrence: Int) -> AttributedString? {
        guard !query.isEmpty, !text.isEmpty else { return nil }
        let source = text as NSString
        var location = 0
        var remaining = occurrence
        var found = NSRange(location: NSNotFound, length: 0)
        while location < source.length {
            let hit = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                   range: NSRange(location: location, length: source.length - location))
            guard hit.location != NSNotFound else { break }
            if remaining == 0 { found = hit; break }
            remaining -= 1
            location = hit.location + max(hit.length, 1)
        }
        // The displayed string is trimmed relative to the entry text the search ran over, so an
        // exact ordinal can fall outside it. Falling back to the first hit shows the user something
        // true rather than nothing.
        if found.location == NSNotFound {
            let first = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
            guard first.location != NSNotFound else { return nil }
            found = first
        }
        var attributed = AttributedString(text)
        guard let range = Range(found, in: attributed) else { return nil }
        attributed[range].backgroundColor = .yellow
        // The bubble draws light text; yellow under it would be unreadable, so the ink is pinned.
        attributed[range].foregroundColor = .black
        return attributed
    }
}
