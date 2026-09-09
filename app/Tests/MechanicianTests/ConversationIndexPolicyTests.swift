import XCTest
@testable import Mechanician

/// The per-entry cap on the conversation search index.
///
/// The measurement that motivated it: 510 rows out of 64,127 held 40% of the indexed text, and the
/// largest single row was 1,049,025 characters of tool output. These tests pin the ceiling, the
/// boundaries, and the property that matters most in practice, which is that truncation cannot
/// corrupt text.
@MainActor
final class ConversationIndexPolicyTests: XCTestCase {

    // MARK: - The caps

    func testEachKindCarriesItsOwnCap() throws {
        XCTAssertEqual(ConversationIndexPolicy.cap(for: .user), 4_000)
        XCTAssertEqual(ConversationIndexPolicy.cap(for: .assistant), 8_000)
        XCTAssertEqual(ConversationIndexPolicy.cap(for: .tool), 2_000)
        XCTAssertEqual(ConversationIndexPolicy.cap(for: .system), 2_000)
        XCTAssertEqual(ConversationIndexPolicy.cap(for: .compaction), 2_000)
    }

    /// A tool row is capped hardest because it carries the bulk, and an assistant answer of the same
    /// length is kept, because prose is what people look for.
    func testTheSameTextIsCappedDifferentlyByKind() throws {
        let text = String(repeating: "x", count: 6_000)
        XCTAssertEqual(ConversationIndexPolicy.indexableText(text, kind: .tool).count, 2_000)
        XCTAssertEqual(ConversationIndexPolicy.indexableText(text, kind: .assistant).count, 6_000)
        XCTAssertEqual(ConversationIndexPolicy.indexableText(text, kind: .user).count, 4_000)
    }

    // MARK: - Boundaries

    func testTextAtOrBelowTheCapIsUntouched() throws {
        let exact = String(repeating: "a", count: 2_000)
        XCTAssertEqual(ConversationIndexPolicy.indexableText(exact, kind: .tool), exact)

        let under = String(repeating: "a", count: 1_999)
        XCTAssertEqual(ConversationIndexPolicy.indexableText(under, kind: .tool), under)

        XCTAssertEqual(ConversationIndexPolicy.indexableText("", kind: .tool), "")
    }

    func testOneCharacterOverIsTruncatedToTheCap() throws {
        let over = String(repeating: "a", count: 2_001)
        XCTAssertEqual(ConversationIndexPolicy.indexableText(over, kind: .tool).count, 2_000)
    }

    /// Head truncation, because the identifying content leads: a tool row opens with its command or
    /// path and continues into output.
    func testTruncationKeepsTheHeadWhereTheIdentifyingContentIs() throws {
        let composed = "grep -R MECHANICIAN_SUPPORT_DIR\n" + String(repeating: "z", count: 50_000)
        let indexed = ConversationIndexPolicy.indexableText(composed, kind: .tool)
        XCTAssertTrue(
            indexed.hasPrefix("grep -R MECHANICIAN_SUPPORT_DIR"),
            "the command must survive; it is what someone searches for")
        XCTAssertEqual(indexed.count, 2_000)
    }

    // MARK: - Truncation must not corrupt text

    /// `String.prefix` counts characters, so a cap can never split a grapheme. Byte slicing would
    /// produce invalid UTF-8 and could poison the index with replacement characters.
    func testTruncationNeverSplitsACharacter() throws {
        // Family emoji: one Character made of many scalars, so a naive byte cut lands mid-cluster.
        let family = "👨‍👩‍👧‍👦"
        let text = String(repeating: family, count: 3_000)
        let indexed = ConversationIndexPolicy.indexableText(text, kind: .tool)

        XCTAssertEqual(indexed.count, 2_000, "counts characters, not bytes")
        XCTAssertTrue(
            indexed.unicodeScalars.allSatisfy { $0 != "\u{FFFD}" },
            "no replacement characters, so nothing was cut mid-character")
        XCTAssertEqual(
            String(data: Data(indexed.utf8), encoding: .utf8), indexed,
            "the result round-trips through UTF-8")
        XCTAssertTrue(indexed.hasPrefix(family))
    }

    func testCombiningMarksAndScriptsSurvive() throws {
        for unit in ["é", "नि", "🇬🇧", "a\u{0301}"] {
            let text = String(repeating: unit, count: 4_000)
            let indexed = ConversationIndexPolicy.indexableText(text, kind: .tool)
            XCTAssertEqual(indexed.count, 2_000, "\(unit) was miscounted")
            XCTAssertEqual(String(data: Data(indexed.utf8), encoding: .utf8), indexed)
        }
    }

    // MARK: - Across the seam

    /// The cap has to apply where the index is actually written, not only in the pure helper.
    func testAConversationsIndexedEntriesAreCapped() throws {
        var tool = TranscriptEntry(kind: .tool, text: "Bash")
        tool.toolName = "Bash"
        tool.toolResult = String(repeating: "q", count: 200_000)
        let conversation = Conversation(
            title: "Big", cwd: "", sdkSessionId: nil,
            messages: [
                TranscriptEntry(kind: .user, text: "run the thing"),
                tool,
            ],
            updatedAt: Date())

        let record = ConversationProjectionStore.record(for: conversation)
        XCTAssertEqual(record.entries.count, 2)
        for entry in record.entries {
            XCTAssertLessThanOrEqual(
                entry.count, ConversationIndexPolicy.assistantCap,
                "no indexed entry may exceed the largest cap")
        }
        let biggest = record.entries.map(\.count).max() ?? 0
        XCTAssertEqual(
            biggest, ConversationIndexPolicy.toolCap,
            "a 200,000 character tool result must be indexed at the tool cap")
    }

    /// The whole point: index size stops tracking tool output volume.
    func testIndexedSizeTracksMessageCountNotOutputVolume() throws {
        func indexedSize(resultLength: Int) -> Int {
            var tool = TranscriptEntry(kind: .tool, text: "Bash")
            tool.toolName = "Bash"
            tool.toolResult = String(repeating: "q", count: resultLength)
            let conversation = Conversation(
                title: "C", cwd: "", sdkSessionId: nil,
                messages: [tool], updatedAt: Date())
            return ConversationProjectionStore.record(for: conversation)
                .entries.reduce(0) { $0 + $1.count }
        }

        let small = indexedSize(resultLength: 10_000)
        let huge = indexedSize(resultLength: 1_000_000)
        XCTAssertEqual(
            small, huge,
            "a hundredfold more tool output must cost the index nothing extra")
    }

    /// A change beyond the cap still re-indexes. The digest covers the complete text on purpose, so
    /// the stamp errs toward extra work rather than toward a stale index.
    func testAChangePastTheCapStillInvalidatesTheStamp() throws {
        func stamp(resultSuffix: String) -> String {
            var tool = TranscriptEntry(kind: .tool, text: "Bash")
            tool.toolName = "Bash"
            tool.toolResult = String(repeating: "q", count: 50_000) + resultSuffix
            let conversation = Conversation(
                title: "C", cwd: "", sdkSessionId: nil,
                messages: [tool], updatedAt: Date())
            return ConversationProjectionStore.record(for: conversation).contentStamp
        }
        XCTAssertNotEqual(
            stamp(resultSuffix: "before"), stamp(resultSuffix: "after"),
            "the stamp must notice a change the index cannot see")
    }
}
