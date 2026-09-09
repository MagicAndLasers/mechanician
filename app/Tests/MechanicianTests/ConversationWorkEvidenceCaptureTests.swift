import XCTest
@testable import Mechanician

@MainActor
final class ConversationWorkEvidenceCaptureTests: XCTestCase {
    func testProviderErrorWithoutAssistantHasNoCompletionEvidenceEdges() {
        let prompt = TranscriptEntry(kind: .user, text: "Please continue")
        var failure = TranscriptEntry(
            kind: .system,
            text: "error: API Error: 529 Overloaded.")
        failure.providerFailurePromptID = prompt.id

        XCTAssertNil(AgentBridge.repositoryCompletionTranscriptEntries(
            after: prompt.id,
            in: [prompt, failure]))
    }

    func testInterruptedTurnWithoutAssistantHasNoCompletionEvidenceEdges() {
        let prompt = TranscriptEntry(kind: .user, text: "Please continue")

        XCTAssertNil(AgentBridge.repositoryCompletionTranscriptEntries(
            after: prompt.id,
            in: [prompt]))
    }

    func testNormalCompletionKeepsExactPromptAndFinalAssistantEdges() throws {
        let prompt = TranscriptEntry(kind: .user, text: "Please continue")
        let firstAssistant = TranscriptEntry(kind: .assistant, text: "Starting now.")
        let finalAssistant = TranscriptEntry(kind: .assistant, text: "Done and verified.")

        let entries = try XCTUnwrap(
            AgentBridge.repositoryCompletionTranscriptEntries(
                after: prompt.id,
                in: [prompt, firstAssistant, finalAssistant]))

        XCTAssertEqual(entries.prompt.id, prompt.id)
        XCTAssertEqual(entries.finalAssistant.id, finalAssistant.id)
    }
}
