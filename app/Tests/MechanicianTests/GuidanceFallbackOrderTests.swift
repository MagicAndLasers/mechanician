import Foundation
import XCTest
@testable import Mechanician

/// Regression: several steers that fall back to the queue at turn-end used to reverse and shuffle,
/// because `fallbackPendingGuidance` iterated a dictionary (arbitrary order) and each one inserted
/// at the queue head. The fix stamps a typed-order sequence, sorts the batch by it, and appends.
@MainActor
final class GuidanceFallbackOrderTests: XCTestCase {
    func testFallenBackSteersKeepTypedOrderRegardlessOfDictionaryOrder() {
        // A dictionary yields arbitrary order; simulate three steers typed in order 1,2,3 surfacing
        // scrambled, then confirm they re-enter the queue in typed order.
        let scrambled = [(key: "steer-B", sequence: 2),
                         (key: "steer-C", sequence: 3),
                         (key: "steer-A", sequence: 1)]
        XCTAssertEqual(
            AgentBridge.orderedFallbackSteerIDs(scrambled),
            ["steer-A", "steer-B", "steer-C"])
    }

    func testOrderedFallbackIsStableAndEmptySafe() {
        XCTAssertEqual(AgentBridge.orderedFallbackSteerIDs([]), [])
        XCTAssertEqual(
            AgentBridge.orderedFallbackSteerIDs([(key: "only", sequence: 7)]), ["only"])
    }

    func testSteerBuffersDuringStartingAndQueuesOnlyWhenNoSteerableTurn() {
        // Active turn → steer now.
        XCTAssertEqual(
            AgentBridge.steerDisposition(canSteerNow: true, turnStartingSteerable: false), .sendNow)
        // Turn still starting under a steer-capable provider → hold it, don't queue.
        XCTAssertEqual(
            AgentBridge.steerDisposition(canSteerNow: false, turnStartingSteerable: true),
            .bufferUntilActive)
        // No steerable turn coming → it's a next-message.
        XCTAssertEqual(
            AgentBridge.steerDisposition(canSteerNow: false, turnStartingSteerable: false),
            .queueAsNext)
        // Active always wins over the starting hint.
        XCTAssertEqual(
            AgentBridge.steerDisposition(canSteerNow: true, turnStartingSteerable: true), .sendNow)
    }

    func testComposerDefaultsToSteerWheneverGuidanceApplies() {
        // canGuide here is fed bridge.guidanceIsDefaultForCurrentTurn, which is true across the whole
        // in-flight window (starting + active) for a steer-capable provider.
        let steerable = ComposerDeliveryPolicy(
            hasText: true, runtimeReady: true, turnReserved: true, canGuide: true)
        XCTAssertEqual(steerable.defaultAction, .guideCurrentTurn)
        XCTAssertEqual(steerable.resolvedAction(selecting: nil), .guideCurrentTurn)
        XCTAssertEqual(steerable.resolvedAction(selecting: .guideCurrentTurn), .guideCurrentTurn)

        // Only when guidance genuinely doesn't apply does the default become Send next.
        let notSteerable = ComposerDeliveryPolicy(
            hasText: true, runtimeReady: true, turnReserved: true, canGuide: false)
        XCTAssertEqual(notSteerable.defaultAction, .sendNext)

        // No turn in flight → a fresh turn, never the queue.
        let idle = ComposerDeliveryPolicy(
            hasText: true, runtimeReady: true, turnReserved: false, canGuide: false)
        XCTAssertEqual(idle.defaultAction, .startTurn)
    }

    func testQueuedGuidanceRowsCorrelateInTypedOrder() {
        // Fallbacks now append in typed order, matching the transcript, so each queued prompt maps
        // to its own transcript guidance row oldest-first.
        var messages = [TranscriptEntry(kind: .user, text: "one"),
                        TranscriptEntry(kind: .user, text: "two"),
                        TranscriptEntry(kind: .user, text: "three")]
        for i in messages.indices { messages[i].guidanceState = .queued }
        XCTAssertEqual(
            AgentBridge.queuedGuidanceEntryIDs(
                prompts: ["one", "two", "three"], messages: messages),
            [messages[0].id, messages[1].id, messages[2].id])
    }

    func testQueuedPromptRedirectExtractsExactRowAndPreservesRemainingOrder() {
        var messages = [
            TranscriptEntry(kind: .user, text: "first"),
            TranscriptEntry(kind: .user, text: "redirect"),
            TranscriptEntry(kind: .user, text: "last"),
        ]
        for index in messages.indices { messages[index].guidanceState = .queued }
        var prompts = ["first", "redirect", "last"]
        let renderedQueue = prompts
        let removedEntryID = messages[1].id

        XCTAssertEqual(
            AgentBridge.takeQueuedPromptForRedirect(
                at: 1,
                expectedQueue: renderedQueue,
                prompts: &prompts,
                messages: &messages),
            "redirect")
        XCTAssertEqual(prompts, ["first", "last"])
        XCTAssertFalse(messages.contains { $0.id == removedEntryID })
        XCTAssertEqual(messages.map(\.text), ["first", "last"])

        XCTAssertNil(
            AgentBridge.takeQueuedPromptForRedirect(
                at: 1,
                expectedQueue: renderedQueue,
                prompts: &prompts,
                messages: &messages),
            "a stale repeated action must not redirect the row that shifted into this index")
        XCTAssertEqual(prompts, ["first", "last"])
    }

