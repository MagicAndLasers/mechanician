import AppKit
import XCTest
@testable import Mechanician

final class ResponsiveConversationLayoutTests: XCTestCase {
    func testHiddenInspectorGivesTheChatAllAvailableWidth() {
        let layout = DetailColumnLayout.resolve(
            availableWidth: 680,
            preferredInspectorWidth: 360,
            showsInspector: false)

        XCTAssertEqual(layout.chatWidth, 680)
        XCTAssertEqual(layout.inspectorWidth, 0)
    }

    func testPreferredInspectorWidthIsPreservedWhenBothColumnsFit() {
        let layout = DetailColumnLayout.resolve(
            availableWidth: 680,
            preferredInspectorWidth: 360,
            showsInspector: true)

        XCTAssertEqual(layout.chatWidth, 319)
        XCTAssertEqual(layout.inspectorWidth, 360)
        XCTAssertEqual(
            layout.chatWidth + DetailColumnLayout.resizeSeamWidth + layout.inspectorWidth,
            680)
    }

    func testInspectorYieldsBeforeChatAtTheMinimumWindowWidth() {
        let layout = DetailColumnLayout.resolve(
            availableWidth: 480,
            preferredInspectorWidth: 520,
            showsInspector: true)

        XCTAssertEqual(layout.chatWidth, DetailColumnLayout.minimumChatWidth)
        XCTAssertEqual(layout.inspectorWidth, 179)
        XCTAssertFalse(layout.inspectorIsResizable)
        XCTAssertEqual(
            layout.chatWidth + DetailColumnLayout.resizeSeamWidth + layout.inspectorWidth,
            480)
    }

    func testInspectorResizeHandleAppearsAtItsMinimumUsableWidth() {
        let layout = DetailColumnLayout.resolve(
            availableWidth: 481,
            preferredInspectorWidth: 520,
            showsInspector: true)

        XCTAssertEqual(layout.inspectorWidth, DetailColumnLayout.minimumInspectorWidth)
        XCTAssertTrue(layout.inspectorIsResizable)
        XCTAssertFalse(
            DetailColumnLayout.hasInspectorResizeRange(availableWidth: 481),
            "an equal lower and upper bound must not advertise an inert resize cursor")
        XCTAssertTrue(DetailColumnLayout.hasInspectorResizeRange(availableWidth: 482))
    }

    func testInspectorReturnsToPreferredWidthAfterWindowGrows() {
        let narrow = DetailColumnLayout.resolve(
            availableWidth: 480,
            preferredInspectorWidth: 420,
            showsInspector: true)
        let wide = DetailColumnLayout.resolve(
            availableWidth: 900,
            preferredInspectorWidth: 420,
            showsInspector: true)

        XCTAssertEqual(narrow.inspectorWidth, 179)
        XCTAssertEqual(wide.inspectorWidth, 420)
        XCTAssertEqual(wide.chatWidth, 479)
    }

    func testColumnResolverHandlesLessThanTheProtectedChatWidth() {
        let layout = DetailColumnLayout.resolve(
            availableWidth: 240,
            preferredInspectorWidth: 360,
            showsInspector: true)

        XCTAssertEqual(layout.chatWidth, 239)
        XCTAssertEqual(layout.inspectorWidth, 0)
        XCTAssertEqual(
            layout.chatWidth + DetailColumnLayout.resizeSeamWidth,
            240)
    }

    func testResponsiveInspectorDragShrinksFromItsDisplayedEdgeWithoutADeadZone() {
        let preferred = ResponsiveResizeDrag.preferredSize(
            preferredSize: 520,
            displayedSize: 299,
            translation: 10,
            range: 180...520)

        XCTAssertEqual(preferred, 289)
    }

    func testResponsiveInspectorDragPreservesPreferenceForImpossibleGrowth() {
        let preferred = ResponsiveResizeDrag.preferredSize(
            preferredSize: 520,
            displayedSize: 299,
            translation: -20,
            range: 180...520)

        XCTAssertEqual(preferred, 520)
    }

    func testUnconstrainedInspectorDragUsesOrdinaryVisibleEdgeSemantics() {
        XCTAssertEqual(
            ResponsiveResizeDrag.preferredSize(
                preferredSize: 360,
                displayedSize: 360,
                translation: 20,
                range: 180...520),
            340)
        XCTAssertEqual(
            ResponsiveResizeDrag.preferredSize(
                preferredSize: 360,
                displayedSize: 360,
                translation: -20,
                range: 180...520),
            380)
    }

