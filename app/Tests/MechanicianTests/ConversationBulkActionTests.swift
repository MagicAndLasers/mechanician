import AppKit
import XCTest
@testable import Mechanician

/// Regression cover for the bug where `Move to Workspace` carried only the right-clicked row while
/// Mark and Delete carried the whole selection, so moving a multi-selection moved one conversation
/// and silently left the rest behind. The rule is now one function; these tests are what stop a
/// future menu item from quietly re-introducing a second one.
final class ConversationBulkActionTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    private func summary(_ id: UUID, favorite: Bool) -> ConversationSummary {
        ConversationSummary(
            id: id,
            title: id.uuidString,
            workspaceCWD: "",
            workspaceID: nil,
            updatedAt: .distantPast,
            messageCount: 0,
            snippet: "",
            hasUserMessage: false,
            favorite: favorite,
            sortIndex: nil,
            unread: false,
            errored: false,
            awaitingQuestion: false,
            hasRunningDelegate: false,
            providerAccessName: nil,
            armedWaitSummary: nil)
    }

    // MARK: targeting

    func testRightClickInsideAMultiSelectionTargetsTheWholeSelection() {
        XCTAssertEqual(
            ConversationBulkAction.targets(clicked: a, selection: [a, b, c]),
            [a, b, c],
            "a bulk action invoked from inside a selection must act on all of it")
    }

    func testRightClickOutsideTheSelectionTargetsOnlyTheClickedRow() {
        XCTAssertEqual(
            ConversationBulkAction.targets(clicked: c, selection: [a, b]),
            [c],
            "the selection does not follow the cursor, so a menu opened elsewhere acts alone")
    }

    func testSingleSelectionTargetsOnlyTheClickedRow() {
        XCTAssertEqual(ConversationBulkAction.targets(clicked: a, selection: [a]), [a])
        XCTAssertEqual(ConversationBulkAction.targets(clicked: a, selection: []), [a])
    }

    /// The load-bearing one. Move, Delete and both Mark items must resolve identical targets for the
    /// same click, because they all read as acting on "what I selected".
    func testEveryBulkActionResolvesTheSameTargetsForTheSameClick() {
        let selection: Set<UUID> = [a, b, c]
        let targets = ConversationBulkAction.targets(clicked: b, selection: selection)

        XCTAssertEqual(targets, selection)
        XCTAssertEqual(
            ConversationBulkAction.moveTitle(count: targets.count),
            "Move 3 Conversations to Workspace")
        XCTAssertEqual(
            ConversationBulkAction.deleteTitle(count: targets.count),
            "Delete 3 Conversations")
        XCTAssertEqual(ConversationBulkAction.markReadTitle(count: targets.count), "Mark 3 as Read")
        XCTAssertEqual(
            ConversationBulkAction.markUnreadTitle(count: targets.count),
            "Mark 3 as Unread")
        XCTAssertEqual(
            ConversationBulkAction.favoriteMutation(
                targets: targets,
                conversations: [
                    summary(a, favorite: true),
                    summary(b, favorite: true),
                    summary(c, favorite: true),
                ]),
            .init(conversationIDs: targets, favorite: false))
    }

    func testFavoriteMutationConvergesMixedSelectionToPinned() {
        let targets: Set<UUID> = [a, b, c]
        XCTAssertEqual(
            ConversationBulkAction.favoriteMutation(
                targets: targets,
                conversations: [
                    summary(a, favorite: true),
                    summary(b, favorite: false),
                    summary(c, favorite: true),
                ]),
            .init(conversationIDs: targets, favorite: true),
            "a mixed selection needs one explicit destination state, never per-row toggles")
    }

    // MARK: titles

    func testTitlesStaySingularForOneTarget() {
        XCTAssertEqual(ConversationBulkAction.moveTitle(count: 1), "Move to Workspace")
        XCTAssertEqual(ConversationBulkAction.deleteTitle(count: 1), "Delete")
        XCTAssertEqual(ConversationBulkAction.markReadTitle(count: 1), "Mark as Read")
        XCTAssertEqual(ConversationBulkAction.markUnreadTitle(count: 1), "Mark as Unread")
        XCTAssertEqual(ConversationBulkAction.favoriteTitle(favorite: true, count: 1), "Pin Conversation")
        XCTAssertEqual(ConversationBulkAction.favoriteTitle(favorite: false, count: 1), "Unpin Conversation")
        XCTAssertEqual(ConversationBulkAction.favoriteTitle(favorite: true, count: 3), "Pin 3 Conversations")
        XCTAssertEqual(ConversationBulkAction.favoriteTitle(favorite: false, count: 3), "Unpin 3 Conversations")
    }

    /// A menu title that says "Move to Workspace" while acting on four conversations is exactly how
    /// the original bug stayed invisible. Any plural target set must announce its own count.
    func testAMultiTargetMoveAnnouncesItsCount() {
        for count in 2...5 {
            XCTAssertTrue(
                ConversationBulkAction.moveTitle(count: count).contains("\(count)"),
                "a move over \(count) conversations must say so in its title")
        }
    }

    // MARK: destination state

    func testDestinationIsCheckedOnlyWhenEveryTargetAlreadyLivesThere() {
        let home = UUID()
        let away = UUID()
        XCTAssertEqual(
            ConversationBulkAction.destinationState(targetProjectIDs: [home], destination: home),
            .on)
        XCTAssertEqual(
            ConversationBulkAction.destinationState(targetProjectIDs: [home], destination: away),
            .off)
    }

    func testAPartlyResidentSelectionIsMixedRatherThanChecked() {
        let home = UUID()
        XCTAssertEqual(
            ConversationBulkAction.destinationState(
                targetProjectIDs: [home, nil],
                destination: home),
            .mixed,
            "some of the selection still lives in Home, so this destination has work to do")
    }

    func testHomeOnlySelectionLeavesEveryWorkspaceDestinationOff() {
        let project = UUID()
        XCTAssertEqual(
            ConversationBulkAction.destinationState(targetProjectIDs: [nil], destination: project),
            .off,
            "loose Home conversations are not resident in any workspace")
    }
}

