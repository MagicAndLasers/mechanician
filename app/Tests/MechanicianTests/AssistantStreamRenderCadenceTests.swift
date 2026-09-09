import Combine
import XCTest
@testable import Mechanician

@MainActor
final class AssistantStreamRenderCadenceTests: XCTestCase {
    func testShortResponseInShortTranscriptKeepsDisplayCadence() {
        XCTAssertEqual(frames(bytes: 4_096, entries: 100), 60)
        XCTAssertEqual(delay(bytes: 4_096, entries: 100), 1.0 / 60.0, accuracy: 0.000_001)
    }

    func testAccumulatedResponseAdaptivelyReducesFullMarkdownRenders() {
        XCTAssertEqual(frames(bytes: 16 * 1_024 - 1, entries: 100), 60)
        XCTAssertEqual(frames(bytes: 16 * 1_024, entries: 100), 30)
        XCTAssertEqual(frames(bytes: 64 * 1_024, entries: 100), 15)
        XCTAssertEqual(frames(bytes: 256 * 1_024, entries: 100), 8)
        XCTAssertEqual(frames(bytes: 1_024 * 1_024, entries: 100), 4)
    }

    func testLongTranscriptAdaptivelyReducesWholeProjectionRebuilds() {
        XCTAssertEqual(frames(bytes: 1_024, entries: 511), 60)
        XCTAssertEqual(frames(bytes: 1_024, entries: 512), 30)
        XCTAssertEqual(frames(bytes: 1_024, entries: 2_048), 15)
        XCTAssertEqual(frames(bytes: 1_024, entries: 8_192), 8)
    }

    func testMostExpensiveInputOwnsCadence() {
        XCTAssertEqual(frames(bytes: 256 * 1_024, entries: 10_000), 8)
        XCTAssertEqual(frames(bytes: 80 * 1_024, entries: 10_000), 8)
        XCTAssertEqual(frames(bytes: 20 * 1_024, entries: 3_000), 15)
    }

    func testCadenceIsMonotonicAcrossIncreasingWork() {
        let byteSamples = [0, 16 * 1_024, 64 * 1_024, 256 * 1_024, 1_048_576]
        let entrySamples = [0, 512, 2_048, 8_192, 20_000]

        for entries in entrySamples {
            let rates = byteSamples.map { frames(bytes: $0, entries: entries) }
            XCTAssertEqual(rates, rates.sorted(by: >))
        }
        for bytes in byteSamples {
            let rates = entrySamples.map { frames(bytes: bytes, entries: $0) }
            XCTAssertEqual(rates, rates.sorted(by: >))
        }
    }

    func testInvalidNegativeEstimatesKeepFullCadence() {
        XCTAssertEqual(frames(bytes: -1, entries: -1), 60)
    }

    func testSynchronousBoundaryFlushPublishesExactTextOnceAndCancelsDelayedFlush() async {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let conversationID = UUID()
        let store = ConversationStore(appSupportBaseOverride: support, watchesDirectory: false)
        store.upsert(Conversation(
            id: conversationID,
            title: "Streaming cadence fixture",
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
        var publications = 0
        let observation = bridge.objectWillChange.sink { publications += 1 }
        var entryPublications = 0
        let entryObservation = bridge.$entries.dropFirst().sink { _ in entryPublications += 1 }
        let payload = String(repeating: "streamed-markdown ", count: 65_536)

        bridge.bufferAssistantTextForTesting(payload)
        XCTAssertEqual(publications, 0, "provider ingress stays buffered until presentation")
        XCTAssertEqual(
            bridge.store.nextCaptureOrdinal(for: conversationID),
            2,
            "the first streamed delta reserves chronology before its timer mutates the transcript")

        bridge.flushAssistantTextForTesting()
        XCTAssertEqual(bridge.entries.map(\.text), [payload])
        XCTAssertEqual(bridge.entries.first?.captureOrdinal, 1)
        XCTAssertEqual(publications, 1, "one @Published mutation is the complete boundary flush")
        XCTAssertEqual(entryPublications, 1)

        let suffix = "final suffix"
        bridge.bufferAssistantTextForTesting(suffix)
        XCTAssertEqual(publications, 1, "existing-row ingress also stays presentation-buffered")
        bridge.flushAssistantTextForTesting()
        XCTAssertEqual(bridge.entries.map(\.text), [payload + suffix])
        XCTAssertEqual(publications, 2, "an existing @Published array element emits exactly once")
        XCTAssertEqual(entryPublications, 2)

        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(bridge.entries.map(\.text), [payload + suffix])
        XCTAssertEqual(
            entryPublications,
            2,
            "the canceled delayed work must not publish a second transcript mutation")
        store.flushSaves()
        withExtendedLifetime((observation, entryObservation)) {}
    }

    private func frames(bytes: Int, entries: Int) -> Double {
        AssistantStreamRenderCadence.framesPerSecond(
            accumulatedUTF8Bytes: bytes,
            transcriptEntryCount: entries)
    }

    private func delay(bytes: Int, entries: Int) -> TimeInterval {
        AssistantStreamRenderCadence.delay(
            accumulatedUTF8Bytes: bytes,
            transcriptEntryCount: entries)
    }
}
