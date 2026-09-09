import AppKit
import SwiftUI

/// Native header for a semantic group of consecutive tool activity. The actions themselves become
/// ordinary rows in the outer transcript table when disclosed, so AppKit realizes only the rows
/// visible in the transcript viewport instead of constructing a potentially enormous nested stack.
@MainActor
final class ActivityGroupHeaderCell: NSTableCellView {
    private let card = ActivityCardBackground()
    private var header: NSView?
    private var representedID: AnyHashable?
    private var representedRevision = 0
    private var topPadding: CGFloat = 0
    private var headerHeight: CGFloat = 38
    private var bottomSpacing: CGFloat = 12
    private var onMeasuredHeight: ((AnyHashable, Int, CGFloat) -> Void)?
    private var measurementScheduled = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(card)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setGroup(
        _ group: AppKitActivityGroup,
        id: AnyHashable,
        revision: Int,
        expanded: Bool,
        topPadding: CGFloat,
        onToggle: @escaping () -> Void,
        onMeasuredHeight: @escaping (AnyHashable, Int, CGFloat) -> Void
    ) {
        representedID = id
        representedRevision = revision
        self.topPadding = topPadding
        headerHeight = max(38, 38 * group.chatScale)
        bottomSpacing = expanded ? 0 : 12
        self.onMeasuredHeight = onMeasuredHeight

        header?.removeFromSuperview()
        let nextHeader = makeActivityHeader(group: group, expanded: expanded, action: onToggle)
        card.addSubview(nextHeader)
        header = nextHeader
        card.configure(expanded ? .top : .whole)
        needsLayout = true
        scheduleMeasurement()
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 32)
        card.frame = NSRect(x: 16, y: topPadding, width: width, height: headerHeight)
        header?.frame = card.bounds
    }

    private func scheduleMeasurement() {
        guard !measurementScheduled else { return }
        measurementScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurementScheduled = false
            guard let id = self.representedID else { return }
            self.onMeasuredHeight?(
                id, self.representedRevision,
                ceil(self.topPadding + self.headerHeight + self.bottomSpacing))
        }
    }
}

/// One lightweight action row inside an expanded Activity group. A rich SwiftUI renderer is added
/// only for the single action the user explicitly opens; every other action remains native AppKit.
@MainActor
final class ActivityActionCell: NSTableCellView {
    private let card = ActivityCardBackground()
    private var header: NSView?
    private var detailHost: ActivityDetailHostingView?
    private var representedID: AnyHashable?
    private var representedRevision = 0
    private var headerHeight: CGFloat = 32
    private var detailHeight: CGFloat = 0
    private var bottomSpacing: CGFloat = 0
    private var onMeasuredHeight: ((AnyHashable, Int, CGFloat) -> Void)?
    private var measurementScheduled = false
    private var lastReportedHeight: CGFloat?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(card)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setAction(
        _ action: AppKitActivityAction,
        presentationID: AnyHashable,
        revision: Int,
        title: String,
        expanded: Bool,
        isLast: Bool,
        chatScale: CGFloat,
        existingMeasuredHeight: CGFloat?,
        detail: AnyView?,
        onToggle: @escaping () -> Void,
        onMeasuredHeight: @escaping (AnyHashable, Int, CGFloat) -> Void
    ) {
        representedID = presentationID
        representedRevision = revision
        headerHeight = max(32, 32 * chatScale)
        bottomSpacing = isLast ? 12 : 0
        self.onMeasuredHeight = onMeasuredHeight
        lastReportedHeight = nil

        header?.removeFromSuperview()
        detailHost?.removeFromSuperview()
        detailHost = nil

        let nextHeader = makeActivityActionHeader(
            action: action,
            title: title,
            expanded: expanded,
            chatScale: chatScale,
            onToggle: onToggle)
        card.addSubview(nextHeader)
        header = nextHeader

        if let detail {
            let estimatedDetail = max(
                1,
                (existingMeasuredHeight ?? (headerHeight + 1 + bottomSpacing))
                    - headerHeight - bottomSpacing)
            detailHeight = estimatedDetail
            let padded = AnyView(detail
                .padding(.leading, 28)
                .padding(.trailing, 8)
                .padding(.bottom, 8))
            let host = ActivityDetailHostingView(root: padded) { [weak self] measuredHeight in
                guard let self else { return }
                self.detailHeight = measuredHeight
                self.needsLayout = true
                self.scheduleMeasurement()
            }
            card.addSubview(host)
            detailHost = host
        } else {
            detailHeight = 0
        }

        card.configure(isLast ? .bottom : .middle)
        needsLayout = true
        scheduleMeasurement()
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 32)
        let contentHeight = headerHeight + detailHeight
        card.frame = NSRect(x: 16, y: 0, width: width, height: contentHeight)
        header?.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)
        detailHost?.frame = NSRect(
            x: 0, y: headerHeight, width: width, height: detailHeight)
    }

    private func scheduleMeasurement() {
        guard !measurementScheduled else { return }
        measurementScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurementScheduled = false
            guard let id = self.representedID else { return }
            let total = ceil(self.headerHeight + self.detailHeight + self.bottomSpacing)
            if let previous = self.lastReportedHeight, abs(previous - total) <= 0.5 { return }
            self.lastReportedHeight = total
            self.onMeasuredHeight?(id, self.representedRevision, total)
        }
    }
}

