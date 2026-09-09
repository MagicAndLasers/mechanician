import AppKit
import XCTest
@testable import Mechanician

/// Deleting an artifact, and putting it back.
///
/// This is the entangled one. `ArtifactStore` carries a resurrection guard — `mutationGeneration`
/// plus `pendingDeleteIDs` — whose entire job is to stop an in-flight reload from bringing a
/// deleted file back. Undo has to land inside that guard rather than beside it, so the assertions
/// here lean on reload behaviour rather than only on the in-memory array.
@MainActor
final class ArtifactDeleteUndoTests: XCTestCase {
    private var support: URL!
    private var store: ArtifactStore!
    private var conversations: ConversationStore!

    override func setUp() async throws {
        try await super.setUp()
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        conversations = ConversationStore(appSupportBaseOverride: support, watchesDirectory: false)
        store = ArtifactStore(appSupportBaseOverride: support, watchesDirectory: false)
    }

    override func tearDown() async throws {
        if let support { try? FileManager.default.removeItem(at: support) }
        try await super.tearDown()
    }

    /// An artifact plus the conversation that references it, which is the shape a delete actually
    /// touches: the durable record AND the nested copy.
    private func makeArtifact() -> (Artifact, Conversation) {
        var conversation = Conversation(
            id: UUID(), title: "Owner", cwd: "/tmp/source",
            sdkSessionId: nil, messages: [], updatedAt: Date())
        conversation.draft = "durable"
        conversations.upsert(conversation)
        let durable = store.upsertFromAgent(
            title: "Plan", type: "markdown", source: "# Plan",
            workspaceID: nil, conversationID: conversation.id,
            conversationTitle: conversation.title, cwd: conversation.cwd)
        conversation.artifacts = [durable]
        conversations.upsert(conversation)
        return (durable, conversation)
    }

