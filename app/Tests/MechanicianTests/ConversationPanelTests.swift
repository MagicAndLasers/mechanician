import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

final class ConversationPanelTests: XCTestCase {
    func testQuestionIndicatorIsExplicitAndRemainsVisibleOnSelectedRows() throws {
        XCTAssertEqual(
            ConversationRowPresentation.questionIndicatorSystemImage,
            "questionmark.circle.fill")
        XCTAssertTrue(
            ConversationRowPresentation.showsQuestionIndicator(
                awaitingQuestion: true, isSelected: false, isRunning: false))
        XCTAssertTrue(
            ConversationRowPresentation.showsQuestionIndicator(
                awaitingQuestion: true, isSelected: true, isRunning: true),
            "a selected, running row in a non-key window must still disclose its pending question")
        XCTAssertTrue(
            ConversationRowPresentation.showsQuestionIndicator(
                awaitingQuestion: true, isSelected: false, isRunning: true),
            "the running spinner must not displace the actionable question indicator")
        XCTAssertFalse(
            ConversationRowPresentation.showsQuestionIndicator(
                awaitingQuestion: false, isSelected: false, isRunning: true))

        let selected = try XCTUnwrap(
            NSColor(ConversationRowPresentation.questionIndicatorColor(isSelected: true))
                .usingColorSpace(.sRGB))
        XCTAssertEqual(selected.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(selected.greenComponent, 1, accuracy: 0.01)
        XCTAssertEqual(selected.blueComponent, 1, accuracy: 0.01)
    }

    func testConversationSelectionStaysAccentedAcrossWindowFocus() {
        XCTAssertTrue(
            ConversationRowPresentation.usesAccentSelection(windowIsKey: true),
            "moving focus from the sidebar into the composer must not turn its active route gray")
        XCTAssertTrue(
            ConversationRowPresentation.usesAccentSelection(windowIsKey: false),
            "comparing another window must not turn this workspace's active route gray")
    }

    func testSelectedConversationSpinnerUsesWhiteDotsWithoutABackplate() throws {
        let selected = try XCTUnwrap(
            ConversationRowPresentation.activitySpinnerColor(isSelected: true))
        let selectedColor = NSColor(selected).usingColorSpace(.sRGB)!
        XCTAssertEqual(selectedColor.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(selectedColor.greenComponent, 1, accuracy: 0.01)
        XCTAssertEqual(selectedColor.blueComponent, 1, accuracy: 0.01)
        XCTAssertNil(ConversationRowPresentation.activitySpinnerColor(isSelected: false))
        XCTAssertFalse(
            ConversationRowPresentation.activitySpinnerShowsGlow(isSelected: true),
            "white selected-row dots must stay separate instead of merging into a pale blob")
        XCTAssertTrue(
            ConversationRowPresentation.activitySpinnerShowsGlow(isSelected: false))
    }

    func testSelectedConversationSpinnerFillsStatusSlotWithoutOverflow() {
        let slot = ConversationRowPresentation.activityStatusSlotDiameter()
        let selected = ConversationRowPresentation.activitySpinnerDiameter(isSelected: true)
        let ordinary = ConversationRowPresentation.activitySpinnerDiameter(isSelected: false)
        let selectedGeometry = OrbitingDotsGeometry.fitted(
            to: selected,
            reservesGlow: false)

        XCTAssertEqual(slot, 20)
        XCTAssertEqual(selected, slot)
        XCTAssertEqual(ordinary, 13)
        XCTAssertLessThanOrEqual(
            selectedGeometry.maximumCorePaintedRadius,
            slot / 2,
            "the selected spinner's animated cores must remain inside its trailing slot")
        XCTAssertGreaterThan(
            selectedGeometry.coreDiameter,
            OrbitingDotsGeometry.fitted(to: ordinary).coreDiameter)
        XCTAssertGreaterThanOrEqual(
            selectedGeometry.coreDiameter,
            5.5,
            "each selected-row dot must read as a status mark rather than a subpixel speck")
        XCTAssertGreaterThanOrEqual(
            selectedGeometry.maximumCorePaintedRadius * 2,
            17,
            "hiding the halo must enlarge the visible mark, not leave a nominally 20pt spinner")

        let compactScale: CGFloat = 0.7
        XCTAssertEqual(
            ConversationRowPresentation.activityStatusSlotDiameter(scale: compactScale),
            14,
            accuracy: 0.001,
            "fixed status geometry must not outgrow a row when the app UI is scaled down")
    }

    func testConversationSelectionUsesAccessibleFixedAppBlueInBothAppearances() {
        let expectations: [(NSAppearance.Name, (CGFloat, CGFloat, CGFloat))] = [
            (.aqua, (0x24 / 255.0, 0x6F / 255.0, 0xC8 / 255.0)),
            (.darkAqua, (0x2B / 255.0, 0x70 / 255.0, 0xD1 / 255.0)),
        ]

        for (appearanceName, expected) in expectations {
            let appearance = NSAppearance(named: appearanceName)!
            let fill = resolve(
                ConversationRowPresentation.selectionFillColor,
                in: appearance)
            XCTAssertEqual(fill.redComponent, expected.0, accuracy: 0.005)
            XCTAssertEqual(fill.greenComponent, expected.1, accuracy: 0.005)
            XCTAssertEqual(fill.blueComponent, expected.2, accuracy: 0.005)
            XCTAssertGreaterThan(fill.blueComponent, fill.greenComponent)
            XCTAssertGreaterThanOrEqual(
                contrastWithWhite(fill),
                4.5,
                "selected-row white copy must remain legible in \(appearanceName.rawValue)")

            let secondary = composite(
                foreground: .white,
                opacity: ConversationRowPresentation.selectedSecondaryTextOpacity,
                over: fill)
            XCTAssertGreaterThanOrEqual(
                contrastBetween(secondary, fill),
                4.5,
                "selected-row metadata must remain legible in \(appearanceName.rawValue)")
        }
    }

    @MainActor
    func testSelectedNativeRowPaintsOneFullWidthBlueCapsule() throws {
        let nativeRow = SeparatorRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 62))
        nativeRow.appearance = NSAppearance(named: .aqua)
        nativeRow.isSelected = true
        nativeRow.selectionHighlightStyle = .regular
        XCTAssertEqual(nativeRow.selectionHighlightStyle, .none)

        let paintedRect = SeparatorRowView.selectionRect(in: nativeRow.bounds)
        XCTAssertEqual(paintedRect.minX, 3)
        XCTAssertEqual(paintedRect.maxX, 237)
        XCTAssertEqual(paintedRect.minY, 1)
        XCTAssertEqual(paintedRect.maxY, 61)

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 240,
            pixelsHigh: 62,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        nativeRow.draw(nativeRow.bounds)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let painted = try XCTUnwrap(
            bitmap.colorAt(x: 12, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        let expected = resolve(
            ConversationRowPresentation.selectionFillColor,
            in: NSAppearance(named: .aqua)!)
        XCTAssertEqual(painted.redComponent, expected.redComponent, accuracy: 0.01)
        XCTAssertEqual(painted.greenComponent, expected.greenComponent, accuracy: 0.01)
        XCTAssertEqual(painted.blueComponent, expected.blueComponent, accuracy: 0.01)
    }

    @MainActor
    func testConversationTableDisablesNativeSelectionAndSourceListGutters() {
        let nativeTable = ConversationNSTableView()
        nativeTable.style = .sourceList
        nativeTable.selectionHighlightStyle = .regular
        nativeTable.useAppOwnedSelectionAppearance()
        XCTAssertEqual(
            nativeTable.style,
            .plain,
            "source-list decoration must not cut pale gutters through the row-owned capsule")
        XCTAssertEqual(
            nativeTable.selectionHighlightStyle,
            .none,
            "AppKit must not paint a gray capsule around the row-owned blue selection")
    }

    @MainActor
    func testSelectAllVisibleConversationsSkipsSectionHeaders() {
        _ = NSApplication.shared
        let pinned = Conversation(
            title: "Pinned conversation",
            cwd: "",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date(),
            favorite: true)
        let regular = Conversation(
            title: "Regular conversation",
            cwd: "",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date())
        var table = ConversationTable(
            conversations: [ConversationSummary(pinned), ConversationSummary(regular)],
            selection: .constant([]),
            scale: 1,
            active: ActiveWorkspace(
                productAccessRequest: { true },
                whenProductReady: { $0() }),
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
            editingID: .constant(nil),
            editText: .constant(""),
            onCommitRename: { _ in })
        let coordinator = table.makeCoordinator()
        let nativeTable = ConversationNSTableView()
        nativeTable.addTableColumn(NSTableColumn(identifier: .init("conversation")))
        nativeTable.dataSource = coordinator
        nativeTable.delegate = coordinator
        coordinator.table = nativeTable
        coordinator.rows = [
            .header(.pinned),
            .conversation(pinned.id),
            .header(.today),
            .conversation(regular.id),
        ]
        nativeTable.reloadData()

        coordinator.selectAllVisibleConversations()

        XCTAssertEqual(nativeTable.selectedRowIndexes, IndexSet([1, 3]))
        XCTAssertEqual(
            coordinator.selectedConversationIDs(),
            [pinned.id, regular.id],
            "Select All must select visible conversations, never their group headings.")

        // The header menu crosses into the native table as a one-shot request. If SwiftUI redraws
        // for an unrelated reason afterwards, it must not silently re-select rows someone cleared.
        nativeTable.deselectAll(nil)
        table.selectAllVisibleRequest = 1
        coordinator.adopt(table)
        coordinator.performPendingSelectAllVisibleRequest()
        XCTAssertEqual(nativeTable.selectedRowIndexes, IndexSet([1, 3]))

        nativeTable.deselectAll(nil)
        coordinator.performPendingSelectAllVisibleRequest()
        XCTAssertTrue(nativeTable.selectedRowIndexes.isEmpty)
    }

    func testSwipeReadActionAlwaysDescribesTheStateItWillSet() {
        XCTAssertEqual(
            ConversationSwipePresentation.readActionTitle(unread: true),
            "Mark Read")
        XCTAssertEqual(
            ConversationSwipePresentation.readActionTitle(unread: false),
            "Mark Unread")
    }

    @MainActor
    func testSwipeActionsRenderTheirRetainedTitlesWithWhiteOriginalImages() throws {
        _ = NSApplication.shared
        let conversation = Conversation(
            title: "Pinned conversation",
            cwd: "",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date(),
            favorite: true,
            unread: false)
        let table = ConversationTable(
            conversations: [ConversationSummary(conversation)],
            selection: .constant([conversation.id]),
            scale: 1,
            active: ActiveWorkspace(
                productAccessRequest: { true },
                whenProductReady: { $0() }),
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
            editingID: .constant(nil),
            editText: .constant(""),
            onCommitRename: { _ in })
        let coordinator = table.makeCoordinator()
        coordinator.rows = [.conversation(conversation.id)]
        let nativeTable = ConversationNSTableView()

        let leading = coordinator.tableView(
            nativeTable,
            rowActionsForRow: 0,
            edge: .leading)
        let trailing = coordinator.tableView(
            nativeTable,
            rowActionsForRow: 0,
            edge: .trailing)

        XCTAssertEqual(leading.map(\.title), ["Unpin", "Mark Unread"])
        XCTAssertEqual(trailing.map(\.title), ["Delete"])
        for action in leading + trailing {
            let image = try XCTUnwrap(
                action.image,
                "\(action.title) must replace AppKit's dark title ink with app-owned white copy")
            XCTAssertFalse(image.isTemplate, "template images can be recoloured dark by AppKit")
            try assertWhiteInk(in: image, title: action.title)
        }
    }

    /// Lightening the violet is the obvious "make the pin pop" change and it silently makes the
    /// app-owned white label unreadable — the light sky blue used for the row's pin glyph measures
    /// 2.14:1 here. Keep the button above WCAG AA.
    func testPinSwipeFillCarriesWhiteLabelText() {
        XCTAssertGreaterThanOrEqual(
            contrastWithWhite(ConversationSwipePresentation.pinBackgroundColor),
            4.5,
            "the pin swipe action's white label must stay legible on its fill")
    }

    /// The `systemBlue` "Mark Unread" action is drawn immediately beside this one. A deep app-blue
    /// pin fill read as a single button split in half, which is why the fill is the brand violet.
    /// Anything that drifts back toward blue reintroduces that.
    func testPinSwipeFillStaysDistinctFromItsNeighbour() {
        let fill = ConversationSwipePresentation.pinBackgroundColor.usingColorSpace(.sRGB)!
        let neighbour = NSColor.systemBlue.usingColorSpace(.sRGB)!
        var separation = abs(Double(fill.hueComponent) - Double(neighbour.hueComponent))
        separation = min(separation, 1 - separation)   // hue is a circle
        XCTAssertGreaterThan(
            separation,
            0.08,
            "the pin action must not read as a second shade of the Mark Unread blue")
    }

    /// The fill is the Magic & Lasers beam violet, deepened only as far as white text requires. If
    /// it drifts off that hue it stops being the brand colour and becomes an arbitrary purple.
    func testPinSwipeFillStaysOnTheBrandVioletHue() {
        let fill = ConversationSwipePresentation.pinBackgroundColor.usingColorSpace(.sRGB)!
        let beam = MagicBeam.components[0]   // violet
        let brand = NSColor(srgbRed: beam.r, green: beam.g, blue: beam.b, alpha: 1)
        XCTAssertEqual(
            Double(fill.hueComponent),
            Double(brand.hueComponent),
            accuracy: 0.03,
            "the pin action should stay on the Magic & Lasers violet hue")
    }

    /// The glyph is a tinted icon on a neutral row, not white-on-colour, so it is judged against the
    /// row behind it in each appearance rather than against white.
    func testPinGlyphIsVisibleAgainstItsRowInBothAppearances() {
        for (appearance, row) in [
            (NSAppearance(named: .aqua)!, NSColor.white),
            (NSAppearance(named: .darkAqua)!,
             NSColor(srgbRed: 0.137, green: 0.141, blue: 0.153, alpha: 1)),
        ] {
            XCTAssertGreaterThanOrEqual(
                contrastBetween(resolve(.nPinned, in: appearance), row),
                3.0,
                "the pin glyph must stay visible on its own row background")
        }
    }

    /// A dynamic `NSColor` resolves against the appearance current at the moment its components are
    /// read, not when the value is captured — so the conversion has to happen inside the block.
    private func resolve(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var out = color
        appearance.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    private func assertWhiteInk(
        in image: NSImage,
        title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let pixelsWide = max(1, Int(ceil(image.size.width * 2)))
        let pixelsHigh = max(1, Int(ceil(image.size.height * 2)))
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelsWide,
                pixelsHigh: pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0),
            file: file,
            line: line)
        bitmap.size = image.size
        let context = try XCTUnwrap(
            NSGraphicsContext(bitmapImageRep: bitmap),
            file: file,
            line: line)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(origin: .zero, size: image.size),
            from: .zero,
            operation: .copy,
            fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var paintedPixelCount = 0
        for x in 0..<pixelsWide {
            for y in 0..<pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.05 else { continue }
                paintedPixelCount += 1
                XCTAssertEqual(
                    color.redComponent,
                    1,
                    accuracy: 0.01,
                    "\(title) contains non-white red ink",
                    file: file,
                    line: line)
                XCTAssertEqual(
                    color.greenComponent,
                    1,
                    accuracy: 0.01,
                    "\(title) contains non-white green ink",
                    file: file,
                    line: line)
                XCTAssertEqual(
                    color.blueComponent,
                    1,
                    accuracy: 0.01,
                    "\(title) contains non-white blue ink",
                    file: file,
                    line: line)
            }
        }
        XCTAssertGreaterThan(
            paintedPixelCount,
            0,
            "\(title) must contain visible label pixels",
            file: file,
            line: line)
    }

    private func relativeLuminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB)!
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent)
            + 0.7152 * channel(c.greenComponent)
            + 0.0722 * channel(c.blueComponent)
    }

    private func contrastBetween(_ lhs: NSColor, _ rhs: NSColor) -> Double {
        let a = relativeLuminance(lhs), b = relativeLuminance(rhs)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func composite(
        foreground: NSColor,
        opacity: Double,
        over background: NSColor
    ) -> NSColor {
        let foreground = foreground.usingColorSpace(.sRGB)!
        let background = background.usingColorSpace(.sRGB)!
        let alpha = CGFloat(opacity)
        return NSColor(
            srgbRed: foreground.redComponent * alpha
                + background.redComponent * (1 - alpha),
            green: foreground.greenComponent * alpha
                + background.greenComponent * (1 - alpha),
            blue: foreground.blueComponent * alpha
                + background.blueComponent * (1 - alpha),
            alpha: 1)
    }

    private func contrastWithWhite(_ color: NSColor) -> Double {
        contrastBetween(color, .white)
    }
}