@MainActor
private func makeActivityHeader(
    group: AppKitActivityGroup,
    expanded: Bool,
    action: @escaping () -> Void
) -> NSView {
    let header = NSView()
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 7
    row.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(row)
    let trailing = row.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10)
    let bottom = row.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6)
    // NSTableView can configure and reuse a cell while its autoresizing-mask boundary is still
    // zero-sized. Keep the near edges authoritative, but let the far edges yield during that
    // transient state instead of forcing AppKit to break the header's required width/height mask.
    // At every realized row size these pins remain satisfiable and preserve the exact insets.
    trailing.priority = .init(999)
    bottom.priority = .init(999)
    NSLayoutConstraint.activate([
        row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
        trailing,
        row.topAnchor.constraint(equalTo: header.topAnchor, constant: 6),
        bottom,
    ])

    row.addArrangedSubview(activitySymbolView(
        expanded ? "chevron.down" : "chevron.right", color: .secondaryLabelColor))
    if group.isRunning {
        row.addArrangedSubview(activityProgressView())
    } else {
        // Refusal ranks below a real failure and above "nothing to report": a group that only
        // contains declined calls must not wear the red error symbol, because nothing went wrong.
        row.addArrangedSubview(activitySymbolView(
            group.failedCount > 0 ? "exclamationmark.circle.fill"
                : group.stoppedCount > 0 ? "stop.circle"
                : group.refusedCount > 0 ? "hand.raised.circle" : "checkmark.circle",
            color: group.failedCount > 0 ? .systemRed : .secondaryLabelColor))
    }

    let summaryText = activitySummary(group.actions)
    let summary = activityLabel(
        summaryText,
        size: 12 * group.chatScale,
        weight: .semibold,
        color: .labelColor)
    summary.lineBreakMode = .byTruncatingTail
    summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    row.addArrangedSubview(summary)

    if group.failedCount > 0 {
        let failed = activityLabel(
            "\(group.failedCount) failed",
            size: 11 * group.chatScale,
            weight: .medium,
            color: .nErrorText)
        failed.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(failed)
    }
    if group.stoppedCount > 0 {
        let stopped = activityLabel(
            "\(group.stoppedCount) stopped",
            size: 11 * group.chatScale,
            weight: .medium,
            color: .secondaryLabelColor)
        stopped.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(stopped)
    }
    if group.refusedCount > 0 {
        // "denied" is the word the permission card beside this group uses for the same event.
        let refused = activityLabel(
            "\(group.refusedCount) denied",
            size: 11 * group.chatScale,
            weight: .medium,
            color: .secondaryLabelColor)
        refused.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(refused)
    }
    if !expanded, group.supersededCount > 0 {
        row.addArrangedSubview(ActivitySupersededBadgeView(chatScale: group.chatScale))
    }

    let button = ActivityClosureButton(action: action)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.isBordered = false
    button.title = ""
    button.setAccessibilityLabel(activityGroupAccessibilityLabel(
        summaryText,
        supersededCount: group.supersededCount))
    button.setAccessibilityHelp(expanded
        ? "Showing \(group.actions.count) actions. Press to collapse."
        : "Press to show \(group.actions.count) actions.")
    header.addSubview(button)
    NSLayoutConstraint.activate([
        button.leadingAnchor.constraint(equalTo: header.leadingAnchor),
        button.trailingAnchor.constraint(equalTo: header.trailingAnchor),
        button.topAnchor.constraint(equalTo: header.topAnchor),
        button.bottomAnchor.constraint(equalTo: header.bottomAnchor),
    ])
    return header
}

