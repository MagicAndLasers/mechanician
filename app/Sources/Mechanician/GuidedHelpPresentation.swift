import AppKit
import SwiftUI

/// The app-owned UI vocabulary a signed guide may point at.
///
/// Authored guide data names one of these semantic controls. Geometry is resolved from a live
/// registration in the exact owning window; no guide is allowed to carry a rectangle, screen
/// coordinate, accessibility query, or view hierarchy path.
enum GuidedHelpPresentationTarget: String, CaseIterable, Sendable {
    case helpInspectorTab
    case helpTopics
    case helpSearchField
    case helpArticleContent
    case helpArticleEvidence
    case helpDemonstrations
    case conversationFilesTab
    case conversationChangesTab
    case conversationArtifactsTab
    case conversationAgentsTab
    case conversationSkillsTab
    case conversationModelControl
    case conversationEffortControl
    case conversationPermissionControl
    case conversationComposer

    /// Strict adapter for the String-backed target enum owned by the signed Help authority.
    /// Unknown future targets fail closed until the app presentation vocabulary is updated.
    init?<SignedTarget>(signedTarget: SignedTarget)
    where SignedTarget: RawRepresentable, SignedTarget.RawValue == String {
        self.init(rawValue: signedTarget.rawValue)
    }

    var accessibilityName: String {
        switch self {
        case .helpInspectorTab:
            String(localized: "Help inspector tab")
        case .helpTopics:
            String(localized: "Help topics")
        case .helpSearchField:
            String(localized: "Help search field")
        case .helpArticleContent:
            String(localized: "Help article")
        case .helpArticleEvidence:
            String(localized: "Help evidence")
        case .helpDemonstrations:
            String(localized: "Help demonstrations")
        case .conversationFilesTab:
            String(localized: "Files inspector tab")
        case .conversationChangesTab:
            String(localized: "Changes inspector tab")
        case .conversationArtifactsTab:
            String(localized: "Artifacts inspector tab")
        case .conversationAgentsTab:
            String(localized: "Agents inspector tab")
        case .conversationSkillsTab:
            String(localized: "Skills inspector tab")
        case .conversationModelControl:
            String(localized: "Model control")
        case .conversationEffortControl:
            String(localized: "Reasoning effort control")
        case .conversationPermissionControl:
            String(localized: "Permissions control")
        case .conversationComposer:
            String(localized: "Message box")
        }
    }
}

struct GuidedHelpPresentationStep: Identifiable, Equatable, Sendable {
    let id: String
    let target: GuidedHelpPresentationTarget
    let title: String
    let instruction: String
    let revealAction: MechanicianHelpGuideRevealAction
    let completion: MechanicianHelpGuideCompletion

    init(
        id: String,
        target: GuidedHelpPresentationTarget,
        title: String,
        instruction: String,
        revealAction: MechanicianHelpGuideRevealAction = .none,
        completion: MechanicianHelpGuideCompletion = .userAdvance
    ) {
        self.id = id
        self.target = target
        self.title = title
        self.instruction = instruction
        self.revealAction = revealAction
        self.completion = completion
    }

    init?(signedStep: MechanicianHelpGuideStep) {
        guard let target = GuidedHelpPresentationTarget(signedTarget: signedStep.target) else {
            return nil
        }
        self.init(
            id: signedStep.id,
            target: target,
            title: signedStep.title,
            instruction: signedStep.instruction,
            revealAction: signedStep.revealAction,
            completion: signedStep.completion)
    }
}

struct GuidedHelpPresentationGuide: Identifiable, Equatable, Sendable {
    enum ValidationError: Equatable {
        case emptyGuideID
        case emptyArticleID
        case emptyTitle
        case noSteps
        case emptyStepID(index: Int)
        case duplicateStepID(String)
        case emptyStepTitle(index: Int)
        case emptyStepInstruction(index: Int)
        case unsupportedCompletion(stepID: String)
        case invalidCorpusDigest
    }

    let id: String
    let articleID: String
    let title: String
    let corpusDigest: String
    let steps: [GuidedHelpPresentationStep]

