import XCTest
@testable import Mechanician

/// Provenance separation for guidance the app injects into a running turn.
///
/// A steer is stored as a `.user` row, and readers treat every `.user` row as something the person
/// typed. Injecting app-authored text through that same channel without marking it makes it
/// indistinguishable from their own message.
///
/// **Nothing writes an author today.** The retired Memory subsystem was the only producer, and the
/// rule outlived it deliberately: `guidanceAuthor` still decodes off disk for rows it wrote, and
/// `guide(_:author:)` still drops rather than queues authored text. Both are kept, and pinned here,
/// because the next thing that injects into a live turn will need exactly this and will not
/// rediscover it.
@MainActor
final class InjectedPolicyGuidanceTests: XCTestCase {

    private func makeBridge() -> (AgentBridge, ConversationStore, URL, URL) {
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("injected-policy-store-\(UUID().uuidString)")
        let bridgeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("injected-policy-bridge-\(UUID().uuidString)")
        let store = ConversationStore(
            appSupportBaseOverride: storeRoot,
            watchesDirectory: false)
        let bridge = AgentBridge(
            settingsBaseOverride: bridgeRoot,
            environmentOverride: [:],
            conversationStoreOverride: store)
        return (bridge, store, storeRoot, bridgeRoot)
    }

    private func tearDown(bridge: AgentBridge, store: ConversationStore, roots: [URL]) {
        AgentBridge.live.remove(bridge)
        bridge.currentID = nil
        bridge.shutdown()
        store.flushSaves()
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }

    private let typedText = "I always want the release notes written before the version bump."
    private let injectedText = "Remembered policy: run check.sh before reporting a build as green."

    private func conversation(with messages: [TranscriptEntry]) -> Conversation {
        Conversation(
            title: "Policy", cwd: "", sdkSessionId: nil,
            modelSelection: .init(access: .claudeSubscription, modelID: "m"),
            messages: messages,
            updatedAt: Date(), projectID: nil)
    }

    // MARK: - Persistence compatibility

