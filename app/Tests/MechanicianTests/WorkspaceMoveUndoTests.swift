import AppKit
import XCTest
@testable import Mechanician

/// Undoing a workspace move.
///
/// The point of these is the claim that motivated the design: replaying `adopt` with the old
/// destination does **not** undo a move, because adoption fills `conversationID` when it was nil and
/// `conversationTitle` when it was empty and nothing ever clears them. So undo restores recorded
/// values, and the test that matters is byte-identity with the pre-move state.
@MainActor
final class WorkspaceMoveUndoTests: XCTestCase {
    private var store: ConversationStore!
    private var artifacts: ArtifactStore!
    private var support: URL!

    override func setUp() async throws {
        try await super.setUp()
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("move-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        store = ConversationStore(appSupportBaseOverride: support, watchesDirectory: false)
        artifacts = ArtifactStore(appSupportBaseOverride: support, watchesDirectory: false)
    }

    override func tearDown() async throws {
        if let support { try? FileManager.default.removeItem(at: support) }
        try await super.tearDown()
    }

    private func makeConversation(cwd: String = "/tmp/source", projectID: UUID? = nil) -> Conversation {
        var conversation = Conversation(
            id: UUID(),
            title: "Move me",
            cwd: cwd,
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date())
        conversation.projectID = projectID
        store.upsert(conversation)
        return conversation
    }

    private func project(cwd: String) -> Project {
        Project(name: "Destination", cwd: cwd)
    }

    private func awaitPlacementOperation() async {
        for _ in 0..<10_000 {
            if !WorkspaceAdoption.isPlacementOperationInProgress { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Workspace placement operation did not finish")
    }

    // MARK: The rule

    func testUndoRestoresTheConversationsPlaceExactly() throws {
        let conversation = makeConversation()
        let before = try XCTUnwrap(store.conversation(conversation.id))
        let undoManager = UndoManager()

        let result = WorkspaceAdoption.adopt(
            conversations: [conversation.id],
            into: .project(project(cwd: "/tmp/destination")),
            conversations: store,
            artifactStore: artifacts,
            synchronizeLiveState: false,
            undoManager: undoManager)
        XCTAssertTrue(result.succeeded, "the move itself must land before undo means anything")

        let moved = try XCTUnwrap(store.conversation(conversation.id))
        XCTAssertEqual(moved.cwd, "/tmp/destination")
        XCTAssertNotEqual(moved.cwd, before.cwd)

        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()

        let restored = try XCTUnwrap(store.conversation(conversation.id))
        XCTAssertEqual(restored.cwd, before.cwd)
        XCTAssertEqual(restored.projectID, before.projectID)
        XCTAssertEqual(restored.artifacts, before.artifacts)
    }

    /// Undo and redo alternate for as long as the user keeps pressing, because applying a record
    /// registers its own inverse rather than being a one-shot.
    func testUndoAndRedoAlternate() async throws {
        let conversation = makeConversation()
        let undoManager = UndoManager()
        let destination = project(cwd: "/tmp/destination")

        _ = WorkspaceAdoption.adopt(
            conversations: [conversation.id],
            into: .project(destination),
            conversations: store,
            artifactStore: artifacts,
            synchronizeLiveState: false,
            undoManager: undoManager)

        undoManager.undo()
        XCTAssertEqual(store.conversation(conversation.id)?.cwd, "/tmp/source")
        await awaitPlacementOperation()

        XCTAssertTrue(undoManager.canRedo)
        undoManager.redo()
        XCTAssertEqual(store.conversation(conversation.id)?.cwd, "/tmp/destination")
        await awaitPlacementOperation()

        undoManager.undo()
        XCTAssertEqual(store.conversation(conversation.id)?.cwd, "/tmp/source")
        await awaitPlacementOperation()
    }

    /// A batch can span several source workspaces, so the record is a per-conversation map rather
    /// than one destination. Undo has to put each one back where *it* was.
    func testABatchFromSeveralPlacesGoesBackToSeveralPlaces() throws {
        let first = makeConversation(cwd: "/tmp/alpha")
        let second = makeConversation(cwd: "/tmp/beta")
        let undoManager = UndoManager()

        _ = WorkspaceAdoption.adopt(
            conversations: [first.id, second.id],
            into: .project(project(cwd: "/tmp/destination")),
            conversations: store,
            artifactStore: artifacts,
            synchronizeLiveState: false,
            undoManager: undoManager)

        XCTAssertEqual(store.conversation(first.id)?.cwd, "/tmp/destination")
        XCTAssertEqual(store.conversation(second.id)?.cwd, "/tmp/destination")

        undoManager.undo()

        XCTAssertEqual(store.conversation(first.id)?.cwd, "/tmp/alpha")
        XCTAssertEqual(store.conversation(second.id)?.cwd, "/tmp/beta")
    }

    /// Moving Home-ward means projectID nil and an empty cwd, which is a real destination rather
    /// than an absence, so it has to survive the round trip too.
    func testMovingHomeAndBackRestoresTheProject() throws {
        let source = project(cwd: "/tmp/source")
        let conversation = makeConversation(cwd: source.cwd, projectID: source.id)
        let before = try XCTUnwrap(store.conversation(conversation.id))
        let undoManager = UndoManager()

        _ = WorkspaceAdoption.adopt(
            conversations: [conversation.id],
            into: .home,
            conversations: store,
            artifactStore: artifacts,
            synchronizeLiveState: false,
            undoManager: undoManager)

        XCTAssertNil(store.conversation(conversation.id)?.projectID)
        undoManager.undo()

        XCTAssertEqual(store.conversation(conversation.id)?.projectID, before.projectID)
        XCTAssertEqual(store.conversation(conversation.id)?.cwd, before.cwd)
    }

    // MARK: Boundaries

    /// The move must not depend on a window existing. Without an undo manager it still moves; there
    /// is simply nothing to undo with.
    func testAMoveWithNoUndoManagerStillMoves() throws {
        let conversation = makeConversation()
        let result = WorkspaceAdoption.adopt(
            conversations: [conversation.id],
            into: .project(project(cwd: "/tmp/destination")),
            conversations: store,
            artifactStore: artifacts,
            synchronizeLiveState: false)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(store.conversation(conversation.id)?.cwd, "/tmp/destination")
    }

    /// A move that changes nothing must not put an empty entry on the stack, or ⌘Z would appear
    /// enabled and then do nothing.
    func testANoOpMoveRegistersNothing() throws {
        let destination = project(cwd: "/tmp/destination")
        let conversation = makeConversation(cwd: destination.cwd, projectID: destination.id)
        let undoManager = UndoManager()

        let result = WorkspaceAdoption.adopt(
            conversations: [conversation.id],
            into: .project(destination),
            conversations: store,
            artifactStore: artifacts,
            synchronizeLiveState: false,
            undoManager: undoManager)

        XCTAssertEqual(result, .unchanged)
        XCTAssertFalse(undoManager.canUndo, "an unchanged move must leave the stack alone")
    }

    /// AppKit prefixes "Undo ", so the stored name is the action alone and it pluralizes.
    ///
    /// The singular is deliberately not asserted here. These names resolve through the string
    /// catalogue so the plural rules are declared rather than written as `count == 1 ? …`, and the
    /// catalogue lives in the app bundle — under `xctest` `Bundle.main` is the runner, so a lookup
    /// falls back to the key and `count: 1` reads "Move 1 Conversations". `LocalizableCatalogTests`
    /// pins the singular against the catalogue itself, and `compile-string-catalog.sh` fails the
    /// build if those plurals do not reach the app.
    func testActionNamesReadLikeMenuItems() {
        XCTAssertEqual(WorkspaceMoveUndo.actionName(conversations: 3), "Move 3 Conversations")
        XCTAssertEqual(WorkspaceMoveUndo.actionName(artifacts: 2), "Move 2 Artifacts")
    }

    // MARK: Artifacts

    /// Builds a durable artifact plus the conversation holding a same-UUID nested snapshot, which is
    /// the shape `adopt(artifacts:)` actually rewrites: the library record AND every copy inside a
    /// conversation.
    private func makeArtifact(
        in conversation: Conversation,
        uuid: UUID = UUID()
    ) -> Artifact {
        // The nested copy is taken FROM the durable record rather than built alongside it. Built
        // separately they diverge in fields like `origin`, and adoption then converges the snapshot
        // even when the destination is unchanged — which is a real write, not a no-op, and made an
        // earlier version of this fixture lie about what "unchanged" means.
        var owner = conversation
        let durable = artifacts.upsertFromAgent(
            title: "Plan",
            type: "markdown",
            source: "# Plan",
            workspaceID: owner.projectID,
            conversationID: owner.id,
            conversationTitle: owner.title,
            cwd: owner.cwd,
            preferredID: uuid)
        owner.artifacts = [durable]
        store.upsert(owner)
        return durable
    }

    func testUndoRestoresAMovedArtifactExactly() throws {
        let conversation = makeConversation()
        let artifact = makeArtifact(in: conversation)
        let before = try XCTUnwrap(artifacts.artifacts.first { $0.uuid == artifact.uuid })
        let undoManager = UndoManager()

        let result = WorkspaceAdoption.adopt(
            artifacts: [artifact.uuid],
            into: .project(project(cwd: "/tmp/destination")),
            conversations: store,
            artifactStore: artifacts,
            synchronizeLiveState: false,
            undoManager: undoManager)
        XCTAssertTrue(result.succeeded)
        XCTAssertNotEqual(
            artifacts.artifacts.first { $0.uuid == artifact.uuid }?.cwd, before.cwd)

        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()

        XCTAssertEqual(artifacts.artifacts.first { $0.uuid == artifact.uuid }, before)
    }

    /// The nested copy inside the conversation has to come back too. Restoring only the durable
    /// record would leave a stale snapshot that writes the destination workspace back on next save —
    /// the exact convergence problem `adopt` exists to prevent, running in reverse.
    func testUndoAlsoRestoresTheNestedSnapshotInsideTheConversation() throws {
        let conversation = makeConversation()
        let artifact = makeArtifact(in: conversation)
        let before = try XCTUnwrap(store.conversation(conversation.id)?.artifacts.first)
        let undoManager = UndoManager()

        _ = WorkspaceAdoption.adopt(
            artifacts: [artifact.uuid],
            into: .project(project(cwd: "/tmp/destination")),
            conversations: store,
            artifactStore: artifacts,
            synchronizeLiveState: false,
            undoManager: undoManager)
        XCTAssertNotEqual(store.conversation(conversation.id)?.artifacts.first, before)

        undoManager.undo()

        XCTAssertEqual(store.conversation(conversation.id)?.artifacts.first, before)
    }

    func testArtifactUndoAndRedoAlternate() async throws {
        let conversation = makeConversation()
        let artifact = makeArtifact(in: conversation)
        let undoManager = UndoManager()

        _ = WorkspaceAdoption.adopt(
            artifacts: [artifact.uuid],
            into: .project(project(cwd: "/tmp/destination")),
            conversations: store,
            artifactStore: artifacts,
            synchronizeLiveState: false,
            undoManager: undoManager)

        undoManager.undo()
        XCTAssertEqual(artifacts.artifacts.first { $0.uuid == artifact.uuid }?.cwd, "/tmp/source")
        await awaitPlacementOperation()

        XCTAssertTrue(undoManager.canRedo)
        undoManager.redo()
        XCTAssertEqual(
            artifacts.artifacts.first { $0.uuid == artifact.uuid }?.cwd, "/tmp/destination")
        await awaitPlacementOperation()
    }

    /// An artifact move that changes nothing must leave the stack alone, same as a conversation one.
    func testAnUnchangedArtifactMoveRegistersNothing() throws {
        let destination = project(cwd: "/tmp/destination")
        let conversation = makeConversation(cwd: destination.cwd, projectID: destination.id)
        let artifact = makeArtifact(in: conversation)
        let undoManager = UndoManager()

        let result = WorkspaceAdoption.adopt(
            artifacts: [artifact.uuid],
            into: .project(destination),
            conversations: store,
            artifactStore: artifacts,
            synchronizeLiveState: false,
            undoManager: undoManager)

        XCTAssertEqual(result, .unchanged)
        XCTAssertFalse(undoManager.canUndo)
    }
}