/// Inspects the real `NSMenu` the sidebar builds. The policy tests above prove the rule; these prove
/// the menu actually uses it, which is the half that was broken — `Move to Workspace` read the
/// clicked row while Mark and Delete read the selection, and nothing on screen disagreed.
@MainActor
final class ConversationContextMenuTargetTests: XCTestCase {
    private struct MenuFixture {
        let menu: NSMenu
        let coordinator: ConversationTable.Coordinator
    }

    private func conversation(_ title: String, projectID: UUID?) -> Conversation {
        var c = Conversation(
            title: title,
            cwd: "",
            sdkSessionId: nil,
            modelSelection: ModelSelection(access: .claudeSubscription, modelID: "model-a"),
            messages: [],
            updatedAt: Date())
        c.projectID = projectID
        return c
    }

    /// Build the menu the coordinator would build for a right-click on `clicked` with `targets`
    /// resolved, without needing AppKit to supply a `clickedRow`.
    private func menu(
        clicked: Conversation,
        targets: Set<UUID>,
        conversations: [Conversation],
        onSetFavorite: @escaping (Set<UUID>, Bool) -> Void = { _, _ in },
        onMarkRead: @escaping (Set<UUID>) -> Void = { _ in },
        onMarkUnread: @escaping (Set<UUID>) -> Void = { _ in },
        onMoveToNewProject: @escaping (Set<UUID>) -> Void = { _ in },
        onDelete: @escaping (Set<UUID>) -> Void = { _ in }
    ) -> MenuFixture {
        _ = NSApplication.shared
        let summaries = conversations.map(ConversationSummary.init)
        let table = ConversationTable(
            conversations: summaries,
            selection: .constant(targets),
            scale: 1,
            active: ActiveWorkspace.shared,
            now: Date(),
            requestExportDocument: { id, completion in
                guard let conversation = conversations.first(where: { $0.id == id }) else {
                    completion(.failure(.deleted))
                    return
                }
                completion(.success(ConversationMarkdownDocument(conversation: conversation)))
            },
            onOpenInWindow: { _ in },
            onOpenInTab: { _ in },
            onDelete: onDelete,
            onReorder: { _ in },
            onSetFavorite: onSetFavorite,
            onRename: { _ in },
            onRegenerateTitle: { _ in },
            onCopyTranscript: { _ in },
            onMarkRead: onMarkRead,
            onMarkUnread: onMarkUnread,
            onResumeWait: { _ in },
            onCancelWait: { _ in },
            onMoveToProject: { _, _ in },
            onMoveToNewProject: onMoveToNewProject,
            onMoveToWorkspace: { _ in false },
            editingID: .constant(nil),
            editText: .constant(""),
            onCommitRename: { _ in })
        let coordinator = table.makeCoordinator()
        let menu = NSMenu()
        coordinator.populate(
            menu,
            clicked: ConversationSummary(clicked),
            targets: targets)
        _ = table
        return MenuFixture(menu: menu, coordinator: coordinator)
    }