    init(
        id: String,
        articleID: String = "mechanician-help",
        title: String,
        corpusDigest: String,
        steps: [GuidedHelpPresentationStep]
    ) {
        self.id = id
        self.articleID = articleID
        self.title = title
        self.corpusDigest = corpusDigest
        self.steps = steps
    }

    init?(signedGuide: MechanicianHelpGuide, corpusDigest: String) {
        let mappedSteps = signedGuide.steps.compactMap(GuidedHelpPresentationStep.init(signedStep:))
        guard mappedSteps.count == signedGuide.steps.count else { return nil }
        self.init(
            id: signedGuide.id,
            articleID: signedGuide.articleID,
            title: signedGuide.title,
            corpusDigest: corpusDigest,
            steps: mappedSteps)
        guard validationError == nil else { return nil }
    }

    var validationError: ValidationError? {
        let whitespace = CharacterSet.whitespacesAndNewlines
        guard !id.trimmingCharacters(in: whitespace).isEmpty else { return .emptyGuideID }
        guard !articleID.trimmingCharacters(in: whitespace).isEmpty else {
            return .emptyArticleID
        }
        guard !title.trimmingCharacters(in: whitespace).isEmpty else { return .emptyTitle }
        guard corpusDigest.range(
            of: #"^[a-f0-9]{64}$"#,
            options: .regularExpression) != nil else { return .invalidCorpusDigest }
        guard !steps.isEmpty else { return .noSteps }

        var stepIDs = Set<String>()
        for (index, step) in steps.enumerated() {
            let stepID = step.id.trimmingCharacters(in: whitespace)
            guard !stepID.isEmpty else { return .emptyStepID(index: index) }
            guard stepIDs.insert(stepID).inserted else { return .duplicateStepID(stepID) }
            guard !step.title.trimmingCharacters(in: whitespace).isEmpty else {
                return .emptyStepTitle(index: index)
            }
            guard !step.instruction.trimmingCharacters(in: whitespace).isEmpty else {
                return .emptyStepInstruction(index: index)
            }
            guard step.completion == .userAdvance else {
                return .unsupportedCompletion(stepID: stepID)
            }
        }
        return nil
    }
}

/// A stable identity receipt for one bridge and the one window it actually owns.
///
/// Both references are weak. A receipt stops being current if either object disappears or if the
/// bridge is ever rebound to another window. A guide can therefore never fall back to the key
/// window, `ActiveWorkspace`, or a process-global "last used" route.
@MainActor
final class GuidedHelpPresentationOwner {
    private weak var bridge: AgentBridge?
    private weak var window: NSWindow?

    let bridgeID: ObjectIdentifier
    let windowID: ObjectIdentifier
    let projectID: UUID?
    let conversationID: UUID?

    init?(bridge: AgentBridge, window: NSWindow) {
        guard bridge.window === window else { return nil }
        self.bridge = bridge
        self.window = window
        bridgeID = ObjectIdentifier(bridge)
        windowID = ObjectIdentifier(window)
        projectID = bridge.projectID
        conversationID = bridge.currentID
    }

    var currentWindow: NSWindow? {
        guard let bridge, let window,
              ObjectIdentifier(bridge) == bridgeID,
              ObjectIdentifier(window) == windowID,
              bridge.window === window,
              bridge.projectID == projectID,
              bridge.currentID == conversationID else { return nil }
        return window
    }

    func matches(bridge: AgentBridge, window: NSWindow) -> Bool {
        currentWindow === window
            && ObjectIdentifier(bridge) == bridgeID
            && bridge.window === window
    }
}

enum GuidedHelpTargetUnavailableReason: Equatable {
    case ownerUnavailable
    case unregistered
    case detachedFromOwner
    case hidden
    case outsideVisibleWindow
    case ambiguous(registrationCount: Int)
}

enum GuidedHelpTargetResolution: Equatable {
    case available(frame: CGRect)
    case unavailable(GuidedHelpTargetUnavailableReason)
}