    private var filesOnDisk: [String] {
        let dir = support.appendingPathComponent("artifacts", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    // MARK: The round trip

    func testDeleteThenRestoreBringsTheArtifactBack() throws {
        let (artifact, _) = makeArtifact()

        let receipt = try XCTUnwrap(store.delete(artifact.uuid, conversations: conversations))
        XCTAssertFalse(store.artifacts.contains { $0.uuid == artifact.uuid })

        XCTAssertTrue(store.restore(receipt, conversations: conversations))
        XCTAssertEqual(store.artifacts.first { $0.uuid == artifact.uuid }, artifact)
    }

    /// The delete prunes the nested copy out of every conversation that referenced it, and
    /// `synchronizeCopies` finds its target by locating that copy — so it cannot run in reverse.
    /// Restoring only the durable record would leave the reference gone.
    func testRestoreAlsoBringsBackTheReferenceInsideTheConversation() throws {
        let (artifact, conversation) = makeArtifact()
        XCTAssertEqual(conversations.conversation(conversation.id)?.artifacts.count, 1)

        let receipt = try XCTUnwrap(store.delete(artifact.uuid, conversations: conversations))
        XCTAssertEqual(
            conversations.conversation(conversation.id)?.artifacts.count, 0,
            "the delete pruned the nested copy")

        XCTAssertTrue(store.restore(receipt, conversations: conversations))

        XCTAssertEqual(
            conversations.conversation(conversation.id)?.artifacts.first?.uuid,
            artifact.uuid,
            "the conversation's reference must come back too")
    }

    /// Deletion snapshots nested membership, not the Conversation's Workspace placement. A later
    /// move must survive Undo and must not trigger the live cross-window handoff path.
    func testRestorePreservesAConversationMoveMadeAfterDeletion() throws {
        let (artifact, conversation) = makeArtifact()
        let receipt = try XCTUnwrap(store.delete(artifact.uuid, conversations: conversations))
        let laterWorkspaceID = UUID()
        conversations.update(conversation.id) {
            $0.projectID = laterWorkspaceID
            $0.cwd = "/tmp/later-workspace"
        }

        XCTAssertTrue(store.restore(receipt, conversations: conversations))

        let restored = try XCTUnwrap(conversations.conversation(conversation.id))
        XCTAssertEqual(restored.projectID, laterWorkspaceID)
        XCTAssertEqual(restored.cwd, "/tmp/later-workspace")
        XCTAssertEqual(restored.artifacts.map(\.uuid), [artifact.uuid])
    }

    // MARK: The resurrection guard

    /// Restore must survive a reload. `pendingDeleteIDs` is exactly what a reload consults to filter
    /// a deleted artifact out, so a restore that failed to clear it would be undone by the next
    /// directory read.
    func testARestoredArtifactSurvivesAReload() throws {
        let (artifact, _) = makeArtifact()
        let receipt = try XCTUnwrap(store.delete(artifact.uuid, conversations: conversations))
        XCTAssertTrue(store.restore(receipt, conversations: conversations))

        store.load()
        let reloaded = expectation(description: "reload settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { reloaded.fulfill() }
        await_fulfillment(of: reloaded)

        XCTAssertTrue(
            store.artifacts.contains { $0.uuid == artifact.uuid },
            "a reload filtered the restored artifact back out")
    }

    /// And the file is really on disk again, not just in the array.
    func testRestoreRewritesTheFile() throws {
        let (artifact, _) = makeArtifact()
        let name = "\(artifact.uuid.uuidString).json"

        let receipt = try XCTUnwrap(store.delete(artifact.uuid, conversations: conversations))
        let gone = expectation(description: "delete lands")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { gone.fulfill() }
        await_fulfillment(of: gone)
        XCTAssertFalse(filesOnDisk.contains(name))

        XCTAssertTrue(store.restore(receipt, conversations: conversations))
        let back = expectation(description: "restore lands")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { back.fulfill() }
        await_fulfillment(of: back)
        XCTAssertTrue(filesOnDisk.contains(name), "restore must rewrite the durable file")
    }

    // MARK: The undo stack

    func testUndoAndRedoAlternate() throws {
        let (artifact, _) = makeArtifact()
        let undoManager = UndoManager()

        let receipt = try XCTUnwrap(store.delete(artifact.uuid, conversations: conversations))
        ArtifactDeleteUndo.register(
            [receipt],
            actionName: ArtifactDeleteUndo.actionName(count: 1),
            store: store,
            conversations: conversations,
            undoManager: undoManager)
        XCTAssertTrue(undoManager.undoMenuItemTitle.contains(ArtifactDeleteUndo.actionName(count: 1)))

        undoManager.undo()
        XCTAssertTrue(store.artifacts.contains { $0.uuid == artifact.uuid })

        XCTAssertTrue(undoManager.canRedo)
        undoManager.redo()
        XCTAssertFalse(store.artifacts.contains { $0.uuid == artifact.uuid })

        undoManager.undo()
        XCTAssertTrue(store.artifacts.contains { $0.uuid == artifact.uuid })
    }

    /// Restoring something already present must not duplicate it — a redo that raced a reload could
    /// otherwise leave two rows for one artifact.
    func testRestoringAnArtifactThatIsAlreadyThereIsRefused() throws {
        let (artifact, _) = makeArtifact()
        let receipt = try XCTUnwrap(store.delete(artifact.uuid, conversations: conversations))
        XCTAssertTrue(store.restore(receipt, conversations: conversations))

        XCTAssertFalse(store.restore(receipt, conversations: conversations))
        XCTAssertEqual(store.artifacts.filter { $0.uuid == artifact.uuid }.count, 1)
    }

    func testDeletingSomethingThatIsNotThereYieldsNoReceipt() {
        XCTAssertNil(store.delete(UUID(), conversations: conversations))
    }

    func testDeletingWithNoUndoManagerStillDeletes() throws {
        let (artifact, _) = makeArtifact()
        let receipt = try XCTUnwrap(store.delete(artifact.uuid, conversations: conversations))
        ArtifactDeleteUndo.register(
            [receipt],
            actionName: ArtifactDeleteUndo.actionName(count: 1),
            store: store,
            conversations: conversations,
            undoManager: nil)
        XCTAssertFalse(store.artifacts.contains { $0.uuid == artifact.uuid })
    }

    private func await_fulfillment(of expectation: XCTestExpectation) {
        wait(for: [expectation], timeout: 3)
    }
}
