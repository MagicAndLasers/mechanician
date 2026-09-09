import AppKit
import XCTest
@testable import Mechanician

/// Deleting a conversation, and putting it back.
///
/// The two assertions that matter most here are not about the happy path. They are the state-loss
/// bugs the critique found in the original design, both confirmed against the tree before any of
/// this was written:
///
///   1. `remove` clears `pausedQueueConversationIDs` and `upsert` only ever removes from that set,
///      so a restored conversation with queued prompts came back **unpaused** — selecting it would
///      have sent to the provider. Undo reverses what Mechanician stored; it must never start an
///      agent turn.
///   2. Redo after an undo moved a sidecar onto a destination that still existed. `moveItem` fails
///      there, the failure was swallowed, and the sidecar stayed in the store directory while the
///      row was dropped from memory — so the conversation reappeared on the next launch.
@MainActor
final class ConversationDeleteUndoTests: XCTestCase {
    private var support: URL!
    private var store: ConversationStore!

    override func setUp() async throws {
        try await super.setUp()
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("delete-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        store = ConversationStore(appSupportBaseOverride: support, watchesDirectory: false)
    }

    override func tearDown() async throws {
        store?.flushSaves()
        if let support { try? FileManager.default.removeItem(at: support) }
        try await super.tearDown()
    }

    private func makeConversation(queued: [String] = []) -> Conversation {
        var conversation = Conversation(
            id: UUID(), title: "Delete me", cwd: "/tmp/source",
            sdkSessionId: nil, messages: [], updatedAt: Date())
        conversation.queuedPrompts = queued
        conversation.draft = "durable"
        store.upsert(conversation)
        store.flushSaves()
        return conversation
    }

    private var sidecars: [String] {
        let dir = support.appendingPathComponent("conversations", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func mediaDirectory(_ id: UUID) -> URL {
        support.appendingPathComponent("conversation-media", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: The round trip

    func testDeleteThenRestoreBringsTheConversationBack() throws {
        let conversation = makeConversation()
        let receipt = try XCTUnwrap(store.remove(conversation.id))
        store.flushSaves()

        XCTAssertNil(store.conversation(conversation.id))
        XCTAssertFalse(sidecars.contains("\(conversation.id.uuidString).json"))

        XCTAssertTrue(store.restore(receipt))
        store.flushSaves()

        XCTAssertEqual(store.conversation(conversation.id)?.title, "Delete me")
        XCTAssertTrue(sidecars.contains("\(conversation.id.uuidString).json"))
    }

    /// The reason this is trash rather than an in-memory snapshot: a snapshot restore would leave
    /// every pasted image dangling.
    func testRestoreBringsTheConversationsMediaBack() throws {
        let conversation = makeConversation()
        let media = mediaDirectory(conversation.id)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let image = media.appendingPathComponent("pasted.png")
        try Data("image bytes".utf8).write(to: image)

        let receipt = try XCTUnwrap(store.remove(conversation.id))
        store.flushSaves()
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path), "media went to the trash")

        XCTAssertTrue(store.restore(receipt))
        store.flushSaves()

        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path), "media came home")
        XCTAssertEqual(try Data(contentsOf: image), Data("image bytes".utf8))
    }

    // MARK: Bug 1 — undo must not start an agent turn

    func testRestoringAConversationWithQueuedPromptsLeavesItPaused() throws {
        let conversation = makeConversation(queued: ["do the thing"])
        let receipt = try XCTUnwrap(store.remove(conversation.id))

        XCTAssertTrue(store.restore(receipt))

        XCTAssertTrue(
            store.pausedQueueConversationIDs.contains(conversation.id),
            "a restored conversation with queued prompts must not drain to the provider")
    }

    /// A conversation with nothing queued has nothing to drain, so restoring it must not invent a
    /// paused state the user would then have to clear.
    func testRestoringAConversationWithNoQueueDoesNotPauseIt() throws {
        let conversation = makeConversation()
        let receipt = try XCTUnwrap(store.remove(conversation.id))

        XCTAssertTrue(store.restore(receipt))

        XCTAssertFalse(store.pausedQueueConversationIDs.contains(conversation.id))
    }

    // MARK: Bug 2 — redo must not resurrect on next launch

    /// Delete, undo, redo, then reload from disk. The conversation must stay gone. This is the exact
    /// sequence that used to leave the sidecar in place while dropping the row from memory.
    func testRedoAfterUndoDoesNotResurrectOnReload() throws {
        let conversation = makeConversation()

        let first = try XCTUnwrap(store.remove(conversation.id))
        store.flushSaves()
        XCTAssertTrue(store.restore(first))
        store.flushSaves()
        let second = try XCTUnwrap(store.remove(conversation.id))
        store.flushSaves()

        XCTAssertNil(store.conversation(conversation.id))
        XCTAssertFalse(
            sidecars.contains("\(conversation.id.uuidString).json"),
            "the sidecar must not survive the redo")

        let relaunched = ConversationStore(
            appSupportBaseOverride: support, watchesDirectory: false)
        XCTAssertNil(
            relaunched.conversation(conversation.id),
            "the conversation came back from disk after a delete/undo/redo cycle")
        _ = second
    }

    /// Each delete gets its own trash slot. Sharing one keyed by conversation id is what made redo
    /// collide with the copy the previous delete left behind.
    func testEachDeleteGetsItsOwnTrashSlot() throws {
        let conversation = makeConversation()
        let first = try XCTUnwrap(store.remove(conversation.id))
        XCTAssertTrue(store.restore(first))
        let second = try XCTUnwrap(store.remove(conversation.id))

        XCTAssertNotEqual(first.slot, second.slot)
    }

    // MARK: Boundaries

    /// The escape hatch test cleanup uses. It must leave nothing behind to restore.
    func testAPermanentDeleteReturnsNoReceipt() throws {
        let conversation = makeConversation()
        XCTAssertNil(store.remove(conversation.id, permanently: true))
        store.flushSaves()
        XCTAssertNil(store.conversation(conversation.id))
        XCTAssertFalse(sidecars.contains("\(conversation.id.uuidString).json"))
    }

    func testRemovingSomethingThatIsNotThereIsHarmless() {
        XCTAssertNil(store.remove(UUID()))
    }

    /// The reaper clears old slots without touching fresh ones, so undo within a session survives a
    /// reload while the trash still cannot grow for the life of the install.
    func testTheReaperDropsOldSlotsAndKeepsFreshOnes() throws {
        let root = support.appendingPathComponent("trash", isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let trash = ConversationTrash(root: root)

        let fresh = try trash.makeSlot(for: UUID())
        let stale = try trash.makeSlot(for: UUID())
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60 * 60 * 24 * 30)],
            ofItemAtPath: stale.path)