/// Per-window registrations for semantic Help targets.
///
/// The registry stores weak views and accepts only views already attached to its exact owner
/// window. More than one visible registration is an error, not a heuristic choice: toolbar palette
/// copies and stale SwiftUI trees must never make a guide spotlight a different control.
@MainActor
final class GuidedHelpTargetRegistry {
    private final class WeakView {
        weak var value: NSView?
        init(_ value: NSView) { self.value = value }
    }

    let owner: GuidedHelpPresentationOwner
    private var registrations: [GuidedHelpPresentationTarget: [WeakView]] = [:]
    var onChange: (() -> Void)?

    init(owner: GuidedHelpPresentationOwner) {
        self.owner = owner
    }

    @discardableResult
    func register(_ target: GuidedHelpPresentationTarget, view: NSView) -> Bool {
        guard let window = owner.currentWindow, view.window === window else { return false }
        var views = liveRegistrations(for: target)
        guard !views.contains(where: { $0.value === view }) else { return true }
        views.append(WeakView(view))
        registrations[target] = views
        onChange?()
        return true
    }

    func unregister(_ target: GuidedHelpPresentationTarget, view: NSView) {
        let before = registrations[target]?.count ?? 0
        let remaining = liveRegistrations(for: target).filter { $0.value !== view }
        registrations[target] = remaining.isEmpty ? nil : remaining
        if remaining.count != before { onChange?() }
    }

    func geometryDidChange(for target: GuidedHelpPresentationTarget, view: NSView) {
        guard registrations[target]?.contains(where: { $0.value === view }) == true else { return }
        onChange?()
    }

    func resolve(_ target: GuidedHelpPresentationTarget) -> GuidedHelpTargetResolution {
        guard let window = owner.currentWindow,
              let contentView = window.contentView else {
            return .unavailable(.ownerUnavailable)
        }

        let registered = liveRegistrations(for: target)
        guard !registered.isEmpty else { return .unavailable(.unregistered) }

        let attached = registered.compactMap(\.value).filter { $0.window === window }
        guard !attached.isEmpty else { return .unavailable(.detachedFromOwner) }

        let visible = attached.filter { !$0.isHiddenOrHasHiddenAncestor }
        guard !visible.isEmpty else { return .unavailable(.hidden) }
        guard visible.count == 1 else {
            return .unavailable(.ambiguous(registrationCount: visible.count))
        }

        let view = visible[0]
        // `visibleRect` can extend beyond a non-clipping view's own bounds. The spotlight belongs
        // to the registered control, never the whole visible ancestor chain.
        let visibleRect = view.bounds.intersection(view.visibleRect)
        guard !visibleRect.isEmpty else { return .unavailable(.outsideVisibleWindow) }
        let converted = view.convert(visibleRect, to: contentView)
            .intersection(contentView.bounds)
        guard !converted.isNull, !converted.isEmpty else {
            return .unavailable(.outsideVisibleWindow)
        }
        return .available(frame: converted)
    }

    private func liveRegistrations(
        for target: GuidedHelpPresentationTarget
    ) -> [WeakView] {
        let live = registrations[target, default: []].filter { $0.value != nil }
        registrations[target] = live.isEmpty ? nil : live
        return live
    }
}

/// A zero-drawing anchor that lets SwiftUI content register its live AppKit geometry.
/// Place it in a target control's background or overlay; its bounds become the spotlight bounds.
struct GuidedHelpTargetAnchor: NSViewRepresentable {
    let target: GuidedHelpPresentationTarget
    let registry: GuidedHelpTargetRegistry

    func makeNSView(context: Context) -> GuidedHelpTargetAnchorView {
        let view = GuidedHelpTargetAnchorView(frame: .zero)
        view.configure(target: target, registry: registry)
        return view
    }

    func updateNSView(_ nsView: GuidedHelpTargetAnchorView, context: Context) {
        nsView.configure(target: target, registry: registry)
    }

    static func dismantleNSView(
        _ nsView: GuidedHelpTargetAnchorView,
        coordinator: Void
    ) {
        nsView.detach()
    }
}

