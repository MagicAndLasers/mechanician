import XCTest
@testable import Mechanician

/// Opt-in regression checks over the reviewed 10,026-entry sanitized record. The public repository
/// does not carry that corpus, so ordinary CI skips cleanly. A maintainer dogfood run points the
/// test at a pinned derivative through `MECHANICIAN_LARGE_CORPUS_FIXTURE`.
final class LargeCorpusDogfoodTests: XCTestCase {
    private static let earlyAnchor = "ggaq xqwmk r xcrjn eqopawsm"
    private static let nearTailAnchor = "wlmrajskcvdbtmqviayeklurspaoshowwlmrajs"

    func testReviewedTenThousandEntryRecordSearchesBothEndsResponsively() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawPath = environment["MECHANICIAN_LARGE_CORPUS_FIXTURE"],
              !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip(
                "Set MECHANICIAN_LARGE_CORPUS_FIXTURE to the reviewed sanitized derivative.")
        }
        let url = URL(fileURLWithPath: rawPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("large-corpus fixture does not exist at \(url.path)")
            return
        }

        let conversation = try ConversationStore.makeDecoder().decode(
            Conversation.self,
            from: Data(contentsOf: url, options: [.mappedIfSafe]))
        XCTAssertEqual(conversation.messages.count, 10_026)

        let started = ContinuousClock.now
        let early = TranscriptSearch.matches(of: Self.earlyAnchor, in: conversation.messages)
        let tail = TranscriptSearch.matches(of: Self.nearTailAnchor, in: conversation.messages)
        let elapsed = started.duration(to: .now)

        XCTAssertEqual(early.count, 1)
        XCTAssertEqual(early.first?.entryIndex, 0)
        XCTAssertEqual(tail.count, 1)
        XCTAssertEqual(tail.first?.entryIndex, 10_024)
        XCTAssertLessThan(
            elapsed,
            .seconds(2),
            "two full 10,026-entry searches must stay inside an interactive debug-build budget")
    }
}
