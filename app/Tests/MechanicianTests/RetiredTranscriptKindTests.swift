import XCTest
@testable import Mechanician

/// A transcript kind this build no longer models must not cost the conversation that contains it.
///
/// `TranscriptEntry.kind` is a non-optional `let` on a synthesized `Codable`, and neither read path
/// tolerates a decode failure: `Conversation.init(from:)` decodes `[TranscriptEntry]` with no
/// `Failable` wrapper, and `LibraryAuthorityAdapter` throws before the row is reached. So retiring a
/// kind is the same class of change as removing a stored property, which the repository already
/// treats as a compatibility break.
///
/// These tests exist before any kind is actually retired, so the mechanism is proven independently
/// of the removal it protects.
final class RetiredTranscriptKindTests: XCTestCase {
    /// Fixtures are built by ENCODING a real value and then rewriting only the `kind` string.
    /// Hand-written JSON silently omits required keys (`toolIsError`, `cwd`) and then fails for a
    /// reason that has nothing to do with what is under test.
    private func retiring(_ entry: TranscriptEntry, to raw: String) throws -> Data {
        let encoded = try JSONEncoder().encode(entry)
        let text = String(decoding: encoded, as: UTF8.self)
        let replaced = text.replacingOccurrences(
            of: "\"kind\":\"\(entry.kind.rawValue)\"", with: "\"kind\":\"\(raw)\"")
        XCTAssertNotEqual(replaced, text, "the fixture did not actually rewrite the kind")
        return Data(replaced.utf8)
    }

    func testAKindThisBuildDoesNotKnowDecodesAsSystemRatherThanThrowing() throws {
        let source = TranscriptEntry(kind: .user, text: "a row from an older build")
        let decoded = try JSONDecoder().decode(
            TranscriptEntry.self, from: retiring(source, to: "aKindFromTheFuture"))
        XCTAssertEqual(decoded.kind, .system)
        XCTAssertEqual(decoded.id, source.id)
        XCTAssertEqual(decoded.text, "a row from an older build")
    }

    /// The tolerance must not swallow the kinds this build still models, or every row would render
    /// as a system row and the transcript would lose its shape.
    func testEveryLiveKindStillRoundTrips() throws {
        let live: [TranscriptEntry.Kind] = [.user, .assistant, .system, .tool,
                                            .permission, .question, .compaction, .review]
        for kind in live {
            let source = TranscriptEntry(kind: kind)
            let decoded = try JSONDecoder().decode(
                TranscriptEntry.self, from: try JSONEncoder().encode(source))
            XCTAssertEqual(decoded.kind, kind, "\(kind.rawValue) must not decode as .system")
        }
    }

    /// A whole conversation containing one unknown row must still load. This is the case that
    /// matters: the failure mode is not one bad row, it is the conversation refusing to open.
    func testAConversationSurvivesARowWhoseKindWasRetired() throws {
        let kept = TranscriptEntry(kind: .user, text: "hello")
        let retired = TranscriptEntry(kind: .review, text: "retired row")
        let conversation = Conversation(
            id: UUID(), title: "Old conversation", cwd: "", sdkSessionId: nil,
            messages: [kept, retired], updatedAt: Date())

        let encoded = try JSONEncoder().encode(conversation)
        let text = String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: "\"kind\":\"review\"", with: "\"kind\":\"someRetiredKind\"")
        let decoded = try JSONDecoder().decode(Conversation.self, from: Data(text.utf8))

        XCTAssertEqual(decoded.messages.count, 2, "the retired row must be kept, not dropped")
        XCTAssertEqual(decoded.messages[0].kind, .user)
        XCTAssertEqual(decoded.messages[1].kind, .system)
        XCTAssertEqual(decoded.messages[1].text, "retired row")
    }

    /// The retired set is the whole safety contract. Nothing may be added to it without a matching
    /// case actually leaving `Kind`, or the adapter would start accepting genuine corruption.
    func testEveryRetiredRawValueIsAbsentFromTheLiveKindSet() {
        for raw in TranscriptEntry.Kind.retiredRawValues {
            XCTAssertNil(
                TranscriptEntry.Kind(rawValue: raw),
                "\(raw) is declared retired but is still a live case")
        }
    }
}
