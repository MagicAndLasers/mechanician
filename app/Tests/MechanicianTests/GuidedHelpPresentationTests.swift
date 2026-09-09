import AppKit
import XCTest
@testable import Mechanician

@MainActor
final class GuidedHelpPresentationTests: XCTestCase {
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private let corpusDigest = String(repeating: "a", count: 64)
    private enum SignedTargetFixture: String {
        case helpSearchField
        case futureUnknownTarget
    }

    @MainActor
    private struct OwnedWindowFixture {
        let bridge: AgentBridge
        let window: NSWindow
        let support: URL

        func cleanUp() {
            bridge.window = nil
            bridge.shutdown()
            window.orderOut(nil)
            window.contentView = nil
            try? FileManager.default.removeItem(at: support)
        }
    }

    private func ownedWindow(name: String = #function) -> OwnedWindowFixture {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("guided-help-\(name)-\(UUID().uuidString)", isDirectory: true)
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        bridge.window = window
        return OwnedWindowFixture(bridge: bridge, window: window, support: support)
    }

    private func step(
        id: String,
        target: GuidedHelpPresentationTarget
    ) -> GuidedHelpPresentationStep {
        GuidedHelpPresentationStep(
            id: id,
            target: target,
            title: "Step \(id)",
            instruction: "Follow step \(id).")
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        isRepeat: Bool = false,
        windowNumber: Int = 0
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isRepeat,
            keyCode: keyCode)!
    }

    func testSignedTargetAdapterAcceptsOnlyTheAppOwnedVocabulary() {
        XCTAssertEqual(
            GuidedHelpPresentationTarget(signedTarget: SignedTargetFixture.helpSearchField),
            .helpSearchField)
        XCTAssertNil(GuidedHelpPresentationTarget(
            signedTarget: SignedTargetFixture.futureUnknownTarget))
        XCTAssertEqual(
            GuidedHelpPresentationTarget.allCases.map(\.rawValue),
            [
                "helpInspectorTab",
                "helpTopics",
                "helpSearchField",
                "helpArticleContent",
                "helpArticleEvidence",
                "helpDemonstrations",
                "conversationFilesTab",
                "conversationChangesTab",
                "conversationArtifactsTab",
                "conversationAgentsTab",
                "conversationSkillsTab",
                "conversationModelControl",
                "conversationEffortControl",
                "conversationPermissionControl",
                "conversationComposer",
            ])
        XCTAssertTrue(GuidedHelpPresentationTarget.allCases.allSatisfy {
            !$0.accessibilityName.isEmpty
        })
    }

    func testSignedGuideAdapterPreservesReviewedStepIdentityAndCopy() throws {
        let signed = MechanicianHelpGuide(
            id: "mechanician-help.inspector-tour",
            articleID: "mechanician-help",
            title: "Take a tour of Help",
            summary: "Learn the Help inspector.",
            surface: .helpWorkspaceInspector,
            lifecycle: .current,
            ordinal: 0,
            claimKeys: ["mechanician-help.agent"],
            steps: [MechanicianHelpGuideStep(
                id: "mechanician-help.inspector-tour.search",
                title: "Search Help",
                instruction: "Enter a product term.",
                target: .helpSearchField,
                revealAction: .showHelpTopics,
                completion: .userAdvance,
                ordinal: 0)],
            evidence: [])

        let presentation = try XCTUnwrap(GuidedHelpPresentationGuide(
            signedGuide: signed,
            corpusDigest: corpusDigest))
        XCTAssertEqual(presentation.id, signed.id)
        XCTAssertEqual(presentation.articleID, signed.articleID)
        XCTAssertEqual(presentation.title, signed.title)
        XCTAssertEqual(presentation.corpusDigest, corpusDigest)
        XCTAssertEqual(presentation.steps, [GuidedHelpPresentationStep(
            id: signed.steps[0].id,
            target: .helpSearchField,
            title: signed.steps[0].title,
            instruction: signed.steps[0].instruction,
            revealAction: .showHelpTopics,
            completion: .userAdvance)])
    }

    func testGuideValidationRejectsEmptyCopyAndDuplicateStepIdentity() {
        XCTAssertEqual(
            GuidedHelpPresentationGuide(
                id: "guide", title: "Guide", corpusDigest: corpusDigest, steps: [])
                .validationError,
            .noSteps)
        XCTAssertEqual(
            GuidedHelpPresentationGuide(
                id: "guide",
                title: "Guide",
                corpusDigest: corpusDigest,
                steps: [
                    step(id: "same", target: .helpTopics),
                    step(id: "same", target: .helpSearchField),
                ]).validationError,
            .duplicateStepID("same"))
        XCTAssertEqual(
            GuidedHelpPresentationGuide(
                id: "guide",
                title: "Guide",
                corpusDigest: corpusDigest,
                steps: [GuidedHelpPresentationStep(
                    id: "step",
                    target: .helpTopics,
                    title: " ",
                    instruction: "Instruction")]).validationError,
            .emptyStepTitle(index: 0))
        XCTAssertEqual(
            GuidedHelpPresentationGuide(
                id: "guide", title: "Guide", corpusDigest: "not-a-digest",
                steps: [step(id: "step", target: .helpTopics)])
                .validationError,
            .invalidCorpusDigest)
        XCTAssertEqual(
            GuidedHelpPresentationGuide(
                id: "guide", articleID: " ", title: "Guide",
                corpusDigest: corpusDigest,
                steps: [step(id: "step", target: .helpTopics)])
                .validationError,
            .emptyArticleID)
        XCTAssertEqual(
            GuidedHelpPresentationGuide(
                id: "guide", title: "Guide", corpusDigest: corpusDigest,
                steps: [GuidedHelpPresentationStep(
                    id: "step",
                    target: .helpTopics,
                    title: "Topics",
                    instruction: "Browse topics.",
                    completion: .targetVisible)])
                .validationError,
            .unsupportedCompletion(stepID: "step"))
    }

    func testOwnerIsExactBridgeWindowReceiptAndFailsAfterRebinding() throws {
        let fixture = ownedWindow()
        let otherWindow = NSWindow()
        defer {
            fixture.bridge.window = fixture.window
            fixture.cleanUp()
        }

        let owner = try XCTUnwrap(GuidedHelpPresentationOwner(
            bridge: fixture.bridge,
            window: fixture.window))
        XCTAssertTrue(owner.matches(bridge: fixture.bridge, window: fixture.window))
        XCTAssertNil(GuidedHelpPresentationOwner(
            bridge: fixture.bridge,
            window: otherWindow))

        fixture.bridge.window = otherWindow
        XCTAssertNil(owner.currentWindow)
        XCTAssertFalse(owner.matches(bridge: fixture.bridge, window: fixture.window))
    }

    func testOwnerFailsClosedAfterWorkspaceOrConversationRebinding() throws {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        fixture.bridge.projectID = HelpWorkspace.id
        fixture.bridge.currentID = UUID()
        let owner = try XCTUnwrap(GuidedHelpPresentationOwner(
            bridge: fixture.bridge,
            window: fixture.window))

        fixture.bridge.currentID = UUID()
        XCTAssertNil(owner.currentWindow)

        let replacement = try XCTUnwrap(GuidedHelpPresentationOwner(
            bridge: fixture.bridge,
            window: fixture.window))
        fixture.bridge.projectID = UUID()
        XCTAssertNil(replacement.currentWindow)
    }

    func testRegistryRejectsOtherWindowsAndFailsClosedOnAmbiguousTargets() throws {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        let owner = try XCTUnwrap(GuidedHelpPresentationOwner(
            bridge: fixture.bridge,
            window: fixture.window))
        let registry = GuidedHelpTargetRegistry(owner: owner)
        var changeCount = 0
        registry.onChange = { changeCount += 1 }
        let content = try XCTUnwrap(fixture.window.contentView)

        let first = NSView(frame: NSRect(x: 60, y: 80, width: 180, height: 34))
        content.addSubview(first)
        XCTAssertTrue(registry.register(.helpSearchField, view: first))
        XCTAssertEqual(changeCount, 1)
        XCTAssertTrue(registry.register(.helpSearchField, view: first))
        XCTAssertEqual(changeCount, 1, "Re-registering the same live target must be silent")
        XCTAssertEqual(
            registry.resolve(.helpSearchField),
            .available(frame: first.frame))

        let otherWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        let foreign = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 30))
        otherWindow.contentView = NSView(frame: otherWindow.contentLayoutRect)
        otherWindow.contentView?.addSubview(foreign)
        XCTAssertFalse(registry.register(.helpSearchField, view: foreign))

        let duplicate = NSView(frame: NSRect(x: 260, y: 80, width: 180, height: 34))
        content.addSubview(duplicate)
        XCTAssertTrue(registry.register(.helpSearchField, view: duplicate))
        XCTAssertEqual(
            registry.resolve(.helpSearchField),
            .unavailable(.ambiguous(registrationCount: 2)))

        duplicate.isHidden = true
        XCTAssertEqual(
            registry.resolve(.helpSearchField),
            .available(frame: first.frame))
        registry.unregister(.helpSearchField, view: duplicate)
        first.removeFromSuperview()
        XCTAssertEqual(
            registry.resolve(.helpSearchField),
            .unavailable(.detachedFromOwner))
    }

    func testOverlayLayoutPlacesCalloutInsideWindowAndAwayFromTarget() {
        let container = CGRect(x: 0, y: 0, width: 900, height: 640)
        let target = CGRect(x: 40, y: 220, width: 180, height: 32)
        let layout = GuidedHelpOverlayLayout.resolve(
            container: container,
            target: target,
            calloutSize: CGSize(width: 340, height: 210))

        XCTAssertEqual(
            layout.spotlightFrame,
            target.insetBy(
                dx: -GuidedHelpOverlayLayout.targetPadding,
                dy: -GuidedHelpOverlayLayout.targetPadding))
        XCTAssertTrue(container.insetBy(
            dx: GuidedHelpOverlayLayout.margin,
            dy: GuidedHelpOverlayLayout.margin).contains(layout.calloutFrame))
        XCTAssertFalse(layout.calloutFrame.intersects(try! XCTUnwrap(layout.spotlightFrame)))

        let missing = GuidedHelpOverlayLayout.resolve(
            container: container,
            target: nil,
            calloutSize: CGSize(width: 340, height: 210))
        XCTAssertNil(missing.spotlightFrame)
        XCTAssertEqual(missing.calloutFrame.midX, container.midX, accuracy: 0.001)
        XCTAssertEqual(missing.calloutFrame.midY, container.midY, accuracy: 0.001)

        let contentLayout = CGRect(x: 0, y: 52, width: 900, height: 588)
        let titlebarSafe = GuidedHelpOverlayLayout.resolve(
            container: contentLayout,
            target: CGRect(x: 700, y: 560, width: 120, height: 30),
            calloutSize: CGSize(width: 340, height: 210))
        XCTAssertTrue(contentLayout.insetBy(
            dx: GuidedHelpOverlayLayout.margin,
            dy: GuidedHelpOverlayLayout.margin).contains(titlebarSafe.calloutFrame))
    }

    func testMissingTargetStaysVisibleAndCannotBeSkipped() throws {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        let coordinator = try XCTUnwrap(GuidedHelpPresentationCoordinator(
            bridge: fixture.bridge,
            window: fixture.window,
            reduceMotion: { true }))
        let guide = GuidedHelpPresentationGuide(
            id: "help-tour",
            title: "Help tour",
            corpusDigest: corpusDigest,
            steps: [step(id: "missing", target: .helpTopics)])

        XCTAssertEqual(coordinator.present(guide), .started)
        XCTAssertEqual(
            coordinator.snapshot?.targetState,
            .unavailable(.unregistered))
        XCTAssertEqual(fixture.window.contentView?.subviews.compactMap {
            $0 as? GuidedHelpOverlayView
        }.count, 1)
        XCTAssertFalse(try XCTUnwrap(coordinator.snapshot).canAdvance)

        coordinator.advance()
        XCTAssertEqual(coordinator.snapshot?.stepID, "missing")

        let target = NSView(frame: NSRect(x: 40, y: 40, width: 160, height: 32))
        fixture.window.contentView?.addSubview(target, positioned: .below, relativeTo: nil)
        XCTAssertTrue(coordinator.registry.register(.helpTopics, view: target))
        coordinator.refreshLayout()
        XCTAssertTrue(try XCTUnwrap(coordinator.snapshot).canAdvance)
        coordinator.advance()
        XCTAssertNil(coordinator.snapshot)
        XCTAssertTrue(fixture.window.contentView?.subviews.compactMap {
            $0 as? GuidedHelpOverlayView
        }.isEmpty == true)
    }

    func testNavigationPreparesEachStepAndExitRestoresTemporaryStateInReverseOrder() throws {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        let coordinator = try XCTUnwrap(GuidedHelpPresentationCoordinator(
            bridge: fixture.bridge,
            window: fixture.window,
            reduceMotion: { true }))
        let content = try XCTUnwrap(fixture.window.contentView)
        let topics = NSView(frame: NSRect(x: 40, y: 40, width: 120, height: 30))
        let search = NSView(frame: NSRect(x: 40, y: 100, width: 220, height: 30))
        content.addSubview(topics)
        content.addSubview(search)
        XCTAssertTrue(coordinator.registry.register(.helpTopics, view: topics))
        XCTAssertTrue(coordinator.registry.register(.helpSearchField, view: search))

        let guide = GuidedHelpPresentationGuide(
            id: "help-tour",
            title: "Help tour",
            corpusDigest: corpusDigest,
            steps: [
                step(id: "topics", target: .helpTopics),
                step(id: "search", target: .helpSearchField),
            ])
        var prepared: [String] = []
        var restored: [String] = []
        var finishReason: GuidedHelpPresentationEndReason?
        let hooks = GuidedHelpPresentationHooks(
            prepareStep: { step, state in
                prepared.append(step.id)
                _ = state.restoreOnEnd(key: .init("first")) { restored.append("first") }
                _ = state.restoreOnEnd(key: .init("second")) { restored.append("second") }
            },
            didFinish: { finishReason = $0 })

        XCTAssertEqual(coordinator.present(guide, hooks: hooks), .started)
        XCTAssertEqual(prepared, ["topics"])
        coordinator.advance()
        XCTAssertEqual(prepared, ["topics", "search"])
        XCTAssertEqual(coordinator.snapshot?.stepID, "search")
        coordinator.goBack()
        XCTAssertEqual(prepared, ["topics", "search", "topics"])
        XCTAssertEqual(coordinator.snapshot?.stepID, "topics")

        coordinator.exit()
        XCTAssertEqual(finishReason, .exited)
        XCTAssertEqual(restored, ["second", "first"])
        XCTAssertNil(coordinator.snapshot)
    }

    func testWindowResizeNotificationRecomputesLiveTargetGeometry() throws {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        let coordinator = try XCTUnwrap(GuidedHelpPresentationCoordinator(
            bridge: fixture.bridge,
            window: fixture.window,
            reduceMotion: { true }))
        let target = NSView(frame: NSRect(x: 20, y: 20, width: 100, height: 30))
        fixture.window.contentView?.addSubview(target)
        XCTAssertTrue(coordinator.registry.register(.helpInspectorTab, view: target))
        let guide = GuidedHelpPresentationGuide(
            id: "resize",
            title: "Resize",
            corpusDigest: corpusDigest,
            steps: [step(id: "tab", target: .helpInspectorTab)])
        XCTAssertEqual(coordinator.present(guide), .started)
        XCTAssertEqual(
            coordinator.snapshot?.targetState,
            .available(frame: target.frame))

        target.frame = NSRect(x: 520, y: 360, width: 120, height: 34)
        NotificationCenter.default.post(
            name: NSWindow.didResizeNotification,
            object: fixture.window)
        XCTAssertEqual(
            coordinator.snapshot?.targetState,
            .available(frame: target.frame))
        XCTAssertTrue(try XCTUnwrap(fixture.window.contentView).bounds.contains(
            try XCTUnwrap(coordinator.snapshot?.calloutFrame)))
    }

    func testManualClipBoundsChangeRefreshesGeometryAndRestoresNotificationLease() throws {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        let coordinator = try XCTUnwrap(GuidedHelpPresentationCoordinator(
            bridge: fixture.bridge,
            window: fixture.window,
            reduceMotion: { true }))
        let content = try XCTUnwrap(fixture.window.contentView)
        let scrollView = NSScrollView(frame: NSRect(x: 60, y: 80, width: 300, height: 180))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 900))
        let target = GuidedHelpTargetAnchorView(
            frame: NSRect(x: 20, y: 360, width: 220, height: 40))
        document.addSubview(target)
        scrollView.documentView = document
        content.addSubview(scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = false
        target.configure(target: .helpArticleContent, registry: coordinator.registry)
        XCTAssertTrue(scrollView.contentView.postsBoundsChangedNotifications)

        let guide = GuidedHelpPresentationGuide(
            id: "scroll",
            title: "Scroll",
            corpusDigest: corpusDigest,
            steps: [step(id: "article", target: .helpArticleContent)])
        XCTAssertEqual(coordinator.present(guide), .started)
        XCTAssertEqual(
            coordinator.snapshot?.targetState,
            .unavailable(.outsideVisibleWindow))

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 330))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let targetIsAvailable = {
            if case .available = coordinator.snapshot?.targetState { return true }
            return false
        }
        let refreshDeadline = Date().addingTimeInterval(1)
        while !targetIsAvailable(), Date() < refreshDeadline {
            _ = RunLoop.main.run(mode: .default, before: refreshDeadline)
        }
        guard case .available(let frame) = coordinator.snapshot?.targetState else {
            return XCTFail("Manual clip-view scrolling must refresh the live semantic target")
        }
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)

        target.detach()
        XCTAssertFalse(
            scrollView.contentView.postsBoundsChangedNotifications,
            "The final target must restore the clip view's original notification policy")
    }

    func testReducedMotionRemovesPresentationTransition() {
        XCTAssertEqual(GuidedHelpMotionPolicy.transitionDuration(reduceMotion: true), 0)
        XCTAssertGreaterThan(GuidedHelpMotionPolicy.transitionDuration(reduceMotion: false), 0)
    }

    func testModalOverlayBlocksSpotlightAndBackgroundPointerInteraction() {
        let overlay = GuidedHelpOverlayView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        overlay.apply(
            spotlightFrame: NSRect(x: 40, y: 40, width: 160, height: 44),
            calloutFrame: NSRect(x: 300, y: 180, width: 340, height: 220),
            animationDuration: 0)

        XCTAssertTrue(overlay.hitTest(NSPoint(x: 80, y: 60)) === overlay)
        XCTAssertTrue(overlay.hitTest(NSPoint(x: 20, y: 20)) === overlay)
        XCTAssertNotNil(overlay.hitTest(NSPoint(x: 340, y: 220)))
        XCTAssertTrue(overlay.isAccessibilityElement())
        XCTAssertEqual(overlay.accessibilityRole(), .group)
    }

    func testModalKeyMonitorContainsGuideNavigationButPassesSystemCommands() {
        let escape = GuidedHelpModalKeyAction(event: keyEvent(
            keyCode: 53, characters: "\u{1b}"))
        let enter = GuidedHelpModalKeyAction(event: keyEvent(
            keyCode: 36, characters: "\r"))
        let space = GuidedHelpModalKeyAction(event: keyEvent(
            keyCode: 49, characters: " "))
        let leftArrow = GuidedHelpModalKeyAction(event: keyEvent(
            keyCode: 123, characters: ""))
        let tab = GuidedHelpModalKeyAction(event: keyEvent(
            keyCode: 48, characters: "\t", modifiers: .shift))
        XCTAssertEqual(escape, .exit)
        XCTAssertEqual(enter, .advance)
        XCTAssertEqual(space, .advance)
        XCTAssertEqual(leftArrow, .back)
        XCTAssertEqual(tab, .containFocus)
        XCTAssertTrue(escape.interceptsInExactWindowMonitor)
        XCTAssertTrue(enter.interceptsInExactWindowMonitor)
        XCTAssertTrue(space.interceptsInExactWindowMonitor)
        XCTAssertTrue(leftArrow.interceptsInExactWindowMonitor)
        XCTAssertTrue(tab.interceptsInExactWindowMonitor)

        let ordinaryInput = GuidedHelpModalKeyAction(event: keyEvent(
            keyCode: 0, characters: "a"))
        let commandNew = GuidedHelpModalKeyAction(event: keyEvent(
            keyCode: 45, characters: "n", modifiers: .command))
        let voiceOverRight = GuidedHelpModalKeyAction(event: keyEvent(
            keyCode: 124,
            characters: "",
            modifiers: [.control, .option]))
        let commandLeft = GuidedHelpModalKeyAction(event: keyEvent(
            keyCode: 123,
            characters: "",
            modifiers: .command))
        let shiftLeft = GuidedHelpModalKeyAction(event: keyEvent(
            keyCode: 123,
            characters: "",
            modifiers: .shift))
        let repeatedReturn = GuidedHelpModalKeyAction(event: keyEvent(
            keyCode: 36,
            characters: "\r",
            isRepeat: true))
        let repeatedLeft = GuidedHelpModalKeyAction(event: keyEvent(
            keyCode: 123,
            characters: "",
            isRepeat: true))
        XCTAssertEqual(ordinaryInput, .consume)
        XCTAssertEqual(commandNew, .passThrough)
        XCTAssertEqual(voiceOverRight, .passThrough)
        XCTAssertEqual(commandLeft, .passThrough)
        XCTAssertEqual(shiftLeft, .passThrough)
        XCTAssertEqual(repeatedReturn, .consume)
        XCTAssertEqual(repeatedLeft, .consume)
        XCTAssertFalse(ordinaryInput.interceptsInExactWindowMonitor)
        XCTAssertFalse(commandNew.interceptsInExactWindowMonitor)
        XCTAssertFalse(voiceOverRight.interceptsInExactWindowMonitor)
        XCTAssertFalse(commandLeft.interceptsInExactWindowMonitor)
        XCTAssertFalse(shiftLeft.interceptsInExactWindowMonitor)
        XCTAssertFalse(repeatedReturn.interceptsInExactWindowMonitor)
        XCTAssertFalse(repeatedLeft.interceptsInExactWindowMonitor)
    }

    func testLocalKeyMonitorInterceptsOnlyItsExactOwningWindow() throws {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        fixture.window.orderFront(nil)
        let coordinator = try XCTUnwrap(GuidedHelpPresentationCoordinator(
            bridge: fixture.bridge,
            window: fixture.window,
            reduceMotion: { true }))
        let content = try XCTUnwrap(fixture.window.contentView)
        let target = NSView(frame: NSRect(x: 60, y: 100, width: 180, height: 36))
        content.addSubview(target)
        XCTAssertTrue(coordinator.registry.register(.helpTopics, view: target))
        let guide = GuidedHelpPresentationGuide(
            id: "exact-window-keys",
            title: "Exact window keys",
            corpusDigest: corpusDigest,
            steps: [
                step(id: "first", target: .helpTopics),
                step(id: "second", target: .helpTopics),
            ])
        XCTAssertEqual(coordinator.present(guide), .started)

        let foreignWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        defer { foreignWindow.orderOut(nil) }
        foreignWindow.orderFront(nil)

        NSApplication.shared.sendEvent(keyEvent(
            keyCode: 0,
            characters: "a",
            windowNumber: foreignWindow.windowNumber))
        XCTAssertEqual(coordinator.snapshot?.stepID, "first")

        NSApplication.shared.sendEvent(keyEvent(
            keyCode: 123,
            characters: "",
            windowNumber: fixture.window.windowNumber))
        XCTAssertEqual(
            coordinator.snapshot?.stepID,
            "first",
            "Back on the first step must be a safe no-op")

        NSApplication.shared.sendEvent(keyEvent(
            keyCode: 48,
            characters: "\t",
            windowNumber: fixture.window.windowNumber))
        XCTAssertEqual(coordinator.snapshot?.stepID, "first")

        NSApplication.shared.sendEvent(keyEvent(
            keyCode: 36,
            characters: "\r",
            windowNumber: fixture.window.windowNumber))
        XCTAssertEqual(coordinator.snapshot?.stepID, "second")

        NSApplication.shared.sendEvent(keyEvent(
            keyCode: 123,
            characters: "",
            modifiers: .shift,
            windowNumber: fixture.window.windowNumber))
        XCTAssertEqual(
            coordinator.snapshot?.stepID,
            "second",
            "Modified Left Arrow must remain outside guide navigation")

        NSApplication.shared.sendEvent(keyEvent(
            keyCode: 123,
            characters: "",
            windowNumber: foreignWindow.windowNumber))
        XCTAssertEqual(
            coordinator.snapshot?.stepID,
            "second",
            "A foreign window's Left Arrow must remain unclaimed")

        NSApplication.shared.sendEvent(keyEvent(
            keyCode: 123,
            characters: "",
            windowNumber: fixture.window.windowNumber))
        XCTAssertEqual(coordinator.snapshot?.stepID, "first")

        NSApplication.shared.sendEvent(keyEvent(
            keyCode: 36,
            characters: "\r",
            windowNumber: fixture.window.windowNumber))
        XCTAssertEqual(coordinator.snapshot?.stepID, "second")
        NSApplication.shared.sendEvent(keyEvent(
            keyCode: 53,
            characters: "\u{1b}",
            windowNumber: fixture.window.windowNumber))
        XCTAssertNil(coordinator.snapshot)
    }

    func testModalSessionFocusesGuideHidesBackgroundAndRestoresEveryEndPath() throws {
        enum EndPath: CaseIterable { case completed, exited, replaced, ownerInvalidated }

        for path in EndPath.allCases {
            let fixture = ownedWindow(name: "\(#function)-\(path)")
            defer { fixture.cleanUp() }
            let coordinator = try XCTUnwrap(GuidedHelpPresentationCoordinator(
                bridge: fixture.bridge,
                window: fixture.window,
                reduceMotion: { true }))
            let content = try XCTUnwrap(fixture.window.contentView)
            let priorResponder = FocusableView(
                frame: NSRect(x: 10, y: 10, width: 180, height: 24))
            let target = NSView(frame: NSRect(x: 60, y: 100, width: 180, height: 36))
            let alreadyHidden = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            alreadyHidden.setAccessibilityHidden(true)
            content.addSubview(priorResponder)
            content.addSubview(target)
            content.addSubview(alreadyHidden)
            XCTAssertTrue(fixture.window.makeFirstResponder(priorResponder))
            XCTAssertTrue(coordinator.registry.register(.helpTopics, view: target))

            let guide = GuidedHelpPresentationGuide(
                id: "modal-\(path)",
                title: "Modal guide",
                corpusDigest: corpusDigest,
                steps: [step(id: "topics", target: .helpTopics)])
            XCTAssertEqual(coordinator.present(guide), .started)
            let overlay = try XCTUnwrap(content.subviews.compactMap {
                $0 as? GuidedHelpOverlayView
            }.first)
            XCTAssertTrue(fixture.window.firstResponder === overlay)
            XCTAssertTrue(target.isAccessibilityHidden())
            XCTAssertTrue(priorResponder.isAccessibilityHidden())
            XCTAssertTrue(alreadyHidden.isAccessibilityHidden())
            let accessibilityValue = try XCTUnwrap(overlay.accessibilityValue() as? String)
            XCTAssertTrue(accessibilityValue.contains("Modal guide"))
            XCTAssertTrue(accessibilityValue.contains(String(localized: "Step 1 of 1")))
            XCTAssertTrue(accessibilityValue.contains("Step topics"))
            XCTAssertTrue(accessibilityValue.contains(
                GuidedHelpPresentationTarget.helpTopics.accessibilityName))

            switch path {
            case .completed:
                overlay.keyDown(with: keyEvent(keyCode: 36, characters: "\r"))
            case .exited:
                overlay.keyDown(with: keyEvent(keyCode: 53, characters: "\u{1b}"))
            case .replaced:
                XCTAssertEqual(coordinator.present(guide), .started)
                coordinator.exit()
            case .ownerInvalidated:
                fixture.bridge.currentID = UUID()
                coordinator.refreshLayout()
            }

            XCTAssertNil(coordinator.snapshot)
            XCTAssertTrue(fixture.window.firstResponder === priorResponder)
            XCTAssertFalse(target.isAccessibilityHidden())
            XCTAssertFalse(priorResponder.isAccessibilityHidden())
            XCTAssertTrue(alreadyHidden.isAccessibilityHidden())
            XCTAssertFalse(overlay.isAccessibilityFocused())
            XCTAssertTrue(content.subviews.compactMap {
                $0 as? GuidedHelpOverlayView
            }.isEmpty)
        }
    }
}