    /// A transcript written before injected guidance existed has no such key. Synthesized
    /// `Decodable` reads an optional with `decodeIfPresent`, so the row must decode as
    /// person-authored rather than failing and costing the whole entry.
    func testATranscriptWrittenBeforeThisFieldDecodesAsPersonAuthored() throws {
        let entry = TranscriptEntry(kind: .user, text: typedText)
        let data = try JSONEncoder().encode(entry)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "guidanceAuthor")
        let older = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(TranscriptEntry.self, from: older)
        XCTAssertNil(
            decoded.guidanceAuthor,
            "an older row must decode as the person's, not fail and not be misattributed")
        XCTAssertEqual(decoded.text, typedText)
    }

    /// **The reason the case cannot simply be deleted.** Rows the retired subsystem wrote carry
    /// `memory_policy` on disk right now. `decodeIfPresent` throws on a present-but-unknown value,
    /// so dropping the case would fail every conversation holding one, and a row that failed
    /// open would be re-attributed to the person — the exact forgery this field prevents.
    func testAnAuthoredRowWrittenByTheRetiredSubsystemStillDecodes() throws {
        var entry = TranscriptEntry(kind: .user, text: injectedText)
        entry.guidanceAuthor = .memoryPolicy
        let decoded = try JSONDecoder().decode(
            TranscriptEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.guidanceAuthor, .memoryPolicy)
        XCTAssertEqual(decoded.text, injectedText)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(entry)) as? [String: Any])
        XCTAssertEqual(object["guidanceAuthor"] as? String, "memory_policy",
                       "the raw value on disk is the contract, not the Swift case name")
    }

    // MARK: - A refusal is not also a failure

    /// **Found by running the real feature, not by a test.** A declined call still produces a
    /// `tool_result` carrying an error, because from the transport's point of view it did not
    /// succeed. Reporting that as a failure says "Bash failed" when Bash never ran, and collapses
    /// the exact distinction `refused` and `failed` exist to keep.
    ///
    /// The counting half of this lived in the retired learning store. The correlation itself did
    /// not: it is transcript presentation, it was re-homed rather than deleted, and without it the
    /// transcript silently stops saying "Denied" while every test still passes.
    func testADeclinedCallIsReportedBackSoItsRowCanSayItWasDenied() {
        let (bridge, store, storeRoot, bridgeRoot) = makeBridge()
        defer { tearDown(bridge: bridge, store: store, roots: [storeRoot, bridgeRoot]) }

        bridge.noteToolRefusal(actionName: "Bash", turnID: "turn-1")
        // Staged first, exactly as production does on `tool_use`, because the suppression matches
        // on the tool's name rather than on the tool-use id a permission event never carries.
        bridge.stageToolName(turnID: "turn-1", toolUseID: "tu-1", name: "Bash")
        XCTAssertTrue(
            bridge.consumeToolRefusal(turnID: "turn-1", toolUseID: "tu-1"),
            "the declined call must be reported back so its row can say it was denied")
    }

    /// Suppression consumes exactly ONE refusal. A second Bash call in the same turn that actually
    /// ran and failed is still a failure.
    func testAGenuineFailureAfterARefusalIsNotAlsoMarkedRefused() {
        let (bridge, store, storeRoot, bridgeRoot) = makeBridge()
        defer { tearDown(bridge: bridge, store: store, roots: [storeRoot, bridgeRoot]) }

        bridge.noteToolRefusal(actionName: "Bash", turnID: "turn-1")
        bridge.stageToolName(turnID: "turn-1", toolUseID: "tu-1", name: "Bash")
        XCTAssertTrue(bridge.consumeToolRefusal(turnID: "turn-1", toolUseID: "tu-1"))

        bridge.stageToolName(turnID: "turn-1", toolUseID: "tu-2", name: "Bash")
        XCTAssertFalse(
            bridge.consumeToolRefusal(turnID: "turn-1", toolUseID: "tu-2"),
            "suppression consumes one refusal; a genuine failure after it is still a failure")
    }

    /// A tool that was never refused, and a refusal of a DIFFERENT tool, both leave this alone.
    func testAnOrdinaryCallIsUnaffectedByAnUnrelatedRefusal() {
        let (bridge, store, storeRoot, bridgeRoot) = makeBridge()
        defer { tearDown(bridge: bridge, store: store, roots: [storeRoot, bridgeRoot]) }

        bridge.stageToolName(turnID: "turn-1", toolUseID: "tu-1", name: "Edit")
        XCTAssertFalse(bridge.consumeToolRefusal(turnID: "turn-1", toolUseID: "tu-1"))

        bridge.noteToolRefusal(actionName: "Bash", turnID: "turn-1")
        bridge.stageToolName(turnID: "turn-1", toolUseID: "tu-2", name: "Edit")
        XCTAssertFalse(
            bridge.consumeToolRefusal(turnID: "turn-1", toolUseID: "tu-2"),
            "a refusal of Bash must not mark an Edit as denied")
    }

    /// The correlation is per turn. A refusal in one turn cannot mark a call in the next.
    func testARefusalDoesNotCrossTurns() {
        let (bridge, store, storeRoot, bridgeRoot) = makeBridge()
        defer { tearDown(bridge: bridge, store: store, roots: [storeRoot, bridgeRoot]) }

        bridge.noteToolRefusal(actionName: "Bash", turnID: "turn-1")
        bridge.stageToolName(turnID: "turn-2", toolUseID: "tu-1", name: "Bash")
        XCTAssertFalse(bridge.consumeToolRefusal(turnID: "turn-2", toolUseID: "tu-1"))
    }

    // MARK: - Delivery

    /// Injected guidance is TIMELY. With no steerable turn running there is nothing to inject
    /// into, and the ordinary fallback would append the text to `queuedPrompts`, sending words the
    /// person never typed as their next message.
    ///
    /// This is the rule that outlives its only producer. `author == nil` still queues; an authored
    /// steer with nowhere to go is dropped and leaves no row behind.
    func testAuthoredGuidanceIsDroppedRatherThanQueuedWhenNoTurnIsRunning() throws {
        let (bridge, store, storeRoot, bridgeRoot) = makeBridge()
        defer { tearDown(bridge: bridge, store: store, roots: [storeRoot, bridgeRoot]) }

        let conversation = conversation(with: [])
        store.upsert(conversation)
        bridge.currentID = conversation.id
        bridge.entries = []

        XCTAssertFalse(
            bridge.guide(injectedText, author: .memoryPolicy),
            "with no running turn there is nothing to steer")
        XCTAssertTrue(
            bridge.queuedPrompts.isEmpty,
            "dropped guidance must never become a prompt attributed to the person")
        XCTAssertFalse(
            bridge.entries.contains { $0.text == injectedText },
            "dropped guidance leaves no transcript row behind")
    }

    /// The control that makes the drop mean something. The SAME text, with no author, takes the
    /// ordinary path and is preserved for the next turn. If authored text were being dropped for
    /// its length or its wording rather than for who wrote it, this would fail too.
    func testTheIdenticalTextIsQueuedWhenThePersonTypedIt() throws {
        let (bridge, store, storeRoot, bridgeRoot) = makeBridge()
        defer { tearDown(bridge: bridge, store: store, roots: [storeRoot, bridgeRoot]) }

        let conversation = conversation(with: [])
        store.upsert(conversation)
        bridge.currentID = conversation.id
        bridge.entries = []

        XCTAssertTrue(bridge.guide(injectedText))
        XCTAssertFalse(
            bridge.queuedPrompts.isEmpty && bridge.entries.isEmpty,
            "the exclusion must key on authorship, not on the text")
    }

    /// Empty or whitespace guidance is refused before anything is staged.
    func testEmptyGuidanceTextIsRefused() throws {
        let (bridge, store, storeRoot, bridgeRoot) = makeBridge()
        defer { tearDown(bridge: bridge, store: store, roots: [storeRoot, bridgeRoot]) }
        let conversation = conversation(with: [])
        store.upsert(conversation)
        bridge.currentID = conversation.id

        XCTAssertFalse(bridge.guide("   \n  ", author: .memoryPolicy))
        XCTAssertTrue(bridge.queuedPrompts.isEmpty)
    }
}
