import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

final class ConversationPinnedDropTests: XCTestCase {
    private func rows(pinned: [UUID], unpinned: [UUID]) -> [ConvRow] {
        var rows: [ConvRow] = []
        if !pinned.isEmpty {
            rows.append(.header(.pinned))
            rows.append(contentsOf: pinned.map(ConvRow.conversation))
        }
        if !unpinned.isEmpty {
            rows.append(.header(.today))
            rows.append(contentsOf: unpinned.map(ConvRow.conversation))
        }
        return rows
    }

    private func proposal(
        pinned: [UUID],
        unpinned: [UUID],
        dragged: Set<UUID>,
        row: Int,
        operation: NSTableView.DropOperation
    ) -> ConversationReorderProposal? {
        ConversationReorderProposal.resolve(
            rows: rows(pinned: pinned, unpinned: unpinned),
            favoriteIDs: Set(pinned),
            draggedIDs: dragged,
            proposedRow: row,
            operation: operation)
    }

    func testRowBodyDropMovesPinnedConversationAfterLowerTarget() throws {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let ordinary = UUID()

        let resolved = try XCTUnwrap(proposal(
            pinned: [first, second, third],
            unpinned: [ordinary],
            dragged: [first],
            row: 3,
            operation: .on))

        XCTAssertEqual(resolved.aboveTableRow, 4)
        XCTAssertEqual(resolved.intent.orderedIDs, [second, third, first, ordinary])
        XCTAssertEqual(resolved.intent.pinningIDs, [first])
        XCTAssertTrue(resolved.intent.unpinningIDs.isEmpty)
    }

    func testRowBodyDropMovesPinnedConversationBeforeHigherTarget() throws {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let ordinary = UUID()

        let resolved = try XCTUnwrap(proposal(
            pinned: [first, second, third],
            unpinned: [ordinary],
            dragged: [third],
            row: 1,
            operation: .on))

        XCTAssertEqual(resolved.aboveTableRow, 1)
        XCTAssertEqual(resolved.intent.orderedIDs, [third, first, second, ordinary])
        XCTAssertEqual(resolved.intent.pinningIDs, [third])
        XCTAssertTrue(resolved.intent.unpinningIDs.isEmpty)
    }

    func testDroppingUnpinnedConversationOnPinnedRowPinsAtDirectionalInsertion() throws {
        let firstPinned = UUID()
        let secondPinned = UUID()
        let dragged = UUID()
        let remaining = UUID()

        let resolved = try XCTUnwrap(proposal(
            pinned: [firstPinned, secondPinned],
            unpinned: [dragged, remaining],
            dragged: [dragged],
            row: 2,
            operation: .on))

        XCTAssertEqual(resolved.aboveTableRow, 2)
        XCTAssertEqual(
            resolved.intent.orderedIDs,
            [firstPinned, dragged, secondPinned, remaining])
        XCTAssertEqual(resolved.intent.pinningIDs, [dragged])
        XCTAssertTrue(resolved.intent.unpinningIDs.isEmpty)
    }

    func testMixedMultirowDragIntoPinnedCarriesDesiredStateInVisualOrder() throws {
        let firstPinned = UUID()
        let draggedPinned = UUID()
        let firstOrdinary = UUID()
        let secondOrdinary = UUID()
        let remainingOrdinary = UUID()

        let resolved = try XCTUnwrap(proposal(
            pinned: [firstPinned, draggedPinned],
            unpinned: [firstOrdinary, secondOrdinary, remainingOrdinary],
            dragged: [draggedPinned, firstOrdinary, secondOrdinary],
            row: 1,
            operation: .above))

        XCTAssertEqual(
            resolved.intent.orderedIDs,
            [draggedPinned, firstOrdinary, secondOrdinary, firstPinned, remainingOrdinary])
        XCTAssertEqual(
            resolved.intent.pinningIDs,
            [draggedPinned, firstOrdinary, secondOrdinary])
        XCTAssertTrue(resolved.intent.unpinningIDs.isEmpty)
    }

    func testRowBodyDropMovesContiguousPinnedSelectionAfterLowerTarget() throws {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()
        let ordinary = UUID()

        let resolved = try XCTUnwrap(proposal(
            pinned: [first, second, third, fourth],
            unpinned: [ordinary],
            dragged: [first, second],
            row: 4,
            operation: .on))

        XCTAssertEqual(resolved.aboveTableRow, 5)
        XCTAssertEqual(resolved.intent.orderedIDs, [third, fourth, first, second, ordinary])
        XCTAssertEqual(resolved.intent.pinningIDs, [first, second])
        XCTAssertTrue(resolved.intent.unpinningIDs.isEmpty)
    }

