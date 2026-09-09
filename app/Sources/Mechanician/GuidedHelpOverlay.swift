import AppKit
import SwiftUI

private struct GuidedHelpCalloutPresentation: Equatable {
    let guideTitle: String
    let step: GuidedHelpPresentationStep
    let stepIndex: Int
    let stepCount: Int
    let targetAvailable: Bool
    let canGoBack: Bool
}

private struct GuidedHelpCalloutView: View {
    let presentation: GuidedHelpCalloutPresentation
    let onBack: () -> Void
    let onAdvance: () -> Void
    let onExit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: presentation.guideTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Step \(presentation.stepIndex + 1) of \(presentation.stepCount)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Exit", action: onExit)
                    .buttonStyle(PillButtonStyle(kind: .plain))
                    .accessibilityLabel("Exit guided help")
                    .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: presentation.step.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.nText)
                Text(verbatim: presentation.step.instruction)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.nText)
                    .fixedSize(horizontal: false, vertical: true)
                Label {
                    Text(verbatim: presentation.step.target.accessibilityName)
                } icon: {
                    Image(systemName: "scope")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(verbatim: String(
                    localized: "Target: \(presentation.step.target.accessibilityName)")))
            }

            if !presentation.targetAvailable {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        "This step’s control isn’t available in this window.",
                        systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.nWarningText)
                    Text("Wait for the expected control to appear, or exit the guide. The guide will not skip this step.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .cardSurface(cornerRadius: 8, strokeOpacity: 0.45)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Guided help target unavailable")
            }

            HStack(spacing: 8) {
                Button("Back", action: onBack)
                    .buttonStyle(PillButtonStyle(kind: .neutral))
                    .disabled(!presentation.canGoBack)
                    .accessibilityLabel("Previous guided help step")
                Spacer(minLength: 8)
                if presentation.stepIndex == presentation.stepCount - 1 {
                    Button("Done", action: onAdvance)
                        .buttonStyle(PillButtonStyle(kind: .accent))
                        .disabled(!presentation.targetAvailable)
                        .accessibilityLabel("Finish guided help")
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Next", action: onAdvance)
                        .buttonStyle(PillButtonStyle(kind: .accent))
                        .disabled(!presentation.targetAvailable)
                        .accessibilityLabel("Next guided help step")
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        .cardSurface(cornerRadius: 13, strokeOpacity: 0.7)
        .shadow(color: .black.opacity(0.24), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Guided help")
    }
}

/// Full-window AppKit overlay. AppKit owns the spotlight geometry and hit-test contract while the
/// callout itself stays ordinary SwiftUI content, matching the app's established shell boundary.
@MainActor
final class GuidedHelpOverlayView: NSView {
    private let calloutHost: NSHostingView<GuidedHelpCalloutView>
    private(set) var spotlightFrame: CGRect?
    private var canGoBack = false
    private var onBack: () -> Void = {}
    private var onAdvance: () -> Void = {}
    private var onExit: () -> Void = {}
    private var announcedStepID: String?

    /// Match the host content view's coordinate orientation. Target rectangles are resolved in that
    /// view's coordinates, and workspace roots can be either AppKit- or SwiftUI-hosted.
    override var isFlipped: Bool { superview?.isFlipped ?? false }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        let placeholder = GuidedHelpCalloutPresentation(
            guideTitle: "",
            step: GuidedHelpPresentationStep(
                id: "placeholder",
                target: .helpInspectorTab,
                title: "",
                instruction: ""),
            stepIndex: 0,
            stepCount: 1,
            targetAvailable: false,
            canGoBack: false)
        calloutHost = NSHostingView(rootView: GuidedHelpCalloutView(
            presentation: placeholder,
            onBack: {},
            onAdvance: {},
            onExit: {}))
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = 0
        addSubview(calloutHost)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Guided help"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var calloutFittingSize: CGSize {
        layoutSubtreeIfNeeded()
        let fitting = calloutHost.fittingSize
        return CGSize(
            width: 340,
            height: max(120, fitting.height.isFinite ? fitting.height : 220))
    }

    func updateCallout(
        guideTitle: String,
        step: GuidedHelpPresentationStep,
        stepIndex: Int,
        stepCount: Int,
        targetAvailable: Bool,
        canGoBack: Bool,
        onBack: @escaping () -> Void,
        onAdvance: @escaping () -> Void,
        onExit: @escaping () -> Void
    ) {
        calloutHost.rootView = GuidedHelpCalloutView(
            presentation: GuidedHelpCalloutPresentation(
                guideTitle: guideTitle,
                step: step,
                stepIndex: stepIndex,
                stepCount: stepCount,
                targetAvailable: targetAvailable,
                canGoBack: canGoBack),
            onBack: onBack,
            onAdvance: onAdvance,
            onExit: onExit)
        self.canGoBack = canGoBack
        self.onBack = onBack
        self.onAdvance = onAdvance
        self.onExit = onExit
        let targetName = step.target.accessibilityName
        let progressDescription = String(localized: "Step \(stepIndex + 1) of \(stepCount)")
        let targetDescription = String(localized: "Target: \(targetName)")
        let accessibilityDescription =
            "\(guideTitle). \(progressDescription). \(step.title). "
            + "\(step.instruction) \(targetDescription)"
        setAccessibilityValue(accessibilityDescription)
        calloutHost.layoutSubtreeIfNeeded()
        if announcedStepID != step.id {
            announcedStepID = step.id
            focusAndAnnounce(accessibilityDescription)
        }
    }

    func apply(
        spotlightFrame: CGRect?,
        calloutFrame: CGRect,
        animationDuration: TimeInterval
    ) {
        self.spotlightFrame = spotlightFrame
        needsDisplay = true
        if animationDuration == 0 || calloutHost.frame.isEmpty {
            calloutHost.frame = calloutFrame
            alphaValue = 1
            return
        }
        if alphaValue == 0 {
            calloutHost.frame = calloutFrame
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            calloutHost.animator().frame = calloutFrame
            animator().alphaValue = 1
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let dimmingPath = NSBezierPath(rect: bounds)
        if let spotlightFrame {
            dimmingPath.appendRoundedRect(
                spotlightFrame,
                xRadius: 9,
                yRadius: 9)
            dimmingPath.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.48).setFill()
        dimmingPath.fill()

        if let spotlightFrame {
            let ring = NSBezierPath(
                roundedRect: spotlightFrame,
                xRadius: 9,
                yRadius: 9)
            ring.lineWidth = 2
            NSColor.nBrandActionFill.setStroke()
            ring.stroke()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if calloutHost.frame.contains(point) { return super.hitTest(point) }
        return self
    }

    override func keyDown(with event: NSEvent) {
        if !handleModalKeyDown(event) {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func scrollWheel(with event: NSEvent) {
        // A user-advance guide is explanatory: scrolling dimmed content would move its semantic
        // target behind a modal callout. Back/Next/Exit remain the only guide navigation controls.
    }

    @discardableResult
    func handleModalKeyDown(_ event: NSEvent) -> Bool {
        switch GuidedHelpModalKeyAction(event: event) {
        case .exit:
            onExit()
            return true
        case .back:
            if canGoBack { onBack() }
            return true
        case .advance:
            onAdvance()
            return true
        case .containFocus, .consume:
            return true
        case .passThrough:
            return false
        }
    }

    func focusForPresentation() {
        window?.makeFirstResponder(self)
        setAccessibilityFocused(true)
        NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
    }

    private func focusAndAnnounce(_ announcement: String) {
        focusForPresentation()
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }
}

enum GuidedHelpModalKeyAction: Equatable {
    case exit
    case back
    case advance
    case containFocus
    case consume
    case passThrough

    init(event: NSEvent) {
        let systemModifiers = event.modifierFlags.intersection([.command, .control, .option])
        if !systemModifiers.isEmpty {
            self = .passThrough
            return
        }
        if event.keyCode == 53 { // Escape
            self = .exit
            return
        }
        if event.keyCode == 48 { // Tab or Shift-Tab stays in the modal guide.
            self = .containFocus
            return
        }
        if event.keyCode == 123 { // Unmodified Left Arrow returns to the previous guide step.
            if event.modifierFlags.contains(.shift) {
                self = .passThrough
            } else if event.isARepeat {
                self = .consume
            } else {
                self = .back
            }
            return
        }
        if !event.isARepeat,
           !event.modifierFlags.contains(.shift),
           [36, 49, 76].contains(event.keyCode) { // Return, Space, keypad Enter
            self = .advance
            return
        }
        self = .consume
    }

    /// A local monitor is needed only for keys AppKit might otherwise route to a key equivalent or
    /// another first responder. Ordinary typing can reach the overlay and be consumed by `keyDown`;
    /// command shortcuts and VoiceOver chords must remain in normal application/system dispatch.
    var interceptsInExactWindowMonitor: Bool {
        switch self {
        case .exit, .back, .advance, .containFocus:
            true
        case .consume, .passThrough:
            false
        }
    }
}
