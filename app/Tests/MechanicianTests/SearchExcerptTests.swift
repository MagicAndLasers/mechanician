import XCTest
@testable import Mechanician

/// The text that explains why a conversation matched.
///
/// This exists in Swift rather than as FTS5's `snippet()` for a measured reason, recorded on
/// `SearchExcerpt`: ranking and snippeting in one statement costs 15 seconds on a real index.
final class SearchExcerptTests: XCTestCase {
    func testCutsAroundTheFirstMatchingTerm() {
        let content = String(repeating: "padding ", count: 40)
            + "the notarization ticket was accepted "
            + String(repeating: "trailing ", count: 40)
        let excerpt = try? XCTUnwrap(SearchExcerpt.make(from: content, matching: ["notarization"]))
        let text = try! XCTUnwrap(excerpt)
        XCTAssertTrue(text.contains("notarization ticket"))
        XCTAssertTrue(text.hasPrefix(SearchExcerpt.ellipsis), "a cut start must be marked")
        XCTAssertTrue(text.hasSuffix(SearchExcerpt.ellipsis), "a cut end must be marked")
    }

    /// The store searches with `"token"*`, so the excerpt has to find the longer word that
    /// actually matched. Otherwise every stemmed hit shows no excerpt at all.
    func testMatchesByPrefixTheWayTheQueryDoes() throws {
        let text = try XCTUnwrap(
            SearchExcerpt.make(from: "we spent the morning testing the migration",
                               matching: ["test"]))
        XCTAssertTrue(text.contains("testing"))
    }

    /// Mirrors the index's `unicode61 remove_diacritics 2` tokenizer.
    func testIgnoresCaseAndDiacritics() throws {
        let text = try XCTUnwrap(
            SearchExcerpt.make(from: "the Café was closed", matching: ["cafe"]))
        XCTAssertTrue(text.contains("Café"))
    }

    /// A tool result is many lines; a table row is one.
    func testCollapsesWhitespaceSoARowStaysOneLine() throws {
        let text = try XCTUnwrap(
            SearchExcerpt.make(from: "alpha\n\n\tbeta   needle\n gamma", matching: ["needle"]))
        XCTAssertFalse(text.contains("\n"))
        XCTAssertFalse(text.contains("  "))
        XCTAssertTrue(text.contains("beta needle gamma"))
    }

    func testEarliestTermWins() throws {
        let text = try XCTUnwrap(
            SearchExcerpt.make(from: "first apple then banana", matching: ["banana", "apple"]))
        XCTAssertTrue(text.contains("first apple"))
    }

    /// Showing the opening of an entry as though it were the match would be a confident lie. An
    /// entry can be a megabyte of tool output and the fetch is capped, so "no excerpt" is a real
    /// outcome the caller must handle, not an error.
    func testReturnsNothingRatherThanGuessingWhenTheTermIsNotPresent() {
        XCTAssertNil(SearchExcerpt.make(from: "nothing relevant here", matching: ["kubernetes"]))
        XCTAssertNil(SearchExcerpt.make(from: "", matching: ["anything"]))
        XCTAssertNil(SearchExcerpt.make(from: "some content", matching: []))
    }

    func testAMatchPastTheContentWindowIsNotInvented() {
        let content = String(repeating: "x", count: SearchExcerpt.contentWindow + 500) + "needle"
        XCTAssertNil(
            SearchExcerpt.make(from: content, matching: ["needle"]),
            "past the window there is no evidence, so there must be no excerpt")
    }

    /// The needle sits well inside the window here on purpose; past it there is deliberately no
    /// excerpt at all, which `testAMatchPastTheContentWindowIsNotInvented` covers.
    func testExcerptStaysShortEnoughForATableRow() throws {
        let filler = String(repeating: "word ", count: 200)   // 1,000 chars, inside the window
        let text = try XCTUnwrap(
            SearchExcerpt.make(from: filler + "needle " + filler, matching: ["needle"]))
        XCTAssertTrue(text.contains("needle"))
        XCTAssertLessThan(text.count, SearchExcerpt.radius * 4)
    }
}