        trash.reap(olderThan: 60 * 60 * 24 * 7)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    // MARK: The undo stack

    func testDeletingRegistersOnTheStackWithAReadableName() throws {
        let conversation = makeConversation()
        let undoManager = UndoManager()
        let receipt = try XCTUnwrap(store.remove(conversation.id))

        ConversationDeleteUndo.register(
            [receipt],
            actionName: ConversationDeleteUndo.actionName(count: 1),
            store: store,
            undoManager: undoManager)

        XCTAssertTrue(undoManager.canUndo)
        XCTAssertTrue(undoManager.undoMenuItemTitle.contains(ConversationDeleteUndo.actionName(count: 1)))
    }

    func testUndoThenRedoAlternatesAcrossDeletes() throws {
        let conversation = makeConversation()
        let undoManager = UndoManager()
        let receipt = try XCTUnwrap(store.remove(conversation.id))
        ConversationDeleteUndo.register(
            [receipt],
            actionName: ConversationDeleteUndo.actionName(count: 1),
            store: store,
            undoManager: undoManager)

        undoManager.undo()
        XCTAssertNotNil(store.conversation(conversation.id), "undo brought it back")

        XCTAssertTrue(undoManager.canRedo)
        undoManager.redo()
        XCTAssertNil(store.conversation(conversation.id), "redo removed it again")

        undoManager.undo()
        XCTAssertNotNil(store.conversation(conversation.id), "and it alternates")
    }

    /// Redo re-deletes by id and takes a FRESH receipt. Reusing the spent one would point at a
    /// trash slot that undo already emptied, which is how a conversation used to survive a redo.
    func testRedoSurvivesAReloadFromDisk() throws {
        let conversation = makeConversation()
        let undoManager = UndoManager()
        let receipt = try XCTUnwrap(store.remove(conversation.id))
        ConversationDeleteUndo.register(
            [receipt],
            actionName: ConversationDeleteUndo.actionName(count: 1),
            store: store,
            undoManager: undoManager)

        undoManager.undo()
        store.flushSaves()
        undoManager.redo()
        store.flushSaves()

        let relaunched = ConversationStore(
            appSupportBaseOverride: support, watchesDirectory: false)
        XCTAssertNil(
            relaunched.conversation(conversation.id),
            "a redone delete must not come back from disk")
    }

    /// One gesture that removes several conversations is one undo, not several.
    func testABulkDeleteUndoesAsASingleAction() throws {
        let first = makeConversation()
        let second = makeConversation()
        let third = makeConversation()
        let undoManager = UndoManager()

        let receipts = [first, second, third].compactMap { store.remove($0.id) }
        XCTAssertEqual(receipts.count, 3)
        ConversationDeleteUndo.register(
            receipts,
            actionName: ConversationDeleteUndo.actionName(count: receipts.count),
            store: store,
            undoManager: undoManager)
        XCTAssertTrue(undoManager.undoMenuItemTitle.contains("Delete 3 Conversations"))

        undoManager.undo()

        XCTAssertNotNil(store.conversation(first.id))
        XCTAssertNotNil(store.conversation(second.id))
        XCTAssertNotNil(store.conversation(third.id))
        XCTAssertFalse(undoManager.canUndo, "three deletes, one undo")
    }

    func testDeleteAllReadsAsItsOwnAction() throws {
        let conversation = makeConversation()
        let undoManager = UndoManager()
        let receipt = try XCTUnwrap(store.remove(conversation.id))

        ConversationDeleteUndo.register(
            [receipt],
            actionName: ConversationDeleteUndo.deleteAllActionName,
            store: store,
            undoManager: undoManager)

        XCTAssertTrue(undoManager.undoMenuItemTitle.contains("Delete All Conversations"))
    }

    /// Nothing about deleting may depend on a window existing.
    func testDeletingWithNoUndoManagerStillDeletes() throws {
        let conversation = makeConversation()
        let receipt = try XCTUnwrap(store.remove(conversation.id))
        ConversationDeleteUndo.register(
            [receipt],
            actionName: ConversationDeleteUndo.actionName(count: 1),
            store: store,
            undoManager: nil)
        XCTAssertNil(store.conversation(conversation.id))
    }
}