/// One reference-counted observation of an AppKit scroll viewport.
///
/// `NSView.layout()` is not called when an `NSClipView` merely changes its bounds origin, so a
/// target can move on screen without its SwiftUI anchor receiving any layout callback. Each live
/// anchor observes its nearest clip view directly. The lease restores the clip view's original
/// notification policy after the last target leaves it, so Guided Help does not leave process-wide
/// AppKit behavior behind when a tour ends or SwiftUI remounts a compact/split reader.
@MainActor
private final class GuidedHelpClipBoundsObservation {
    @MainActor
    private final class Lease {
        weak var clipView: NSClipView?
        let originallyPostedBoundsChanges: Bool
        var count = 1

        init(clipView: NSClipView) {
            self.clipView = clipView
            originallyPostedBoundsChanges = clipView.postsBoundsChangedNotifications
        }
    }

    private static var leases: [ObjectIdentifier: Lease] = [:]

    private weak var clipView: NSClipView?
    private var token: NSObjectProtocol?

    init(clipView: NSClipView, onChange: @escaping @MainActor () -> Void) {
        self.clipView = clipView
        Self.acquire(clipView)
        token = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    func observes(_ candidate: NSClipView?) -> Bool {
        clipView === candidate && token != nil
    }

    func cancel() {
        if let token {
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
        if let clipView {
            Self.release(clipView)
            self.clipView = nil
        }
    }

    isolated deinit {
        cancel()
    }

    private static func acquire(_ clipView: NSClipView) {
        let id = ObjectIdentifier(clipView)
        if let lease = leases[id], lease.clipView === clipView {
            lease.count += 1
        } else {
            let lease = Lease(clipView: clipView)
            leases[id] = lease
            clipView.postsBoundsChangedNotifications = true
        }
    }

    private static func release(_ clipView: NSClipView) {
        let id = ObjectIdentifier(clipView)
        guard let lease = leases[id], lease.clipView === clipView else { return }
        lease.count -= 1
        guard lease.count == 0 else { return }
        clipView.postsBoundsChangedNotifications = lease.originallyPostedBoundsChanges
        leases[id] = nil
    }
}

final class GuidedHelpTargetAnchorView: NSView {
    private var target: GuidedHelpPresentationTarget?
    private weak var registry: GuidedHelpTargetRegistry?
    private var clipBoundsObservation: GuidedHelpClipBoundsObservation?

    override var isOpaque: Bool { false }

    func configure(
        target: GuidedHelpPresentationTarget,
        registry: GuidedHelpTargetRegistry
    ) {
        if self.target != target || self.registry !== registry {
            detach()
            self.target = target
            self.registry = registry
        }
        attachIfPossible()
    }

    func detach() {
        clipBoundsObservation?.cancel()
        clipBoundsObservation = nil
        if let target, let registry { registry.unregister(target, view: self) }
        target = nil
        registry = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateClipBoundsObservation()
        attachIfPossible()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateClipBoundsObservation()
        attachIfPossible()
    }

    override func layout() {
        super.layout()
        updateClipBoundsObservation()
        notifyGeometryChange()
    }

    private func attachIfPossible() {
        guard let target, let registry, window != nil else { return }
        _ = registry.register(target, view: self)
        updateClipBoundsObservation()
    }

    private func updateClipBoundsObservation() {
        guard target != nil, registry != nil, window != nil else {
            clipBoundsObservation?.cancel()
            clipBoundsObservation = nil
            return
        }

        var ancestor = superview
        var enclosingClipView: NSClipView?
        while let view = ancestor {
            if let clipView = view as? NSClipView {
                enclosingClipView = clipView
                break
            }
            ancestor = view.superview
        }
        guard clipBoundsObservation?.observes(enclosingClipView) != true else { return }
        clipBoundsObservation?.cancel()
        clipBoundsObservation = enclosingClipView.map { clipView in
            GuidedHelpClipBoundsObservation(clipView: clipView) { [weak self] in
                self?.notifyGeometryChange()
            }
        }
    }

    private func notifyGeometryChange() {
        guard let target, let registry else { return }
        registry.geometryDidChange(for: target, view: self)
    }
}

/// Session-only restoration stack for UI state a guide temporarily reveals.
///
/// It deliberately has no Codable, UserDefaults, or store seam. Integrations may register a
/// restoration once per semantic key; completion, Exit, replacement, and owner invalidation all
/// unwind it in reverse order.
@MainActor
final class GuidedHelpTemporaryState {
    struct Key: Hashable, Sendable {
        let rawValue: String
        init(_ rawValue: String) { self.rawValue = rawValue }
    }

    private var order: [Key] = []
    private var restorations: [Key: @MainActor () -> Void] = [:]

    @discardableResult
    func restoreOnEnd(key: Key, _ restoration: @escaping @MainActor () -> Void) -> Bool {
        guard restorations[key] == nil else { return false }
        restorations[key] = restoration
        order.append(key)
        return true
    }

    func restoreAll() {
        let pending = order.reversed().compactMap { restorations[$0] }
        order.removeAll()
        restorations.removeAll()
        pending.forEach { $0() }
    }

    /// Forget temporary restoration without running it. An agent-driven guide uses this only when
    /// the person presses Done: the requested destination remains visible as the outcome of
    /// "show me", while Exit and invalidation still put back app-owned navigation that the person
    /// did not subsequently change.
    func discardAll() {
        order.removeAll()
        restorations.removeAll()
    }

    var isEmpty: Bool { restorations.isEmpty }
}

enum GuidedHelpPresentationEndReason: Equatable {
    case completed
    case exited
    case replaced
    case ownerInvalidated
}

struct GuidedHelpPresentationHooks {
    var prepareStep: @MainActor (
        _ step: GuidedHelpPresentationStep,
        _ temporaryState: GuidedHelpTemporaryState
    ) -> Void = { _, _ in }
    var didFinish: @MainActor (_ reason: GuidedHelpPresentationEndReason) -> Void = { _ in }
    var restoresTemporaryState: @MainActor (
        _ reason: GuidedHelpPresentationEndReason
    ) -> Bool = { _ in true }
}

enum GuidedHelpPresentationStartResult: Equatable {
    case started
    case invalidGuide(GuidedHelpPresentationGuide.ValidationError)
    case ownerUnavailable
}

struct GuidedHelpPresentationSnapshot: Equatable {
    enum TargetState: Equatable {
        case available(frame: CGRect)
        case unavailable(GuidedHelpTargetUnavailableReason)
    }

    let guideID: String
    let corpusDigest: String
    let stepID: String
    let stepIndex: Int
    let stepCount: Int
    let target: GuidedHelpPresentationTarget
    let targetState: TargetState
    let calloutFrame: CGRect

    var canGoBack: Bool { stepIndex > 0 }
    var canAdvance: Bool {
        if case .available = targetState { return true }
        return false
    }
}

enum GuidedHelpMotionPolicy {
    static func transitionDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : 0.16
    }
}

struct GuidedHelpOverlayLayout: Equatable {
    let spotlightFrame: CGRect?
    let calloutFrame: CGRect

