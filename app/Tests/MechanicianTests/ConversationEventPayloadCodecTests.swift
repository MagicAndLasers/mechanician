import XCTest
@testable import Mechanician

/// Transparent compression of large conversation event payloads.
///
/// This touches the AUTHORITY, so the tests are written around the ways it could lose data rather
/// than the ways it saves space. A payload that decodes wrongly corrupts a transcript; a payload
/// that fails to compress merely takes more disk.
@MainActor
final class ConversationEventPayloadCodecTests: XCTestCase {

    /// Shaped like the real thing: a grep dump, which is what the 972 MB actually is.
    private func toolOutput(lines: Int = 4_000) -> Data {
        Data(String(
            repeating: "app/Sources/Mechanician/AgentBridge.swift:1912: let entry = record\n",
            count: lines).utf8)
    }

    // MARK: - Round trip

    func testALargeToolPayloadSurvivesExactly() throws {
        let original = toolOutput()
        let encoded = ConversationEventPayloadCodec.encode(original, kind: "transcript.tool")

        XCTAssertLessThan(encoded.count, original.count, "it must actually compress")
        XCTAssertTrue(ConversationEventPayloadCodec.hasHeader(encoded))
        XCTAssertEqual(
            ConversationEventPayloadCodec.decode(encoded), original,
            "byte for byte, or a transcript is corrupted")
    }

    func testCompressionIsWorthDoing() throws {
        let original = toolOutput()
        let encoded = ConversationEventPayloadCodec.encode(original, kind: "transcript.tool")
        let ratio = Double(original.count) / Double(encoded.count)
        XCTAssertGreaterThan(ratio, 3.0, "measured 3.6x on real payloads; a regression here is why")
    }

    func testUnicodePayloadsSurvive() throws {
        let text = String(repeating: "こんにちは 👨‍👩‍👧‍👦 café naïve\n", count: 400)
        let original = Data(text.utf8)
        let encoded = ConversationEventPayloadCodec.encode(original, kind: "transcript.tool")
        XCTAssertEqual(ConversationEventPayloadCodec.decode(encoded), original)
        XCTAssertEqual(String(data: ConversationEventPayloadCodec.decode(encoded), encoding: .utf8), text)
    }

    // MARK: - What must never be compressed

    /// SQL parses these payloads as JSON to verify that a memory source's quote really appears in
    /// the person's message. Compressing them would make `json_valid` fail and the provenance gate
    /// would silently stop matching.
    func testKindsThatSQLParsesAreNeverCompressed() throws {
        let payload = toolOutput()
        for kind in ["transcript.user",
                     "legacy_projection.subagent_summary",
                     "legacy_projection.workflow_summary",
                     "transcript.assistant",
                     "agent_activity.state"] {
            let encoded = ConversationEventPayloadCodec.encode(payload, kind: kind)
            XCTAssertEqual(encoded, payload, "\(kind) must be stored verbatim")
            XCTAssertFalse(ConversationEventPayloadCodec.hasHeader(encoded))
        }
    }

    func testOnlyToolEventsAreCompressible() throws {
        XCTAssertTrue(ConversationEventPayloadCodec.isCompressible(kind: "transcript.tool"))
        XCTAssertFalse(ConversationEventPayloadCodec.isCompressible(kind: "transcript.user"))
    }

    // MARK: - When compression would not help

    func testSmallPayloadsAreLeftAlone() throws {
        let small = Data(String(repeating: "a", count: 512).utf8)
        XCTAssertEqual(
            ConversationEventPayloadCodec.encode(small, kind: "transcript.tool"), small)
    }

    /// Random bytes do not deflate. The payload must be stored as-is rather than grown by a header
    /// plus incompressible output.
    func testIncompressiblePayloadsNeverGrow() throws {
        var random = Data(count: 64_000)
        random.withUnsafeMutableBytes { buffer in
            for index in 0..<buffer.count { buffer[index] = UInt8.random(in: 0...255) }
        }
        let encoded = ConversationEventPayloadCodec.encode(random, kind: "transcript.tool")
        XCTAssertLessThanOrEqual(encoded.count, random.count, "storage must never get worse")
        XCTAssertEqual(ConversationEventPayloadCodec.decode(encoded), random)
    }

    func testEmptyPayloadIsUntouched() throws {
        XCTAssertEqual(
            ConversationEventPayloadCodec.encode(Data(), kind: "transcript.tool"), Data())
        XCTAssertEqual(ConversationEventPayloadCodec.decode(Data()), Data())
    }

    // MARK: - Rows written before this existed

    /// The whole reason the encoding is self-describing rather than a `payload_version` bump: old
    /// rows must decode unchanged, with no migration.
    func testUncompressedRowsPassThroughUntouched() throws {
        let json = Data(#"{"id":"abc","kind":"tool","text":"ls -la"}"#.utf8)
        XCTAssertEqual(ConversationEventPayloadCodec.decode(json), json)

        let big = toolOutput()
        XCTAssertEqual(
            ConversationEventPayloadCodec.decode(big), big,
            "a large legacy payload is still returned verbatim")
    }

    /// JSON begins with `{` or `[`, never a null byte, so a stored payload can never be mistaken
    /// for a compressed one.
    func testJSONCanNeverBeMistakenForCompressedData() throws {
        for text in [#"{"a":1}"#, "[1,2,3]", "plain text", " {leading space}"] {
            XCTAssertFalse(
                ConversationEventPayloadCodec.hasHeader(Data(text.utf8)),
                "\(text) must not look compressed")
        }
        XCTAssertEqual(ConversationEventPayloadCodec.magic.first, 0x00)
    }

    // MARK: - Failing open

    /// A payload carrying the header that does not inflate must be returned untouched. A wrong
    /// decode corrupts a transcript; a passthrough merely fails to shrink one.
    func testAHeaderOverGarbageReturnsTheInputRatherThanGuessing() throws {
        var forged = Data(ConversationEventPayloadCodec.magic)
        forged.append(contentsOf: [0x00, 0x00, 0x10, 0x00])   // claims 4096 bytes
        forged.append(Data(repeating: 0xAB, count: 64))       // not deflate
        XCTAssertEqual(
            ConversationEventPayloadCodec.decode(forged), forged,
            "it must fail open to the stored bytes")
    }

    func testAHeaderWithTheWrongLengthIsRejected() throws {
        let original = toolOutput()
        var encoded = ConversationEventPayloadCodec.encode(original, kind: "transcript.tool")
        XCTAssertTrue(ConversationEventPayloadCodec.hasHeader(encoded))
        // Corrupt the recorded original length.
        encoded[encoded.startIndex + 7] = encoded[encoded.startIndex + 7] &+ 1
        XCTAssertEqual(
            ConversationEventPayloadCodec.decode(encoded), encoded,
            "a length that does not match what inflated must not be trusted")
    }

    func testEncodingIsNotAppliedTwice() throws {
        let original = toolOutput()
        let once = ConversationEventPayloadCodec.encode(original, kind: "transcript.tool")
        let twice = ConversationEventPayloadCodec.encode(once, kind: "transcript.tool")
        XCTAssertEqual(once, twice, "an already-encoded payload must not be wrapped again")
        XCTAssertEqual(ConversationEventPayloadCodec.decode(twice), original)
    }
}