@MainActor
private func makeActivityActionHeader(
    action: AppKitActivityAction,
    title: String,
    expanded: Bool,
    chatScale: CGFloat,
    onToggle: @escaping () -> Void
) -> NSView {
    let header = NSView()
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 7
    row.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(row)
    let trailing = row.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10)
    let bottom = row.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -5)
    // Action rows have the same zero-sized construction/reuse phase as their group header.
    trailing.priority = .init(999)
    bottom.priority = .init(999)
    NSLayoutConstraint.activate([
        row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 29),
        trailing,
        row.topAnchor.constraint(equalTo: header.topAnchor, constant: 5),
        bottom,
    ])

    if action.state == .running {
        // Use the same compositor-owned animation as the group summary. A static hourglass made an
        // expanded group look idle even while one of its individual actions was still executing.
        row.addArrangedSubview(activityProgressView())
    } else {
        row.addArrangedSubview(activitySymbolView(
            action.state == .failed ? "exclamationmark.circle.fill"
                : action.state == .stopped ? "stop.circle"
                : action.state == .refused ? "hand.raised.circle"
                : activitySymbol(action.toolName),
            color: action.state == .failed ? .systemRed : .secondaryLabelColor))
    }
    let titleLabel = activityLabel(
        title,
        size: 11.5 * chatScale,
        weight: .regular,
        color: action.state == .failed ? .nErrorText : .labelColor)
    titleLabel.lineBreakMode = .byTruncatingMiddle
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    row.addArrangedSubview(titleLabel)
    if action.isSuperseded {
        row.addArrangedSubview(ActivitySupersededBadgeView(chatScale: chatScale))
    }
    let trailingSpacer = NSView()
    trailingSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
    trailingSpacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    row.addArrangedSubview(trailingSpacer)
    row.addArrangedSubview(activitySymbolView(
        expanded ? "chevron.down" : "chevron.right", color: .tertiaryLabelColor))

    let button = ActivityClosureButton(action: onToggle)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.isBordered = false
    button.title = ""
    button.setAccessibilityLabel(supersededActionAccessibilityLabel(
        title,
        isSuperseded: action.isSuperseded))
    button.setAccessibilityHelp(expanded
        ? "Showing details. Press to collapse."
        : "Press to show details.")
    header.addSubview(button)
    NSLayoutConstraint.activate([
        button.leadingAnchor.constraint(equalTo: header.leadingAnchor),
        button.trailingAnchor.constraint(equalTo: header.trailingAnchor),
        button.topAnchor.constraint(equalTo: header.topAnchor),
        button.bottomAnchor.constraint(equalTo: header.bottomAnchor),
    ])
    return header
}

@MainActor
private final class ActivityDetailHostingView: NSView {
    private let controller: NSHostingController<AnyView>
    private let onSizeChange: (CGFloat) -> Void
    private var measuredHeight: CGFloat = 1
    private var lastWidth: CGFloat?
    private var measurementScheduled = false
    private var passesRemaining = 2
    private var hostFrameObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }

    init(root: AnyView, onSizeChange: @escaping (CGFloat) -> Void) {
        controller = NSHostingController(rootView: root)
        self.onSizeChange = onSizeChange
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        controller.sizingOptions = [.intrinsicContentSize]
        let host = controller.view
        // The native detail frame is authoritative. Measuring starts from a one-point placeholder;
        // an intrinsically tall SwiftUI root must not escape that placeholder and paint upward
        // through the action header while AppKit is accepting its real height.
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        host.postsFrameChangedNotifications = true
        addSubview(host)
        hostFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: host,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.bounds.width > 0 else { return }
                self.passesRemaining = max(self.passesRemaining, 1)
                self.scheduleMeasurement()
            }
        }
        scheduleMeasurement()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let hostFrameObserver { NotificationCenter.default.removeObserver(hostFrameObserver) }
    }

    override func layout() {
        super.layout()
        let host = controller.view
        if host.frame != bounds { host.frame = bounds }
        guard bounds.width > 0,
              lastWidth.map({ abs($0 - bounds.width) > 0.5 }) ?? true else { return }
        passesRemaining = max(passesRemaining, 1)
        scheduleMeasurement()
    }

    private func scheduleMeasurement() {
        guard passesRemaining > 0, !measurementScheduled else { return }
        measurementScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurementScheduled = false
            self.measure()
            self.passesRemaining = max(0, self.passesRemaining - 1)
            self.scheduleMeasurement()
        }
    }

    private func measure() {
        guard bounds.width > 0 else { return }
        let host = controller.view
        host.updateConstraintsForSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        let height = ceil(controller.sizeThatFits(
            in: NSSize(width: bounds.width, height: .greatestFiniteMagnitude)).height)
        guard height.isFinite, height > 0 else { return }
        lastWidth = bounds.width
        guard abs(measuredHeight - height) > 0.5 else { return }
        measuredHeight = height
        onSizeChange(height)
    }
}