    static let margin: CGFloat = 16
    static let targetPadding: CGFloat = 7
    static let calloutGap: CGFloat = 14

    static func resolve(
        container: CGRect,
        target: CGRect?,
        calloutSize: CGSize
    ) -> GuidedHelpOverlayLayout {
        let safeContainer = container.insetBy(dx: margin, dy: margin)
        let availableWidth = max(0, safeContainer.width)
        let availableHeight = max(0, safeContainer.height)
        let fittedSize = CGSize(
            width: min(max(calloutSize.width, 260), availableWidth),
            height: min(max(calloutSize.height, 120), availableHeight))

        guard let target else {
            return GuidedHelpOverlayLayout(
                spotlightFrame: nil,
                calloutFrame: centered(size: fittedSize, in: safeContainer))
        }

        let spotlight = target.insetBy(dx: -targetPadding, dy: -targetPadding)
            .intersection(container)
        let candidates = [
            CGRect(
                x: spotlight.maxX + calloutGap,
                y: spotlight.midY - fittedSize.height / 2,
                width: fittedSize.width,
                height: fittedSize.height),
            CGRect(
                x: spotlight.minX - calloutGap - fittedSize.width,
                y: spotlight.midY - fittedSize.height / 2,
                width: fittedSize.width,
                height: fittedSize.height),
            CGRect(
                x: spotlight.midX - fittedSize.width / 2,
                y: spotlight.minY - calloutGap - fittedSize.height,
                width: fittedSize.width,
                height: fittedSize.height),
            CGRect(
                x: spotlight.midX - fittedSize.width / 2,
                y: spotlight.maxY + calloutGap,
                width: fittedSize.width,
                height: fittedSize.height),
        ]

        let callout = candidates.first(where: { safeContainer.contains($0) })
            ?? candidates.max(by: {
                intersectionArea($0, safeContainer) < intersectionArea($1, safeContainer)
            }).map { clamp($0, to: safeContainer) }
            ?? centered(size: fittedSize, in: safeContainer)

        return GuidedHelpOverlayLayout(
            spotlightFrame: spotlight.isEmpty ? nil : spotlight,
            calloutFrame: callout)
    }

