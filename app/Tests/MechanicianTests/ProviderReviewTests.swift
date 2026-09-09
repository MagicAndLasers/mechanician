import XCTest
@testable import Mechanician

@MainActor
final class ProviderReviewTests: XCTestCase {
    private func capability(
        availability: ProviderCapabilityAvailability = .available,
        support: MechanicianCapabilitySupport = .implemented,
        operation: String? = "review/start"
    ) -> ProviderCapability {
        ProviderCapability(
            id: "native_review",
            providerAvailability: availability,
            mechanicianSupport: support,
            symmetry: .providerSpecific,
            operation: operation,
            constraints: ["targets": "uncommittedChanges"],
            disclosures: [:],
            evidence: ProviderCapabilityEvidence(
                source: .providerContract,
                operation: "review/start",
                revision: "fixture"))
    }

    private func snapshot(
        phase: ProviderCapabilitySnapshot.Phase = .ready,
        capabilities: [ProviderCapability]
    ) -> ProviderCapabilitySnapshot {
        ProviderCapabilitySnapshot(
            phase: phase,
            capabilities: capabilities,
            adapterRevision: "fixture",
            sourceRevision: nil,
            rawEvidenceDigest: nil,
            updatedAt: Date())
    }

    func testNativeReviewRequiresExactAvailableImplementedOperation() {
        XCTAssertTrue(AgentBridge.supportsNativeCodexReview(snapshot(capabilities: [capability()])))
        XCTAssertFalse(AgentBridge.supportsNativeCodexReview(snapshot(
            phase: .loading, capabilities: [capability()])))
        XCTAssertFalse(AgentBridge.supportsNativeCodexReview(snapshot(capabilities: [
            capability(availability: .unknown),
        ])))
        XCTAssertFalse(AgentBridge.supportsNativeCodexReview(snapshot(capabilities: [
            capability(support: .unimplemented),
        ])))
        XCTAssertFalse(AgentBridge.supportsNativeCodexReview(snapshot(capabilities: [
            capability(operation: "turn/start"),
        ])))
        XCTAssertEqual(
            AgentBridge.restoredRunningStatusLabel(isReview: true),
            "Reviewing changes…")
        XCTAssertEqual(
            AgentBridge.restoredRunningStatusLabel(isReview: false),
            "Thinking…")
    }

    func testReviewLifecycleUpdatesOneDistinctTranscriptRow() throws {
        let startedAt = Date(timeIntervalSince1970: 100)
        let completedAt = Date(timeIntervalSince1970: 200)
        var messages: [TranscriptEntry] = []

        XCTAssertTrue(AgentBridge.applyProviderReviewEvent([
            "type": "review_started",
            "reviewId": "review-1",
            "target": "uncommittedChanges",
        ], to: &messages, now: startedAt))
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].kind, .review)
        XCTAssertEqual(messages[0].review?.status, .running)
        XCTAssertEqual(messages[0].review?.title, "Codex Review · Uncommitted Changes")

        XCTAssertTrue(AgentBridge.applyProviderReviewEvent([
            "type": "review_result",
            "reviewId": "review-1",
            "target": "uncommittedChanges",
            "text": "- [P1] Fix the race — Sources/Feature.swift:42",
        ], to: &messages, now: completedAt))
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].review?.status, .completed)
        XCTAssertEqual(messages[0].review?.endedAt, completedAt)
        XCTAssertTrue(messages[0].text.contains("Sources/Feature.swift:42"))
        XCTAssertTrue(AgentBridge.transcriptMarkdown(messages).contains("Codex Review"))
    }

    func testTerminalFallbackCannotOverwriteCompletedReview() {
        var messages: [TranscriptEntry] = []
        _ = AgentBridge.applyProviderReviewEvent([
            "type": "review_started", "reviewId": "review-1",
        ], to: &messages)
        _ = AgentBridge.applyProviderReviewEvent([
            "type": "review_result", "reviewId": "review-1", "text": "No findings.",
        ], to: &messages)

        XCTAssertFalse(AgentBridge.finishRunningProviderReview(
            in: &messages, status: .failed, message: "fallback"))
        XCTAssertEqual(messages[0].review?.status, .completed)
        XCTAssertEqual(messages[0].text, "No findings.")

        XCTAssertTrue(AgentBridge.applyProviderReviewEvent([
            "type": "review_started", "reviewId": "review-1",
        ], to: &messages))
        XCTAssertEqual(messages[0].review?.status, .completed)
        XCTAssertEqual(messages[0].text, "No findings.")
    }

    func testRelaunchStopsAnUnownedRunningReview() throws {
        var row = TranscriptEntry(kind: .review)
        row.review = ProviderReview(
            provider: .codexSubscription,
            providerReviewID: "review-live",
            target: .uncommittedChanges,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 100))
        let conversation = Conversation(
            title: "Review",
            cwd: "/tmp/repo",
            sdkSessionId: "codex-tools:thread-1",
            modelSelection: ModelSelection(
                access: .codexSubscription, modelID: "gpt-fixture"),
            messages: [row],
            updatedAt: Date(timeIntervalSince1970: 100))

        let decoded = try JSONDecoder().decode(
            Conversation.self,
            from: JSONEncoder().encode(conversation))
        XCTAssertEqual(decoded.messages.first?.review?.status, .stopped)
        XCTAssertEqual(decoded.messages.first?.review?.endedAt, conversation.updatedAt)
        XCTAssertEqual(
            decoded.messages.first?.text,
            "Review stopped before Codex returned findings.")
        XCTAssertTrue(decoded.hasDurableContent)
    }

    func testReviewAndDraftAreDurableConversationContent() {
        var review = TranscriptEntry(kind: .review, text: "One finding")
        review.review = ProviderReview(
            provider: .codexSubscription,
            providerReviewID: "review-only",
            target: .uncommittedChanges,
            status: .completed,
            startedAt: Date(),
            endedAt: Date())
        XCTAssertTrue(Conversation(
            title: "Review", cwd: "/tmp", sdkSessionId: nil,
            messages: [review], updatedAt: Date()).hasDurableContent)
        XCTAssertTrue(Conversation(
            title: "Draft", cwd: "/tmp", sdkSessionId: nil,
            messages: [], updatedAt: Date(), draft: "unsent").hasDurableContent)
    }
}