private final class ActivityCardBackground: NSView {
    enum Segment { case whole, top, middle, bottom }

    private let divider = NSView()
    private var segment: Segment = .whole

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        divider.wantsLayer = true
        divider.isHidden = true
        divider.setAccessibilityIdentifier("ActivityHeaderDivider")
        addSubview(divider)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ segment: Segment) {
        self.segment = segment
        let corners: CACornerMask
        switch segment {
        case .whole:
            corners = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                       .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        case .top:
            corners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        case .middle:
            corners = []
        case .bottom:
            corners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
        layer?.cornerRadius = segment == .middle ? 0 : 8
        layer?.maskedCorners = corners
        divider.isHidden = segment != .top
        updateColors()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        divider.frame = NSRect(
            x: 10,
            y: max(0, bounds.height - 1),
            width: max(0, bounds.width - 20),
            height: 1)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        // Routine Activity should feel grouped, not boxed in. A quiet continuous surface carries
        // the grouping; expanded headers get one internal divider, while failure/permission states
        // keep their existing semantic accents instead of every row drawing permanent border lines.
        let alpha: CGFloat = segment == .whole ? 0.50 : 0.34
        let appearance = effectiveAppearance
        layer?.backgroundColor = NSColor.controlBackgroundColor
            .mechanicianCGColor(in: appearance, alpha: alpha)
        layer?.borderWidth = 0
        layer?.borderColor = nil
        divider.layer?.backgroundColor = NSColor.separatorColor
            .mechanicianCGColor(in: appearance, alpha: 0.30)
    }
}

private final class ActivityClosureButton: NSButton {
    private let closure: () -> Void

    init(action: @escaping () -> Void) {
        closure = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(invoke)
        focusRingType = .default
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() { closure() }
}

private func activityLabel(
    _ text: String,
    size: CGFloat,
    weight: NSFont.Weight,
    color: NSColor
) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.maximumNumberOfLines = 1
    return field
}

/// A deliberately quiet status capsule: superseded tool work is important audit evidence, but it
/// is no longer part of the model's live answer and should not compete with failure state.
private final class ActivitySupersededBadgeView: NSView {
    private let label: NSTextField

    override var isFlipped: Bool { true }

    init(chatScale: CGFloat) {
        label = activityLabel(
            "Superseded",
            size: 9.5 * chatScale,
            weight: .semibold,
            color: .secondaryLabelColor)
        super.init(frame: .zero)
        addSubview(label)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(false)
        label.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let labelSize = label.intrinsicContentSize
        return NSSize(width: labelSize.width + 12, height: labelSize.height + 4)
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 6, dy: 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let capsule = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25),
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2)
        NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
        capsule.fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.25).setStroke()
        capsule.lineWidth = 0.5
        capsule.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

func supersededActionAccessibilityLabel(_ base: String, isSuperseded: Bool) -> String {
    guard isSuperseded else { return base }
    let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
    let sentence = trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    return "\(sentence). Superseded. Retained as audit evidence because this action may already have run."
}

func activityGroupAccessibilityLabel(_ summary: String, supersededCount: Int) -> String {
    guard supersededCount > 0 else { return summary }
    let noun = supersededCount == 1 ? "action is" : "actions are"
    return "\(summary). \(supersededCount) superseded \(noun) retained as audit evidence."
}

private func activitySymbolView(_ name: String, color: NSColor) -> NSImageView {
    let view = NSImageView()
    view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    view.contentTintColor = color
    view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalToConstant: 14).isActive = true
    view.heightAnchor.constraint(equalToConstant: 14).isActive = true
    return view
}

private func activityProgressView() -> OrbitingDotsLayerView {
    let view = OrbitingDotsLayerView()
    view.configure(
        color: nil,
        reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalToConstant: 14).isActive = true
    view.heightAnchor.constraint(equalToConstant: 14).isActive = true
    return view
}