    func testPinnedHeaderAndInsertionLinesRetainExactPinnedPositions() throws {
        let firstPinned = UUID()
        let secondPinned = UUID()
        let dragged = UUID()

        let atHeader = try XCTUnwrap(proposal(
            pinned: [firstPinned, secondPinned],
            unpinned: [dragged],
            dragged: [dragged],
            row: 0,
            operation: .on))
        let atEnd = try XCTUnwrap(proposal(
            pinned: [firstPinned, secondPinned],
            unpinned: [dragged],
            dragged: [dragged],
            row: 3,
            operation: .above))

        XCTAssertEqual(atHeader.aboveTableRow, 1)
        XCTAssertEqual(atHeader.intent.orderedIDs, [dragged, firstPinned, secondPinned])
        XCTAssertEqual(atEnd.intent.orderedIDs, [firstPinned, secondPinned, dragged])
        XCTAssertEqual(atHeader.intent.pinningIDs, [dragged])
        XCTAssertEqual(atEnd.intent.pinningIDs, [dragged])
        XCTAssertTrue(atHeader.intent.unpinningIDs.isEmpty)
        XCTAssertTrue(atEnd.intent.unpinningIDs.isEmpty)
    }

    func testAllPinnedListAcceptsTrailingInsertionLine() throws {
        let first = UUID()
        let second = UUID()

        let resolved = try XCTUnwrap(proposal(
            pinned: [first, second],
            unpinned: [],
            dragged: [first],
            row: 3,
            operation: .above))

        XCTAssertEqual(resolved.intent.orderedIDs, [second, first])
        XCTAssertEqual(resolved.intent.pinningIDs, [first])
        XCTAssertTrue(resolved.intent.unpinningIDs.isEmpty)
    }

    func testInertDropCarriesDesiredStateWithoutClaimingAnOrderChange() throws {
        let first = UUID()
        let second = UUID()
        let ordinary = UUID()

        let atCurrentPosition = try XCTUnwrap(proposal(
            pinned: [first, second],
            unpinned: [ordinary],
            dragged: [first],
            row: 1,
            operation: .above))
        let onHeader = try XCTUnwrap(proposal(
            pinned: [first, second],
            unpinned: [ordinary],
            dragged: [first],
            row: 0,
            operation: .on))

        for resolved in [atCurrentPosition, onHeader] {
            XCTAssertFalse(resolved.intent.orderChanged)
            XCTAssertEqual(resolved.intent.orderedIDs, [first, second, ordinary])
            XCTAssertEqual(resolved.intent.pinningIDs, [first])
            XCTAssertTrue(resolved.intent.unpinningIDs.isEmpty)
        }
    }

    func testDroppingPinnedConversationOnDatedRowUnpinsIt() throws {
        let firstPinned = UUID()
        let remainingPinned = UUID()
        let firstOrdinary = UUID()
        let secondOrdinary = UUID()

        let resolved = try XCTUnwrap(proposal(
            pinned: [firstPinned, remainingPinned],
            unpinned: [firstOrdinary, secondOrdinary],
            dragged: [firstPinned],
            row: 4,
            operation: .on))

        XCTAssertEqual(resolved.aboveTableRow, 5)
        XCTAssertEqual(
            resolved.intent.orderedIDs,
            [remainingPinned, firstOrdinary, firstPinned, secondOrdinary])
        XCTAssertTrue(resolved.intent.pinningIDs.isEmpty)
        XCTAssertEqual(resolved.intent.unpinningIDs, [firstPinned])
    }

    func testMixedDragOutCarriesDesiredStateAndPreservesVisualOrder() throws {
        let draggedPinned = UUID()
        let remainingPinned = UUID()
        let draggedOrdinary = UUID()
        let targetOrdinary = UUID()

        let resolved = try XCTUnwrap(proposal(
            pinned: [draggedPinned, remainingPinned],
            unpinned: [draggedOrdinary, targetOrdinary],
            dragged: [draggedPinned, draggedOrdinary],
            row: 5,
            operation: .on))

        XCTAssertEqual(resolved.aboveTableRow, 6)
        XCTAssertEqual(
            resolved.intent.orderedIDs,
            [remainingPinned, targetOrdinary, draggedPinned, draggedOrdinary])
        XCTAssertTrue(resolved.intent.pinningIDs.isEmpty)
        XCTAssertEqual(resolved.intent.unpinningIDs, [draggedPinned, draggedOrdinary])
    }