    func testQueuedPromptRedirectRejectsTurnEndRaceWithoutMutatingQueue() {
        var messages: [TranscriptEntry] = []
        var prompts = ["already drained", "still queued"]
        let staleRenderedQueue = ["redirect me", "already drained", "still queued"]

        XCTAssertNil(
            AgentBridge.takeQueuedPromptForRedirect(
                at: 0,
                expectedQueue: staleRenderedQueue,
                prompts: &prompts,
                messages: &messages))
        XCTAssertEqual(prompts, ["already drained", "still queued"])
        XCTAssertTrue(messages.isEmpty)
    }

    func testBufferedStartGuidanceExtractionIsScopedOrderedAndIdempotent() {
        let current = UUID()
        let other = UUID()
        var first = TranscriptEntry(kind: .user, text: "first")
        first.guidanceState = .sending
        var redirect = TranscriptEntry(kind: .user, text: "redirect")
        redirect.guidanceState = .sending
        var unrelated = TranscriptEntry(kind: .user, text: "unrelated")
        unrelated.guidanceState = .sending
        var pending = [
            current: [first, redirect],
            other: [unrelated],
        ]

        XCTAssertNil(AgentBridge.takeBufferedStartGuidance(
            unrelated.id,
            conversationID: current,
            from: &pending))
        XCTAssertEqual(pending[other]?.map(\.id), [unrelated.id])

        XCTAssertEqual(AgentBridge.takeBufferedStartGuidance(
            redirect.id,
            conversationID: current,
            from: &pending)?.text, "redirect")
        XCTAssertEqual(pending[current]?.map(\.id), [first.id])
        XCTAssertNil(AgentBridge.takeBufferedStartGuidance(
            redirect.id,
            conversationID: current,
            from: &pending))
    }

    func testUnacknowledgedRedirectIsNotAutomaticallyResentToSameProviderLane() {
        let stalledGeneration = UUID()
        let replacementGeneration = UUID()
        let redirect = "Use the corrected direction"

        XCTAssertTrue(AgentBridge.blocksAutomaticRecoveredPromptRetry(
            recoveredPrompt: redirect,
            queueHead: redirect,
            timedOutAccess: .codexSubscription,
            currentAccess: .codexSubscription,
            timedOutGeneration: stalledGeneration,
            currentGeneration: stalledGeneration))
        XCTAssertFalse(AgentBridge.blocksAutomaticRecoveredPromptRetry(
            recoveredPrompt: redirect,
            queueHead: redirect,
            timedOutAccess: .codexSubscription,
            currentAccess: .codexSubscription,
            timedOutGeneration: stalledGeneration,
            currentGeneration: replacementGeneration))
        XCTAssertFalse(AgentBridge.blocksAutomaticRecoveredPromptRetry(
            recoveredPrompt: redirect,
            queueHead: "An unrelated queued prompt",
            timedOutAccess: .codexSubscription,
            currentAccess: .codexSubscription,
            timedOutGeneration: stalledGeneration,
            currentGeneration: stalledGeneration))
        XCTAssertFalse(AgentBridge.blocksAutomaticRecoveredPromptRetry(
            recoveredPrompt: redirect,
            queueHead: redirect,
            timedOutAccess: .codexSubscription,
            currentAccess: .claudeSubscription,
            timedOutGeneration: stalledGeneration,
            currentGeneration: stalledGeneration))

        // The live failure was: interrupt root, send redirect, timeout-interrupt redirect, then
        // auto-send the same redirect repeatedly. The barrier leaves exactly the initial redirect
        // send on this provider generation; timeout recovery only restores the queue row.
        var sameLaneWire = ["interrupt:root", "send:\(redirect)", "interrupt:redirect"]
        if !AgentBridge.blocksAutomaticRecoveredPromptRetry(
            recoveredPrompt: redirect,
            queueHead: redirect,
            timedOutAccess: .codexSubscription,
            currentAccess: .codexSubscription,
            timedOutGeneration: stalledGeneration,
            currentGeneration: stalledGeneration) {
            sameLaneWire.append("send:\(redirect)")
        }
        XCTAssertEqual(
            sameLaneWire.filter { $0 == "send:\(redirect)" }.count,
            1,
            "timeout recovery must not write the redirect again to the unchanged lane")
        XCTAssertEqual(
            sameLaneWire.filter { $0.hasPrefix("interrupt:") },
            ["interrupt:root", "interrupt:redirect"])
    }

}
