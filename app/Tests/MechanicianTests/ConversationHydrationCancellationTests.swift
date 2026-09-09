import Foundation
import XCTest
@testable import Mechanician

private final class ConversationHydrationHookProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var willReadCounts: [UUID: Int] = [:]
    private var didReadCounts: [UUID: Int] = [:]

    func recordWillRead(_ id: UUID) -> Int {
        lock.lock(); defer { lock.unlock() }
        willReadCounts[id, default: 0] += 1
        return willReadCounts[id] ?? 0
    }

    func recordDidRead(_ id: UUID) -> Int {
        lock.lock(); defer { lock.unlock() }
        didReadCounts[id, default: 0] += 1
        return didReadCounts[id] ?? 0
    }

    func willReadCount(_ id: UUID) -> Int {
        lock.lock(); defer { lock.unlock() }
        return willReadCounts[id] ?? 0
    }

    func didReadCount(_ id: UUID) -> Int {
        lock.lock(); defer { lock.unlock() }
        return didReadCounts[id] ?? 0
    }
}

@MainActor
final class ConversationHydrationCancellationTests: XCTestCase {
    override func tearDown() {
        ConversationStore.hydrationWillReadTestHook = nil
        ConversationStore.hydrationDidReadTestHook = nil
        super.tearDown()
    }

    func testCancelingOneCoalescedWaiterPreservesTheSharedHydration() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        let firstReadStarted = expectation(description: "shared hydration reached read boundary")
        let releaseRead = DispatchSemaphore(value: 0)
        let probe = ConversationHydrationHookProbe()
        ConversationStore.hydrationWillReadTestHook = { id in
            guard id == fixture.conversation.id else { return }
            if probe.recordWillRead(id) == 1 {
                firstReadStarted.fulfill()
                releaseRead.wait()
            }
        }
        ConversationStore.hydrationDidReadTestHook = { id in
            guard id == fixture.conversation.id else { return }
            _ = probe.recordDidRead(id)
        }
        defer { releaseRead.signal() }

        var canceledCallbackCount = 0
        let canceledRequest = try XCTUnwrap(fixture.store.acquireConversation(
            fixture.conversation.id
        ) { _ in
            canceledCallbackCount += 1
        })
        await fulfillment(of: [firstReadStarted], timeout: 5)

        let survivingFinished = expectation(description: "surviving waiter completed")
        var survivingResult: Result<Conversation, ConversationHydrationError>?
        let survivingRequest = fixture.store.acquireConversation(fixture.conversation.id) { result in
            survivingResult = result
            survivingFinished.fulfill()
        }
        XCTAssertNotNil(survivingRequest)

        fixture.store.cancelConversationAcquisition(canceledRequest)
        releaseRead.signal()
        await fulfillment(of: [survivingFinished], timeout: 5)

