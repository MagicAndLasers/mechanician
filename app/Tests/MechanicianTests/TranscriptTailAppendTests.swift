import XCTest
@testable import Mechanician

@MainActor
final class TranscriptTailAppendTests: XCTestCase {
    func testExistingAssistantTailPublishesExactAppendDescriptor() throws {
        try withBridge { bridge, conversationID in
            bridge.bufferAssistantTextForTesting("Hello")
            bridge.flushAssistantTextForTesting()

            XCTAssertNil(
                bridge.transcriptTailAppend,
                "creating a transcript row is structural, not a tail append")
            let baseGeneration = bridge.transcriptEntriesGeneration
            let entryID = try XCTUnwrap(bridge.entries.first?.id)

            bridge.bufferAssistantTextForTesting(" 🌍")
            bridge.flushAssistantTextForTesting()

            let append = try XCTUnwrap(bridge.transcriptTailAppend)
            XCTAssertEqual(append.conversationID, conversationID)
            XCTAssertEqual(append.entryID, entryID)
            XCTAssertEqual(append.baseGeneration, baseGeneration)
            XCTAssertEqual(append.generation, bridge.transcriptEntriesGeneration)
            XCTAssertEqual(append.generation, baseGeneration + 1)
            XCTAssertEqual(append.baseUTF8Count, "Hello".utf8.count)
            XCTAssertEqual(append.resultingUTF8Count, "Hello 🌍".utf8.count)
            XCTAssertEqual(append.delta, " 🌍")
            XCTAssertEqual(bridge.entries.first?.text, "Hello 🌍")
        }
    }

    func testCoalescedIngressProducesOneExactDelta() throws {
        try withBridge { bridge, _ in
            bridge.bufferAssistantTextForTesting("prefix")
            bridge.flushAssistantTextForTesting()
            let baseGeneration = bridge.transcriptEntriesGeneration

            bridge.bufferAssistantTextForTesting("-one")
            bridge.bufferAssistantTextForTesting("-two")
            bridge.flushAssistantTextForTesting()

            let append = try XCTUnwrap(bridge.transcriptTailAppend)
            XCTAssertEqual(append.baseGeneration, baseGeneration)
            XCTAssertEqual(append.delta, "-one-two")
            XCTAssertEqual(append.baseUTF8Count, "prefix".utf8.count)
            XCTAssertEqual(append.resultingUTF8Count, "prefix-one-two".utf8.count)
            XCTAssertEqual(bridge.entries.first?.text, "prefix-one-two")
        }
    }

    func testSkippedAppendGenerationCannotReplayOnlyLatestDelta() throws {
        try withBridge { bridge, _ in
            bridge.bufferAssistantTextForTesting("base")
            bridge.flushAssistantTextForTesting()
            let consumerGeneration = bridge.transcriptEntriesGeneration

            bridge.bufferAssistantTextForTesting("-first")
            bridge.flushAssistantTextForTesting()
            let firstAppend = try XCTUnwrap(bridge.transcriptTailAppend)
            XCTAssertEqual(firstAppend.baseGeneration, consumerGeneration)

            bridge.bufferAssistantTextForTesting("-second")
            bridge.flushAssistantTextForTesting()
            let latestAppend = try XCTUnwrap(bridge.transcriptTailAppend)

            XCTAssertEqual(latestAppend.baseGeneration, firstAppend.generation)
            XCTAssertNotEqual(
                latestAppend.baseGeneration,
                consumerGeneration,
                "a consumer that missed the first publication must rebuild canonically")
            XCTAssertEqual(latestAppend.delta, "-second")
            XCTAssertEqual(bridge.entries.first?.text, "base-first-second")
        }
    }