func activitySummary(_ actions: [AppKitActivityAction]) -> String {
    var counts: [ActivityCategory: Int] = [:]
    for action in actions {
        let category = ActivityCategory(toolName: action.toolName)
        counts[category, default: 0] += 1
    }
    let populated = ActivityCategory.displayOrder.filter { counts[$0] != nil }
    let visible = populated.prefix(3).compactMap { category -> String? in
        guard let count = counts[category] else { return nil }
        return category.countSummary(count)
    }
    let base = visible.joined(separator: " · ")
    let hidden = populated.count - visible.count
    return hidden > 0 ? "\(base) · +\(hidden) more" : (base.isEmpty ? "Tool activity" : base)
}

@MainActor
func activityActionTitle(_ action: AppKitActivityAction) -> String {
    let summary = AgentBridge.toolTitle(name: action.toolName, rawInput: action.rawInput)
    if action.state == .stopped { return "Stopped \(summary)" }
    // Before the per-tool verbs, all of which are past tense and would claim the call happened.
    // "Ran mkdir …" for a command the person refused is the plainest form of the whole bug.
    if action.state == .refused { return "Denied \(summary)" }
    let running = action.state == .running
    switch action.toolName {
    case "Bash": return "\(running ? "Running" : "Ran") \(summary)"
    case "Read": return "\(running ? "Reading" : "Read") \(summary)"
    case "Write": return "\(running ? "Writing" : "Wrote") \(summary)"
    case "Edit", "MultiEdit", "NotebookEdit":
        return "\(running ? "Editing" : "Edited") \(summary)"
    case "Glob", "Grep": return "\(running ? "Searching" : "Searched") \(summary)"
    case "WebSearch": return "\(running ? "Searching" : "Searched") \(summary)"
    case "WebFetch": return "\(running ? "Fetching" : "Fetched") \(summary)"
    case "ComputerScreenshot": return running ? "Capturing screenshot" : "Captured screenshot"
    case "ComputerAction": return computerActionTitle(action.rawInput, running: running)
    case "ImageGeneration": return running ? "Generating image" : "Generated image"
    case "Task", "Agent": return "\(running ? "Delegating" : "Delegated") \(summary)"
    default:
        if summary == action.toolName { return "\(running ? "Using" : "Used") \(action.toolName)" }
        return "\(running ? "Using" : "Used") \(action.toolName) · \(summary)"
    }
}

private func computerActionTitle(_ rawInput: String, running: Bool) -> String {
    let input = rawInput.data(using: .utf8)
        .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    let action = (input?["action"] as? String)?.lowercased()
    switch action {
    case "click": return running ? "Clicking" : "Clicked"
    case "doubleclick": return running ? "Double-clicking" : "Double-clicked"
    case "rightclick": return running ? "Right-clicking" : "Right-clicked"
    case "type": return running ? "Typing text" : "Typed text"
    case "key": return running ? "Pressing a key" : "Pressed a key"
    case "scroll": return running ? "Scrolling" : "Scrolled"
    case "launch_app": return running ? "Opening an app" : "Opened an app"
    case "wait": return running ? "Waiting" : "Waited"
    default: return running ? "Using the computer" : "Used the computer"
    }
}

private func activitySymbol(_ toolName: String) -> String {
    switch ActivityCategory(toolName: toolName) {
    case .edit: return "pencil"
    case .read: return "doc.text"
    case .search: return "magnifyingglass"
    case .command: return "terminal"
    case .web: return "globe"
    case .computer: return "display"
    case .delegate: return "person.2"
    case .other: return "wrench.and.screwdriver"
    }
}

private enum ActivityCategory: Hashable {
    case edit, read, search, command, web, computer, delegate, other

    static let displayOrder: [ActivityCategory] = [
        .edit, .read, .search, .command, .web, .computer, .delegate, .other,
    ]

    init(toolName: String) {
        switch toolName {
        case "Edit", "MultiEdit", "Write", "NotebookEdit": self = .edit
        case "Read": self = .read
        case "Glob", "Grep": self = .search
        case "Bash": self = .command
        case "WebFetch", "WebSearch": self = .web
        case "ComputerAction", "ComputerScreenshot": self = .computer
        case "Task", "Agent": self = .delegate
        default: self = .other
        }
    }

    func countSummary(_ count: Int) -> String {
        let noun: String
        switch self {
        case .edit: noun = "write"
        case .read: noun = "read"
        case .search: noun = "search"
        case .command: noun = "command"
        case .web: noun = "web action"
        case .computer: noun = "computer action"
        case .delegate: noun = "delegation"
        case .other: noun = "tool"
        }
        return "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
