import XCTest
@testable import Mechanician

/// FR-336. Each of these is a case the previous `split(separator:)` renderer got wrong, written as
/// the input a person would actually have on disk rather than as an abstract parser exercise.
final class CSVParserTests: XCTestCase {

    // MARK: - The four defects that motivated the parser

    /// The one that mattered most. `split(separator: "\n")` never matches a CRLF file, because in
    /// Swift `"\r\n"` is a single `Character`, so an Excel-on-Windows export arrived as one row.
    func testCRLFFileIsRowsRatherThanOneEnormousRow() {
        let rows = CSVParser.rows(from: "name,age\r\nAlice,30\r\nBob,41")
        XCTAssertEqual(rows, [["name", "age"], ["Alice", "30"], ["Bob", "41"]])
    }

    func testQuotedFieldKeepsItsComma() {
        let rows = CSVParser.rows(from: "name,age\n\"Smith, John\",42")
        XCTAssertEqual(rows, [["name", "age"], ["Smith, John", "42"]])
    }

    func testEscapedQuotesBecomeOneLiteralQuote() {
        let rows = CSVParser.rows(from: "quote\n\"She said \"\"hi\"\"\"")
        XCTAssertEqual(rows, [["quote"], ["She said \"hi\""]])
    }

    func testNewlineInsideAQuotedFieldStaysInTheField() {
        let rows = CSVParser.rows(from: "note,n\n\"line one\nline two\",1")
        XCTAssertEqual(rows, [["note", "n"], ["line one\nline two", "1"]])
    }

    // MARK: - Line endings

    func testAllThreeLineEndingsEndARow() {
        XCTAssertEqual(CSVParser.rows(from: "a\nb"), [["a"], ["b"]], "LF")
        XCTAssertEqual(CSVParser.rows(from: "a\r\nb"), [["a"], ["b"]], "CRLF")
        XCTAssertEqual(CSVParser.rows(from: "a\rb"), [["a"], ["b"]], "CR (classic Mac)")
    }

    func testCRLFInsideAQuotedFieldIsContentNotARowBreak() {
        let rows = CSVParser.rows(from: "a,b\n\"x\r\ny\",2")
        XCTAssertEqual(rows, [["a", "b"], ["x\r\ny", "2"]])
    }

    func testTrailingNewlineDoesNotInventAnEmptyRow() {
        XCTAssertEqual(CSVParser.rows(from: "a,b\n1,2\n"), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(CSVParser.rows(from: "a,b\r\n1,2\r\n"), [["a", "b"], ["1", "2"]])
    }

    // MARK: - Empties and edges

    func testEmptyFieldsSurviveIncludingLeadingAndTrailing() {
        XCTAssertEqual(CSVParser.rows(from: "a,b,c\n1,,3"), [["a", "b", "c"], ["1", "", "3"]])
        XCTAssertEqual(CSVParser.rows(from: ",x,"), [["", "x", ""]])
    }

    func testEmptyQuotedFieldIsAnEmptyString() {
        XCTAssertEqual(CSVParser.rows(from: "a,b\n\"\",2"), [["a", "b"], ["", "2"]])
    }

    func testEmptyDocumentHasNoRows() {
        XCTAssertEqual(CSVParser.rows(from: ""), [])
        XCTAssertEqual(CSVParser.rows(from: "\n"), [])
    }

    /// A preview must show something rather than refuse, so malformed input is read as far as it
    /// goes instead of throwing.
    func testUnclosedQuoteRunsToEndOfInputInsteadOfFailing() {
        let rows = CSVParser.rows(from: "a,b\n\"never closed,2")
        XCTAssertEqual(rows, [["a", "b"], ["never closed,2"]])
    }

    func testWhitespaceInsideFieldsIsPreserved() {
        // The old renderer trimmed every cell, which silently altered data. A leading space in a
        // quoted field is content.
        XCTAssertEqual(CSVParser.rows(from: "\" padded \",x"), [[" padded ", "x"]])
    }

    func testUnicodeContentSurvivesIntact() {
        let rows = CSVParser.rows(from: "emoji,text\n\"🎩, and lasers\",naïve")
        XCTAssertEqual(rows, [["emoji", "text"], ["🎩, and lasers", "naïve"]])
    }

    // MARK: - Preview bounds

    func testMaximumRowsStopsTheScanEarly() {
        let source = (1...500).map { "row\($0),\($0)" }.joined(separator: "\n")
        let rows = CSVParser.rows(from: source, maximumRows: 10)
        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(rows.first, ["row1", "1"])
        XCTAssertEqual(rows.last, ["row10", "10"])
    }

    func testMaximumRowsIsNotAppliedWhenAbsent() {
        let source = (1...500).map { "row\($0),\($0)" }.joined(separator: "\n")
        XCTAssertEqual(CSVParser.rows(from: source).count, 500)
    }

    // MARK: - Rectangularity

    func testRaggedRowsArePaddedSoTheGridStaysRectangular() {
        let ragged = [["a", "b", "c"], ["1"], ["x", "y"]]
        XCTAssertEqual(
            CSVParser.rectangular(ragged),
            [["a", "b", "c"], ["1", "", ""], ["x", "y", ""]])
    }

    func testRectangularLeavesAnAlreadyRectangularTableAlone() {
        let square = [["a", "b"], ["1", "2"]]
        XCTAssertEqual(CSVParser.rectangular(square), square)
        XCTAssertEqual(CSVParser.rectangular([]), [])
    }

    // MARK: - The production path, end to end

    /// The parser is only half the fix. This drives the seam a dropped file actually takes —
    /// `ArtifactActions.imports(from:)` reads it with `String(contentsOf:)`, which preserves CRLF —
    /// using real bytes on disk rather than a string literal, because the whole bug was that a CRLF
    /// byte sequence survives reading and then dies at the split.
    @MainActor
    func testACRLFFileImportedFromDiskParsesAsRowsThroughTheRealImportPath() throws {
        let bytes = Data(
            "region,contact\r\n\"West, North\",\"Smith, John\"\r\nEast,Alice\r\n".utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fr336-\(UUID().uuidString).csv")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let (ready, skipped) = ArtifactActions.imports(from: [url])

        XCTAssertTrue(skipped.isEmpty, "a .csv should import, not skip")
        XCTAssertEqual(ready.count, 1)
        let imported = try XCTUnwrap(ready.first)
        XCTAssertEqual(imported.type, "csv")
        XCTAssertTrue(imported.source.contains("\r\n"), "the import must not normalise the bytes")

        XCTAssertEqual(CSVParser.rows(from: imported.source), [
            ["region", "contact"],
            ["West, North", "Smith, John"],
            ["East", "Alice"],
        ])
    }

    // MARK: - Round trip with what the app exports

    func testAFileTheAppItselfWouldWriteParsesBackUnchanged() {
        // Values that need quoting on the way out and unquoting on the way back in.
        let source = "title,note\r\n\"Q1, final\",\"He said \"\"ship it\"\"\"\r\n\"multi\nline\",plain\r\n"
        XCTAssertEqual(CSVParser.rows(from: source), [
            ["title", "note"],
            ["Q1, final", "He said \"ship it\""],
            ["multi\nline", "plain"],
        ])
    }
}
