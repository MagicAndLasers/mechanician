import XCTest
@testable import Mechanician

final class TranscriptSearchTests: XCTestCase {
    private func entry(_ kind: TranscriptEntry.Kind, _ text: String) -> TranscriptEntry {
        TranscriptEntry(kind: kind, text: text)
    }

    func testMatchesComeBackInReadingOrder() {
        let entries = [
            entry(.user, "where is the pin controller"),
            entry(.assistant, "The pin controller owns scrolling. One pin, always."),
            entry(.tool, "grep pin"),
        ]
        let matches = TranscriptSearch.matches(of: "pin", in: entries)
        XCTAssertEqual(matches.map(\.entryIndex), [0, 1, 1, 2])
        // Within an entry, by position.
        XCTAssertLessThan(matches[1].range.location, matches[2].range.location)
    }

    func testSearchIsCaseAndDiacriticInsensitive() {
        let entries = [entry(.assistant, "Café CONTROLLER café")]
        XCTAssertEqual(TranscriptSearch.matches(of: "cafe", in: entries).count, 2)
        XCTAssertEqual(TranscriptSearch.matches(of: "controller", in: entries).count, 1)
    }

    /// Every kind carrying text is searchable. A match the transcript cannot reveal is handled by
    /// the reveal reporting failure, not by quietly making that text unfindable here.
    func testEveryKindWithTextIsSearched() {
        let kinds: [TranscriptEntry.Kind] = [.user, .assistant, .system, .tool, .review, .compaction]
        let entries = kinds.map { entry($0, "needle") }
        XCTAssertEqual(TranscriptSearch.matches(of: "needle", in: entries).count, kinds.count)
    }

    func testAnEmptyOrBlankQueryFindsNothing() {
        let entries = [entry(.assistant, "plenty of text here")]
        XCTAssertTrue(TranscriptSearch.matches(of: "", in: entries).isEmpty)
        XCTAssertTrue(TranscriptSearch.matches(of: "   \n", in: entries).isEmpty)
    }

    func testEmptyEntriesAreSkipped() {
        let entries = [entry(.system, ""), entry(.assistant, "needle")]
        XCTAssertEqual(TranscriptSearch.matches(of: "needle", in: entries).map(\.entryIndex), [1])
    }

    /// Overlapping candidates advance past each hit rather than re-finding the same one — the shape
    /// of loop that hangs the app rather than failing a test.
    func testRepeatedAndOverlappingMatchesTerminate() {
        let entries = [entry(.assistant, "aaaa")]
        XCTAssertEqual(TranscriptSearch.matches(of: "aa", in: entries).map(\.range.location), [0, 2])
    }

    /// The highlight counts occurrences in the *rendered* text rather than using `range`, because an
    /// assistant row renders markdown and the raw offsets point elsewhere on screen. That only works
    /// if the ordinal restarts per entry.
    func testOccurrenceCountsRestartInEachEntry() {
        let entries = [
            entry(.assistant, "pin pin pin"),
            entry(.assistant, "pin"),
        ]
        let matches = TranscriptSearch.matches(of: "pin", in: entries)
        XCTAssertEqual(matches.map(\.occurrenceInEntry), [0, 1, 2, 0])
        XCTAssertEqual(matches.map(\.entryIndex), [0, 0, 0, 1])
    }

    func testRangesAreUTF16OffsetsIntoTheEntryText() {
        // An emoji is two UTF-16 units; an NSTextView selection would land wrong on character counts.
        let text = "🙂 needle"
        let entries = [entry(.assistant, text)]
        let match = TranscriptSearch.matches(of: "needle", in: entries)[0]
        XCTAssertEqual((text as NSString).substring(with: match.range), "needle")
        XCTAssertEqual(match.range.location, 3)
    }

    // MARK: - Stepping

    func testSteppingWrapsInBothDirections() {
        XCTAssertEqual(TranscriptSearch.index(after: nil, count: 3), 0)
        XCTAssertEqual(TranscriptSearch.index(after: 0, count: 3), 1)
        XCTAssertEqual(TranscriptSearch.index(after: 2, count: 3), 0, "⌘G must cycle, not dead-end")
        XCTAssertEqual(TranscriptSearch.index(before: nil, count: 3), 2)
        XCTAssertEqual(TranscriptSearch.index(before: 0, count: 3), 2)
        XCTAssertNil(TranscriptSearch.index(after: nil, count: 0))
        XCTAssertNil(TranscriptSearch.index(before: nil, count: 0))
    }

    /// Typing another character re-runs the search; the user should stay where they were rather
    /// than being thrown back to the top.
    func testRerunningASearchKeepsThePlace() {
        let entries = [
            entry(.assistant, "needle one"),
            entry(.assistant, "needle two"),
            entry(.assistant, "needle three"),
        ]
        let matches = TranscriptSearch.matches(of: "needle", in: entries)
        XCTAssertEqual(TranscriptSearch.index(of: matches[2], in: matches), 2)
    }

    /// A streaming turn appends entries under the search, so indices shift while the user reads.
    /// Identity is what carries the place across that, not position.
    func testThePlaceSurvivesEntriesBeingInsertedAbove() {
        let target = entry(.assistant, "the needle")
        let before = [entry(.user, "ask"), target]
        let after = [entry(.user, "ask"), entry(.tool, "no match here"), target]

        let old = TranscriptSearch.matches(of: "needle", in: before)
        let new = TranscriptSearch.matches(of: "needle", in: after)
        let restored = TranscriptSearch.index(of: old[0], in: new)

        XCTAssertEqual(restored, 0)
        XCTAssertEqual(new[restored!].entryID, target.id)
        XCTAssertEqual(new[restored!].entryIndex, 2, "the index moved even though the place did not")
    }

    /// A match that vanished entirely (its entry deleted or edited) falls back to the top rather
    /// than to nothing — the bar always has somewhere to be.
    func testAVanishedPlaceFallsBackToTheFirstMatch() {
        let gone = TranscriptSearch.Match(entryIndex: 9, entryID: UUID(), range: NSRange(location: 0, length: 6))
        let matches = TranscriptSearch.matches(of: "needle", in: [entry(.assistant, "needle")])
        XCTAssertEqual(TranscriptSearch.index(of: gone, in: matches), 0)
    }
}
