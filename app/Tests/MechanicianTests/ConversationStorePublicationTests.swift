import Combine
import XCTest
@testable import Mechanician

@MainActor
final class ConversationStorePublicationTests: XCTestCase {
    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Mechanician-store-publication-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func conversation(
        messages: [TranscriptEntry] = [TranscriptEntry(kind: .user, text: "hello")]
    ) -> Conversation {
        Conversation(
            title: "Publication fixture",
            cwd: "/tmp/publication-fixture",
            sdkSessionId: nil,
            messages: messages,
            updatedAt: Date(timeIntervalSinceReferenceDate: 10_000))
    }

    private func seededStore(
        at base: URL,
        conversation: Conversation,
        checkpointLatency: TimeInterval = 5
    ) -> ConversationStore {
        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            liveCheckpointMaximumLatency: checkpointLatency)
        store.upsert(conversation)
        store.flushSaves()
        return store
    }

    private func awaitReady(_ store: ConversationStore) async {
        await withCheckedContinuation { continuation in
            store.whenReady { continuation.resume() }
        }
        for _ in 0..<10_000 {
            if store.activeResidencyMode == .boundedAfterRecovery { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("bounded residency did not activate")
    }

    func testThousandSummaryNeutralLiveMutationsDoNotFanOut() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = conversation()
        let store = seededStore(at: base, conversation: fixture)
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }

        for index in 0..<1_000 {
            store.updateLive(fixture.id) { $0.sdkSessionId = "session-\(index)" }
        }

        XCTAssertEqual(store.conversation(fixture.id)?.sdkSessionId, "session-999")
        XCTAssertEqual(publications, 0)
        store.flushLiveSummaryRefreshes()
        XCTAssertEqual(
            publications,
            0,
            "an equal coalesced summary must not turn hidden live state into global repainting")
        withExtendedLifetime(observation) {}
    }

    func testTranscriptLiveMutationsPublishOnceAtSummaryBoundary() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = conversation(messages: [
            TranscriptEntry(kind: .user, text: "hello"),
            TranscriptEntry(kind: .assistant, text: ""),
        ])
        let store = seededStore(at: base, conversation: fixture)
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }
        var contentPulses: [Set<UUID>] = []
        let contentObservation = store.liveResidentContentDidChange.sink {
            contentPulses.append($0)
        }

        for _ in 0..<1_000 {
            store.updateLive(fixture.id, searchableTextChanged: true) {
                $0.messages[1].text.append("x")
            }
        }

        XCTAssertEqual(publications, 0)
        XCTAssertEqual(store.conversation(fixture.id)?.messages[1].text.count, 1_000)
        store.flushLiveSummaryRefreshes()
        XCTAssertEqual(publications, 1)
        XCTAssertTrue(
            contentPulses.isEmpty,
            "a changed summary already invalidates active search and must not trigger a second scan")
        XCTAssertEqual(store.summary(fixture.id)?.snippet, String(repeating: "x", count: 239) + "…")
        withExtendedLifetime((observation, contentObservation)) {}
    }

    func testSummaryNeutralLiveTranscriptContentPulsesOnlyAtBoundedBoundary() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let stablePrefix = String(repeating: "a", count: 300)
        let fixture = conversation(messages: [
            TranscriptEntry(kind: .assistant, text: stablePrefix),
        ])
        let store = seededStore(at: base, conversation: fixture)
        var generalPublications = 0
        let generalObservation = store.objectWillChange.sink { generalPublications += 1 }
        var contentPulses: [Set<UUID>] = []
        let contentObservation = store.liveResidentContentDidChange.sink {
            contentPulses.append($0)
        }

        XCTAssertTrue(ConversationSidebarSnapshot.residentContentMatches(
            in: [fixture], query: "searchable needle").isEmpty)
        for index in 0..<1_000 {
            store.updateLive(fixture.id, searchableTextChanged: true) {
                $0.messages[0].text = stablePrefix + " hidden searchable needle \(index)"
            }
        }

        XCTAssertEqual(generalPublications, 0)
        XCTAssertTrue(contentPulses.isEmpty)
        XCTAssertEqual(
            store.summary(fixture.id)?.snippet,
            String(repeating: "a", count: 239) + "…",
            "the fixture must keep its lightweight summary unchanged")
        store.flushLiveSummaryRefreshes()
        XCTAssertEqual(generalPublications, 0)
        XCTAssertEqual(contentPulses, [[fixture.id]])
        let resident = try XCTUnwrap(store.conversation(fixture.id))
        XCTAssertEqual(
            ConversationSidebarSnapshot.residentContentMatches(
                in: [resident], query: "searchable needle"),
            [fixture.id],
            "the exact eager-search helper must see text beyond the unchanged summary snippet")
        withExtendedLifetime((generalObservation, contentObservation)) {}
    }

    func testSummaryNeutralContentPulseBatchesEveryLiveConversation() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let stablePrefix = String(repeating: "b", count: 300)
        let first = conversation(messages: [
            TranscriptEntry(kind: .assistant, text: stablePrefix),
        ])
        var second = conversation(messages: [
            TranscriptEntry(kind: .assistant, text: stablePrefix),
        ])
        second.id = UUID()
        let store = seededStore(at: base, conversation: first)
        store.upsert(second)
        var contentPulses: [Set<UUID>] = []
        let observation = store.liveResidentContentDidChange.sink {
            contentPulses.append($0)
        }

        for fixture in [first, second] {
            store.updateLive(fixture.id, searchableTextChanged: true) {
                $0.messages[0].text += " hidden batch needle"
            }
        }
        store.flushLiveSummaryRefreshes()

        XCTAssertEqual(
            contentPulses,
            [[first.id, second.id]],
            "all live conversations share one bounded search invalidation per process")
        withExtendedLifetime(observation) {}
    }

    func testMixedLiveBatchPublishesOneSummaryAndNoRedundantContentPulse() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let summaryChanging = conversation(messages: [
            TranscriptEntry(kind: .assistant, text: ""),
        ])
        var summaryNeutral = conversation(messages: [
            TranscriptEntry(kind: .assistant, text: String(repeating: "c", count: 300)),
        ])
        summaryNeutral.id = UUID()
        let store = seededStore(at: base, conversation: summaryChanging)
        store.upsert(summaryNeutral)
        var generalPublications = 0
        let generalObservation = store.objectWillChange.sink { generalPublications += 1 }
        var contentPulses: [Set<UUID>] = []
        let contentObservation = store.liveResidentContentDidChange.sink {
            contentPulses.append($0)
        }

        store.updateLive(summaryChanging.id, searchableTextChanged: true) {
            $0.messages[0].text = "new visible summary"
        }
        store.updateLive(summaryNeutral.id, searchableTextChanged: true) {
            $0.messages[0].text += " hidden mixed-batch needle"
        }
        store.flushLiveSummaryRefreshes()

        XCTAssertEqual(generalPublications, 1)
        XCTAssertTrue(
            contentPulses.isEmpty,
            "the batch's general summary publication already refreshes every active search")
        XCTAssertEqual(store.summary(summaryChanging.id)?.snippet, "new visible summary")
        withExtendedLifetime((generalObservation, contentObservation)) {}
    }

    func testDurableBoundaryCancelsPendingLiveRefreshWithoutDuplicatePublication() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = conversation(messages: [
            TranscriptEntry(kind: .user, text: "hello"),
            TranscriptEntry(kind: .assistant, text: "draft"),
        ])
        let store = seededStore(at: base, conversation: fixture)
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }
        var contentPulses: [Set<UUID>] = []
        let contentObservation = store.liveResidentContentDidChange.sink {
            contentPulses.append($0)
        }

        store.updateLive(fixture.id, searchableTextChanged: true) {
            $0.messages[1].text = "streaming"
        }
        XCTAssertEqual(publications, 0)
        store.update(fixture.id) {
            $0.messages[1].text = "final"
            $0.errored = true
        }

        XCTAssertEqual(publications, 1)
        XCTAssertEqual(store.summary(fixture.id)?.snippet, "final")
        store.flushLiveSummaryRefreshes()
        XCTAssertEqual(publications, 1, "the canceled live refresh must not publish later")
        XCTAssertTrue(contentPulses.isEmpty)

        store.updateLive(fixture.id) { $0.sdkSessionId = "later-summary-neutral-change" }
        store.flushLiveSummaryRefreshes()
        XCTAssertTrue(
            contentPulses.isEmpty,
            "a canceled transcript pulse must not leak into an unrelated later live boundary")
        store.flushSaves()
        withExtendedLifetime((observation, contentObservation)) {}
    }

    func testEveryDurableSummaryNeutralMutationSeamPublishesOneFallback() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        var fixture = conversation()
        let store = seededStore(at: base, conversation: fixture)
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }

        fixture.sdkSessionId = "upsert-session"
        store.upsert(fixture)
        XCTAssertEqual(publications, 1)

        publications = 0
        store.updateResident(fixture.id) { $0.sdkSessionId = "resident-session" }
        XCTAssertEqual(publications, 1)

        publications = 0
        store.updateAwaitingPersistence(
            fixture.id,
            { $0.sdkSessionId = "awaited-session" },
            completion: { _ in })
        XCTAssertEqual(publications, 1)

        publications = 0
        store.update(fixture.id) { $0.title = "Summary change" }
        XCTAssertEqual(
            publications,
            1,
            "a changed summary is the publication; the resident fallback must not duplicate it")
        store.flushSaves()
        withExtendedLifetime(observation) {}
    }

    func testExplicitRuntimeOnlyPresentationStampPublishesWithoutPersistence() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        var fixture = conversation()
        fixture.armedTrigger = ArmedTrigger(
            note: "wait for completion",
            check: "test -f /tmp/complete",
            deadline: nil,
            armedAt: Date(timeIntervalSinceReferenceDate: 9_000),
            expiresAt: Date(timeIntervalSinceReferenceDate: 20_000))
        let store = seededStore(at: base, conversation: fixture, checkpointLatency: 0.01)
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }
        let checkedAt = Date(timeIntervalSinceReferenceDate: 11_000)

        let writesBeforeRuntimeStamp = store.completedDiskWrites
        store.updateLive(
            fixture.id,
            publishResidentChange: true,
            persistence: .runtimeOnly
        ) {
            $0.armedTrigger?.lastCheckedAt = checkedAt
        }

        XCTAssertEqual(publications, 1)
        XCTAssertEqual(store.conversation(fixture.id)?.armedTrigger?.lastCheckedAt, checkedAt)
        store.flushLiveSummaryRefreshes()
        XCTAssertEqual(publications, 1, "lastCheckedAt is intentionally absent from the summary")
        try await Task.sleep(nanoseconds: 30_000_000)
        store.flushSaves()
        XCTAssertEqual(
            store.completedDiskWrites,
            writesBeforeRuntimeStamp,
            "a runtime-only stamp must not advance the authority write sequence")
        let persisted = try ConversationStore.makeDecoder().decode(
            Conversation.self,
            from: Data(contentsOf: base.appendingPathComponent(
                "conversations/\(fixture.id.uuidString).json")))
        XCTAssertNil(persisted.armedTrigger?.lastCheckedAt)
        withExtendedLifetime(observation) {}
    }

    func testHydrationAndEvictionEachPublishOneResidentBoundary() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = conversation()
        var secondFixture = conversation()
        secondFixture.id = UUID()
        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for seeded in [fixture, secondFixture] {
            try ConversationStore.makeEncoder().encode(seeded).write(
                to: directory.appendingPathComponent("\(seeded.id.uuidString).json"))
        }
        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertFalse(store.residentConversationIDs.contains(fixture.id))
        XCTAssertFalse(store.residentConversationIDs.contains(secondFixture.id))
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }

        XCTAssertEqual(store.hydrateImmediately(fixture.id)?.id, fixture.id)
        XCTAssertEqual(store.hydrateImmediately(secondFixture.id)?.id, secondFixture.id)
        XCTAssertEqual(publications, 2, "each independent hydration is one cache boundary")

        publications = 0
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertEqual(publications, 1, "one multi-record eviction batch is one publication")
        XCTAssertFalse(store.residentConversationIDs.contains(fixture.id))
        XCTAssertFalse(store.residentConversationIDs.contains(secondFixture.id))
        withExtendedLifetime(observation) {}
    }
}