    private func targetIDs(_ item: NSMenuItem?) -> Set<UUID>? {
        (item?.representedObject as? [UUID]).map(Set.init)
    }

    /// The exact regression: Move must carry the same conversations Delete does.
    func testMoveToWorkspaceCarriesTheSameTargetsAsDelete() throws {
        let a = conversation("Not Easy Being Green", projectID: nil)
        let b = conversation("Dinner for six", projectID: nil)
        let targets: Set<UUID> = [a.id, b.id]

        let menu = menu(clicked: a, targets: targets, conversations: [a, b]).menu
        let move = try XCTUnwrap(menu.items.first { $0.title.hasPrefix("Move") })
        let delete = try XCTUnwrap(menu.items.first { $0.title.hasPrefix("Delete") })
        let newWorkspace = try XCTUnwrap(
            move.submenu?.items.first { $0.title == "New Workspace…" })

        XCTAssertEqual(
            targetIDs(newWorkspace),
            targets,
            "New Workspace… must adopt every selected conversation, not just the clicked row")
        XCTAssertEqual(
            targetIDs(newWorkspace),
            targetIDs(delete),
            "Move and Delete must agree about what the right-click targeted")
    }

    func testMoveTitleAnnouncesAMultiSelection() throws {
        let a = conversation("Not Easy Being Green", projectID: nil)
        let b = conversation("Dinner for six", projectID: nil)

        let many = menu(clicked: a, targets: [a.id, b.id], conversations: [a, b]).menu
        XCTAssertNotNil(
            many.items.first { $0.title == "Move 2 Conversations to Workspace" },
            "a two-conversation move must say two")

        let one = menu(clicked: a, targets: [a.id], conversations: [a, b]).menu
        XCTAssertNotNil(one.items.first { $0.title == "Move to Workspace" })
    }

    func testSingleTargetMoveStillCarriesThatConversation() throws {
        let a = conversation("Not Easy Being Green", projectID: nil)
        let b = conversation("Dinner for six", projectID: nil)

        let menu = menu(clicked: b, targets: [b.id], conversations: [a, b]).menu
        let move = try XCTUnwrap(menu.items.first { $0.title.hasPrefix("Move") })
        let newWorkspace = try XCTUnwrap(
            move.submenu?.items.first { $0.title == "New Workspace…" })
        XCTAssertEqual(targetIDs(newWorkspace), [b.id])
    }

    func testPinAndUnpinMenuItemsInvokeEveryTargetWithAnExplicitState() throws {
        let unpinned = conversation("Unpinned", projectID: nil)
        var pinned = conversation("Pinned", projectID: nil)
        pinned.favorite = true
        var invoked: [(Set<UUID>, Bool)] = []

        var secondPinned = conversation("Also pinned", projectID: nil)
        secondPinned.favorite = true
        let actualTargets: Set<UUID> = [pinned.id, secondPinned.id]
        let fixture = menu(
            clicked: pinned,
            targets: actualTargets,
            conversations: [pinned, secondPinned, unpinned],
            onSetFavorite: { invoked.append(($0, $1)) })
        let item = try XCTUnwrap(
            fixture.menu.items.first { $0.title == "Unpin 2 Conversations" })
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        withExtendedLifetime(fixture.coordinator) {}

        XCTAssertEqual(invoked.count, 1)
        XCTAssertEqual(invoked.first?.0, actualTargets)
        XCTAssertEqual(invoked.first?.1, false)
    }