    func testEveryNonAppendTranscriptMutationInvalidatesDescriptor() {
        withBridge { bridge, _ in
            bridge.bufferAssistantTextForTesting("base")
            bridge.flushAssistantTextForTesting()
            bridge.bufferAssistantTextForTesting("-tail")
            bridge.flushAssistantTextForTesting()
            XCTAssertNotNil(bridge.transcriptTailAppend)

            bridge.entries[0].text = "replacement"
            XCTAssertNil(bridge.transcriptTailAppend)

            bridge.bufferAssistantTextForTesting("-append")
            bridge.flushAssistantTextForTesting()
            XCTAssertNotNil(bridge.transcriptTailAppend)

            bridge.entries.append(TranscriptEntry(kind: .system, text: "boundary"))
            XCTAssertNil(bridge.transcriptTailAppend)

            // This deliberately violates the normal structural-close invariant. Even though the
            // bridge still has the old assistant index, metadata must fail closed because that row
            // is no longer the transcript tail.
            bridge.bufferAssistantTextForTesting("-behind-boundary")
            bridge.flushAssistantTextForTesting()
            XCTAssertNil(bridge.transcriptTailAppend)
            XCTAssertEqual(bridge.entries.map(\.text), ["replacement-append-behind-boundary", "boundary"])
        }
    }

    func testConversationOwnershipMismatchFailsClosed() {
        withBridge { bridge, _ in
            bridge.bufferAssistantTextForTesting("base")
            bridge.flushAssistantTextForTesting()

            bridge.currentID = UUID()
            bridge.bufferAssistantTextForTesting("-wrong-owner")
            bridge.flushAssistantTextForTesting()
            XCTAssertNil(bridge.transcriptTailAppend)

            bridge.bufferAssistantTextForTesting("-still-wrong-owner")
            bridge.flushAssistantTextForTesting()
            XCTAssertNil(
                bridge.transcriptTailAppend,
                "a mismatch must not bless the old row as belonging to the new conversation")
        }
    }

    func testSameRowAppendAdvancesFindRefreshSignal() {
        withBridge { bridge, _ in
            bridge.bufferAssistantTextForTesting("needle")
            bridge.flushAssistantTextForTesting()
            bridge.openFind(seed: "needle")
            XCTAssertEqual(bridge.find.matches.count, 1)
            let entryCount = bridge.entries.count
            let generation = bridge.transcriptEntriesGeneration

            bridge.bufferAssistantTextForTesting(" and another needle")
            bridge.flushAssistantTextForTesting()

            XCTAssertEqual(bridge.entries.count, entryCount)
            XCTAssertGreaterThan(bridge.transcriptEntriesGeneration, generation)
            bridge.refreshFindForEntriesChange()
            XCTAssertEqual(
                bridge.find.matches.count,
                2,
                "Find must refresh from transcript generation, not only from row count")
        }
    }

    func testGuidanceStyleBoundaryClosesFrameAndAssistantOwnership() {
        withBridge { bridge, _ in
            bridge.bufferAssistantTextForTesting("before", frameUUID: "partial-before")
            bridge.flushAssistantTextForTesting()
            let firstID = bridge.entries[0].id

            bridge.closeAssistantForStructuralBoundaryForTesting()
            var guidance = TranscriptEntry(kind: .user, text: "change direction")
            guidance.guidanceState = .sending
            bridge.entries.append(guidance)
            bridge.bufferAssistantTextForTesting("after", frameUUID: "partial-after")
            bridge.flushAssistantTextForTesting()

            XCTAssertEqual(bridge.entries.map(\.kind), [.assistant, .user, .assistant])
            XCTAssertEqual(bridge.entries.map(\.text), ["before", "change direction", "after"])
            XCTAssertEqual(bridge.entries[0].id, firstID)
            XCTAssertEqual(bridge.entries[0].providerFrameUUID, "partial-before")
            XCTAssertEqual(bridge.entries[2].providerFrameUUID, "partial-after")
            XCTAssertNotEqual(bridge.entries[2].id, firstID)
            XCTAssertNil(
                bridge.transcriptTailAppend,
                "the first post-boundary prose creates a row and cannot masquerade as a tail append")
        }
    }

    private func withBridge(
        _ body: (AgentBridge, UUID) throws -> Void
    ) rethrows {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let conversationID = UUID()
        let store = ConversationStore(appSupportBaseOverride: support, watchesDirectory: false)
        store.upsert(Conversation(
            id: conversationID,
            title: "Tail append fixture",
            cwd: "/tmp",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date()))
        store.flushSaves()
        let bridge = AgentBridge(
            settingsBaseOverride: support,
            environmentOverride: [:],
            conversationStoreOverride: store)
        bridge.entries = []
        bridge.currentID = conversationID

        try body(bridge, conversationID)
        store.flushSaves()
    }
}