    private static func centered(size: CGSize, in rect: CGRect) -> CGRect {
        CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height)
    }

    private static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        CGRect(
            x: min(max(rect.minX, bounds.minX), bounds.maxX - rect.width),
            y: min(max(rect.minY, bounds.minY), bounds.maxY - rect.height),
            width: rect.width,
            height: rect.height)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}

/// Captures a background AppKit view's accessibility state for one modal guide session.
@MainActor
private final class GuidedHelpAccessibilityHiddenState {
    weak var view: NSView?
    let wasHidden: Bool

    init(view: NSView) {
        self.view = view
        wasHidden = view.isAccessibilityHidden()
    }
}

/// Owns one temporary guide presentation in one exact workspace window.
@MainActor
final class GuidedHelpPresentationCoordinator {
    /// There is one modal teaching surface process-wide. A Help card and an agent tool may each
    /// own an exact-window coordinator, but starting either replaces the presentation already on
    /// screen instead of stacking two modal overlays in different windows.
    private static weak var activePresentation: GuidedHelpPresentationCoordinator?

    let owner: GuidedHelpPresentationOwner
    let registry: GuidedHelpTargetRegistry

    private let reduceMotion: () -> Bool
    private var guide: GuidedHelpPresentationGuide?
    private var stepIndex = 0
    private var hooks = GuidedHelpPresentationHooks()
    private var temporaryState = GuidedHelpTemporaryState()
    private var overlayView: GuidedHelpOverlayView?
    private var observerTokens: [NSObjectProtocol] = []
    private var refreshScheduled = false
    private weak var interactionWindow: NSWindow?
    private weak var priorFirstResponder: NSResponder?
    private var accessibilityHiddenStates: [GuidedHelpAccessibilityHiddenState] = []
    private var keyMonitor: Any?

    private(set) var snapshot: GuidedHelpPresentationSnapshot?

    convenience init?(
        bridge: AgentBridge,
        window: NSWindow,
        reduceMotion: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    ) {
        guard let owner = GuidedHelpPresentationOwner(bridge: bridge, window: window) else {
            return nil
        }
        self.init(owner: owner, reduceMotion: reduceMotion)
    }

    init(
        owner: GuidedHelpPresentationOwner,
        reduceMotion: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    ) {
        self.owner = owner
        registry = GuidedHelpTargetRegistry(owner: owner)
        self.reduceMotion = reduceMotion
        registry.onChange = { [weak self] in self?.scheduleRefresh() }
    }

    isolated deinit {
        observerTokens.forEach(NotificationCenter.default.removeObserver)
        dismantleModalInteraction()
    }

