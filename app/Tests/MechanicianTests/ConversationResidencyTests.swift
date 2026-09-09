import XCTest
@testable import Mechanician

/// Safety boundaries for P1b's bounded full-record cache.
///
/// These tests deliberately exercise the store through sidecars rather than constructing fake
/// inventory rows. The file remains authoritative: eviction may discard only the decoded value,
/// while hydration must recover that exact value or report a failure without inventing a shell.
@MainActor
final class ConversationResidencyTests: XCTestCase {
    override func tearDown() {
        ConversationStore.hydrationWillReadTestHook = nil
        ConversationStore.hydrationDidReadTestHook = nil
        super.tearDown()
    }

    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Mechanician-residency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func conversation(
        title: String,
        queuedPrompts: [String] = [],
        armedTrigger: ArmedTrigger? = nil
    ) -> Conversation {
        Conversation(
            title: title,
            cwd: "/tmp/\(title)",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "durable \(title)")],
            updatedAt: Date(),
            queuedPrompts: queuedPrompts,
            armedTrigger: armedTrigger)
    }

    private func seed(_ conversations: [Conversation], at base: URL) throws {
        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for conversation in conversations {
            try ConversationStore.makeEncoder().encode(conversation).write(
                to: directory.appendingPathComponent("\(conversation.id.uuidString).json"))
        }
    }

    private func awaitReady(_ store: ConversationStore) async {
        await withCheckedContinuation { continuation in
            store.whenReady { continuation.resume() }
        }
        // Readiness is intentionally earlier than disposable-projection reconciliation. These
        // residency tests need the later activation edge before asserting eviction behavior.
        for _ in 0..<10_000 {
            if store.activeResidencyMode == .boundedAfterRecovery { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("bounded residency did not activate after projection reconciliation")
    }

    private func acquire(
        _ id: UUID,
        from store: ConversationStore
    ) async -> Result<Conversation, ConversationHydrationError> {
        await withCheckedContinuation { continuation in
            store.acquireConversation(id) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func exportDocument(
        _ id: UUID,
        from store: ConversationStore
    ) async -> Result<ConversationMarkdownDocument, ConversationHydrationError> {
        await withCheckedContinuation { continuation in
            ConversationMarkdownExport.document(for: id, in: store) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func remove(
        _ id: UUID,
        from store: ConversationStore
    ) async -> ConversationDeleteReceipt? {
        await withCheckedContinuation { continuation in
            store.removeAfterAcquiring(id) { continuation.resume(returning: $0) }
        }
    }

    private func projectedSummaries(
        _ store: ConversationProjectionStore
    ) async -> [ConversationSummary] {
        await withCheckedContinuation { continuation in
            store.summaries { continuation.resume(returning: $0) }
        }
    }

    func testResidentByteEstimateIncludesCompactionSummary() {
        var boundary = TranscriptEntry(kind: .compaction, text: "boundary")
        boundary.compactionSummary = "continuity summary"
        boundary.compactionSummarySource = "claude_post_compact"
        let conversation = Conversation(
            title: "Compaction accounting", cwd: "", sdkSessionId: nil,
            messages: [boundary], updatedAt: Date())

        XCTAssertEqual(
            ConversationStore.estimatedResidentByteCount(conversation),
            boundary.text.utf8.count + (boundary.compactionSummary?.utf8.count ?? 0))
    }

    func testBoundedResidencyPreservesCompleteSummaryInventoryAndCoalescesHydration() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let seeded = (0..<7).map { conversation(title: "Record \($0)") }
        try seed(seeded, at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        XCTAssertEqual(store.activeResidencyMode, .boundedAfterRecovery)

        store.trimResidencyIfNeeded(evictAllEligible: true)

        let allIDs = Set(seeded.map(\.id))
        XCTAssertEqual(Set(store.summaries.map(\.id)), allIDs)
        XCTAssertEqual(store.conversationIDs, allIDs)
        XCTAssertTrue(allIDs.allSatisfy(store.contains))
        XCTAssertTrue(store.residentConversationIDs.isEmpty)

        let target = try XCTUnwrap(seeded.first)
        var completedSynchronously = false
        typealias HydrationResult = Result<Conversation, ConversationHydrationError>
        let results = await withCheckedContinuation {
            (continuation: CheckedContinuation<[HydrationResult], Never>) in
            var received: [Result<Conversation, ConversationHydrationError>] = []
            let receive: @MainActor (Result<Conversation, ConversationHydrationError>) -> Void = {
                result in
                received.append(result)
                if received.count == 2 { continuation.resume(returning: received) }
            }
            store.acquireConversation(target.id) {
                completedSynchronously = true
                receive($0)
            }
            store.acquireConversation(target.id, completion: receive)
            XCTAssertFalse(
                completedSynchronously,
                "An evicted record must decode on the hydration queue, never inline on the "
                    + "main actor.")
        }

        XCTAssertEqual(results.count, 2)
        for result in results {
            let hydrated = try XCTUnwrap(try? result.get())
            XCTAssertEqual(hydrated.id, target.id)
            XCTAssertEqual(hydrated.messages.map(\.text), ["durable Record 0"])
        }
        XCTAssertEqual(
            store.hydrationDecodeCounts[target.id], 1,
            "Concurrent acquisitions of one id must share one decode.")
        XCTAssertEqual(store.synchronousHydrationCount, 0)
    }

    func testPromisedAttachmentPinsOriginalConversationUntilTransferEnds() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let seeded = conversation(title: "Promised attachment")
        try seed([seeded], at: base)
        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)

        AgentBridge.retainPromisedAttachmentConversation(seeded.id)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertNotNil(store.residentConversation(seeded.id))

        AgentBridge.releasePromisedAttachmentConversation(seeded.id)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertNil(store.residentConversation(seeded.id))
    }

    func testRecentBackNavigationRetentionAvoidsSecondHydrationUntilExpiry() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = conversation(title: "Large predecessor")
        let second = conversation(title: "New destination")
        try seed([first, second], at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)

        _ = try await acquire(first.id, from: store).get()
        XCTAssertEqual(store.hydrationDecodeCounts[first.id], 1)

        let owner = UUID()
        let retainedAt = Date()
        store.retainForBackNavigation(first.id, owner: owner, now: retainedAt)
        _ = try await acquire(second.id, from: store).get()
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertNotNil(
            store.residentConversation(first.id),
            "leaving A for B must not evict the one record an immediate Back returns to")

        var completedInline = false
        store.acquireConversation(first.id) { result in
            if case .failure(let error) = result {
                XCTFail("retained predecessor failed to load: \(error)")
            }
            completedInline = true
        }
        XCTAssertTrue(completedInline, "returning to the retained predecessor must not wait on I/O")
        XCTAssertEqual(
            store.hydrationDecodeCounts[first.id],
            1,
            "A→B→A must reuse the validated record instead of decoding it twice")
        XCTAssertEqual(store.synchronousHydrationCount, 0)

        store.expireBackNavigationRetentions(
            asOf: retainedAt.addingTimeInterval(
                ConversationStore.backNavigationRetentionInterval + 1))
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertNil(
            store.residentConversation(first.id),
            "expiry must return the predecessor to the ordinary bounded-residency budget")
    }

    func testBackNavigationRetentionReplacesPerOwnerAndHonorsOtherOwners() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = conversation(title: "First predecessor")
        let second = conversation(title: "Replacement predecessor")
        try seed([first, second], at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        let firstOwner = UUID()
        let secondOwner = UUID()

        store.retainForBackNavigation(first.id, owner: firstOwner)
        store.retainForBackNavigation(second.id, owner: firstOwner)
        store.retainForBackNavigation(second.id, owner: secondOwner)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertNil(
            store.residentConversation(first.id),
            "a third selection must replace, not accumulate, one window's predecessor")
        XCTAssertNotNil(store.residentConversation(second.id))

        store.releaseBackNavigationRetention(owner: firstOwner)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertNotNil(
            store.residentConversation(second.id),
            "one window closing must not release another window's lease on the same record")
        store.releaseBackNavigationRetention(owner: secondOwner)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertNil(store.residentConversation(second.id))
    }

    func testCompletionlessSidebarMutationRunsForResidentAndEvictedRecords() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let resident = conversation(title: "Resident pin")
        let evicted = conversation(title: "Evicted pin")
        try seed([resident, evicted], at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)

        _ = try await acquire(resident.id, from: store).get()
        XCTAssertNotNil(store.residentConversation(resident.id))
        store.updateAfterAcquiring(resident.id) {
            $0.favorite.toggle()
            $0.unread = true
            $0.sortIndex = 7
        }
        XCTAssertEqual(
            store.summary(resident.id)?.favorite,
            true,
            "a completionless pin must mutate a resident conversation synchronously")
        XCTAssertEqual(store.summary(resident.id)?.unread, true)
        XCTAssertEqual(store.summary(resident.id)?.sortIndex, 7)

        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertNil(store.residentConversation(evicted.id))
        store.updateAfterAcquiring(evicted.id) {
            $0.favorite.toggle()
            $0.unread = true
            $0.sortIndex = 11
        }
        for _ in 0..<10_000 where store.summary(evicted.id)?.favorite != true {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(
            store.summary(evicted.id)?.favorite,
            true,
            "a completionless pin must hydrate and mutate an evicted conversation")
        XCTAssertEqual(store.summary(evicted.id)?.unread, true)
        XCTAssertEqual(store.summary(evicted.id)?.sortIndex, 11)
        XCTAssertEqual(store.synchronousHydrationCount, 0)

        store.flushSaves()
        for conversation in [resident, evicted] {
            let url = base.appendingPathComponent("conversations", isDirectory: true)
                .appendingPathComponent("\(conversation.id.uuidString).json")
            let persisted = try ConversationStore.makeDecoder().decode(
                Conversation.self,
                from: Data(contentsOf: url))
            XCTAssertTrue(persisted.favorite, "the pin mutation must survive relaunch")
            XCTAssertTrue(persisted.unread, "the read-state mutation must survive relaunch")
            XCTAssertNotNil(persisted.sortIndex, "the reorder mutation must survive relaunch")
        }
    }

    func testBulkFavoritePersistsForResidentAndEvictedRowsWithoutChangingPlacement() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let updatedAt = Date(timeIntervalSince1970: 1_777_777_777.123)
        var resident = conversation(title: "Resident bulk unpin")
        resident.favorite = true
        resident.unread = true
        resident.sortIndex = 4
        resident.updatedAt = updatedAt
        var evicted = conversation(title: "Evicted bulk unpin")
        evicted.favorite = true
        evicted.unread = true
        evicted.sortIndex = 9
        evicted.updatedAt = updatedAt
        try seed([resident, evicted], at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        _ = try await acquire(resident.id, from: store).get()
        XCTAssertNil(store.residentConversation(evicted.id))

        store.setConversationsFavorite([resident.id, evicted.id], to: false)
        store.setConversationsUnread([resident.id, evicted.id], to: false)
        XCTAssertEqual(store.summary(resident.id)?.favorite, false)
        XCTAssertEqual(store.summary(resident.id)?.unread, false)
        for _ in 0..<10_000 where store.summary(evicted.id)?.favorite != false {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(store.summary(evicted.id)?.favorite, false)
        XCTAssertEqual(store.summary(evicted.id)?.unread, false)
        XCTAssertEqual(store.summary(resident.id)?.sortIndex, 4)
        XCTAssertEqual(store.summary(evicted.id)?.sortIndex, 9)
        XCTAssertEqual(store.summary(resident.id)?.updatedAt, updatedAt)
        XCTAssertEqual(store.summary(evicted.id)?.updatedAt, updatedAt)
        XCTAssertEqual(store.synchronousHydrationCount, 0)
        XCTAssertEqual(store.hydrationDecodeCounts[evicted.id], 1)

        store.flushSaves()
        let relaunched = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false)
        for (id, sortIndex) in [(resident.id, 4), (evicted.id, 9)] {
            XCTAssertEqual(relaunched.summary(id)?.favorite, false)
            XCTAssertEqual(relaunched.summary(id)?.unread, false)
            XCTAssertEqual(relaunched.summary(id)?.sortIndex, sortIndex)
            XCTAssertEqual(relaunched.summary(id)?.updatedAt, updatedAt)
        }
    }

    func testBulkFavoriteSkipsAlreadyMatchingEvictedRows() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        var alreadyPinned = conversation(title: "Already pinned")
        alreadyPinned.favorite = true
        let needsPin = conversation(title: "Needs pin")
        try seed([alreadyPinned, needsPin], at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)

        store.setConversationsFavorite([alreadyPinned.id, needsPin.id], to: true)
        for _ in 0..<10_000 where store.summary(needsPin.id)?.favorite != true {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(store.summary(needsPin.id)?.favorite, true)
        XCTAssertNil(
            store.hydrationDecodeCounts[alreadyPinned.id],
            "a bulk state command must not decode an already-matching evicted transcript")
        XCTAssertEqual(store.synchronousHydrationCount, 0)
        store.flushSaves()
    }

    func testLatestSidebarStateWinsAcrossReorderFavoriteAndReadCommands() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        var seeded = conversation(title: "Interleaved sidebar state")
        seeded.favorite = true
        seeded.unread = true
        seeded.sortIndex = 0
        try seed([seeded], at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)

        let readStarted = expectation(description: "sidebar mutation began hydration")
        let releaseRead = DispatchSemaphore(value: 0)
        ConversationStore.hydrationWillReadTestHook = { id in
            guard id == seeded.id else { return }
            readStarted.fulfill()
            releaseRead.wait()
        }
        defer {
            releaseRead.signal()
            ConversationStore.hydrationWillReadTestHook = nil
        }

        store.applySidebarOrder([seeded.id], unpinning: [seeded.id])
        await fulfillment(of: [readStarted], timeout: 5)
        store.setConversationsFavorite([seeded.id], to: true)
        store.setConversationsUnread([seeded.id], to: false)
        store.setConversationsUnread([seeded.id], to: true)
        store.applySidebarOrder([seeded.id], unpinning: [seeded.id])
        releaseRead.signal()

        for _ in 0..<10_000 where store.residentConversation(seeded.id) == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        ConversationStore.hydrationWillReadTestHook = nil
        XCTAssertEqual(store.summary(seeded.id)?.favorite, false)
        XCTAssertEqual(store.summary(seeded.id)?.unread, true)
        XCTAssertEqual(store.summary(seeded.id)?.sortIndex, 0)
        XCTAssertEqual(store.hydrationDecodeCounts[seeded.id], 1)
        XCTAssertEqual(store.synchronousHydrationCount, 0)

        store.flushSaves()
        let relaunched = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false)
        XCTAssertEqual(relaunched.summary(seeded.id)?.favorite, false)
        XCTAssertEqual(relaunched.summary(seeded.id)?.unread, true)
        XCTAssertEqual(relaunched.summary(seeded.id)?.sortIndex, 0)
    }

    func testSidebarStateReversalToAuthorityAvoidsANoOpRewrite() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        var seeded = conversation(title: "Convergent sidebar state")
        seeded.favorite = true
        seeded.unread = true
        try seed([seeded], at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        let readStarted = expectation(description: "convergent mutation began hydration")
        let releaseRead = DispatchSemaphore(value: 0)
        ConversationStore.hydrationWillReadTestHook = { id in
            guard id == seeded.id else { return }
            readStarted.fulfill()
            releaseRead.wait()
        }
        defer {
            releaseRead.signal()
            ConversationStore.hydrationWillReadTestHook = nil
        }

        store.setConversationsFavorite([seeded.id], to: false)
        await fulfillment(of: [readStarted], timeout: 5)
        store.setConversationsUnread([seeded.id], to: false)
        store.setConversationsFavorite([seeded.id], to: true)
        store.setConversationsUnread([seeded.id], to: true)
        releaseRead.signal()

        for _ in 0..<10_000 where store.residentConversation(seeded.id) == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        ConversationStore.hydrationWillReadTestHook = nil
        store.flushSaves()
        XCTAssertEqual(store.summary(seeded.id)?.favorite, true)
        XCTAssertEqual(store.summary(seeded.id)?.unread, true)
        XCTAssertEqual(store.hydrationDecodeCounts[seeded.id], 1)
        XCTAssertEqual(
            store.completedDiskWrites,
            0,
            "a command sequence that returns to authority must not rewrite the transcript")
    }

    func testFailedSidebarMutationCanRetryAfterTheRecordReturns() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let seeded = conversation(title: "Temporarily unavailable sidebar row")
        try seed([seeded], at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        let source = base.appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(seeded.id.uuidString).json")
        let bytes = try Data(contentsOf: source)
        try FileManager.default.removeItem(at: source)

        store.setConversationsFavorite([seeded.id], to: true)
        for _ in 0..<10_000 where store.hydrationError == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNotNil(store.hydrationError)
        XCTAssertEqual(store.summary(seeded.id)?.favorite, false)

        try bytes.write(to: source)
        store.setConversationsFavorite([seeded.id], to: true)
        for _ in 0..<10_000 where store.summary(seeded.id)?.favorite != true {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(
            store.summary(seeded.id)?.favorite,
            true,
            "a failed hydration must release the pending sidebar owner so a retry can start")
        XCTAssertNil(store.hydrationError)
        XCTAssertEqual(store.synchronousHydrationCount, 0)
        store.flushSaves()
    }

    func testPinnedDropPersistsForEvictedRowAlreadyAtItsDestinationIndex() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        var pinned = conversation(title: "Pinned first")
        pinned.favorite = true
        pinned.sortIndex = 0
        var dragged = conversation(title: "Dragged into Pinned")
        dragged.sortIndex = 1
        var remaining = conversation(title: "Remaining unpinned")
        remaining.sortIndex = 2
        try seed([pinned, dragged, remaining], at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertNil(store.residentConversation(dragged.id))

        store.applySidebarOrder(
            [pinned.id, dragged.id, remaining.id],
            pinning: [dragged.id])
        for _ in 0..<10_000 where store.summary(dragged.id)?.favorite != true {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(store.summary(dragged.id)?.favorite == true)
        XCTAssertEqual(store.summary(dragged.id)?.sortIndex, 1)
        store.flushSaves()

        let relaunched = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false)
        XCTAssertEqual(
            relaunched.summaries.map(\.id),
            [pinned.id, dragged.id, remaining.id])
        XCTAssertEqual(
            relaunched.summaries.filter(\.favorite).map(\.id),
            [pinned.id, dragged.id],
            "pinning must not be skipped merely because the dragged row already had its new index")
    }

    func testPinnedDragOutPersistsForResidentAndEvictedRowsAtTheirDestinationIndices() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        var resident = conversation(title: "Resident pinned")
        resident.favorite = true
        resident.sortIndex = 0
        var evicted = conversation(title: "Evicted pinned")
        evicted.favorite = true
        evicted.sortIndex = 1
        var remaining = conversation(title: "Remaining ordinary")
        remaining.sortIndex = 2
        try seed([resident, evicted, remaining], at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        _ = try await acquire(resident.id, from: store).get()
        XCTAssertNotNil(store.residentConversation(resident.id))
        XCTAssertNil(store.residentConversation(evicted.id))

        let order = [resident.id, evicted.id, remaining.id]
        let unpinning: Set<UUID> = [resident.id, evicted.id]
        store.applySidebarOrder(order, unpinning: unpinning)

        XCTAssertEqual(
            store.summary(resident.id)?.favorite,
            false,
            "a resident row must unpin synchronously even when its index is already correct")
        for _ in 0..<10_000 where store.summary(evicted.id)?.favorite != false {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(
            store.summary(evicted.id)?.favorite,
            false,
            "an evicted row must hydrate and unpin even when its index is already correct")
        XCTAssertEqual(store.summary(resident.id)?.sortIndex, 0)
        XCTAssertEqual(store.summary(evicted.id)?.sortIndex, 1)
        XCTAssertEqual(store.synchronousHydrationCount, 0)

        store.applySidebarOrder(order, unpinning: unpinning)
        XCTAssertEqual(store.summary(resident.id)?.favorite, false)
        XCTAssertEqual(store.summary(evicted.id)?.favorite, false)
        store.flushSaves()

        let relaunched = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false)
        XCTAssertEqual(relaunched.summaries.map(\.id), order)
        XCTAssertTrue(relaunched.summaries.allSatisfy { !$0.favorite })
        XCTAssertEqual(relaunched.summary(resident.id)?.sortIndex, 0)
        XCTAssertEqual(relaunched.summary(evicted.id)?.sortIndex, 1)
    }

    func testLatestFavoriteDirectiveWinsWhileEvictedReorderHydrationIsPending() async throws {
        try await assertLatestFavoriteDirectiveWins(initiallyFavorite: true)
        try await assertLatestFavoriteDirectiveWins(initiallyFavorite: false)
    }

    func testSamePositionDragBackIntoPinnedWinsOverPendingEvictedUnpinIntent() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        var dragged = conversation(title: "Dragged pinned row")
        dragged.favorite = true
        dragged.sortIndex = 0
        var remainingPinned = conversation(title: "Remaining pinned row")
        remainingPinned.favorite = true
        remainingPinned.sortIndex = 1
        var ordinary = conversation(title: "Ordinary row")
        ordinary.sortIndex = 2
        try seed([dragged, remainingPinned, ordinary], at: base)

        let snapshotRows: [ConvRow] = [
            .header(.pinned),
            .conversation(dragged.id),
            .conversation(remainingPinned.id),
            .header(.today),
            .conversation(ordinary.id),
        ]
        let favoriteIDs: Set<UUID> = [dragged.id, remainingPinned.id]
        let dragOut = try XCTUnwrap(ConversationReorderIntent.droppingInSidebar(
            rows: snapshotRows,
            favoriteIDs: favoriteIDs,
            draggedIDs: [dragged.id],
            aboveTableRow: snapshotRows.endIndex))
        let dragBack = try XCTUnwrap(ConversationReorderIntent.droppingInSidebar(
            rows: snapshotRows,
            favoriteIDs: favoriteIDs,
            draggedIDs: [dragged.id],
            aboveTableRow: 1))
        XCTAssertEqual(dragOut.unpinningIDs, [dragged.id])
        XCTAssertFalse(dragBack.orderChanged)
        XCTAssertEqual(
            dragBack.pinningIDs,
            [dragged.id],
            "the stale pinned snapshot must still emit an explicit latest-state directive")

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertTrue(store.residentConversationIDs.isEmpty)

        let draggedReadStarted = expectation(description: "dragged row hydration began")
        let releaseDraggedRead = DispatchSemaphore(value: 0)
        let draggedID = dragged.id
        ConversationStore.hydrationWillReadTestHook = { id in
            guard id == draggedID else { return }
            draggedReadStarted.fulfill()
            releaseDraggedRead.wait()
        }
        defer {
            releaseDraggedRead.signal()
            ConversationStore.hydrationWillReadTestHook = nil
        }

        store.applySidebarOrder(
            dragOut.orderedIDs,
            orderChanged: dragOut.orderChanged,
            pinning: dragOut.pinningIDs,
            unpinning: dragOut.unpinningIDs)
        await fulfillment(of: [draggedReadStarted], timeout: 5)
        store.applySidebarOrder(
            dragBack.orderedIDs,
            orderChanged: dragBack.orderChanged,
            pinning: dragBack.pinningIDs,
            unpinning: dragBack.unpinningIDs)
        releaseDraggedRead.signal()

        for _ in 0..<10_000 where store.residentConversation(dragged.id) == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        ConversationStore.hydrationWillReadTestHook = nil
        XCTAssertEqual(store.summary(dragged.id)?.favorite, true)
        XCTAssertEqual(store.summary(dragged.id)?.sortIndex, 0)
        XCTAssertEqual(store.summary(remainingPinned.id)?.sortIndex, 1)
        XCTAssertEqual(store.summary(ordinary.id)?.sortIndex, 2)
        XCTAssertEqual(store.synchronousHydrationCount, 0)

        store.flushSaves()
        let relaunched = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false)
        XCTAssertEqual(relaunched.summary(dragged.id)?.favorite, true)
        XCTAssertEqual(relaunched.summaries.map(\.id), [dragged.id, remainingPinned.id, ordinary.id])
    }

    func testOrdinaryInertPinnedDropDoesNotFreezeRecencyOrderOrHydrateRows() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        var pinned = conversation(title: "Pinned without manual order")
        pinned.favorite = true
        let ordinary = conversation(title: "Ordinary without manual order")
        try seed([pinned, ordinary], at: base)

        let rows: [ConvRow] = [
            .header(.pinned),
            .conversation(pinned.id),
            .header(.today),
            .conversation(ordinary.id),
        ]
        let intent = try XCTUnwrap(ConversationReorderIntent.droppingInSidebar(
            rows: rows,
            favoriteIDs: [pinned.id],
            draggedIDs: [pinned.id],
            aboveTableRow: 1))
        XCTAssertFalse(intent.orderChanged)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        store.applySidebarOrder(
            intent.orderedIDs,
            orderChanged: intent.orderChanged,
            pinning: intent.pinningIDs,
            unpinning: intent.unpinningIDs)

        XCTAssertTrue(store.residentConversationIDs.isEmpty)
        XCTAssertNil(store.summary(pinned.id)?.sortIndex)
        XCTAssertNil(store.summary(ordinary.id)?.sortIndex)
        XCTAssertEqual(store.synchronousHydrationCount, 0)
        store.flushSaves()

        let relaunched = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false)
        XCTAssertNil(relaunched.summary(pinned.id)?.sortIndex)
        XCTAssertNil(relaunched.summary(ordinary.id)?.sortIndex)
    }

    func testPendingReorderInAnotherSidebarDoesNotActivateAnInertDrop() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        var pending = conversation(title: "Pending in workspace A")
        pending.favorite = true
        pending.sortIndex = 0
        var inert = conversation(title: "Inert in workspace B")
        inert.favorite = true
        try seed([pending, inert], at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)

        let readStarted = expectation(description: "workspace A reorder began hydration")
        let releaseRead = DispatchSemaphore(value: 0)
        let pendingID = pending.id
        ConversationStore.hydrationWillReadTestHook = { id in
            guard id == pendingID else { return }
            readStarted.fulfill()
            releaseRead.wait()
        }
        defer {
            releaseRead.signal()
            ConversationStore.hydrationWillReadTestHook = nil
        }

        store.applySidebarOrder(
            [pending.id],
            orderChanged: true,
            unpinning: [pending.id])
        await fulfillment(of: [readStarted], timeout: 5)
        store.applySidebarOrder(
            [inert.id],
            orderChanged: false,
            pinning: [inert.id])

        XCTAssertNil(store.residentConversation(inert.id))
        XCTAssertNil(store.summary(inert.id)?.sortIndex)
        XCTAssertNil(store.hydrationDecodeCounts[inert.id])
        releaseRead.signal()
        for _ in 0..<10_000 where store.residentConversation(pending.id) == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        ConversationStore.hydrationWillReadTestHook = nil
        XCTAssertEqual(store.summary(pending.id)?.favorite, false)
        XCTAssertEqual(store.synchronousHydrationCount, 0)
    }

    private func assertLatestFavoriteDirectiveWins(initiallyFavorite: Bool) async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        var seeded = conversation(title: initiallyFavorite ? "Initially pinned" : "Initially plain")
        seeded.favorite = initiallyFavorite
        seeded.sortIndex = 0
        try seed([seeded], at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertNil(store.residentConversation(seeded.id))

        let readStarted = expectation(description: "opposite favorite mutation began hydration")
        let releaseRead = DispatchSemaphore(value: 0)
        ConversationStore.hydrationWillReadTestHook = { id in
            guard id == seeded.id else { return }
            readStarted.fulfill()
            releaseRead.wait()
        }
        defer {
            releaseRead.signal()
            ConversationStore.hydrationWillReadTestHook = nil
        }

        func applyFavorite(_ favorite: Bool) {
            store.applySidebarOrder(
                [seeded.id],
                pinning: favorite ? [seeded.id] : [],
                unpinning: favorite ? [] : [seeded.id])
        }

        applyFavorite(!initiallyFavorite)
        await fulfillment(of: [readStarted], timeout: 5)
        applyFavorite(initiallyFavorite)
        releaseRead.signal()

        for _ in 0..<10_000 where store.residentConversation(seeded.id) == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        ConversationStore.hydrationWillReadTestHook = nil
        XCTAssertEqual(store.summary(seeded.id)?.favorite, initiallyFavorite)
        XCTAssertEqual(store.summary(seeded.id)?.sortIndex, 0)
        XCTAssertEqual(store.hydrationDecodeCounts[seeded.id], 1)
        XCTAssertEqual(store.synchronousHydrationCount, 0)

        store.flushSaves()
        let relaunched = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false)
        XCTAssertEqual(relaunched.summary(seeded.id)?.favorite, initiallyFavorite)
        XCTAssertEqual(relaunched.summary(seeded.id)?.sortIndex, 0)
    }

    func testBatchAcquisitionPinsEveryMemberAcrossForcedTrimUntilCallbackReturns() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let seeded = (0..<3).map { conversation(title: "Leased \($0)") }
        try seed(seeded, at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertTrue(store.residentConversationIDs.isEmpty)

        let ids = Set(seeded.map(\.id))
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<
                Result<Void, ConversationHydrationError>, Never>) in
            store.withAcquiredConversations(ids) { result in
                store.trimResidencyIfNeeded(evictAllEligible: true)
                XCTAssertEqual(
                    store.residentConversationIDs,
                    ids,
                    "an early batch member must stay resident while the operation owns its claim")
                continuation.resume(returning: result)
            }
        }

        _ = try result.get()
        XCTAssertEqual(store.synchronousHydrationCount, 0)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertTrue(
            store.residentConversationIDs.isEmpty,
            "returning from the scoped callback must release every temporary residency claim")
    }

    func testFailedBatchAcquisitionReleasesClaimsWithoutInventingARecord() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let seeded = [
            conversation(title: "Loads first"),
            conversation(title: "Disappears second"),
        ].sorted { $0.id.uuidString < $1.id.uuidString }
        try seed(seeded, at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)

        let missing = try XCTUnwrap(seeded.last)
        let sidecar = base.appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(missing.id.uuidString).json")
        try FileManager.default.removeItem(at: sidecar)

        let ids = Set(seeded.map(\.id))
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<
                Result<Void, ConversationHydrationError>, Never>) in
            store.withAcquiredConversations(ids) { continuation.resume(returning: $0) }
        }

        XCTAssertEqual(result.failure, .missing)
        XCTAssertTrue(store.contains(missing.id), "a missing binding remains visible for repair")
        XCTAssertNil(store.residentConversation(missing.id))
        XCTAssertEqual(store.synchronousHydrationCount, 0)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertTrue(
            store.residentConversationIDs.isEmpty,
            "a failed batch must release the claim on members hydrated before the failure")
    }

    func testOverlappingBatchAcquisitionsCoalesceAndReleaseReferenceCountedClaims() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let seeded = (0..<2).map { conversation(title: "Shared lease \($0)") }
        try seed(seeded, at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)

        let ids = Set(seeded.map(\.id))
        let results = await withCheckedContinuation {
            (continuation: CheckedContinuation<
                [Result<Void, ConversationHydrationError>], Never>) in
            var received: [Result<Void, ConversationHydrationError>] = []
            let receive: @MainActor (
                Result<Void, ConversationHydrationError>
            ) -> Void = { result in
                store.trimResidencyIfNeeded(evictAllEligible: true)
                XCTAssertEqual(
                    store.residentConversationIDs,
                    ids,
                    "one callback returning must not release another overlapping batch's claim")
                received.append(result)
                if received.count == 2 { continuation.resume(returning: received) }
            }
            store.withAcquiredConversations(ids, completion: receive)
            store.withAcquiredConversations(ids, completion: receive)
        }

        XCTAssertEqual(results.count, 2)
        for result in results {
            _ = try result.get()
        }
        for id in ids {
            XCTAssertEqual(
                store.hydrationDecodeCounts[id],
                1,
                "overlapping batches must share the store's one in-flight decode per id")
        }
        XCTAssertEqual(store.synchronousHydrationCount, 0)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertTrue(
            store.residentConversationIDs.isEmpty,
            "the final overlapping callback must release the last reference-counted claim")
    }

    func testEvictedConversationExportIsExactCoalescedAndNeverHydratesSynchronously() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let seeded = conversation(title: "Export after eviction")
        try seed([seeded], at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertNil(store.residentConversation(seeded.id))

        typealias ExportResult = Result<
            ConversationMarkdownDocument,
            ConversationHydrationError
        >
        var completedSynchronously = false
        let results = await withCheckedContinuation {
            (continuation: CheckedContinuation<[ExportResult], Never>) in
            var received: [ExportResult] = []
            let receive: @MainActor (ExportResult) -> Void = { result in
                received.append(result)
                if received.count == 2 { continuation.resume(returning: received) }
            }
            ConversationMarkdownExport.document(for: seeded.id, in: store) {
                completedSynchronously = true
                receive($0)
            }
            ConversationMarkdownExport.document(
                for: seeded.id,
                in: store,
                completion: receive)
            XCTAssertFalse(
                completedSynchronously,
                "Exporting an evicted record must not decode it on the main actor.")
        }

        let expected = ConversationMarkdownDocument(conversation: seeded)
        XCTAssertEqual(results.count, 2)
        for result in results {
            XCTAssertEqual(try result.get(), expected)
        }
        XCTAssertEqual(store.hydrationDecodeCounts[seeded.id], 1)
        XCTAssertEqual(store.synchronousHydrationCount, 0)

        let url = try ConversationMarkdownExport.temporaryFile(
            for: expected,
            conversationID: seeded.id)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(url.lastPathComponent, expected.filename)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expected.contents)
    }

    func testMissingEvictedConversationExportReportsFailureAndCreatesNoOutput() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let seeded = conversation(title: "Missing export binding")
        try seed([seeded], at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)

        let sidecar = base.appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(seeded.id.uuidString).json")
        try FileManager.default.removeItem(at: sidecar)
        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mechanician Conversation Exports", isDirectory: true)
            .appendingPathComponent(seeded.id.uuidString, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportDirectory.path))

        let result = await exportDocument(seeded.id, from: store)

        XCTAssertEqual(result.failure, .missing)
        XCTAssertTrue(
            result.failure?.localizedDescription.contains("missing") == true,
            "The UI alert must explain why no export was created.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportDirectory.path))
        XCTAssertEqual(store.synchronousHydrationCount, 0)
        XCTAssertNotNil(store.summary(seeded.id), "The missing binding remains repairable.")
    }

    func testMissingEvictedSidecarStaysVisibleAndDoesNotCreateAnEmptyRecord() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let seeded = conversation(title: "Externally removed")
        try seed([seeded], at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertNil(store.residentConversation(seeded.id))

        let sidecar = base.appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(seeded.id.uuidString).json")
        try FileManager.default.removeItem(at: sidecar)

        let result = await acquire(seeded.id, from: store)

        XCTAssertEqual(result.failure, .missing)
        XCTAssertNotNil(store.summary(seeded.id), "A missing binding must remain repairable.")
        XCTAssertTrue(store.contains(seeded.id))
        XCTAssertNil(store.residentConversation(seeded.id))
        XCTAssertNil(store.hydrationDecodeCounts[seeded.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertNotNil(store.hydrationError)
    }

    func testQueueWaitAndPendingPromptRecordsAreNeverEvicted() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let queue = conversation(title: "Queued", queuedPrompts: ["continue"])
        let wait = conversation(
            title: "Waiting",
            armedTrigger: ArmedTrigger(
                note: "waiting for a result",
                check: nil,
                deadline: Date(timeIntervalSinceNow: 3_600),
                armedAt: Date(),
                expiresAt: Date(timeIntervalSinceNow: 7_200)))
        let clean = conversation(title: "Clean control")
        try seed([queue, wait, clean], at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)

        var pending = conversation(title: "Accepted prompt")
        pending.pendingTurnPrompt = "send this exactly once"
        store.upsert(pending)
        store.flushSaves()

        let expectedProtectedBytes = try [queue, wait, pending].reduce(into: 0) {
            $0 += try ConversationStore.makeEncoder().encode($1).count
        }
        // `finishSave` returns to the main actor and records the new file's byte count. Keep
        // exercising the trim until that exact persisted accounting lands; otherwise the pending
        // prompt might appear protected only because a save was still in flight.
        for _ in 0..<100 where store.residentSourceBytes != expectedProtectedBytes {
            store.trimResidencyIfNeeded(evictAllEligible: true)
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        store.trimResidencyIfNeeded(evictAllEligible: true)

        XCTAssertEqual(store.residentSourceBytes, expectedProtectedBytes)
        XCTAssertFalse(store.residentConversationIDs.contains(clean.id))
        XCTAssertTrue(store.residentConversationIDs.contains(queue.id))
        XCTAssertTrue(store.residentConversationIDs.contains(wait.id))
        XCTAssertTrue(store.residentConversationIDs.contains(pending.id))
        XCTAssertEqual(
            store.residentConversation(pending.id)?.pendingTurnPrompt,
            "send this exactly once")
    }

    func testDeletingAnEvictedRecordProducesAnExactUndoReceipt() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        var seeded = conversation(title: "Undo after hydration")
        seeded.draft = "unsent exact draft"
        try seed([seeded], at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertNil(store.residentConversation(seeded.id))
        XCTAssertTrue(store.contains(seeded.id))

        let removed = await remove(seeded.id, from: store)
        let receipt = try XCTUnwrap(removed)
        store.flushSaves()
        XCTAssertFalse(store.contains(seeded.id))
        XCTAssertEqual(receipt.conversation.id, seeded.id)
        XCTAssertEqual(receipt.conversation.messages.map(\.id), seeded.messages.map(\.id))
        XCTAssertEqual(receipt.conversation.messages.map(\.kind), seeded.messages.map(\.kind))
        XCTAssertEqual(receipt.conversation.messages.map(\.text), seeded.messages.map(\.text))
        XCTAssertEqual(receipt.conversation.draft, "unsent exact draft")
        XCTAssertEqual(store.synchronousHydrationCount, 0)

        XCTAssertTrue(store.restore(receipt))
        store.flushSaves()
        XCTAssertTrue(store.contains(seeded.id))
        XCTAssertEqual(
            store.residentConversation(seeded.id)?.messages.map(\.id), seeded.messages.map(\.id))
        XCTAssertEqual(
            store.residentConversation(seeded.id)?.messages.map(\.kind),
            seeded.messages.map(\.kind))
        XCTAssertEqual(
            store.residentConversation(seeded.id)?.messages.map(\.text),
            seeded.messages.map(\.text))
        XCTAssertEqual(store.residentConversation(seeded.id)?.draft, "unsent exact draft")
    }

    func testLateAsyncHydrationCannotOverwriteNewerSynchronousMutation() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let seeded = conversation(title: "Disk title")
        try seed([seeded], at: base)
        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)

        let waiterResult = await withCheckedContinuation {
            (continuation: CheckedContinuation<
                Result<Conversation, ConversationHydrationError>, Never>) in
            store.acquireConversation(seeded.id) { continuation.resume(returning: $0) }
            // The hydration queue decodes the async request first, but its MainActor completion is
            // held until this synchronous compatibility load and newer mutation finish.
            XCTAssertNotNil(store.hydrateImmediately(seeded.id))
            store.update(seeded.id) { $0.title = "Newer in-memory title" }
        }

        XCTAssertEqual(try waiterResult.get().title, "Newer in-memory title")
        XCTAssertEqual(store.residentConversation(seeded.id)?.title, "Newer in-memory title")
    }

    func testRemovalCompletesAnInFlightHydrationWaiterAsDeleted() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let seeded = conversation(title: "Delete during acquire")
        try seed([seeded], at: base)
        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)

        let waiterResult = await withCheckedContinuation {
            (continuation: CheckedContinuation<
                Result<Conversation, ConversationHydrationError>, Never>) in
            store.acquireConversation(seeded.id) { continuation.resume(returning: $0) }
            XCTAssertNotNil(store.remove(seeded.id))
        }

        XCTAssertEqual(waiterResult.failure, .deleted)
        XCTAssertFalse(store.hasConversation(seeded.id))
    }

    func testLateProjectedOrphanCannotReenterAuthoritativeInventory() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let orphan = conversation(title: "Projection-only ghost")
        var projection: ConversationProjectionStore? = ConversationProjectionStore(
            appSupportBase: base)
        projection?.index(orphan)
        for _ in 0..<100 {
            if await projectedSummaries(try XCTUnwrap(projection)).contains(where: {
                $0.id == orphan.id
            }) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let seededProjectionRows = await projectedSummaries(try XCTUnwrap(projection))
        XCTAssertTrue(seededProjectionRows.contains(where: { $0.id == orphan.id }))
        projection = nil

        let live = conversation(title: "Authoritative sidecar")
        try seed([live], at: base)
        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            loadsAsynchronously: true,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)

        XCTAssertEqual(store.conversationIDs, Set([live.id]))
        XCTAssertNil(store.summary(orphan.id))
    }
}

private extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