    func testControlBarTiersExposeTheirResponsiveBehavior() {
        XCTAssertFalse(ControlBarTier.full.stacksRows)
        XCTAssertFalse(ControlBarTier.full.usesCompactControls)

        XCTAssertTrue(ControlBarTier.wrapped.stacksRows)
        XCTAssertFalse(ControlBarTier.wrapped.usesCompactControls)

        XCTAssertTrue(ControlBarTier.compact.stacksRows)
        XCTAssertTrue(ControlBarTier.compact.usesCompactControls)
    }

    func testCompactControlBarFitsTheProtectedChatWidthWithoutTextOrBadge() {
        XCTAssertEqual(CompactControlBarContract.horizontalPadding, 12)
        XCTAssertLessThanOrEqual(
            CompactControlBarContract.requiredWidth,
            DetailColumnLayout.minimumChatWidth)

        var modelPresentation = ConversationControlPopoverState()
        modelPresentation.present(title: "Claude Opus 4.1")
        XCTAssertEqual(
            modelPresentation.triggerTitle(current: "Claude Opus 4.1", compact: true),
            "")
        XCTAssertNil(
            ConversationPermissionTriggerPresentation.badge(
                appliesNextTurn: true,
                compact: true))
        XCTAssertEqual(
            ConversationPermissionTriggerPresentation.badge(
                appliesNextTurn: true,
                compact: false),
            "NEXT")
    }

    func testProviderWarningUsesAReadableIconTarget() {
        XCTAssertEqual(ProviderWarningPresentation.iconSize, 16)
        XCTAssertEqual(ProviderWarningPresentation.frameSize, 20)
        XCTAssertGreaterThan(
            ProviderWarningPresentation.frameSize,
            ProviderWarningPresentation.iconSize)
    }

    // MARK: - No fixed cap

    /// David: *"can we just let all inspector panes expand more fully like the memory window. I see
    /// no advantage in preventing the pane from getting wider."*
    ///
    /// The 520 cap, and the brief per-tab version of it, are both gone. The only limit left is the
    /// one that protects something: the composer's floor.
    func testAnyPaneMayUseTheRoomTheWindowHas() {
        let wide = DetailColumnLayout.resolve(
            availableWidth: 1600, preferredInspectorWidth: 900, showsInspector: true)
        XCTAssertEqual(wide.inspectorWidth, 900, "no tab is capped at an arbitrary width any more")
        XCTAssertEqual(wide.chatWidth, 1600 - 900 - DetailColumnLayout.resizeSeamWidth)
    }

    /// The constraint that remains, and the reason it is the only one worth keeping.
    func testTheComposerKeepsItsFloorHoweverFarTheHandleIsDragged() {
        let cramped = DetailColumnLayout.resolve(
            availableWidth: 900, preferredInspectorWidth: 5000, showsInspector: true)
        XCTAssertGreaterThanOrEqual(cramped.chatWidth, DetailColumnLayout.minimumChatWidth)
        XCTAssertEqual(
            cramped.inspectorWidth,
            900 - DetailColumnLayout.minimumChatWidth - DetailColumnLayout.resizeSeamWidth)
    }

    /// The drag range is derived from the window, so it stops exactly where the composer's floor is.
    func testTheDragRangeStopsWhereTheComposerFloorIs() {
        XCTAssertEqual(
            DetailColumnLayout.maximumInspectorWidth(availableWidth: 1600),
            1600 - DetailColumnLayout.minimumChatWidth - DetailColumnLayout.resizeSeamWidth)
        XCTAssertEqual(
            DetailColumnLayout.maximumInspectorWidth(availableWidth: 200),
            DetailColumnLayout.minimumInspectorWidth,
            "a window too narrow for both never returns a nonsense negative bound")
    }

    /// THE TRAP THIS PINS: the drag handle's range was two hard-coded literals rather than the
    /// constants beside it, so raising the cap changed nothing and the tab still would not widen.
    func testTheResizeBoundsComeFromTheConstantsAndNotALiteral() throws {
        let source = try String(
            contentsOfFile: #filePath
                .replacingOccurrences(
                    of: "Tests/MechanicianTests/ResponsiveConversationLayoutTests.swift",
                    with: "Sources/Mechanician/RootView.swift"),
            encoding: .utf8)
        XCTAssertFalse(
            source.contains("range: 180...520"),
            "the drag range must be derived from the constants and the window")
        XCTAssertTrue(source.contains("DetailColumnLayout.maximumInspectorWidth("))
    }
}