    @discardableResult
    func present(
        _ guide: GuidedHelpPresentationGuide,
        hooks: GuidedHelpPresentationHooks = GuidedHelpPresentationHooks()
    ) -> GuidedHelpPresentationStartResult {
        if let error = guide.validationError { return .invalidGuide(error) }
        guard owner.currentWindow != nil else { return .ownerUnavailable }
        if self.guide != nil { finish(.replaced) }
        if let active = Self.activePresentation, active !== self {
            active.finish(.replaced)
        }
        Self.activePresentation = self

        self.guide = guide
        self.hooks = hooks
        stepIndex = 0
        temporaryState = GuidedHelpTemporaryState()
        installOverlayIfNeeded()
        installObserversIfNeeded()
        prepareCurrentStep()
        refreshLayout()
        return .started
    }

    func goBack() {
        guard guide != nil, stepIndex > 0 else { return }
        stepIndex -= 1
        prepareCurrentStep()
        refreshLayout()
    }

    func advance() {
        guard let guide, snapshot?.canAdvance == true else { return }
        if stepIndex == guide.steps.count - 1 {
            finish(.completed)
            return
        }
        stepIndex += 1
        prepareCurrentStep()
        refreshLayout()
    }

    func exit() {
        guard guide != nil else { return }
        finish(.exited)
    }

    func refreshLayout() {
        guard let guide else { return }
        guard let window = owner.currentWindow, let contentView = window.contentView else {
            finish(.ownerInvalidated)
            return
        }
        guard guide.steps.indices.contains(stepIndex) else {
            finish(.ownerInvalidated)
            return
        }

        let step = guide.steps[stepIndex]
        installOverlayIfNeeded()
        guard let overlayView else { return }
        overlayView.frame = contentView.bounds
        let safeContainer = safeLayoutContainer(
            window: window,
            contentView: contentView,
            overlayView: overlayView)
        let resolution = registry.resolve(step.target)
        let targetFrame: CGRect?
        let targetState: GuidedHelpPresentationSnapshot.TargetState
        switch resolution {
        case .available(let frame):
            let frameInOverlay = overlayView.convert(frame, from: contentView)
                .intersection(safeContainer)
            if frameInOverlay.isNull || frameInOverlay.isEmpty {
                targetFrame = nil
                targetState = .unavailable(.outsideVisibleWindow)
            } else {
                targetFrame = frameInOverlay
                targetState = .available(frame: frameInOverlay)
            }
        case .unavailable(let reason):
            targetFrame = nil
            targetState = .unavailable(reason)
        }

        overlayView.updateCallout(
            guideTitle: guide.title,
            step: step,
            stepIndex: stepIndex,
            stepCount: guide.steps.count,
            targetAvailable: targetFrame != nil,
            canGoBack: stepIndex > 0,
            onBack: { [weak self] in self?.goBack() },
            onAdvance: { [weak self] in self?.advance() },
            onExit: { [weak self] in self?.exit() })

        let layout = GuidedHelpOverlayLayout.resolve(
            container: safeContainer,
            target: targetFrame,
            calloutSize: overlayView.calloutFittingSize)
        overlayView.apply(
            spotlightFrame: layout.spotlightFrame,
            calloutFrame: layout.calloutFrame,
            animationDuration: GuidedHelpMotionPolicy.transitionDuration(
                reduceMotion: reduceMotion()))
        snapshot = GuidedHelpPresentationSnapshot(
            guideID: guide.id,
            corpusDigest: guide.corpusDigest,
            stepID: step.id,
            stepIndex: stepIndex,
            stepCount: guide.steps.count,
            target: step.target,
            targetState: targetState,
            calloutFrame: layout.calloutFrame)
    }

    private func prepareCurrentStep() {
        guard let guide, guide.steps.indices.contains(stepIndex) else { return }
        hooks.prepareStep(guide.steps[stepIndex], temporaryState)
    }

    private func installOverlayIfNeeded() {
        guard overlayView == nil,
              let window = owner.currentWindow,
              let contentView = window.contentView else { return }
        let backgroundViews = contentView.subviews
        let overlay = GuidedHelpOverlayView(frame: contentView.bounds)
        overlay.autoresizingMask = [.width, .height]
        contentView.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlayView = overlay
        beginModalInteraction(
            window: window,
            overlay: overlay,
            backgroundViews: backgroundViews)
    }