    func testDatedRowsCannotBeManuallyReorderedWithoutPinnedBoundaryCrossing() {
        let pinned = UUID()
        let firstOrdinary = UUID()
        let secondOrdinary = UUID()

        XCTAssertNil(proposal(
            pinned: [pinned],
            unpinned: [firstOrdinary, secondOrdinary],
            dragged: [firstOrdinary],
            row: 4,
            operation: .on))
        XCTAssertNil(ConversationReorderProposal.resolve(
            rows: rows(pinned: [], unpinned: [firstOrdinary, secondOrdinary]),
            favoriteIDs: [],
            draggedIDs: [firstOrdinary],
            proposedRow: 2,
            operation: .on))
    }

    func testAmbiguousSelectedAndStaleRowBodyDropsAreRejected() {
        let first = UUID()
        let middle = UUID()
        let last = UUID()
        let ordinary = UUID()

        XCTAssertNil(proposal(
            pinned: [first, middle, last],
            unpinned: [ordinary],
            dragged: [first, last],
            row: 2,
            operation: .on),
            "a target inside a noncontiguous selection has no directional interpretation")
        XCTAssertNil(proposal(
            pinned: [first, middle, last],
            unpinned: [ordinary],
            dragged: [middle],
            row: 2,
            operation: .on),
            "dropping on a selected row is a no-op, not a new position")
        XCTAssertNil(proposal(
            pinned: [first, middle, last],
            unpinned: [ordinary],
            dragged: [UUID()],
            row: 1,
            operation: .on),
            "a stale same-table payload must not reorder only the ids still visible")
    }

    func testDateHeadersRemainNonContainerDropTargets() {
        let pinned = UUID()
        let ordinary = UUID()

        XCTAssertNil(proposal(
            pinned: [pinned],
            unpinned: [ordinary],
            dragged: [pinned],
            row: 2,
            operation: .on))
    }

    func testUnpinnedConversationReturnsToItsTruthfulDateSection() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let oldDate = now.addingTimeInterval(-40 * 24 * 60 * 60)
        var oldPinned = conversation(
            id: UUID(),
            title: "Old pinned",
            favorite: true,
            updatedAt: oldDate)
        var today = conversation(
            id: UUID(),
            title: "Today",
            favorite: false,
            updatedAt: now)

        let resolved = try XCTUnwrap(proposal(
            pinned: [oldPinned.id],
            unpinned: [today.id],
            dragged: [oldPinned.id],
            row: 3,
            operation: .on))
        XCTAssertEqual(resolved.intent.unpinningIDs, [oldPinned.id])

        for (index, id) in resolved.intent.orderedIDs.enumerated() {
            if id == oldPinned.id {
                oldPinned.favorite = false
                oldPinned.sortIndex = index
            } else if id == today.id {
                today.sortIndex = index
            }
        }
        let settledRows = buildConversationRows(
            [ConversationSummary(today), ConversationSummary(oldPinned)],
            now: now)

        XCTAssertEqual(settledRows, [
            .header(.today),
            .conversation(today.id),
            .header(.older),
            .conversation(oldPinned.id),
        ])
        XCTAssertEqual(oldPinned.updatedAt, oldDate)
    }

    @MainActor
    func testCoordinatorValidationAndAcceptanceShareTheSameNormalizedProposal() throws {
        let first = UUID()
        let second = UUID()
        let ordinary = UUID()
        let conversations = [
            conversation(id: first, title: "First", favorite: true),
            conversation(id: second, title: "Second", favorite: true),
            conversation(id: ordinary, title: "Ordinary", favorite: false),
        ]
        var applied: [ConversationReorderIntent] = []
        let table = ConversationTable(
            conversations: conversations.map(ConversationSummary.init),
            selection: .constant([first]),
            scale: 1,
            active: ActiveWorkspace(
                productAccessRequest: { true },
                whenProductReady: { $0() }),
            now: Date(),
            onOpenInWindow: { _ in },
            onOpenInTab: { _ in },
            onDelete: { _ in },
            onReorder: { applied.append($0) },
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
            editingID: .constant(nil),
            editText: .constant(""),
            onCommitRename: { _ in })
        let coordinator = table.makeCoordinator()
        coordinator.rows = rows(pinned: [first, second], unpinned: [ordinary])

        let validated = try XCTUnwrap(coordinator.localReorderProposal(
            dragging: [first],
            proposedRow: 2,
            operation: .on))
        let accepted = try XCTUnwrap(coordinator.acceptLocalReorder(
            dragging: [first],
            proposedRow: validated.aboveTableRow,
            operation: .above))

        XCTAssertEqual(accepted, validated)
        XCTAssertEqual(applied, [validated.intent])
    }

    private func conversation(
        id: UUID,
        title: String,
        favorite: Bool,
        updatedAt: Date = Date()
    ) -> Conversation {
        Conversation(
            id: id,
            title: title,
            cwd: "",
            sdkSessionId: nil,
            messages: [],
            updatedAt: updatedAt,
            favorite: favorite)
    }
}