        XCTAssertEqual(try survivingResult?.get().id, fixture.conversation.id)
        XCTAssertEqual(canceledCallbackCount, 0)
        XCTAssertEqual(probe.willReadCount(fixture.conversation.id), 1)
        XCTAssertEqual(probe.didReadCount(fixture.conversation.id), 1)
        XCTAssertEqual(fixture.store.hydrationDecodeCounts[fixture.conversation.id], 1)
    }

    func testCancelingTheLastWaiterSkipsItsReadAndLetsAReplacementJobFinish() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        let canceledJobReachedBoundary = expectation(
            description: "canceled job reached pre-read boundary")
        let releaseCanceledJob = DispatchSemaphore(value: 0)
        let probe = ConversationHydrationHookProbe()
        ConversationStore.hydrationWillReadTestHook = { id in
            guard id == fixture.conversation.id else { return }
            if probe.recordWillRead(id) == 1 {
                canceledJobReachedBoundary.fulfill()
                releaseCanceledJob.wait()
            }
        }
        ConversationStore.hydrationDidReadTestHook = { id in
            guard id == fixture.conversation.id else { return }
            _ = probe.recordDidRead(id)
        }
        defer { releaseCanceledJob.signal() }

        var canceledCallbackCount = 0
        let canceledRequest = try XCTUnwrap(fixture.store.acquireConversation(
            fixture.conversation.id
        ) { _ in
            canceledCallbackCount += 1
        })
        await fulfillment(of: [canceledJobReachedBoundary], timeout: 5)

        fixture.store.cancelConversationAcquisition(canceledRequest)
        let replacementFinished = expectation(description: "replacement hydration completed")
        var replacementResult: Result<Conversation, ConversationHydrationError>?
        let replacementRequest = fixture.store.acquireConversation(fixture.conversation.id) { result in
            replacementResult = result
            replacementFinished.fulfill()
        }
        XCTAssertNotNil(replacementRequest)
        releaseCanceledJob.signal()
        await fulfillment(of: [replacementFinished], timeout: 5)

        XCTAssertEqual(try replacementResult?.get().messages.map(\.text), ["durable transcript"])
        XCTAssertEqual(canceledCallbackCount, 0)
        XCTAssertEqual(
            probe.willReadCount(fixture.conversation.id),
            2,
            "The canceled job reaches the hook but must exit before reading; the replacement reads.")
        XCTAssertEqual(probe.didReadCount(fixture.conversation.id), 1)
        XCTAssertEqual(fixture.store.hydrationDecodeCounts[fixture.conversation.id], 1)
    }

    func testCanceledReadCannotPublishOverAReplacementJobForTheSameConversation() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        let canceledJobFinishedReading = expectation(
            description: "canceled job reached post-read boundary")
        let releaseCanceledJob = DispatchSemaphore(value: 0)
        let probe = ConversationHydrationHookProbe()
        ConversationStore.hydrationWillReadTestHook = { id in
            guard id == fixture.conversation.id else { return }
            _ = probe.recordWillRead(id)
        }
        ConversationStore.hydrationDidReadTestHook = { id in
            guard id == fixture.conversation.id else { return }
            if probe.recordDidRead(id) == 1 {
                canceledJobFinishedReading.fulfill()
                releaseCanceledJob.wait()
            }
        }
        defer { releaseCanceledJob.signal() }

        var canceledCallbackCount = 0
        let canceledRequest = try XCTUnwrap(fixture.store.acquireConversation(
            fixture.conversation.id
        ) { _ in
            canceledCallbackCount += 1
        })
        await fulfillment(of: [canceledJobFinishedReading], timeout: 5)

        fixture.store.cancelConversationAcquisition(canceledRequest)
        let replacementFinished = expectation(description: "replacement hydration completed")
        var replacementResult: Result<Conversation, ConversationHydrationError>?
        let replacementRequest = fixture.store.acquireConversation(fixture.conversation.id) { result in
            replacementResult = result
            replacementFinished.fulfill()
        }
        XCTAssertNotNil(replacementRequest)
        releaseCanceledJob.signal()
        await fulfillment(of: [replacementFinished], timeout: 5)

        XCTAssertEqual(try replacementResult?.get().id, fixture.conversation.id)
        XCTAssertEqual(canceledCallbackCount, 0)
        XCTAssertEqual(probe.willReadCount(fixture.conversation.id), 2)
        XCTAssertEqual(probe.didReadCount(fixture.conversation.id), 2)
        XCTAssertEqual(
            fixture.store.hydrationDecodeCounts[fixture.conversation.id],
            1,
            "Only the replacement job may publish and increment the completed-decode metric.")
    }

    private struct Fixture {
        let base: URL
        let store: ConversationStore
        let conversation: Conversation
    }

    private func makeFixture() async throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Mechanician-hydration-cancellation-\(UUID().uuidString)",
            isDirectory: true)
        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let conversation = Conversation(
            title: "Cancellable hydration",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "durable transcript")],
            updatedAt: Date())
        try ConversationStore.makeEncoder().encode(conversation).write(
            to: directory.appendingPathComponent("\(conversation.id.uuidString).json"))

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await withCheckedContinuation { continuation in
            store.whenReady { continuation.resume() }
        }
        for _ in 0..<10_000 {
            if store.activeResidencyMode == .boundedAfterRecovery { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(store.activeResidencyMode, .boundedAfterRecovery)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertNil(store.residentConversation(conversation.id))
        return Fixture(base: base, store: store, conversation: conversation)
    }
}
