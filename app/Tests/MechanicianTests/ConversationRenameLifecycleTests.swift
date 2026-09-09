import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

/// A sidebar reload rebuilds every hosted row, and the rebuilt SwiftUI `TextField` comes back
/// without focus — so commit-on-blur can never fire again and an open rename editor would sit on the
/// row indefinitely, dark ink on the blue selection fill, reading as a mis-coloured title. That was
/// the reported bug, and the reloads behind it are routine: a new conversation, a reorder, a pin, or
/// a row crossing a date section as time passes. The rename therefore ends at the reload.
@MainActor
final class ConversationRenameLifecycleTests: XCTestCase {
    private final class EditState {
        var editingID: UUID?
        var editText = "renamed while the list moved"
        var committed: [UUID] = []
    }

    private func summary(_ title: String = "deepseek coding harness") -> ConversationSummary {
        ConversationSummary(
            Conversation(
                title: title,
                cwd: "/private/tmp/rename",
                sdkSessionId: nil,
                messages: [],
                updatedAt: Date(),
                projectID: nil))
    }

    private func coordinator(
        conversations: [ConversationSummary],
        state: EditState,
        onCommit: @escaping (UUID) -> Void
    ) -> ConversationTable.Coordinator {
        _ = NSApplication.shared
        let table = ConversationTable(
            conversations: conversations,
            selection: .constant(Set(state.editingID.map { [$0] } ?? [])),
            scale: 1,
            active: ActiveWorkspace(productAccessRequest: { true }, whenProductReady: { $0() }),
            now: Date(),
            onOpenInWindow: { _ in },
            onOpenInTab: { _ in },
            onDelete: { _ in },
            onReorder: { _ in },
            onSetFavorite: { _, _ in },
            onRename: { _ in },
            onRegenerateTitle: { _ in },
            onCopyTranscript: { _ in },
            onMarkRead: { _ in },
            onMarkUnread: { _ in },
            onResumeWait: { _ in },
            onCancelWait: { _ in },
            onMoveToProject: { _, _ in },
            onMoveToNewProject: { _ in },
            onMoveToWorkspace: { _ in false },
            editingID: Binding(get: { state.editingID }, set: { state.editingID = $0 }),
            editText: Binding(get: { state.editText }, set: { state.editText = $0 }),
            onCommitRename: onCommit)
        return table.makeCoordinator()
    }

    /// What the user typed is kept: the reload ends the rename by committing it, not by discarding it.
    func testAReloadCommitsTheOpenRenameRatherThanStrandingTheEditor() {
        let row = summary()
        let state = EditState()
        state.editingID = row.id
        let committed = expectation(description: "the open rename is committed")
        let coord = coordinator(conversations: [row], state: state) { id in
            state.committed.append(id)
            state.editingID = nil
            committed.fulfill()
        }

        coord.endRenameOrphanedByReload()

        wait(for: [committed], timeout: 2)
        XCTAssertEqual(state.committed, [row.id])
        XCTAssertNil(state.editingID, "the editor must not survive the reload that orphans it")
    }

    /// A conversation can leave the list in the same update that reloads it — deleted, or filed into
    /// another workspace. There is nothing left to rename, but the editor still has to go.
    func testAConversationThatLeftTheListClosesItsEditorWithoutRenamingIt() {
        let row = summary()
        let state = EditState()
        state.editingID = row.id
        let closed = expectation(description: "the editor closes")
        let coord = coordinator(conversations: [], state: state) { id in
            state.committed.append(id)
        }
        // Observe the binding rather than the callback: the point of this case is that nothing is
        // renamed, so the only signal is `editingID` going nil.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if state.editingID == nil { closed.fulfill() }
        }

        coord.endRenameOrphanedByReload()

        wait(for: [closed], timeout: 2)
        XCTAssertTrue(
            state.committed.isEmpty,
            "a conversation that is no longer listed must not be renamed by a reload")
    }

    /// The overwhelming majority of reloads happen with no rename open, and they must stay free of
    /// stray commits — a spurious rename would rewrite a title nobody was editing.
    func testAReloadWithNoOpenRenameCommitsNothing() {
        let row = summary()
        let state = EditState()
        let quiet = expectation(description: "no commit is published")
        quiet.isInverted = true
        let coord = coordinator(conversations: [row], state: state) { _ in quiet.fulfill() }

        coord.endRenameOrphanedByReload()

        wait(for: [quiet], timeout: 0.4)
        XCTAssertNil(state.editingID)
    }

    func testTypingRefreshesOnlyTheEditingRow() {
        let editingID = UUID()

        XCTAssertEqual(
            ConversationTableRowRefreshScope.resolve(
                semanticPresentationChanged: false,
                previousEditingID: editingID,
                previousEditText: "bef",
                editingID: editingID,
                editText: "before"),
            .conversations([editingID]))
    }

    func testEnteringAndLeavingRenameRefreshOnlyTheAffectedRows() {
        let firstID = UUID()
        let secondID = UUID()

        XCTAssertEqual(
            ConversationTableRowRefreshScope.resolve(
                semanticPresentationChanged: false,
                previousEditingID: nil,
                previousEditText: "",
                editingID: firstID,
                editText: "First"),
            .conversations([firstID]))
        XCTAssertEqual(
            ConversationTableRowRefreshScope.resolve(
                semanticPresentationChanged: false,
                previousEditingID: firstID,
                previousEditText: "First",
                editingID: secondID,
                editText: "Second"),
            .conversations([firstID, secondID]))
        XCTAssertEqual(
            ConversationTableRowRefreshScope.resolve(
                semanticPresentationChanged: false,
                previousEditingID: secondID,
                previousEditText: "Second",
                editingID: nil,
                editText: "Second"),
            .conversations([secondID]))
    }

    func testSemanticChangesStillRefreshEveryVisibleRow() {
        let editingID = UUID()

        XCTAssertEqual(
            ConversationTableRowRefreshScope.resolve(
                semanticPresentationChanged: true,
                previousEditingID: editingID,
                previousEditText: "Before",
                editingID: editingID,
                editText: "After"),
            .allVisible)
    }

    func testSubmitAndBlurCommitOneRenameOnlyOnce() {
        let row = summary()
        let state = EditState()
        state.editingID = row.id
        let coord = coordinator(conversations: [row], state: state) { id in
            state.committed.append(id)
            // Deliberately leave editingID intact: the coordinator, rather than a synchronous
            // binding mutation, must suppress the blur callback that follows submit.
        }

        coord.commitRenameIfNeeded(row.id) // submit
        coord.commitRenameIfNeeded(row.id) // blur

        XCTAssertEqual(state.committed, [row.id])
    }

    func testCancelSuppressesTheBlurCommit() {
        let row = summary()
        let state = EditState()
        state.editingID = row.id
        let coord = coordinator(conversations: [row], state: state) { id in
            state.committed.append(id)
        }

        coord.cancelRenameIfNeeded(row.id)
        coord.commitRenameIfNeeded(row.id)

        XCTAssertNil(state.editingID)
        XCTAssertTrue(state.committed.isEmpty)
    }
}