    private func installObserversIfNeeded() {
        guard observerTokens.isEmpty, let window = owner.currentWindow else { return }
        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLayout() }
        })
        observerTokens.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.ownerInvalidated) }
        })
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshLayout()
        }
    }

    private func finish(_ reason: GuidedHelpPresentationEndReason) {
        guard guide != nil else { return }
        let didFinish = hooks.didFinish
        let restoresTemporaryState = hooks.restoresTemporaryState(reason)
        guide = nil
        stepIndex = 0
        snapshot = nil
        dismantleModalInteraction()
        observerTokens.forEach(NotificationCenter.default.removeObserver)
        observerTokens.removeAll()
        refreshScheduled = false
        if restoresTemporaryState {
            temporaryState.restoreAll()
        } else {
            temporaryState.discardAll()
        }
        temporaryState = GuidedHelpTemporaryState()
        hooks = GuidedHelpPresentationHooks()
        if Self.activePresentation === self { Self.activePresentation = nil }
        didFinish(reason)
    }

    private func beginModalInteraction(
        window: NSWindow,
        overlay: GuidedHelpOverlayView,
        backgroundViews: [NSView]
    ) {
        interactionWindow = window
        priorFirstResponder = window.firstResponder
        accessibilityHiddenStates = backgroundViews.map(GuidedHelpAccessibilityHiddenState.init)
        accessibilityHiddenStates.forEach { $0.view?.setAccessibilityHidden(true) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self, weak window] event in
            var intercepted = false
            MainActor.assumeIsolated {
                guard let self,
                      let window,
                      event.window === window,
                      self.interactionWindow === window,
                      self.overlayView?.window === window,
                      self.guide != nil else { return }
                let action = GuidedHelpModalKeyAction(event: event)
                guard action.interceptsInExactWindowMonitor else { return }
                _ = self.overlayView?.handleModalKeyDown(event)
                intercepted = true
            }
            // `NSEvent` is explicitly non-Sendable. Return it outside the isolated block, just as
            // the transcript's exact-scroll monitor does, so it never crosses an actor boundary.
            if intercepted { return nil }
            return event
        }
        overlay.focusForPresentation()
    }

    private func dismantleModalInteraction() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }

        let overlay = overlayView
        overlay?.setAccessibilityFocused(false)
        overlay?.removeFromSuperview()
        overlayView = nil

        accessibilityHiddenStates.forEach { state in
            state.view?.setAccessibilityHidden(state.wasHidden)
        }
        accessibilityHiddenStates.removeAll()

        if let window = interactionWindow {
            restorePriorFirstResponder(in: window, removedOverlay: overlay)
        }
        priorFirstResponder = nil
        interactionWindow = nil
    }

    private func restorePriorFirstResponder(
        in window: NSWindow,
        removedOverlay: GuidedHelpOverlayView?
    ) {
        if let view = priorFirstResponder as? NSView, view.window === window {
            window.makeFirstResponder(view)
        } else if priorFirstResponder === window {
            window.makeFirstResponder(window)
        } else if window.firstResponder === removedOverlay {
            window.makeFirstResponder(nil)
        }
    }

    private func safeLayoutContainer(
        window: NSWindow,
        contentView: NSView,
        overlayView: GuidedHelpOverlayView
    ) -> CGRect {
        let contentLayout = contentView.convert(window.contentLayoutRect, from: nil)
        let overlayLayout = overlayView.convert(contentLayout, from: contentView)
            .intersection(overlayView.bounds)
        return overlayLayout.isNull || overlayLayout.isEmpty
            ? overlayView.bounds
            : overlayLayout
    }
}

extension View {
    /// Registers an exact semantic target only when an owning guide registry exists. The authored
    /// guide never sees this view, its accessibility tree, or its geometry.
    @ViewBuilder
    func guidedHelpTarget(
        _ target: GuidedHelpPresentationTarget,
        registry: GuidedHelpTargetRegistry?
    ) -> some View {
        if let registry {
            background(GuidedHelpTargetAnchor(target: target, registry: registry))
        } else {
            self
        }
    }
}
