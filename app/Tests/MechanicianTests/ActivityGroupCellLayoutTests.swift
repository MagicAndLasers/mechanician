import AppKit
import XCTest
@testable import Mechanician

@MainActor
final class ActivityGroupCellLayoutTests: XCTestCase {
    func testGroupHeaderCanBeConfiguredAtZeroSizeThenLaidOutAndReused() throws {
        _ = NSApplication.shared
        let cell = ActivityGroupHeaderCell(frame: .zero)
        let group = AppKitActivityGroup(
            id: AnyHashable("activity-group"),
            actions: [
                action("failed", state: .failed),
                action("stopped", state: .stopped),
                action("refused", state: .refused, isSuperseded: true),
            ],
            chatScale: 1)

        configure(cell, group: group, revision: 1, expanded: false)
        try assertZeroSizeBoundaryIsConstraintSafe(in: cell)

        cell.frame = NSRect(x: 0, y: 0, width: 600, height: 50)
        cell.layoutSubtreeIfNeeded()
        try assertHeaderInsets(in: cell, leading: 10, trailing: 10, top: 6, bottom: 6)

        cell.frame = .zero
        cell.layoutSubtreeIfNeeded()
        configure(cell, group: group, revision: 2, expanded: true)
        try assertZeroSizeBoundaryIsConstraintSafe(in: cell)

        cell.frame = NSRect(x: 0, y: 0, width: 420, height: 38)
        cell.layoutSubtreeIfNeeded()
        try assertHeaderInsets(in: cell, leading: 10, trailing: 10, top: 6, bottom: 6)
    }

    func testActionHeaderCanBeConfiguredAtZeroSizeThenLaidOutAndReused() throws {
        _ = NSApplication.shared
        let cell = ActivityActionCell(frame: .zero)
        let first = action("first", state: .running)

        configure(cell, action: first, revision: 1, expanded: false)
        try assertZeroSizeBoundaryIsConstraintSafe(in: cell)

        cell.frame = NSRect(x: 0, y: 0, width: 600, height: 44)
        cell.layoutSubtreeIfNeeded()
        try assertHeaderInsets(in: cell, leading: 29, trailing: 10, top: 5, bottom: 5)

        cell.frame = .zero
        cell.layoutSubtreeIfNeeded()
        configure(
            cell,
            action: action("replacement", state: .succeeded, isSuperseded: true),
            revision: 2,
            expanded: true)
        try assertZeroSizeBoundaryIsConstraintSafe(in: cell)

        cell.frame = NSRect(x: 0, y: 0, width: 420, height: 32)
        cell.layoutSubtreeIfNeeded()
        try assertHeaderInsets(in: cell, leading: 29, trailing: 10, top: 5, bottom: 5)
    }

    private func configure(
        _ cell: ActivityGroupHeaderCell,
        group: AppKitActivityGroup,
        revision: Int,
        expanded: Bool
    ) {
        cell.setGroup(
            group,
            id: group.id,
            revision: revision,
            expanded: expanded,
            topPadding: 0,
            onToggle: {},
            onMeasuredHeight: { _, _, _ in })
    }

    private func configure(
        _ cell: ActivityActionCell,
        action: AppKitActivityAction,
        revision: Int,
        expanded: Bool
    ) {
        cell.setAction(
            action,
            presentationID: AnyHashable("action-presentation"),
            revision: revision,
            title: activityActionTitle(action),
            expanded: expanded,
            isLast: true,
            chatScale: 1,
            existingMeasuredHeight: nil,
            detail: nil,
            onToggle: {},
            onMeasuredHeight: { _, _, _ in })
    }

    /// A table cell is legitimately born at zero size and can return there while being reused.
    /// The stack's far-edge pins must be breakable during that transient state, or AppKit breaks a
    /// required autoresizing-mask width/height constraint and emits one warning per realized row.
    private func assertZeroSizeBoundaryIsConstraintSafe(
        in cell: NSTableCellView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let button = try XCTUnwrap(
            descendants(of: cell).compactMap { $0 as? NSButton }.first,
            file: file,
            line: line)
        let header = try XCTUnwrap(button.superview, file: file, line: line)
        let row = try XCTUnwrap(
            header.subviews.compactMap { $0 as? NSStackView }.first,
            file: file,
            line: line)
        let farEdgePins = header.constraints.filter { constraint in
            guard constraint.firstItem as AnyObject? === row
                    || constraint.secondItem as AnyObject? === row else { return false }
            return constraint.firstAttribute == .trailing
                || constraint.secondAttribute == .trailing
                || constraint.firstAttribute == .bottom
                || constraint.secondAttribute == .bottom
        }

        XCTAssertEqual(farEdgePins.count, 2, file: file, line: line)
        XCTAssertTrue(
            farEdgePins.allSatisfy { $0.priority < .required },
            "A zero-sized reusable header must not require its content to fit its far edges.",
            file: file,
            line: line)
    }

    private func assertHeaderInsets(
        in cell: NSTableCellView,
        leading: CGFloat,
        trailing: CGFloat,
        top: CGFloat,
        bottom: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let button = try XCTUnwrap(
            descendants(of: cell).compactMap { $0 as? NSButton }.first,
            file: file,
            line: line)
        let header = try XCTUnwrap(button.superview, file: file, line: line)
        let row = try XCTUnwrap(
            header.subviews.compactMap { $0 as? NSStackView }.first,
            file: file,
            line: line)

        XCTAssertFalse(header.hasAmbiguousLayout, file: file, line: line)
        XCTAssertFalse(row.hasAmbiguousLayout, file: file, line: line)
        XCTAssertEqual(row.frame.minX, leading, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(header.bounds.maxX - row.frame.maxX, trailing, accuracy: 0.5,
                       file: file, line: line)
        XCTAssertEqual(row.frame.minY, top, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(header.bounds.maxY - row.frame.maxY, bottom, accuracy: 0.5,
                       file: file, line: line)
    }

    private func action(
        _ id: String,
        state: AppKitActivityAction.State,
        isSuperseded: Bool = false
    ) -> AppKitActivityAction {
        AppKitActivityAction(
            id: AnyHashable(id),
            sourceIndex: 0,
            toolName: "Bash",
            rawInput: #"{"command":"swift test"}"#,
            state: state,
            isSuperseded: isSuperseded)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