@MainActor
final class AppKitInspectorResizeHandleTests: XCTestCase {
    func testNoOpFrameAssignmentsDoNotRepublishTheWindowSeam() {
        _ = NSApplication.shared
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let handle = AppKitInspectorResizeHandleView(
            frame: NSRect(
                x: 95,
                y: 0,
                width: AppKitInspectorResizeHandle.hitSlabWidth,
                height: 100))
        var published: [CGFloat?] = []
        handle.onSeamMove = { published.append($0) }
        container.addSubview(handle)
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = container
        defer { window.contentView = nil }

        XCTAssertEqual(published.compactMap { $0 }, [100])
        published.removeAll()

        handle.setFrameOrigin(handle.frame.origin)
        handle.setFrameSize(handle.frame.size)
        handle.setFrameSize(NSSize(width: handle.frame.width, height: 99))
        handle.setFrameOrigin(NSPoint(x: 95.01, y: 0))
        XCTAssertTrue(published.isEmpty)

        handle.setFrameOrigin(NSPoint(x: 96, y: 0))
        handle.setFrameOrigin(NSPoint(x: 96, y: 0))
        XCTAssertEqual(published.compactMap { $0 }, [101])
    }

    func testDismantleDoesNotPublishSeamOrResizeCallbacks() {
        _ = NSApplication.shared
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let handle = AppKitInspectorResizeHandleView(
            frame: NSRect(x: 95, y: 0, width: 10, height: 100))
        var published: [CGFloat?] = []
        var resized: [Double] = []
        handle.onSeamMove = { published.append($0) }
        handle.configure(
            preferredSize: 360,
            displayedSize: 360,
            range: 180...520,
            onResize: { resized.append($0) })
        container.addSubview(handle)
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = container
        defer { window.contentView = nil }
        published.removeAll()

        AppKitInspectorResizeHandle.dismantleNSView(handle, coordinator: ())
        handle.removeFromSuperview()
        handle.setFrameOrigin(NSPoint(x: 96, y: 0))
        _ = handle.accessibilityPerformIncrement()

        XCTAssertTrue(published.isEmpty)
        XCTAssertTrue(resized.isEmpty)
    }

    func testInspectorToolbarFallsBackWithoutAVisibleResizeSeam() {
        XCTAssertEqual(
            WorkspaceToolbarController.inspectorToolbarButtonWindowX(
                showsInspector: true,
                inspectorIsFullWidth: false,
                seamX: 500),
            500 + InspectorToolbarRegionView.openLeadingInset)
        XCTAssertNil(
            WorkspaceToolbarController.inspectorToolbarButtonWindowX(
                showsInspector: false,
                inspectorIsFullWidth: false,
                seamX: 500),
            "a hidden inspector must ignore a stale handle position")
        XCTAssertNil(
            WorkspaceToolbarController.inspectorToolbarButtonWindowX(
                showsInspector: true,
                inspectorIsFullWidth: true,
                seamX: 500),
            "a full-width inspector has no seam even before AppKit dismantles its handle")
    }

    func testHitSlabOwnsPointsOnBothSidesOfTheVisibleSeam() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let handle = AppKitInspectorResizeHandleView(
            frame: NSRect(
                x: 95,
                y: 0,
                width: AppKitInspectorResizeHandle.hitSlabWidth,
                height: 100))
        container.addSubview(handle)

        XCTAssertIdentical(container.hitTest(NSPoint(x: 95.25, y: 50)), handle)
        XCTAssertIdentical(container.hitTest(NSPoint(x: 104.75, y: 50)), handle)
        XCTAssertEqual(handle.accessibilityRole(), .splitter)
        XCTAssertEqual(handle.accessibilityLabel(), "Resize inspector")
    }

    func testNativeDragStaysInWindowCoordinatesWhenLayoutMovesTheHandle() throws {
        let handle = AppKitInspectorResizeHandleView(
            frame: NSRect(x: 495, y: 0, width: 10, height: 100))
        var published: [Double] = []
        handle.configure(
            preferredSize: 360,
            displayedSize: 360,
            range: 180...520,
            onResize: { published.append($0) })

        handle.mouseDown(with: try mouseEvent(.leftMouseDown, windowX: 500))
        // Binding publication moves the divider itself. The gesture must still use the original
        // window-space press rather than interpreting this frame change as pointer movement.
        handle.frame.origin.x = 465
        handle.mouseDragged(with: try mouseEvent(.leftMouseDragged, windowX: 470))
        handle.mouseUp(with: try mouseEvent(.leftMouseUp, windowX: 470))

        XCTAssertEqual(published, [390])
    }

    func testAccessibilityIncrementAndDecrementResizeTheTrailingInspector() {
        let handle = AppKitInspectorResizeHandleView(frame: .zero)
        var published: [Double] = []
        handle.configure(
            preferredSize: 360,
            displayedSize: 360,
            range: 180...520,
            onResize: { published.append($0) })

        XCTAssertTrue(handle.accessibilityPerformIncrement())
        XCTAssertTrue(handle.accessibilityPerformDecrement())
        XCTAssertEqual(published, [370, 360])
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        windowX: CGFloat
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: windowX, y: 50),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0))
    }
}