    func testEveryBulkMenuMutationUsesTheSameTargets() throws {
        var a = conversation("A", projectID: nil)
        var b = conversation("B", projectID: nil)
        a.favorite = true
        b.favorite = true
        a.unread = true
        let targets: Set<UUID> = [a.id, b.id]
        var invocations: [(String, Set<UUID>)] = []
        let fixture = menu(
            clicked: a,
            targets: targets,
            conversations: [a, b],
            onSetFavorite: { ids, _ in invocations.append(("favorite", ids)) },
            onMarkRead: { invocations.append(("read", $0)) },
            onMarkUnread: { invocations.append(("unread", $0)) },
            onMoveToNewProject: { invocations.append(("move", $0)) },
            onDelete: { invocations.append(("delete", $0)) })

        let items = [
            try XCTUnwrap(fixture.menu.items.first { $0.title.hasPrefix("Unpin") }),
            try XCTUnwrap(fixture.menu.items.first { $0.title.hasPrefix("Mark 2 as Read") }),
            try XCTUnwrap(fixture.menu.items.first { $0.title.hasPrefix("Mark 2 as Unread") }),
            try XCTUnwrap(fixture.menu.items.first { $0.title.hasPrefix("Delete") }),
            try XCTUnwrap(
                fixture.menu.items.first { $0.title.hasPrefix("Move") }?.submenu?.items.first {
                    $0.title == "New Workspace…"
                }),
        ]
        XCTAssertTrue(items[1].isEnabled)
        XCTAssertTrue(items[2].isEnabled)
        for item in items {
            let action = try XCTUnwrap(item.action)
            XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        }
        withExtendedLifetime(fixture.coordinator) {}

        XCTAssertEqual(Set(invocations.map(\.0)), ["favorite", "read", "unread", "move", "delete"])
        XCTAssertTrue(invocations.allSatisfy { $0.1 == targets })
    }
}

/// The artifact browser reaches the same batch move through its own Finder-like selection. These
/// assert the two surfaces agree about what a right-click targets, so a fix on one side cannot leave
/// the other moving a single row.
final class ArtifactBulkActionTargetTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    private func selection(_ ids: [UUID], ordered: [UUID]) -> ArtifactListSelection {
        var selection = ArtifactListSelection()
        for (index, id) in ids.enumerated() {
            selection.select(id, orderedIDs: ordered, extending: index > 0, range: false)
        }
        return selection
    }

    func testRightClickInsideAMultiSelectionTargetsEveryArtifact() {
        let selection = selection([a, b, c], ordered: [a, b, c])
        XCTAssertEqual(selection.actionIDs(for: a), [a, b, c])
        XCTAssertEqual(selection.actionIDs(for: b), [a, b, c])
    }

    func testRightClickOutsideTheSelectionTargetsOnlyTheClickedArtifact() {
        let selection = selection([a, b], ordered: [a, b, c])
        XCTAssertEqual(selection.actionIDs(for: c), [c])
    }

    /// Both browsers resolve targets the same way, so the same click must produce the same set on
    /// either side of the app.
    func testArtifactAndConversationTargetingAgree() {
        let artifacts = selection([a, b, c], ordered: [a, b, c])
        XCTAssertEqual(
            artifacts.actionIDs(for: b),
            ConversationBulkAction.targets(clicked: b, selection: [a, b, c]))
        XCTAssertEqual(
            selection([a, b], ordered: [a, b, c]).actionIDs(for: c),
            ConversationBulkAction.targets(clicked: c, selection: [a, b]))
    }

    /// A bulk move reveals one stable artifact afterwards; depending on Set iteration order would
    /// land the user on a different row run to run.
    func testBulkMoveRevealIsStableAcrossSetOrdering() {
        let ids: Set<UUID> = [a, b, c]
        let expected = ids.min { $0.uuidString < $1.uuidString }
        for _ in 0..<8 {
            XCTAssertEqual(
                ArtifactMoveRevealPolicy.artifactID(
                    after: .moved(conversations: 0, artifacts: 3),
                    moving: ids),
                expected)
        }
        XCTAssertNil(
            ArtifactMoveRevealPolicy.artifactID(after: .busy, moving: ids),
            "a refused move must not navigate anywhere")
    }
}
