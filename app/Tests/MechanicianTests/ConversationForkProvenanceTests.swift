import XCTest
@testable import Mechanician

final class ConversationForkProvenanceTests: XCTestCase {
    private func conversation(provenance: ConversationForkProvenance?) -> Conversation {
        Conversation(
            title: "Forked record",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Retained context")],
            updatedAt: Date(timeIntervalSince1970: 1_786_223_100),
            forkProvenance: provenance)
    }

    func testCurrentJSONRoundTripRetainsRecordLocalForkFacts() throws {
        let sourceID = UUID(uuidString: "E54ED3D0-338B-47E6-81A4-382988F07941")!
        let entryID = UUID(uuidString: "7B98C398-C5CE-4D2B-9165-9BD53EF9D596")!
        let provenance = ConversationForkProvenance(
            kind: .assistantResponse,
            sourceConversationID: sourceID,
            sourceTitleSnapshot: "Investigate launch performance",
            forkPointEntryID: entryID,
            createdAt: Date(timeIntervalSince1970: 1_786_223_045.125))

        let encoded = try ConversationStore.makeEncoder().encode(provenance)
        let decoded = try ConversationStore.makeDecoder().decode(
            ConversationForkProvenance.self,
            from: encoded)

        XCTAssertEqual(decoded, provenance)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["kind", "sourceConversationID", "sourceTitleSnapshot", "forkPointEntryID", "createdAt"],
            "Fork provenance must not acquire provider, session, path, or file-instance identity.")
        XCTAssertEqual(object["kind"] as? String, "assistantResponse")
    }

    func testMissingTitleAndFutureFieldsDecodeWithoutDroppingProvenance() throws {
        let json = """
        {
          "kind": "assistantResponse",
          "sourceConversationID": "E54ED3D0-338B-47E6-81A4-382988F07941",
          "forkPointEntryID": "7B98C398-C5CE-4D2B-9165-9BD53EF9D596",
          "createdAt": "2026-08-03T06:24:05.125Z",
          "futurePortableIdentity": {"lineage": "not-current-local-authority"}
        }
        """

        let decoded = try ConversationStore.makeDecoder().decode(
            ConversationForkProvenance.self,
            from: Data(json.utf8))

        XCTAssertEqual(decoded.kind, .assistantResponse)
        XCTAssertNil(decoded.sourceTitleSnapshot)
        XCTAssertEqual(
            decoded.sourceConversationID,
            UUID(uuidString: "E54ED3D0-338B-47E6-81A4-382988F07941"))
    }

    func testUnknownKindSurvivesDecodeAndRoundTrip() throws {
        let json = """
        {
          "kind": "futureForkProfile",
          "sourceConversationID": "E54ED3D0-338B-47E6-81A4-382988F07941",
          "sourceTitleSnapshot": "A source title",
          "forkPointEntryID": "7B98C398-C5CE-4D2B-9165-9BD53EF9D596",
          "createdAt": "2026-08-03T06:24:05Z"
        }
        """

        let decoded = try ConversationStore.makeDecoder().decode(
            ConversationForkProvenance.self,
            from: Data(json.utf8))
        XCTAssertEqual(decoded.kind.rawValue, "futureForkProfile")

        let reencoded = try ConversationStore.makeEncoder().encode(decoded)
        let roundTripped = try ConversationStore.makeDecoder().decode(
            ConversationForkProvenance.self,
            from: reencoded)
        XCTAssertEqual(roundTripped, decoded)
        XCTAssertEqual(roundTripped.kind.rawValue, "futureForkProfile")
    }

    func testClickableSourceRequiresExactLocalConversationIdentity() {
        let sourceID = UUID()
        let provenance = ConversationForkProvenance(
            kind: .assistantResponse,
            sourceConversationID: sourceID,
            sourceTitleSnapshot: "A title shared by many records",
            forkPointEntryID: UUID(),
            createdAt: Date())

        XCTAssertNil(provenance.clickableSourceID(in: []))
        XCTAssertNil(provenance.clickableSourceID(in: [UUID()]))
        XCTAssertEqual(provenance.clickableSourceID(in: [UUID(), sourceID]), sourceID)
    }

    func testForkProvenanceSurvivesTheWholeConversationJSONRoundTrip() throws {
        let provenance = ConversationForkProvenance(
            kind: .assistantResponse,
            sourceConversationID: UUID(),
            sourceTitleSnapshot: "Source conversation",
            forkPointEntryID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_786_223_045))

        let data = try ConversationStore.makeEncoder().encode(conversation(provenance: provenance))
        let decoded = try ConversationStore.makeDecoder().decode(Conversation.self, from: data)

        XCTAssertEqual(decoded.forkProvenance, provenance)
        XCTAssertEqual(decoded.messages.map(\.text), ["Retained context"])
    }

    func testMalformedOptionalForkProvenanceCannotQuarantineTheConversation() throws {
        let original = conversation(provenance: nil)
        let data = try ConversationStore.makeEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["forkProvenance"] = [
            "kind": "assistantResponse",
            "sourceConversationID": "not-a-uuid",
            "forkPointEntryID": UUID().uuidString,
            "createdAt": "2026-08-03T06:24:05Z",
        ]

        let malformed = try JSONSerialization.data(withJSONObject: object)
        let decoded = try ConversationStore.makeDecoder().decode(
            Conversation.self, from: malformed)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.messages.map(\.text), ["Retained context"])
        XCTAssertNil(decoded.forkProvenance)
    }
}
