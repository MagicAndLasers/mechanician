import AppKit
import Combine
import SwiftUI

// MARK: - SwiftUI boundary

/// The inspector still switches tabs in SwiftUI, but the complete Agents surface on the other side
/// of this seam is AppKit. In particular, this bridge never creates an `NSHostingView`: scrolling,
/// rows, controls, the resizable split, timers, hit testing, and chart drawing all remain native.
struct AgentsPanel: NSViewRepresentable {
    @EnvironmentObject private var bridge: AgentBridge

    func makeNSView(context: Context) -> NSView {
        AppKitAgentsPanelView(bridge: bridge)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? AppKitAgentsPanelView)?.setBridge(bridge)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? AppKitAgentsPanelView)?.shutdown()
    }
}

// MARK: - Deterministic list snapshot

enum AppKitAgentsGroup: String, CaseIterable, Equatable {
    case active
    case attention
    case completed

    var title: String {
        switch self {
        case .active: return "Active"
        // Not "Needs attention": these agents failed or were stopped, and there is nothing for the
        // person to do about it. Naming a section for an action nobody can take makes an ordinary
        // provider failure read as a demand.
        case .attention: return "Didn't finish"
        case .completed: return "Completed"
        }
    }
}

enum AppKitAgentsListItem: Equatable {
    case root
    case group(AppKitAgentsGroup, count: Int, expanded: Bool)
    case subagent(key: String, depth: Int)
    case workflow(key: String, expanded: Bool)
    case workflowAgent(runKey: String, agentKey: String, ordinal: Int, depth: Int)

    var id: String {
        switch self {
        case .root: return "root"
        case .group(let group, _, _): return "group:\(group.rawValue)"
        case .subagent(let key, _): return "subagent:\(key)"
        case .workflow(let key, _): return "workflow:\(key)"
        case .workflowAgent(let runKey, let agentKey, _, _):
            return "workflow-agent:\(runKey):\(agentKey)"
        }
    }
}

/// The one deterministic sort for a workflow-run value. The list view caches this projection and
/// reuses it until that specific run changes; row height, cell configuration, and ticking then
/// carry the already-computed ordinal instead of sorting the complete agent set again.
struct AppKitWorkflowAgentOrdering: Equatable {
    let orderedAgentKeys: [String]

    init(_ run: WorkflowRun) {
        orderedAgentKeys = run.agents.values.sorted {
            if $0.phaseIndex != $1.phaseIndex { return $0.phaseIndex < $1.phaseIndex }
            if $0.index != $1.index { return $0.index < $1.index }
            return $0.id < $1.id
        }
        .map(\.id)
    }
}

/// A pure, deterministic reducer for the native table. Tests can validate grouping and row order
/// without constructing an AppKit window, while the panel can compare snapshots before rebuilding
/// its table. A timer tick and a pointer move never call this reducer.
struct AppKitAgentsListSnapshot: Equatable {
    var items: [AppKitAgentsListItem]
    var activeCount: Int
    var attentionCount: Int
    var completedCount: Int
    var unfilteredCount: Int

    static func make(
        subagents: [String: SubagentRun],
        workflowRuns: [String: WorkflowRun],
        search rawSearch: String,
        attentionExpanded: Bool,
        completedExpanded: Bool,
        expandedWorkflowKeys: Set<String> = [],
        workflowAgentOrderings: [String: AppKitWorkflowAgentOrdering] = [:],
        includeRoot: Bool = false
    ) -> Self {
        let search = rawSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ subagent: SubagentRun) -> Bool {
            search.isEmpty
                || subagent.task.localizedCaseInsensitiveContains(search)
                || subagent.subagentType.localizedCaseInsensitiveContains(search)
                || (subagent.summary?.localizedCaseInsensitiveContains(search) ?? false)
                || (subagent.error?.localizedCaseInsensitiveContains(search) ?? false)
        }
        func matches(_ run: WorkflowRun) -> Bool {
            search.isEmpty
                || (run.workflowName?.localizedCaseInsensitiveContains(search) ?? false)
                || run.description.localizedCaseInsensitiveContains(search)
                || (run.summary?.localizedCaseInsensitiveContains(search) ?? false)
                || (run.error?.localizedCaseInsensitiveContains(search) ?? false)
        }

        let filteredSubagents = subagents.filter { matches($0.value) }
        func stableTreeOrder(_ nodes: [SubagentTreeNode]) -> [SubagentTreeNode] {
            nodes.map {
                SubagentTreeNode(sub: $0.sub, children: stableTreeOrder($0.children))
            }
            .sorted {
                if $0.sub.startedAt != $1.sub.startedAt {
                    return $0.sub.startedAt < $1.sub.startedAt
                }
                return $0.sub.key < $1.sub.key
            }
        }
        let forest = stableTreeOrder(subagentForest(filteredSubagents))
        let activeRoots = forest.filter(\.hasRunning)
        let attentionRoots = forest
            .filter { !$0.hasRunning && $0.hasAttention }
            .compactMap { $0.prunedToAttention() }
        let completedRoots = forest.filter { !$0.hasRunning && !$0.hasAttention }

        let filteredRuns = workflowRuns.values.filter(matches).sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.runKey < $1.runKey
        }
        let activeRuns = filteredRuns.filter(appKitWorkflowHasLiveWork)
        let attentionRuns = filteredRuns.filter {
            !appKitWorkflowHasLiveWork($0) && effectiveRunStatus($0).needsAttention
        }
        let completedRuns = filteredRuns.filter {
            !appKitWorkflowHasLiveWork($0) && !effectiveRunStatus($0).needsAttention
        }

        let activeCount = activeRoots.reduce(0) { $0 + $1.count } + activeRuns.count
        let attentionCount = attentionRoots.reduce(0) { $0 + $1.count } + attentionRuns.count
        let completedCount = completedRoots.reduce(0) { $0 + $1.count } + completedRuns.count
        var items: [AppKitAgentsListItem] = includeRoot ? [.root] : []

        func append(_ nodes: [SubagentTreeNode], depth: Int = 0) {
            for node in nodes {
                items.append(.subagent(key: node.sub.key, depth: depth))
                append(node.children, depth: depth + 1)
            }
        }
        func appendGroup(
            _ group: AppKitAgentsGroup,
            roots: [SubagentTreeNode],
            runs: [WorkflowRun],
            count: Int,
            expanded: Bool
        ) {
            guard count > 0 else { return }
            items.append(.group(group, count: count, expanded: expanded))
            guard expanded else { return }
            append(roots)
            for run in runs {
                let runExpanded = expandedWorkflowKeys.contains(run.runKey)
                items.append(.workflow(key: run.runKey, expanded: runExpanded))
                if runExpanded {
                    let ordering = workflowAgentOrderings[run.runKey]
                        ?? AppKitWorkflowAgentOrdering(run)
                    items.append(contentsOf: ordering.orderedAgentKeys.enumerated().map {
                        .workflowAgent(
                            runKey: run.runKey,
                            agentKey: $0.element,
                            ordinal: $0.offset + 1,
                            depth: 1)
                    })
                }
            }
        }

        appendGroup(.active, roots: activeRoots, runs: activeRuns, count: activeCount, expanded: true)
        appendGroup(
            .attention,
            roots: attentionRoots,
            runs: attentionRuns,
            count: attentionCount,
            expanded: attentionExpanded)
        appendGroup(
            .completed,
            roots: completedRoots,
            runs: completedRuns,
            count: completedCount,
            expanded: completedExpanded)

        return Self(
            items: items,
            activeCount: activeCount,
            attentionCount: attentionCount,
            completedCount: completedCount,
            unfilteredCount: subagents.count + workflowRuns.count)
    }
}

struct AppKitAgentsPanelDebugCounters: Equatable {
    var listSnapshotRebuilds = 0
    var tableGraphRebuilds = 0
    var workflowAgentOrderingSorts = 0
    var activityModelRebuilds = 0
    var timerOnlyRedraws = 0
    var pointerOnlyRedraws = 0
}

private struct AppKitAgentsPanelReloadScope: OptionSet {
    let rawValue: UInt8

    static let list = Self(rawValue: 1 << 0)
    static let activity = Self(rawValue: 1 << 1)
    static let detail = Self(rawValue: 1 << 2)
    static let all: Self = [.list, .activity, .detail]
}

/// The production list's horizontal geometry, exposed narrowly so a regression test can exercise
/// the complete NSTableView/NSClipView stack rather than an isolated card cell.
struct AppKitAgentsListGeometrySnapshot: Equatable {
    var clipBounds: NSRect
    var documentFrame: NSRect
    var viewportInDocument: NSRect
    var cellFrameInDocument: NSRect
    var cardFrameInDocument: NSRect
}

// MARK: - Panel container and native split

final class AppKitAgentsPanelView: NSView {
    /// Agent presentation is not state ingestion. Default mode pauses both the live clock and
    /// bridge-driven redraws while AppKit owns a nested menu or drag tracking loop.
    static let presentationRunLoopMode = RunLoop.Mode.default

    private enum Defaults {
        static let timelineHeight = "agentsActivityTimelineHeight"
        static let timelineShown = "agentsActivityTimelineShown"
        static let compactRows = "agentsCompactRows"
    }

    private let listView: AppKitAgentsListView
    private let activityView: AppKitAgentActivityPanelView
    private let divider = AppKitAgentsSplitDividerView()
    private let showTimelineButton = NSButton()
    private let liveActivityReloadDelay: TimeInterval
    private let applicationIsActive: @MainActor () -> Bool
    private var bridge: AgentBridge
    private var observations = Set<AnyCancellable>()
    private var ticker: Timer?
    private var detailView: AppKitAgentDetailView?
    private var reloadScheduled = false
    private var scheduledReloadIsLiveDeferred = false
    private var reloadScheduleGeneration: UInt = 0
    private var pendingReloadScope: AppKitAgentsPanelReloadScope = []
    private var activityReloadPending = false
    private var isShutDown = false

    private var timelineHeight: CGFloat {
        didSet {
            let value = Double(timelineHeight)
            UserDefaults.standard.set(value, forKey: Defaults.timelineHeight)
            needsLayout = true
        }
    }
    private var timelineShown: Bool {
        didSet {
            UserDefaults.standard.set(timelineShown, forKey: Defaults.timelineShown)
            updateTimelineVisibility()
        }
    }

    private(set) var debugCounters = AppKitAgentsPanelDebugCounters()
    var hasDeferredActivityReloadForTesting: Bool { activityReloadPending }
    var hasDeferredLiveReloadForTesting: Bool {
        reloadScheduled && scheduledReloadIsLiveDeferred
    }
    var hasPendingPresentationReloadForTesting: Bool { !pendingReloadScope.isEmpty }
    var activityVisualizationModeForTesting: AppKitAgentActivityVisualizationMode {
        activityView.visualizationMode
    }
    var activityVisualizationControlModeForTesting: AppKitAgentActivityVisualizationMode? {
        activityView.visualizationControlModeForTesting
    }
    var activityTrendMetricForTesting: AppKitAgentActivityTrendMetric {
        activityView.trendMetricForTesting
    }
    func setActivityVisualizationModeForTesting(
        _ mode: AppKitAgentActivityVisualizationMode
    ) {
        activityView.setVisualizationModeForTesting(mode)
    }
    func showRuntimeOnlyActivityForTesting(_ samples: [HarnessMetricSample]) {
        activityView.showRuntimeOnlyActivityForTesting(samples)
    }
    @discardableResult
    func reloadHarnessMetricSamplesForTesting(_ samples: [HarnessMetricSample]) -> Bool {
        let rebuilt = activityView.reloadFromBridge(
            harnessMetricSamplesOverrideForTesting: samples)
        if rebuilt { debugCounters.activityModelRebuilds += 1 }
        return rebuilt
    }
    func setActivityTrendMetricForTesting(_ metric: AppKitAgentActivityTrendMetric) {
        activityView.setTrendMetricForTesting(metric)
    }
    func activityControlFramesForTesting() -> (
        mode: NSRect,
        metric: NSRect,
        chart: NSRect
    ) {
        activityView.layoutSubtreeIfNeeded()
        return activityView.controlFramesForTesting
    }
    func setTimelineShownForTesting(_ shown: Bool) {
        guard timelineShown != shown else { return }
        if shown {
            presentTimeline()
        } else {
            timelineShown = false
        }
    }
    var rootStopButtonForTesting: NSButton? {
        listView.rootStopButtonForTesting
    }
    func listGeometryForTesting(
        scrollingCellToVisible: Bool = false
    ) -> AppKitAgentsListGeometrySnapshot? {
        listView.geometryForTesting(scrollingCellToVisible: scrollingCellToVisible)
    }
    func workflowAgentBadgeForTesting(runKey: String, agentKey: String) -> String? {
        listView.workflowAgentBadgeForTesting(runKey: runKey, agentKey: agentKey)
    }
    var listRowHeightMeasurementCountForTesting: Int {
        listView.rowHeightMeasurementCount
    }

    override var isFlipped: Bool { true }

    init(
        bridge: AgentBridge,
        liveActivityReloadDelay: TimeInterval = 1.0 / 60.0,
        applicationIsActive: @escaping @MainActor () -> Bool = { NSApp.isActive }
    ) {
        self.bridge = bridge
        self.liveActivityReloadDelay = max(0, liveActivityReloadDelay)
        self.applicationIsActive = applicationIsActive
        let defaults = UserDefaults.standard
        let storedHeight = defaults.object(forKey: Defaults.timelineHeight) as? Double
        timelineHeight = CGFloat(storedHeight ?? 270)
        timelineShown = defaults.object(forKey: Defaults.timelineShown) == nil
            ? true
            : defaults.bool(forKey: Defaults.timelineShown)
        listView = AppKitAgentsListView(bridge: bridge)
        activityView = AppKitAgentActivityPanelView(bridge: bridge)
        super.init(frame: .zero)

        wantsLayer = true
        setAccessibilityElement(false)

        addSubview(listView)
        addSubview(divider)
        addSubview(activityView)
        configureShowTimelineButton()
        addSubview(showTimelineButton)

        listView.onOpenSubagent = { [weak self] subagent in
            self?.showDetail(for: subagent)
        }
        listView.onOpenWorkflow = { [weak self] run in
            self?.showDetail(for: run)
        }
        listView.onOpenWorkflowAgent = { [weak self] run, agent in
            self?.showDetail(for: agent, in: run)
        }
        activityView.onClose = { [weak self] in
            self?.timelineShown = false
        }
        divider.onBeginDrag = { [weak self] in self?.timelineHeight ?? 270 }
        divider.onDrag = { [weak self] startingHeight, deltaY in
            guard let self else { return }
            // This view is flipped: dragging the divider up has a negative delta and makes the
            // bottom activity pane taller.
            self.timelineHeight = self.clampedTimelineHeight(startingHeight - deltaY)
        }
        setBridge(bridge)
        updateTimelineVisibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setBridge(_ bridge: AgentBridge) {
        guard !isShutDown else { return }
        guard self.bridge !== bridge || observations.isEmpty else { return }
        observations.removeAll()
        self.bridge = bridge
        listView.setBridge(bridge)
        activityView.setBridge(bridge)
        reloadScheduleGeneration &+= 1
        reloadScheduled = false
        scheduledReloadIsLiveDeferred = false
        pendingReloadScope = []
        activityReloadPending = false
        observeBridgeChanges()
        reloadFromBridge(.all)
    }

    private func scopedPublisher<Value>(
        _ publisher: Published<Value>.Publisher,
        scope: AppKitAgentsPanelReloadScope
    ) -> AnyPublisher<AppKitAgentsPanelReloadScope, Never> {
        publisher
            .dropFirst()
            .map { _ in scope }
            .eraseToAnyPublisher()
    }

    /// The transcript is AgentBridge's hottest publication stream, but this panel renders none of
    /// it. Subscribe only to the provider-neutral projections the native list, chart, and detail
    /// actually read, and keep metric-only updates away from the list entirely.
    private func observeBridgeChanges() {
        let publishers: [AnyPublisher<AppKitAgentsPanelReloadScope, Never>] = [
            scopedPublisher(bridge.$currentID, scope: .all),
            scopedPublisher(bridge.$subagents, scope: .all),
            scopedPublisher(bridge.$workflowRuns, scope: .all),
            scopedPublisher(bridge.$harnessMetricSamples, scope: .activity),
            scopedPublisher(bridge.$isWorking, scope: .list),
            scopedPublisher(bridge.$isStreaming, scope: .list),
            scopedPublisher(bridge.$turnStartedAt, scope: .list),
            scopedPublisher(bridge.$runningConvs, scope: .list),
            scopedPublisher(bridge.$activeAgents, scope: .list),
            scopedPublisher(bridge.$provider, scope: .list),
            scopedPublisher(bridge.$model, scope: .list),
            scopedPublisher(bridge.$authMode, scope: .list),
            scopedPublisher(bridge.$ultracode, scope: .list),
            // A duplicate viewer can show the same conversation whose route lives in another
            // bridge. The process-wide running union is the narrow signal for that owner starting
            // or stopping; without it a missing root row cannot be repaired by the one-second tick.
            ActiveWorkspace.shared.$runningConversations
                .dropFirst()
                .map { _ in AppKitAgentsPanelReloadScope.list }
                .eraseToAnyPublisher(),
            // ConversationStore intentionally keeps token accumulation off this publication
            // plane. Retain its bounded semantic boundary so a cross-window model selection or
            // provisional root reservation refreshes the list without restoring transcript churn.
            bridge.store.objectWillChange
                .map { AppKitAgentsPanelReloadScope.list }
                .eraseToAnyPublisher(),
            // Publications received while Mechanician is inactive leave one accumulated dirty
            // scope. Activation is the exact lifecycle edge that consumes it.
            NotificationCenter.default
                .publisher(for: NSApplication.didBecomeActiveNotification)
                .map { _ in AppKitAgentsPanelReloadScope.all }
                .eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(publishers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] scope in
                self?.scheduleReload(scope)
            }
            .store(in: &observations)

        // Activity arrives as a burst of small provider events. Rebuilding the complete list and
        // timeline after every row can hold the main thread long enough to delay editor key events,
        // so collect nonterminal rows for one display frame. A terminal row bypasses the window:
        // completed/failed/stopped state must become truthful immediately.
        bridge.$agentActivity
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] records in
                let terminal = records.last?.kind == .state
                    && records.last?.phase?.isTerminal == true
                self?.scheduleReload(.all, deferLiveActivity: !terminal)
            }
            .store(in: &observations)
    }

    /// `@Published` sends before assignment. Accumulate the relevant scopes and read one coherent
    /// bridge snapshot on the next main-run-loop turn, preserving the former event coalescing
    /// without observing unrelated bridge state.
    private func scheduleReload(
        _ scope: AppKitAgentsPanelReloadScope,
        deferLiveActivity: Bool = false
    ) {
        pendingReloadScope.formUnion(scope)
        guard applicationIsActive() else {
            // A callback may already be waiting when the app resigns. Invalidate it but retain the
            // accumulated scope; didBecomeActive schedules the single catch-up presentation.
            if reloadScheduled {
                reloadScheduleGeneration &+= 1
                reloadScheduled = false
                scheduledReloadIsLiveDeferred = false
            }
            return
        }
        let shouldDefer = deferLiveActivity && liveActivityReloadDelay > 0
        if reloadScheduled {
            guard scheduledReloadIsLiveDeferred, !shouldDefer else { return }
            // Supersede the deferred callback with a next-run-loop delivery. Its generation check
            // turns the old callback into a no-op without losing the accumulated scopes.
            reloadScheduleGeneration &+= 1
            reloadScheduled = false
        }
        reloadScheduled = true
        scheduledReloadIsLiveDeferred = shouldDefer
        reloadScheduleGeneration &+= 1
        let generation = reloadScheduleGeneration
        if shouldDefer {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + liveActivityReloadDelay
            ) { [weak self] in
                self?.enqueueScheduledReload(generation: generation)
            }
        } else {
            enqueueScheduledReload(generation: generation)
        }
    }

    private func enqueueScheduledReload(generation: UInt) {
        RunLoop.main.perform(inModes: [Self.presentationRunLoopMode]) { [weak self] in
            self?.performScheduledReload(generation: generation)
        }
    }

    private func performScheduledReload(generation: UInt) {
        guard !isShutDown, reloadScheduled,
              reloadScheduleGeneration == generation else { return }
        guard applicationIsActive() else {
            // Preserve pendingReloadScope for the activation publisher to consume.
            reloadScheduled = false
            scheduledReloadIsLiveDeferred = false
            return
        }
        reloadScheduled = false
        scheduledReloadIsLiveDeferred = false
        let scope = pendingReloadScope
        pendingReloadScope = []
        guard !scope.isEmpty else { return }
        reloadFromBridge(scope)
    }

    func flushPendingReloadForTesting() {
        guard reloadScheduled else { return }
        reloadScheduleGeneration &+= 1
        reloadScheduled = false
        scheduledReloadIsLiveDeferred = false
        let scope = pendingReloadScope
        pendingReloadScope = []
        guard !scope.isEmpty else { return }
        reloadFromBridge(scope)
    }

    /// SwiftUI can dismantle the representable without first detaching it from a window. Release
    /// both native lifecycle sources explicitly so a closed inspector cannot keep observing or
    /// ticking in the background.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        observations.removeAll()
        ticker?.invalidate()
        ticker = nil
        reloadScheduleGeneration &+= 1
        reloadScheduled = false
        scheduledReloadIsLiveDeferred = false
        pendingReloadScope = []
        activityReloadPending = false
    }

    deinit {
        ticker?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            ticker?.invalidate()
            ticker = nil
        } else if ticker == nil, !isShutDown {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(timer, forMode: Self.presentationRunLoopMode)
            ticker = timer
            tick()
        }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        if let detailView {
            detailView.frame = bounds
            return
        }

        if timelineShown {
            let dividerHeight: CGFloat = 7
            let activityHeight = clampedTimelineHeight(timelineHeight)
            let topHeight = max(0, height - activityHeight - dividerHeight)
            listView.frame = NSRect(x: 0, y: 0, width: width, height: topHeight)
            divider.frame = NSRect(x: 0, y: topHeight, width: width, height: dividerHeight)
            activityView.frame = NSRect(
                x: 0,
                y: topHeight + dividerHeight,
                width: width,
                height: activityHeight)
        } else {
            let revealHeight: CGFloat = 29
            listView.frame = NSRect(x: 0, y: 0, width: width, height: max(0, height - revealHeight))
            showTimelineButton.frame = NSRect(
                x: 0,
                y: max(0, height - revealHeight),
                width: width,
                height: revealHeight)
        }
    }

    private func configureShowTimelineButton() {
        showTimelineButton.title = "Show activity timeline"
        showTimelineButton.image = NSImage(
            systemSymbolName: "waveform.path.ecg",
            accessibilityDescription: nil)
        showTimelineButton.imagePosition = .imageLeading
        showTimelineButton.bezelStyle = .inline
        showTimelineButton.font = .systemFont(ofSize: 10, weight: .medium)
        showTimelineButton.contentTintColor = .secondaryLabelColor
        showTimelineButton.target = self
        showTimelineButton.action = #selector(showTimeline)
        showTimelineButton.toolTip =
            "Show token, state, context maintenance, and user-guidance activity"
        showTimelineButton.setAccessibilityLabel("Show activity timeline")
    }

    @objc private func showTimeline() {
        presentTimeline()
    }

    private func presentTimeline() {
        activityView.resetVisualizationModeToTrace()
        timelineShown = true
    }

    private func updateTimelineVisibility() {
        activityView.isHidden = !timelineShown
        divider.isHidden = !timelineShown
        showTimelineButton.isHidden = timelineShown
        reloadDeferredActivityIfVisible()
        needsLayout = true
    }

    private func clampedTimelineHeight(_ proposed: CGFloat) -> CGFloat {
        let available = max(0, bounds.height - 150 - 7)
        return min(760, max(min(180, available), min(proposed, available)))
    }

    private func reloadFromBridge(_ scope: AppKitAgentsPanelReloadScope) {
        if scope.contains(.list) {
            debugCounters.listSnapshotRebuilds += 1
            if listView.reloadFromBridge() {
                debugCounters.tableGraphRebuilds += 1
            }
            debugCounters.workflowAgentOrderingSorts =
                listView.workflowAgentOrderingSortCount
        }
        if scope.contains(.activity) {
            if timelineShown, detailView == nil {
                activityReloadPending = false
                reloadActivityModelIfNeeded()
            } else {
                activityReloadPending = true
            }
        }
        if scope.contains(.detail), let detailView {
            let stillExists = detailView.refreshIfNeeded(
                subagents: bridge.subagents,
                workflowRuns: bridge.workflowRuns,
                activity: bridge.agentActivity)
            if !stillExists { hideDetail() }
        }
    }

    private func reloadActivityModelIfNeeded() {
        if activityView.reloadFromBridge() {
            debugCounters.activityModelRebuilds += 1
        }
    }

    private func reloadDeferredActivityIfVisible() {
        guard timelineShown, detailView == nil, activityReloadPending, !isShutDown else { return }
        activityReloadPending = false
        reloadActivityModelIfNeeded()
    }

    private func tick() {
        guard applicationIsActive() else { return }
        if let detailView {
            guard detailView.needsLiveTick else { return }
            detailView.tick(now: Date())
            debugCounters.timerOnlyRedraws += 1
            return
        }
        guard bridge.currentConversationHasRootWork
                || bridge.hasRunningDelegate
                || (timelineShown && activityView.needsLiveTick) else { return }
        let now = Date()
        listView.tick(now: now)
        if timelineShown { activityView.tick(now: now) }
        debugCounters.timerOnlyRedraws += 1
    }

    func tickForTesting() {
        tick()
    }

    private func showDetail(for subagent: SubagentRun) {
        let view = AppKitAgentDetailView()
        view.onBack = { [weak self] in self?.hideDetail() }
        view.onStopTask = { [weak bridge] taskID in bridge?.stopTask(taskID) }
        view.configure(
            subagent: subagent,
            ordinal: agentActivitySubagentOrdinals(bridge.subagents)[subagent.key],
            activity: bridge.agentActivity,
            now: Date())
        detailView = view
        listView.isHidden = true
        activityView.isHidden = true
        divider.isHidden = true
        showTimelineButton.isHidden = true
        addSubview(view)
        needsLayout = true
    }

    private func showDetail(for run: WorkflowRun) {
        let view = AppKitAgentDetailView()
        view.onBack = { [weak self] in self?.hideDetail() }
        view.onStopTask = { [weak bridge] taskID in bridge?.stopTask(taskID) }
        view.configure(workflow: run, now: Date())
        detailView = view
        listView.isHidden = true
        activityView.isHidden = true
        divider.isHidden = true
        showTimelineButton.isHidden = true
        addSubview(view)
        needsLayout = true
    }

    private func showDetail(for agent: WorkflowAgent, in run: WorkflowRun) {
        let view = AppKitAgentDetailView()
        view.onBack = { [weak self] in self?.hideDetail() }
        view.onStopTask = { [weak bridge] taskID in bridge?.stopTask(taskID) }
        view.configure(workflowAgent: agent, in: run, activity: bridge.agentActivity, now: Date())
        detailView = view
        listView.isHidden = true
        activityView.isHidden = true
        divider.isHidden = true
        showTimelineButton.isHidden = true
        addSubview(view)
        needsLayout = true
    }

    private func hideDetail() {
        detailView?.removeFromSuperview()
        detailView = nil
        listView.isHidden = false
        updateTimelineVisibility()
        needsLayout = true
    }
}

private final class AppKitAgentsSplitDividerView: NSView {
    var onBeginDrag: (() -> CGFloat)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    private var startingHeight: CGFloat = 0
    private var startingY: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize activity timeline")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: floor(bounds.midY), width: bounds.width, height: 1).fill()
        let handle = NSBezierPath(
            roundedRect: NSRect(x: bounds.midX - 15, y: bounds.midY - 1, width: 30, height: 2),
            xRadius: 1,
            yRadius: 1)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.45).setFill()
        handle.fill()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        startingHeight = onBeginDrag?() ?? 0
        startingY = superview?.convert(event.locationInWindow, from: nil).y ?? 0
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let currentY = superview?.convert(next.locationInWindow, from: nil).y ?? startingY
            onDrag?(startingHeight, currentY - startingY)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126:
            onDrag?(onBeginDrag?() ?? 0, -10)
        case 125:
            onDrag?(onBeginDrag?() ?? 0, 10)
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        onDrag?(onBeginDrag?() ?? 0, -10)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onDrag?(onBeginDrag?() ?? 0, 10)
        return true
    }
}

// MARK: - Native list

private final class AppKitAgentsTableView: NSTableView {
    var onActivateSelectedRow: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            guard selectedRow >= 0 else {
                NSSound.beep()
                return
            }
            onActivateSelectedRow?(selectedRow)
            return
        }
        super.keyDown(with: event)
    }
}

private final class AppKitAgentsListView: NSView,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSSearchFieldDelegate
{
    private enum Defaults {
        static let compactRows = "agentsCompactRows"
    }

    private var bridge: AgentBridge
    private let controls = NSView()
    private let searchField = NSSearchField()
    private let densityButton = NSButton()
    private let rootSummary = AppKitRootAgentSummaryView()
    private let scrollView = NSScrollView()
    private let tableView = AppKitAgentsTableView()
    private let emptyView = AppKitAgentsEmptyView()

    private var snapshot = AppKitAgentsListSnapshot(
        items: [],
        activeCount: 0,
        attentionCount: 0,
        completedCount: 0,
        unfilteredCount: 0)
    private var previousSubagents: [String: SubagentRun] = [:]
    private var previousRuns: [String: WorkflowRun] = [:]
    private var previousActivity: [AgentActivityRecord] = []
    private var previousRootWorking = false
    private var previousRootSelection: ModelSelection?
    private var previousRootStartedAt: Date?
    private var previousRootPresent = false
    private var hasLoadedBridgeSnapshot = false
    private var attentionExpanded = true
    private var completedExpanded = false
    private var expandedWorkflowKeys: Set<String> = []
    private var knownWorkflowKeys: Set<String> = []
    private var workflowAgentOrderings: [String: AppKitWorkflowAgentOrdering] = [:]
    private(set) var workflowAgentOrderingSortCount = 0
    private(set) var rowHeightMeasurementCount = 0
    private var compactRows: Bool {
        didSet {
            UserDefaults.standard.set(compactRows, forKey: Defaults.compactRows)
            updateDensityButton()
            rebuildSnapshot(forceTableReload: true)
        }
    }
    private let activityIndexCache = AgentActivityLedgerIndexCache()
    private var activityIndex = AgentActivityLedgerIndex([])
    private var conversationActivityIndex = AgentConversationActivityIndex([])
    private var ordinals: [String: Int] = [:]
    private var lastNow = Date()

    var onOpenSubagent: ((SubagentRun) -> Void)?
    var onOpenWorkflow: ((WorkflowRun) -> Void)?
    var onOpenWorkflowAgent: ((WorkflowRun, WorkflowAgent) -> Void)?
    var rootStopButtonForTesting: NSButton? {
        guard let row = snapshot.items.firstIndex(of: .root) else { return nil }
        return (tableView.view(
            atColumn: 0,
            row: row,
            makeIfNecessary: true) as? AppKitAgentTableCellView)?
            .stopButtonForTesting
    }

    override var isFlipped: Bool { true }

    init(bridge: AgentBridge) {
        self.bridge = bridge
        compactRows = UserDefaults.standard.bool(forKey: Defaults.compactRows)
        super.init(frame: .zero)
        configureControls()
        configureTable()
        addSubview(controls)
        addSubview(rootSummary)
        addSubview(scrollView)
        addSubview(emptyView)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setBridge(_ bridge: AgentBridge) {
        guard self.bridge !== bridge else { return }
        self.bridge = bridge
        previousSubagents = [:]
        previousRuns = [:]
        previousActivity = []
        previousRootSelection = nil
        previousRootStartedAt = nil
        previousRootPresent = false
        workflowAgentOrderings = [:]
        hasLoadedBridgeSnapshot = false
    }

    /// Returns true only when the table's row graph changed. Ordinary activity samples update the
    /// already-visible native cells in place.
    @discardableResult
    func reloadFromBridge() -> Bool {
        let firstSnapshot = !hasLoadedBridgeSnapshot
        let previousRunsValue = previousRuns
        let previousActivityValue = previousActivity
        let subagentsChanged = firstSnapshot || previousSubagents != bridge.subagents
        let runsChanged = firstSnapshot || previousRuns != bridge.workflowRuns
        let activityChanged = firstSnapshot || previousActivityValue != bridge.agentActivity
        let appendedActivity: ArraySlice<AgentActivityRecord>? = {
            guard !firstSnapshot,
                  bridge.agentActivity.count > previousActivityValue.count,
                  bridge.agentActivity.prefix(previousActivityValue.count)
                    .elementsEqual(previousActivityValue) else { return nil }
            return bridge.agentActivity.dropFirst(previousActivityValue.count)
        }()
        let rootWorking = bridge.currentConversationHasRootWork
        let workingChanged = firstSnapshot || previousRootWorking != rootWorking
        let rootSelection = bridge.currentConversation?.modelSelection
            ?? bridge.selectedModelSelection
        let rootSelectionChanged = firstSnapshot || previousRootSelection != rootSelection
        let rootStartedAtChanged = firstSnapshot || previousRootStartedAt != bridge.turnStartedAt

        hasLoadedBridgeSnapshot = true
        previousSubagents = bridge.subagents
        previousRuns = bridge.workflowRuns
        previousActivity = bridge.agentActivity
        previousRootWorking = rootWorking
        previousRootSelection = rootSelection
        previousRootStartedAt = bridge.turnStartedAt

        var activityAliases: [String: String] = [:]
        if activityChanged || subagentsChanged || runsChanged {
            // Same reconciliation the trace lanes use, so a card and its lane agree about which
            // activity belongs to the agent.
            let aliases = agentActivityAliases(
                subagents: bridge.subagents,
                workflowRuns: bridge.workflowRuns)
            activityAliases = aliases
            activityIndex = activityIndexCache.index(
                for: bridge.agentActivity,
                aliases: aliases)
            conversationActivityIndex = AgentConversationActivityIndex(
                bridge.agentActivity,
                aliases: aliases)
        }
        if subagentsChanged {
            ordinals = agentActivitySubagentOrdinals(bridge.subagents)
        }
        if runsChanged {
            var nextOrderings: [String: AppKitWorkflowAgentOrdering] = [:]
            nextOrderings.reserveCapacity(bridge.workflowRuns.count)
            for (key, run) in bridge.workflowRuns {
                if previousRunsValue[key] == run,
                   let existing = workflowAgentOrderings[key] {
                    nextOrderings[key] = existing
                } else {
                    nextOrderings[key] = AppKitWorkflowAgentOrdering(run)
                    workflowAgentOrderingSortCount += 1
                }
            }
            workflowAgentOrderings = nextOrderings

            let currentKeys = Set(bridge.workflowRuns.keys)
            let newlySeen = currentKeys.subtracting(knownWorkflowKeys)
            for key in newlySeen {
                if let run = bridge.workflowRuns[key],
                   effectiveRunStatus(run).needsAttention {
                    expandedWorkflowKeys.insert(key)
                }
            }
            for (key, run) in bridge.workflowRuns
            where effectiveRunStatus(run).needsAttention
                && previousRunsValue[key].map({ !effectiveRunStatus($0).needsAttention }) != false {
                expandedWorkflowKeys.insert(key)
            }
            expandedWorkflowKeys.formIntersection(currentKeys)
            knownWorkflowKeys = currentKeys
        }

        let rootPresent = currentRootSnapshot(now: lastNow) != nil
        let rootPresenceChanged = firstSnapshot || rootPresent != previousRootPresent
        previousRootPresent = rootPresent
        var graphChanged = false
        if subagentsChanged || runsChanged || rootPresenceChanged {
            graphChanged = rebuildSnapshot(forceTableReload: false)
        } else if activityChanged
            || workingChanged
            || rootSelectionChanged
            || rootStartedAtChanged {
            refreshVisibleRows()
        }
        if activityChanged || subagentsChanged || runsChanged {
            if graphChanged {
                // `rebuildSnapshot` already invalidated the new table graph. Repeating the same
                // all-row notification here made AppKit measure every card twice.
            } else if activityChanged,
                      !subagentsChanged,
                      !runsChanged,
                      let appendedActivity {
                // The ledger is append-only in normal operation. Card presentation is lane-local,
                // so one provider event should not remeasure hundreds of unrelated workflow rows.
                let rows = rowsAffectedByAppendedActivity(
                    appendedActivity,
                    aliases: activityAliases)
                if !rows.isEmpty {
                    tableView.noteHeightOfRows(withIndexesChanged: rows)
                    needsLayout = true
                }
            } else {
                // Replacement, truncation, reordering, and alias changes can alter any card.
                // Metrics, summary, error, and composition are independent optional rows, so a
                // structural-value change with a stable row graph still requires full invalidation.
                tableView.noteHeightOfRows(
                    withIndexesChanged: IndexSet(integersIn: 0..<snapshot.items.count))
                needsLayout = true
            }
        } else if !rootPresenceChanged,
                  workingChanged || rootSelectionChanged || rootStartedAtChanged,
                  let rootRow = snapshot.items.firstIndex(of: .root) {
            // A new provider turn can replace a rich terminal root with the pre-ledger "Starting"
            // card while retaining the same structural row identity. Invalidate that cached height
            // even though no activity record has arrived yet.
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: rootRow))
            needsLayout = true
        }
        if activityChanged || workingChanged || subagentsChanged || runsChanged {
            rootSummary.configure(
                conversationActivityIndex.snapshot(
                    subagents: bridge.subagents,
                    workflowRuns: bridge.workflowRuns,
                    isRootWorking: rootWorking,
                    now: lastNow))
        }
        updateEmptyView()
        needsLayout = true
        return graphChanged
    }

    private func rowsAffectedByAppendedActivity(
        _ records: ArraySlice<AgentActivityRecord>,
        aliases: [String: String]
    ) -> IndexSet {
        let changedLanes = Set(records.map { aliases[$0.agentID] ?? $0.agentID })
        var rows = IndexSet()
        for (row, item) in snapshot.items.enumerated() {
            let identity: String
            switch item {
            case .root:
                // Selecting the active/latest turn is a whole-ledger decision. A child event can
                // therefore change the root projection even though child card data stays local.
                rows.insert(row)
                continue
            case .subagent(let key, _):
                identity = AgentActivityIdentity.subagent(key)
            case .workflowAgent(let runKey, let agentKey, _, _):
                identity = AgentActivityIdentity.workflow(
                    runKey: runKey,
                    agentKey: agentKey)
            case .group, .workflow:
                continue
            }
            if changedLanes.contains(aliases[identity] ?? identity) {
                rows.insert(row)
            }
        }
        return rows
    }

    private func currentRootSnapshot(now: Date) -> AgentRootActivitySnapshot? {
        conversationActivityIndex.rootSnapshot(
            isRootWorking: bridge.currentConversationHasRootWork,
            liveSelection: bridge.currentConversation?.modelSelection
                ?? bridge.selectedModelSelection,
            liveStartedAt: bridge.turnStartedAt,
            now: now)
    }

    func tick(now: Date) {
        lastNow = now
        let priorRootHeight = rootSummary.preferredHeight(for: rootSummary.bounds.width)
        rootSummary.configure(
            conversationActivityIndex.snapshot(
                subagents: bridge.subagents,
                workflowRuns: bridge.workflowRuns,
                isRootWorking: bridge.currentConversationHasRootWork,
                now: now))
        if rootSummary.preferredHeight(for: rootSummary.bounds.width) != priorRootHeight {
            // A duration crossing a fitting threshold can move complete metrics onto their fallback
            // row. Relayout only at that boundary; ordinary one-second text refreshes remain local.
            needsLayout = true
        }
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound else { return }
        let end = min(tableView.numberOfRows, range.location + range.length)
        guard range.location < end else { return }
        for row in range.location..<end {
            guard let view = tableView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false) as? AppKitAgentTableCellView else { continue }
            if snapshot.items[row] == .root {
                configure(view, item: .root)
            } else {
                view.tick(now: now)
            }
        }
        // Deliberately no unconditional `needsLayout = true`. The cells refresh their own elapsed
        // text; forcing a full relayout once a second re-framed the whole panel and looked jittery.
    }

    override func layout() {
        super.layout()
        let controlsHeight: CGFloat = snapshot.unfilteredCount > 0 ? 42 : 0
        controls.isHidden = controlsHeight == 0
        controls.frame = NSRect(x: 0, y: 0, width: bounds.width, height: controlsHeight)
        layoutControls()

        // Inset to the same gutter the table's content insets give the agent cards below, so this
        // strip reads as the first card in the list rather than a band bleeding to both edges.
        let rootInset = AgentCard.inset
        let rootWidth = max(0, bounds.width - rootInset * 2)
        let rootHeight = rootSummary.preferredHeight(for: rootWidth)
        rootSummary.frame = NSRect(
            x: rootInset,
            y: controlsHeight,
            width: rootWidth,
            height: rootHeight)
        let bodyY = controlsHeight + rootHeight
        let bodyFrame = NSRect(
            x: 0,
            y: bodyY,
            width: bounds.width,
            height: max(0, bounds.height - bodyY))
        scrollView.frame = bodyFrame
        emptyView.frame = bodyFrame
        layoutTableDocument()
    }

    private func configureControls() {
        searchField.placeholderString = "Filter agents"
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Filter agents")
        searchField.identifier = NSUserInterfaceItemIdentifier("agents-search")
        controls.addSubview(searchField)

        densityButton.isBordered = false
        densityButton.target = self
        densityButton.action = #selector(toggleDensity)
        densityButton.identifier = NSUserInterfaceItemIdentifier("agents-density")
        controls.addSubview(densityButton)
        updateDensityButton()
    }

    private func layoutControls() {
        let inset: CGFloat = 10
        let buttonWidth: CGFloat = 28
        densityButton.frame = NSRect(
            x: max(inset, controls.bounds.width - inset - buttonWidth),
            y: 7,
            width: buttonWidth,
            height: 28)
        searchField.frame = NSRect(
            x: inset,
            y: 7,
            width: max(40, densityButton.frame.minX - inset - 7),
            height: 28)
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("agents"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 5)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableClicked)
        tableView.doubleAction = #selector(tableDoubleClicked)
        tableView.onActivateSelectedRow = { [weak self] row in self?.activate(row: row) }
        tableView.setAccessibilityLabel("Agents")
        // `.fullWidth` still places every cell six points inboard and expands the table document by
        // twelve points on current macOS. Giving its column the viewport width therefore leaves a
        // valid horizontal scroll range even with the scroller hidden, and the card can bleed from
        // either edge depending on the clip view's retained origin. `.plain` plus zero horizontal
        // intercell spacing is the one style whose cell and document both exactly span the viewport;
        // the custom row view below already owns the rounded selection treatment.
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        // Deliberately NOT `.width`, and no column autoresizing: both snap the table back to the
        // clip view's full width, overriding the inset-aware width computed in
        // `layoutTableDocument()` and pushing each row's right edge outside the visible area.
        tableView.autoresizingMask = []
        tableView.columnAutoresizingStyle = .noColumnAutoresizing

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.contentInsets = NSEdgeInsets(top: 7, left: 0, bottom: 8, right: 0)
        scrollView.automaticallyAdjustsContentInsets = false
    }

    private func layoutTableDocument() {
        // `contentSize` is the clip view's size; the content insets shift the document inside it
        // rather than shrinking it. Sizing rows to the full width therefore pushed each row's
        // right edge (and its rounded corner) out past the visible area by the inset amount.
        // The table spans the full clip width and each card insets itself. Deriving the row width
        // from the scroll view's geometry meant three different mechanisms (content insets,
        // autoresizing, column autoresizing) each got a vote on it, and the row kept ending up
        // wider than the visible area.
        let contentWidth = max(1, scrollView.contentSize.width)
        let column = tableView.tableColumns.first
        let widthChanged = abs(tableView.frame.width - contentWidth) > 0.5
            || column.map { abs($0.width - contentWidth) > 0.5 } == true

        // Frame first, then the column. Setting the frame re-runs column autoresizing, which was
        // widening the column straight back to the full clip width and undoing the inset.
        if abs(tableView.frame.width - contentWidth) > 0.5 {
            tableView.frame = NSRect(
                x: 0,
                y: 0,
                width: contentWidth,
                height: tableView.frame.height)
        }
        if let column, abs(column.width - contentWidth) > 0.5 {
            column.width = contentWidth
        }
        if widthChanged, tableView.numberOfRows > 0 {
            // Card text wraps at the viewport width. Width is the one layout input that can change
            // every row without a model publication, so invalidate once at that boundary.
            tableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
        }

        let rowsHeight: CGFloat
        if tableView.numberOfRows > 0 {
            // NSTableView owns the variable-height cache. Asking for the final row's geometry fills
            // any invalid entries once and then stays O(1); directly invoking the delegate here
            // measured every agent again after `noteHeightOfRows` had just done the same work.
            // Plain-style row rects include one trailing intercell gap, which the previous document
            // height deliberately omitted.
            rowsHeight = max(
                0,
                tableView.rect(ofRow: tableView.numberOfRows - 1).maxY
                    - tableView.intercellSpacing.height)
        } else {
            rowsHeight = 0
        }
        let frame = NSRect(
            x: 0,
            y: 0,
            width: contentWidth,
            height: max(scrollView.contentSize.height, rowsHeight))
        if abs(tableView.frame.width - frame.width) > 0.5
            || abs(tableView.frame.height - frame.height) > 0.5 {
            tableView.frame = frame
        }
        // A hidden horizontal scroller does not prevent programmatic scrolling (including
        // `scrollToVisible` during focus/accessibility changes). Clear an origin retained from an
        // earlier oversized document while preserving the user's vertical position.
        let clipView = scrollView.contentView
        if clipView.bounds.minX != 0 {
            clipView.scroll(to: NSPoint(x: 0, y: clipView.bounds.minY))
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    func geometryForTesting(
        scrollingCellToVisible: Bool
    ) -> AppKitAgentsListGeometrySnapshot? {
        layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        guard let row = snapshot.items.firstIndex(where: {
            if case .group = $0 { return false }
            return true
        }),
        let cell = tableView.view(
            atColumn: 0,
            row: row,
            makeIfNecessary: true) as? AppKitAgentTableCellView else { return nil }

        cell.layoutSubtreeIfNeeded()
        if scrollingCellToVisible {
            cell.scrollToVisible(cell.bounds)
        }

        let depth: Int
        switch snapshot.items[row] {
        case .subagent(_, let itemDepth), .workflowAgent(_, _, _, let itemDepth):
            depth = itemDepth
        case .root, .group, .workflow:
            depth = 0
        }
        return AppKitAgentsListGeometrySnapshot(
            clipBounds: scrollView.contentView.bounds,
            documentFrame: tableView.frame,
            viewportInDocument: tableView.visibleRect,
            cellFrameInDocument: cell.convert(cell.bounds, to: tableView),
            cardFrameInDocument: cell.convert(
                appKitAgentCardRect(in: cell.bounds, depth: depth),
                to: tableView))
    }

    func workflowAgentBadgeForTesting(runKey: String, agentKey: String) -> String? {
        guard let item = snapshot.items.first(where: {
            guard case .workflowAgent(
                let candidateRunKey,
                let candidateAgentKey,
                _,
                _
            ) = $0 else { return false }
            return candidateRunKey == runKey && candidateAgentKey == agentKey
        }),
        case .workflowAgent(_, _, let ordinal, _) = item,
        let run = bridge.workflowRuns[runKey],
        let agent = run.agents[agentKey] else { return nil }
        let activity = activityIndex.cardSnapshot(
            agentID: AgentActivityIdentity.workflow(
                runKey: runKey,
                agentKey: agentKey),
            now: lastNow)
        return appKitWorkflowAgentCardPresentation(
            agent,
            in: run,
            ordinal: ordinal,
            activity: activity,
            now: lastNow)
            .badges.first?.text
    }

    @objc private func toggleDensity() {
        compactRows.toggle()
    }

    private func updateDensityButton() {
        densityButton.image = NSImage(
            systemSymbolName: compactRows
                ? "rectangle.expand.vertical"
                : "rectangle.compress.vertical",
            accessibilityDescription: nil)
        densityButton.contentTintColor = compactRows ? .controlAccentColor : .secondaryLabelColor
        let label = compactRows ? "Show full agent cards" : "Show compact rows"
        densityButton.toolTip = label
        densityButton.setAccessibilityLabel(label)
    }

    func controlTextDidChange(_ notification: Notification) {
        rebuildSnapshot(forceTableReload: false)
    }

    @discardableResult
    private func rebuildSnapshot(forceTableReload: Bool) -> Bool {
        let next = AppKitAgentsListSnapshot.make(
            subagents: bridge.subagents,
            workflowRuns: bridge.workflowRuns,
            search: searchField.stringValue,
            attentionExpanded: attentionExpanded,
            completedExpanded: completedExpanded,
            expandedWorkflowKeys: expandedWorkflowKeys,
            workflowAgentOrderings: workflowAgentOrderings,
            includeRoot: currentRootSnapshot(now: lastNow) != nil)
        let changed = forceTableReload || next != snapshot
        snapshot = next
        if changed {
            tableView.reloadData()
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<snapshot.items.count))
        } else {
            refreshVisibleRows()
        }
        updateEmptyView()
        needsLayout = true
        return changed
    }

    private func updateEmptyView() {
        let noRows = snapshot.items.isEmpty
        emptyView.isHidden = !noRows
        scrollView.isHidden = noRows
        guard noRows else { return }
        if snapshot.unfilteredCount == 0 {
            let copy = agentsEmptyStateCopy(
                for: bridge.currentModelAccess,
                ultraEnabled: bridge.ultracode)
            emptyView.configure(
                imageName: copy.systemImage,
                title: copy.title,
                detail: copy.detail)
        } else {
            emptyView.configure(
                imageName: "line.3.horizontal.decrease.circle",
                title: "No matches",
                detail: "No agents match this filter.")
        }
    }

    private func refreshVisibleRows() {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound else { return }
        let end = min(tableView.numberOfRows, range.location + range.length)
        guard range.location < end else { return }
        for row in range.location..<end {
            guard let view = tableView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false) as? AppKitAgentTableCellView else { continue }
            configure(view, item: snapshot.items[row])
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        snapshot.items.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rowHeightMeasurementCount &+= 1
        let width = max(1, scrollView.contentSize.width)
        switch snapshot.items[row] {
        case .root:
            guard !compactRows else { return 38 }
            guard let root = currentRootSnapshot(now: lastNow) else { return 48 }
            return AppKitAgentTableCellView.preferredHeight(
                for: appKitRootAgentCardPresentation(root),
                width: width,
                depth: 0)
        case .group:
            return 25
        case .subagent(let key, let depth):
            guard !compactRows else { return 33 }
            guard let subagent = bridge.subagents[key] else { return 48 }
            let activity = activityIndex.cardSnapshot(
                agentID: AgentActivityIdentity.subagent(key),
                now: lastNow)
            return AppKitAgentTableCellView.preferredHeight(
                for: appKitSubagentCardPresentation(
                    subagent,
                    ordinal: ordinals[key],
                    activity: activity,
                    now: lastNow),
                width: width,
                depth: depth)
        case .workflow(let key, let expanded):
            guard !compactRows else { return 38 }
            guard let workflow = bridge.workflowRuns[key] else { return 48 }
            return AppKitAgentTableCellView.preferredHeight(
                for: appKitWorkflowCardPresentation(
                    workflow,
                    expanded: expanded,
                    now: lastNow),
                width: width,
                depth: 0)
        case .workflowAgent(let runKey, let agentKey, let ordinal, let depth):
            guard !compactRows else { return 34 }
            guard let run = bridge.workflowRuns[runKey],
                  let agent = run.agents[agentKey] else { return 48 }
            let activity = activityIndex.cardSnapshot(
                agentID: AgentActivityIdentity.workflow(
                    runKey: runKey,
                    agentKey: agentKey),
                now: lastNow)
            return AppKitAgentTableCellView.preferredHeight(
                for: appKitWorkflowAgentCardPresentation(
                    agent,
                    in: run,
                    ordinal: ordinal,
                    activity: activity,
                    now: lastNow),
                width: width,
                depth: depth)
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("agent-native-rowview")
        let view = tableView.makeView(withIdentifier: identifier, owner: self)
            as? AppKitAgentsTableRowView
            ?? AppKitAgentsTableRowView()
        view.identifier = identifier
        let depth: Int
        switch snapshot.items[row] {
        case .subagent(_, let itemDepth), .workflowAgent(_, _, _, let itemDepth):
            depth = itemDepth
        case .root, .group, .workflow:
            depth = 0
        }
        view.configure(depth: depth)
        return view
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("agent-native-row")
        let view = tableView.makeView(withIdentifier: identifier, owner: self)
            as? AppKitAgentTableCellView
            ?? AppKitAgentTableCellView()
        view.identifier = identifier
        configure(view, item: snapshot.items[row])
        return view
    }

    private func configure(_ view: AppKitAgentTableCellView, item: AppKitAgentsListItem) {
        view.pressHandler = { [weak self] in self?.activate(item: item) }
        switch item {
        case .root:
            view.pressHandler = nil
            guard let root = currentRootSnapshot(now: lastNow) else { return }
            view.configure(
                root: root,
                compact: compactRows,
                onStop: { [weak bridge] in bridge?.stopRootWork() })
        case .group(let group, let count, let expanded):
            if group == .active { view.pressHandler = nil }
            view.configureGroup(group: group, count: count, expanded: expanded)
        case .subagent(let key, let depth):
            guard let subagent = bridge.subagents[key] else { return }
            view.configure(
                subagent: subagent,
                ordinal: ordinals[key],
                depth: depth,
                compact: compactRows,
                activityIndex: activityIndex,
                now: lastNow,
                onStop: { [weak bridge] taskID in bridge?.stopTask(taskID) })
        case .workflow(let key, let expanded):
            guard let run = bridge.workflowRuns[key] else { return }
            view.configure(
                workflow: run,
                expanded: expanded,
                compact: compactRows,
                now: lastNow,
                onStop: { [weak bridge] taskID in bridge?.stopTask(taskID) })
        case .workflowAgent(let runKey, let agentKey, let ordinal, let depth):
            guard let run = bridge.workflowRuns[runKey],
                  let agent = run.agents[agentKey] else { return }
            view.configure(
                workflowAgent: agent,
                run: run,
                ordinal: ordinal,
                depth: depth,
                compact: compactRows,
                activityIndex: activityIndex,
                now: lastNow)
        }
    }

    @objc private func tableClicked() {
        let row = tableView.clickedRow
        activate(row: row)
    }

    private func activate(row: Int) {
        guard row >= 0, row < snapshot.items.count else { return }
        activate(item: snapshot.items[row])
        tableView.deselectAll(nil)
    }

    private func activate(item: AppKitAgentsListItem) {
        switch item {
        case .root:
            break
        case .group(let group, _, _):
            switch group {
            case .active: break
            case .attention:
                attentionExpanded.toggle()
                rebuildSnapshot(forceTableReload: false)
            case .completed:
                completedExpanded.toggle()
                rebuildSnapshot(forceTableReload: false)
            }
        case .subagent(let key, _):
            if let subagent = bridge.subagents[key] { onOpenSubagent?(subagent) }
        case .workflow(let key, _):
            if expandedWorkflowKeys.contains(key) {
                expandedWorkflowKeys.remove(key)
            } else {
                expandedWorkflowKeys.insert(key)
            }
            rebuildSnapshot(forceTableReload: false)
        case .workflowAgent(let runKey, let agentKey, _, _):
            if let run = bridge.workflowRuns[runKey],
               let agent = run.agents[agentKey] {
                onOpenWorkflowAgent?(run, agent)
            }
        }
    }

    @objc private func tableDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < snapshot.items.count else { return }
        if case .workflow(let key, _) = snapshot.items[row],
           let run = bridge.workflowRuns[key] {
            onOpenWorkflow?(run)
        }
    }
}

/// The rows in this list are rounded cards, so the stock full-bleed rectangular highlight painted
/// a hard-edged box behind them. This draws the selection to the same radius and inset as the card
/// it sits under, and never emphasizes it into the saturated system blue.
private final class AppKitAgentsTableRowView: NSTableRowView {
    private var cardDepth = 0

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    func configure(depth: Int) {
        let nextDepth = max(0, depth)
        guard nextDepth != cardDepth else { return }
        cardDepth = nextDepth
        needsDisplay = true
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let path = NSBezierPath(
            roundedRect: appKitAgentCardRect(in: bounds, depth: cardDepth)
                .insetBy(dx: 0, dy: 1),
            xRadius: AgentCard.radius,
            yRadius: AgentCard.radius)
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        path.fill()
        path.lineWidth = 1
        NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
        path.stroke()
    }
}

struct AgentConversationSummaryPresentation: Equatable {
    var stateText: String
    /// Ordered from complete to most compact. Visual abbreviation never changes accessibility,
    /// which always receives the complete first value.
    var metricVariants: [String]
    var accessibilityText: String
}

func agentConversationSummaryPresentation(
    _ snapshot: AgentConversationActivitySnapshot
) -> AgentConversationSummaryPresentation {
    let rootStepText: String? = snapshot.currentRootStep.map { current in
        let label = current.phase == .tool
            ? traceToolDisplayName(toolName: current.label, target: current.target)
            : current.label
        let target = current.target.flatMap(activitySingleLine)
        return target.map { "\(label) · \($0)" } ?? label
    }

    let stateText: String
    if snapshot.activeAgentCount > 0 {
        stateText = "\(snapshot.activeAgentCount) "
            + (snapshot.activeAgentCount == 1 ? "agent active" : "agents active")
            + rootStepText.flatMap {
                agentConversationRootStepIsDistinctive($0) ? " · \($0)" : nil
            }.orEmpty
    } else if let rootStepText {
        stateText = rootStepText
    } else if let state = snapshot.overallState {
        stateText = activityPhaseLabel(state)
    } else {
        stateText = ""
    }

    let tokens = snapshot.tokenUsage
    var full: [String] = []
    var compact: [String] = []
    if !tokens.isEmpty {
        full.append("\(formatTokens(tokens.processed)) processed")
        compact.append("\(formatTokens(tokens.processed)) proc")
    }
    if tokens.generated > 0 {
        full.append("\(formatTokens(tokens.generated)) generated")
        compact.append("\(formatTokens(tokens.generated)) out")
    }
    if tokens.input > 0, tokens.cachedInput > 0 {
        let cached = min(tokens.input, tokens.cachedInput)
        let percent = Int((Double(cached) / Double(tokens.input) * 100).rounded())
        full.append("\(percent)% from cache")
        compact.append("\(percent)% cache")
    }
    if let context = snapshot.contextTokens {
        let value = snapshot.contextWindow.map {
            "\(formatTokens(context))/\(formatTokens($0))"
        } ?? formatTokens(context)
        full.append("\(value) context")
        compact.append("\(value) ctx")
    }
    if snapshot.turnID != nil || snapshot.isActive {
        let duration = agentStepDurationLabel(snapshot.duration)
        full.append(duration)
        compact.append(duration)
    }

    let essential = [
        tokens.isEmpty ? nil : formatTokens(tokens.processed),
        tokens.generated > 0 ? "\(formatTokens(tokens.generated)) out" : nil,
        (snapshot.turnID != nil || snapshot.isActive)
            ? agentStepDurationLabel(snapshot.duration) : nil,
    ].compactMap { $0 }.joined(separator: " · ")
    var metricVariants = [
        full.joined(separator: " · "),
        compact.joined(separator: " · "),
        essential,
        tokens.isEmpty ? "" : formatTokens(tokens.processed),
    ]
    metricVariants = metricVariants.filter { !$0.isEmpty }
    metricVariants = metricVariants.enumerated().filter { index, value in
        !metricVariants[..<index].contains(value)
    }.map(\.element)

    let accessibility = [
        "This conversation",
        stateText.isEmpty ? nil : stateText,
        full.isEmpty ? nil : full.joined(separator: " · "),
        snapshot.delegationSummary,
        snapshot.toolComposition.isEmpty ? nil : "Tool mix: " + snapshot.toolComposition
            .map { "\($0.name) \($0.count)" }
            .joined(separator: ", "),
    ].compactMap { $0 }.joined(separator: ", ")
    return AgentConversationSummaryPresentation(
        stateText: stateText,
        metricVariants: metricVariants,
        accessibilityText: accessibility)
}

private func agentConversationRootStepIsDistinctive(_ text: String) -> Bool {
    let leading = text
        .split(separator: "·", maxSplits: 1)
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard let leading else { return false }
    return ![
        "responding", "working", "model", "model call", "delegating",
        "completed", "failed", "stopped",
    ].contains(leading)
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

struct AgentConversationSummaryLayout: Equatable {
    var titleFrame: NSRect
    var stateFrame: NSRect
    var metricsFrame: NSRect
    var compositionFrame: NSRect
    var metricsVariantIndex: Int?
    var wrapsMetrics: Bool
    var height: CGFloat

    var visibleFrames: [NSRect] {
        [titleFrame, stateFrame, metricsFrame, compositionFrame].filter {
            !$0.isEmpty
        }
    }
}

/// Pure geometry for the root strip. Labels are either given their measured width or moved to a
/// separate row; no field is laid out on top of another and no metrics value receives a width cap.
func agentConversationSummaryLayout(
    width: CGFloat,
    titleWidth: CGFloat,
    stateIsEmpty: Bool,
    metricWidths: [CGFloat],
    hasComposition: Bool
) -> AgentConversationSummaryLayout {
    let inset: CGFloat = 10
    let contentX: CGFloat = 31
    let lineHeight: CGFloat = 16
    let gap: CGFloat = 8
    let contentRight = max(contentX, width - inset)
    let title = NSRect(
        x: contentX,
        y: 8,
        width: min(titleWidth, max(0, contentRight - contentX)),
        height: lineHeight)
    let stateX = min(contentRight, title.maxX + gap)
    let minimumStateWidth: CGFloat = stateIsEmpty ? 0 : 52

    if let fullWidth = metricWidths.first,
       fullWidth <= max(0, contentRight - contentX) {
        let metricsX = contentRight - fullWidth
        let stateRight = metricsX - gap
        if stateRight - stateX >= minimumStateWidth {
            let compositionY: CGFloat = 29
            return AgentConversationSummaryLayout(
                titleFrame: title,
                stateFrame: NSRect(
                    x: stateX,
                    y: 8,
                    width: max(0, stateRight - stateX),
                    height: lineHeight),
                metricsFrame: NSRect(
                    x: metricsX,
                    y: 8,
                    width: fullWidth,
                    height: lineHeight),
                compositionFrame: hasComposition
                    ? NSRect(
                        x: contentX,
                        y: compositionY,
                        width: max(0, contentRight - contentX),
                        height: 22)
                    : .zero,
                metricsVariantIndex: 0,
                wrapsMetrics: false,
                height: hasComposition ? 56 : 34)
        }
    } else if metricWidths.isEmpty {
        return AgentConversationSummaryLayout(
            titleFrame: title,
            stateFrame: NSRect(
                x: stateX,
                y: 8,
                width: max(0, contentRight - stateX),
                height: lineHeight),
            metricsFrame: .zero,
            compositionFrame: hasComposition
                ? NSRect(
                    x: contentX,
                    y: 29,
                    width: max(0, contentRight - contentX),
                    height: 22)
                : .zero,
            metricsVariantIndex: nil,
            wrapsMetrics: false,
            height: hasComposition ? 56 : 34)
    }

    let available = max(0, contentRight - contentX)
    let variant = metricWidths.firstIndex(where: { $0 <= available })
    guard let variant else {
        // Even the shortest truthful variant can exceed an ultra-narrow inspector. Keep it on its
        // own full-width row and render an explicit ellipsis with the complete value in the tooltip
        // and accessibility label. A zero frame silently erased the metric altogether.
        let fallbackVariant = metricWidths.indices.last
        let compositionY: CGFloat = 50
        return AgentConversationSummaryLayout(
            titleFrame: title,
            stateFrame: NSRect(
                x: stateX,
                y: 8,
                width: max(0, contentRight - stateX),
                height: lineHeight),
            metricsFrame: fallbackVariant == nil
                ? .zero
                : NSRect(
                    x: contentX,
                    y: 29,
                    width: available,
                    height: lineHeight),
            compositionFrame: hasComposition
                ? NSRect(
                    x: contentX,
                    y: compositionY,
                    width: available,
                    height: 22)
                : .zero,
            metricsVariantIndex: fallbackVariant,
            wrapsMetrics: fallbackVariant != nil,
            height: fallbackVariant == nil
                ? (hasComposition ? 56 : 34)
                : (hasComposition ? 77 : 55))
    }
    let metricsWidth = metricWidths[variant]
    let compositionY: CGFloat = 50
    return AgentConversationSummaryLayout(
        titleFrame: title,
        stateFrame: NSRect(
            x: stateX,
            y: 8,
            width: max(0, contentRight - stateX),
            height: lineHeight),
        metricsFrame: NSRect(
            x: contentRight - metricsWidth,
            y: 29,
            width: metricsWidth,
            height: lineHeight),
        compositionFrame: hasComposition
            ? NSRect(
                x: contentX,
                y: compositionY,
                width: available,
                height: 22)
            : .zero,
        metricsVariantIndex: variant,
        wrapsMetrics: true,
        height: hasComposition ? 77 : 55)
}

private final class AppKitRootAgentSummaryView: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "This conversation")
    private let step = NSTextField(labelWithString: "")
    private let metrics = NSTextField(labelWithString: "")
    /// The shipped panel puts the conversation's whole tool mix here, with its own key. It is the
    /// one place that answers "what has this conversation actually been doing" without expanding
    /// anything, and the port had it only on individual agent cards.
    private let composition = AppKitToolCompositionBar()
    private let delegation = NSTextField(labelWithString: "")
    private var hasContent = false
    private var hasCompositionRow = false
    private var presentation = AgentConversationSummaryPresentation(
        stateText: "",
        metricVariants: [],
        accessibilityText: "")

    func preferredHeight(for width: CGFloat) -> CGFloat {
        guard hasContent else { return 0 }
        return summaryLayout(width: width).height
    }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Matches the agent cards below it. Without the radius this row reads as a hard-edged
        // system box whose corners are clipped by the enclosing clip view.
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        icon.imageScaling = .scaleProportionallyDown
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        title.textColor = .labelColor
        step.font = .systemFont(ofSize: 10)
        step.textColor = .secondaryLabelColor
        step.lineBreakMode = .byTruncatingMiddle
        metrics.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        metrics.textColor = .tertiaryLabelColor
        metrics.alignment = .right
        metrics.lineBreakMode = .byTruncatingMiddle
        delegation.font = .systemFont(ofSize: 10, weight: .medium)
        delegation.textColor = .secondaryLabelColor
        delegation.lineBreakMode = .byTruncatingTail
        for view in [icon, title, step, metrics] { addSubview(view) }
        addSubview(composition)
        addSubview(delegation)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        let appearance = effectiveAppearance
        layer?.backgroundColor = NSColor.controlAccentColor
            .mechanicianCGColor(in: appearance, alpha: 0.055)
        layer?.borderColor = NSColor.separatorColor
            .mechanicianCGColor(in: appearance, alpha: 0.6)
        layer?.borderWidth = 0.5
    }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: 9, width: 14, height: 14)
        let geometry = summaryLayout(width: bounds.width)
        title.frame = geometry.titleFrame
        step.frame = geometry.stateFrame
        metrics.frame = geometry.metricsFrame
        if let variant = geometry.metricsVariantIndex {
            metrics.stringValue = presentation.metricVariants[variant]
            metrics.isHidden = false
        } else {
            metrics.stringValue = ""
            metrics.isHidden = true
        }
        composition.frame = geometry.compositionFrame
        delegation.frame = geometry.compositionFrame
    }

    func configure(_ activity: AgentConversationActivitySnapshot) {
        presentation = agentConversationSummaryPresentation(activity)
        hasContent = !activity.isEmpty
        hasCompositionRow = !activity.toolComposition.isEmpty
            || activity.delegationSummary != nil
        composition.configure(activity.toolComposition, trailing: "")
        composition.isHidden = activity.toolComposition.isEmpty
        delegation.stringValue = activity.delegationSummary ?? ""
        delegation.isHidden = activity.delegationSummary == nil
        isHidden = !hasContent
        guard hasContent else { return }

        icon.image = NSImage(
            systemSymbolName: activity.isActive
                ? "bubble.left.and.bubble.right.fill"
                : "bubble.left.and.bubble.right",
            accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor

        step.stringValue = presentation.stateText
        step.textColor = activity.isStalled ? .nWarningText : .secondaryLabelColor
        metrics.textColor = activity.isStalled ? .nWarningText : .tertiaryLabelColor
        metrics.toolTip = presentation.metricVariants.first
        setAccessibilityLabel(presentation.accessibilityText)
        needsLayout = true
    }

    private func summaryLayout(width: CGFloat) -> AgentConversationSummaryLayout {
        let titleWidth = ceil(title.fittingSize.width)
        let attributes: [NSAttributedString.Key: Any] = [.font: metrics.font as Any]
        let metricWidths = presentation.metricVariants.map {
            ceil(($0 as NSString).size(withAttributes: attributes).width)
        }
        return agentConversationSummaryLayout(
            width: width,
            titleWidth: titleWidth,
            stateIsEmpty: presentation.stateText.isEmpty,
            metricWidths: metricWidths,
            hasComposition: hasCompositionRow)
    }
}

private final class AppKitAgentsEmptyView: NSView {
    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(wrappingLabelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .tertiaryLabelColor
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.alignment = .center
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.alignment = .center
        detailField.maximumNumberOfLines = 5
        addSubview(imageView)
        addSubview(titleField)
        addSubview(detailField)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let width = min(360, max(120, bounds.width - 40))
        let x = (bounds.width - width) / 2
        let centerY = max(18, bounds.midY - 70)
        imageView.frame = NSRect(x: bounds.midX - 16, y: centerY, width: 32, height: 32)
        titleField.frame = NSRect(x: x, y: centerY + 42, width: width, height: 20)
        detailField.frame = NSRect(x: x, y: centerY + 67, width: width, height: 74)
    }

    func configure(imageName: String, title: String, detail: String) {
        imageView.image = NSImage(systemSymbolName: imageName, accessibilityDescription: nil)
        titleField.stringValue = title
        detailField.stringValue = detail
        setAccessibilityLabel("\(title). \(detail)")
    }
}

private final class AppKitClosureButton: NSButton {
    var handler: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(invoke)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler?()
    }
}

@MainActor
enum AppKitAgentStopStyle {
    static let imageSize: CGFloat = 17

    static func apply(to button: NSButton) {
        button.isBordered = false
        button.image = ComposerRoadSignImage.image(kind: .stop, size: imageSize)
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageOnly
        button.contentTintColor = nil
    }
}

/// One place that owns the agent card's gutter and corner, so the list, the selection highlight
/// and the root strip above the table cannot drift apart.
private enum AgentCard {
    static let inset: CGFloat = AgentCardMetrics.inset
    static let radius: CGFloat = AgentCardMetrics.radius
}

/// The card's gutter and corner, visible to tests so an alignment assertion cannot drift from the
/// value the layout actually uses.
enum AgentCardMetrics {
    static let inset: CGFloat = 8
    static let radius: CGFloat = 8
    static let hierarchyIndent: CGFloat = 18
}

/// The original SwiftUI tree indented each child card's complete surface. Keep the trailing edge
/// fixed so nesting remains obvious without making Stop, disclosure, or right-aligned metrics
/// wander between levels.
func appKitAgentCardRect(in bounds: NSRect, depth: Int) -> NSRect {
    let hierarchyInset = CGFloat(max(0, depth)) * AgentCardMetrics.hierarchyIndent
    return NSRect(
        x: bounds.minX + AgentCard.inset + hierarchyInset,
        y: bounds.minY,
        width: max(0, bounds.width - AgentCard.inset * 2 - hierarchyInset),
        height: bounds.height)
}

/// The stacked share of an agent's tool calls, restored from the SwiftUI card the native list
/// replaced. `AgentActivityLedgerIndex.toolComposition` never stopped computing this; the port
/// simply drew nothing with it, so every card lost its one at-a-glance picture of what the agent
/// actually spent its calls on.
private final class AppKitToolCompositionBar: NSView {
    private var shares: [AgentToolShare] = []

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// A tool's colour is derived from its name, not from its rank in this particular agent's list.
    /// Position-indexed colours meant `Bash` was teal on one card and pink on the next depending on
    /// how often each agent happened to call it — the colour carried no meaning across the panel.
    /// Hashing the name makes `Bash` the same colour everywhere, which is what makes a glance
    /// across several cards worth anything.
    fileprivate static let palette = MagicLaserSpectrum.meterColors

    private static func paletteIndex(forTool name: String) -> Int {
        var hash: UInt64 = 5381
        for byte in name.lowercased().utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return Int(hash % UInt64(palette.count))
    }

    static func color(forTool name: String) -> NSColor {
        palette[paletteIndex(forTool: name)]
    }

    /// Colours for one bar's segments.
    ///
    /// Hashing the name keeps a tool the same colour across cards, which is what makes a glance
    /// across several of them mean anything. But two names can hash to the same slot, and inside a
    /// single stacked bar that reads as one segment rather than two — `git` and `sed` came out the
    /// same green. Collisions are resolved by taking the next free slot, so neighbours always
    /// differ while a tool keeps its usual colour whenever it can.
    static func colors(forTools names: [String]) -> [NSColor] {
        var taken = Set<Int>()
        return names.map { name in
            // The common shape is five named leaders plus a residue. Making that sixth segment
            // grey discarded one ray from the Magic & Lasers mark and made the bar look like a
            // generic analytics widget. Give the residue the remaining brand ray: the label still
            // says exactly what it means, while a six-segment bar now carries the complete mark.
            if name == "other" {
                let index = palette.indices.first { !taken.contains($0) } ?? 0
                taken.insert(index)
                return palette[index]
            }
            var index = paletteIndex(forTool: name)
            var attempts = 0
            while taken.contains(index), attempts < palette.count {
                index = (index + 1) % palette.count
                attempts += 1
            }
            taken.insert(index)
            return palette[index]
        }
    }

    private var trailing = ""

    func configure(_ shares: [AgentToolShare], trailing: String) {
        guard shares != self.shares || trailing != self.trailing else { return }
        self.shares = shares
        self.trailing = trailing
        toolTip = shares
            .map { "\($0.name) \($0.count) (\(Int(($0.share * 100).rounded()))%)" }
            .joined(separator: " · ")
        setAccessibilityLabel("Tool mix: " + (toolTip ?? ""))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !shares.isEmpty else { return }
        let barHeight: CGFloat = 6
        let bar = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        let radius = barHeight / 2
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).addClip()

        let segmentColors = Self.colors(forTools: shares.map(\.name))
        var x: CGFloat = 0
        for (index, share) in shares.enumerated() {
            let width = index == shares.count - 1
                ? max(0, bar.maxX - x)
                : (bounds.width * CGFloat(share.share)).rounded()
            segmentColors[index].setFill()
            NSRect(x: x, y: 0, width: max(0, width - 1), height: barHeight).fill()
            x += width
        }
        NSGraphicsContext.current?.cgContext.resetClip()
        if !effectiveAppearance.mechanicianIsDark {
            NSColor.black.withAlphaComponent(0.20).setStroke()
            let outline = NSBezierPath(
                roundedRect: bar.insetBy(dx: 0.5, dy: 0.5),
                xRadius: radius - 0.5,
                yRadius: radius - 0.5)
            outline.lineWidth = 1
            outline.stroke()
        }

        // Name the leaders. A bare stacked bar with no key is decoration, not information.
        var labelX: CGFloat = 0
        var drawn = 0
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        // Reserve room for a "+N" so running out of width can be stated rather than hidden.
        let overflowFont = NSFont.systemFont(ofSize: 10, weight: .regular)
        let overflowReserve: CGFloat = shares.count > 1 ? 34 : 0
        for (index, share) in shares.enumerated() {
            let text = "\(share.name) \(share.count)" as NSString
            let width = ceil(text.size(withAttributes: [.font: font]).width)
            let isLast = index == shares.count - 1
            let reserve = isLast ? 8 : overflowReserve
            guard labelX + width + reserve <= bounds.width else { break }
            drawn += 1
            segmentColors[index].setFill()
            NSBezierPath(ovalIn: NSRect(x: labelX, y: barHeight + 5, width: 5, height: 5)).fill()
            text.draw(
                at: NSPoint(x: labelX + 9, y: barHeight + 3),
                withAttributes: [
                    .font: font,
                    .foregroundColor: NSColor.secondaryLabelColor
                ])
            labelX += width + 14
        }

        if drawn < shares.count {
            let hidden = shares.count - drawn
            ("+\(hidden)" as NSString).draw(
                at: NSPoint(x: labelX, y: barHeight + 3),
                withAttributes: [
                    .font: overflowFont,
                    .foregroundColor: NSColor.tertiaryLabelColor
                ])
        }

        // Token and tool totals ride the same row, right-aligned, so the card states them once
        // without the header having to truncate to fit them.
        guard !trailing.isEmpty else { return }
        let trailingWidth = ceil((trailing as NSString)
            .size(withAttributes: [.font: font]).width)
        guard labelX + trailingWidth + 12 <= bounds.width else { return }
        (trailing as NSString).draw(
            at: NSPoint(x: bounds.width - trailingWidth, y: barHeight + 3),
            withAttributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor
            ])
    }
}

/// Test seam for the exact colors a real stacked card receives. Palette-count tests alone missed
/// the grey-residue special case that prevented a common six-segment bar from ever showing the
/// complete brand spectrum.
func appKitToolCompositionColors(forTools names: [String]) -> [NSColor] {
    AppKitToolCompositionBar.colors(forTools: names)
}

/// One tool's colour, hashed from its name so it is the same wherever that tool appears.
///
/// The agent card's composition bar has always coloured tools this way. The trace drew every tool
/// span in one phase colour instead, which said "this is a tool" — something the row already says —
/// while discarding which tool. Sharing the mapping means `git` is the same ray in both places, and
/// a trace of mixed calls reads as mixed rather than as one long band.
func appKitToolColor(forTool name: String) -> NSColor {
    AppKitToolCompositionBar.color(forTool: name)
}

enum AppKitAgentBadgeTone: Equatable {
    case neutral
    case type
    case model
    case warning
}

struct AppKitAgentBadge: Equatable {
    var text: String
    var tone: AppKitAgentBadgeTone
    var accessibilityText: String
}

struct AppKitAgentProgress: Equatable {
    var completed: Int
    var total: Int

    var accessibilityText: String {
        "\(completed) of \(total) agents complete"
    }
}

/// Pure content projection for the native card. Keeping current work, metrics, and summary in
/// separate fields is intentional: the old card put all three into one label, so the moment an
/// agent started a tool call its token and tool totals disappeared.
struct AppKitAgentCardPresentation: Equatable {
    var status: WorkflowStatus
    var badges: [AppKitAgentBadge]
    var title: String
    var task: String
    var stateBand: String?
    var metrics: String?
    var summary: String?
    var error: String?
    var meta: String
    var toolComposition: [AgentToolShare]
    var disclosureLabel: String
    var accessibilityText: String
    var progress: AppKitAgentProgress? = nil
    var outputFile: String? = nil
    var isExpandable = true

    var modelBadge: String? {
        badges.first(where: { $0.tone == .model })?.text
    }
}

/// A child model is displayable only when the provider actually supplied one. In particular this
/// helper has no parent-model argument: it is impossible for the row to silently manufacture a
/// child model from the selected conversation route.
func appKitReportedChildModel(_ rawValue: String?) -> String? {
    guard let rawValue else { return nil }
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Composition fallback for providers that expose child tool events but do not emit the activity
/// ledger records used by the richer cards. Shell calls use the same target-aware names as trace.
func appKitObservedToolComposition(
    _ events: [SubagentToolEvent],
    limit: Int = 5,
    minimumShare: Double = 0.04
) -> [AgentToolShare] {
    var counts: [String: Int] = [:]
    for event in events {
        let rawName = event.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawName.isEmpty else { continue }
        counts[traceToolDisplayName(toolName: rawName, target: event.target), default: 0] += 1
    }
    let total = counts.values.reduce(0, +)
    guard total > 0 else { return [] }
    let ranked = counts.map {
        AgentToolShare(
            name: $0.key,
            count: $0.value,
            share: Double($0.value) / Double(total))
    }
    .sorted {
        if $0.count != $1.count { return $0.count > $1.count }
        return $0.name < $1.name
    }

    var head: [AgentToolShare] = []
    for share in ranked {
        guard head.count < limit else { break }
        if share.share < minimumShare, !head.isEmpty { break }
        head.append(share)
    }
    let tail = ranked.dropFirst(head.count)
    guard !tail.isEmpty else { return head }
    let tailCount = tail.reduce(0) { $0 + $1.count }
    return head + [AgentToolShare(
        name: "other",
        count: tailCount,
        share: Double(tailCount) / Double(total))]
}

private func appKitCardNonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func appKitCardStepText(_ step: AgentStepSnapshot) -> String {
    let label = step.phase == .tool
        ? traceToolDisplayName(toolName: step.label, target: step.target)
        : step.label
    return [
        label,
        step.target.flatMap(activitySingleLine),
        agentStepDurationLabel(step.duration),
    ].compactMap { $0 }.joined(separator: " · ")
}

private func appKitCardMetrics(
    tokens: Int?,
    tokenLabel: String,
    tools: Int?,
    toolLabel: String
) -> String? {
    let value = [
        tokens.map { "\(formatTokens($0)) \(tokenLabel)" },
        tools.map { "\($0) \(toolLabel)" },
    ].compactMap { $0 }.joined(separator: " · ")
    return value.isEmpty ? nil : value
}

private func appKitCardToolMixAccessibility(_ shares: [AgentToolShare]) -> String? {
    guard !shares.isEmpty else { return nil }
    return "Tool mix " + shares.map { "\($0.name) \($0.count)" }.joined(separator: ", ")
}

private func appKitRootCardStatus(_ snapshot: AgentRootActivitySnapshot) -> WorkflowStatus {
    if snapshot.isActive { return .running }
    switch snapshot.phase {
    case .completed: return .completed
    case .failed: return .failed
    case .stopped: return .stopped
    case .waiting: return .paused
    case .model, .tool, .compacting, nil: return .pending
    }
}

/// Root-card content is projected only from the selected turn's root lane. In particular, token and
/// tool totals never consult a workflow or child card. Requested model attribution stays visually
/// provisional until an explicit provider identity record replaces it.
func appKitRootAgentCardPresentation(
    _ snapshot: AgentRootActivitySnapshot
) -> AppKitAgentCardPresentation {
    let status = appKitRootCardStatus(snapshot)
    let elapsed = agentStepDurationLabel(snapshot.duration)
    let provider = snapshot.providerAccess?.displayName
    let requestedModel = appKitCardNonempty(snapshot.requestedModelID)
    let reportedModel = appKitCardNonempty(snapshot.providerReportedModelID)
    var badges: [AppKitAgentBadge] = []
    if let provider {
        badges.append(AppKitAgentBadge(
            text: provider,
            tone: .type,
            accessibilityText: "Provider \(provider)"))
    }
    if let reportedModel {
        badges.append(AppKitAgentBadge(
            text: "Reported · \(reportedModel)",
            tone: .model,
            accessibilityText: "Provider-reported model \(reportedModel)"))
    } else if let requestedModel {
        badges.append(AppKitAgentBadge(
            text: "Requested · \(requestedModel)",
            tone: .neutral,
            accessibilityText:
                "Requested model \(requestedModel), awaiting provider confirmation"))
    }

    let metrics = [
        snapshot.tokenUsage.isEmpty
            ? nil
            : "\(formatTokens(snapshot.tokenUsage.processed)) processed",
        snapshot.observedToolCount > 0
            ? "\(snapshot.observedToolCount) "
                + (snapshot.observedToolCount == 1 ? "tool call" : "tool calls")
            : nil,
    ].compactMap { $0 }.joined(separator: " · ")
    let stateBand: String?
    if let step = snapshot.currentStep {
        stateBand = (snapshot.isStalled ? "Possibly stalled · " : "")
            + appKitCardStepText(step)
    } else if snapshot.isActive {
        let label: String
        if snapshot.turnID == nil {
            label = "Starting"
        } else {
            switch snapshot.phase {
            case .waiting: label = "Waiting"
            case .compacting: label = "Compacting"
            case .tool: label = "Using tools"
            case .model, .completed, .failed, .stopped, nil: label = "Working"
            }
        }
        stateBand = "\(label) · \(elapsed)"
    } else if let phase = snapshot.phase, !phase.isTerminal {
        stateBand = "\(activityPhaseLabel(phase)) · \(elapsed)"
    } else {
        stateBand = nil
    }
    let accessibility = [
        "Root agent",
        provider.map { "Provider \($0)" },
        reportedModel.map { "Provider-reported model \($0)" }
            ?? requestedModel.map {
                "Requested model \($0), awaiting provider confirmation"
            },
        "Status \(status.label)",
        "Started \(agentRowStamp(snapshot.startedAt))",
        "Duration \(elapsed)",
        stateBand.map { "Current work \($0)" },
        metrics.isEmpty ? nil : metrics,
        appKitCardToolMixAccessibility(snapshot.toolComposition),
    ].compactMap { $0 }.joined(separator: ", ")
    return AppKitAgentCardPresentation(
        status: status,
        badges: badges,
        title: "Root agent",
        task: "",
        stateBand: stateBand,
        metrics: metrics.isEmpty ? nil : metrics,
        summary: nil,
        error: nil,
        meta: "\(agentRowStamp(snapshot.startedAt)) · \(elapsed)",
        toolComposition: snapshot.toolComposition,
        disclosureLabel: "",
        accessibilityText: accessibility,
        isExpandable: false)
}

/// An aggregate can arrive terminal before its last buffered child update. The native Agents UI
/// treats that child as live everywhere it matters (grouping, ticking, and Stop) until the child
/// itself terminalizes.
func appKitWorkflowHasLiveWork(_ workflow: WorkflowRun) -> Bool {
    !effectiveRunStatus(workflow).isTerminal
        || workflow.agents.values.contains { !$0.state.isTerminal }
}

func appKitSubagentCardPresentation(
    _ subagent: SubagentRun,
    ordinal: Int?,
    activity: AgentActivityCardSnapshot,
    now: Date
) -> AppKitAgentCardPresentation {
    let candidate = subagent.status == .running ? activity.currentStep : nil
    let step = candidate?.isTerminal == true ? nil : candidate
    let elapsed = agentElapsed(
        durationMs: subagent.durationMs,
        startedAt: subagent.startedAt,
        endedAt: subagent.endedAt,
        now: now)
    let type = appKitCardNonempty(subagent.subagentType) ?? "Agent"
    let model = appKitReportedChildModel(subagent.model)
    var badges = [
        ordinal.map {
            AppKitAgentBadge(
                text: "A\($0)",
                tone: .neutral,
                accessibilityText: "Agent \($0)")
        },
        AppKitAgentBadge(text: type, tone: .type, accessibilityText: "Type \(type)"),
        model.map {
            AppKitAgentBadge(
                text: $0,
                tone: .model,
                accessibilityText: "Model \(subagent.model ?? $0)")
        },
    ].compactMap { $0 }

    // A type named exactly like the ordinal is provider data but visually redundant.
    if badges.count > 1, badges[0].text == badges[1].text {
        badges.remove(at: 1)
    }
    let composition = activity.toolComposition.isEmpty
        ? appKitObservedToolComposition(subagent.toolEvents)
        : activity.toolComposition
    let observedTools = composition.reduce(0) { $0 + $1.count }
    let providerTokens = subagent.reportedTokens
    let activityTokens = activity.tokenUsage.isEmpty ? nil : activity.tokenUsage.processed
    let metrics = appKitCardMetrics(
        tokens: providerTokens ?? activityTokens,
        tokenLabel: providerTokens == nil ? "processed" : "tokens",
        tools: subagent.reportedToolUses ?? (observedTools > 0 ? observedTools : nil),
        toolLabel: subagent.reportedToolUses == nil
            ? "observed tools"
            : subagent.toolMetricLabel)
    let stateBand: String?
    if let step {
        stateBand = (activity.isStalled ? "Possibly stalled · " : "") + appKitCardStepText(step)
    } else if subagent.status == .running, let tool = appKitCardNonempty(subagent.lastToolName) {
        stateBand = traceToolDisplayName(toolName: tool, target: nil) + " · " + elapsed
    } else if subagent.status == .running {
        stateBand = "Working · \(elapsed)"
    } else {
        stateBand = nil
    }
    let summary = appKitCardNonempty(subagent.summary)
    let error = appKitCardNonempty(subagent.error).flatMap { $0 == summary ? nil : $0 }
    let meta = "\(agentRowStamp(subagent.startedAt)) · \(elapsed)"
    let accessibility = [
        badges.map(\.accessibilityText).joined(separator: ", "),
        "Status \(subagent.status.label)",
        "Started \(agentRowStamp(subagent.startedAt))",
        "Duration \(elapsed)",
        appKitCardNonempty(subagent.task).map { "Task \($0)" },
        stateBand.map { "Current work \($0)" },
        metrics,
        summary.map { "Summary \($0)" },
        error.map { "Error \($0)" },
        appKitCardToolMixAccessibility(composition),
        "Opens agent details",
    ].compactMap { $0 }.joined(separator: ", ")
    return AppKitAgentCardPresentation(
        status: subagent.status,
        badges: badges,
        title: "",
        task: subagent.task,
        stateBand: stateBand,
        metrics: metrics,
        summary: summary,
        error: error,
        meta: meta,
        toolComposition: composition,
        disclosureLabel: "Open agent details",
        accessibilityText: accessibility)
}

func appKitWorkflowCardPresentation(
    _ workflow: WorkflowRun,
    expanded: Bool,
    now: Date
) -> AppKitAgentCardPresentation {
    let aggregateStatus = effectiveRunStatus(workflow)
    let liveChildren = workflow.agents.values.filter { !$0.state.isTerminal }.count
    let hasLiveWork = appKitWorkflowHasLiveWork(workflow)
    let parentEndedBeforeChildren = aggregateStatus.isTerminal && liveChildren > 0
    let status: WorkflowStatus = parentEndedBeforeChildren
        ? .running
        : aggregateStatus
    let stats = runStats(workflow)
    let elapsed = agentElapsed(
        durationMs: parentEndedBeforeChildren ? 0 : (workflow.usage?.durationMs ?? 0),
        startedAt: workflow.startedAt,
        endedAt: hasLiveWork ? nil : workflow.endedAt,
        now: now)
    let events = workflow.agents.values.flatMap(\.toolEvents)
    let composition = appKitObservedToolComposition(events)
    let task = appKitCardNonempty(workflow.description) ?? ""
    let summary = appKitCardNonempty(workflow.summary)
    let error = appKitCardNonempty(workflow.error)
    let metrics = [
        "\(stats.done)/\(stats.agents) agents",
        stats.tokens > 0 ? "\(formatTokens(stats.tokens)) tokens" : nil,
        stats.toolUses > 0 ? "\(stats.toolUses) tools" : nil,
    ].compactMap { $0 }.joined(separator: " · ")
    let stateBand: String?
    if liveChildren > 0 {
        stateBand = "\(liveChildren) "
            + (liveChildren == 1 ? "agent active" : "agents active")
            + " · \(stats.done)/\(stats.agents) complete · \(elapsed)"
    } else if status.isTerminal {
        stateBand = nil
    } else {
        stateBand = "\(status.label) · \(stats.done)/\(stats.agents) complete · \(elapsed)"
    }
    let title = appKitCardNonempty(workflow.workflowName) ?? "Workflow"
    let disclosure = expanded ? "Collapse workflow agents" : "Expand workflow agents"
    let outputFile = expanded ? appKitCardNonempty(workflow.outputFile) : nil
    let accessibility = [
        "Workflow \(title)",
        "Status \(status.label)",
        parentEndedBeforeChildren ? "Parent \(aggregateStatus.label), delegated work remains active" : nil,
        "Started \(agentRowStamp(workflow.startedAt))",
        "Duration \(elapsed)",
        task.isEmpty ? nil : "Task \(task)",
        stateBand.map { "Progress \($0)" },
        metrics,
        summary.map { "Summary \($0)" },
        outputFile.map { "Output \($0)" },
        error.map { "Error \($0)" },
        appKitCardToolMixAccessibility(composition),
        expanded ? "Expanded" : "Collapsed",
    ].compactMap { $0 }.joined(separator: ", ")
    return AppKitAgentCardPresentation(
        status: status,
        badges: [
            AppKitAgentBadge(
                text: "Workflow",
                tone: .type,
                accessibilityText: "Workflow"),
        ],
        title: title,
        task: task,
        stateBand: stateBand,
        metrics: metrics,
        summary: summary,
        error: error,
        meta: "\(agentRowStamp(workflow.startedAt)) · \(elapsed)",
        toolComposition: composition,
        disclosureLabel: disclosure,
        accessibilityText: accessibility,
        progress: stats.agents > 0
            ? AppKitAgentProgress(completed: stats.done, total: stats.agents)
            : nil,
        outputFile: outputFile)
}

func appKitWorkflowAgentCardPresentation(
    _ agent: WorkflowAgent,
    in workflow: WorkflowRun,
    ordinal: Int,
    activity: AgentActivityCardSnapshot,
    now: Date
) -> AppKitAgentCardPresentation {
    let status: WorkflowStatus
    switch agent.state {
    case .queued: status = .pending
    case .start, .progress: status = .running
    case .done: status = .completed
    case .failed: status = .failed
    case .stopped: status = .stopped
    }
    let started = agent.startedAt ?? workflow.startedAt
    let elapsed = agentElapsed(
        durationMs: agent.durationMs ?? 0,
        startedAt: started,
        endedAt: agent.endedAt,
        now: now)
    let model = appKitReportedChildModel(agent.model)
    let name = appKitCardNonempty(agent.label) ?? "Workflow agent"
    var badges = [
        AppKitAgentBadge(
            text: "A\(ordinal)",
            tone: .neutral,
            accessibilityText: "Agent \(ordinal)"),
        AppKitAgentBadge(text: name, tone: .type, accessibilityText: "Type \(name)"),
        model.map {
            AppKitAgentBadge(
                text: $0,
                tone: .model,
                accessibilityText: "Model \(agent.model ?? $0)")
        },
    ].compactMap { $0 }
    if let attempt = agent.attempt, attempt > 1 {
        badges.append(AppKitAgentBadge(
            text: "↻\(attempt)",
            tone: .warning,
            accessibilityText: "Attempt \(attempt)"))
    }

    let composition = activity.toolComposition.isEmpty
        ? appKitObservedToolComposition(agent.toolEvents)
        : activity.toolComposition
    let observedTools = composition.reduce(0) { $0 + $1.count }
    let providerTokens = agent.reportedTokens
    let activityTokens = activity.tokenUsage.isEmpty ? nil : activity.tokenUsage.processed
    let metrics = appKitCardMetrics(
        tokens: providerTokens ?? activityTokens,
        tokenLabel: providerTokens == nil ? "processed" : "tokens",
        tools: agent.reportedToolCalls ?? (observedTools > 0 ? observedTools : nil),
        toolLabel: agent.reportedToolCalls == nil ? "observed tools" : "tool calls")
    let candidate = agent.state.isRunning ? activity.currentStep : nil
    let step = candidate?.isTerminal == true ? nil : candidate
    let stateBand: String?
    if let step {
        stateBand = (activity.isStalled ? "Possibly stalled · " : "") + appKitCardStepText(step)
    } else if agent.state.isRunning, let tool = appKitCardNonempty(agent.lastToolName) {
        stateBand = [
            traceToolDisplayName(toolName: tool, target: nil),
            appKitCardNonempty(agent.lastToolSummary),
            elapsed,
        ].compactMap { $0 }.joined(separator: " · ")
    } else if agent.state.isRunning {
        stateBand = "\(agent.phaseTitle.isEmpty ? agent.state.label : agent.phaseTitle) · \(elapsed)"
    } else {
        stateBand = nil
    }
    let task = appKitCardNonempty(agent.promptPreview) ?? ""
    let summary = appKitCardNonempty(agent.resultPreview)
    let error = appKitCardNonempty(agent.error)
    let phase = agent.phaseTitle.isEmpty ? "\(agent.phaseIndex + 1)" : agent.phaseTitle
    let accessibility = [
        badges.map(\.accessibilityText).joined(separator: ", "),
        "Workflow \(workflow.workflowName ?? "Workflow")",
        "Phase \(phase)",
        "Status \(agent.state.label)",
        "Started \(agentRowStamp(started))",
        "Duration \(elapsed)",
        task.isEmpty ? nil : "Task \(task)",
        stateBand.map { "Current work \($0)" },
        metrics,
        summary.map { "Summary \($0)" },
        error.map { "Error \($0)" },
        appKitCardToolMixAccessibility(composition),
        "Opens agent details",
    ].compactMap { $0 }.joined(separator: ", ")
    return AppKitAgentCardPresentation(
        status: status,
        badges: badges,
        title: "",
        task: task,
        stateBand: stateBand,
        metrics: metrics,
        summary: summary,
        error: error,
        meta: "\(agentRowStamp(started)) · \(elapsed)",
        toolComposition: composition,
        disclosureLabel: "Open workflow agent details",
        accessibilityText: accessibility)
}

private func appKitStatusColor(_ status: WorkflowStatus) -> NSColor {
    switch status {
    case .running: return .controlAccentColor
    case .completed: return .systemGreen
    case .failed, .killed: return .systemRed
    case .paused, .stopped: return .systemOrange
    case .pending: return .secondaryLabelColor
    }
}

/// Text uses the contrast-safe semantic palette. `appKitStatusColor` remains the brighter system
/// color for filled dots, bands, bars, and status symbols.
private func appKitStatusTextColor(_ status: WorkflowStatus) -> NSColor {
    switch status {
    case .running: return .nInfoText
    case .completed: return .nSuccessText
    case .failed, .killed: return .nErrorText
    case .paused, .stopped: return .nWarningText
    case .pending: return .secondaryLabelColor
    }
}

/// Which badge gives up width first. Proportional shrinking took the most from the *widest* badge,
/// which is the model — so `Reported · gpt-5.6-sol` lost exactly the version that makes it worth
/// showing. The route and the agent type still read when compressed; a truncated model identifier
/// does not, so it yields last.
private func appKitAgentBadgeShrinkRank(_ tone: AppKitAgentBadgeTone) -> Int {
    switch tone {
    case .type: return 0
    case .neutral: return 1
    case .warning: return 2
    case .model: return 3
    }
}

/// Distribute `available` points across badges, taking width from the least important first.
/// Extracted from the strip's `draw` so the policy can be asserted directly.
func appKitAgentBadgeWidths(
    ideals: [CGFloat],
    tones: [AppKitAgentBadgeTone],
    available: CGFloat
) -> [CGFloat] {
    guard !ideals.isEmpty, ideals.count == tones.count else { return ideals }
    var widths = ideals
    var deficit = ideals.reduce(0, +) - available
    guard deficit > 0 else { return widths }

    let floorWidth: CGFloat = min(24, max(0, available) / CGFloat(ideals.count))
    for rank in 0...3 {
        guard deficit > 0 else { break }
        let group = ideals.indices.filter { appKitAgentBadgeShrinkRank(tones[$0]) == rank }
        let slack = group.reduce(CGFloat.zero) { $0 + max(0, widths[$1] - floorWidth) }
        guard slack > 0 else { continue }
        let taken = min(deficit, slack)
        for index in group {
            widths[index] -= taken * max(0, widths[index] - floorWidth) / slack
        }
        deficit -= taken
    }
    // Narrower than every badge's floor: nothing is protectable, so share what is left.
    if deficit > 0 {
        let total = widths.reduce(0, +)
        if total > 0 { widths = widths.map { $0 * max(0, available) / total } }
    }
    return widths
}

private final class AppKitAgentBadgeStrip: NSView {
    private var badges: [AppKitAgentBadge] = []

    override var isFlipped: Bool { true }

    var desiredWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let text = badges.reduce(CGFloat.zero) {
            $0 + ceil(($1.text as NSString).size(withAttributes: [.font: font]).width) + 13
        }
        return text + CGFloat(max(0, badges.count - 1)) * 4
    }

    var minimumWidth: CGFloat {
        CGFloat(badges.count) * 24 + CGFloat(max(0, badges.count - 1)) * 4
    }

    func configure(_ badges: [AppKitAgentBadge]) {
        self.badges = badges
        isHidden = badges.isEmpty
        toolTip = badges.map(\.accessibilityText).joined(separator: " · ")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(toolTip ?? "")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !badges.isEmpty, bounds.width > 0 else { return }
        let gap: CGFloat = 4
        let font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let ideals = badges.map {
            ceil(($0.text as NSString).size(withAttributes: [.font: font]).width) + 13
        }
        let widths = appKitAgentBadgeWidths(
            ideals: ideals,
            tones: badges.map(\.tone),
            available: max(0, bounds.width - gap * CGFloat(max(0, badges.count - 1))))

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var x: CGFloat = 0
        for (index, badge) in badges.enumerated() {
            let width = max(0, min(widths[index], bounds.width - x))
            guard width > 1 else { break }
            let rect = NSRect(x: x, y: 1, width: width, height: max(0, bounds.height - 2))
            let fillColor: NSColor
            let textColor: NSColor
            switch badge.tone {
            case .neutral:
                fillColor = .secondaryLabelColor
                textColor = .secondaryLabelColor
            case .type:
                fillColor = .labelColor
                textColor = .labelColor
            case .model:
                fillColor = .controlAccentColor
                textColor = .nInfoText
            case .warning:
                fillColor = .systemOrange
                textColor = .nWarningText
            }
            fillColor.withAlphaComponent(badge.tone == .model ? 0.20 : 0.12).setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: rect.height / 2,
                yRadius: rect.height / 2).fill()
            // Ellipsize rather than clip. A hard clip cut mid-glyph and gave no sign anything was
            // missing, so `Claude subscrip` read as the whole value.
            (badge.text as NSString).draw(
                in: NSRect(
                    x: rect.minX + 6,
                    y: rect.minY + 3,
                    width: max(0, rect.width - 11),
                    height: 12),
                withAttributes: [
                    .font: font,
                    .foregroundColor: textColor,
                    .paragraphStyle: paragraph,
                ])
            x = rect.maxX + gap
        }
    }
}

private final class AppKitAgentStateBand: NSView {
    private var text = ""
    private var markColor = NSColor.controlAccentColor
    private var textColor = NSColor.nInfoText
    private var stalled = false

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func configure(_ text: String?, status: WorkflowStatus, stalled: Bool) {
        self.text = text ?? ""
        markColor = stalled ? .systemOrange : appKitStatusColor(status)
        textColor = stalled ? .nWarningText : appKitStatusTextColor(status)
        self.stalled = stalled
        isHidden = self.text.isEmpty
        toolTip = self.text
        setAccessibilityElement(!self.text.isEmpty)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(self.text)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        markColor.withAlphaComponent(0.11).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        markColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 7, y: 8, width: 5, height: 5)).fill()
        let prefix = stalled ? "⚠︎ " : ""
        ((prefix + text) as NSString).draw(
            in: NSRect(x: 17, y: 4, width: max(0, bounds.width - 23), height: 15),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: textColor,
            ])
    }
}

private final class AppKitAgentProgressBar: NSView {
    private(set) var progress: AppKitAgentProgress?
    private var status: WorkflowStatus = .pending

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func configure(_ progress: AppKitAgentProgress?, status: WorkflowStatus) {
        self.progress = progress
        self.status = status
        isHidden = progress == nil
        setAccessibilityElement(progress != nil)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Workflow progress")
        setAccessibilityValue(progress?.accessibilityText ?? "")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let progress, progress.total > 0, bounds.width > 0, bounds.height > 0 else { return }
        let radius = bounds.height / 2
        NSColor.tertiaryLabelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let fraction = min(1, max(0, Double(progress.completed) / Double(progress.total)))
        guard fraction > 0 else { return }
        let color: NSColor
        switch status {
        case .failed, .killed: color = .systemRed
        case .paused, .stopped: color = .systemOrange
        default: color = .systemGreen
        }
        color.setFill()
        let fill = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: max(bounds.height, bounds.width * fraction),
            height: bounds.height)
            .intersection(bounds)
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}

/// Internal so the render harness can exercise the workflow row paths. The card refactor — the
/// clip-view-derived `cardRect`, the disclosure chevron, the inboard stop button, the height that
/// varies with content — was only ever driven by subagent rows in the running app.
final class AppKitAgentTableCellView: NSTableCellView {
    private enum Content {
        case none
        case root(AgentRootActivitySnapshot)
        case subagent(SubagentRun, Int?, AgentActivityLedgerIndex)
        case workflow(WorkflowRun, Bool)
        case workflowAgent(WorkflowAgent, WorkflowRun, Int, AgentActivityLedgerIndex)
    }

    private let statusIcon = NSImageView()
    private let statusSpinner = OrbitingDotsLayerView()
    private let badgeStrip = AppKitAgentBadgeStrip()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let stateBand = AppKitAgentStateBand()
    private let metricsField = NSTextField(labelWithString: "")
    private let progressBar = AppKitAgentProgressBar()
    private let summaryField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let metaField = NSTextField(labelWithString: "")
    private let outputIcon = NSImageView()
    private let outputField = NSTextField(labelWithString: "")
    private let openOutputButton = AppKitClosureButton()
    private let errorGlyph = NSImageView()
    private let errorField = NSTextField(labelWithString: "")
    private let compositionBar = AppKitToolCompositionBar()
    private let disclosure = NSImageView()
    private let stopButton = AppKitClosureButton()
    private var content: Content = .none
    private var compact = false
    private var depth = 0
    private var group: AppKitAgentsGroup?
    private(set) var presentationForTesting: AppKitAgentCardPresentation?
    var pressHandler: (() -> Void)?
    var outputOpener: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        compositionBar.needsDisplay = true
        stateBand.needsDisplay = true
        progressBar.needsDisplay = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        statusIcon.imageScaling = .scaleProportionallyDown
        statusSpinner.configure(
            color: nil,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        statusSpinner.isHidden = true
        titleField.lineBreakMode = .byTruncatingTail
        subtitleField.lineBreakMode = .byTruncatingTail
        metricsField.lineBreakMode = .byTruncatingTail
        summaryField.lineBreakMode = .byTruncatingTail
        detailField.lineBreakMode = .byTruncatingTail
        // Head truncation destroyed the hour — "…:21 AM" cannot be read as a time at all, while a
        // clipped tail still leaves "11:21 AM · 5…". The stamp leads, so truncate from the end.
        metaField.lineBreakMode = .byTruncatingTail
        metaField.alignment = .right

        metricsField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        metricsField.textColor = .secondaryLabelColor
        metricsField.isHidden = true
        summaryField.font = .systemFont(ofSize: 10)
        summaryField.textColor = .secondaryLabelColor
        summaryField.maximumNumberOfLines = 2
        summaryField.isHidden = true

        outputIcon.image = NSImage(
            systemSymbolName: "doc.text",
            accessibilityDescription: nil)
        outputIcon.contentTintColor = .secondaryLabelColor
        outputIcon.imageScaling = .scaleProportionallyDown
        outputIcon.isHidden = true
        outputIcon.setAccessibilityElement(false)
        outputField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        outputField.textColor = .secondaryLabelColor
        outputField.lineBreakMode = .byTruncatingMiddle
        outputField.isHidden = true
        openOutputButton.title = "Open"
        openOutputButton.isBordered = false
        openOutputButton.bezelStyle = .inline
        openOutputButton.font = .systemFont(ofSize: 10, weight: .medium)
        openOutputButton.contentTintColor = .controlAccentColor
        openOutputButton.isHidden = true

        errorGlyph.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: nil)
        errorGlyph.contentTintColor = .systemRed
        errorGlyph.imageScaling = .scaleProportionallyDown
        errorGlyph.isHidden = true
        errorGlyph.setAccessibilityElement(false)
        errorField.lineBreakMode = .byTruncatingTail
        errorField.maximumNumberOfLines = 2
        errorField.font = .systemFont(ofSize: 10, weight: .medium)
        errorField.textColor = .nErrorText
        errorField.isHidden = true

        // The row opens a detail pane; without this the whole card looked inert.
        disclosure.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        disclosure.contentTintColor = .tertiaryLabelColor
        disclosure.isHidden = true

        AppKitAgentStopStyle.apply(to: stopButton)
        stopButton.toolTip = "Stop this agent"
        stopButton.setAccessibilityLabel("Stop this agent")

        for view in [
            statusIcon, statusSpinner, badgeStrip, titleField, subtitleField, stateBand,
            metricsField, progressBar, summaryField, detailField, metaField,
            outputIcon, outputField, openOutputButton, errorGlyph, errorField,
            compositionBar, disclosure, stopButton
        ] {
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func accessibilityPerformPress() -> Bool {
        guard let pressHandler else { return false }
        pressHandler()
        return true
    }

    /// The Stop button's visibility and the id it sends are both decided in `configure`, and both
    /// have shipped wrong; the tests assert on them directly.
    var stopButtonForTesting: NSButton? { stopButton }
    var disclosureForTesting: NSImageView { disclosure }
    var statusTooltipForTesting: String? {
        statusSpinner.isHidden ? statusIcon.toolTip : statusSpinner.toolTip
    }
    var workflowProgressForTesting: AppKitAgentProgress? { progressBar.progress }
    var openOutputButtonForTesting: NSButton { openOutputButton }
    var errorGlyphForTesting: NSImageView { errorGlyph }
    func pressStopForTesting() { stopButton.performClick(nil) }
    func pressOpenOutputForTesting() { openOutputButton.performClick(nil) }

    /// How many lines the task text needs. The card reserved two unconditionally, which left a
    /// visible band of dead space under every one-line task.
    static func taskLineCount(_ task: String, width: CGFloat) -> Int {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, width > 0 else { return 0 }
        let measured = ceil((text as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width)
        return measured <= width ? 1 : 2
    }

    static func preferredHeight(
        for presentation: AppKitAgentCardPresentation,
        width: CGFloat,
        depth: Int
    ) -> CGFloat {
        let contentWidth = max(
            1,
            width - AgentCard.inset * 2 - CGFloat(22 + depth * 18))
        var height: CGFloat = 34
        if !presentation.task.isEmpty {
            height += CGFloat(taskLineCount(presentation.task, width: contentWidth)) * 15 + 5
        }
        if presentation.stateBand != nil { height += 27 }
        if presentation.metrics != nil { height += 19 }
        if presentation.progress != nil { height += 13 }
        if let summary = presentation.summary {
            height += CGFloat(taskLineCount(summary, width: contentWidth)) * 14 + 4
        }
        if presentation.outputFile != nil { height += 25 }
        if presentation.error != nil { height += 30 }
        if !presentation.toolComposition.isEmpty { height += 27 }
        return max(48, height + 7)
    }

    /// The card's frame within this cell.
    ///
    /// This was briefly derived from the enclosing clip view, to defeat the padding
    /// `NSTableView.style = .automatic` adds to cells. That made every cell's layout depend on its
    /// own position in the view hierarchy, and recycled cells disagreed: the same list rendered
    /// some rows with a card origin of 8 and others of 2, so their icons and titles sat six points
    /// apart while the cards themselves lined up. The table is `.fullWidth` now, which removes the
    /// padding at its source, so the cell's own bounds are both correct and identical for every row.
    private var cardRect: NSRect {
        appKitAgentCardRect(in: bounds, depth: depth)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard group == nil else { return }
        let card = cardRect
        guard card.width > 0 else { return }
        let path = NSBezierPath(
            roundedRect: card,
            xRadius: AgentCard.radius,
            yRadius: AgentCard.radius)
        NSColor.nSurface.setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func updateGroupTint() {
        guard let group else { return }
        titleField.textColor = group == .attention
            ? .nErrorText
            : group == .active ? .nInfoText : .secondaryLabelColor
    }

    override func layout() {
        super.layout()
        let card = cardRect
        if group != nil {
            statusIcon.frame = NSRect(x: card.minX + 5, y: 6, width: 12, height: 12)
            statusSpinner.frame = statusIcon.frame
            titleField.frame = NSRect(
                x: card.minX + 21,
                y: 4,
                width: max(0, card.width - 21),
                height: 17)
            return
        }

        // Depth belongs to the complete card surface. Adding it here as well would double-indent
        // the contents and make nested cards progressively unreadable.
        let left = card.minX + 10
        statusIcon.frame = NSRect(x: left, y: compact ? 8 : 11, width: 16, height: 16)
        statusSpinner.frame = statusIcon.frame

        let chevronWidth: CGFloat = disclosure.isHidden ? 0 : 16
        stopButton.frame = NSRect(
            x: max(left + 20, card.maxX - 26 - chevronWidth),
            y: compact ? 5 : 8,
            width: 22,
            height: 22)
        disclosure.frame = NSRect(x: card.maxX - 15, y: 12, width: 10, height: 12)

        let controlLeft = stopButton.isHidden
            ? card.maxX - chevronWidth - 8
            : stopButton.frame.minX - 5
        // Measure through the cell, not the bare string. NSTextFieldCell adds its own horizontal
        // inset, so `ceil(stringWidth) + 3` landed a fraction of a point under the natural width
        // (80.0 assigned against 80.04 needed) and the field truncated with the whole card empty
        // beside it. Ceil the cell's own size and keep a point of slack for sub-pixel rounding.
        let metaNatural = ceil(metaField.cell?.cellSize.width ?? 0) + 1
        let metaLimit = compact ? CGFloat(78) : min(150, card.width * 0.38)
        let metaWidth = min(
            min(max(0, metaNatural), max(0, metaLimit)),
            max(0, controlLeft - (left + 48)))
        metaField.frame = NSRect(
            x: controlLeft - metaWidth,
            y: compact ? 7 : 10,
            width: max(0, metaWidth),
            height: 16)
        let headerLeft = left + 23
        let contentRight = max(headerLeft, metaField.frame.minX - 7)
        let headerWidth = max(0, contentRight - headerLeft)
        let hasBadges = !badgeStrip.isHidden
        let hasTitle = !titleField.isHidden && !titleField.stringValue.isEmpty
        let badgeWidth: CGFloat
        if hasBadges, hasTitle {
            // The flat 52% split protected the title, but a short title like "Root agent" left a band
            // of empty header to its right while the badges beside it were being clipped mid-word.
            // Reserve what the title actually measures and give the badges the remainder; the old
            // split stays as a floor so a long title can never starve them.
            let titleNatural = ceil(titleField.cell?.cellSize.width ?? 0) + 1
            badgeWidth = min(
                headerWidth,
                min(
                    badgeStrip.desiredWidth,
                    max(
                        badgeStrip.minimumWidth,
                        max(headerWidth * 0.52, headerWidth - titleNatural - 5))))
        } else if hasBadges {
            badgeWidth = min(badgeStrip.desiredWidth, headerWidth)
        } else {
            badgeWidth = 0
        }
        badgeStrip.frame = NSRect(
            x: headerLeft,
            y: compact ? 5 : 7,
            width: max(0, badgeWidth),
            height: 19)
        let titleX = hasBadges ? badgeStrip.frame.maxX + 5 : headerLeft
        titleField.frame = NSRect(
            x: titleX,
            y: compact ? 6 : 7,
            width: max(0, contentRight - titleX),
            height: 17)

        if compact {
            let subtitleX = left + 23
            subtitleField.frame = NSRect(
                x: subtitleX,
                y: 20,
                width: max(0, controlLeft - subtitleX),
                height: 14)
            stateBand.isHidden = true
            metricsField.isHidden = true
            progressBar.isHidden = true
            summaryField.isHidden = true
            detailField.isHidden = true
            outputIcon.isHidden = true
            outputField.isHidden = true
            openOutputButton.isHidden = true
            errorGlyph.isHidden = true
            errorField.isHidden = true
            compositionBar.isHidden = true
            disclosure.isHidden = true
        } else {
            let contentWidth = max(0, card.maxX - left - 12)
            var y: CGFloat = 33
            if !subtitleField.isHidden {
                let taskHeight = CGFloat(Self.taskLineCount(
                    subtitleField.stringValue,
                    width: contentWidth)) * 15
                subtitleField.frame = NSRect(
                    x: left + 1,
                    y: y,
                    width: contentWidth,
                    height: taskHeight)
                y += taskHeight + 5
            }
            if !stateBand.isHidden {
                stateBand.frame = NSRect(x: left + 1, y: y, width: contentWidth, height: 22)
                y += 27
            }
            if !metricsField.isHidden {
                metricsField.frame = NSRect(x: left + 1, y: y, width: contentWidth, height: 15)
                y += 19
            }
            if !progressBar.isHidden {
                progressBar.frame = NSRect(
                    x: left + 1,
                    y: y + 2,
                    width: contentWidth,
                    height: 5)
                y += 13
            }
            if !summaryField.isHidden {
                let summaryHeight = CGFloat(Self.taskLineCount(
                    summaryField.stringValue,
                    width: contentWidth)) * 14
                summaryField.frame = NSRect(
                    x: left + 1,
                    y: y,
                    width: contentWidth,
                    height: summaryHeight)
                y += summaryHeight + 4
            }
            if !outputField.isHidden {
                let openWidth: CGFloat = 35
                outputIcon.frame = NSRect(x: left + 1, y: y + 3, width: 14, height: 14)
                openOutputButton.frame = NSRect(
                    x: card.maxX - 12 - openWidth,
                    y: y,
                    width: openWidth,
                    height: 20)
                outputField.frame = NSRect(
                    x: outputIcon.frame.maxX + 5,
                    y: y + 2,
                    width: max(
                        0,
                        openOutputButton.frame.minX - outputIcon.frame.maxX - 10),
                    height: 16)
                y += 25
            }
            if !errorField.isHidden {
                errorGlyph.frame = NSRect(x: left + 1, y: y + 2, width: 14, height: 14)
                errorField.frame = NSRect(
                    x: errorGlyph.frame.maxX + 5,
                    y: y,
                    width: max(0, card.maxX - 12 - errorGlyph.frame.maxX - 5),
                    height: 26)
                y += 30
            }
            if !compositionBar.isHidden {
                compositionBar.frame = NSRect(x: left + 1, y: y, width: contentWidth, height: 20)
            }
            detailField.isHidden = true
        }
    }

    func configureGroup(group: AppKitAgentsGroup, count: Int, expanded: Bool) {
        self.group = group
        content = .none
        presentationForTesting = nil
        statusSpinner.isHidden = true
        statusIcon.isHidden = false
        badgeStrip.configure([])
        stateBand.configure(nil, status: .pending, stalled: false)
        metricsField.isHidden = true
        progressBar.configure(nil, status: .pending)
        summaryField.isHidden = true
        outputIcon.isHidden = true
        outputField.isHidden = true
        openOutputButton.isHidden = true
        openOutputButton.handler = nil
        errorGlyph.isHidden = true
        errorField.isHidden = true
        compositionBar.isHidden = true
        disclosure.isHidden = true
        compact = false
        depth = 0
        let foldable = group != .active
        setAccessibilityRole(foldable ? .button : .group)
        statusIcon.image = NSImage(
            systemSymbolName: foldable
                ? (expanded ? "chevron.down" : "chevron.right")
                : "bolt.fill",
            accessibilityDescription: nil)
        statusIcon.contentTintColor = group == .attention
            ? .systemRed
            : group == .active ? .controlAccentColor : .secondaryLabelColor
        titleField.isHidden = false
        titleField.stringValue = "\(group.title.uppercased())  \(count)"
        titleField.font = .systemFont(ofSize: 10, weight: .bold)
        subtitleField.isHidden = true
        detailField.isHidden = true
        metaField.isHidden = true
        stopButton.isHidden = true
        setAccessibilityLabel(
            "\(group.title), \(count) \(count == 1 ? "agent" : "agents")"
                + (foldable ? (expanded ? ", expanded" : ", collapsed") : ""))
        needsLayout = true
        needsDisplay = true
    }

    func configure(
        root: AgentRootActivitySnapshot,
        compact: Bool,
        onStop: @escaping () -> Void
    ) {
        group = nil
        setAccessibilityRole(.group)
        content = .root(root)
        self.compact = compact
        depth = 0
        stopButton.isHidden = !root.isActive
        stopButton.handler = onStop
        stopButton.toolTip = "Stop root agent"
        stopButton.setAccessibilityLabel("Stop root agent")
        apply(
            appKitRootAgentCardPresentation(root),
            stalled: root.isStalled)
        needsLayout = true
        needsDisplay = true
    }

    func configure(
        subagent: SubagentRun,
        ordinal: Int?,
        depth: Int,
        compact: Bool,
        activityIndex: AgentActivityLedgerIndex,
        now: Date,
        onStop: @escaping (String) -> Void
    ) {
        group = nil
        setAccessibilityRole(.button)
        content = .subagent(subagent, ordinal, activityIndex)
        self.compact = compact
        self.depth = depth
        subtitleField.isHidden = false
        metaField.isHidden = false
        // `taskId` arrives with the SDK's task_* events and can stay nil for the whole life of a run
        // whose provider never sent them. Hiding Stop in that case left a card spinning with no way
        // to clear it. The tool-use key identifies the same run to `stopRun(matching:)`, and a
        // provider that doesn't know the id simply ignores the request.
        let stopID = subagent.taskId ?? subagent.key
        stopButton.isHidden = subagent.status != .running
        stopButton.handler = { onStop(stopID) }
        stopButton.toolTip = "Stop this agent"
        stopButton.setAccessibilityLabel("Stop this agent")
        updateSubagent(subagent, ordinal: ordinal, activityIndex: activityIndex, now: now)
        needsLayout = true
        needsDisplay = true
    }

    func configure(
        workflow: WorkflowRun,
        expanded: Bool,
        compact: Bool,
        now: Date,
        onStop: @escaping (String) -> Void
    ) {
        group = nil
        setAccessibilityRole(.button)
        content = .workflow(workflow, expanded)
        self.compact = compact
        depth = 0
        let stopID = workflow.runTaskId ?? workflow.toolUseId ?? workflow.runKey
        stopButton.isHidden = !appKitWorkflowHasLiveWork(workflow)
        stopButton.handler = { onStop(stopID) }
        stopButton.toolTip = "Stop this workflow"
        stopButton.setAccessibilityLabel("Stop this workflow")
        updateWorkflow(workflow, expanded: expanded, now: now)
        needsLayout = true
        needsDisplay = true
    }

    func configure(
        workflowAgent: WorkflowAgent,
        run: WorkflowRun,
        ordinal: Int,
        depth: Int,
        compact: Bool,
        activityIndex: AgentActivityLedgerIndex = AgentActivityLedgerIndex([]),
        now: Date
    ) {
        group = nil
        setAccessibilityRole(.button)
        content = .workflowAgent(workflowAgent, run, ordinal, activityIndex)
        self.compact = compact
        self.depth = depth
        stopButton.isHidden = true
        stopButton.handler = nil
        updateWorkflowAgent(
            workflowAgent,
            run: run,
            ordinal: ordinal,
            activityIndex: activityIndex,
            now: now)
        needsLayout = true
        needsDisplay = true
    }

    func tick(now: Date) {
        switch content {
        case .root:
            // The list owns the selected-turn index and reconfigures this structural row on ticks.
            break
        case .subagent(let subagent, let ordinal, let activityIndex):
            guard subagent.status == .running else { return }
            updateSubagent(subagent, ordinal: ordinal, activityIndex: activityIndex, now: now)
        case .workflow(let workflow, let expanded):
            guard appKitWorkflowHasLiveWork(workflow) else { return }
            updateWorkflow(workflow, expanded: expanded, now: now)
        case .workflowAgent(let agent, let run, let ordinal, let activityIndex):
            guard agent.state.isRunning else { return }
            updateWorkflowAgent(
                agent,
                run: run,
                ordinal: ordinal,
                activityIndex: activityIndex,
                now: now)
        case .none:
            break
        }
    }

    private func updateSubagent(
        _ subagent: SubagentRun,
        ordinal: Int?,
        activityIndex: AgentActivityLedgerIndex,
        now: Date
    ) {
        let laneID = AgentActivityIdentity.subagent(subagent.key)
        let activity = activityIndex.cardSnapshot(agentID: laneID, now: now)
        let presentation = appKitSubagentCardPresentation(
            subagent,
            ordinal: ordinal,
            activity: activity,
            now: now)
        apply(presentation, stalled: activity.isStalled)
    }

    private func updateWorkflow(_ workflow: WorkflowRun, expanded: Bool, now: Date) {
        let presentation = appKitWorkflowCardPresentation(
            workflow,
            expanded: expanded,
            now: now)
        disclosure.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: presentation.disclosureLabel)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        apply(presentation, stalled: false)
    }

    private func updateWorkflowAgent(
        _ agent: WorkflowAgent,
        run: WorkflowRun,
        ordinal: Int,
        activityIndex: AgentActivityLedgerIndex,
        now: Date
    ) {
        let activity = activityIndex.cardSnapshot(
            agentID: AgentActivityIdentity.workflow(runKey: run.runKey, agentKey: agent.id),
            now: now)
        let presentation = appKitWorkflowAgentCardPresentation(
            agent,
            in: run,
            ordinal: ordinal,
            activity: activity,
            now: now)
        disclosure.image = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: presentation.disclosureLabel)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        apply(presentation, stalled: activity.isStalled)
    }

    private func apply(_ presentation: AppKitAgentCardPresentation, stalled: Bool) {
        presentationForTesting = presentation
        configureStatus(presentation.status)
        badgeStrip.configure(presentation.badges)
        titleField.isHidden = presentation.title.isEmpty
        titleField.stringValue = presentation.title
        titleField.font = .systemFont(ofSize: compact ? 10 : 11, weight: .semibold)
        titleField.textColor = presentation.status.needsAttention ? .nErrorText : .labelColor

        subtitleField.isHidden = presentation.task.isEmpty
        subtitleField.stringValue = presentation.task
        subtitleField.font = .systemFont(ofSize: compact ? 9 : 11)
        subtitleField.textColor = compact ? .secondaryLabelColor : .labelColor
        subtitleField.maximumNumberOfLines = compact ? 1 : 2
        subtitleField.toolTip = presentation.task.isEmpty ? nil : presentation.task

        stateBand.configure(
            presentation.stateBand,
            status: presentation.status,
            stalled: stalled)
        metricsField.stringValue = presentation.metrics ?? ""
        metricsField.isHidden = presentation.metrics == nil
        metricsField.toolTip = presentation.metrics
        metricsField.setAccessibilityLabel(presentation.metrics ?? "")
        progressBar.configure(presentation.progress, status: presentation.status)

        summaryField.stringValue = presentation.summary.map { "Summary · \($0)" } ?? ""
        summaryField.isHidden = presentation.summary == nil
        summaryField.toolTip = presentation.summary
        summaryField.setAccessibilityLabel(
            presentation.summary.map { "Summary \($0)" } ?? "")

        if let output = presentation.outputFile {
            let filename = (output as NSString).lastPathComponent
            outputIcon.isHidden = false
            outputField.isHidden = false
            outputField.stringValue = filename
            outputField.toolTip = output
            outputField.setAccessibilityLabel("Workflow output \(output)")
            openOutputButton.isHidden = false
            openOutputButton.toolTip = "Open \(filename)"
            openOutputButton.setAccessibilityLabel("Open workflow output \(filename)")
            let url = URL(fileURLWithPath: output)
            openOutputButton.handler = { [weak self] in self?.outputOpener(url) }
        } else {
            outputIcon.isHidden = true
            outputField.isHidden = true
            outputField.stringValue = ""
            outputField.toolTip = nil
            outputField.setAccessibilityLabel("")
            openOutputButton.isHidden = true
            openOutputButton.handler = nil
            openOutputButton.toolTip = nil
            openOutputButton.setAccessibilityLabel("")
        }

        errorField.stringValue = presentation.error ?? ""
        errorField.isHidden = presentation.error == nil
        errorField.toolTip = presentation.error
        errorField.setAccessibilityLabel(
            presentation.error.map { "Error \($0)" } ?? "")
        errorGlyph.isHidden = presentation.error == nil
        compositionBar.configure(presentation.toolComposition, trailing: "")
        compositionBar.isHidden = presentation.toolComposition.isEmpty

        metaField.isHidden = presentation.meta.isEmpty
        metaField.stringValue = presentation.meta
        metaField.font = .monospacedDigitSystemFont(ofSize: compact ? 9 : 10, weight: .medium)
        metaField.textColor = stalled ? .nWarningText : .secondaryLabelColor
        metaField.toolTip = presentation.meta

        disclosure.isHidden = compact || !presentation.isExpandable
        disclosure.toolTip = presentation.disclosureLabel
        disclosure.setAccessibilityElement(true)
        disclosure.setAccessibilityLabel(presentation.disclosureLabel)
        detailField.isHidden = true
        setAccessibilityLabel(presentation.accessibilityText)
    }

    private func configureStatus(_ status: WorkflowStatus) {
        let label = status == .running ? "Working" : status.label
        statusIcon.toolTip = label
        statusIcon.setAccessibilityElement(true)
        statusIcon.setAccessibilityLabel(label)
        statusSpinner.toolTip = label
        statusSpinner.setAccessibilityElement(true)
        statusSpinner.setAccessibilityLabel(label)
        if status == .running {
            statusSpinner.configure(
                color: nil,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            statusIcon.isHidden = true
            statusSpinner.isHidden = false
        } else {
            statusSpinner.isHidden = true
            statusIcon.isHidden = false
            statusIcon.image = statusImage(status)
            statusIcon.contentTintColor = statusColor(status)
        }
    }

    private func statusImage(_ status: WorkflowStatus) -> NSImage? {
        let name: String
        switch status {
        case .running: name = "bolt.circle.fill"
        case .completed: name = "checkmark.circle.fill"
        case .failed, .killed: name = "xmark.octagon.fill"
        case .paused: name = "pause.circle.fill"
        case .stopped: name = "stop.circle.fill"
        case .pending: name = "circle.dotted"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: status.label)
    }

    private func statusColor(_ status: WorkflowStatus) -> NSColor {
        switch status {
        case .running: return .controlAccentColor
        case .completed: return .systemGreen
        case .failed, .killed: return .systemRed
        case .paused, .stopped: return .systemOrange
        case .pending: return .secondaryLabelColor
        }
    }
}

// MARK: - Native activity model

/// Activity's display modes are AppKit policy, not retained activity data. Keeping Trends here lets
/// the panel aggregate the bounded conversation ledger without teaching the provider-neutral model
/// file about one renderer's navigation.
enum AppKitAgentActivityVisualizationMode: String, CaseIterable {
    case trace
    case usage
    case trends
}

enum AppKitAgentActivityTrendMetric: String, CaseIterable {
    case duration
    case tokens
    case context
    case reliability
    case runtime

    var title: String {
        switch self {
        case .duration: return String(localized: "Duration")
        case .tokens: return String(localized: "Tokens")
        case .context: return String(localized: "Context")
        case .reliability: return String(localized: "Events")
        case .runtime: return String(localized: "Harness metrics")
        }
    }

    var menuTitle: String {
        switch self {
        case .duration: return String(localized: "Duration by turn")
        case .tokens: return String(localized: "Tokens by turn")
        case .context: return String(localized: "Context by turn")
        case .reliability: return String(localized: "Events by turn")
        case .runtime: return String(localized: "Harness metrics")
        }
    }
}

private let appKitHarnessLaneID = "harness"

/// The token categories Activity can distinguish, plus whether a drawn remainder is an exact fresh
/// input measurement or merely the part left after every breakdown the provider supplied. Optional
/// categories are absence, never a measured zero.
struct AppKitActivityTokenAnatomy: Equatable {
    var inputTotal: Int?
    var freshInput: Int?
    var cacheRead: Int?
    var cacheWrite: Int?
    var answerOutput: Int?
    var reasoningOutput: Int?
    var unclassified: Int?

    var plottedCacheRead: Int {
        guard let cacheRead else { return 0 }
        guard let inputTotal else { return max(0, cacheRead) }
        return min(max(0, cacheRead), max(0, inputTotal))
    }

    var plottedCacheWrite: Int {
        guard let cacheWrite else { return 0 }
        guard let inputTotal else { return max(0, cacheWrite) }
        return min(max(0, cacheWrite), max(0, inputTotal - plottedCacheRead))
    }

    var inputRemainder: Int? {
        if let inputTotal {
            // The plotted subdivisions always sum to the provider's input total, even when a
            // malformed or differently scoped component would otherwise exceed it.
            return max(0, inputTotal - plottedCacheRead - plottedCacheWrite)
        }
        return freshInput.map { max(0, $0) }
    }

    var inputRemainderIsExact: Bool {
        if let freshInput, let inputRemainder {
            return max(0, freshInput) == inputRemainder
        }
        return inputTotal != nil && cacheRead != nil && cacheWrite != nil
    }

    var generated: Int? {
        guard answerOutput != nil || reasoningOutput != nil else { return nil }
        return max(0, answerOutput ?? 0) + max(0, reasoningOutput ?? 0)
    }

    var processed: Int? {
        guard inputTotal != nil || generated != nil || unclassified != nil else { return nil }
        return max(0, inputTotal ?? 0) + max(0, generated ?? 0)
            + max(0, unclassified ?? 0)
    }
}

struct AppKitAgentActivityTrendTurn: Identifiable, Equatable {
    var id: String
    var startedAt: Date
    var endedAt: Date
    var providerAccess: ModelAccess?
    var modelID: String?
    var outcome: AgentActivityPhase?
    var tokens: AppKitActivityTokenAnatomy
    var finalContextTokens: Int?
    var peakContextTokens: Int?
    var contextWindow: Int?
    var compactionCount: Int
    var retryCount: Int
    var recoveryCount: Int
    var subtractionCount: Int
    var rerouteCount: Int
    var safetyCount: Int
    var failureCount: Int
    var ttft: TimeInterval?

    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
}

/// A stable, human-readable scale for the categorical per-turn duration chart. The top tick is a
/// rounded ceiling rather than the raw slowest observation, so the slowest mark does not masquerade
/// as a fixed 100% boundary. Every tick carries its unit because this compact chart has no room for
/// a separate rotated axis title.
struct AppKitDurationTrendScale: Equatable {
    let maximum: TimeInterval
    let step: TimeInterval
    let ticks: [TimeInterval]

    init(observedMaximum: TimeInterval) {
        let observed = observedMaximum.isFinite ? max(0, observedMaximum) : 0
        guard observed > 0 else {
            maximum = 1
            step = 0.5
            ticks = [0, 0.5, 1]
            return
        }

        let roughStep = max(Double.leastNonzeroMagnitude, observed / 2)
        let magnitude = pow(10, floor(log10(roughStep)))
        let normalized = roughStep / magnitude
        let niceNormalized: Double
        if normalized <= 1 {
            niceNormalized = 1
        } else if normalized <= 2 {
            niceNormalized = 2
        } else if normalized <= 2.5 {
            niceNormalized = 2.5
        } else if normalized <= 5 {
            niceNormalized = 5
        } else {
            niceNormalized = 10
        }
        let niceStep = niceNormalized * magnitude
        var intervalCount = max(1, Int(ceil(observed / niceStep)))
        var ceiling = Double(intervalCount) * niceStep
        // Leave headroom when an observation lands exactly on a nice boundary. A dot centered on
        // the top rule otherwise looks clipped and makes the scale feel normalized rather than
        // quantitative.
        if abs(ceiling - observed) <= max(1e-9, observed * 1e-9), intervalCount < 3 {
            intervalCount += 1
            ceiling = Double(intervalCount) * niceStep
        }
        maximum = ceiling
        step = niceStep
        ticks = (0...intervalCount).map { Double($0) * niceStep }
    }

    func label(for value: TimeInterval) -> String {
        let bounded = max(0, value)
        if maximum < 1 {
            return String(format: "%.0fms", bounded * 1_000)
        }
        if maximum < 60 {
            return step < 1
                ? String(format: "%.1fs", bounded)
                : String(format: "%.0fs", bounded)
        }
        let wholeSeconds = Int(bounded.rounded())
        if wholeSeconds == 0 { return "0s" }
        if wholeSeconds < 60 { return "\(wholeSeconds)s" }
        if wholeSeconds < 3_600 {
            let minutes = wholeSeconds / 60
            let seconds = wholeSeconds % 60
            return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
        }
        let hours = wholeSeconds / 3_600
        let minutes = (wholeSeconds % 3_600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }
}

/// Select non-overlapping categorical time labels. Retained turns are equally spaced categories,
/// not a continuous time series; these labels provide chronology without implying that the gaps
/// between turns were equal in wall-clock time.
func appKitDurationTrendTimeLabelIndices(
    turnCount: Int,
    columnWidth: CGFloat,
    selectedIndex: Int,
    minimumSpacing: CGFloat = 54
) -> [Int] {
    guard turnCount > 0 else { return [] }
    guard turnCount > 1 else { return [0] }
    let width = max(1, columnWidth)
    if width >= minimumSpacing { return Array(0..<turnCount) }

    var indices = [0, turnCount - 1]
    func canInsert(_ candidate: Int) -> Bool {
        indices.allSatisfy { abs(CGFloat(candidate - $0)) * width >= minimumSpacing }
    }
    let boundedSelection = min(turnCount - 1, max(0, selectedIndex))
    if boundedSelection != 0,
       boundedSelection != turnCount - 1,
       canInsert(boundedSelection) {
        indices.append(boundedSelection)
    }
    let stride = max(1, Int(ceil(minimumSpacing / width)))
    for candidate in Swift.stride(from: stride, to: turnCount - 1, by: stride)
        where canInsert(candidate) {
        indices.append(candidate)
    }
    return indices.sorted()
}

private struct AppKitHarnessRuntimeMetricGroup {
    var laneID: AgentHarnessLaneID?
    var samples: [HarnessMetricSample]

    var title: String {
        guard let laneID else { return String(localized: "Unattributed harness") }
        if laneID == .claude { return "Claude" }
        if laneID == .codex { return "Codex" }
        if laneID == .openAI { return "OpenAI" }
        return laneID.rawValue
    }
}

/// The provider wire names are deliberately closed and safe, but they are still telemetry schema
/// names rather than interface copy. Runtime keeps the exact name for inspection while presenting
/// a short title, an unambiguous value, and the dimensions that make two otherwise similar rows
/// distinct.
struct AppKitRuntimeMetricPresentation: Equatable {
    var title: String
    var value: String
    var detail: String
    var fullDetail: String = ""
    var sortPriority: Int
}

struct AppKitRuntimeMetricTextLayout: Equatable {
    var title: NSRect
    var value: NSRect
    var detail: NSRect
}

func appKitRuntimeMetricTextLayout(
    in row: NSRect,
    presentation: AppKitRuntimeMetricPresentation
) -> AppKitRuntimeMetricTextLayout {
    let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    let valueWidth = min(
        row.width * 0.48,
        ceil((presentation.value as NSString).size(withAttributes: [.font: valueFont]).width) + 3)
    let value = NSRect(
        x: row.maxX - 8 - valueWidth,
        y: row.minY + 5,
        width: valueWidth,
        height: 12)
    let titleX = row.minX + 10
    return AppKitRuntimeMetricTextLayout(
        title: NSRect(
            x: titleX,
            y: row.minY + 4,
            width: max(18, value.minX - titleX - 7),
            height: 13),
        value: value,
        detail: NSRect(
            x: titleX,
            y: row.minY + 19,
            width: max(20, row.width - 18),
            height: 11))
}

private let appKitRuntimeMetricExactTitles: [String: String] = [
    "claude_code.session.count": String(localized: "Sessions"),
    "claude_code.lines_of_code.count": String(localized: "Lines of code"),
    "claude_code.pull_request.count": String(localized: "Pull requests"),
    "claude_code.commit.count": String(localized: "Commits"),
    "claude_code.cost.usage": String(localized: "Cost"),
    "claude_code.token.usage": String(localized: "Token usage"),
    "claude_code.code_edit_tool.decision": String(localized: "Code-edit decisions"),
    "claude_code.active_time.total": String(localized: "Active time"),
    "codex.account.rate_limits.bucket_count": String(localized: "Rate-limit buckets"),
    "codex.account.rate_limits.primary.used_percent.max": String(localized: "Primary limit used"),
    "codex.account.rate_limits.secondary.used_percent.max": String(localized: "Secondary limit used"),
    "codex.account.rate_limits.individual.remaining_percent.min": String(localized: "Individual limit remaining"),
    "codex.account.rate_limits.primary.window_seconds.max": String(localized: "Primary limit window"),
    "codex.account.rate_limits.secondary.window_seconds.max": String(localized: "Secondary limit window"),
    "codex.account.rate_limits.primary.resets_at.earliest": String(localized: "Primary limit reset"),
    "codex.account.rate_limits.secondary.resets_at.earliest": String(localized: "Secondary limit reset"),
    "codex.account.rate_limits.individual.resets_at.earliest": String(localized: "Individual limit reset"),
    "codex.account.rate_limits.credits.has_credits.any": String(localized: "Credits available"),
    "codex.account.rate_limits.credits.unlimited.any": String(localized: "Unlimited credits"),
    "codex.account.rate_limits.spend_control_reached.any": String(localized: "Spend control reached"),
    "codex.account.rate_limits.reached.any": String(localized: "Rate limit reached"),
    "codex.account.rate_limits.reset_credits.available": String(localized: "Reset credits available"),
    "codex.account.tokens.lifetime": String(localized: "Lifetime tokens"),
    "codex.account.tokens.daily.peak": String(localized: "Peak daily tokens"),
    "codex.account.tokens.daily.bucket_count": String(localized: "Daily usage buckets"),
    "codex.account.tokens.daily.recent": String(localized: "Recent daily tokens"),
    "codex.account.turn.longest_running": String(localized: "Longest running turn"),
    "codex.account.streak.current_days": String(localized: "Current streak"),
    "codex.account.streak.longest_days": String(localized: "Longest streak"),
]

private func appKitRuntimeMetricWords(_ raw: String) -> String {
    let special: [String: String] = [
        "api": "API", "sse": "SSE", "mcp": "MCP", "db": "database",
        "http": "HTTP", "ttft": "TTFT", "ttfm": "TTFM", "tbt": "TBT",
        "e2e": "end-to-end", "usd": "USD",
    ]
    let words = raw
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .split(separator: " ")
        .map { word -> String in
            let lower = word.lowercased()
            return special[lower] ?? lower
        }
        .joined(separator: " ")
    guard let first = words.first else { return raw }
    return String(first).uppercased() + words.dropFirst()
}

private func appKitRuntimeMetricTitle(_ name: String) -> String {
    if let exact = appKitRuntimeMetricExactTitles[name] { return exact }
    var components = name.split(separator: ".").map(String.init)
    if components.first == "codex" { components.removeFirst() }
    if components.first == "claude_code" { components.removeFirst() }
    while let suffix = components.last,
          ["max", "min", "any", "earliest"].contains(suffix) {
        components.removeLast()
    }
    guard !components.isEmpty else { return appKitRuntimeMetricWords(name) }
    return appKitRuntimeMetricWords(components.joined(separator: " "))
}

private func appKitRuntimeMetricAttributeText(
    key: HarnessMetricAttributeKey,
    value: HarnessMetricAttributeValue
) -> String? {
    guard key != .provider else { return nil }
    func words(_ raw: String) -> String { appKitRuntimeMetricWords(raw) }
    switch (key, value) {
    case (.success, .bool(let flag)):
        return flag ? String(localized: "Successful") : String(localized: "Failed")
    case (.cached, .bool(let flag)):
        return flag ? String(localized: "Cached") : String(localized: "Uncached")
    case (.warm, .bool(let flag)):
        return flag ? String(localized: "Warm") : String(localized: "Cold")
    case (.provenance, .string("local_otlp")):
        return String(localized: "Local telemetry")
    case (_, .string(let raw)):
        return words(raw)
    case (_, .bool(let flag)):
        return flag ? String(localized: "Yes") : String(localized: "No")
    case (_, .number(let number)):
        return String(format: "%.3g", number)
    }
}

private func appKitRuntimeMetricSortPriority(_ name: String) -> Int {
    if name.contains("rate_limits.reached") { return 0 }
    if name.contains("rate_limits") && (name.contains("used_percent")
        || name.contains("remaining_percent")) { return 1 }
    if name.contains("rate_limits") && name.contains("resets_at") { return 2 }
    if name.contains("rate_limits") && name.contains("window_seconds") { return 3 }
    if name.contains("rate_limits") { return 4 }
    if name.contains("account.tokens") || name.contains("account.turn")
        || name.contains("account.streak") { return 10 }
    if name.contains("cost") { return 20 }
    if name.contains("token") { return 21 }
    if name.contains("duration") || name.contains("ttft") || name.contains("ttfm")
        || name.contains("tbt") || name.contains("e2e") { return 30 }
    if name.contains("error") || name.contains("fail") { return 40 }
    if name.contains("decision") || name.contains("status") { return 45 }
    return 50
}

private func appKitRuntimeCompactDuration(_ seconds: Double) -> String {
    let sign = seconds < 0 ? "−" : ""
    let value = abs(seconds)
    if value >= 86_400 {
        let days = Int(value / 86_400)
        let hours = Int(value.truncatingRemainder(dividingBy: 86_400) / 3_600)
        return hours == 0
            ? String(localized: "\(sign)\(days)d")
            : String(localized: "\(sign)\(days)d \(hours)h")
    }
    if value >= 3_600 {
        let hours = Int(value / 3_600)
        let minutes = Int(value.truncatingRemainder(dividingBy: 3_600) / 60)
        return minutes == 0
            ? String(localized: "\(sign)\(hours)h")
            : String(localized: "\(sign)\(hours)h \(minutes)m")
    }
    if value >= 60 {
        let minutes = Int(value / 60)
        let seconds = Int(value.rounded()) % 60
        return seconds == 0
            ? String(localized: "\(sign)\(minutes)m")
            : String(localized: "\(sign)\(minutes)m \(seconds)s")
    }
    if value >= 10 {
        return String(localized: "\(sign)\(String(format: "%.0f", value))s")
    }
    if value >= 1 {
        return String(localized: "\(sign)\(String(format: "%.1f", value))s")
    }
    return String(localized: "\(sign)\(String(format: "%.0f", value * 1_000))ms")
}

private let appKitRuntimeCompactTimestamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter
}()

private func appKitRuntimeMetricValue(_ sample: HarnessMetricSample) -> String {
    let measurement: (value: Double, qualifier: String?)? = {
        if sample.kind == .histogram {
            if let count = sample.count, count > 0, let sum = sample.sum {
                return (sum / Double(count), String(localized: "avg"))
            }
            if let value = sample.value { return (value, nil) }
            if let sum = sample.sum { return (sum, String(localized: "total")) }
            if let maximum = sample.max { return (maximum, String(localized: "max")) }
            if let minimum = sample.min { return (minimum, String(localized: "min")) }
            return nil
        }
        return (sample.value ?? sample.sum ?? sample.max ?? sample.min)
            .map { ($0, nil) }
    }()
    guard let measurement else { return String(localized: "Not reported") }
    let value = measurement.value
    if sample.kind == .gauge,
       sample.unit == .count,
       sample.name.hasSuffix(".any"),
       value == 0 || value == 1 {
        return value == 1 ? String(localized: "Yes") : String(localized: "No")
    }
    if sample.name.contains("streak."), sample.unit == .count {
        let count = Int(value.rounded())
        return String(localized: "\(count) days")
    }
    let formatted: String = switch sample.unit {
    case .count: String(format: "%.0f", value)
    case .tokens: formatTokens(Int(value.rounded()))
    case .milliseconds:
        abs(value) < 1_000
            ? String(format: "%.0fms", value)
            : appKitRuntimeCompactDuration(value / 1_000)
    case .seconds: appKitRuntimeCompactDuration(value)
    case .unixSeconds:
        if value >= 0, value <= 32_503_680_000 {
            appKitRuntimeCompactTimestamp.string(from: Date(timeIntervalSince1970: value))
        } else {
            String(localized: "Invalid timestamp")
        }
    case .bytes: ByteCountFormatter.string(
        fromByteCount: Int64(value.rounded()), countStyle: .file)
    case .usd:
        abs(value) >= 0.01 ? String(format: "$%.3f", value) : String(format: "$%.4g", value)
    case .ratio: String(format: "%.3g", value)
    case .percent: String(format: "%.3g%%", value)
    case .lines: String(localized: "\(Int(value.rounded())) lines")
    }
    if let qualifier = measurement.qualifier {
        return String(localized: "\(formatted) \(qualifier)")
    }
    return formatted
}

func appKitRuntimeMetricPresentation(
    _ sample: HarnessMetricSample
) -> AppKitRuntimeMetricPresentation {
    var kindDetail: [String] = []
    switch sample.kind {
    case .counter:
        kindDetail.append(String(localized: "Cumulative counter"))
    case .gauge:
        kindDetail.append(String(localized: "Latest gauge"))
    case .histogram:
        if let count = sample.count {
            kindDetail.append(count == 1
                ? String(localized: "1 sample")
                : String(localized: "\(count) samples"))
        } else {
            kindDetail.append(String(localized: "Distribution"))
        }
    }
    let preferredDimensions: [HarnessMetricAttributeKey] = [
        .scope, .model, .event, .outcome, .status, .phase, .toolKind, .success,
        .cached, .access, .provenance,
    ]
    let remainingDimensions = HarnessMetricAttributeKey.allCases.filter {
        $0 != .provider && !preferredDimensions.contains($0)
    }
    var conciseDimensions: [String] = []
    var fullDimensions: [String] = []
    for key in preferredDimensions + remainingDimensions {
        guard let value = sample.attributes[key],
              let text = appKitRuntimeMetricAttributeText(key: key, value: value)
        else { continue }
        if !conciseDimensions.contains(text), kindDetail.count + conciseDimensions.count < 4 {
            conciseDimensions.append(text)
        }
        fullDimensions.append("\(appKitRuntimeMetricWords(key.rawValue)): \(text)")
    }
    let detail = (kindDetail + conciseDimensions).joined(separator: " · ")
    let fullDetail = (kindDetail + fullDimensions).joined(separator: " · ")
    return AppKitRuntimeMetricPresentation(
        title: appKitRuntimeMetricTitle(sample.name),
        value: appKitRuntimeMetricValue(sample),
        detail: detail,
        fullDetail: fullDetail,
        sortPriority: appKitRuntimeMetricSortPriority(sample.name))
}

private func appKitHarnessRuntimeMetricGroups(
    _ samples: [HarnessMetricSample]
) -> [AppKitHarnessRuntimeMetricGroup] {
    // OTLP readers may append repeated points for the same instrument. Runtime shows its latest
    // bounded aggregate instead of implying that those snapshots are per-turn samples.
    var latest: [HarnessMetricSeriesIdentity: HarnessMetricSample] = [:]
    for sample in samples {
        let key = sample.seriesIdentity
        if latest[key].map({ $0.at < sample.at }) != false {
            latest[key] = sample
        }
    }
    var compacted = Array(latest.values)
    let dailyPrefix = "codex.account.tokens.daily."
    let dailySamples = compacted.filter { sample in
        guard sample.name.hasPrefix(dailyPrefix) else { return false }
        let suffix = sample.name.dropFirst(dailyPrefix.count)
        let parts = suffix.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3
            && parts[0].count == 4 && parts[1].count == 2 && parts[2].count == 2
            && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }
    compacted.removeAll { dailySamples.contains($0) }
    let dailySeries = Dictionary(grouping: dailySamples) { sample in
        var identity = sample.seriesIdentity
        // Dates live in the instrument name; fold them only within the exact same typed dimension
        // set so two account/runtime dimensions cannot be blended into one recent histogram.
        identity.name = dailyPrefix
        return identity
    }
    for (identity, laneSamples) in dailySeries {
        let values = laneSamples.compactMap(\.value)
        guard !values.isEmpty,
              let recent = laneSamples.max(by: { $0.name < $1.name }),
              let summary = HarnessMetricSample(
                  name: "codex.account.tokens.daily.recent",
                  kind: .histogram,
                  at: laneSamples.map(\.at).max() ?? recent.at,
                  unit: .tokens,
                  harnessLaneID: identity.harnessLaneID,
                  count: values.count,
                  sum: values.reduce(0, +),
                  min: values.min(),
                  max: values.max(),
                  attributes: recent.attributes)
        else { continue }
        compacted.append(summary)
    }
    return Dictionary(grouping: compacted, by: \.harnessLaneID)
        .map { laneID, samples in
            AppKitHarnessRuntimeMetricGroup(
                laneID: laneID,
                samples: samples.sorted {
                    let lhsPriority = appKitRuntimeMetricSortPriority($0.name)
                    let rhsPriority = appKitRuntimeMetricSortPriority($1.name)
                    if lhsPriority != rhsPriority {
                        return lhsPriority < rhsPriority
                    }
                    let lhsTitle = appKitRuntimeMetricTitle($0.name)
                    let rhsTitle = appKitRuntimeMetricTitle($1.name)
                    if lhsTitle != rhsTitle { return lhsTitle < rhsTitle }
                    if $0.name != $1.name { return $0.name < $1.name }
                    return $0.at < $1.at
                })
        }
        .sorted {
            let lhs = $0.laneID?.rawValue ?? "~"
            let rhs = $1.laneID?.rawValue ?? "~"
            return lhs < rhs
        }
}

private let appKitRuntimeOnlySummaryID = "__mechanician_runtime_session__"

func appKitRuntimeOnlySummary(
    samples: [HarnessMetricSample]
) -> AgentActivityTurnSummary? {
    guard let startedAt = samples.map(\.at).min(),
          let endedAt = samples.map(\.at).max() else { return nil }
    return AgentActivityTurnSummary(
        id: appKitRuntimeOnlySummaryID,
        startedAt: startedAt,
        endedAt: max(startedAt, endedAt),
        providerAccess: nil,
        modelID: nil,
        isTerminal: true,
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        aggregateOnlyTokens: 0)
}

func appKitActivityTokenAnatomy(
    records: [AgentActivityRecord],
    breakdown: AgentActivityTokenBreakdown? = nil
) -> AppKitActivityTokenAnatomy {
    let tokens = breakdown ?? agentActivityTokenBreakdown(records)
    let tokenRecords = agentActivityEffectiveTokenRecords(records)
        .filter { $0.kind == .tokens }
    let fresh = tokenRecords.contains(where: { $0.uncachedInputTokens != nil })
        ? tokenRecords.compactMap(\.uncachedInputTokens).reduce(0, +) : nil
    let read = tokenRecords.contains(where: { $0.cachedInputTokens != nil })
        ? tokens.cachedInput : nil
    let write = tokenRecords.contains(where: { $0.cacheWriteInputTokens != nil })
        ? tokenRecords.compactMap(\.cacheWriteInputTokens).reduce(0, +) : nil
    let reportedInput = tokenRecords.contains(where: { $0.inputTokens != nil })
        ? tokens.input : nil
    let reportedComponents = [fresh, read, write].compactMap { $0 }
    let inputTotal = reportedInput
        ?? (reportedComponents.isEmpty ? nil : reportedComponents.reduce(0, +))
    return AppKitActivityTokenAnatomy(
        inputTotal: inputTotal,
        freshInput: fresh,
        cacheRead: read,
        cacheWrite: write,
        answerOutput: tokenRecords.contains(where: { $0.outputTokens != nil })
            ? tokens.output : nil,
        reasoningOutput: tokenRecords.contains(where: { $0.reasoningOutputTokens != nil })
            ? tokens.reasoningOutput : nil,
        unclassified: tokenRecords.contains(where: { $0.totalTokens != nil })
            ? tokens.unclassified : nil)
}

func appKitAgentActivityTrendTurns(
    records: [AgentActivityRecord],
    summaries: [AgentActivityTurnSummary]
) -> [AppKitAgentActivityTrendTurn] {
    let recordsByTurn = Dictionary(grouping: records.compactMap { record in
        record.turnID.map { ($0, record) }
    }, by: \.0)
    let reliabilityByTurn = Dictionary(uniqueKeysWithValues:
        agentHarnessReliabilityTrend(records).map { ($0.id, $0) })

    return summaries.reversed().map { summary in
        let turnRecords = (recordsByTurn[summary.id] ?? []).map(\.1)
        let ordered = turnRecords.enumerated().sorted {
            if $0.element.at != $1.element.at { return $0.element.at < $1.element.at }
            return $0.offset < $1.offset
        }.map(\.element)
        let rootContext = ordered.filter {
            $0.agentID == AgentActivityIdentity.root
                && $0.kind == .context
                && $0.contextTokens != nil
        }
        let outcome = turnRecords.last {
            $0.agentID == AgentActivityIdentity.root
                && $0.kind == .state
                && $0.phase?.isTerminal == true
        }?.phase
        let reliability = reliabilityByTurn[summary.id]
        let reliableOutcome: AgentActivityPhase? = {
            switch reliability?.terminalOutcome {
            case .completed: return .completed
            case .failed: return .failed
            case .interrupted: return .stopped
            case nil: return outcome
            }
        }()
        let tokens = appKitActivityTokenAnatomy(
            records: turnRecords,
            breakdown: summary.tokenBreakdown)
        let finalContextTokens = rootContext.last?.contextTokens
        let peakContextTokens = reliability?.contextPeakTokens
            ?? rootContext.compactMap(\.contextTokens).max()
        let contextWindow = reliability?.contextLimitTokens ?? rootContext.compactMap {
            $0.contextUsableWindowTokens ?? $0.contextWindow
        }.last
        let compactionCount = reliability?.compactionCount
            ?? turnRecords.filter { $0.kind == .compaction }.count
        let retryCount = reliability?.retryEventCount ?? turnRecords.filter {
            $0.retryDisposition != nil || $0.retryAttempt != nil
        }.count
        let recoveryCount = reliability?.recoveredRetryCount ?? turnRecords.filter {
            $0.harnessEventKind == .retryRecovered || $0.retryDisposition == .recovered
        }.count
        let subtractionCount = turnRecords.filter {
            $0.contextEventKind == .subtraction
        }.count
        let rerouteCount = reliability?.rerouteCount
            ?? turnRecords.filter { $0.rerouteModelID != nil }.count
        let safetyCount = reliability?.safetyEventCount
            ?? turnRecords.filter { $0.safetyOutcome != nil }.count
        let recordedTTFT = ordered.compactMap {
            $0.timeToFirstOutputMs
                ?? $0.streamTimeToFirstOutputMs
                ?? $0.timeToFirstTokenMs
        }.last
        let ttftMilliseconds = reliability?.timeToFirstOutputMs ?? recordedTTFT
        return AppKitAgentActivityTrendTurn(
            id: summary.id,
            startedAt: summary.startedAt,
            endedAt: summary.endedAt,
            providerAccess: summary.providerAccess,
            modelID: summary.modelID,
            outcome: reliableOutcome,
            tokens: tokens,
            finalContextTokens: finalContextTokens,
            peakContextTokens: peakContextTokens,
            contextWindow: contextWindow,
            compactionCount: compactionCount,
            retryCount: retryCount,
            recoveryCount: recoveryCount,
            subtractionCount: subtractionCount,
            rerouteCount: rerouteCount,
            safetyCount: safetyCount,
            failureCount: reliableOutcome == .failed ? 1 : 0,
            ttft: ttftMilliseconds.map { TimeInterval($0) / 1_000 })
    }
}

func appKitHarnessTraceSpans(
    records: [AgentActivityRecord],
    summary: AgentActivityTurnSummary
) -> [AppKitAgentActivityTraceSpan] {
    let milestones = records.enumerated().filter {
        $0.element.agentID == AgentActivityIdentity.root
            && $0.element.harnessPhase != nil
    }.sorted {
        if $0.element.at != $1.element.at { return $0.element.at < $1.element.at }
        return $0.offset < $1.offset
    }.map(\.element)
    guard !milestones.isEmpty else { return [] }

    func stage(endingAt phase: AgentHarnessPhase) -> (String, AgentActivityPhase) {
        switch phase {
        case .providerReady:
            return (String(localized: "Provider startup"), .waiting)
        case .threadReady:
            return (String(localized: "Thread setup"), .waiting)
        case .requestAccepted:
            return (String(localized: "Request setup"), .waiting)
        case .firstOutput:
            return (String(localized: "First output wait"), .model)
        case .terminal:
            return (String(localized: "Provider response"), .model)
        }
    }

    func stage(after phase: AgentHarnessPhase) -> (String, AgentActivityPhase)? {
        switch phase {
        case .providerReady:
            return (String(localized: "Thread setup"), .waiting)
        case .threadReady:
            return (String(localized: "Request setup"), .waiting)
        case .requestAccepted:
            return (String(localized: "First output wait"), .model)
        case .firstOutput:
            return (String(localized: "Streaming response"), .model)
        case .terminal:
            return nil
        }
    }

    let rootTerminalBoundary = records.filter {
        $0.agentID == AgentActivityIdentity.root
            && $0.kind == .state
            && $0.phase?.isTerminal == true
    }.map(\.at).min()
    let harnessEnd = min(summary.endedAt, rootTerminalBoundary ?? summary.endedAt)
    let lastHarnessPhase = milestones.last?.harnessPhase
    let hasOpenTail = !summary.isTerminal
        && rootTerminalBoundary == nil
        && lastHarnessPhase.flatMap(stage(after:)) != nil

    var spans: [AppKitAgentActivityTraceSpan] = []
    var cursor = summary.startedAt
    for milestone in milestones {
        guard let harnessPhase = milestone.harnessPhase else { continue }
        let end = min(max(cursor, milestone.at), harnessEnd)
        if end > cursor {
            let presentation = stage(endingAt: harnessPhase)
            spans.append(AppKitAgentActivityTraceSpan(
                span: AgentActivityTraceSpan(
                    id: milestone.id,
                    start: cursor,
                    end: end,
                    phase: presentation.1,
                    title: presentation.0,
                    detail: milestone.measurementProvenance.map(appKitMeasurementProvenanceLabel),
                    tokens: AgentActivityTokenBreakdown(),
                    toolNames: [],
                    sourceCount: 1),
                isOpen: false))
        }
        cursor = max(cursor, milestone.at)
    }
    if (cursor < harnessEnd || hasOpenTail),
       let lastPhase = lastHarnessPhase,
       let presentation = stage(after: lastPhase) {
        spans.append(AppKitAgentActivityTraceSpan(
            span: AgentActivityTraceSpan(
                id: appKitDerivedSpanID(milestones.last!.id),
                start: min(cursor, harnessEnd),
                end: max(min(cursor, harnessEnd), harnessEnd),
                phase: presentation.1,
                title: presentation.0,
                detail: milestones.last?.measurementProvenance.map(appKitMeasurementProvenanceLabel),
                tokens: AgentActivityTokenBreakdown(),
                toolNames: [],
                sourceCount: 1),
            isOpen: hasOpenTail))
    }
    return spans
}

private func appKitDerivedSpanID(_ source: UUID) -> UUID {
    var bytes = source.uuid
    withUnsafeMutableBytes(of: &bytes) { raw in
        raw[raw.count - 1] ^= 0x80
    }
    return UUID(uuid: bytes)
}

private func appKitMeasurementProvenanceLabel(
    _ provenance: AgentMeasurementProvenance
) -> String {
    switch provenance {
    case .mechanicianClock: return String(localized: "Measured by Mechanician")
    case .providerReport: return String(localized: "Reported by provider")
    case .derived: return String(localized: "Derived measurement")
    case .estimated: return String(localized: "Estimated measurement")
    }
}

private func appKitHarnessTokenLabel(_ rawValue: String) -> String {
    rawValue.replacingOccurrences(of: "_", with: " ")
}

private func appKitContextCategoryLabel(_ category: AgentContextCompositionCategory) -> String {
    switch category {
    case .systemPrompt: return String(localized: "system prompt")
    case .systemTools: return String(localized: "system tools")
    case .mcpTools: return String(localized: "MCP tools")
    case .deferredTools: return String(localized: "deferred tools")
    case .memory: return String(localized: "memory")
    case .agents: return String(localized: "agents")
    case .skills: return String(localized: "skills")
    case .commands: return String(localized: "commands")
    case .messages: return String(localized: "messages")
    case .compactionBuffer: return String(localized: "compaction buffer")
    case .free: return String(localized: "free")
    case .other: return String(localized: "other")
    }
}

private func appKitHarnessEventAppearsOnRail(_ record: AgentActivityRecord) -> Bool {
    guard let event = record.harnessEventKind else { return false }
    switch event {
    case .retry, .retryRecovered, .retryExhausted,
         .modelRerouted, .modelSafety, .modelVerification,
         .permission, .mcpConnection, .interrupt, .internalError:
        return true
    case .phase, .tool, .result, .context, .compaction, .hook:
        return false
    }
}

struct AppKitAgentActivityTraceSpan: Equatable {
    var span: AgentActivityTraceSpan
    /// A final nonterminal state is an open observation, not a measured completed duration.
    var isOpen: Bool
}

struct AppKitAgentActivityLane: Equatable {
    var id: String
    var label: String
    var detail: String?
    var records: [AgentActivityRecord]
    var spans: [AppKitAgentActivityTraceSpan]
    var usage: AgentActivityTokenBreakdown
    var isActive: Bool
}

struct AppKitAgentActivityRenderInput: Equatable {
    var records: [AgentActivityRecord]
    var summary: AgentActivityTurnSummary
    var aliases: [String: String]
    var labels: [String: String]
    /// The full task each agent was given. The lane label is a truncated summary; this is the
    /// unabridged text, used for the lane's tooltip and its hover readout. It was being dropped at
    /// model-build time, so the trace could never say what an agent had actually been asked to do.
    var details: [String: String] = [:]
    /// Optional measured harness stages. They render as a lane above Root, but are excluded from the
    /// agent critical-path calculation and agent usage filter.
    var harnessSpans: [AppKitAgentActivityTraceSpan] = []
    /// Oldest first, for the retained-conversation Trends mode.
    var trendTurns: [AppKitAgentActivityTrendTurn] = []
    var selectedTrendTurnID: String? = nil
    /// Short-lived, provider-wide aggregates. These are deliberately separate from per-turn
    /// protocol measurements because no runtime metric is implied to belong to the selected turn.
    var runtimeSamples: [HarnessMetricSample] = []
}

struct AppKitAgentContextSample: Equatable {
    var at: Date
    var tokens: Int
    var window: Int?
}

struct AppKitAgentContextSeries: Equatable {
    var samples: [AppKitAgentContextSample] = []
    var compactionDates: [Date] = []
    var reportedWindow: Int?
    var scaleMaximum = 0

    var latestTokens: Int? { samples.last?.tokens }
    var headroom: Int? {
        guard let latestTokens, let reportedWindow else { return nil }
        return max(0, reportedWindow - latestTokens)
    }
}

struct AppKitAgentActivityTickDelta: Equatable {
    var oldEnd: Date
    var newEnd: Date
    var openLaneIDs: [String]
}

enum AppKitAgentActivityTickInvalidationPlan: Equatable {
    case none
    case full
}

/// A live tick repaints the plot or does nothing — there is no partial case.
///
/// Fixed-scale trace mode used to invalidate only the open lanes' newly exposed tails plus the cost
/// track and ruler, on the reasoning that closed spans keep identical coordinates. That reasoning
/// held for span geometry and nothing else: `rebuildUsageBuckets` re-derives all 52 token buckets
/// against the new `end` on every tick, so the histogram's bars change across the whole plot, and a
/// lane that appeared since the last full rebuild has no strip to invalidate at all. The result was
/// a plot whose ruler advanced while its bars held stale pixels until some unrelated rebuild
/// repainted everything at once. One viewport-sized repaint per second is not worth that.
func appKitAgentActivityTickInvalidationPlan(
    delta: AppKitAgentActivityTickDelta?
) -> AppKitAgentActivityTickInvalidationPlan {
    delta == nil ? .none : .full
}

/// Cached ledger-derived chart state. `rebuild` is called only for a different value input.
/// `tick` extends open tails in O(number of lanes), while pointer movement changes no model data.
final class AppKitAgentActivityRenderModel {
    private(set) var input: AppKitAgentActivityRenderInput?
    private let activityIndexCache = AgentActivityLedgerIndexCache()
    private var activityIndex = AgentActivityLedgerIndex([])
    private(set) var lanes: [AppKitAgentActivityLane] = []
    private(set) var globalEvents: [AgentActivityRecord] = []
    private(set) var usageBuckets: [AgentActivityUsageBucket] = []
    private(set) var contextSeries = AppKitAgentContextSeries()
    private(set) var start = Date()
    private(set) var end = Date()
    private(set) var usageAgentID: String?
    /// The spans that actually determined how long the turn took.
    ///
    /// A waterfall shows where time went; it does not say which of the overlapping bars *caused*
    /// the total. Walking backwards from the end answers that: at any instant the turn is gated
    /// either by the root doing its own work, or — while the root is blocked on delegates — by
    /// whichever delegate runs latest, because that is the one the root is waiting for. Shortening
    /// anything off this chain would not have shortened the turn.
    private(set) var criticalSpanIDs: Set<UUID> = []

    /// Total time attributable to the critical chain.
    private(set) var criticalPathDuration: TimeInterval = 0

    private func rebuildCriticalPath() {
        criticalSpanIDs = []
        criticalPathDuration = 0
        guard !lanes.isEmpty else { return }

        // Everything that could gate the turn, by lane.
        struct Candidate {
            var laneID: String
            var span: AgentActivityTraceSpan
        }
        var candidates: [Candidate] = []
        for lane in lanes {
            for item in lane.spans where !item.span.phase.isTerminal {
                candidates.append(Candidate(laneID: lane.id, span: item.span))
            }
        }
        guard !candidates.isEmpty else { return }

        let rootID = AgentActivityIdentity.root
        var cursor = end
        /// The lane whose chain is currently being followed backwards.
        var currentLaneID: String?
        // A turn is a few hundred spans at most; the guard is only to bound pathological input.
        var steps = 0
        while cursor > start, steps < 10_000 {
            steps += 1
            // Spans covering this instant, excluding zero-length ones that cannot make progress.
            let covering = candidates.filter {
                $0.span.start < cursor && $0.span.end >= cursor && $0.span.end > $0.span.start
            }
            guard !covering.isEmpty else {
                // A gap: nothing was running. Jump to the previous span end so idle time is not
                // attributed to anyone.
                let previousEnd = candidates
                    .map(\.span.end)
                    .filter { $0 < cursor }
                    .max()
                guard let previousEnd, previousEnd < cursor else { break }
                cursor = previousEnd
                continue
            }

            // Stay inside the chain already being followed. Re-deciding at every instant let the
            // walk hop into whichever lane happened to end latest overall, so an agent that had
            // long since finished could be credited for time inside another agent's chain.
            let chosen: Candidate?
            // Only a delegate's chain is followed through. The root interleaves its own work with
            // time spent blocked, so staying in it would credit the root's waiting span — which is
            // by definition not work — for the delegate that was actually gating the turn.
            if let current = currentLaneID,
               current != rootID,
               let continuing = covering
                .filter({ $0.laneID == current })
                .max(by: { $0.span.start < $1.span.start }) {
                chosen = continuing
            } else {
                // A boundary: either the root is working, or it is blocked and the delegate that
                // runs latest is the one it is waiting for.
                let root = covering.filter { $0.laneID == rootID }
                let delegates = covering.filter { $0.laneID != rootID }
                if delegates.isEmpty {
                    chosen = root.max { $0.span.start < $1.span.start }
                } else {
                    chosen = delegates.max {
                        if $0.span.end != $1.span.end { return $0.span.end < $1.span.end }
                        return $0.span.start > $1.span.start
                    }
                }
            }
            guard let chosen else { break }
            currentLaneID = chosen.laneID

            criticalSpanIDs.insert(chosen.span.id)
            let contribution = min(cursor, chosen.span.end)
                .timeIntervalSince(max(start, chosen.span.start))
            criticalPathDuration += max(0, contribution)
            let nextCursor = max(start, chosen.span.start)
            // If this lane has nothing covering the new cursor, the chain has run out and the next
            // step decides afresh.
            let laneContinues = candidates.contains {
                $0.laneID == chosen.laneID
                    && $0.span.start < nextCursor
                    && $0.span.end >= nextCursor
                    && $0.span.end > $0.span.start
            }
            if !laneContinues { currentLaneID = nil }
            cursor = nextCursor
        }
    }

    /// Whether the turn this model describes is still running, which is what earns the plot a
    /// runway of empty space ahead of "now".
    var isLive: Bool { input?.summary.isTerminal == false }
    private(set) var rebuildCount = 0
    private(set) var timerRedrawCount = 0
    private(set) var pointerRedrawCount = 0
    var activityIndexRebuildCount: Int { activityIndexCache.rebuildCount }

    /// Step insight shares the chart's monotonic horizon. A pointer redraw must not advance a live
    /// duration independently, and retained terminal history must not keep aging after it ended.
    func currentStep(agentID: String) -> AgentStepSnapshot? {
        activityIndex.currentStep(agentID: agentID, now: end)
    }

    func stepIsStalled(agentID: String) -> Bool {
        activityIndex.stepIsStalled(agentID: agentID, now: end)
    }

    @discardableResult
    func rebuild(_ input: AppKitAgentActivityRenderInput, now: Date) -> Bool {
        guard self.input != input else { return false }
        // A live turn's horizon only ever grows. Rebuild and tick used to derive `end` differently —
        // rebuild took `max(now, endedAt)` while tick took plain `now` — so a rebuild that saw a
        // record dated ahead of the caller's clock pushed the horizon out and the next tick pulled
        // it back, shortening every open span. That is the plot visibly running backwards.
        let liveFloor = self.input?.summary.id == input.summary.id ? end : Date.distantPast
        self.input = input
        rebuildCount += 1
        // The lane labels ask for both the current step and its stall status during drawing. Keep
        // the ledger's grouping and sorts here, once per changed records/aliases value, instead of
        // reconstructing them twice for every lane on every AppKit display pass.
        activityIndex = activityIndexCache.index(
            for: input.records,
            aliases: input.aliases)
        start = input.summary.startedAt
        end = input.summary.isTerminal
            ? max(input.summary.endedAt, start.addingTimeInterval(0.001))
            : max(now, input.summary.endedAt, liveFloor, start.addingTimeInterval(0.001))

        let ordered = input.records.enumerated().sorted {
            if $0.element.at != $1.element.at { return $0.element.at < $1.element.at }
            return $0.offset < $1.offset
        }.map(\.element)
        // Usage shown beside each lane must use the same authoritative-snapshot reconciliation as
        // the headline and Usage view. Keeping raw provisional rows here made a lane disagree with
        // the turn total whenever the harness later supplied a final request/tree snapshot.
        let effectiveTokenRecordIDs = Set(
            agentActivityEffectiveTokenRecords(input.records)
                .lazy
                .filter { $0.kind == .tokens }
                .map(\.id))
        let appendOrderedLaneRecords = Dictionary(grouping: input.records.filter {
            $0.kind == .state || $0.kind == .tokens || $0.kind == .tool
                || $0.kind == .compaction
        }) { record in
            input.aliases[record.agentID] ?? record.agentID
        }
        globalEvents = ordered.filter {
            $0.kind == .compaction
                || $0.kind == .interjection
                || $0.contextEventKind == .historyReduction
                || $0.contextEventKind == .subtraction
                || appKitHarnessEventAppearsOnRail($0)
        }
        let contextSamples = ordered.compactMap { record -> AppKitAgentContextSample? in
            let canonical = input.aliases[record.agentID] ?? record.agentID
            guard record.kind == .context,
                  canonical == AgentActivityIdentity.root,
                  let tokens = record.contextTokens else { return nil }
            return AppKitAgentContextSample(
                at: record.at,
                tokens: max(0, tokens),
                window: record.contextWindow.flatMap { $0 > 0 ? $0 : nil })
        }
        let maximumContextTokens = contextSamples.map(\.tokens).max() ?? 0
        let pressureScaleMaximum: Int = {
            guard maximumContextTokens > 0 else { return 1 }
            let (scaled, multiplyOverflow) =
                maximumContextTokens.multipliedReportingOverflow(by: 112)
            guard !multiplyOverflow else { return .max }
            let (rounded, addOverflow) = scaled.addingReportingOverflow(99)
            guard !addOverflow else { return .max }
            return max(1, rounded / 100)
        }()
        contextSeries = AppKitAgentContextSeries(
            samples: contextSamples,
            compactionDates: globalEvents
                .filter { $0.kind == .compaction }
                .map(\.at),
            reportedWindow: contextSamples.compactMap(\.window).last,
            // Scale to the context WINDOW, so the filled height literally means "share of the
            // window consumed". Scaling to the observed peak made the curve fill the plot in every
            // turn — a turn at 11% and a turn at 95% drew the same picture, which is the one thing
            // this chart exists to distinguish. A low sliver is not a failure to show change; it is
            // the information that there is plenty of headroom.
            scaleMaximum: contextSamples.isEmpty
                ? 0
                : (contextSamples.compactMap(\.window).last ?? pressureScaleMaximum))

        var grouped: [String: [AgentActivityRecord]] = [:]
        // Compaction records ride along so the lane's span builder can close a compacting interval at
        // the boundary the provider actually reported. They draw nothing themselves here — the shared
        // event rail owns their marker — and every lane consumer filters on `.state`.
        for record in ordered
        where record.kind == .state || record.kind == .tokens || record.kind == .tool
            || record.kind == .compaction {
            let canonical = input.aliases[record.agentID] ?? record.agentID
            grouped[canonical, default: []].append(record)
        }

        lanes = grouped.map { id, records in
            var usage = AgentActivityTokenBreakdown()
            for record in records
            where record.kind == .tokens && effectiveTokenRecordIDs.contains(record.id) {
                usage.add(record)
            }
            // Provider timestamps are geometry, never lifecycle order. Partition the canonical lane
            // in append order before sorting each generation by its provider clock. This retains
            // legitimate completed history while preventing buffered state or late metadata from a
            // prior generation from attaching to a reopened span.
            let appendOrderedRecords = appendOrderedLaneRecords[id] ?? records
            let generations = agentActivityLifecycleGenerationRecords(appendOrderedRecords)
            let currentGeneration = generations.last ?? []
            let isActive = agentActivityLaneIsActive(currentGeneration)
            var rawSpans: [AgentActivityTraceSpan] = []
            var currentGenerationLastState: AgentActivityRecord?
            for (index, generation) in generations.enumerated() {
                let acceptedLifecycle = terminalMonotonicActivityStates(generation)
                let visibleStateIDs = Set(acceptedLifecycle.map(\.id))
                let terminalBoundary = agentActivityLaneTerminalBoundary(generation)
                let nextBoundary = generations.indices.contains(index + 1)
                    ? generations[index + 1].first(where: {
                        $0.kind == .state && $0.startsNewLifecycleGeneration == true
                    })?.at
                    : nil
                // A previous generation that never received a terminal event still ends when the
                // next authoritative generation begins. Never let provider clock skew extend the
                // old geometry across that boundary.
                let generationEnd = max(start, min(end, nextBoundary ?? end))
                var traceRecords = generation.filter { record in
                    guard record.at <= generationEnd else { return false }
                    if record.kind == .state {
                        guard record.phase?.isTerminal != true else { return false }
                        return visibleStateIDs.contains(record.id)
                    }
                    guard let terminalBoundary, record.at > terminalBoundary else { return true }
                    return false
                }
                if var projectedTerminal = acceptedLifecycle.first(where: {
                    $0.kind == .state && $0.phase?.isTerminal == true
                }) {
                    if let refined = acceptedLifecycle.last(where: {
                        $0.kind == .state && $0.phase?.isTerminal == true
                    }) {
                        projectedTerminal.phase = refined.phase
                        projectedTerminal.detail = refined.detail
                    }
                    projectedTerminal.at = min(projectedTerminal.at, generationEnd)
                    traceRecords.append(projectedTerminal)
                }
                rawSpans.append(contentsOf: agentActivityTraceSpans(
                    traceRecords,
                    start: start,
                    end: generationEnd))
                if index == generations.count - 1 {
                    currentGenerationLastState = acceptedLifecycle.last {
                        $0.kind == .state && $0.phase != nil
                    }
                }
            }
            rawSpans.sort {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.id.uuidString < $1.id.uuidString
            }
            let openStateID: UUID? = {
                guard isActive, !input.summary.isTerminal,
                      currentGenerationLastState?.phase?.isTerminal == false else { return nil }
                return currentGenerationLastState?.id
            }()
            return AppKitAgentActivityLane(
                id: id,
                label: input.labels[id]
                    ?? records.last(where: { $0.agentLabel?.isEmpty == false })?.agentLabel
                    ?? (id == AgentActivityIdentity.root ? "Root agent" : "Agent"),
                detail: input.details[id],
                records: records,
                spans: rawSpans.map {
                    AppKitAgentActivityTraceSpan(span: $0, isOpen: $0.id == openStateID)
                },
                usage: usage,
                isActive: isActive)
        }
        .sorted {
            if $0.id == AgentActivityIdentity.root { return true }
            if $1.id == AgentActivityIdentity.root { return false }
            let lhs = $0.records.first?.at ?? .distantPast
            let rhs = $1.records.first?.at ?? .distantPast
            if lhs != rhs { return lhs < rhs }
            return $0.id < $1.id
        }

        rebuildCriticalPath()

        if !input.harnessSpans.isEmpty {
            var harnessSpans = input.harnessSpans
            if let openIndex = harnessSpans.lastIndex(where: \.isOpen) {
                harnessSpans[openIndex].span.end = max(
                    harnessSpans[openIndex].span.start,
                    end)
            }
            lanes.insert(
                AppKitAgentActivityLane(
                    id: appKitHarnessLaneID,
                    label: String(localized: "Harness"),
                    detail: String(localized: "Measured host and provider stages"),
                    records: [],
                    spans: harnessSpans,
                    usage: AgentActivityTokenBreakdown(),
                    isActive: harnessSpans.contains(where: \.isOpen)),
                at: 0)
        }

        if let usageAgentID, !lanes.contains(where: { $0.id == usageAgentID }) {
            self.usageAgentID = nil
        }
        rebuildUsageBuckets()
        return true
    }

    @discardableResult
    func setUsageAgentID(_ agentID: String?) -> Bool {
        let valid = agentID.flatMap { candidate in
            candidate != appKitHarnessLaneID && lanes.contains(where: { $0.id == candidate })
                ? candidate : nil
        }
        guard valid != usageAgentID else { return false }
        usageAgentID = valid
        rebuildUsageBuckets()
        return true
    }

    @discardableResult
    func tick(now: Date) -> AppKitAgentActivityTickDelta? {
        guard let input, !input.summary.isTerminal else { return nil }
        let oldEnd = end
        // Monotonic, and derived the same way `rebuild` derives it: a clock that jumps backwards, or
        // a rebuild that already pushed the horizon past this caller's `now`, must not shorten the
        // spans that are already drawn.
        let nextEnd = max(now, end, start.addingTimeInterval(0.001))
        guard nextEnd != end else { return nil }
        end = nextEnd
        var openLaneIDs: [String] = []
        for laneIndex in lanes.indices {
            guard let spanIndex = lanes[laneIndex].spans.lastIndex(where: \.isOpen) else { continue }
            lanes[laneIndex].spans[spanIndex].span.end = nextEnd
            openLaneIDs.append(lanes[laneIndex].id)
        }
        // Bucket boundaries are dates, not percentages. Leaving the original boundaries in place
        // while `end` advances compresses the entire token histogram into the left edge of a live
        // Fit trace, even though the lane spans and ruler correctly occupy the new duration.
        rebuildUsageBuckets()
        timerRedrawCount += 1
        return AppKitAgentActivityTickDelta(
            oldEnd: oldEnd,
            newEnd: nextEnd,
            openLaneIDs: openLaneIDs)
    }

    func notePointerRedraw() {
        pointerRedrawCount += 1
    }

    private func rebuildUsageBuckets() {
        guard let input else {
            usageBuckets = []
            return
        }
        usageBuckets = agentActivityUsageBuckets(
            input.records,
            start: start,
            end: end,
            count: 52,
            agentID: usageAgentID,
            aliases: input.aliases)
    }
}

// MARK: - Compact control language

/// The activity header is a 30-point strip inside an inspector, not a window toolbar. Stock
/// `NSSegmentedControl` and `NSPopUpButton` draw at system control size with full bezels, which
/// dwarf that strip and read as system controls bolted onto the panel. These three controls draw
/// the same capsule vocabulary the rest of the app uses, at the panel's scale.
private enum ActivityControl {
    static let height: CGFloat = 20
    static let font = NSFont.systemFont(ofSize: 9, weight: .medium)
    static let horizontalPadding: CGFloat = 9

    /// This strip is drawn on the activity panel's own `windowBackgroundColor`, never on a card, and
    /// `nElevated` there is within a couple of 8-bit levels of the background — the track has been
    /// invisible in Light Mode for as long as the panel has painted its own background. Found while
    /// checking what the inspector's move to the window background would disturb; it disturbs
    /// nothing here, because this was already wrong.
    static func track(hovered: Bool) -> NSColor {
        NSColor.nTrackOnBackground.withAlphaComponent(hovered ? 0.95 : 0.72)
    }

    static func width(of title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// A capsule segmented control. Exposes `selectedSegment` so it drops into the same call sites the
/// stock control used. Internal so the tooltip-owner lifecycle can be exercised without waiting
/// for AppKit's delayed hover timer in a UI test.
final class AppKitActivitySegmentedControl: NSView, NSViewToolTipOwner {
    var onChange: (() -> Void)?
    private let titles: [String]
    private let helpText: [String]
    private var hovered: Int?
    private var tracking: NSTrackingArea?
    private(set) var toolTipTextByTag: [NSView.ToolTipTag: String] = [:]

    var selectedSegment: Int = 0 {
        didSet {
            guard selectedSegment != oldValue else { return }
            setAccessibilityValue(titles.indices.contains(selectedSegment)
                ? titles[selectedSegment]
                : nil)
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(titles: [String], helpText: [String]) {
        self.titles = titles
        self.helpText = helpText
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityValue(titles.first)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: titles.reduce(4) { $0 + ActivityControl.width(of: $1) + ActivityControl.horizontalPadding * 2 },
            height: ActivityControl.height)
    }

    private func segmentRects() -> [NSRect] {
        var x: CGFloat = 2
        return titles.map { title in
            let width = ActivityControl.width(of: title) + ActivityControl.horizontalPadding * 2
            defer { x += width }
            return NSRect(x: x, y: 2, width: width, height: max(0, bounds.height - 4))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp],
            owner: self)
        addTrackingArea(area)
        tracking = area
        removeAllToolTips()
        toolTipTextByTag.removeAll(keepingCapacity: true)
        for (index, rect) in segmentRects().enumerated() where helpText.indices.contains(index) {
            let tag = addToolTip(rect, owner: self, userData: nil)
            toolTipTextByTag[tag] = helpText[index]
        }
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard view === self else { return "" }
        return toolTipTextByTag[tag] ?? ""
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next = segmentRects().firstIndex { $0.contains(point) }
        if next != hovered {
            hovered = next
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = segmentRects().firstIndex(where: { $0.contains(point) }) else { return }
        guard index != selectedSegment else { return }
        selectedSegment = index
        onChange?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123 where selectedSegment > 0: // left arrow
            selectedSegment -= 1
            onChange?()
        case 124 where selectedSegment < titles.count - 1: // right arrow
            selectedSegment += 1
            onChange?()
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        ActivityControl.track(hovered: false).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        for (index, rect) in segmentRects().enumerated() {
            let active = index == selectedSegment
            if active {
                NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
                NSBezierPath(
                    roundedRect: rect,
                    xRadius: rect.height / 2,
                    yRadius: rect.height / 2).fill()
            } else if index == hovered {
                NSColor.nElevated.withAlphaComponent(0.85).setFill()
                NSBezierPath(
                    roundedRect: rect,
                    xRadius: rect.height / 2,
                    yRadius: rect.height / 2).fill()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: ActivityControl.font,
                .foregroundColor: active ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
            ]
            let size = (titles[index] as NSString).size(withAttributes: attributes)
            (titles[index] as NSString).draw(
                at: NSPoint(
                    x: rect.midX - size.width / 2,
                    y: rect.midY - size.height / 2),
                withAttributes: attributes)
        }

        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                xRadius: radius,
                yRadius: radius)
            focus.lineWidth = 1.5
            focus.stroke()
        }
    }
}

/// A capsule icon button. Icon-only, so the accessibility label is required, not optional.
private final class AppKitActivityIconButton: NSButton {
    private var hovered = false
    private var tracking: NSTrackingArea?

    override var wantsUpdateLayer: Bool { true }

    init(symbol: String, label: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        contentTintColor = .secondaryLabelColor
        self.target = target
        self.action = action
        title = ""
        toolTip = label
        setAccessibilityLabel(label)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 24, height: ActivityControl.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        let appearance = effectiveAppearance
        layer?.backgroundColor = hovered
            ? ActivityControl.track(hovered: true).mechanicianCGColor(in: appearance)
            : NSColor.clear.mechanicianCGColor(in: appearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A capsule button carrying a word rather than a glyph. `Fit` and `1×` say what they do; the
/// magnifier icons alone left the zoom controls ambiguous, and an accent-tinted icon read as an
/// arbitrary selected state rather than a mode.
private final class AppKitActivityTextButton: NSButton {
    var isActive = false {
        didSet { if isActive != oldValue { needsDisplay = true } }
    }

    private var hovered = false
    private var tracking: NSTrackingArea?

    init(title: String, help: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        isBordered = false
        self.title = ""
        self.target = target
        self.action = action
        label = title
        toolTip = help
        setAccessibilityLabel(help)
        wantsLayer = true
    }

    private var label = ""

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: ActivityControl.width(of: label) + ActivityControl.horizontalPadding * 2,
            height: ActivityControl.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let fill: NSColor = isActive
            ? NSColor.controlAccentColor.withAlphaComponent(0.16)
            : ActivityControl.track(hovered: hovered)
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: ActivityControl.font,
            .foregroundColor: isEnabled
                ? (isActive ? NSColor.controlAccentColor : NSColor.secondaryLabelColor)
                : NSColor.tertiaryLabelColor
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes)
    }
}

/// A capsule menu button standing in for `NSPopUpButton`. It keeps that class's item API so the
/// panel's rebuild code reads the same, but draws a compact title plus chevron instead of a bezel.
private final class AppKitActivityMenuButton: NSView {
    var onSelect: (() -> Void)?
    var maximumWidth: CGFloat = 190

    private var titles: [String] = []
    private var selection = 0
    private var hovered = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var indexOfSelectedItem: Int { selection }

    func removeAllItems() {
        titles.removeAll()
        selection = 0
    }

    func addItem(withTitle title: String) {
        titles.append(title)
    }

    func selectItem(at index: Int) {
        guard titles.indices.contains(index) else { return }
        selection = index
        setAccessibilityValue(titles[index])
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let title = titles.indices.contains(selection) ? titles[selection] : ""
        let width = ActivityControl.width(of: title)
            + ActivityControl.horizontalPadding * 2
            + 14 // chevron
        return NSSize(width: min(maximumWidth, width), height: ActivityControl.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        presentMenu()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { // space or return
            presentMenu()
        } else {
            super.keyDown(with: event)
        }
    }

    private func presentMenu() {
        let menu = NSMenu()
        for (index, title) in titles.enumerated() {
            let item = NSMenuItem(
                title: title,
                action: #selector(pick(_:)),
                keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == selection ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(
            positioning: menu.item(at: selection),
            at: NSPoint(x: 0, y: bounds.height + 2),
            in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard sender.tag != selection else { return }
        selectItem(at: sender.tag)
        onSelect?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        ActivityControl.track(hovered: hovered).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: ActivityControl.font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let title = titles.indices.contains(selection) ? titles[selection] : ""
        let textWidth = max(0, bounds.width - ActivityControl.horizontalPadding - 16)
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(
            with: NSRect(
                x: ActivityControl.horizontalPadding,
                y: bounds.midY - height / 2,
                width: textWidth,
                height: height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes)

        let chevron = NSBezierPath()
        let cx = bounds.maxX - 11
        let cy = bounds.midY
        chevron.move(to: NSPoint(x: cx - 3, y: cy - 1.5))
        chevron.line(to: NSPoint(x: cx, y: cy + 1.5))
        chevron.line(to: NSPoint(x: cx + 3, y: cy - 1.5))
        chevron.lineWidth = 1.2
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        NSColor.tertiaryLabelColor.setStroke()
        chevron.stroke()

        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                xRadius: radius,
                yRadius: radius)
            focus.lineWidth = 1.5
            focus.stroke()
        }
    }
}

// MARK: - Native activity panel

private final class AppKitAgentActivityScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?
    private(set) var isHandlingUserScroll = false

    override func scrollWheel(with event: NSEvent) {
        isHandlingUserScroll = true
        super.scrollWheel(with: event)
        isHandlingUserScroll = false
        onUserScroll?()
    }
}

private final class AppKitAgentActivityPanelView: NSView {
    private var bridge: AgentBridge
    private let titleField = NSTextField(labelWithString: "Activity")
    private let turnPopup = AppKitActivityMenuButton()
    private let modeControl = AppKitActivitySegmentedControl(
        titles: [
            String(localized: "Trace"),
            String(localized: "Usage"),
            String(localized: "Trends"),
        ],
        helpText: [
            String(localized: "Show what each agent did, in order"),
            String(localized: "Show provider-reported tokens and context"),
            String(localized: "Compare the retained turns in this conversation"),
        ])
    private var closeButton: AppKitActivityIconButton!
    private let processedField = NSTextField(labelWithString: "")
    private let generatedField = NSTextField(labelWithString: "")
    private let contextField = NSTextField(labelWithString: "")
    private let cachedField = NSTextField(labelWithString: "")
    private let contextMeter = AppKitContextMeter()
    private var zoomOutButton: AppKitActivityIconButton!
    private var zoomInButton: AppKitActivityIconButton!
    private var fitButton: AppKitActivityTextButton!
    private var resetZoomButton: AppKitActivityTextButton!
    private var criticalPathButton: AppKitActivityTextButton!
    private let laneFilterButton = AppKitActivityMenuButton()
    private let usageLanePopup = AppKitActivityMenuButton()
    private let trendMetricPopup = AppKitActivityMenuButton()
    private let scrollView = AppKitAgentActivityScrollView()
    private let chartView = AppKitAgentActivityChartView()
    private let legendView = AppKitTraceLegendView()
    private let emptyField = NSTextField(wrappingLabelWithString: "Activity will appear on the next turn.")

    private var selectedTurnID: String?
    private var summaries: [AgentActivityTurnSummary] = []
    private var previousPopupSignature: [String] = []
    private var bridgeActivity: [AgentActivityRecord] = []
    private var previousSubagents: [String: SubagentRun] = [:]
    private var previousRuns: [String: WorkflowRun] = [:]
    private var previousHarnessMetricSamples: [HarnessMetricSample] = []
    private var hasLoadedBridgeSnapshot = false
    private var previousSelectionMarker: String?
    private var renderedSummaryID: String?
    private var followingLive = true
    private var programmaticScroll = false
    private var pendingTrailingFollow = false
    private var hasExplicitTrendMetricSelection = false
    private var clipBoundsObservation: NSObjectProtocol?
    private var usageLaneIDs: [String?] = []
    private var now = Date()

    var onClose: (() -> Void)?
    var needsLiveTick: Bool { selectedSummary?.isTerminal == false }
    var visualizationMode: AppKitAgentActivityVisualizationMode { chartView.mode }
    var visualizationControlModeForTesting: AppKitAgentActivityVisualizationMode? {
        let index = modeControl.selectedSegment
        guard AppKitAgentActivityVisualizationMode.allCases.indices.contains(index) else {
            return nil
        }
        return AppKitAgentActivityVisualizationMode.allCases[index]
    }
    var trendMetricForTesting: AppKitAgentActivityTrendMetric { chartView.trendMetric }
    override var isFlipped: Bool { true }

    init(bridge: AgentBridge) {
        self.bridge = bridge
        super.init(frame: .zero)
        wantsLayer = true
        configureViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let clipBoundsObservation {
            NotificationCenter.default.removeObserver(clipBoundsObservation)
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let appearance = effectiveAppearance
        layer?.backgroundColor = NSColor.windowBackgroundColor
            .mechanicianCGColor(in: appearance)
        layer?.borderColor = NSColor.separatorColor.mechanicianCGColor(in: appearance)
        layer?.borderWidth = 0.5
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func setBridge(_ bridge: AgentBridge) {
        guard self.bridge !== bridge else { return }
        self.bridge = bridge
        resetVisualizationModeToTrace()
        selectedTurnID = nil
        bridgeActivity = []
        previousSubagents = [:]
        previousRuns = [:]
        previousHarnessMetricSamples = []
        hasExplicitTrendMetricSelection = false
        selectTrendMetric(.duration, explicitly: false)
        hasLoadedBridgeSnapshot = false
        previousSelectionMarker = nil
        previousPopupSignature = []
        renderedSummaryID = nil
        followingLive = true
        pendingTrailingFollow = false
    }

    @discardableResult
    func reloadFromBridge(
        harnessMetricSamplesOverrideForTesting: [HarnessMetricSample]? = nil
    ) -> Bool {
        // Rebuilds are driven by the ledger, not by the ticker, so they must read the clock rather
        // than reuse whatever `now` the last tick left behind. A rebuild carrying a stale `now`
        // pins a live turn's horizon to that older instant until the next tick moves it, which is
        // the plot sitting still and then jumping.
        now = Date()
        let activityChanged = !hasLoadedBridgeSnapshot || bridgeActivity != bridge.agentActivity
        let subagentsChanged = !hasLoadedBridgeSnapshot || previousSubagents != bridge.subagents
        let runsChanged = !hasLoadedBridgeSnapshot || previousRuns != bridge.workflowRuns
        let harnessMetricSamples = harnessMetricSamplesOverrideForTesting
            ?? bridge.harnessMetricSamples
        let runtimeMetricsChanged = !hasLoadedBridgeSnapshot
            || previousHarnessMetricSamples != harnessMetricSamples
        let selectionMarker = selectedTurnID.map { "turn:\($0)" } ?? "latest"
        let selectionChanged = previousSelectionMarker != selectionMarker
        guard activityChanged || subagentsChanged || runsChanged || runtimeMetricsChanged
                || selectionChanged else {
            return false
        }
        hasLoadedBridgeSnapshot = true
        previousSelectionMarker = selectionMarker
        bridgeActivity = bridge.agentActivity
        previousSubagents = bridge.subagents
        previousRuns = bridge.workflowRuns
        previousHarnessMetricSamples = harnessMetricSamples
        if runtimeMetricsChanged, !hasExplicitTrendMetricSelection {
            selectTrendMetric(
                previousHarnessMetricSamples.isEmpty ? .duration : .runtime,
                explicitly: false)
        }
        let aliases = laneAliases()
        summaries = agentActivityTurnSummaries(bridgeActivity, aliases: aliases)
        if let selectedTurnID, !summaries.contains(where: { $0.id == selectedTurnID }) {
            self.selectedTurnID = nil
        }
        rebuildTurnPopupIfNeeded()
        guard let summary = selectedSummary else {
            if let runtimeSummary = appKitRuntimeOnlySummary(
                samples: previousHarnessMetricSamples
            ) {
                return showRuntimeOnlyActivity(
                    runtimeSummary,
                    aliases: aliases,
                    samples: previousHarnessMetricSamples)
            }
            renderedSummaryID = nil
            chartView.isHidden = true
            scrollView.isHidden = true
            emptyField.isHidden = false
            updateMetrics(nil)
            return false
        }
        if renderedSummaryID != summary.id {
            renderedSummaryID = summary.id
            followingLive = !summary.isTerminal
            pendingTrailingFollow = followingLive
        }

        // Preserve ledger append order for lifecycle reconciliation. The render model creates its
        // own timestamp-sorted projection for geometry; sorting here first would lose which terminal
        // boundary the app observed before a later provider update carrying a historical timestamp.
        let records = bridgeActivity.filter { $0.turnID == summary.id }
        let input = AppKitAgentActivityRenderInput(
            records: records,
            summary: summary,
            aliases: aliases,
            labels: laneLabels(),
            details: laneDetails(),
            harnessSpans: appKitHarnessTraceSpans(records: records, summary: summary),
            trendTurns: appKitAgentActivityTrendTurns(
                records: bridgeActivity,
                summaries: summaries),
            selectedTrendTurnID: summary.id,
            runtimeSamples: previousHarnessMetricSamples)
        let rebuilt = chartView.rebuild(input: input, now: now)
        rebuildUsageLanePopup()
        rebuildLaneFilter()
        chartView.isHidden = false
        scrollView.isHidden = false
        emptyField.isHidden = true
        updateMetrics(summary)
        legendView.totalText = chartView.totalDurationText
        legendView.marksCriticalPath = chartView.showsCriticalPath
            && !chartView.renderModel.criticalSpanIDs.isEmpty
        needsLayout = true
        if pendingTrailingFollow {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.layoutSubtreeIfNeeded()
                self.updateChartDocumentFrame()
                self.followLiveEdge()
                self.pendingTrailingFollow = false
            }
        }
        return rebuilt
    }

    /// Runtime aggregates can arrive before the first turn ledger row. Preparing that data must
    /// not choose an Activity tab on the person's behalf. Keeping the branch in one method lets
    /// the regression test exercise the same path without opening a provider connection.
    private func showRuntimeOnlyActivity(
        _ runtimeSummary: AgentActivityTurnSummary,
        aliases: [String: String],
        samples: [HarnessMetricSample]
    ) -> Bool {
        let enteringRuntimeOnly = renderedSummaryID != runtimeSummary.id
        renderedSummaryID = runtimeSummary.id
        followingLive = false
        pendingTrailingFollow = false
        if enteringRuntimeOnly {
            if !hasExplicitTrendMetricSelection {
                selectTrendMetric(.runtime, explicitly: false)
            }
        }
        let rebuilt = chartView.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: [],
                summary: runtimeSummary,
                aliases: aliases,
                labels: [:],
                selectedTrendTurnID: nil,
                runtimeSamples: samples),
            now: now)
        rebuildUsageLanePopup()
        rebuildLaneFilter()
        chartView.isHidden = false
        scrollView.isHidden = false
        emptyField.isHidden = true
        updateMetrics(nil)
        legendView.totalText = ""
        legendView.marksCriticalPath = false
        updateZoomControls()
        updateChartDocumentFrame()
        needsLayout = true
        return rebuilt
    }

    func showRuntimeOnlyActivityForTesting(_ samples: [HarnessMetricSample]) {
        guard let summary = appKitRuntimeOnlySummary(samples: samples) else { return }
        previousHarnessMetricSamples = samples
        summaries = []
        _ = showRuntimeOnlyActivity(summary, aliases: [:], samples: samples)
    }

    func tick(now: Date) {
        self.now = now
        guard selectedSummary?.isTerminal == false else { return }
        chartView.tick(now: now)
        if chartView.mode == .trace, !chartView.fitsWidth {
            updateChartDocumentFrame()
            if followingLive, !chartView.hasPinnedInspection {
                followLiveEdge()
            }
        }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let edge: CGFloat = 10
        let controlHeight = ActivityControl.height
        let headerY: CGFloat = 6

        titleField.frame = NSRect(x: 11, y: headerY + 2, width: 63, height: 16)

        let closeWidth = closeButton.intrinsicContentSize.width
        closeButton.frame = NSRect(
            x: max(edge, width - edge - closeWidth),
            y: headerY,
            width: closeWidth,
            height: controlHeight)

        // The turn picker owns the rest of the title row now that the mode control has moved down
        // to sit with the other plot controls.
        let turnX: CGFloat = 80
        let turnAvailable = max(0, closeButton.frame.minX - 8 - turnX)
        turnPopup.maximumWidth = turnAvailable
        turnPopup.invalidateIntrinsicContentSize()
        turnPopup.frame = NSRect(
            x: turnX,
            y: headerY,
            width: min(turnAvailable, turnPopup.intrinsicContentSize.width),
            height: controlHeight)
        turnPopup.isHidden = turnAvailable < 46

        // Row 2: token volume. Row 3: context, on its own line as the shipped panel has it — it is
        // a different question from throughput and sharing a line made all three read as one list.
        let metricsY: CGFloat = 32
        let contextY: CGFloat = 52
        layoutMetrics(from: 11, to: width - edge, y: metricsY, contextY: contextY)

        // Row 4: the controls that act on the plot, gathered into one row instead of being wedged
        // in beside the metrics.
        let controlsY: CGFloat = 74
        let modeWidth = modeControl.intrinsicContentSize.width
        var chartY: CGFloat = 100
        var trailing = width - edge

        switch chartView.mode {
        case .trace:
            laneFilterButton.maximumWidth = max(90, width * 0.42)
            laneFilterButton.invalidateIntrinsicContentSize()
            if !laneFilterButton.isHidden {
                let filterWidth = laneFilterButton.intrinsicContentSize.width
                laneFilterButton.frame = NSRect(
                    x: max(edge, trailing - filterWidth),
                    y: controlsY,
                    width: filterWidth,
                    height: controlHeight)
                trailing = laneFilterButton.frame.minX - 8
            }
            usageLanePopup.isHidden = true
            trendMetricPopup.isHidden = true
        case .usage:
            laneFilterButton.isHidden = true
            usageLanePopup.maximumWidth = min(190, max(80, width - 2 * edge))
            usageLanePopup.invalidateIntrinsicContentSize()
            let laneWidth = usageLanePopup.intrinsicContentSize.width
            let stacksPicker = edge + modeWidth + 8 + laneWidth + edge > width
            usageLanePopup.frame = NSRect(
                x: stacksPicker ? edge : max(edge, trailing - laneWidth),
                y: stacksPicker ? controlsY + 26 : controlsY,
                width: min(laneWidth, max(1, width - 2 * edge)),
                height: controlHeight)
            usageLanePopup.isHidden = false
            if stacksPicker {
                chartY += 26
            } else {
                trailing = usageLanePopup.frame.minX - 8
            }
            trendMetricPopup.isHidden = true
        case .trends:
            laneFilterButton.isHidden = true
            usageLanePopup.isHidden = true
            trendMetricPopup.maximumWidth = min(160, max(80, width - 2 * edge))
            trendMetricPopup.invalidateIntrinsicContentSize()
            let metricWidth = trendMetricPopup.intrinsicContentSize.width
            let stacksPicker = edge + modeWidth + 8 + metricWidth + edge > width
            trendMetricPopup.frame = NSRect(
                x: stacksPicker ? edge : max(edge, trailing - metricWidth),
                y: stacksPicker ? controlsY + 26 : controlsY,
                width: min(metricWidth, max(1, width - 2 * edge)),
                height: controlHeight)
            trendMetricPopup.isHidden = false
            if stacksPicker {
                chartY += 26
            } else {
                trailing = trendMetricPopup.frame.minX - 8
            }
        }

        modeControl.frame = NSRect(
            x: edge,
            y: controlsY,
            width: modeWidth,
            height: controlHeight)

        if chartView.mode == .trace {
            let iconWidth = zoomOutButton.intrinsicContentSize.width
            let fitWidth = fitButton.intrinsicContentSize.width
            let resetWidth = resetZoomButton.intrinsicContentSize.width
            let pathWidth = criticalPathButton.intrinsicContentSize.width
            var x = modeControl.frame.maxX + 10
            let cluster: [(NSView, CGFloat)] = [
                (zoomOutButton, iconWidth),
                (zoomInButton, iconWidth),
                (fitButton, fitWidth),
                (resetZoomButton, resetWidth),
                (criticalPathButton, pathWidth),
            ]
            for (view, itemWidth) in cluster {
                let fits = x + itemWidth <= trailing
                view.isHidden = !fits
                view.frame = fits
                    ? NSRect(x: x, y: controlsY, width: itemWidth, height: controlHeight)
                    : .zero
                if fits { x += itemWidth + 4 }
            }
        } else {
            for view in [
                zoomOutButton as NSView?, zoomInButton, fitButton, resetZoomButton,
                criticalPathButton,
            ] {
                view?.isHidden = true
            }
        }

        let legendHeight: CGFloat = chartView.mode == .trace ? 20 : 0
        legendView.isHidden = legendHeight == 0
        legendView.frame = NSRect(
            x: 0,
            y: max(chartY, bounds.height - legendHeight),
            width: width,
            height: legendHeight)
        let chartFrame = NSRect(
            x: 0,
            y: chartY,
            width: width,
            height: max(0, bounds.height - chartY - legendHeight))
        scrollView.frame = chartFrame
        emptyField.frame = NSRect(
            x: 20,
            y: chartY + max(10, (chartFrame.height - 40) / 2),
            width: max(40, width - 40),
            height: 40)
        updateChartDocumentFrame()
    }

    /// Lays the headline metrics out at their measured widths. The previous fixed-thirds split gave
    /// the context metric whatever was left after the zoom cluster, which truncated it to
    /// `CONTEXT 20….` — a number that reads as broken rather than abbreviated. A metric that cannot
    /// fit whole is dropped instead, so every value shown is a complete one.
    /// Throughput on one row, context pressure on its own beneath it.
    ///
    /// Sharing a line made all of them read as one undifferentiated list, and the context metric —
    /// the longest, and a different question from the other two — was simply dropped whenever the
    /// row ran out of room. It now has a row to itself, with its meter beside it.
    private func layoutMetrics(
        from left: CGFloat,
        to right: CGFloat,
        y: CGFloat,
        contextY: CGFloat
    ) {
        var throughput: [NSTextField] = [processedField]
        if !cachedField.isHidden { throughput.append(cachedField) }
        throughput.append(generatedField)

        let gap: CGFloat = 18
        let widths = throughput.map { ceil($0.fittingSize.width) + 1 }
        let available = max(0, right - left)
        var shown = throughput.count
        while shown > 1,
              widths.prefix(shown).reduce(0, +) + gap * CGFloat(shown - 1) > available {
            shown -= 1
        }
        var x = left
        for (index, field) in throughput.enumerated() {
            guard index < shown else {
                field.isHidden = true
                continue
            }
            field.isHidden = false
            field.frame = NSRect(x: x, y: y, width: widths[index], height: 16)
            x += widths[index] + gap
        }

        let contextWidth = ceil(contextField.fittingSize.width) + 1
        contextField.isHidden = false
        contextField.frame = NSRect(x: left, y: contextY, width: contextWidth, height: 16)

        let meterWidth: CGFloat = 44
        let showsMeter = contextMeter.fraction > 0
            && contextField.frame.maxX + 8 + meterWidth <= right
        contextMeter.isHidden = !showsMeter
        contextMeter.frame = showsMeter
            ? NSRect(
                x: contextField.frame.maxX + 8,
                y: contextField.frame.midY - 2.5,
                width: meterWidth,
                height: 5)
            : .zero
    }

    private var selectedSummary: AgentActivityTurnSummary? {
        if let selectedTurnID {
            return summaries.first { $0.id == selectedTurnID }
        }
        return agentActivityActiveOrLatestTurn(summaries)
    }

    private func configureViews() {
        titleField.font = .systemFont(ofSize: 11, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.toolTip = "Token, state, context maintenance, and user-guidance activity"
        addSubview(titleField)

        turnPopup.onSelect = { [weak self] in self?.turnChanged() }
        turnPopup.setAccessibilityLabel("Provider turn")
        addSubview(turnPopup)

        modeControl.selectedSegment = 0
        modeControl.onChange = { [weak self] in self?.modeChanged() }
        modeControl.setAccessibilityLabel("Activity visualization")
        addSubview(modeControl)

        closeButton = AppKitActivityIconButton(
            symbol: "xmark",
            label: "Hide activity timeline",
            target: self,
            action: #selector(close))
        addSubview(closeButton)

        addSubview(contextMeter)
        for field in [processedField, cachedField, generatedField, contextField] {
            field.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            addSubview(field)
        }

        zoomOutButton = AppKitActivityIconButton(
            symbol: "minus.magnifyingglass",
            label: "Zoom out",
            target: self,
            action: #selector(zoomOut))
        zoomInButton = AppKitActivityIconButton(
            symbol: "plus.magnifyingglass",
            label: "Zoom in",
            target: self,
            action: #selector(zoomIn))
        fitButton = AppKitActivityTextButton(
            title: "Fit",
            help: "Fit the whole turn in the panel",
            target: self,
            action: #selector(toggleFit))
        resetZoomButton = AppKitActivityTextButton(
            title: "1\u{00D7}",
            help: "Reset to the default time scale",
            target: self,
            action: #selector(resetZoom))
        addSubview(zoomOutButton)
        addSubview(zoomInButton)
        addSubview(fitButton)
        addSubview(resetZoomButton)
        criticalPathButton = AppKitActivityTextButton(
            title: "Path",
            help: "Mark the spans that determined how long this turn took",
            target: self,
            action: #selector(toggleCriticalPath))
        addSubview(criticalPathButton)

        laneFilterButton.onSelect = { [weak self] in self?.laneFilterChanged() }
        laneFilterButton.setAccessibilityLabel("Which agent lanes to show")
        addSubview(laneFilterButton)

        usageLanePopup.onSelect = { [weak self] in self?.usageLaneChanged() }
        usageLanePopup.setAccessibilityLabel("Usage agent filter")
        addSubview(usageLanePopup)

        trendMetricPopup.onSelect = { [weak self] in self?.trendMetricChanged() }
        trendMetricPopup.setAccessibilityLabel(String(localized: "Trend metric"))
        for metric in AppKitAgentActivityTrendMetric.allCases {
            trendMetricPopup.addItem(withTitle: metric.menuTitle)
        }
        trendMetricPopup.selectItem(at: 0)
        addSubview(trendMetricPopup)

        chartView.onSelectTrendTurnID = { [weak self] turnID in
            self?.selectTrendTurn(turnID)
        }

        scrollView.documentView = chartView
        // The lane gutter, the EVENTS and TOKENS labels and the ruler are drawn relative to
        // `visibleRect` so they stay pinned while the plot scrolls under them. `NSClipView`
        // bit-blits on scroll by default, which copies that pinned chrome along with the content
        // and then draws a second set at the new origin — the duplicated row labels. Redrawing the
        // exposed area in full is the price of pinned content. `copiesOnScroll = false` used to say
        // that explicitly; it has been a no-op since macOS 11, where NSClipView always minimizes the
        // invalidated area itself, so the app already relies on that behavior rather than the flag.
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.onUserScroll = { [weak self] in
            guard let self else { return }
            self.followingLive = self.isAtTrailingEdge
        }
        clipBoundsObservation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Pinned labels/legend are drawn relative to visibleRect, so scrolling must invalidate
            // the exposed viewport even when NSClipView would otherwise bit-blit its old pixels.
            self.chartView.invalidateFrozenChrome()
            self.chartView.invalidateHoverAfterScroll()
            if self.scrollView.isHandlingUserScroll, !self.programmaticScroll {
                self.followingLive = self.isAtTrailingEdge
            }
        }
        addSubview(scrollView)

        addSubview(legendView)

        emptyField.font = .systemFont(ofSize: 11)
        emptyField.textColor = .secondaryLabelColor
        emptyField.alignment = .center
        addSubview(emptyField)
        setAccessibilityElement(false)
        updateZoomControls()
    }

    @objc private func close() {
        onClose?()
    }

    @objc private func modeChanged() {
        let mode: AppKitAgentActivityVisualizationMode = switch modeControl.selectedSegment {
        case 0: .trace
        case 1: .usage
        default: .trends
        }
        applyVisualizationMode(mode, synchronizingControl: false)
    }

    func resetVisualizationModeToTrace() {
        hasExplicitTrendMetricSelection = false
        selectTrendMetric(.duration, explicitly: false)
        applyVisualizationMode(.trace, synchronizingControl: true)
    }

    func setVisualizationModeForTesting(_ mode: AppKitAgentActivityVisualizationMode) {
        applyVisualizationMode(mode, synchronizingControl: true)
    }

    func setTrendMetricForTesting(_ metric: AppKitAgentActivityTrendMetric) {
        selectTrendMetric(metric, explicitly: true)
        updateChartDocumentFrame()
    }

    var controlFramesForTesting: (mode: NSRect, metric: NSRect, chart: NSRect) {
        (modeControl.frame, trendMetricPopup.frame, scrollView.frame)
    }

    private func applyVisualizationMode(
        _ mode: AppKitAgentActivityVisualizationMode,
        synchronizingControl: Bool
    ) {
        if mode == .trends, chartView.mode != .trends, !hasExplicitTrendMetricSelection {
            selectTrendMetric(
                previousHarnessMetricSamples.isEmpty ? .duration : .runtime,
                explicitly: false)
        }
        if synchronizingControl {
            modeControl.selectedSegment = AppKitAgentActivityVisualizationMode.allCases
                .firstIndex(of: mode) ?? 0
        }
        chartView.mode = mode
        updateZoomControls()
        updateChartDocumentFrame()
        // The metrics row shares its trailing edge with whichever cluster the mode shows.
        needsLayout = true
    }

    @objc private func usageLaneChanged() {
        let index = usageLanePopup.indexOfSelectedItem
        let laneID = usageLaneIDs.indices.contains(index) ? usageLaneIDs[index] : nil
        chartView.usageLaneID = laneID
    }

    private func trendMetricChanged() {
        let index = trendMetricPopup.indexOfSelectedItem
        guard AppKitAgentActivityTrendMetric.allCases.indices.contains(index) else { return }
        selectTrendMetric(AppKitAgentActivityTrendMetric.allCases[index], explicitly: true)
        updateChartDocumentFrame()
        needsLayout = true
    }

    private func selectTrendMetric(
        _ metric: AppKitAgentActivityTrendMetric,
        explicitly: Bool
    ) {
        if explicitly {
            hasExplicitTrendMetricSelection = true
        }
        chartView.trendMetric = metric
        if let index = AppKitAgentActivityTrendMetric.allCases.firstIndex(of: metric) {
            trendMetricPopup.selectItem(at: index)
        }
    }

    private func selectTrendTurn(_ turnID: String) {
        guard summaries.contains(where: { $0.id == turnID }) else { return }
        selectedTurnID = turnID
        selectCurrentPopupItem()
        reloadFromBridge()
    }

    @objc private func zoomOut() {
        chartView.scaleExponent = max(-6, chartView.scaleExponent - 1)
        chartView.fitsWidth = false
        updateZoomControls()
        updateChartDocumentFrame()
    }

    @objc private func zoomIn() {
        chartView.scaleExponent = min(4, chartView.scaleExponent + 1)
        chartView.fitsWidth = false
        updateZoomControls()
        updateChartDocumentFrame()
    }

    @objc private func toggleCriticalPath() {
        chartView.showsCriticalPath.toggle()
        legendView.marksCriticalPath = chartView.showsCriticalPath
            && !chartView.renderModel.criticalSpanIDs.isEmpty
        updateZoomControls()
    }

    @objc private func resetZoom() {
        chartView.scaleExponent = 0
        chartView.fitsWidth = false
        updateZoomControls()
        updateChartDocumentFrame()
        needsLayout = true
    }

    private func laneFilterChanged() {
        chartView.laneFilter = laneFilterButton.indexOfSelectedItem == 1 ? .rootOnly : .all
        updateChartDocumentFrame()
        needsLayout = true
    }

    /// The filter's own title states what the turn contains, so the control doubles as a summary.
    private func rebuildLaneFilter() {
        let lanes = chartView.renderModel.lanes
        let delegated = lanes.filter {
            $0.id != AgentActivityIdentity.root && $0.id != appKitHarnessLaneID
        }
        let active = delegated.filter(\.isActive).count
        let selected = laneFilterButton.indexOfSelectedItem
        laneFilterButton.removeAllItems()
        laneFilterButton.addItem(
            withTitle: delegated.isEmpty
                ? "Root only"
                : "Root + \(delegated.count) · \(active) active · \(delegated.count - active) done")
        laneFilterButton.addItem(withTitle: "Root only")
        laneFilterButton.selectItem(at: selected == 1 ? 1 : 0)
        laneFilterButton.isHidden = delegated.isEmpty
    }

    @objc private func toggleFit() {
        chartView.fitsWidth.toggle()
        updateZoomControls()
        updateChartDocumentFrame()
    }

    @objc private func turnChanged() {
        if turnPopup.indexOfSelectedItem <= 0 {
            selectedTurnID = nil
        } else {
            let index = turnPopup.indexOfSelectedItem - 1
            selectedTurnID = summaries.indices.contains(index) ? summaries[index].id : nil
        }
        reloadFromBridge()
    }

    private func rebuildTurnPopupIfNeeded() {
        let runtimeOnly = summaries.isEmpty && !previousHarnessMetricSamples.isEmpty
        var signature = summaries.map {
            "\($0.id)|\($0.startedAt.timeIntervalSinceReferenceDate)|"
                + "\($0.providerAccess?.displayName ?? "")|\($0.modelID ?? "")"
        }
        if runtimeOnly { signature.append(appKitRuntimeOnlySummaryID) }
        guard signature != previousPopupSignature else {
            selectCurrentPopupItem()
            return
        }
        previousPopupSignature = signature
        turnPopup.removeAllItems()
        if runtimeOnly {
            turnPopup.addItem(withTitle: String(localized: "Session runtime"))
            turnPopup.selectItem(at: 0)
            return
        }
        turnPopup.addItem(withTitle: summaries.contains(where: { !$0.isTerminal })
            ? "Follow active turn"
            : "Follow latest turn")
        for summary in summaries {
            turnPopup.addItem(withTitle: turnTitle(summary))
        }
        selectCurrentPopupItem()
    }

    private func selectCurrentPopupItem() {
        if let selectedTurnID,
           let index = summaries.firstIndex(where: { $0.id == selectedTurnID }) {
            turnPopup.selectItem(at: index + 1)
        } else {
            turnPopup.selectItem(at: 0)
        }
    }

    private func turnTitle(_ summary: AgentActivityTurnSummary) -> String {
        let time = Self.turnTime.string(from: summary.startedAt)
        return [
            time,
            summary.providerAccess?.displayName ?? "Provider",
            summary.modelID.flatMap { $0.isEmpty ? nil : $0 },
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// Label and value carried the same size, weight and colour, so the noun and the number were
    /// indistinguishable. Small uppercase label, bold value, and a colour dot tying the metric back
    /// to the mark it describes in the plot.
    private func metricString(dot: NSColor, label: String, value: String) -> NSAttributedString {
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "\u{25CF} ", attributes: [
            .font: NSFont.systemFont(ofSize: 6),
            .foregroundColor: dot
        ]))
        text.append(NSAttributedString(string: label + "  ", attributes: [
            .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))
        text.append(NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]))
        return text
    }

    private func updateMetrics(_ summary: AgentActivityTurnSummary?) {
        guard let summary else {
            processedField.attributedStringValue = metricString(
                dot: .tertiaryLabelColor, label: "PROCESSED", value: "—")
            generatedField.attributedStringValue = metricString(
                dot: .tertiaryLabelColor, label: "GENERATED", value: "—")
            contextField.attributedStringValue = metricString(
                dot: .tertiaryLabelColor, label: "CURRENT CONTEXT", value: "—")
            cachedField.isHidden = true
            cachedField.toolTip = nil
            contextMeter.fraction = 0
            return
        }
        let generated = summary.outputTokens + summary.reasoningOutputTokens
        let processed = summary.inputTokens + generated + summary.aggregateOnlyTokens
        let records = bridgeActivity.filter { $0.turnID == summary.id }
        let tokenAnatomy = appKitActivityTokenAnatomy(
            records: records,
            breakdown: summary.tokenBreakdown)
        let context = records.last { $0.kind == .context }

        processedField.attributedStringValue = metricString(
            dot: phaseColorForMetrics(.model),
            label: "PROCESSED",
            value: processed > 0 ? formatTokens(processed) : "—")

        // Cache hit rate is the most actionable cost number the summary carries, and it was
        // computed and then discarded: a turn that reprocesses its whole context every step costs
        // an order of magnitude more than one that does not.
        let cached = tokenAnatomy.cacheRead
        if summary.inputTokens > 0, let cached {
            let share = Int((Double(cached) / Double(summary.inputTokens) * 100).rounded())
            cachedField.attributedStringValue = metricString(
                dot: phaseColorForMetrics(.model).withAlphaComponent(0.55),
                label: "FROM CACHE",
                value: "\(share)%")
            cachedField.toolTip = nil
            cachedField.isHidden = false
        } else if summary.inputTokens > 0 {
            cachedField.attributedStringValue = metricString(
                dot: .tertiaryLabelColor,
                label: String(localized: "CACHE"),
                value: "—")
            cachedField.toolTip = String(localized: "Cache breakdown not reported by this provider")
            cachedField.isHidden = false
        } else {
            cachedField.toolTip = nil
            cachedField.isHidden = true
        }

        generatedField.attributedStringValue = metricString(
            dot: phaseColorForMetrics(.completed),
            label: "GENERATED",
            value: generated > 0 ? formatTokens(generated) : "—")

        if let tokens = context?.contextTokens {
            let window = context?.contextWindow
            contextField.attributedStringValue = metricString(
                dot: phaseColorForMetrics(.compacting),
                label: "CURRENT CONTEXT",
                value: window.map { "\(formatTokens(tokens))/\(formatTokens($0))" }
                    ?? formatTokens(tokens))
            // A ratio stated as text has to be arithmetic-ed by the reader; the meter makes "how
            // close am I to compaction" a glance instead of a calculation.
            contextMeter.fraction = window.map {
                $0 > 0 ? min(1, Double(tokens) / Double($0)) : 0
            } ?? 0
        } else {
            contextField.attributedStringValue = metricString(
                dot: .tertiaryLabelColor, label: "CURRENT CONTEXT", value: "—")
            contextMeter.fraction = 0
        }
    }

    private func phaseColorForMetrics(_ phase: AgentActivityPhase) -> NSColor {
        appKitAgentActivityPhaseColor(phase)
    }

    private func updateChartDocumentFrame() {
        let size = scrollView.contentSize
        let width = chartView.preferredWidth(viewportWidth: max(1, size.width))
        let frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: max(size.height, chartView.requiredHeight(forWidth: width)))
        // Assigning a frame invalidates the whole view. At one hertz on a growing live timeline
        // that repainted every lane, every second, which is what read as jitter. Only take the hit
        // when the geometry actually moved by a visible amount.
        if abs(chartView.frame.width - frame.width) > 0.5
            || abs(chartView.frame.height - frame.height) > 0.5 {
            chartView.frame = frame
        }
        let wantsScroller = chartView.mode == .trace && !chartView.fitsWidth
        if scrollView.hasHorizontalScroller != wantsScroller {
            scrollView.hasHorizontalScroller = wantsScroller
        }
    }

    /// Following means "now" is visible, not that the scroller is pinned to the document's end.
    /// Under the runway policy the two are different, and testing for the end turned following off
    /// the moment the plot was allowed to hold still.
    private var isAtTrailingEdge: Bool {
        let viewport = scrollView.contentSize.width
        guard viewport > 0 else { return true }
        let currentX = scrollView.contentView.bounds.minX
        let liveX = chartView.liveEdgeX
        return liveX >= currentX + chartView.viewportGutterWidth - 4
            && liveX <= currentX + viewport + 4
    }

    /// The one live-follow policy. Every caller uses this; two callers with different targets made
    /// the plot oscillate between them on every tick.
    ///
    /// The plot stays exactly where it is while "now" advances across the viewport. Only when the
    /// live edge reaches the right margin does it reposition, putting the edge halfway across the
    /// visible plot beside the frozen gutter — so the content is still for several seconds at a
    /// time instead of shifting every second or disappearing underneath the lane labels.
    private func followLiveEdge() {
        let viewport = scrollView.contentSize.width
        guard viewport > 0, chartView.frame.width > viewport else { return }
        let currentX = scrollView.contentView.bounds.minX
        let liveX = chartView.liveEdgeX
        let gutter = chartView.viewportGutterWidth
        let visiblePlotWidth = max(0, viewport - gutter)
        // On a narrow inspector, a fixed 28-point margin can consume most of the visible plot and
        // force a reposition every tick. Scale it down while retaining a small arrival threshold.
        let rightMargin = min(CGFloat(28), max(8, visiblePlotWidth * 0.1))
        guard liveX < currentX + gutter
                || liveX > currentX + viewport - rightMargin else { return }
        let target = appKitAgentActivityLiveFollowTarget(
            liveEdgeX: liveX,
            documentWidth: chartView.frame.width,
            viewportWidth: viewport,
            gutterWidth: gutter)
        scrollTo(x: target)
    }

    private func scrollToTrailingEdge() {
        guard chartView.frame.width > scrollView.contentSize.width else { return }
        let x = max(0, chartView.frame.width - scrollView.contentSize.width)
        scrollTo(x: x)
    }

    private func scrollTo(x: CGFloat) {
        // Re-scrolling to a position we are already at still forces a clip-view redraw.
        guard abs(scrollView.contentView.bounds.minX - x) > 0.5 else { return }
        programmaticScroll = true
        scrollView.contentView.scroll(to: NSPoint(
            x: x,
            y: scrollView.contentView.bounds.minY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        programmaticScroll = false
        chartView.invalidateFrozenChrome()
    }

    private func updateZoomControls() {
        let trace = chartView.mode == .trace
        // Visibility is decided by `layout()`, which also knows whether each control fits; this
        // only sets enablement and the state each control reports.
        zoomOutButton.isEnabled = trace && (chartView.fitsWidth || chartView.scaleExponent > -6)
        zoomInButton.isEnabled = trace && (chartView.fitsWidth || chartView.scaleExponent < 4)
        fitButton.isEnabled = trace
        fitButton.isActive = chartView.fitsWidth
        fitButton.toolTip = chartView.fitsWidth
            ? "Use a fixed time scale"
            : "Fit the whole turn in the panel"
        fitButton.setAccessibilityLabel(fitButton.toolTip)
        resetZoomButton.isEnabled = trace && (chartView.fitsWidth || chartView.scaleExponent != 0)
        resetZoomButton.isActive = !chartView.fitsWidth && chartView.scaleExponent == 0
        criticalPathButton.isEnabled = trace
        criticalPathButton.isActive = chartView.showsCriticalPath
        criticalPathButton.toolTip = chartView.showsCriticalPath
            ? "Stop marking the critical path"
            : "Mark the spans that determined how long this turn took"
        criticalPathButton.setAccessibilityLabel(criticalPathButton.toolTip)
        rebuildLaneFilter()
    }

    private func rebuildUsageLanePopup() {
        let previous = chartView.usageLaneID
        let usageLanes = chartView.renderModel.lanes.filter { $0.id != appKitHarnessLaneID }
        usageLaneIDs = [nil] + usageLanes.map(\.id)
        usageLanePopup.removeAllItems()
        usageLanePopup.addItem(withTitle: "All agents")
        for lane in usageLanes {
            usageLanePopup.addItem(withTitle: lane.label)
        }
        if let previous,
           let index = usageLaneIDs.firstIndex(where: { $0 == previous }) {
            usageLanePopup.selectItem(at: index)
        } else {
            usageLanePopup.selectItem(at: 0)
            chartView.usageLaneID = nil
        }
    }

    private func laneAliases() -> [String: String] {
        agentActivityAliases(
            subagents: bridge.subagents,
            workflowRuns: bridge.workflowRuns)
    }

    /// The unabridged task text per lane, keyed the same way as the labels.
    private func laneDetails() -> [String: String] {
        var details: [String: String] = [:]
        for subagent in bridge.subagents.values {
            guard let task = activitySingleLine(subagent.task), !task.isEmpty else { continue }
            details[AgentActivityIdentity.subagent(subagent.key)] = task
        }
        for run in bridge.workflowRunsSorted {
            for agent in run.agents.values {
                let id = AgentActivityIdentity.workflow(runKey: run.runKey, agentKey: agent.id)
                if let prompt = agent.promptPreview.flatMap(activitySingleLine), !prompt.isEmpty {
                    details[id] = prompt
                } else if !agent.label.isEmpty {
                    details[id] = agent.label
                }
            }
        }
        return details
    }

    private func laneLabels() -> [String: String] {
        var labels = [AgentActivityIdentity.root: "Root agent"]
        let ordinals = agentActivitySubagentOrdinals(bridge.subagents)
        for subagent in bridge.subagents.values {
            let prefix = ordinals[subagent.key].map { "A\($0) · " } ?? ""
            let type = subagent.subagentType.isEmpty ? "Agent" : subagent.subagentType
            let task = activitySingleLine(subagent.task)
            labels[AgentActivityIdentity.subagent(subagent.key)] =
                prefix + (task.map { traceLaneTaskSummary($0) } ?? type)
        }
        for (runOffset, run) in bridge.workflowRunsSorted.enumerated() {
            let agents = run.agents.values.sorted {
                if $0.phaseIndex != $1.phaseIndex { return $0.phaseIndex < $1.phaseIndex }
                return $0.index < $1.index
            }
            for agent in agents {
                let id = AgentActivityIdentity.workflow(runKey: run.runKey, agentKey: agent.id)
                guard labels[id] == nil else { continue }
                labels[id] = "W\(runOffset + 1).\(agent.index) · "
                    + (agent.label.isEmpty ? "Agent \(agent.index)" : agent.label)
            }
        }
        return labels
    }

    private static let turnTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()
}

// MARK: - One-pass native chart

/// Trace geometry in one place. The lane is a track with two rails: a primary model rail on the
/// lane's centre line and a thinner tool sub-rail beneath it, so a tool call reads as work done
/// inside the model's span rather than as a separate mark floating below it.
/// Geometry ported verbatim from the SwiftUI trace this panel replaced, so the native chart is the
/// same visualization rather than a new one. A lane is 58 points tall and carries two tracks: the
/// model track centred at y=17 and the tool/wait/compaction track centred at y=41. Tool calls are
/// bars on their own track with real duration — the thing a point marker cannot express.
private enum TraceLayout {
    static let eventRailHeight: CGFloat = 34
    static let laneHeight: CGFloat = 58
    static let rulerHeight: CGFloat = 20
    /// A counter track under the lanes, on the same time axis. Cost is a primary question and it
    /// had no mark anywhere in the plot — only a number in the header, which cannot answer "when".
    static let costTrackHeight: CGFloat = 40
    static let barHeight: CGFloat = 15
    static let barRadius: CGFloat = 3
    static let minimumSpanWidth: CGFloat = 3

    static let laneNameFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
    static let laneChildFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    static let laneMetaFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)
    static let laneDetailFont = NSFont.systemFont(ofSize: 8, weight: .regular)
    // Span titles sit directly on saturated rays, often at the edge of the user's peripheral
    // vision while a turn is moving. Eight-point medium text technically cleared contrast but
    // looked hairline once its dark edge and AppKit antialiasing shared the same tiny glyph. Give
    // the white interior enough area to read as ink rather than a grey fringe.
    static let spanLabelFont = appKitAgentActivitySpanLabelFont()
    static let rulerFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)
    static let railTitleFont = NSFont.systemFont(ofSize: 8, weight: .bold)

    /// Which of the lane's two tracks a phase belongs on.
    static func trackY(_ phase: AgentActivityPhase) -> CGFloat {
        phase == .model ? 17 : 41
    }

    static func laneCenter(_ rowY: CGFloat) -> CGFloat { rowY + 29 }
}

/// Edge labels live wholly inside the plot. Centering the first and last boxes on their ticks
/// placed half of each box beyond the document, so AppKit correctly clipped the right-hand time.
func appKitTimelineTickLabelRect(
    tickX: CGFloat,
    top: CGFloat,
    width: CGFloat,
    index: Int,
    count: Int
) -> NSRect {
    let x: CGFloat
    if index == 0 {
        x = tickX
    } else if index == count {
        x = tickX - width
    } else {
        x = tickX - width / 2
    }
    return NSRect(x: x, y: top, width: width, height: 12)
}

/// A right-aligned final tick may have an intentionally wide alignment box extending beneath the
/// frozen gutter even though every glyph is in the visible plot. Judge the text itself; rejecting
/// the whole box made the current time disappear at narrow inspector widths.
func appKitTimelineTickLabelFitsPastFrozenGutter(
    box: NSRect,
    measuredTextWidth: CGFloat,
    alignment: NSTextAlignment,
    gutterEdge: CGFloat
) -> Bool {
    let width = max(0, min(box.width, measuredTextWidth))
    let textMinX: CGFloat
    switch alignment {
    case .right:
        textMinX = box.maxX - width
    case .center:
        textMinX = box.midX - width / 2
    default:
        textMinX = box.minX
    }
    return textMinX >= gutterEdge
}

/// Put a followed live edge in the middle of the plot the user can actually see, excluding the
/// frozen lane gutter. Centering it in the complete viewport can put "now" underneath that gutter
/// at compact widths even though the horizontal scroll position is otherwise valid.
func appKitAgentActivityLiveFollowTarget(
    liveEdgeX: CGFloat,
    documentWidth: CGFloat,
    viewportWidth: CGFloat,
    gutterWidth: CGFloat
) -> CGFloat {
    let viewport = max(0, viewportWidth)
    guard viewport > 0 else { return 0 }
    let gutter = min(viewport, max(0, gutterWidth))
    let visiblePlotWidth = viewport - gutter
    let desiredLiveOffset = gutter + visiblePlotWidth / 2
    let maximumOrigin = max(0, documentWidth - viewport)
    return min(maximumOrigin, max(0, liveEdgeX - desiredLiveOffset))
}

/// Usage answers "what new work happened in each interval." Cached input is a subset of input that
/// was reused rather than newly processed; drawing it as a full-height backing bar made the plot a
/// yellow cache chart and obscured the two quantities this mode names. Cache remains available in
/// the headline, Trace, and hover inspection.
struct AppKitUsagePlottedTokens: Equatable {
    let input: Int
    let generated: Int

    var total: Int { input + generated }
}

func appKitUsagePlottedTokens(
    _ tokens: AgentActivityTokenBreakdown
) -> AppKitUsagePlottedTokens {
    AppKitUsagePlottedTokens(
        input: tokens.uncachedInput + tokens.unclassified,
        generated: tokens.generated)
}

/// The trace legend, a footer strip under the chart exactly as the SwiftUI panel had it — out of
/// the way of the plot, naming every mark the chart can draw.
///
/// Activity is product data, not system chrome. Keep its categories on the same six appearance-
/// tuned rays as the agent-card meters so Graphite or an orange accent cannot collapse the chart
/// into grey or make model and tool work indistinguishable.
/// One instance, not one per call. A dynamic `NSColor` built inline is a NEW object every time, so
/// the legend's swatch and the span's fill compared unequal even though they draw identically.
private let waitingSlate = NSColor(name: nil) { appearance in
    appearance.mechanicianIsDark
        ? NSColor(srgbRed: 0.29, green: 0.31, blue: 0.35, alpha: 1)
        : NSColor(srgbRed: 0.36, green: 0.39, blue: 0.44, alpha: 1)
}

func appKitAgentActivityPhaseColor(_ phase: AgentActivityPhase) -> NSColor {
    let rays = MagicLaserSpectrum.meterColors
    switch phase {
    case .model: return rays[5]       // blue
    case .tool: return rays[2]        // orange
    // NOT `secondaryLabelColor`. That is a TEXT colour pressed into service as a fill, and it
    // resolves to a light grey in Dark mode — so a white span label sat on pale grey and had to be
    // rescued by an outline around every letter, which is what David reported as hard to read. A
    // slate that white reads on in both appearances removes the reason the outline existed.
    case .waiting: return waitingSlate
    case .compacting: return rays[4]  // purple
    case .completed: return rays[0]   // green
    case .failed: return rays[3]      // red
    case .stopped: return rays[1]     // gold
    }
}

/// Context pressure is data, not interactive chrome. Using `controlAccentColor` made this graph
/// beige or gold on Macs whose Accent Color was not blue, even though it sits directly beneath the
/// blue new-input series. Keep it on the same appearance-tuned blue ray as model/input activity.
func appKitAgentActivityContextColor() -> NSColor {
    appKitAgentActivityPhaseColor(.model)
}

/// Cached input is context the provider reused, not a third kind of work. In Trace's lower token
/// track it still needs to remain inspectable, but an opaque gold segment turned cache-heavy turns
/// into the same beige wall removed from Usage. A translucent version of the input blue preserves
/// the distinction without making cache the chart's dominant color.
func appKitAgentActivityCachedInputColor(in appearance: NSAppearance) -> NSColor {
    appKitAgentActivityPhaseColor(.model).withAlphaComponent(
        appearance.mechanicianIsDark ? 0.34 : 0.24)
}

/// Activity-span labels use white ink. In Light Mode the saturated model and tool rays must
/// therefore remain opaque: even a small amount of the pale lane composited underneath makes the
/// label look washed out. Other phases retain the translucency that separates overlapping rails
/// from solid status marks.
func appKitAgentActivitySpanFillAlpha(
    _ phase: AgentActivityPhase,
    appearance: NSAppearance
) -> CGFloat {
    if phase == .compacting {
        // Raised from 0.30/0.22. At those the purple was barely there and a white label floated on
        // the card behind it, which is the other half of why glyphs were being outlined. Still the
        // quietest fill of the set, now solid enough to carry its own text.
        return appearance.mechanicianIsDark ? 0.62 : 0.70
    }
    if phase == .model || phase == .tool, !appearance.mechanicianIsDark {
        return 1
    }
    return appearance.mechanicianIsDark ? 0.82 : 0.94
}

/// The fill a span is drawn on, which is not always the phase's palette color.
///
/// A tool span carries its own tool's ray rather than one shared orange, so the chart says WHICH
/// tool ran — the thing a single phase colour discarded. Label ink is then chosen per span, because
/// the six rays do not share one legible ink.
///
/// An earlier attempt kept the single tool colour and deepened it far enough to carry white text.
/// It did clear contrast, but the result read as brown: neither the logo colour nor recognisably
/// orange. Identity, not saturation, was the thing worth fixing.
func appKitAgentActivitySpanFillColor(
    _ phase: AgentActivityPhase,
    tool: String? = nil
) -> NSColor {
    guard phase == .tool else { return appKitAgentActivityPhaseColor(phase) }
    // A named tool wears its own ray, the same one the agent card's composition bar gives it.
    if let tool, !tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return appKitToolColor(forTool: tool)
    }
    // Unnamed tool work keeps the phase ray. It is deliberately not the deepened orange that
    // replaced it for a while: darkening the ray far enough to carry white text turned it brown,
    // which is neither the logo colour nor recognisably orange.
    return appKitAgentActivityPhaseColor(.tool)
}

/// The swatch the trace key draws for a mark, which is not always one colour.
///
/// Every other mark has exactly one, so its swatch is that colour. `tool` no longer does: a span
/// wears the ray hashed from its tool's name, the same one the agent card's tool mix gives it. A
/// single orange chip therefore stated a rule the chart had stopped following. The swatch is the
/// whole palette a tool can draw from — a miniature of that composition bar — so the key says
/// "colour identifies the tool" rather than naming one colour out of six.
///
/// It is derived from the tool colouring itself rather than restated, so the key cannot drift out
/// of agreement with the chart when the palette changes.
func appKitTraceLegendSwatchColors(_ phase: AgentActivityPhase) -> [NSColor] {
    guard phase == .tool else { return [appKitAgentActivityPhaseColor(phase)] }
    return AppKitToolCompositionBar.palette
}

/// Text inside activity spans uses one consistent ink across every phase, tool ray, and appearance.
/// The fill continues to identify the kind of work; changing glyph polarity from span to span made
/// one timeline look visually unrelated even when adjacent bars represented the same turn.
///
/// Some bright rays score better against black in a standalone contrast calculation, while the
/// translucent waiting and compacting fills can be too quiet for unassisted white. The uniform
/// white treatment is intentional.
///
/// **PLAIN WHITE, WITH NOTHING BEHIND IT.** There used to be a dark outline here, added so the
/// glyphs would separate from every possible ray colour. On screen it reads as a black fringe
/// around each letter and makes small text harder to read, not easier — which is the opposite of
/// what a contrast aid is for. David has asked for plain white text repeatedly; the answer to a
/// fill too quiet for white is a better fill, not an outline on the letters.
func appKitAgentActivitySpanLabelColor(
    _ phase: AgentActivityPhase,
    tool: String? = nil,
    background: NSColor,
    appearance: NSAppearance
) -> NSColor {
    .white
}

/// Span labels are deliberately a step stronger than the surrounding lane metadata. They are
/// painted on moving colour rather than on a quiet card surface, so regular/medium 8-point glyphs
/// lose their white core to antialiasing. Weight is what carries them now that nothing is drawn
/// behind them.
func appKitAgentActivitySpanLabelFont() -> NSFont {
    NSFont.systemFont(ofSize: 9, weight: .semibold)
}

/// No outline. Kept as a named zero rather than deleted so the two draw sites keep one answer to
/// "what is drawn behind a span label", and so a future contrast idea has an obvious place to be
/// argued about rather than sprinkled at a call site.
func appKitAgentActivitySpanLabelOutlineColor() -> NSColor { .clear }

func appKitAgentActivitySpanLabelStrokeWidth() -> CGFloat { 0 }

/// A capsule meter for context-window pressure. Colour steps at the thresholds where the number
/// starts to mean something: comfortable, getting tight, about to compact.
final class AppKitContextMeter: NSView {
    var fraction: Double = 0 {
        didSet { if fraction != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The empty remainder of the capsule.
    ///
    /// This was `quaternaryLabelColor.withAlphaComponent(0.5)`, which reads as subtle but is not:
    /// `withAlphaComponent` REPLACES a colour's alpha rather than scaling it, so a semantic grey
    /// whose subtlety lives entirely in its own low alpha became a flat 50% black — a mid grey
    /// measuring 1.25:1 against the blue fill in Light mode, which is what made a quarter-full
    /// meter unreadable. A recessed well instead: pale on light surfaces, dark on dark ones, so the
    /// fill is the bright part in both.
    private var trackColor: NSColor {
        effectiveAppearance.mechanicianIsDark
            ? NSColor(white: 0, alpha: 0.55)
            : NSColor(white: 0, alpha: 0.09)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        trackColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard fraction > 0 else { return }
        let width = max(bounds.height, bounds.width * CGFloat(min(1, fraction)))
        let color: NSColor = fraction > 0.9
            ? appKitAgentActivityPhaseColor(.failed)
            : fraction > 0.75
                ? appKitAgentActivityPhaseColor(.tool)
                : appKitAgentActivityPhaseColor(.model)
        color.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
            xRadius: radius,
            yRadius: radius).fill()
    }
}

/// The trace key: a footer strip naming every mark the chart can draw.
///
/// Internal rather than private so a render test can draw it offscreen. The marks are painted, not
/// composed from labelled subviews, so only pixels can show whether they say what they mean.
final class AppKitTraceLegendView: NSView {
    var totalText: String = "" {
        didSet { if totalText != oldValue { needsDisplay = true } }
    }

    /// Whether the chart is currently marking the chain that determined the turn's length.
    var marksCriticalPath = false {
        didSet {
            guard marksCriticalPath != oldValue else { return }
            updateAccessibilityLabel()
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    /// The one rule a reader cannot recover from looking at a swatch: the tool mark is a spectrum
    /// because the colour names the tool, not the category.
    private static let toolColorNote =
        "Each tool has its own colour, the same one it has in the agent card's tool mix."

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        // The key is drawn text. Without this VoiceOver reaches a strip that reports nothing at all.
        updateAccessibilityLabel()
        setAccessibilityHelp(Self.toolColorNote)
        toolTip = Self.toolColorNote
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateAccessibilityLabel() {
        var marks = Self.entries.compactMap { $0.1 == nil ? nil : $0.0 }
        marks.append(contentsOf: ["user", "grouped"])
        if marksCriticalPath { marks.append("critical path") }
        setAccessibilityLabel("Trace key: " + marks.joined(separator: ", "))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private static let entries: [(String, AgentActivityPhase?)] = [
        ("model", .model),
        ("tool", .tool),
        ("wait", .waiting),
        ("compaction", .compacting),
        ("ended", .completed),
    ]

    /// Draw one mark's swatch and return the x to continue from.
    ///
    /// A multi-colour swatch is banded inside the same capsule a single-colour one uses, so the row
    /// keeps its rhythm; it is only wide enough that each band survives at this size.
    private func drawSwatch(_ phase: AgentActivityPhase, at x: CGFloat, midY: CGFloat) -> CGFloat {
        let colors = appKitTraceLegendSwatchColors(phase)
        if phase == .completed {
            colors[0].withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: midY - 2.5, width: 5, height: 5)).fill()
            return x + 8
        }
        let width: CGFloat = colors.count > 1 ? 15 : 9
        let capsule = NSBezierPath(
            roundedRect: NSRect(x: x, y: midY - 1.5, width: width, height: 3),
            xRadius: 1.5,
            yRadius: 1.5)
        guard colors.count > 1 else {
            colors[0].withAlphaComponent(0.85).setFill()
            capsule.fill()
            return x + width + 3
        }
        NSGraphicsContext.saveGraphicsState()
        capsule.addClip()
        let band = width / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            color.withAlphaComponent(0.85).setFill()
            // Overdraw by a band edge so no seam of background shows between two bands.
            NSRect(
                x: x + CGFloat(index) * band,
                y: midY - 1.5,
                width: band + 0.5,
                height: 3).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return x + width + 3
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 8, weight: .regular)
        let titleFont = NSFont.systemFont(ofSize: 8, weight: .bold)
        var x: CGFloat = 10
        let midY = bounds.midY

        ("TRACE" as NSString).draw(
            at: NSPoint(x: x, y: midY - 5),
            withAttributes: [.font: titleFont, .foregroundColor: NSColor.nChartMuted])
        x += 38

        for (title, phase) in Self.entries {
            guard let phase else { continue }
            x = drawSwatch(phase, at: x, midY: midY)
            let text = title as NSString
            text.draw(
                at: NSPoint(x: x, y: midY - 5),
                withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            x += ceil(text.size(withAttributes: [.font: font]).width) + 12
        }

        // The two non-phase marks the chart also draws.
        MagicLaserSpectrum.meterColors[1].withAlphaComponent(0.90).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: x, y: midY - 4, width: 8, height: 8),
            xRadius: 4,
            yRadius: 4).fill()
        x += 11
        ("user" as NSString).draw(
            at: NSPoint(x: x, y: midY - 5),
            withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        x += ceil(("user" as NSString).size(withAttributes: [.font: font]).width) + 12

        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setFill()
        for offset in stride(from: CGFloat(0), to: 9, by: 3) {
            NSRect(x: x + offset, y: midY - 1.5, width: 1.5, height: 3).fill()
        }
        x += 12
        ("grouped" as NSString).draw(
            at: NSPoint(x: x, y: midY - 5),
            withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        x += ceil(("grouped" as NSString).size(withAttributes: [.font: font]).width) + 12

        if marksCriticalPath {
            NSColor.controlAccentColor.withAlphaComponent(0.95).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: x, y: midY - 1.5, width: 10, height: 3),
                xRadius: 1.5,
                yRadius: 1.5).fill()
            x += 13
            ("critical path" as NSString).draw(
                at: NSPoint(x: x, y: midY - 5),
                withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        }

        var rightEdge = bounds.maxX - 10
        let totalFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)

        // Which build this pixel came from. Only dev bundles carry the stamp, and it is here rather
        // than in the titlebar because a cropped screenshot of this panel is the artifact that gets
        // reasoned about — twice this panel was judged from a stale binary that looked identical.
        if let stamp = MechanicianBuildStamp.current {
            let text = stamp as NSString
            let width = ceil(text.size(withAttributes: [.font: totalFont]).width)
            text.draw(
                at: NSPoint(x: rightEdge - width, y: midY - 5),
                withAttributes: [.font: totalFont, .foregroundColor: NSColor.nChartMuted])
            rightEdge -= width + 10
        }

        guard !totalText.isEmpty else { return }
        let total = totalText as NSString
        let width = ceil(total.size(withAttributes: [.font: totalFont]).width)
        total.draw(
            at: NSPoint(x: rightEdge - width, y: midY - 5),
            withAttributes: [.font: totalFont, .foregroundColor: NSColor.nChartMuted])
    }
}

/// The git SHA and build time baked into a dev bundle by `dev.sh`.
///
/// Release bundles have no such key, so this is nil and nothing draws. `+dirty` means the working
/// tree had uncommitted changes when the bundle was built — which is the common case mid-session and
/// exactly when knowing the build's provenance matters most.
enum MechanicianBuildStamp {
    static let current: String? = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "MechanicianBuildStamp") as? String
        else { return nil }
        let stamp = raw.trimmingCharacters(in: .whitespaces)
        return stamp.isEmpty ? nil : stamp
    }()
}

/// Internal rather than private so the offscreen render harness in the tests can drive it: Light
/// Mode, the EVENTS rail and draw cost are all properties of what this view paints, and none of
/// them can be checked through the render model alone.
final class AppKitAgentActivityChartView: NSView, NSViewToolTipOwner {
    /// This view draws pinned chrome — the lane gutter, the EVENTS and TOKENS labels, the ruler —
    /// at positions derived from `visibleRect`. Responsive scrolling caches overdraw tiles and
    /// reuses them, so that chrome was blitted to a new position and then drawn again at the
    /// correct one: two sets of row labels, with stale content in the tiles that were not redrawn.
    /// Content that depends on the scroll offset cannot use cached tiles.
    override class var isCompatibleWithResponsiveScrolling: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        inspectionOverlay.needsDisplay = true
    }

    let renderModel = AppKitAgentActivityRenderModel()
    private let inspectionOverlay = AppKitAgentActivityInspectionOverlay()
    var scaleExponent = 0 {
        didSet {
            guard scaleExponent != oldValue else { return }
            rebuildDisplaySpans()
            needsDisplay = true
        }
    }
    var fitsWidth = false {
        didSet {
            guard fitsWidth != oldValue else { return }
            rebuildDisplaySpans()
            needsDisplay = true
        }
    }
    var hasPinnedInspection: Bool { pinnedPoint != nil }
    var usageLaneID: String? {
        get { renderModel.usageAgentID }
        set {
            if renderModel.setUsageAgentID(newValue) {
                needsDisplay = true
                updateAccessibilitySummary()
            }
        }
    }
    var mode: AppKitAgentActivityVisualizationMode = .trace {
        didSet {
            guard mode != oldValue else { return }
            hoverPoint = nil
            pinnedPoint = nil
            pinnedRuntimeMetricIndex = nil
            invalidateIntrinsicContentSize()
            rebuildDisplaySpans()
            needsDisplay = true
            superview?.needsLayout = true
        }
    }
    var trendMetric: AppKitAgentActivityTrendMetric = .duration {
        didSet {
            guard trendMetric != oldValue else { return }
            hoverPoint = nil
            pinnedPoint = nil
            pinnedRuntimeMetricIndex = nil
            focusedTrendIndex = selectedTrendIndex
            focusedRuntimeMetricIndex = 0
            invalidateIntrinsicContentSize()
            needsDisplay = true
            superview?.needsLayout = true
            updateAccessibilitySummary()
        }
    }
    var onSelectTrendTurnID: ((String) -> Void)?

    fileprivate var hoverPoint: NSPoint?
    fileprivate var pinnedPoint: NSPoint?
    private var pinnedRuntimeMetricIndex: Int?
    private var displaySpansByLaneID: [String: [AppKitAgentActivityTraceSpan]] = [:]
    private(set) var focusedTrendIndex = 0
    private(set) var focusedRuntimeMetricIndex = 0
    private var lastDisplayWidth: CGFloat = 0
    private var lastRuntimeAccessibilityWidth: CGFloat = -1
    private(set) var toolTipTextByTag: [NSView.ToolTipTag: String] = [:]
    private var accessibilityChildrenDirty = true
    private(set) var accessibilityTreeRebuildCount = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Total elapsed for the selected turn, shown at the right of the legend footer.
    var totalDurationText: String {
        duration > 0 ? durationLabel(duration) : ""
    }

    var requiredHeight: CGFloat {
        requiredHeight(forWidth: bounds.width)
    }

    func requiredHeight(forWidth width: CGFloat) -> CGFloat {
        switch mode {
        case .trace:
            return TraceLayout.eventRailHeight
                + CGFloat(visibleLanes.count) * TraceLayout.laneHeight
                + TraceLayout.costTrackHeight
                + TraceLayout.rulerHeight
        case .usage:
            return 170
        case .trends:
            return trendMetric == .runtime
                ? runtimeMetricRequiredHeight(documentWidth: width)
                : 230
        }
    }

    /// Points per second at the current zoom.
    var pointsPerSecond: CGFloat {
        traceBasePointsPerSecond * pow(2, CGFloat(scaleExponent))
    }

    /// Physical width of the selected turn at a fixed trace scale.
    private var fixedScaleTimeAxisWidth: CGFloat {
        max(1, CGFloat(duration) * pointsPerSecond)
    }

    /// Where "now" sits in document coordinates.
    ///
    /// Keep this derived from the rectangle that actually draws time. The live-follow policy used
    /// to calculate the edge independently while `x(for:)` stretched the same duration across the
    /// document's reserved runway. Follow therefore stopped 150 points before the pixels that meant
    /// now, leaving the live edge visibly clipped off the right side of a narrow inspector.
    var liveEdgeX: CGFloat {
        plotRect.maxX
    }

    /// Empty runway reserved ahead of the live edge while a turn is still running.
    ///
    /// Without it the document ends exactly at "now", so there is nowhere for the edge to advance
    /// into: any attempt to hold the plot still clamps straight back to the trailing edge and the
    /// view scrolls every single second. Reserving space ahead is what lets the plot stay put.
    static let liveRunway: CGFloat = 160

    func preferredWidth(viewportWidth: CGFloat) -> CGFloat {
        guard mode == .trace, !fitsWidth else { return max(1, viewportWidth) }
        let runway = renderModel.isLive ? Self.liveRunway : 10
        return max(
            viewportWidth,
            labelWidth + fixedScaleTimeAxisWidth + runway)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Agent activity visualization")
        setAccessibilityHelp(
            "Move the pointer across the chart to inspect time and agent state. Click to pin the inspection.")
        inspectionOverlay.owner = self
        addSubview(inspectionOverlay)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func rebuild(input: AppKitAgentActivityRenderInput, now: Date) -> Bool {
        let rebuilt = renderModel.rebuild(input, now: now)
        guard rebuilt else { return false }
        focusedTrendIndex = selectedTrendIndex
        rebuildDisplaySpans()
        invalidateIntrinsicContentSize()
        needsDisplay = true
        superview?.needsLayout = true
        return true
    }

    private var selectedTrendIndex: Int {
        guard let turns = renderModel.input?.trendTurns, !turns.isEmpty else { return 0 }
        if let selected = renderModel.input?.selectedTrendTurnID,
           let index = turns.firstIndex(where: { $0.id == selected }) {
            return index
        }
        return turns.count - 1
    }

    func tick(now: Date) {
        switch appKitAgentActivityTickInvalidationPlan(delta: renderModel.tick(now: now)) {
        case .none:
            break
        case .full:
            updateOpenDisplayTails()
            needsDisplay = true
        }
    }

    /// Whether the critical chain is marked. Additive by design: it underlines the spans that
    /// determined the total rather than dimming everything else, so the chart reads the same as it
    /// always did with one more layer on top.
    var showsCriticalPath = UserDefaults.standard.object(forKey: "agentsTraceCriticalPath") as? Bool ?? true {
        didSet {
            guard showsCriticalPath != oldValue else { return }
            UserDefaults.standard.set(showsCriticalPath, forKey: "agentsTraceCriticalPath")
            needsDisplay = true
        }
    }

    /// Which lanes the trace shows. A turn with a dozen delegated agents is unreadable at once;
    /// the shipped panel offers a root-only view and this restores it.
    enum LaneFilter {
        case all
        case rootOnly
    }

    var laneFilter: LaneFilter = .all {
        didSet {
            guard laneFilter != oldValue else { return }
            rebuildDisplaySpans()
            focusedLane = min(focusedLane, max(0, visibleLanes.count - 1))
            focusedSpan = 0
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// The lanes actually drawn and measured. Everything that lays the trace out reads this rather
    /// than the render model, so a filtered view cannot disagree with its own height or hit testing.
    var visibleLanes: [AppKitAgentActivityLane] {
        switch laneFilter {
        case .all:
            return renderModel.lanes
        case .rootOnly:
            return renderModel.lanes.filter {
                $0.id == appKitHarnessLaneID || $0.id == AgentActivityIdentity.root
            }
        }
    }

    /// Where the viewport is, in this view's coordinates.
    ///
    /// Everything pinned — the lane gutter, the EVENTS and TOKENS labels, the ruler backdrop, the
    /// inspection clip — is positioned from this. It was read straight off `visibleRect`, which is
    /// empty when the view is not inside a scroll view, so all of that chrome collapsed to
    /// zero-width and vanished. Falling back to `bounds` keeps a standalone view (a render harness,
    /// a snapshot) drawing the same picture the scrolled one does.
    var viewportRect: NSRect {
        if let clip = enclosingScrollView?.contentView {
            return convert(clip.bounds, from: clip)
        }
        // A view with no superview reports an INFINITE `visibleRect`, not an empty one. Taken at
        // face value that put the frozen gutter at x = -8.99e307 — drawn, but off in the far
        // negative distance. Intersecting with `bounds` collapses infinite, null and empty alike to
        // something drawable.
        let visible = visibleRect.intersection(bounds)
        return visible.isEmpty ? bounds : visible
    }

    /// Repaint everything currently on screen.
    ///
    /// Invalidating only the chrome strips left the rest of the viewport holding whatever the
    /// scroll blit had moved there. Because every pinned element is positioned from `visibleRect`,
    /// a scroll changes what belongs in the entire viewport, so the entire viewport is the dirty
    /// region. This runs on scroll, not on the one-hertz tick, which stays bounded.
    func invalidateFrozenChrome() {
        guard mode == .trace else { return }
        setNeedsDisplay(visibleRect)
        // The inspection overlay is a subview of the scrolling document, so it travels with the
        // content and its old drawing is blitted along with it.
        inspectionOverlay.needsDisplay = true
        rebuildLaneTooltips()
    }

    /// Drop a hover that a scroll has invalidated.
    ///
    /// The pointer does not move when the plot scrolls under it, so the stored point keeps
    /// describing whatever used to be beneath the cursor. Once the scroll carried that point behind
    /// the frozen gutter, the crosshair and its readout drew straight over the lane names. A pinned
    /// inspection is deliberate and survives; a hover does not.
    /// Keyboard focus, expressed in the chart's own units: a lane and a span within it.
    ///
    /// Arrow keys previously nudged a pinned inspection by eight points, which scrubs pixels rather
    /// than moving between the marks that mean something, and never changed lane at all. Moving
    /// span to span is what makes the chart operable without a pointer — and it is the same
    /// traversal VoiceOver needs.
    private(set) var focusedLane = 0
    private(set) var focusedSpan = 0

    /// The span the keyboard is on, if any.
    var focusedItem: AppKitAgentActivityTraceSpan? {
        guard visibleLanes.indices.contains(focusedLane) else { return nil }
        let lane = visibleLanes[focusedLane]
        let spans = displaySpansByLaneID[lane.id] ?? lane.spans
        guard spans.indices.contains(focusedSpan) else { return nil }
        return spans[focusedSpan]
    }

    /// Move the keyboard focus. Returns false when the move would leave the chart.
    @discardableResult
    func moveFocus(laneDelta: Int, spanDelta: Int) -> Bool {
        guard !visibleLanes.isEmpty else { return false }
        var lane = focusedLane
        var span = focusedSpan
        if laneDelta != 0 {
            lane = min(visibleLanes.count - 1, max(0, lane + laneDelta))
            span = 0
        }
        if spanDelta != 0 {
            let spans = spanCount(inLane: lane)
            guard spans > 0 else { return false }
            let next = span + spanDelta
            guard next >= 0, next < spans else { return false }
            span = next
        }
        guard lane != focusedLane || span != focusedSpan else { return false }
        focusedLane = lane
        focusedSpan = span
        pinFocusedSpan()
        return true
    }

    private func spanCount(inLane index: Int) -> Int {
        guard visibleLanes.indices.contains(index) else { return 0 }
        let lane = visibleLanes[index]
        return (displaySpansByLaneID[lane.id] ?? lane.spans).count
    }

    /// Pin the inspection to the focused span so the readout describes it, and bring it on screen.
    private func pinFocusedSpan() {
        guard let item = focusedItem else { return }
        let rowY = TraceLayout.eventRailHeight + CGFloat(focusedLane) * TraceLayout.laneHeight
        let midX = (x(for: item.span.start) + x(for: item.span.end)) / 2
        pinnedPoint = NSPoint(x: midX, y: rowY + TraceLayout.trackY(item.span.phase))
        renderModel.notePointerRedraw()
        // The readout lives in the overlay; marking only the chart dirty left the previous box on
        // screen and every keypress added another.
        inspectionOverlay.needsDisplay = true
        if let scrollView = enclosingScrollView {
            scrollView.contentView.scrollToVisible(NSRect(
                x: max(0, midX - 60),
                y: rowY,
                width: 120,
                height: TraceLayout.laneHeight))
        }
        NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }

    /// Tooltips over each lane's gutter and each span.
    ///
    /// The gutter carries the agent's unabridged task. Span tooltips carry every complete tool name
    /// even when the measured-fit rule hides a title on the trace itself.
    private func rebuildLaneTooltips() {
        removeAllToolTips()
        toolTipTextByTag.removeAll(keepingCapacity: true)
        guard mode == .trace else { return }
        let originX = viewportRect.minX
        for (index, lane) in visibleLanes.enumerated() {
            let rowY = TraceLayout.eventRailHeight + CGFloat(index) * TraceLayout.laneHeight
            if let detail = lane.detail, !detail.isEmpty {
                let text = "\(lane.label)\n\(detail)"
                let tag = addToolTip(
                    NSRect(x: originX, y: rowY, width: labelWidth, height: TraceLayout.laneHeight),
                    owner: self,
                    userData: nil)
                toolTipTextByTag[tag] = text
            }
            let spans = displaySpansByLaneID[lane.id] ?? lane.spans
            for item in spans {
                let span = item.span
                guard !span.title.isEmpty else { continue }
                let text = spanToolTipText(span)
                let tag = addToolTip(
                    traceSpanRect(span, rowY: rowY),
                    owner: self,
                    userData: nil)
                toolTipTextByTag[tag] = text
            }
        }
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard view === self else { return "" }
        return toolTipTextByTag[tag] ?? ""
    }

    func invalidateHoverAfterScroll() {
        guard hoverPoint != nil else { return }
        hoverPoint = nil
        inspectionOverlay.needsDisplay = true
    }

    override func layout() {
        super.layout()
        inspectionOverlay.frame = bounds
        if mode == .trends,
           trendMetric == .runtime,
           abs(lastRuntimeAccessibilityWidth - bounds.width) > 0.5 {
            lastRuntimeAccessibilityWidth = bounds.width
            updateAccessibilitySummary()
            needsDisplay = true
        }
        if fitsWidth, abs(lastDisplayWidth - plotRect.width) > 0.5 {
            rebuildDisplaySpans()
            needsDisplay = true
        } else {
            lastDisplayWidth = plotRect.width
        }
    }

    func pointerMoved(to point: NSPoint) {
        guard pinnedPoint == nil else { return }
        if mode == .trends, trendMetric == .runtime {
            guard let layout = runtimeMetricLayouts().first(where: {
                $0.frame.insetBy(dx: -2, dy: -1).contains(point)
            }) else {
                guard hoverPoint != nil else { return }
                hoverPoint = nil
                inspectionOverlay.needsDisplay = true
                return
            }
            hoverPoint = NSPoint(x: layout.frame.midX, y: layout.frame.midY)
        } else {
            hoverPoint = point
        }
        renderModel.notePointerRedraw()
        inspectionOverlay.needsDisplay = true
    }

    func pointerExited() {
        guard pinnedPoint == nil else { return }
        hoverPoint = nil
        inspectionOverlay.needsDisplay = true
    }

    func pointerPressed(at point: NSPoint) {
        if let dismissRect = currentInspectionOverlayLayout()?.dismissRect,
           dismissRect.insetBy(dx: -3, dy: -3).contains(point) {
            clearPinnedInspection()
            return
        }
        if mode == .trends, trendMetric == .runtime {
            let layouts = runtimeMetricLayouts()
            guard let index = layouts.firstIndex(where: {
                $0.frame.insetBy(dx: -2, dy: -1).contains(point)
            }) else {
                clearPinnedInspection()
                hoverPoint = nil
                needsDisplay = true
                inspectionOverlay.needsDisplay = true
                return
            }
            if pinnedRuntimeMetricIndex == index {
                clearPinnedInspection()
                return
            }
            focusedRuntimeMetricIndex = index
            pinnedPoint = runtimeMetricInspectionPoint(for: index)
            pinnedRuntimeMetricIndex = index
            hoverPoint = nil
            renderModel.notePointerRedraw()
            needsDisplay = true
            inspectionOverlay.needsDisplay = true
            updateAccessibilitySummary()
            NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
            return
        }
        if mode == .trends, let index = trendTurnIndex(at: point),
           let turns = renderModel.input?.trendTurns,
           turns.indices.contains(index) {
            focusedTrendIndex = index
            pinnedPoint = trendInspectionPoint(for: index)
            hoverPoint = nil
            onSelectTrendTurnID?(turns[index].id)
            renderModel.notePointerRedraw()
            inspectionOverlay.needsDisplay = true
            updateAccessibilitySummary()
            return
        }
        if pinnedPoint == nil {
            pinnedPoint = point
            hoverPoint = nil
        } else {
            pinnedPoint = nil
            hoverPoint = point
        }
        renderModel.notePointerRedraw()
        inspectionOverlay.needsDisplay = true
    }

    fileprivate func clearPinnedInspection() {
        if pinnedPoint != nil {
            pinnedPoint = nil
            pinnedRuntimeMetricIndex = nil
            needsDisplay = true
            inspectionOverlay.needsDisplay = true
            updateAccessibilitySummary()
        }
    }

    @discardableResult
    func moveTrendFocus(_ delta: Int) -> Bool {
        if mode == .trends, trendMetric == .runtime {
            let layouts = runtimeMetricLayouts()
            guard !layouts.isEmpty else { return false }
            let next = min(
                layouts.count - 1,
                max(0, focusedRuntimeMetricIndex + delta))
            guard next != focusedRuntimeMetricIndex else { return false }
            focusedRuntimeMetricIndex = next
            pinnedPoint = runtimeMetricInspectionPoint(for: next)
            pinnedRuntimeMetricIndex = next
            hoverPoint = nil
            scrollToVisible(layouts[next].frame.insetBy(dx: -4, dy: -3))
            renderModel.notePointerRedraw()
            needsDisplay = true
            inspectionOverlay.needsDisplay = true
            updateAccessibilitySummary()
            NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
            return true
        }
        guard mode == .trends,
              let turns = renderModel.input?.trendTurns,
              !turns.isEmpty else { return false }
        let next = min(turns.count - 1, max(0, focusedTrendIndex + delta))
        guard next != focusedTrendIndex else { return false }
        focusedTrendIndex = next
        pinnedPoint = trendInspectionPoint(for: next)
        hoverPoint = nil
        onSelectTrendTurnID?(turns[next].id)
        renderModel.notePointerRedraw()
        inspectionOverlay.needsDisplay = true
        updateAccessibilitySummary()
        NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
        return true
    }

    func selectFocusedTrendTurn() {
        if mode == .trends, trendMetric == .runtime {
            pinnedPoint = runtimeMetricInspectionPoint(for: focusedRuntimeMetricIndex)
            pinnedRuntimeMetricIndex = focusedRuntimeMetricIndex
            needsDisplay = true
            inspectionOverlay.needsDisplay = true
            updateAccessibilitySummary()
            return
        }
        guard mode == .trends,
              let turns = renderModel.input?.trendTurns,
              turns.indices.contains(focusedTrendIndex) else { return }
        pinnedPoint = trendInspectionPoint(for: focusedTrendIndex)
        onSelectTrendTurnID?(turns[focusedTrendIndex].id)
        inspectionOverlay.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        guard renderModel.input != nil else { return }
        switch mode {
        case .trace: drawTrace(dirtyRect: dirtyRect)
        case .usage: drawUsage()
        case .trends: drawTrends()
        }
    }

    /// Derived from the VIEWPORT, not from the document. On a live turn at a fixed scale the
    /// document grows every second; deriving the frozen gutter from `bounds.width` meant the plot
    /// origin crept sideways on each tick and every bar shifted with it.
    /// How wide the frozen lane gutter is, in points, persisted across launches.
    ///
    /// It used to be a hard 132-point cap derived from the viewport, which is why an agent's task
    /// could never be printed beside its name and had to live in a tooltip. It is draggable now.
    private static let gutterWidthDefaultsKey = "agentsTraceGutterWidth"
    static let minimumGutterWidth: CGFloat = 92
    static let maximumGutterWidth: CGFloat = 320

    var laneGutterWidth: CGFloat = {
        let stored = UserDefaults.standard.object(forKey: "agentsTraceGutterWidth") as? Double
        return CGFloat(stored ?? 132)
    }() {
        didSet {
            guard laneGutterWidth != oldValue else { return }
            UserDefaults.standard.set(
                Double(laneGutterWidth),
                forKey: Self.gutterWidthDefaultsKey)
            rebuildDisplaySpans()
            needsDisplay = true
        }
    }

    /// The gutter never takes more than half the viewport, however wide it has been dragged, so the
    /// plot cannot be squeezed out of existence on a narrow inspector.
    private var labelWidth: CGFloat {
        let ceiling = max(Self.minimumGutterWidth, viewportRect.width * 0.5)
        return min(ceiling, max(Self.minimumGutterWidth, laneGutterWidth)).rounded()
    }

    /// Width occupied by the frozen lane labels in the current viewport. The panel's live-follow
    /// policy needs the same value as drawing so it never centers now underneath those labels.
    var viewportGutterWidth: CGFloat { labelWidth }

    /// The draggable divider's hit zone, in this view's coordinates.
    func gutterDividerRect() -> NSRect {
        NSRect(
            x: viewportRect.minX + labelWidth - 3,
            y: 0,
            width: 7,
            height: max(1, bounds.height))
    }

    /// Apply a drag, clamped to the range the layout can honour.
    func resizeGutter(toPointerX x: CGFloat) {
        let proposed = x - viewportRect.minX
        laneGutterWidth = min(
            Self.maximumGutterWidth,
            max(Self.minimumGutterWidth, proposed.rounded()))
    }

    private var plotRect: NSRect {
        let width: CGFloat
        if mode == .trace, !fitsWidth {
            // A fixed-scale trace is measured in points per second, not as a fraction of whatever
            // document width happens to be available. In particular, `preferredWidth` adds a live
            // runway after this rectangle. Including that runway in the normalized time axis put
            // every current span and ruler tick at the document edge while follow logic correctly
            // treated the runway as empty space ahead of now. Keeping the axis at its physical
            // duration also means earlier spans never slide as a live turn grows.
            width = fixedScaleTimeAxisWidth
        } else {
            width = max(1, bounds.width - labelWidth - 10)
        }
        return NSRect(
            x: labelWidth,
            y: 0,
            width: width,
            height: max(1, bounds.height))
    }

    /// Plot pixels that are actually visible beside the frozen gutter.
    ///
    /// `plotRect` is in document coordinates and starts at the document's one original gutter.
    /// Once the document scrolls horizontally, however, the pinned labels occupy a new strip
    /// beginning at `viewportRect.minX`. Marks behind that strip must be clipped at its trailing
    /// edge, not merely covered by the gutter: the EVENTS backdrop is intentionally translucent,
    /// so guidance badges otherwise remain visible through it.
    private var visiblePlotRect: NSRect {
        let viewport = viewportRect
        let minX = max(plotRect.minX, viewport.minX + labelWidth)
        let maxX = min(plotRect.maxX, viewport.maxX)
        return NSRect(
            x: minX,
            y: 0,
            width: max(0, maxX - minX),
            height: max(1, bounds.height))
    }

    private var duration: TimeInterval {
        max(0.001, renderModel.end.timeIntervalSince(renderModel.start))
    }

    private func x(for date: Date) -> CGFloat {
        let fraction = date.timeIntervalSince(renderModel.start) / duration
        return plotRect.minX + plotRect.width * CGFloat(min(1, max(0, fraction)))
    }

    private func date(forX x: CGFloat) -> Date {
        let fraction = min(1, max(0, (x - plotRect.minX) / max(1, plotRect.width)))
        return renderModel.start.addingTimeInterval(duration * Double(fraction))
    }

    /// The visible and inspectable bounds of one span. Minimum-width marks deliberately occupy
    /// more pixels than their literal duration, so hover, tooltips, and accessibility must use this
    /// geometry instead of a narrower time-only interval.
    private func traceSpanRect(_ span: AgentActivityTraceSpan, rowY: CGFloat) -> NSRect {
        let startX = x(for: span.start)
        if span.phase.isTerminal {
            let markerX = min(plotRect.maxX - 8, max(plotRect.minX + 8, startX))
            return NSRect(
                x: markerX - 4.5,
                y: TraceLayout.laneCenter(rowY) - 4.5,
                width: 9,
                height: 9)
        }
        let width = max(TraceLayout.minimumSpanWidth, x(for: span.end) - startX)
        if span.phase == .compacting {
            // Compaction halts the agent, so by construction nothing occupies either track while it
            // runs. A 15-point bar on the lower rail with dead space above it read as a minor
            // sub-activity; the block spans both rails because it is the lane's whole state.
            let top = TraceLayout.trackY(.model) - TraceLayout.barHeight / 2
            let bottom = TraceLayout.trackY(.tool) + TraceLayout.barHeight / 2
            return NSRect(x: startX, y: rowY + top, width: width, height: bottom - top)
        }
        return NSRect(
            x: startX,
            y: rowY + TraceLayout.trackY(span.phase) - TraceLayout.barHeight / 2,
            width: width,
            height: TraceLayout.barHeight)
    }

    private func drawTrace(dirtyRect: NSRect) {
        let laneCount = visibleLanes.count
        let lanesTop = TraceLayout.eventRailHeight
        let lanesBottom = lanesTop + CGFloat(laneCount) * TraceLayout.laneHeight

        drawEventRail(dirtyRect: dirtyRect)

        for (index, lane) in visibleLanes.enumerated() {
            let rowY = lanesTop + CGFloat(index) * TraceLayout.laneHeight
            let rowRect = NSRect(
                x: 0,
                y: rowY,
                width: bounds.width,
                height: TraceLayout.laneHeight)
            guard rowRect.intersects(dirtyRect) else { continue }

            // The Dark chart gets depth from luminous marks on a near-black field. On white, that
            // same unfilled field made its rails and low-volume spans look unfinished. A quiet,
            // alternating paper tint gives the Light chart equal structure without turning it into
            // a spreadsheet.
            let isDark = effectiveAppearance.mechanicianIsDark
            NSColor.nElevated
                .withAlphaComponent(isDark ? 0.16 : (index.isMultiple(of: 2) ? 0.42 : 0.25))
                .setFill()
            NSRect(
                x: plotRect.minX,
                y: rowY,
                width: plotRect.width,
                height: TraceLayout.laneHeight).fill()

            if lane.id == AgentActivityIdentity.root {
                NSColor.controlAccentColor
                    .withAlphaComponent(isDark ? 0.045 : 0.075)
                    .setFill()
                NSRect(
                    x: plotRect.minX,
                    y: rowY,
                    width: plotRect.width,
                    height: TraceLayout.laneHeight).fill()
            }

            drawTimelineGrid(top: rowY, height: TraceLayout.laneHeight)

            // The two track baselines the bars sit centred on.
            NSColor.secondaryLabelColor
                .withAlphaComponent(isDark ? 0.14 : 0.20)
                .setFill()
            for offset in [CGFloat(17), CGFloat(41)] {
                NSRect(
                    x: plotRect.minX,
                    y: rowY + offset - 0.5,
                    width: plotRect.width,
                    height: 1).fill()
            }

            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(
                x: visiblePlotRect.minX,
                y: rowY,
                width: visiblePlotRect.width,
                height: TraceLayout.laneHeight)).addClip()
            for event in renderModel.globalEvents {
                let eventX = x(for: event.at)
                guard eventX >= dirtyRect.minX - 1, eventX <= dirtyRect.maxX + 1 else { continue }
                agentTraceEventMarkerPalette(
                    event: event,
                    appearance: effectiveAppearance)
                    .fill.withAlphaComponent(0.32).setFill()
                NSRect(x: eventX, y: rowY, width: 1, height: TraceLayout.laneHeight).fill()
            }

            for item in spansForDrawing(
                displaySpansByLaneID[lane.id] ?? lane.spans,
                dirtyRect: dirtyRect
            ) {
                drawTraceSpan(item, rowY: rowY)
            }
            NSGraphicsContext.restoreGraphicsState()

            drawFrozenLaneLabel(lane, rowY: rowY, frozenX: viewportRect.minX)
        }

        if laneCount > 0 {
            drawCostTrack(top: lanesBottom, dirtyRect: dirtyRect)
            drawRuler(top: lanesBottom + TraceLayout.costTrackHeight)
        }

        // A hairline where the gutter ends, so the draggable seam is discoverable rather than an
        // invisible strip you have to find.
        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        NSRect(
            x: viewportRect.minX + labelWidth - 0.5,
            y: 0,
            width: 1,
            height: max(0, lanesBottom + TraceLayout.costTrackHeight)).fill()
    }

    /// Compactions and user-authored turn events, aligned across every lane.
    private func drawEventRail(dirtyRect: NSRect) {
        let rail = NSRect(x: 0, y: 0, width: bounds.width, height: TraceLayout.eventRailHeight)
        guard rail.intersects(dirtyRect) else { return }
        drawTimelineGrid(top: 0, height: TraceLayout.eventRailHeight)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(
            x: visiblePlotRect.minX,
            y: 0,
            width: visiblePlotRect.width,
            height: TraceLayout.eventRailHeight)).addClip()
        for geometry in globalEventBadgeGeometries() {
            let event = geometry.event
            let eventX = geometry.eventX
            let palette = agentTraceEventMarkerPalette(
                event: event,
                appearance: effectiveAppearance)
            if eventX >= dirtyRect.minX - 1, eventX <= dirtyRect.maxX + 1 {
                palette.stem.setFill()
                NSRect(x: eventX, y: 12, width: 1, height: 18).fill()
            }

            guard geometry.badgeRect.intersects(dirtyRect) else { continue }
            let badge = geometry.badgeRect
            let radius: CGFloat = event.contextEventKind == .historyReduction
                    || event.contextEventKind == .subtraction
                ? 2
                : event.kind == .compaction ? 4 : 8
            let badgePath = NSBezierPath(
                roundedRect: badge,
                xRadius: radius,
                yRadius: radius)
            palette.fill.setFill()
            badgePath.fill()
            palette.stroke.setStroke()
            badgePath.lineWidth = 1.25
            badgePath.stroke()
            let size = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
            let tint = NSImage.SymbolConfiguration(paletteColors: [palette.symbol])
            if let symbol = NSImage(
                systemSymbolName: agentTraceEventSymbolName(event),
                accessibilityDescription: nil)?
                .withSymbolConfiguration(size.applying(tint)) {
                let target = NSRect(x: badge.midX - 5, y: badge.midY - 5, width: 10, height: 10)
                symbol.isTemplate = false
                symbol.draw(
                    in: target,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        // Frozen rail label, right-aligned against the lane gutter.
        let frozenX = viewportRect.minX
        NSColor.nElevated.withAlphaComponent(0.2).setFill()
        NSRect(x: frozenX, y: 0, width: labelWidth, height: TraceLayout.eventRailHeight).fill()
        let count = renderModel.globalEvents.count
        let title = count > 0 ? "EVENTS  \(count)" : "EVENTS"
        drawText(
            title,
            rect: NSRect(
                x: frozenX,
                y: TraceLayout.eventRailHeight / 2 - 6,
                width: labelWidth - 8,
                height: 12),
            font: TraceLayout.railTitleFont,
            color: .nChartMuted,
            alignment: .right)
        NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
        NSRect(
            x: frozenX,
            y: TraceLayout.eventRailHeight - 1,
            width: viewportRect.width,
        height: 1).fill()
    }

    /// Solid, polarity-flipped event badges remain legible over both trace backdrops. The previous
    /// interjection marker was system teal at 16% opacity with no outline; on common dark themes its
    /// circular body nearly disappeared and only a tiny quote glyph survived.
    struct AgentTraceEventMarkerPalette {
        var fill: NSColor
        var stroke: NSColor
        var symbol: NSColor
        var stem: NSColor
    }

    func agentTraceEventMarkerPalette(
        event: AgentActivityRecord,
        appearance: NSAppearance
    ) -> AgentTraceEventMarkerPalette {
        if let harnessEvent = event.harnessEventKind,
           appKitHarnessEventAppearsOnRail(event) {
            let fill: NSColor
            switch harnessEvent {
            case .retry:
                fill = appKitAgentActivityPhaseColor(.stopped)
            case .retryRecovered:
                fill = appKitAgentActivityPhaseColor(.completed)
            case .retryExhausted, .internalError:
                fill = appKitAgentActivityPhaseColor(.failed)
            case .modelRerouted, .modelVerification:
                fill = appKitAgentActivityPhaseColor(.model)
            case .modelSafety:
                fill = event.safetyOutcome == .blocked || event.safetyOutcome == .refused
                    ? appKitAgentActivityPhaseColor(.failed)
                    : appKitAgentActivityPhaseColor(.stopped)
            case .permission:
                fill = appKitAgentActivityPhaseColor(.tool)
            case .mcpConnection:
                fill = waitingSlate
            case .interrupt:
                fill = appKitAgentActivityPhaseColor(.stopped)
            case .phase, .tool, .result, .context, .compaction, .hook:
                fill = waitingSlate
            }
            let foreground = appearance.mechanicianIsDark ? NSColor.black : NSColor.white
            return AgentTraceEventMarkerPalette(
                fill: fill,
                stroke: foreground.withAlphaComponent(0.92),
                symbol: foreground,
                stem: fill.withAlphaComponent(0.72))
        }
        return agentTraceEventMarkerPalette(
            kind: event.kind,
            isInitialPrompt: event.userEventKind == .initialPrompt,
            isHistoryReduction: event.contextEventKind == .historyReduction
                || event.contextEventKind == .subtraction,
            appearance: appearance)
    }

    func agentTraceEventMarkerPalette(
        kind: AgentActivityKind,
        appearance: NSAppearance
    ) -> AgentTraceEventMarkerPalette {
        agentTraceEventMarkerPalette(
            kind: kind,
            isInitialPrompt: false,
            isHistoryReduction: false,
            appearance: appearance)
    }

    private func agentTraceEventMarkerPalette(
        kind: AgentActivityKind,
        isInitialPrompt: Bool,
        isHistoryReduction: Bool,
        appearance: NSAppearance
    ) -> AgentTraceEventMarkerPalette {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill: NSColor
        if isHistoryReduction {
            // Gold is maintenance/recovery, distinct from provider-authored purple compaction and
            // teal user guidance. Polarity flips so its minus-text glyph remains AA contrast.
            fill = isDark
                ? NSColor(srgbRed: 0.95, green: 0.76, blue: 0.31, alpha: 1)
                : NSColor(srgbRed: 0.42, green: 0.31, blue: 0.00, alpha: 1)
        } else if kind == .compaction {
            fill = isDark
                ? NSColor(srgbRed: 0.73, green: 0.59, blue: 0.97, alpha: 1)
                : NSColor(srgbRed: 0.35, green: 0.16, blue: 0.58, alpha: 1)
        } else if isInitialPrompt {
            // The prompt starts the turn, so use the app's blue interaction family. Mid-turn
            // guidance remains teal; the two user-authored events should not require a tooltip to
            // distinguish them.
            fill = isDark
                ? NSColor(srgbRed: 0.30, green: 0.64, blue: 1.00, alpha: 1)
                : NSColor(srgbRed: 0.00, green: 0.31, blue: 0.66, alpha: 1)
        } else {
            fill = isDark
                ? NSColor(srgbRed: 0.27, green: 0.82, blue: 0.84, alpha: 1)
                : NSColor(srgbRed: 0.00, green: 0.36, blue: 0.42, alpha: 1)
        }
        let foreground = isDark ? NSColor.black : NSColor.white
        return AgentTraceEventMarkerPalette(
            fill: fill,
            stroke: foreground.withAlphaComponent(0.92),
            symbol: foreground,
            stem: fill.withAlphaComponent(0.72))
    }

    func agentTraceEventTitle(_ event: AgentActivityRecord) -> String {
        if let harnessEvent = event.harnessEventKind,
           appKitHarnessEventAppearsOnRail(event) {
            switch harnessEvent {
            case .retry:
                let attempt = event.retryAttempt.map { " · attempt \($0)" } ?? ""
                return String(localized: "Retry scheduled") + attempt
            case .retryRecovered:
                return String(localized: "Retry recovered")
            case .retryExhausted:
                return String(localized: "Retries exhausted")
            case .modelRerouted:
                if let from = event.rerouteOriginalModelID, let to = event.rerouteModelID {
                    return String(localized: "Model rerouted") + " · \(from) → \(to)"
                }
                return String(localized: "Model rerouted")
            case .modelSafety:
                return String(localized: "Model safety check")
            case .modelVerification:
                return String(localized: "Model verified")
            case .permission:
                return String(localized: "Approval decision")
            case .mcpConnection:
                return String(localized: "MCP connection")
            case .interrupt:
                return String(localized: "Interrupted")
            case .internalError:
                return String(localized: "Harness error")
            case .phase, .tool, .result, .context, .compaction, .hook:
                break
            }
        }
        if event.contextEventKind == .subtraction {
            let subject = event.subtractionSubject
            let count = event.subtractionCount ?? 0
            let noun = count == 1 ? (subject?.singular ?? "item") : (subject?.plural ?? "items")
            // Name what was withheld when it fits, because "1 tool withheld" is not actionable and
            // the name is the whole point. Fall back to the count when several went at once.
            let what = count == 1
                ? (event.subtractionNames?.first.map { "\($0) withheld" } ?? "1 \(noun) withheld")
                : "\(count) \(noun) withheld"
            guard let reason = event.subtractionReason else { return what }
            return "\(what) · \(reason.label)"
        }
        if event.contextEventKind == .historyReduction {
            var changes: [String] = []
            if let omitted = event.historyOmittedMessages, omitted > 0 {
                changes.append("\(omitted) \(omitted == 1 ? "message" : "messages") omitted")
            }
            if let shortened = event.historyShortenedMessages, shortened > 0 {
                changes.append(
                    "\(shortened) \(shortened == 1 ? "message" : "messages") shortened")
            }
            return "History reduced" + (changes.isEmpty ? "" : " · \(changes.joined(separator: " · "))")
        }
        if event.kind == .compaction { return "Compaction" }
        if event.userEventKind == .initialPrompt { return "Initial prompt" }
        if event.interjectionDisposition == .queued { return "User guidance queued" }
        return "User guidance"
    }

    func agentTraceEventSymbolName(_ event: AgentActivityRecord) -> String {
        if let harnessEvent = event.harnessEventKind,
           appKitHarnessEventAppearsOnRail(event) {
            switch harnessEvent {
            case .retry: return "arrow.clockwise"
            case .retryRecovered: return "checkmark.circle.fill"
            case .retryExhausted, .internalError: return "exclamationmark.triangle.fill"
            case .modelRerouted: return "arrow.left.arrow.right"
            case .modelSafety: return "shield.lefthalf.filled"
            case .modelVerification: return "checkmark.seal.fill"
            case .permission: return "hand.raised.fill"
            case .mcpConnection: return "network"
            case .interrupt: return "stop.fill"
            case .phase, .tool, .result, .context, .compaction, .hook: break
            }
        }
        if event.contextEventKind == .subtraction { return "minus.circle" }
        if event.contextEventKind == .historyReduction { return "text.badge.minus" }
        if event.kind == .compaction { return "arrow.triangle.2.circlepath" }
        if event.userEventKind == .initialPrompt { return "paperplane.fill" }
        return "quote.bubble.fill"
    }

    /// The badge and its truthful timestamp stem intentionally have separate horizontal geometry.
    /// An opening prompt sits at t=0, so its 16-point badge must move right to remain inside the
    /// plot. A context-recovery marker can arrive only milliseconds later and needs the same
    /// clamping; independently clamping both painted the second glyph directly over the first.
    ///
    /// Resolve the whole ordered rail once. The same result drives paint, pointer inspection, and
    /// VoiceOver frames so the glyph a user can see is always the event they can inspect.
    private struct GlobalEventBadgeGeometry {
        var event: AgentActivityRecord
        var eventX: CGFloat
        var badgeRect: NSRect
    }

    private func globalEventBadgeGeometries() -> [GlobalEventBadgeGeometry] {
        let ordered = renderModel.globalEvents.enumerated().sorted {
            if $0.element.at != $1.element.at {
                return $0.element.at < $1.element.at
            }
            return $0.offset < $1.offset
        }.map(\.element)
        guard !ordered.isEmpty else { return [] }

        let minimumCenterX = plotRect.minX + 8
        let maximumCenterX = max(minimumCenterX, plotRect.maxX - 8)
        let availableWidth = max(0, maximumCenterX - minimumCenterX)
        // Sixteen-point bodies retain a two-point visual gap whenever the rail has enough room.
        // If the rail contains more events than can physically fit, distribute them across all
        // available space instead of sending the last cluster outside the chart.
        let spacing: CGFloat = ordered.count > 1
            ? min(18, availableWidth / CGFloat(ordered.count - 1))
            : 0
        let eventXs = ordered.map { x(for: $0.at) }
        var centers = eventXs.map {
            min(maximumCenterX, max(minimumCenterX, $0))
        }

        if centers.count > 1 {
            for index in 1..<centers.count {
                centers[index] = max(centers[index], centers[index - 1] + spacing)
            }
            if centers[centers.count - 1] > maximumCenterX {
                centers[centers.count - 1] = maximumCenterX
                for index in stride(from: centers.count - 2, through: 0, by: -1) {
                    centers[index] = min(centers[index], centers[index + 1] - spacing)
                }
            }
        }

        return ordered.indices.map { index in
            GlobalEventBadgeGeometry(
                event: ordered[index],
                eventX: eventXs[index],
                badgeRect: NSRect(
                    x: centers[index] - 8,
                    y: 1,
                    width: 16,
                    height: 16))
        }
    }

    /// Cost on the same time axis as the work that caused it.
    ///
    /// Token totals existed only as header text, which answers "how much" but never "when" — so a
    /// context spike could not be traced back to the span that produced it. This is a counter track
    /// in the Perfetto/Instruments sense: stacked columns per bucket, sharing the lanes' x-mapping
    /// so a column lines up with the bar above it. Cached input is drawn separately from fresh
    /// input because they differ in cost by an order of magnitude.
    private func drawCostTrack(top: CGFloat, dirtyRect: NSRect) {
        let rect = NSRect(
            x: 0,
            y: top,
            width: bounds.width,
            height: TraceLayout.costTrackHeight)
        guard rect.intersects(dirtyRect) else { return }

        // Share the lanes' backdrop and sit directly against the last lane, so the track reads as
        // part of the same stack rather than a detached chart parked underneath it.
        NSColor.nElevated
            .withAlphaComponent(effectiveAppearance.mechanicianIsDark ? 0.18 : 0.42)
            .setFill()
        NSRect(
            x: plotRect.minX,
            y: top,
            width: plotRect.width,
            height: TraceLayout.costTrackHeight).fill()
        drawTimelineGrid(top: top, height: TraceLayout.costTrackHeight)
        NSColor.secondaryLabelColor
            .withAlphaComponent(effectiveAppearance.mechanicianIsDark ? 0.14 : 0.20)
            .setFill()
        NSRect(x: plotRect.minX, y: top, width: plotRect.width, height: 1).fill()

        let buckets = renderModel.usageBuckets
        let peak = buckets.map(\.tokens.processed).max() ?? 0
        let plotTop = top + 6
        let plotHeight = TraceLayout.costTrackHeight - 12

        if peak > 0 {
            for bucket in buckets where bucket.tokens.processed > 0 {
                let startX = x(for: bucket.start)
                let endX = x(for: bucket.end)
                guard endX >= dirtyRect.minX - 2, startX <= dirtyRect.maxX + 2 else { continue }
                let width = max(1.5, endX - startX - 1)
                let scale = plotHeight / CGFloat(peak)
                var y = top + TraceLayout.costTrackHeight - 6

                let anatomy = appKitActivityTokenAnatomy(
                    records: tokenRecords(
                        in: bucket,
                        from: renderModel.input?.records ?? []),
                    breakdown: bucket.tokens)
                // One stack, with subdivisions inside input and generated totals. Optional provider
                // categories remain absent instead of becoming extra zero-height segments.
                for (amount, color, hatched) in [
                    (anatomy.inputRemainder ?? 0,
                     phaseColor(.model).withAlphaComponent(0.82),
                     !anatomy.inputRemainderIsExact),
                    (anatomy.plottedCacheRead,
                     appKitAgentActivityCachedInputColor(in: effectiveAppearance),
                     false),
                    (anatomy.plottedCacheWrite,
                     phaseColor(.model).withAlphaComponent(0.62),
                     true),
                    (anatomy.answerOutput ?? 0,
                     phaseColor(.completed).withAlphaComponent(0.88),
                     false),
                    (anatomy.reasoningOutput ?? 0,
                     phaseColor(.completed).withAlphaComponent(0.68),
                     true),
                    (anatomy.unclassified ?? 0,
                     waitingSlate.withAlphaComponent(0.72),
                     true),
                ] where amount > 0 {
                    let height = max(0.5, CGFloat(amount) * scale)
                    color.setFill()
                    let segment = NSRect(
                        x: startX,
                        y: y - height,
                        width: width,
                        height: height)
                    segment.fill()
                    if hatched { drawHatching(in: segment, color: color) }
                    if !effectiveAppearance.mechanicianIsDark, height >= 1 {
                        NSColor.black.withAlphaComponent(0.18).setStroke()
                        let outline = NSBezierPath(
                            rect: segment.insetBy(dx: 0.25, dy: 0.25))
                        outline.lineWidth = 0.5
                        outline.stroke()
                    }
                    y -= height
                }
            }
        }

        // Frozen label for the track, matching the lane gutter's right alignment.
        let frozenX = viewportRect.minX
        NSColor.windowBackgroundColor.setFill()
        NSRect(
            x: frozenX,
            y: top,
            width: labelWidth,
            height: TraceLayout.costTrackHeight).fill()
        drawText(
            "TOKENS",
            rect: NSRect(x: frozenX, y: plotTop, width: labelWidth - 8, height: 11),
            font: TraceLayout.railTitleFont,
            color: .nChartMuted,
            alignment: .right)
        if peak > 0 {
            drawText(
                "peak \(formatTokens(peak))",
                rect: NSRect(x: frozenX, y: plotTop + 12, width: labelWidth - 8, height: 11),
                font: TraceLayout.laneMetaFont,
                color: .nChartMuted,
                alignment: .right)
        }
    }

    /// Five evenly spaced verticals, heavier at the two edges — the original's quiet backdrop.
    private func drawTimelineGrid(top: CGFloat, height: CGFloat) {
        for index in 0...4 {
            let gridX = plotRect.minX + plotRect.width * CGFloat(index) / 4
            NSColor.secondaryLabelColor
                .withAlphaComponent(
                    index == 0 || index == 4
                        ? (effectiveAppearance.mechanicianIsDark ? 0.14 : 0.20)
                        : (effectiveAppearance.mechanicianIsDark ? 0.075 : 0.11))
                .setFill()
            NSRect(x: gridX, y: top, width: 1, height: height).fill()
        }
    }

    private func drawRuler(top: CGFloat) {
        let frozenX = viewportRect.minX
        let gutterEdge = frozenX + labelWidth
        let count = max(2, min(40, Int(plotRect.width / 90)))
        for index in 0...count {
            let fraction = Double(index) / Double(count)
            let tickX = plotRect.minX + plotRect.width * CGFloat(fraction)
            let moment = renderModel.start.addingTimeInterval(duration * fraction)
            let label = durationLabel(moment.timeIntervalSince(renderModel.start))
            let alignment: NSTextAlignment = index == 0
                ? .left
                : index == count ? .right : .center
            let box = appKitTimelineTickLabelRect(
                tickX: tickX,
                top: top + 4,
                width: 84,
                index: index,
                count: count)
            // Scrolled right, a tick's 84pt alignment box can reach beneath the frozen gutter even
            // when its right-aligned glyphs do not. Test the measured text footprint so the final
            // live label survives a narrow viewport without printing over the lane names.
            let measuredWidth = ceil((label as NSString).size(
                withAttributes: [.font: TraceLayout.rulerFont]).width)
            guard appKitTimelineTickLabelFitsPastFrozenGutter(
                box: box,
                measuredTextWidth: measuredWidth,
                alignment: alignment,
                gutterEdge: gutterEdge) else { continue }
            drawText(
                label,
                rect: box,
                font: TraceLayout.rulerFont,
                color: .nChartMuted,
                alignment: alignment)
        }
        // The ruler row needs the same frozen backdrop every other row has, so nothing shows
        // through beneath the gutter.
        NSColor.windowBackgroundColor.setFill()
        NSRect(
            x: frozenX,
            y: top,
            width: labelWidth,
            height: TraceLayout.rulerHeight).fill()
    }

    /// Lane identity stays pinned while the plot scrolls under it: a status dot and name, the
    /// lane's processed tokens and current state, and its task when the gutter is wide enough.
    private func drawFrozenLaneLabel(
        _ lane: AppKitAgentActivityLane,
        rowY: CGFloat,
        frozenX: CGFloat
    ) {
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: frozenX, y: rowY, width: labelWidth, height: TraceLayout.laneHeight).fill()
        drawLaneLabel(lane, rect: NSRect(
            x: frozenX + 8,
            y: rowY,
            width: max(0, labelWidth - 16),
            height: TraceLayout.laneHeight))
    }

    /// Binary-search the lane's spans down to the ones the dirty rect can actually show, so a
    /// one-hertz tick redraws a sliver instead of every span in the turn.
    private func spansForDrawing(
        _ spans: [AppKitAgentActivityTraceSpan],
        dirtyRect: NSRect
    ) -> ArraySlice<AppKitAgentActivityTraceSpan> {
        guard !spans.isEmpty else { return spans[...] }
        let dirtyStart = date(forX: max(plotRect.minX, dirtyRect.minX - 3))
        let dirtyEnd = date(forX: min(plotRect.maxX, dirtyRect.maxX + 3))
        var low = 0
        var high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].span.start < dirtyStart {
                low = middle + 1
            } else {
                high = middle
            }
        }
        var first = max(0, low - 1)
        while first < spans.count, spans[first].span.end < dirtyStart {
            first += 1
        }
        var last = first
        while last < spans.count, spans[last].span.start <= dirtyEnd {
            last += 1
        }
        return spans[first..<last]
    }

    private func drawTraceSpan(_ item: AppKitAgentActivityTraceSpan, rowY: CGFloat) {
        let span = item.span
        let rect = traceSpanRect(span, rowY: rowY)

        if span.phase.isTerminal {
            // A ringed dot on the lane's centre line, clamped inside the plot so it is never
            // half-cut at either edge.
            phaseColor(span.phase).setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor.nSurface.setStroke()
            let ring = NSBezierPath(ovalIn: rect)
            ring.lineWidth = 1.5
            ring.stroke()
            return
        }

        // Every non-terminal phase is a BAR with real duration, on the track its phase belongs to.
        // Model calls ride the upper track, tool calls and waits the lower one, so a tool call's
        // length on screen is its length in time.
        let width = rect.width
        let centerY = rect.midY
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: TraceLayout.barRadius,
            yRadius: TraceLayout.barRadius)
        let spanTool = span.toolNames.first
        let color = appKitAgentActivitySpanFillColor(span.phase, tool: spanTool)
            .mechanicianResolved(in: effectiveAppearance)
        let isDark = effectiveAppearance.mechanicianIsDark
        let barAlpha = appKitAgentActivitySpanFillAlpha(
            span.phase,
            appearance: effectiveAppearance)
        color.withAlphaComponent(barAlpha).setFill()
        path.fill()
        if !isDark {
            NSColor.black.withAlphaComponent(0.20).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        if span.phase == .compacting {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let hatch = NSBezierPath()
            var hatchX = rect.minX - rect.height
            while hatchX < rect.maxX + rect.height {
                hatch.move(to: NSPoint(x: hatchX, y: rect.maxY))
                hatch.line(to: NSPoint(x: hatchX + rect.height, y: rect.minY))
                hatchX += 5
            }
            hatch.lineWidth = 1
            color.withAlphaComponent(0.9).setStroke()
            hatch.stroke()
            NSGraphicsContext.restoreGraphicsState()
        } else if span.sourceCount > 1 {
            // Coalesced spans are divided so an aggregate never reads as one long call.
            let divisions = min(span.sourceCount, max(1, Int(width / 3)))
            if divisions > 1 {
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                let ticks = NSBezierPath()
                let step = width / CGFloat(divisions)
                for index in 1..<divisions {
                    let tickX = rect.minX + step * CGFloat(index)
                    ticks.move(to: NSPoint(x: tickX, y: rect.minY + 2))
                    ticks.line(to: NSPoint(x: tickX, y: rect.maxY - 2))
                }
                ticks.lineWidth = 0.5
                NSColor.black.withAlphaComponent(0.28).setStroke()
                ticks.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        path.lineWidth = span.phase == .compacting ? 1 : 0.5
        color.withAlphaComponent(span.phase == .compacting ? 0.85 : 0.35).setStroke()
        path.stroke()

        // The critical-path marker: a bar under the span, in the accent reserved for interaction
        // and emphasis. Drawn beneath rather than over the mark so it never obscures what it
        // annotates, and only for spans that carry real duration.
        if showsCriticalPath,
           renderModel.criticalSpanIDs.contains(span.id),
           rect.width >= 2 {
            NSColor.controlAccentColor.withAlphaComponent(0.95).setFill()
            NSBezierPath(
                roundedRect: NSRect(
                    x: rect.minX,
                    y: rect.maxY + 2,
                    width: rect.width,
                    height: 2.5),
                xRadius: 1.25,
                yRadius: 1.25).fill()
        }

        guard !span.title.isEmpty else { return }
        let textWidth = ceil((span.title as NSString)
            .size(withAttributes: [.font: TraceLayout.spanLabelFont]).width)
        guard traceSpanLabelPlacement(
            textWidth: textWidth,
            spanWidth: width) == .inside else {
            return
        }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        drawText(
            span.title,
            rect: NSRect(
                x: rect.minX + 4,
                y: centerY - 6,
                width: max(1, width - 8),
                height: 12),
            font: TraceLayout.spanLabelFont,
            color: appKitAgentActivitySpanLabelColor(
                span.phase,
                tool: spanTool,
                background: .nElevated,
                appearance: effectiveAppearance),
            strokeColor: appKitAgentActivitySpanLabelOutlineColor(),
            strokeWidth: appKitAgentActivitySpanLabelStrokeWidth())
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawUsage() {
        drawUsageLegend()
        let fullChart = NSRect(
            x: plotRect.minX,
            y: 48,
            width: plotRect.width,
            height: max(45, bounds.height - 68))
        let hasContext = !renderModel.contextSeries.samples.isEmpty
        let tokenChart = hasContext
            ? NSRect(
                x: fullChart.minX,
                y: fullChart.minY,
                width: fullChart.width,
                height: max(28, floor(fullChart.height * 0.55)))
            : fullChart
        NSColor.nElevated
            .withAlphaComponent(effectiveAppearance.mechanicianIsDark ? 0.20 : 0.46)
            .setFill()
        NSBezierPath(roundedRect: tokenChart, xRadius: 4, yRadius: 4).fill()
        drawText(
            renderModel.usageAgentID.flatMap { selected in
                renderModel.lanes.first(where: { $0.id == selected })?.label
            } ?? "All agents",
            rect: NSRect(
                x: 8,
                y: tokenChart.midY - 8,
                width: labelWidth - 14,
                height: 17),
            font: .systemFont(ofSize: 9, weight: .medium),
            color: .secondaryLabelColor)

        let buckets = renderModel.usageBuckets
        let reportingRecords = usageReportingRecords
        let maximum = max(1, buckets.compactMap {
            appKitActivityTokenAnatomy(
                records: reportingRecords,
                breakdown: $0.tokens).processed
        }.max() ?? 0)
        for bucket in buckets {
            let startX = x(for: bucket.start)
            let endX = x(for: bucket.end)
            let width = max(1, endX - startX - 1)
            let anatomy = appKitActivityTokenAnatomy(
                records: tokenRecords(in: bucket, from: reportingRecords),
                breakdown: bucket.tokens)
            let scale = tokenChart.height / CGFloat(maximum)
            var y = tokenChart.maxY
            let segments: [(Int, NSColor, Bool)] = [
                (anatomy.inputRemainder ?? 0,
                 phaseColor(.model).withAlphaComponent(
                    effectiveAppearance.mechanicianIsDark ? 0.80 : 0.92),
                 !anatomy.inputRemainderIsExact),
                (anatomy.plottedCacheRead,
                 appKitAgentActivityCachedInputColor(in: effectiveAppearance),
                 false),
                (anatomy.plottedCacheWrite,
                 phaseColor(.model).withAlphaComponent(0.62),
                 true),
                (anatomy.answerOutput ?? 0,
                 phaseColor(.completed).withAlphaComponent(
                    effectiveAppearance.mechanicianIsDark ? 0.82 : 0.94),
                 false),
                (anatomy.reasoningOutput ?? 0,
                 phaseColor(.completed).withAlphaComponent(0.68),
                 true),
                (anatomy.unclassified ?? 0,
                 waitingSlate.withAlphaComponent(0.72),
                 true),
            ]
            for (amount, color, hatched) in segments where amount > 0 {
                let height = max(0.5, CGFloat(amount) * scale)
                let rect = NSRect(
                    x: startX,
                    y: y - height,
                    width: width,
                    height: height)
                color.setFill()
                rect.fill()
                if hatched { drawHatching(in: rect, color: color) }
                y -= height
            }
        }

        if hasContext {
            let contextChart = NSRect(
                x: fullChart.minX,
                y: tokenChart.maxY + 7,
                width: fullChart.width,
                height: max(24, fullChart.maxY - tokenChart.maxY - 7))
            drawContextPressure(in: contextChart)
        }

        drawText(
            durationLabel(duration),
            rect: NSRect(
                x: fullChart.maxX - 50,
                y: fullChart.maxY + 3,
                width: 50,
                height: 12),
            font: .monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            color: .nChartMuted,
            alignment: .right)
    }

    private var trendsChartRect: NSRect {
        let bottomReserve: CGFloat
        if trendMetric == .runtime {
            bottomReserve = 10
        } else {
            bottomReserve = bounds.width < 480 ? 44 : 26
        }
        let horizontal = trendMetric == .duration || trendMetric == .runtime
            ? NSRect(x: 8, y: 0, width: max(1, bounds.width - 16), height: 1)
            : plotRect
        return NSRect(
            x: horizontal.minX,
            y: 42,
            width: horizontal.width,
            height: max(70, bounds.height - 42 - bottomReserve))
    }

    private func durationTrendPlotRect(in chart: NSRect) -> NSRect {
        let axisGutter = min(48, max(38, chart.width * 0.18))
        return NSRect(
            x: chart.minX + axisGutter,
            y: chart.minY + 7,
            width: max(1, chart.width - axisGutter - 7),
            height: max(12, chart.height - 35))
    }

    private func trendTurnFrames() -> [NSRect] {
        guard let turns = renderModel.input?.trendTurns, !turns.isEmpty else { return [] }
        let chart = trendsChartRect
        let horizontal = trendMetric == .duration ? durationTrendPlotRect(in: chart) : chart
        let width = horizontal.width / CGFloat(turns.count)
        return turns.indices.map { index in
            NSRect(
                x: horizontal.minX + CGFloat(index) * width,
                y: chart.minY,
                width: max(1, width),
                height: chart.height)
        }
    }

    private func trendTurnIndex(at point: NSPoint) -> Int? {
        trendTurnFrames().firstIndex { $0.insetBy(dx: 0, dy: -8).contains(point) }
    }

    private func trendInspectionPoint(for index: Int) -> NSPoint? {
        let frames = trendTurnFrames()
        guard frames.indices.contains(index) else { return nil }
        return NSPoint(x: frames[index].midX, y: trendsChartRect.midY)
    }

    private func drawTrends() {
        if trendMetric == .runtime {
            drawRuntimeTrend()
            return
        }
        guard let turns = renderModel.input?.trendTurns, !turns.isEmpty else {
            drawText(
                String(localized: "No retained turns"),
                rect: NSRect(x: 16, y: 58, width: max(40, bounds.width - 32), height: 16),
                font: .systemFont(ofSize: 10),
                color: .secondaryLabelColor,
                alignment: .center)
            return
        }

        let chart = trendsChartRect
        NSColor.nElevated
            .withAlphaComponent(effectiveAppearance.mechanicianIsDark ? 0.20 : 0.46)
            .setFill()
        NSBezierPath(roundedRect: chart, xRadius: 4, yRadius: 4).fill()

        drawText(
            String(localized: "\(trendMetric.title) · \(turns.count) retained turns"),
            rect: NSRect(x: 9, y: 6, width: max(80, bounds.width - 18), height: 14),
            font: .systemFont(ofSize: 10, weight: .semibold),
            color: .labelColor)
        if trendMetric == .duration {
            drawDurationTrendLegend(hasMissing: turns.contains { $0.ttft == nil })
        } else {
                drawText(
                    trendLegendCopy(turns),
                    rect: NSRect(
                        x: 9,
                        y: 22,
                        width: max(20, bounds.width - 18),
                        height: 12),
                font: .systemFont(ofSize: 8),
                color: .secondaryLabelColor)

            for fraction in [CGFloat(0), 0.5, 1] {
                NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
                NSRect(
                    x: chart.minX,
                    y: chart.maxY - chart.height * fraction,
                    width: chart.width,
                    height: 1).fill()
            }
        }

        let frames = trendTurnFrames()
        if frames.indices.contains(selectedTrendIndex) {
            NSColor.controlAccentColor.withAlphaComponent(0.09).setFill()
            NSBezierPath(
                roundedRect: frames[selectedTrendIndex].insetBy(dx: 1, dy: 1),
                xRadius: 3,
                yRadius: 3).fill()
            NSColor.controlAccentColor.withAlphaComponent(0.34).setStroke()
            let selectionOutline = NSBezierPath(
                roundedRect: frames[selectedTrendIndex].insetBy(dx: 1.5, dy: 1.5),
                xRadius: 3,
                yRadius: 3)
            selectionOutline.lineWidth = 1
            selectionOutline.stroke()
        }
        if window?.firstResponder === self,
           frames.indices.contains(focusedTrendIndex) {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focusOutline = NSBezierPath(
                roundedRect: frames[focusedTrendIndex].insetBy(dx: 3, dy: 3),
                xRadius: 3,
                yRadius: 3)
            focusOutline.lineWidth = 2
            focusOutline.stroke()
        }

        switch trendMetric {
        case .duration:
            drawDurationTrend(turns, frames: frames, chart: chart)
        case .tokens:
            drawTokenTrend(turns, frames: frames, chart: chart)
        case .context:
            drawContextTrend(turns, frames: frames, chart: chart)
        case .reliability:
            drawReliabilityTrend(turns, frames: frames, chart: chart)
        case .runtime:
            break
        }

        if frames.indices.contains(selectedTrendIndex) {
            let selected = turns[selectedTrendIndex]
            if trendMetric == .duration {
                drawDurationSelectedTurn(
                    selected,
                    index: selectedTrendIndex,
                    chart: chart)
            } else {
                drawSelectedTrendTurn(
                    selected,
                    index: selectedTrendIndex,
                    chart: chart)
            }
        }
    }

    private func trendLegendCopy(_ turns: [AppKitAgentActivityTrendTurn]) -> String {
        switch trendMetric {
        case .duration:
            return turns.contains(where: { $0.ttft != nil })
                ? String(localized: "wall duration · time to first output")
                : String(localized: "wall duration · first output not reported")
        case .tokens:
            let hasWrite = turns.contains { $0.tokens.cacheWrite != nil }
            let hasReasoning = turns.contains { $0.tokens.reasoningOutput != nil }
            return [
                String(localized: "fresh/unsplit"),
                String(localized: "cache read"),
                hasWrite ? String(localized: "cache write") : String(localized: "cache write —"),
                String(localized: "answer"),
                hasReasoning ? String(localized: "reasoning") : String(localized: "reasoning —"),
            ].joined(separator: " · ")
        case .context:
            return String(localized: "final fill · peak fill · compaction")
        case .reliability:
            return String(localized: "retry · recovery · withheld · reroute · safety · failed; counts, not a score")
        case .runtime:
            return String(localized: "session-wide harness aggregates; not attributed to a turn")
        }
    }

    private func drawDurationTrendLegend(hasMissing: Bool) {
        let font = NSFont.systemFont(ofSize: 8, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let centerY: CGFloat = 28
        var x: CGFloat = 10

        func drawLabel(_ label: String) {
            let width = ceil((label as NSString).size(withAttributes: attributes).width) + 2
            drawText(
                label,
                rect: NSRect(x: x, y: centerY - 6, width: width, height: 12),
                font: font,
                color: .secondaryLabelColor)
            x += width + 10
        }

        appKitAgentActivityPhaseColor(.model).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: centerY - 3, width: 6, height: 6)).fill()
        x += 9
        drawLabel(String(localized: "Wall"))

        drawTrendDiamond(
            center: NSPoint(x: x + 3, y: centerY),
            color: appKitAgentActivityPhaseColor(.completed),
            radius: 3)
        x += 9
        drawLabel(String(localized: "First output"))

        if hasMissing {
            drawMissingTrendCross(at: NSPoint(x: x + 3, y: centerY))
            x += 9
            drawLabel(String(localized: "Not reported"))
        }
    }

    private func drawDurationSelectedTurn(
        _ turn: AppKitAgentActivityTrendTurn,
        index: Int,
        chart: NSRect
    ) {
        let selected = String(localized: "Selected turn \(index + 1)")
        let timestamp = Self.trendTurnTime.string(from: turn.startedAt)
        let wall = String(localized: "Wall \(durationLabel(turn.duration))")
        let first = turn.ttft.map {
            String(localized: "First output \(durationLabel($0))")
        } ?? String(localized: "First output not reported")
        let route = [turn.providerAccess?.displayName, turn.modelID]
            .compactMap { value in value.flatMap { $0.isEmpty ? nil : $0 } }
            .joined(separator: " · ")
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)

        if bounds.width < 480 {
            drawText(
                "\(selected) · \(timestamp)",
                rect: NSRect(
                    x: chart.minX,
                    y: chart.maxY + 4,
                    width: chart.width,
                    height: 11),
                font: font,
                color: .nChartMuted)
            drawText(
                "\(wall) · \(first)",
                rect: NSRect(
                    x: chart.minX,
                    y: chart.maxY + 16,
                    width: chart.width,
                    height: 11),
                font: font,
                color: .labelColor)
            if !route.isEmpty {
                drawText(
                    route,
                    rect: NSRect(
                        x: chart.minX,
                        y: chart.maxY + 28,
                        width: chart.width,
                        height: 11),
                    font: font,
                    color: .nChartMuted)
            }
        } else {
            let parts = [selected, wall, first, timestamp, route].filter { !$0.isEmpty }
            drawText(
                parts.joined(separator: " · "),
                rect: NSRect(
                    x: chart.minX,
                    y: chart.maxY + 4,
                    width: chart.width,
                    height: 12),
                font: font,
                color: .labelColor)
        }
    }

    private func drawSelectedTrendTurn(
        _ turn: AppKitAgentActivityTrendTurn,
        index: Int,
        chart: NSRect
    ) {
        let selected = String(localized: "Selected turn \(index + 1)")
        let timestamp = Self.trendTurnTime.string(from: turn.startedAt)
        let route = [turn.providerAccess?.displayName, turn.modelID]
            .compactMap { value in value.flatMap { $0.isEmpty ? nil : $0 } }
            .joined(separator: " · ")
        let value: String
        switch trendMetric {
        case .tokens:
            var parts: [String] = []
            if let processed = turn.tokens.processed {
                parts.append(String(localized: "\(formatTokens(processed)) processed"))
            } else {
                parts.append(String(localized: "Tokens not reported"))
            }
            if let input = turn.tokens.inputTotal,
               input > 0,
               let cached = turn.tokens.cacheRead {
                let share = Int((Double(cached) / Double(input) * 100).rounded())
                parts.append(String(localized: "\(share)% from cache"))
            }
            if let generated = turn.tokens.generated {
                parts.append(String(localized: "\(formatTokens(generated)) generated"))
            }
            value = parts.joined(separator: " · ")
        case .context:
            var parts: [String] = []
            if let final = turn.finalContextTokens, let window = turn.contextWindow {
                parts.append(String(localized: "Final \(formatTokens(final))/\(formatTokens(window))"))
            } else {
                parts.append(String(localized: "Context not reported"))
            }
            if let peak = turn.peakContextTokens {
                parts.append(String(localized: "Peak \(formatTokens(peak))"))
            }
            if turn.compactionCount > 0 {
                parts.append(turn.compactionCount == 1
                    ? String(localized: "1 compaction")
                    : String(localized: "\(turn.compactionCount) compactions"))
            }
            value = parts.joined(separator: " · ")
        case .reliability:
            let counts: [(String, Int)] = [
                (String(localized: "retry"), turn.retryCount),
                (String(localized: "recovery"), turn.recoveryCount),
                (String(localized: "withheld"), turn.subtractionCount),
                (String(localized: "reroute"), turn.rerouteCount),
                (String(localized: "safety"), turn.safetyCount),
                (String(localized: "failed"), turn.failureCount),
            ]
            let reported = counts.filter { $0.1 > 0 }.map { "\($0.1) \($0.0)" }
            value = reported.isEmpty
                ? String(localized: "No recorded events")
                : reported.joined(separator: " · ")
        case .duration, .runtime:
            return
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)
        if bounds.width < 480 {
            drawText(
                "\(selected) · \(timestamp)",
                rect: NSRect(
                    x: chart.minX,
                    y: chart.maxY + 4,
                    width: chart.width,
                    height: 11),
                font: font,
                color: .nChartMuted)
            drawText(
                value,
                rect: NSRect(
                    x: chart.minX,
                    y: chart.maxY + 16,
                    width: chart.width,
                    height: 11),
                font: font,
                color: .labelColor)
            if !route.isEmpty {
                drawText(
                    route,
                    rect: NSRect(
                        x: chart.minX,
                        y: chart.maxY + 28,
                        width: chart.width,
                        height: 11),
                    font: font,
                    color: .nChartMuted)
            }
        } else {
            drawText(
                [selected, value, timestamp, route].filter { !$0.isEmpty }
                    .joined(separator: " · "),
                rect: NSRect(
                    x: chart.minX,
                    y: chart.maxY + 4,
                    width: chart.width,
                    height: 12),
                font: font,
                color: .labelColor)
        }
    }

    private func trendY(_ value: TimeInterval, maximum: TimeInterval, chart: NSRect) -> CGFloat {
        let fraction = maximum > 0 ? min(1, max(0, value / maximum)) : 0
        return chart.maxY - chart.height * CGFloat(fraction)
    }

    private func drawDurationTrend(
        _ turns: [AppKitAgentActivityTrendTurn],
        frames: [NSRect],
        chart: NSRect
    ) {
        let plot = durationTrendPlotRect(in: chart)
        let observedMaximum = turns.map { max($0.duration, $0.ttft ?? 0) }.max() ?? 0
        let scale = AppKitDurationTrendScale(observedMaximum: observedMaximum)

        for tick in scale.ticks {
            let y = trendY(tick, maximum: scale.maximum, chart: plot)
            NSColor.secondaryLabelColor
                .withAlphaComponent(tick == 0 ? 0.28 : 0.13)
                .setFill()
            NSRect(x: plot.minX, y: y - 0.5, width: plot.width, height: 1).fill()
            drawText(
                scale.label(for: tick),
                rect: NSRect(
                    x: chart.minX + 2,
                    y: y - 6,
                    width: max(8, plot.minX - chart.minX - 8),
                    height: 12),
                font: .monospacedDigitSystemFont(ofSize: 8, weight: .regular),
                color: .nChartMuted,
                alignment: .right)
        }

        for (index, turn) in turns.enumerated() where frames.indices.contains(index) {
            let x = frames[index].midX
            let totalY = trendY(turn.duration, maximum: scale.maximum, chart: plot)
            NSColor.secondaryLabelColor.withAlphaComponent(0.45).setStroke()
            let stem = NSBezierPath()
            stem.move(to: NSPoint(x: x, y: plot.maxY))
            stem.line(to: NSPoint(x: x, y: totalY))
            stem.lineWidth = max(1, min(3, frames[index].width * 0.14))
            stem.stroke()
            appKitAgentActivityPhaseColor(.model).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 3, y: totalY - 3, width: 6, height: 6)).fill()
            if let ttft = turn.ttft {
                let ttftY = trendY(ttft, maximum: scale.maximum, chart: plot)
                drawTrendDiamond(
                    center: NSPoint(x: x, y: ttftY),
                    color: appKitAgentActivityPhaseColor(.completed),
                    radius: 3)
            } else {
                // Absence has no quantitative y-position. Keep it below the zero baseline so it
                // cannot be mistaken for a fast zero or a near-maximum observation.
                drawMissingTrendCross(at: NSPoint(x: x, y: plot.maxY + 8))
            }
        }

        let crossesDay = turns.first.map { first in
            turns.last.map { !Calendar.current.isDate(first.startedAt, inSameDayAs: $0.startedAt) }
                ?? false
        } ?? false
        let minimumSpacing: CGFloat = crossesDay ? 78 : 54
        let labelIndices = appKitDurationTrendTimeLabelIndices(
            turnCount: turns.count,
            columnWidth: frames.first?.width ?? plot.width,
            selectedIndex: selectedTrendIndex,
            minimumSpacing: minimumSpacing)
        let labelWidth = min(minimumSpacing, plot.width)
        for index in labelIndices where turns.indices.contains(index) && frames.indices.contains(index) {
            let alignment: NSTextAlignment
            let x: CGFloat
            if index == 0 {
                alignment = .left
                x = plot.minX
            } else if index == turns.count - 1 {
                alignment = .right
                x = plot.maxX - labelWidth
            } else {
                alignment = .center
                x = frames[index].midX - labelWidth / 2
            }
            let formatter = crossesDay ? Self.trendTurnAxisDayAndTime : Self.trendTurnAxisTime
            drawText(
                formatter.string(from: turns[index].startedAt),
                rect: NSRect(x: x, y: plot.maxY + 14, width: labelWidth, height: 10),
                font: .monospacedDigitSystemFont(
                    ofSize: 7,
                    weight: index == selectedTrendIndex ? .semibold : .regular),
                color: index == selectedTrendIndex ? .labelColor : .nChartMuted,
                alignment: alignment)
        }
    }

    private func drawTokenTrend(
        _ turns: [AppKitAgentActivityTrendTurn],
        frames: [NSRect],
        chart: NSRect
    ) {
        let maximum = max(1, turns.compactMap { $0.tokens.processed }.max() ?? 0)
        for (index, turn) in turns.enumerated() where frames.indices.contains(index) {
            guard let processed = turn.tokens.processed else {
                drawNotReportedMark(at: NSPoint(x: frames[index].midX, y: chart.midY))
                continue
            }
            let width = max(1, min(18, frames[index].width - 3))
            let scale = processed > 0
                ? chart.height * CGFloat(processed) / CGFloat(maximum) / CGFloat(processed)
                : 0
            var y = chart.maxY
            let segments: [(Int, NSColor, Bool)] = [
                (turn.tokens.inputRemainder ?? 0,
                 appKitAgentActivityPhaseColor(.model),
                 !turn.tokens.inputRemainderIsExact),
                (turn.tokens.plottedCacheRead,
                 appKitAgentActivityCachedInputColor(in: effectiveAppearance),
                 false),
                (turn.tokens.plottedCacheWrite,
                 appKitAgentActivityPhaseColor(.model).withAlphaComponent(0.62),
                 true),
                (turn.tokens.answerOutput ?? 0,
                 appKitAgentActivityPhaseColor(.completed),
                 false),
                (turn.tokens.reasoningOutput ?? 0,
                 appKitAgentActivityPhaseColor(.completed).withAlphaComponent(0.68),
                 true),
                (turn.tokens.unclassified ?? 0,
                 waitingSlate.withAlphaComponent(0.72),
                 true),
            ]
            for (amount, color, hatched) in segments where amount > 0 {
                let height = max(0.5, CGFloat(amount) * scale)
                let rect = NSRect(
                    x: frames[index].midX - width / 2,
                    y: y - height,
                    width: width,
                    height: height)
                color.setFill()
                rect.fill()
                if hatched { drawHatching(in: rect, color: color) }
                y -= height
            }
            if processed == 0 {
                NSColor.secondaryLabelColor.setFill()
                NSRect(x: frames[index].midX - width / 2, y: chart.maxY - 1, width: width, height: 1).fill()
            }
        }
    }

    private func drawContextTrend(
        _ turns: [AppKitAgentActivityTrendTurn],
        frames: [NSRect],
        chart: NSRect
    ) {
        for (index, turn) in turns.enumerated() where frames.indices.contains(index) {
            let x = frames[index].midX
            guard let window = turn.contextWindow, window > 0,
                  let final = turn.finalContextTokens else {
                drawNotReportedMark(at: NSPoint(x: x, y: chart.midY))
                continue
            }
            let peak = max(final, turn.peakContextTokens ?? final)
            let finalY = chart.maxY - chart.height
                * CGFloat(min(1, Double(final) / Double(window)))
            let peakY = chart.maxY - chart.height
                * CGFloat(min(1, Double(peak) / Double(window)))
            let range = NSBezierPath()
            range.move(to: NSPoint(x: x, y: finalY))
            range.line(to: NSPoint(x: x, y: peakY))
            range.lineWidth = 2
            appKitAgentActivityContextColor().withAlphaComponent(0.65).setStroke()
            range.stroke()
            appKitAgentActivityContextColor().setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 2.5, y: finalY - 2.5, width: 5, height: 5)).fill()
            if peak != final {
                appKitAgentActivityContextColor().withAlphaComponent(0.55).setFill()
                NSBezierPath(ovalIn: NSRect(x: x - 2, y: peakY - 2, width: 4, height: 4)).fill()
            }
            if turn.compactionCount > 0 {
                drawTrendTriangle(
                    center: NSPoint(x: x, y: chart.maxY - 5),
                    color: appKitAgentActivityPhaseColor(.compacting))
            }
        }
    }

    private func drawReliabilityTrend(
        _ turns: [AppKitAgentActivityTrendTurn],
        frames: [NSRect],
        chart: NSRect
    ) {
        let rows: [(String, (AppKitAgentActivityTrendTurn) -> Int, NSColor)] = [
            (String(localized: "RETRY"), { $0.retryCount }, appKitAgentActivityPhaseColor(.stopped)),
            (String(localized: "RECOVERY"), { $0.recoveryCount }, appKitAgentActivityPhaseColor(.stopped)),
            (String(localized: "WITHHELD"), { $0.subtractionCount }, appKitAgentActivityPhaseColor(.waiting)),
            (String(localized: "REROUTE"), { $0.rerouteCount }, appKitAgentActivityPhaseColor(.model)),
            (String(localized: "SAFETY"), { $0.safetyCount }, appKitAgentActivityPhaseColor(.stopped)),
            (String(localized: "FAILED"), { $0.failureCount }, appKitAgentActivityPhaseColor(.failed)),
        ]
        let rowHeight = chart.height / CGFloat(rows.count)
        for (row, item) in rows.enumerated() {
            let y = chart.minY + (CGFloat(row) + 0.5) * rowHeight
            drawText(
                item.0,
                rect: NSRect(
                    x: viewportRect.minX,
                    y: y - 6,
                    width: labelWidth - 8,
                    height: 12),
                font: TraceLayout.railTitleFont,
                color: .nChartMuted,
                alignment: .right)
            NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
            NSRect(x: chart.minX, y: y, width: chart.width, height: 1).fill()
            for (index, turn) in turns.enumerated() where frames.indices.contains(index) {
                let count = item.1(turn)
                guard count > 0 else { continue }
                item.2.setFill()
                let size: CGFloat = count > 1 ? 8 : 6
                NSBezierPath(
                    roundedRect: NSRect(
                        x: frames[index].midX - size / 2,
                        y: y - size / 2,
                        width: size,
                        height: size),
                    xRadius: count > 1 ? 2 : 3,
                    yRadius: count > 1 ? 2 : 3).fill()
                if count > 1 {
                    drawText(
                        "\(count)",
                        rect: NSRect(x: frames[index].midX - 8, y: y - 5, width: 16, height: 10),
                        font: .monospacedDigitSystemFont(ofSize: 7, weight: .bold),
                        color: .white,
                        alignment: .center)
                }
            }
        }
    }

    private struct RuntimeMetricLayout {
        var harnessTitle: String
        var sample: HarnessMetricSample
        var presentation: AppKitRuntimeMetricPresentation
        var frame: NSRect
    }

    private struct RuntimeMetricGroupLayout {
        var group: AppKitHarnessRuntimeMetricGroup
        var frame: NSRect
        var metrics: [RuntimeMetricLayout]
    }

    private var runtimeLayoutCacheSamples: [HarnessMetricSample]?
    private var runtimeLayoutCacheSize: NSSize = .zero
    private var runtimeLayoutCacheGroups: [RuntimeMetricGroupLayout] = []

    private func runtimeMetricGrid(
        width: CGFloat,
        groupCount: Int
    ) -> (columns: Int, columnWidth: CGFloat, rowHeight: CGFloat) {
        let columns = width >= 620 ? min(2, max(1, groupCount)) : 1
        let gap: CGFloat = 10
        let columnWidth = max(1, (width - gap * CGFloat(columns - 1)) / CGFloat(columns))
        return (columns, columnWidth, columnWidth < 280 ? 46 : 40)
    }

    private func runtimeMetricRequiredHeight(documentWidth: CGFloat) -> CGFloat {
        let groups = appKitHarnessRuntimeMetricGroups(
            renderModel.input?.runtimeSamples ?? [])
        guard !groups.isEmpty else { return 230 }
        let width = max(1, documentWidth - 16)
        let grid = runtimeMetricGrid(width: width, groupCount: groups.count)
        let headerHeight: CGFloat = 34
        let sectionPadding: CGFloat = 8
        let rowGap: CGFloat = 10
        var contentHeight: CGFloat = 0
        for start in stride(from: 0, to: groups.count, by: grid.columns) {
            let end = min(groups.count, start + grid.columns)
            let height = groups[start..<end].map {
                headerHeight + CGFloat($0.samples.count) * grid.rowHeight + sectionPadding
            }.max() ?? 0
            if contentHeight > 0 { contentHeight += rowGap }
            contentHeight += height
        }
        return max(230, 50 + contentHeight + 10)
    }

    private func runtimeMetricGroupLayouts() -> [RuntimeMetricGroupLayout] {
        let samples = renderModel.input?.runtimeSamples ?? []
        if runtimeLayoutCacheSamples == samples,
           abs(runtimeLayoutCacheSize.width - bounds.width) < 0.5,
           abs(runtimeLayoutCacheSize.height - bounds.height) < 0.5 {
            return runtimeLayoutCacheGroups
        }
        let groups = appKitHarnessRuntimeMetricGroups(samples)
        guard !groups.isEmpty else {
            runtimeLayoutCacheSamples = samples
            runtimeLayoutCacheSize = bounds.size
            runtimeLayoutCacheGroups = []
            return []
        }
        let chart = trendsChartRect
        let grid = runtimeMetricGrid(width: chart.width, groupCount: groups.count)
        let columnGap: CGFloat = 10
        let rowGap: CGFloat = 10
        let headerHeight: CGFloat = 34
        var result: [RuntimeMetricGroupLayout] = []
        var y = chart.minY
        for start in stride(from: 0, to: groups.count, by: grid.columns) {
            let end = min(groups.count, start + grid.columns)
            let rowGroups = Array(groups[start..<end])
            let heights = rowGroups.map {
                headerHeight + CGFloat($0.samples.count) * grid.rowHeight + 8
            }
            let rowHeight = heights.max() ?? 0
            for (column, group) in rowGroups.enumerated() {
                let groupHeight = heights[column]
                let frame = NSRect(
                    x: chart.minX + CGFloat(column) * (grid.columnWidth + columnGap),
                    y: y,
                    width: grid.columnWidth,
                    height: groupHeight)
                let metrics = group.samples.enumerated().map { rowIndex, sample in
                    RuntimeMetricLayout(
                        harnessTitle: group.title,
                        sample: sample,
                        presentation: appKitRuntimeMetricPresentation(sample),
                        frame: NSRect(
                            x: frame.minX + 7,
                            y: frame.minY + headerHeight + CGFloat(rowIndex) * grid.rowHeight,
                            width: max(1, frame.width - 14),
                            height: grid.rowHeight - 5))
                }
                result.append(RuntimeMetricGroupLayout(
                    group: group,
                    frame: frame,
                    metrics: metrics))
            }
            y += rowHeight + rowGap
        }
        runtimeLayoutCacheSamples = samples
        runtimeLayoutCacheSize = bounds.size
        runtimeLayoutCacheGroups = result
        return result
    }

    private func runtimeMetricLayouts() -> [RuntimeMetricLayout] {
        runtimeMetricGroupLayouts().flatMap(\.metrics)
    }

    private func runtimeMetricInspectionPoint(for index: Int) -> NSPoint? {
        let layouts = runtimeMetricLayouts()
        guard layouts.indices.contains(index) else { return nil }
        return NSPoint(x: layouts[index].frame.midX, y: layouts[index].frame.midY)
    }

    private func drawRuntimeTrend() {
        let chart = trendsChartRect
        NSColor.nElevated
            .withAlphaComponent(effectiveAppearance.mechanicianIsDark ? 0.20 : 0.46)
            .setFill()
        NSBezierPath(roundedRect: chart, xRadius: 4, yRadius: 4).fill()
        drawText(
            String(localized: "Harness metrics"),
            rect: NSRect(x: 9, y: 6, width: max(80, bounds.width - 18), height: 14),
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: .labelColor)
        drawText(
            String(localized: "Latest session-wide provider aggregates · not attributed to a turn"),
            rect: NSRect(x: 9, y: 22, width: max(40, bounds.width - 18), height: 13),
            font: .systemFont(ofSize: 9),
            color: .secondaryLabelColor)

        let groupLayouts = runtimeMetricGroupLayouts()
        guard !groupLayouts.isEmpty else {
            drawText(
                String(localized: "Harness metrics not reported for this session"),
                rect: chart.insetBy(dx: 12, dy: 12),
                font: .systemFont(ofSize: 10),
                color: .secondaryLabelColor,
                alignment: .center)
            return
        }

        let flattened = groupLayouts.flatMap(\.metrics)
        let metricIndexByID = Dictionary(
            flattened.enumerated().map { ($0.element.sample.id, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        for groupLayout in groupLayouts {
            guard needsToDraw(groupLayout.frame) else { continue }
            let group = groupLayout.group
            NSColor.controlBackgroundColor
                .withAlphaComponent(effectiveAppearance.mechanicianIsDark ? 0.34 : 0.58)
                .setFill()
            NSBezierPath(
                roundedRect: groupLayout.frame,
                xRadius: 6,
                yRadius: 6).fill()
            NSColor.separatorColor.withAlphaComponent(0.38).setStroke()
            let outline = NSBezierPath(
                roundedRect: groupLayout.frame.insetBy(dx: 0.5, dy: 0.5),
                xRadius: 6,
                yRadius: 6)
            outline.lineWidth = 1
            outline.stroke()

            let providerColor: NSColor = group.laneID == .codex
                ? appKitAgentActivityPhaseColor(.completed)
                : appKitAgentActivityPhaseColor(.model)
            providerColor.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: groupLayout.frame.minX + 9,
                y: groupLayout.frame.minY + 9,
                width: 6,
                height: 6)).fill()
            drawText(
                group.title,
                rect: NSRect(
                    x: groupLayout.frame.minX + 19,
                    y: groupLayout.frame.minY + 5,
                    width: max(20, groupLayout.frame.width - 28),
                    height: 13),
                font: .systemFont(ofSize: 10, weight: .semibold),
                color: .labelColor)
            let latest = group.samples.map(\.at).max().map {
                appKitRuntimeCompactTimestamp.string(from: $0)
            } ?? String(localized: "Not reported")
            drawText(
                String(localized: "\(group.samples.count) metrics · updated \(latest)"),
                rect: NSRect(
                    x: groupLayout.frame.minX + 9,
                    y: groupLayout.frame.minY + 19,
                    width: max(20, groupLayout.frame.width - 18),
                    height: 11),
                font: .systemFont(ofSize: 8),
                color: .secondaryLabelColor)

            for layout in groupLayout.metrics {
                guard needsToDraw(layout.frame) else { continue }
                let index = metricIndexByID[layout.sample.id] ?? -1
                drawRuntimeMetric(
                    layout,
                    focused: index == focusedRuntimeMetricIndex
                        && (window?.firstResponder === self || pinnedPoint != nil))
            }
        }
    }

    private func drawRuntimeMetric(_ layout: RuntimeMetricLayout, focused: Bool) {
        let sample = layout.sample
        let presentation = layout.presentation
        let row = layout.frame
        let color: NSColor = switch sample.kind {
        case .counter: appKitAgentActivityPhaseColor(.model)
        case .gauge: appKitAgentActivityPhaseColor(.completed)
        case .histogram: appKitAgentActivityPhaseColor(.stopped)
        }
        NSColor.textBackgroundColor
            .withAlphaComponent(effectiveAppearance.mechanicianIsDark ? 0.32 : 0.72)
            .setFill()
        NSBezierPath(roundedRect: row, xRadius: 4, yRadius: 4).fill()
        color.withAlphaComponent(0.86).setFill()
        NSBezierPath(
            roundedRect: NSRect(
                x: row.minX,
                y: row.minY + 4,
                width: 3,
                height: max(1, row.height - 8)),
            xRadius: 1.5,
            yRadius: 1.5).fill()

        let textLayout = appKitRuntimeMetricTextLayout(
            in: row,
            presentation: presentation)
        drawText(
            presentation.title,
            rect: textLayout.title,
            font: .systemFont(ofSize: 9.5, weight: .semibold),
            color: .labelColor)
        drawText(
            presentation.value,
            rect: textLayout.value,
            font: .monospacedDigitSystemFont(ofSize: 9, weight: .medium),
            color: .labelColor,
            alignment: .right)
        drawText(
            presentation.detail,
            rect: textLayout.detail,
            font: .systemFont(ofSize: 8),
            color: .secondaryLabelColor)

        if sample.kind == .histogram,
           let minimum = sample.min,
           let maximum = sample.max {
            let lower = min(0, minimum)
            let upper = max(0, maximum)
            let scale = max(0.000_001, upper - lower)
            let rail = NSRect(
                x: row.minX + 7,
                y: row.maxY - 5,
                width: max(1, row.width - 14),
                height: 2)
            NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
            rail.fill()
            let minX = rail.minX + rail.width * CGFloat((minimum - lower) / scale)
            let maxX = rail.minX + rail.width * CGFloat((maximum - lower) / scale)
            color.withAlphaComponent(0.70).setFill()
            NSRect(x: minX, y: rail.minY, width: max(1, maxX - minX), height: rail.height).fill()
            if let mean = runtimeMetricMean(sample) {
                let fraction = min(1, max(0, (mean - lower) / scale))
                let meanX = rail.minX + rail.width * CGFloat(fraction)
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: meanX - 2, y: rail.midY - 2, width: 4, height: 4)).fill()
            }
        }
        if focused {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(
                roundedRect: row.insetBy(dx: 1.5, dy: 1.5),
                xRadius: 4,
                yRadius: 4)
            focus.lineWidth = 2
            focus.stroke()
        }
    }

    private func runtimeMetricMean(_ sample: HarnessMetricSample) -> Double? {
        if let count = sample.count, count > 0, let sum = sample.sum {
            return sum / Double(count)
        }
        return sample.value
    }

    private func drawNotReportedMark(at point: NSPoint) {
        NSColor.tertiaryLabelColor.setFill()
        NSRect(x: point.x - 3, y: point.y - 0.5, width: 6, height: 1).fill()
    }

    private func drawMissingTrendCross(at point: NSPoint) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: point.x - 2.5, y: point.y - 2.5))
        path.line(to: NSPoint(x: point.x + 2.5, y: point.y + 2.5))
        path.move(to: NSPoint(x: point.x + 2.5, y: point.y - 2.5))
        path.line(to: NSPoint(x: point.x - 2.5, y: point.y + 2.5))
        path.lineWidth = 1.2
        NSColor.tertiaryLabelColor.setStroke()
        path.stroke()
    }

    private func drawTrendDiamond(center: NSPoint, color: NSColor, radius: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x, y: center.y - radius))
        path.line(to: NSPoint(x: center.x + radius, y: center.y))
        path.line(to: NSPoint(x: center.x, y: center.y + radius))
        path.line(to: NSPoint(x: center.x - radius, y: center.y))
        path.close()
        color.setFill()
        path.fill()
    }

    private func drawTrendTriangle(center: NSPoint, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x, y: center.y - 4))
        path.line(to: NSPoint(x: center.x + 4, y: center.y + 3))
        path.line(to: NSPoint(x: center.x - 4, y: center.y + 3))
        path.close()
        color.setFill()
        path.fill()
    }

    private func drawHatching(in rect: NSRect, color: NSColor) {
        guard rect.width > 1, rect.height > 1 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: rect).addClip()
        let lines = NSBezierPath()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            lines.move(to: NSPoint(x: x, y: rect.maxY))
            lines.line(to: NSPoint(x: x + rect.height, y: rect.minY))
            x += 5
        }
        lines.lineWidth = 0.7
        NSColor.labelColor.withAlphaComponent(0.38).setStroke()
        lines.stroke()
        color.withAlphaComponent(0.55).setStroke()
        NSBezierPath(rect: rect.insetBy(dx: 0.25, dy: 0.25)).stroke()
    }

    private static let trendTurnTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let trendTurnAxisTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let trendTurnAxisDayAndTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private func drawContextPressure(in chart: NSRect) {
        let series = renderModel.contextSeries
        guard !series.samples.isEmpty, series.scaleMaximum > 0 else { return }
        NSColor.nElevated
            .withAlphaComponent(effectiveAppearance.mechanicianIsDark ? 0.20 : 0.46)
            .setFill()
        NSBezierPath(roundedRect: chart, xRadius: 4, yRadius: 4).fill()
        drawText(
            "Root context",
            rect: NSRect(x: 8, y: chart.midY - 8, width: labelWidth - 14, height: 17),
            font: .systemFont(ofSize: 9, weight: .medium),
            color: .secondaryLabelColor)

        func contextY(_ tokens: Int) -> CGFloat {
            let fraction = min(1, max(0, CGFloat(tokens) / CGFloat(series.scaleMaximum)))
            return chart.maxY - chart.height * fraction
        }
        let firstDate = series.samples.first!.at
        let lastDate = series.samples.last!.at
        let sampleDuration = max(1, lastDate.timeIntervalSince(firstDate))
        let paddedStart = firstDate.addingTimeInterval(-sampleDuration * 0.025)
        let paddedEnd = lastDate.addingTimeInterval(sampleDuration * 0.025)
        let paddedDuration = max(1, paddedEnd.timeIntervalSince(paddedStart))
        func contextX(_ date: Date) -> CGFloat {
            let fraction = date.timeIntervalSince(paddedStart) / paddedDuration
            return chart.minX + chart.width * CGFloat(min(1, max(0, fraction)))
        }

        let line = NSBezierPath()
        for (index, sample) in series.samples.enumerated() {
            let point = NSPoint(x: contextX(sample.at), y: contextY(sample.tokens))
            if index == 0 {
                line.move(to: point)
            } else {
                // Context samples are snapshots, not evidence of a continuous ramp. Hold the
                // previous value until the next sample and then change vertically.
                line.line(to: NSPoint(x: point.x, y: line.currentPoint.y))
                line.line(to: point)
            }
        }
        if let first = series.samples.first, let last = series.samples.last {
            let fill = line.copy() as! NSBezierPath
            fill.line(to: NSPoint(x: contextX(last.at), y: chart.maxY))
            fill.line(to: NSPoint(x: contextX(first.at), y: chart.maxY))
            fill.close()
            appKitAgentActivityContextColor().withAlphaComponent(0.13).setFill()
            fill.fill()
        }
        line.lineWidth = 1.4
        appKitAgentActivityContextColor().withAlphaComponent(0.85).setStroke()
        line.stroke()

        if let last = series.samples.last {
            let dot = NSRect(
                x: contextX(last.at) - 2.5,
                y: contextY(last.tokens) - 2.5,
                width: 5,
                height: 5)
            appKitAgentActivityContextColor().setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        for date in series.compactionDates {
            guard date >= paddedStart, date <= paddedEnd else { continue }
            let marker = NSBezierPath()
            marker.move(to: NSPoint(x: contextX(date), y: chart.minY))
            marker.line(to: NSPoint(x: contextX(date), y: chart.maxY))
            marker.lineWidth = 1
            marker.setLineDash([2, 2], count: 2, phase: 0)
            appKitAgentActivityPhaseColor(.compacting).withAlphaComponent(0.88).setStroke()
            marker.stroke()
        }

        let value: String
        if let latest = series.latestTokens, let window = series.reportedWindow {
            value = "\(formatTokens(latest))/\(formatTokens(window))"
                + (series.headroom.map { " · \(formatTokens($0)) free" } ?? "")
        } else if let latest = series.latestTokens {
            value = "\(formatTokens(latest)) · window not reported"
        } else {
            value = "—"
        }
        drawText(
            value,
            rect: NSRect(x: chart.maxX - 145, y: chart.minY + 3, width: 139, height: 12),
            font: .monospacedDigitSystemFont(ofSize: 8, weight: .medium),
            color: .secondaryLabelColor,
            alignment: .right)
    }

    private func drawUsageLegend() {
        let anatomy = appKitActivityTokenAnatomy(records: usageReportingRecords)
        drawText(
            String(localized: "INPUT"),
            rect: NSRect(x: 9, y: 6, width: 42, height: 12),
            font: .systemFont(ofSize: 8, weight: .bold),
            color: .nChartMuted)
        drawLegendSwatch(
            anatomy.inputRemainderIsExact
                ? String(localized: "fresh") : String(localized: "fresh/unsplit"),
            color: appKitAgentActivityPhaseColor(.model),
            x: 48,
            y: 8)
        drawLegendSwatch(
            anatomy.cacheRead == nil
                ? String(localized: "read —") : String(localized: "cache read"),
            color: anatomy.cacheRead == nil
                ? .tertiaryLabelColor
                : appKitAgentActivityCachedInputColor(in: effectiveAppearance),
            x: 132,
            y: 8)
        drawLegendSwatch(
            anatomy.cacheWrite == nil
                ? String(localized: "write —") : String(localized: "cache write"),
            color: anatomy.cacheWrite == nil
                ? .tertiaryLabelColor
                : appKitAgentActivityPhaseColor(.model).withAlphaComponent(0.62),
            x: 210,
            y: 8,
            hatched: anatomy.cacheWrite != nil)
        drawText(
            String(localized: "OUTPUT"),
            rect: NSRect(x: 9, y: 24, width: 42, height: 12),
            font: .systemFont(ofSize: 8, weight: .bold),
            color: .nChartMuted)
        drawLegendSwatch(
            anatomy.answerOutput == nil
                ? String(localized: "answer —") : String(localized: "answer"),
            color: anatomy.answerOutput == nil
                ? .tertiaryLabelColor
                : appKitAgentActivityPhaseColor(.completed),
            x: 48,
            y: 26)
        drawLegendSwatch(
            anatomy.reasoningOutput == nil
                ? String(localized: "reasoning —") : String(localized: "reasoning"),
            color: anatomy.reasoningOutput == nil
                ? .tertiaryLabelColor
                : appKitAgentActivityPhaseColor(.completed).withAlphaComponent(0.68),
            x: 132,
            y: 26,
            hatched: anatomy.reasoningOutput != nil)
        if anatomy.unclassified != nil {
            drawLegendSwatch(
                String(localized: "unclassified"),
                color: waitingSlate.withAlphaComponent(0.72),
                x: 220,
                y: 26,
                hatched: true)
        }
    }

    private var usageReportingRecords: [AgentActivityRecord] {
        guard let input = renderModel.input else { return [] }
        guard let selected = renderModel.usageAgentID else { return input.records }
        return input.records.filter {
            (input.aliases[$0.agentID] ?? $0.agentID) == selected
        }
    }

    private func tokenRecords(
        in bucket: AgentActivityUsageBucket,
        from records: [AgentActivityRecord]
    ) -> [AgentActivityRecord] {
        agentActivityEffectiveTokenRecords(records).filter {
            $0.kind == .tokens && $0.at >= bucket.start && $0.at < bucket.end
        }
    }

    private func drawLegendSwatch(
        _ title: String,
        color: NSColor,
        x: CGFloat,
        y: CGFloat,
        hatched: Bool = false
    ) {
        color.setFill()
        let swatch = NSRect(x: x, y: y + 2, width: 8, height: 5)
        swatch.fill()
        if hatched { drawHatching(in: swatch, color: color) }
        drawText(
            title,
            rect: NSRect(x: x + 11, y: y - 2, width: 76, height: 13),
            font: .systemFont(ofSize: 8),
            color: .secondaryLabelColor)
    }

    private struct InspectionOverlayLayout {
        var isRuntimeMetricGrid: Bool
        var viewport: NSRect
        var leftEdge: CGFloat
        var inspectionX: CGFloat
        var lineStart: CGFloat
        var lineEnd: CGFloat
        var lines: [String]
        var box: NSRect
        var dismissRect: NSRect?
    }

    private func currentInspectionOverlayLayout() -> InspectionOverlayLayout? {
        let runtime = mode == .trends && trendMetric == .runtime
        let viewport = viewportRect
        let content = runtime ? trendsChartRect : plotRect
        let leftEdge = runtime
            ? max(content.minX, viewport.minX)
            : max(content.minX, viewport.minX + labelWidth)
        guard let point = pinnedPoint ?? hoverPoint,
              point.x >= leftEdge,
              point.x <= min(content.maxX, viewport.maxX) else { return nil }
        let inspectionX = min(content.maxX, max(content.minX, point.x))
        let lines = inspectionLines(at: point)
        guard !lines.isEmpty else { return nil }

        let titleFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let bodyFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let widest = lines.enumerated().map { index, line in
            ceil((line as NSString)
                .size(withAttributes: [.font: index == 0 ? titleFont : bodyFont]).width)
        }.max() ?? 0
        let width = min(300, max(140, widest + 20))
        let lineHeight: CGFloat = 14
        let height = 10 + CGFloat(lines.count) * lineHeight
        let boxX = min(
            viewport.maxX - width - 5,
            max(leftEdge + 5, inspectionX - width / 2))
        let box = NSRect(
            x: boxX,
            y: viewport.minY + 20,
            width: width,
            height: height)
        let dismissRect = pinnedPoint == nil ? nil : NSRect(
            x: box.maxX - 20,
            y: box.minY + 4,
            width: 16,
            height: 16)
        return InspectionOverlayLayout(
            isRuntimeMetricGrid: runtime,
            viewport: viewport,
            leftEdge: leftEdge,
            inspectionX: inspectionX,
            lineStart: runtime
                ? max(content.minY, viewport.minY)
                : TraceLayout.eventRailHeight,
            lineEnd: runtime
                ? min(content.maxY, viewport.maxY)
                : bounds.height - 3,
            lines: lines,
            box: box,
            dismissRect: dismissRect)
    }

    var hasVisibleInspectionForTesting: Bool {
        currentInspectionOverlayLayout() != nil
    }

    var drawsInspectionTrackingLineForTesting: Bool {
        guard let layout = currentInspectionOverlayLayout() else { return false }
        return !layout.isRuntimeMetricGrid
    }

    var inspectionDismissRectForTesting: NSRect? {
        currentInspectionOverlayLayout()?.dismissRect
    }

    var runtimeMetricFramesForTesting: [NSRect] {
        runtimeMetricLayouts().map(\.frame)
    }

    fileprivate func drawInspection() {
        guard let layout = currentInspectionOverlayLayout() else { return }
        // Clip to the plot. The lane gutter is frozen chrome drawn under this overlay, so an
        // unclipped scrub line drew straight through the agent names and their metrics.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: NSRect(
            x: layout.leftEdge,
            y: layout.viewport.minY,
            width: max(0, layout.viewport.maxX - layout.leftEdge),
            height: layout.viewport.height)).addClip()
        // Harness metrics are a card grid, not a time axis. A vertical crosshair through the rows
        // implied a relationship between their x positions that does not exist.
        if !layout.isRuntimeMetricGrid {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: layout.inspectionX, y: layout.lineStart))
            path.line(to: NSPoint(x: layout.inspectionX, y: layout.lineEnd))
            path.lineWidth = pinnedPoint == nil ? 0.8 : 1.2
            NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
            path.stroke()
        }

        // The readout used to be one line restating the bar already under the cursor, while the
        // span's whole token breakdown, its tool names and its merge count sat unused in the same
        // scope. It is now a small record of what actually happened at this instant.
        let titleFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let bodyFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let lineHeight: CGFloat = 14
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        let boxPath = NSBezierPath(roundedRect: layout.box, xRadius: 6, yRadius: 6)
        boxPath.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
        boxPath.lineWidth = 0.7
        boxPath.stroke()

        for (index, line) in layout.lines.enumerated() {
            let trailingInset: CGFloat = index == 0 && layout.dismissRect != nil ? 30 : 10
            drawText(
                line,
                rect: NSRect(
                    x: layout.box.minX + 10,
                    y: layout.box.minY + 5 + CGFloat(index) * lineHeight,
                    width: layout.box.width - 10 - trailingInset,
                    height: lineHeight),
                font: index == 0 ? titleFont : bodyFont,
                color: index == 0 ? .labelColor : .secondaryLabelColor)
        }
        if let dismissRect = layout.dismissRect {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(ovalIn: dismissRect).fill()
            let glyph = dismissRect.insetBy(dx: 5, dy: 5)
            let path = NSBezierPath()
            path.move(to: glyph.origin)
            path.line(to: NSPoint(x: glyph.maxX, y: glyph.maxY))
            path.move(to: NSPoint(x: glyph.maxX, y: glyph.minY))
            path.line(to: NSPoint(x: glyph.minX, y: glyph.maxY))
            path.lineWidth = 1.2
            NSColor.secondaryLabelColor.setStroke()
            path.stroke()
        }
    }

    /// The same complete text the hover and pinned-keyboard inspection render. Kept internal so the
    /// render contract can verify that a title hidden on a narrow mark remains inspectable.
    func inspectionLines(at point: NSPoint) -> [String] {
        let inspectionX = min(plotRect.maxX, max(plotRect.minX, point.x))
        return inspectionLines(date: date(forX: inspectionX), point: point)
    }

    /// What to say about the instant under the pointer, most specific first.
    private func inspectionLines(date: Date, point: NSPoint) -> [String] {
        let elapsed = durationLabel(date.timeIntervalSince(renderModel.start))
        switch mode {
        case .usage:
            return usageInspectionLines(date: date, point: point)
        case .trends:
            return trendInspectionLines(at: point)
        case .trace:
            break
        }
        if let event = inspectedGlobalEvent(at: point) {
            var lines = [agentTraceEventTitle(event)]
            if let detail = activitySingleLine(event.detail ?? "") {
                lines.append(detail)
            }
            lines.append(contentsOf: harnessEventInspectionDetails(event))
            if event.harnessEventKind == nil, let provenance = event.measurementProvenance {
                lines.append(appKitMeasurementProvenanceLabel(provenance))
            }
            lines.append("at \(durationLabel(event.at.timeIntervalSince(renderModel.start)))")
            return lines
        }
        let row = Int(floor((point.y - TraceLayout.eventRailHeight) / TraceLayout.laneHeight))
        guard visibleLanes.indices.contains(row) else {
            return [inspectionText(date: date, point: point)]
        }
        let lane = visibleLanes[row]
        let spans = displaySpansByLaneID[lane.id] ?? lane.spans
        let rowY = TraceLayout.eventRailHeight + CGFloat(row) * TraceLayout.laneHeight
        guard let item = visiblyInspectedSpan(
            in: spans,
            rowY: rowY,
            point: point
        ) ?? inspectedSpan(in: spans, at: date) else {
            return ["\(elapsed) · \(lane.label)", lane.detail].compactMap { $0 }
        }

        // A span whose title was filtered out as uninformative contributes no title line rather
        // than a blank one.
        let span = item.span
        var lines: [String] = span.title.isEmpty ? [] : [span.title]
        let length = span.end.timeIntervalSince(span.start)
        var timing = "\(elapsed)  ·  \(durationLabel(length))"
        if duration > 0 {
            timing += " (\(Int((length / duration * 100).rounded()))% of turn)"
        }
        lines.append(timing)
        if let detail = span.detail.flatMap(activitySingleLine), !detail.isEmpty {
            lines.append(detail)
        }

        let tokens = span.tokens
        if !tokens.isEmpty {
            var parts: [String] = []
            if tokens.uncachedInput > 0 { parts.append("\(formatTokens(tokens.uncachedInput)) in") }
            if tokens.cachedInput > 0 { parts.append("\(formatTokens(tokens.cachedInput)) cached") }
            if tokens.generated > 0 { parts.append("\(formatTokens(tokens.generated)) out") }
            if !parts.isEmpty { lines.append(parts.joined(separator: "  ·  ")) }
        }

        // The span's title is usually the tool's own name, so listing it again says nothing. Only
        // name tools the title does not already cover.
        let tools = span.toolNames
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(span.title) != .orderedSame }
        if !tools.isEmpty {
            lines.append(tools.prefix(3).joined(separator: ", ")
                + (tools.count > 3 ? " +\(tools.count - 3)" : ""))
        }
        if span.sourceCount > 1 {
            lines.append("\(span.sourceCount) calls merged. Zoom in to separate")
        }
        if item.isOpen { lines.append("still running") }
        if showsCriticalPath, renderModel.criticalSpanIDs.contains(span.id) {
            lines.append("on the critical path")
        }
        if span.phase == .tool {
            let toolRecord = lane.records.last { record in
                (record.kind == .tool || record.harnessEventKind == .tool)
                    && record.at >= span.start && record.at <= span.end
            }
            if let toolRecord {
                if let total = toolRecord.toolDurationMs {
                    lines.append("tool \(durationLabel(TimeInterval(total) / 1_000))")
                } else {
                    lines.append("tool duration — not reported")
                }
                if let wait = toolRecord.toolWaitDurationMs {
                    lines.append("approval wait \(durationLabel(TimeInterval(wait) / 1_000))")
                }
                if let execution = toolRecord.toolExecutionDurationMs {
                    lines.append("execution \(durationLabel(TimeInterval(execution) / 1_000))")
                }
                if let outcome = toolRecord.toolOutcome {
                    lines.append("outcome \(appKitHarnessTokenLabel(outcome.rawValue))")
                }
                if let provenance = toolRecord.measurementProvenance {
                    lines.append(appKitMeasurementProvenanceLabel(provenance))
                }
            }
        }
        if let input = renderModel.input {
            let provenance = [
                input.summary.providerAccess?.displayName,
                input.summary.modelID,
            ].compactMap { value in
                value.flatMap { $0.isEmpty ? nil : $0 }
            }.joined(separator: " · ")
            if !provenance.isEmpty { lines.append(provenance) }
        }
        lines.append(lane.label)
        return lines
    }

    private func harnessEventInspectionDetails(_ event: AgentActivityRecord) -> [String] {
        guard event.harnessEventKind != nil else { return [] }
        var lines: [String] = []
        if let attempt = event.retryAttempt ?? event.retryAttempts {
            if let maximum = event.retryMaxAttempts {
                lines.append("attempt \(attempt) of \(maximum)")
            } else {
                lines.append("attempt \(attempt)")
            }
        }
        if let delay = event.retryDelayMs {
            lines.append("retry delay \(durationLabel(TimeInterval(delay) / 1_000))")
        }
        if let willContinue = event.retryWillContinue {
            lines.append(willContinue ? "retry will continue" : "no further retry")
        }
        if let status = event.httpStatusCode { lines.append("HTTP \(status)") }
        if let errorKind = event.errorKind {
            lines.append("error \(appKitHarnessTokenLabel(errorKind))")
        }
        if let reason = event.rerouteReason {
            lines.append("reroute reason \(appKitHarnessTokenLabel(reason))")
        }
        if let safety = event.safetyOutcome {
            lines.append("safety \(appKitHarnessTokenLabel(safety.rawValue))")
        }
        if let reasons = event.safetyReasons, !reasons.isEmpty {
            lines.append("reasons " + reasons.map(appKitHarnessTokenLabel).joined(separator: ", "))
        }
        if let useCases = event.safetyUseCases, !useCases.isEmpty {
            lines.append("use cases " + useCases.map(appKitHarnessTokenLabel).joined(separator: ", "))
        }
        if let verifications = event.modelVerifications, !verifications.isEmpty {
            lines.append("verified "
                + verifications.map(appKitHarnessTokenLabel).joined(separator: ", "))
        }
        if let fasterModel = event.safetyFasterModelID {
            lines.append("faster model \(fasterModel)")
        }
        if let buffering = event.safetyShowsBufferingUI {
            lines.append(buffering ? "buffering UI shown" : "buffering UI not shown")
        }
        if let lane = event.resolvedHarnessLaneID {
            lines.append("harness \(lane.rawValue)")
        }
        if let scope = event.measurementScope {
            lines.append("scope \(appKitHarnessTokenLabel(scope.rawValue))")
        }
        if let aggregation = event.measurementAggregation {
            lines.append("aggregation \(appKitHarnessTokenLabel(aggregation.rawValue))")
        }
        lines.append(event.measurementProvenance.map(appKitMeasurementProvenanceLabel)
            ?? String(localized: "Measurement provenance — not reported"))
        return lines
    }

    private func usageInspectionLines(date: Date, point: NSPoint) -> [String] {
        let elapsed = durationLabel(date.timeIntervalSince(renderModel.start))
        let fullHeight = max(45, bounds.height - 68)
        let contextStartsAt = 48 + floor(fullHeight * 0.55) + 7
        if point.y >= contextStartsAt {
            var lines = [inspectionText(date: date, point: point)]
            let rootContext = (renderModel.input?.records ?? []).filter {
                $0.agentID == AgentActivityIdentity.root
                    && $0.kind == .context
                    && $0.contextTokens != nil
            }
            if let closest = rootContext.min(by: {
                abs($0.at.timeIntervalSince(date)) < abs($1.at.timeIntervalSince(date))
            }) {
                if let composition = closest.contextComposition {
                    let categories = composition.reportedCategories.compactMap { category in
                        composition[category].map {
                            "\(appKitContextCategoryLabel(category)) \(formatTokens($0))"
                        }
                    }
                    for group in stride(from: 0, to: categories.count, by: 3) {
                        lines.append(categories[group..<min(categories.count, group + 3)]
                            .joined(separator: "  ·  "))
                    }
                } else {
                    lines.append("context composition — not reported")
                }
                if let provenance = closest.measurementProvenance {
                    lines.append(appKitMeasurementProvenanceLabel(provenance))
                }
            }
            return lines
        }
        guard let bucket = renderModel.usageBuckets.min(by: {
            abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date))
        }) else { return ["\(elapsed) · no token sample"] }
        let bucketRecords = tokenRecords(in: bucket, from: usageReportingRecords)
        let anatomy = appKitActivityTokenAnatomy(
            records: bucketRecords,
            breakdown: bucket.tokens)
        guard let processed = anatomy.processed else {
            return ["\(elapsed) · tokens not reported"]
        }
        var lines = ["\(elapsed) · \(formatTokens(processed)) processed"]
        var input: [String] = []
        if let remainder = anatomy.inputRemainder {
            input.append("\(formatTokens(remainder)) "
                + (anatomy.inputRemainderIsExact ? "fresh" : "fresh/unsplit"))
        }
        input.append(anatomy.cacheRead.map { "\(formatTokens($0)) cache read" }
            ?? "cache read — not reported")
        input.append(anatomy.cacheWrite.map { "\(formatTokens($0)) cache write" }
            ?? "cache write — not reported")
        if !input.isEmpty { lines.append(input.joined(separator: "  ·  ")) }
        var output: [String] = []
        output.append(anatomy.answerOutput.map { "\(formatTokens($0)) answer" }
            ?? "answer — not reported")
        output.append(anatomy.reasoningOutput.map { "\(formatTokens($0)) reasoning" }
            ?? "reasoning — not reported")
        lines.append(output.joined(separator: "  ·  "))
        if let unclassified = anatomy.unclassified {
            lines.append("\(formatTokens(unclassified)) unclassified provider total")
        }
        if let input = renderModel.input {
            let route = [input.summary.providerAccess?.displayName, input.summary.modelID]
                .compactMap { value in value.flatMap { $0.isEmpty ? nil : $0 } }
                .joined(separator: " · ")
            if !route.isEmpty { lines.append(route) }
        }
        let provenance = Dictionary(grouping: bucketRecords.compactMap(\.measurementProvenance),
                                    by: \.rawValue)
            .compactMap { $0.value.first }
            .sorted { $0.rawValue < $1.rawValue }
            .map(appKitMeasurementProvenanceLabel)
        if !provenance.isEmpty { lines.append(provenance.joined(separator: " · ")) }
        return lines
    }

    private func trendInspectionLines(at point: NSPoint) -> [String] {
        if trendMetric == .runtime {
            return runtimeInspectionLines(at: point)
        }
        guard let turns = renderModel.input?.trendTurns, !turns.isEmpty else {
            return ["No retained turns"]
        }
        let index = trendTurnIndex(at: point) ?? focusedTrendIndex
        guard turns.indices.contains(index) else { return [] }
        let turn = turns[index]
        var lines = ["Turn \(index + 1) · \(Self.trendTurnTime.string(from: turn.startedAt))"]
        let route = [turn.providerAccess?.displayName, turn.modelID]
            .compactMap { value in value.flatMap { $0.isEmpty ? nil : $0 } }
            .joined(separator: " · ")
        if !route.isEmpty { lines.append(route) }
        switch trendMetric {
        case .duration:
            lines.append("wall \(durationLabel(turn.duration))")
            lines.append(turn.ttft.map { "first output \(durationLabel($0))" }
                ?? "first output not reported")
        case .tokens:
            if let processed = turn.tokens.processed {
                lines.append("\(formatTokens(processed)) processed")
            } else {
                lines.append("tokens — not reported")
            }
            let cache = turn.tokens.cacheRead.map { "\(formatTokens($0)) cache read" }
                ?? "cache read — not reported"
            let write = turn.tokens.cacheWrite.map { "\(formatTokens($0)) cache write" }
                ?? "cache write — not reported"
            lines.append("\(cache)  ·  \(write)")
        case .context:
            if let final = turn.finalContextTokens, let window = turn.contextWindow {
                lines.append("final \(formatTokens(final))/\(formatTokens(window))")
                if let peak = turn.peakContextTokens {
                    lines.append("peak \(formatTokens(peak))")
                }
            } else {
                lines.append("context — not reported")
            }
            if turn.compactionCount > 0 {
                lines.append("\(turn.compactionCount) "
                    + (turn.compactionCount == 1 ? "compaction" : "compactions"))
            }
        case .reliability:
            lines.append("\(turn.retryCount) retry  ·  \(turn.recoveryCount) recovery  ·  "
                + "\(turn.subtractionCount) withheld")
            lines.append("\(turn.rerouteCount) reroute  ·  \(turn.safetyCount) safety  ·  "
                + "\(turn.failureCount) failed")
        case .runtime:
            break
        }
        if let outcome = turn.outcome { lines.append(activityPhaseLabel(outcome)) }
        return lines
    }

    private func runtimeInspectionLines(at point: NSPoint) -> [String] {
        let samples = renderModel.input?.runtimeSamples ?? []
        guard !samples.isEmpty else { return [] }
        guard let layout = runtimeMetricLayouts().first(where: {
            $0.frame.insetBy(dx: -2, dy: -1).contains(point)
        }) else { return [] }
        let sample = layout.sample
        var lines = [
            "\(layout.harnessTitle) · \(layout.presentation.title)",
            "\(layout.presentation.value) · \(layout.presentation.detail)",
            sample.name,
        ]
        if layout.presentation.fullDetail != layout.presentation.detail {
            lines.append(layout.presentation.fullDetail)
        }
        if sample.kind == .histogram {
            if let minimum = sample.min, let maximum = sample.max {
                lines.append(
                    "range \(runtimeMetricScalar(minimum, unit: sample.unit))–"
                        + runtimeMetricScalar(maximum, unit: sample.unit))
            } else {
                lines.append(String(localized: "histogram range — not reported"))
            }
            if let count = sample.count { lines.append("\(count) observations") }
        }
        if let scope = sample.attributes[.scope].flatMap(runtimeMetricAttributeText) {
            lines.append("scope \(scope)")
        }
        if let provenance = sample.attributes[.provenance].flatMap(runtimeMetricAttributeText) {
            lines.append("provenance \(provenance)")
        } else {
            lines.append(String(localized: "local harness telemetry"))
        }
        lines.append("updated \(Self.trendTurnTime.string(from: sample.at))")
        lines.append(String(localized: "Session-wide aggregate · not attributed to this turn"))
        return lines
    }

    private func runtimeMetricScalar(_ value: Double, unit: HarnessMetricUnit) -> String {
        let sample = HarnessMetricSample(
            name: "display",
            kind: .gauge,
            unit: unit,
            value: value)
        return sample.map(appKitRuntimeMetricValue) ?? String(format: "%.3g", value)
    }

    private func runtimeMetricAttributeText(_ value: HarnessMetricAttributeValue) -> String? {
        switch value {
        case .string(let text): return text
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return String(format: "%.3g", value)
        }
    }

    private func inspectedGlobalEvent(at point: NSPoint) -> AgentActivityRecord? {
        guard point.y >= 0, point.y <= TraceLayout.eventRailHeight else { return nil }
        return globalEventBadgeGeometries()
            .filter { $0.badgeRect.insetBy(dx: -2, dy: 0).contains(point) }
            .map { geometry in
                (
                    event: geometry.event,
                    distance: abs(geometry.badgeRect.midX - point.x)
                )
            }
            .min {
                if $0.distance != $1.distance { return $0.distance < $1.distance }
                return $0.event.at < $1.event.at
            }?
            .event
    }

    private func drawLaneLabel(_ lane: AppKitAgentActivityLane, rect: NSRect) {
        let isRoot = lane.id == AgentActivityIdentity.root
        let records = lane.records
        let latestPhase = records
            .filter { $0.kind == .state && $0.phase != nil }
            .max(by: { $0.at < $1.at })?
            .phase

        let nameFont = isRoot ? TraceLayout.laneNameFont : TraceLayout.laneChildFont
        let nameWidth = ceil((lane.label as NSString)
            .size(withAttributes: [.font: nameFont]).width)
        // Widening the gutter is what makes room for the task; below that it stays in the tooltip.
        let hasDetail = (lane.detail?.isEmpty == false) && rect.width >= 150
        let blockHeight: CGFloat = hasDetail ? 34 : 24
        var y = rect.minY + (rect.height - blockHeight) / 2

        // Name row, right-aligned with its status dot leading it.
        let nameX = max(rect.minX + 9, rect.maxX - nameWidth)
        drawText(
            lane.label,
            rect: NSRect(x: nameX, y: y, width: rect.maxX - nameX, height: 12),
            font: nameFont,
            color: isRoot ? .labelColor : .secondaryLabelColor)
        (latestPhase.map(phaseColor) ?? NSColor.secondaryLabelColor).setFill()
        NSBezierPath(ovalIn: NSRect(x: nameX - 9, y: y + 3.5, width: 5, height: 5)).fill()
        y += 14

        // WHAT IT IS DOING NOW, AND FOR HOW LONG. The phase alone ("running") is the same word for
        // a healthy minute and a wedged hour, and the elapsed total does not separate them either.
        // `AgentStepInsight` answers both and was written for exactly this line — and then nothing
        // ever called it.
        let step = laneStep(lane)
        let status = step?.text
            ?? latestPhase.map { activityPhaseLabel($0).lowercased() }
            ?? "no state"
        let processed = lane.usage.processed
        drawText(
            processed > 0 ? "\(formatTokens(processed)) processed · \(status)" : status,
            rect: NSRect(x: rect.minX, y: y, width: rect.width, height: 11),
            font: TraceLayout.laneMetaFont,
            // Said in colour rather than with a word, because the word is the step's own name and
            // it is the useful half. Stalled is judged against THIS agent's median step, so a
            // build agent's slow minute and a search agent's slow second are both its own.
            color: step?.isStalled == true ? NSColor(Color.nWarningText) : .nChartMuted,
            alignment: .right)

        if hasDetail, let detail = lane.detail {
            y += 12
            drawText(
                detail,
                rect: NSRect(x: rect.minX, y: y, width: rect.width, height: 10),
                font: TraceLayout.laneDetailFont,
                color: .nChartMuted,
                alignment: .right)
        }
    }

    private func inspectionText(date: Date, point: NSPoint) -> String {
        let elapsed = durationLabel(date.timeIntervalSince(renderModel.start))
        if mode == .usage {
            let fullHeight = max(45, bounds.height - 68)
            let contextStartsAt = 48 + floor(fullHeight * 0.55) + 7
            if point.y >= contextStartsAt,
               let first = renderModel.contextSeries.samples.first,
               let last = renderModel.contextSeries.samples.last {
                let sampleDuration = max(1, last.at.timeIntervalSince(first.at))
                let paddedStart = first.at.addingTimeInterval(-sampleDuration * 0.025)
                let paddedDuration = sampleDuration * 1.05
                let fraction = min(
                    1,
                    max(0, (point.x - plotRect.minX) / max(1, plotRect.width)))
                let contextDate = paddedStart.addingTimeInterval(
                    paddedDuration * Double(fraction))
                if let sample = renderModel.contextSeries.samples.min(by: {
                    abs($0.at.timeIntervalSince(contextDate))
                        < abs($1.at.timeIntervalSince(contextDate))
                }) {
                    let window = sample.window ?? renderModel.contextSeries.reportedWindow
                    let contextElapsed = durationLabel(
                        contextDate.timeIntervalSince(renderModel.start))
                    return "\(contextElapsed) · root context \(formatTokens(sample.tokens))"
                        + (window.map { "/\(formatTokens($0))" } ?? " · window not reported")
                }
            }
            let closest = renderModel.usageBuckets.min {
                abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date))
            }
            guard let closest, !closest.tokens.isEmpty else { return "\(elapsed) · no token sample" }
            return "\(elapsed) · \(formatTokens(closest.tokens.processed)) processed"
        }
        let row = Int(floor((point.y - TraceLayout.eventRailHeight) / TraceLayout.laneHeight))
        guard visibleLanes.indices.contains(row) else { return elapsed }
        let lane = visibleLanes[row]
        let spans = displaySpansByLaneID[lane.id] ?? lane.spans
        if let item = inspectedSpan(in: spans, at: date) {
            return "\(elapsed) · \(lane.label) · \(item.span.title)"
                + (item.isOpen ? " · open" : "")
        }
        return "\(elapsed) · \(lane.label)"
    }

    private func inspectedSpan(
        in spans: [AppKitAgentActivityTraceSpan],
        at date: Date
    ) -> AppKitAgentActivityTraceSpan? {
        guard !spans.isEmpty else { return nil }
        var low = 0
        var high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].span.start <= date {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let terminalTolerance = max(0.25, duration * 0.01)
        var index = min(spans.count - 1, low - 1)
        while index >= 0 {
            let item = spans[index]
            if item.span.phase.isTerminal {
                if abs(item.span.start.timeIntervalSince(date)) <= terminalTolerance {
                    return item
                }
            } else if date >= item.span.start && date <= item.span.end {
                return item
            } else if item.span.end < date
                        && date.timeIntervalSince(item.span.end) > terminalTolerance {
                break
            }
            if index == 0 { break }
            index -= 1
        }
        return nil
    }

    /// Prefer the mark actually under the pointer. This matters for a sub-pixel call promoted to
    /// the minimum visible bar width: most of that visible mark lies outside its literal time range.
    private func visiblyInspectedSpan(
        in spans: [AppKitAgentActivityTraceSpan],
        rowY: CGFloat,
        point: NSPoint
    ) -> AppKitAgentActivityTraceSpan? {
        spans.enumerated()
            .compactMap { index, item -> (
                item: AppKitAgentActivityTraceSpan,
                distance: CGFloat,
                index: Int
            )? in
                let rect = traceSpanRect(item.span, rowY: rowY)
                guard rect.contains(point) else { return nil }
                return (item, abs(rect.midX - point.x), index)
            }
            .min {
                if $0.distance != $1.distance { return $0.distance < $1.distance }
                return $0.index < $1.index
            }?
            .item
    }

    override func accessibilityChildren() -> [Any]? {
        if accessibilityChildrenDirty {
            accessibilityChildrenDirty = false
            accessibilityTreeRebuildCount += 1
            updateAccessibilitySummary(rebuildChildren: true)
        }
        return super.accessibilityChildren()
    }

    private func invalidateAccessibilityChildren() {
        accessibilityChildrenDirty = true
        // Do not leave a prior ledger's position-bearing children installed while the new tree is
        // waiting for an accessibility client to request it.
        setAccessibilityChildren(nil)
    }

    private func updateAccessibilitySummary(rebuildChildren: Bool = false) {
        if !rebuildChildren { invalidateAccessibilityChildren() }
        guard let input = renderModel.input else {
            if rebuildChildren { setAccessibilityChildren([]) }
            return
        }
        if mode == .trends {
            updateTrendAccessibilitySummary(input, rebuildChildren: rebuildChildren)
            return
        }
        let usage = agentActivityTokenBreakdown(input.records)
        let lanes = visibleLanes
        let open = lanes.flatMap(\.spans).filter(\.isOpen).count
        setAccessibilityValue(
            "\(lanes.count) agent lanes, "
                + "\(formatTokens(usage.processed)) tokens processed, "
                + "\(open) open last-known states")
        if renderModel.criticalPathDuration > 0, duration > 0 {
            let share = Int((renderModel.criticalPathDuration / duration * 100).rounded())
            setAccessibilityValue(
                (accessibilityValue() as? String ?? "")
                    + ", critical path \(durationLabel(renderModel.criticalPathDuration))"
                    + ", \(share) percent of the turn")
        }
        setAccessibilityHelp(
            "Left and right arrows move between spans, up and down between agent lanes. "
                + "Hold Option to scrub finely. Escape clears the inspection.")

        // Constructing one position-bearing NSAccessibilityElement for every span and event is
        // expensive on long live ledgers. Keep the cheap group summary current on every update,
        // and materialize the detailed tree only when VoiceOver or another AX client asks for it.
        guard rebuildChildren else { return }

        // Elements carry frames. Without them VoiceOver has a tree it can read but nothing it can
        // point at: no cursor rectangle, and no way to reach a span by position.
        let laneElements: [NSAccessibilityElement] = lanes.enumerated().map { index, lane in
            let rowY = TraceLayout.eventRailHeight + CGFloat(index) * TraceLayout.laneHeight
            let laneRect = NSRect(
                x: 0,
                y: rowY,
                width: bounds.width,
                height: TraceLayout.laneHeight)
            let laneElement = NSAccessibilityElement()
            laneElement.setAccessibilityRole(.group)
            laneElement.setAccessibilityLabel(lane.label)
            if let detail = lane.detail, !detail.isEmpty {
                laneElement.setAccessibilityHelp(detail)
            }
            let laneUsage = lane.usage
            laneElement.setAccessibilityValue(
                laneUsage.isEmpty
                    ? "no tokens reported"
                    : "\(formatTokens(laneUsage.processed)) tokens processed")
            laneElement.setAccessibilityParent(self)
            setFrame(laneRect, on: laneElement)

            let spans = displaySpansByLaneID[lane.id] ?? lane.spans
            let spanElements: [NSAccessibilityElement] = spans.map { item in
                let element = NSAccessibilityElement()
                element.setAccessibilityRole(.staticText)
                element.setAccessibilityLabel(spanAccessibilityLabel(item, lane: lane))
                element.setAccessibilityParent(laneElement)
                setFrame(traceSpanRect(item.span, rowY: rowY), on: element)
                return element
            }
            laneElement.setAccessibilityChildren(spanElements)
            return laneElement
        }

        let eventElements: [NSAccessibilityElement]
        if mode == .trace {
            eventElements = globalEventBadgeGeometries().map { geometry in
                let event = geometry.event
                let element = NSAccessibilityElement()
                element.setAccessibilityRole(.staticText)
                let title = agentTraceEventTitle(event)
                let detail = activitySingleLine(event.detail ?? "")
                var label = title + (detail.map { ", \($0)" } ?? "")
                // Compaction reports how much it reclaimed; that is the whole point of the mark.
                if event.kind == .compaction,
                   let before = event.compactionPreTokens,
                   let after = event.compactionPostTokens {
                    label += ", \(formatTokens(before)) down to \(formatTokens(after))"
                }
                if let duration = event.compactionDurationMs {
                    label += ", \(durationLabel(TimeInterval(duration) / 1_000))"
                }
                let harnessDetails = harnessEventInspectionDetails(event)
                if !harnessDetails.isEmpty {
                    label += ", " + harnessDetails.joined(separator: ", ")
                } else if let provenance = event.measurementProvenance {
                    label += ", \(appKitMeasurementProvenanceLabel(provenance))"
                }
                label += ", at \(durationLabel(event.at.timeIntervalSince(renderModel.start)))"
                element.setAccessibilityLabel(label)
                element.setAccessibilityParent(self)
                setFrame(
                    NSRect(
                        x: geometry.badgeRect.minX,
                        y: 0,
                        width: geometry.badgeRect.width,
                        height: TraceLayout.eventRailHeight),
                    on: element)
                return element
            }
        } else {
            // Usage mode has no EVENTS rail. Do not leave its Trace-only markers in VoiceOver's
            // traversal as invisible, position-bearing controls.
            eventElements = []
        }

        var contextElements: [NSAccessibilityElement] = []
        if let latest = renderModel.contextSeries.latestTokens {
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            var label = "Latest root context, \(formatTokens(latest)) tokens"
            if let window = renderModel.contextSeries.reportedWindow {
                label += " of \(formatTokens(window))"
                if let headroom = renderModel.contextSeries.headroom {
                    label += ", \(formatTokens(headroom)) tokens headroom"
                }
            } else {
                label += ", context window not reported"
            }
            element.setAccessibilityLabel(label)
            element.setAccessibilityParent(self)
            contextElements = [element]
        }

        // The token track is drawn but was never described.
        var costElements: [NSAccessibilityElement] = []
        let peak = renderModel.usageBuckets.map(\.tokens.processed).max() ?? 0
        if peak > 0, !lanes.isEmpty {
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.group)
            element.setAccessibilityLabel("Token volume over time")
            element.setAccessibilityValue("peak \(formatTokens(peak)) tokens in one interval")
            element.setAccessibilityParent(self)
            let top = TraceLayout.eventRailHeight
                + CGFloat(lanes.count) * TraceLayout.laneHeight
            setFrame(
                NSRect(
                    x: 0,
                    y: top,
                    width: bounds.width,
                    height: TraceLayout.costTrackHeight),
                on: element)
            costElements = [element]
        }

        setAccessibilityChildren(laneElements + eventElements + costElements + contextElements)
    }

    private func updateTrendAccessibilitySummary(
        _ input: AppKitAgentActivityRenderInput,
        rebuildChildren: Bool
    ) {
        if trendMetric == .runtime {
            updateRuntimeAccessibilitySummary(input, rebuildChildren: rebuildChildren)
            return
        }
        let turns = input.trendTurns
        if trendMetric == .duration {
            let observedMaximum = turns.map { max($0.duration, $0.ttft ?? 0) }.max() ?? 0
            let scale = AppKitDurationTrendScale(observedMaximum: observedMaximum)
            let selected = turns.indices.contains(selectedTrendIndex)
                ? turns[selectedTrendIndex]
                : nil
            let selectedValue = selected.map { turn in
                let first = turn.ttft.map { durationLabel($0) } ?? "not reported"
                return ", selected turn \(selectedTrendIndex + 1), wall duration "
                    + "\(durationLabel(turn.duration)), first output \(first)"
            } ?? ""
            setAccessibilityValue(
                "\(turns.count) retained conversation turns, duration trend, axis zero to "
                    + "\(scale.label(for: scale.maximum)), blue circles are wall duration, "
                    + "green diamonds are first output, crosses below zero are not reported"
                    + selectedValue)
            setAccessibilityHelp(
                "Left and right arrows select retained turns. Click a mark to select its provider turn.")
        } else {
            setAccessibilityValue(
                "\(turns.count) retained conversation turns, \(trendMetric.title.lowercased()) trend")
            setAccessibilityHelp(
                "Left and right arrows select retained turns. Click a mark to select its provider turn.")
        }
        guard rebuildChildren else { return }
        let frames = trendTurnFrames()
        let elements: [NSAccessibilityElement] = turns.enumerated().map { index, turn in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            var parts = [
                index == selectedTrendIndex
                    ? "Selected turn \(index + 1) of \(turns.count)"
                    : "Turn \(index + 1) of \(turns.count)",
                Self.trendTurnTime.string(from: turn.startedAt),
                turn.providerAccess?.displayName,
                turn.modelID,
            ].compactMap { $0 }
            switch trendMetric {
            case .duration:
                parts.append("wall duration \(durationLabel(turn.duration))")
                parts.append(turn.ttft.map { "first output \(durationLabel($0))" }
                    ?? "first output not reported")
            case .tokens:
                parts.append(turn.tokens.processed.map {
                    "\(formatTokens($0)) tokens processed"
                } ?? "tokens not reported")
            case .context:
                if let final = turn.finalContextTokens, let window = turn.contextWindow {
                    parts.append("final context \(formatTokens(final)) of \(formatTokens(window))")
                } else {
                    parts.append("context not reported")
                }
                if turn.compactionCount > 0 {
                    parts.append("\(turn.compactionCount) compactions")
                }
            case .reliability:
                parts.append("\(turn.retryCount) retries")
                parts.append("\(turn.recoveryCount) recoveries")
                parts.append("\(turn.subtractionCount) withheld events")
                parts.append("\(turn.rerouteCount) reroutes")
                parts.append("\(turn.safetyCount) safety events")
                parts.append("\(turn.failureCount) failures")
            case .runtime:
                break
            }
            element.setAccessibilityLabel(parts.joined(separator: ", "))
            element.setAccessibilityParent(self)
            if frames.indices.contains(index) { setFrame(frames[index], on: element) }
            return element
        }
        setAccessibilityChildren(elements)
    }

    private func updateRuntimeAccessibilitySummary(
        _ input: AppKitAgentActivityRenderInput,
        rebuildChildren: Bool
    ) {
        setAccessibilityValue(
            String(localized: "\(input.runtimeSamples.count) session-wide harness metric samples; not attributed to a turn"))
        setAccessibilityHelp(
            String(localized: "Harness metrics are provider-wide aggregates. Click a metric for details; click it again, click outside the rows, or press Escape to dismiss. Use Duration for protocol-authoritative per-turn timing."))
        guard rebuildChildren else { return }
        let layouts = runtimeMetricLayouts()
        if layouts.isEmpty {
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(
                String(localized: "Harness metrics not reported for this session"))
            element.setAccessibilityParent(self)
            setFrame(trendsChartRect, on: element)
            setAccessibilityChildren([element])
            return
        }
        var elements = layouts.map { layout in
            let sample = layout.sample
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            let label = String(localized: "\(layout.harnessTitle), \(layout.presentation.title), \(layout.presentation.value), \(layout.presentation.fullDetail), exact metric \(sample.name), session-wide aggregate")
            element.setAccessibilityLabel(label)
            element.setAccessibilityHelp(
                String(localized: "Updated \(Self.trendTurnTime.string(from: sample.at)); not attributed to a turn"))
            element.setAccessibilityParent(self)
            setFrame(layout.frame, on: element)
            return element
        }
        if let dismissRect = currentInspectionOverlayLayout()?.dismissRect {
            let dismiss = AppKitAgentActivityDismissAccessibilityElement(owner: self)
            dismiss.setAccessibilityRole(.button)
            dismiss.setAccessibilityLabel(String(localized: "Dismiss metric details"))
            dismiss.setAccessibilityHelp(String(localized: "Closes the selected Harness metric details."))
            dismiss.setAccessibilityParent(self)
            setFrame(dismissRect, on: dismiss)
            elements.append(dismiss)
        }
        setAccessibilityChildren(elements)
    }

    /// Keep VoiceOver's cursor and the keyboard focus on the same span. Two traversals of the same
    /// chart that disagree are worse than one, and the arrow keys already move span to span.
    func accessibilityFocusedUIElement() -> Any? {
        if mode == .trends, trendMetric == .runtime,
           let children = accessibilityChildren() as? [NSAccessibilityElement],
           children.indices.contains(focusedRuntimeMetricIndex) {
            return children[focusedRuntimeMetricIndex]
        }
        if mode == .trends,
           let children = accessibilityChildren() as? [NSAccessibilityElement],
           children.indices.contains(focusedTrendIndex) {
            return children[focusedTrendIndex]
        }
        guard let children = accessibilityChildren() as? [NSAccessibilityElement],
              children.indices.contains(focusedLane) else {
            return self
        }
        let lane = children[focusedLane]
        guard let spans = lane.accessibilityChildren() as? [NSAccessibilityElement],
              spans.indices.contains(focusedSpan) else {
            return lane
        }
        return spans[focusedSpan]
    }

    /// Elements are positioned in screen space when the view is in a window, and in the view's own
    /// space otherwise, so an offscreen render still produces a locatable tree.
    private func setFrame(_ rect: NSRect, on element: NSAccessibilityElement) {
        if window != nil {
            element.setAccessibilityFrame(convertToScreenSpace(rect))
        } else {
            element.setAccessibilityFrameInParentSpace(rect)
        }
    }

    private func convertToScreenSpace(_ rect: NSRect) -> NSRect {
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    private func spanAccessibilityLabel(
        _ item: AppKitAgentActivityTraceSpan,
        lane: AppKitAgentActivityLane
    ) -> String {
        let span = item.span
        var parts = [span.title, activityPhaseLabel(span.phase)]
        parts.append("starting \(durationLabel(span.start.timeIntervalSince(renderModel.start)))")
        if item.isOpen {
            parts.append("open last-known state")
        } else {
            parts.append(durationLabel(span.duration))
        }
        let tokens = span.tokens
        if !tokens.isEmpty {
            parts.append("\(formatTokens(tokens.processed)) tokens")
        }
        if span.sourceCount > 1 {
            parts.append("\(span.sourceCount) calls merged")
        }
        let additionalTools = span.toolNames.filter {
            !$0.isEmpty && $0.caseInsensitiveCompare(span.title) != .orderedSame
        }
        if !additionalTools.isEmpty {
            parts.append("tools \(additionalTools.joined(separator: ", "))")
        }
        if renderModel.criticalSpanIDs.contains(span.id) {
            parts.append("on the critical path")
        }
        if span.phase == .tool,
           let record = lane.records.last(where: {
               ($0.kind == .tool || $0.harnessEventKind == .tool)
                   && $0.at >= span.start && $0.at <= span.end
           }) {
            parts.append(record.toolDurationMs.map {
                "tool duration \(durationLabel(TimeInterval($0) / 1_000))"
            } ?? "tool duration not reported")
            if let wait = record.toolWaitDurationMs {
                parts.append("approval wait \(durationLabel(TimeInterval(wait) / 1_000))")
            }
            if let outcome = record.toolOutcome {
                parts.append("outcome \(appKitHarnessTokenLabel(outcome.rawValue))")
            }
            if let provenance = record.measurementProvenance {
                parts.append(appKitMeasurementProvenanceLabel(provenance))
            }
        }
        return parts.joined(separator: ", ")
    }

    private func spanToolTipText(_ span: AgentActivityTraceSpan) -> String {
        let additionalTools = span.toolNames.filter {
            !$0.isEmpty && $0.caseInsensitiveCompare(span.title) != .orderedSame
        }
        guard !additionalTools.isEmpty else { return span.title }
        return ([span.title] + additionalTools).joined(separator: "\n")
    }

    private func rebuildDisplaySpans() {
        let width = max(1, plotRect.width)
        lastDisplayWidth = width
        var next: [String: [AppKitAgentActivityTraceSpan]] = [:]
        next.reserveCapacity(renderModel.lanes.count)
        for lane in renderModel.lanes {
            let raw = lane.spans.map(\.span)
            let coalesced = fitsWidth
                ? agentActivityCoalescedTraceSpans(
                    raw,
                    start: renderModel.start,
                    end: renderModel.end,
                    width: width)
                : raw
            let openSpans = lane.spans.filter(\.isOpen).map(\.span)
            next[lane.id] = coalesced.map { span in
                let containsOpen = openSpans.contains {
                    $0.phase == span.phase
                        && $0.start >= span.start
                        && $0.end <= span.end
                }
                return AppKitAgentActivityTraceSpan(span: span, isOpen: containsOpen)
            }
        }
        displaySpansByLaneID = next
        // Coalescing and zoom can change both span bounds and titles. Tooltip hit regions and the
        // accessibility tree must describe the marks that are actually on screen.
        rebuildLaneTooltips()
        updateAccessibilitySummary()
        inspectionOverlay.needsDisplay = true
    }

    private func updateOpenDisplayTails() {
        for lane in renderModel.lanes {
            guard let open = lane.spans.last(where: \.isOpen),
                  var displayed = displaySpansByLaneID[lane.id],
                  let index = displayed.lastIndex(where: \.isOpen) else { continue }
            displayed[index].span.end = open.span.end
            displaySpansByLaneID[lane.id] = displayed
        }
        inspectionOverlay.needsDisplay = true
    }

    private func phaseColor(_ phase: AgentActivityPhase) -> NSColor {
        appKitAgentActivityPhaseColor(phase)
    }

    /// What this lane is doing now, how long it has been doing it, and whether that is unusual.
    ///
    /// Only for a LIVE lane. A finished agent's last step is history, and reporting how long it sat
    /// in it reads as a complaint about work that is already done.
    private func laneStep(_ lane: AppKitAgentActivityLane) -> (text: String, isStalled: Bool)? {
        guard lane.isActive else { return nil }
        guard let step = renderModel.currentStep(agentID: lane.id),
              !step.isTerminal else { return nil }
        let label = step.label.isEmpty
            ? activityPhaseLabel(step.phase).lowercased()
            : step.label
        // Under a few seconds the number is noise on a line that is redrawn constantly.
        let text = step.duration >= 3
            ? "\(label) · \(durationLabel(step.duration))"
            : label
        return (
            text,
            renderModel.stepIsStalled(agentID: lane.id))
    }

    private func durationLabel(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private func drawText(
        _ text: String,
        rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left,
        strokeColor: NSColor? = nil,
        strokeWidth: CGFloat? = nil
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        if let strokeColor, let strokeWidth {
            attributes[.strokeColor] = strokeColor
            attributes[.strokeWidth] = strokeWidth
        }
        (text as NSString).draw(
            in: rect,
            withAttributes: attributes)
    }
}

private final class AppKitAgentActivityInspectionOverlay: NSView {
    weak var owner: AppKitAgentActivityChartView?
    private var pointerTrackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil)
        addTrackingArea(next)
        pointerTrackingArea = next
    }

    /// True while the lane gutter is being dragged wider or narrower.
    private var isResizingGutter = false

    private func isOverGutterDivider(_ point: NSPoint) -> Bool {
        guard let owner, owner.mode == .trace else { return false }
        return owner.gutterDividerRect().contains(point)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isOverGutterDivider(point) {
            // Over the divider the pointer is a resize handle, not an inspector, and the readout
            // must not follow it there.
            NSCursor.resizeLeftRight.set()
            owner?.pointerExited()
            return
        }
        NSCursor.arrow.set()
        owner?.pointerMoved(to: point)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        owner?.pointerExited()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if isOverGutterDivider(point) {
            isResizingGutter = true
            return
        }
        owner?.pointerPressed(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isResizingGutter, let owner else {
            super.mouseDragged(with: event)
            return
        }
        owner.resizeGutter(toPointerX: convert(event.locationInWindow, from: nil).x)
        NSCursor.resizeLeftRight.set()
    }

    override func mouseUp(with event: NSEvent) {
        if isResizingGutter {
            isResizingGutter = false
            NSCursor.arrow.set()
            return
        }
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            owner?.clearPinnedInspection()
            return
        }
        if let owner, owner.mode == .trends {
            if owner.trendMetric == .runtime {
                switch event.keyCode {
                case 125:
                    owner.moveTrendFocus(1)
                    needsDisplay = true
                    return
                case 126:
                    owner.moveTrendFocus(-1)
                    needsDisplay = true
                    return
                default:
                    break
                }
            }
            switch event.keyCode {
            case 123:
                owner.moveTrendFocus(-1)
                needsDisplay = true
                return
            case 124:
                owner.moveTrendFocus(1)
                needsDisplay = true
                return
            case 36, 76:
                owner.selectFocusedTrendTurn()
                needsDisplay = true
                return
            default:
                break
            }
        }
        // Arrows move between marks, not pixels: left/right step through the focused lane's spans,
        // up/down change lane. Holding Option falls back to a fine scrub for reading between spans.
        if let owner {
            let fine = event.modifierFlags.contains(.option)
            switch event.keyCode {
            case 123 where fine, 124 where fine:
                let current = owner.pinnedPoint
                    ?? NSPoint(x: owner.bounds.midX, y: owner.bounds.midY)
                let delta: CGFloat = event.keyCode == 123 ? -8 : 8
                owner.pinnedPoint = NSPoint(
                    x: min(owner.bounds.maxX, max(owner.bounds.minX, current.x + delta)),
                    y: current.y)
                owner.renderModel.notePointerRedraw()
                needsDisplay = true
                return
            case 123:
                owner.moveFocus(laneDelta: 0, spanDelta: -1)
                needsDisplay = true
                return
            case 124:
                owner.moveFocus(laneDelta: 0, spanDelta: 1)
                needsDisplay = true
                return
            case 126:
                owner.moveFocus(laneDelta: -1, spanDelta: 0)
                needsDisplay = true
                return
            case 125:
                owner.moveFocus(laneDelta: 1, spanDelta: 0)
                needsDisplay = true
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        owner?.drawInspection()
    }
}

@MainActor
private final class AppKitAgentActivityDismissAccessibilityElement: NSAccessibilityElement {
    private weak var owner: AppKitAgentActivityChartView?

    init(owner: AppKitAgentActivityChartView) {
        self.owner = owner
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        guard owner?.hasPinnedInspection == true else { return false }
        owner?.clearPinnedInspection()
        return true
    }
}

// MARK: - Native detail overlay

final class AppKitAgentDetailView: NSView {
    private enum Selection {
        case subagent(key: String, ordinal: Int?)
        case workflow(key: String)
        case workflowAgent(runKey: String, agentKey: String)
    }

    private let backButton = NSButton()
    private let titleField = NSTextField(labelWithString: "")
    private let statusField = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let stopButton = NSButton()
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private var selection: Selection?
    private var subagent: SubagentRun?
    private var workflow: WorkflowRun?
    private var workflowAgent: WorkflowAgent?
    private var activity: [AgentActivityRecord] = []
    private let activityIndexCache = AgentActivityLedgerIndexCache()
    private var now = Date()

    var onBack: (() -> Void)?
    var onStopTask: ((String) -> Void)?
    var detailTextForTesting: String { textView.string }
    var stopButtonForTesting: NSButton { stopButton }
    var needsLiveTick: Bool {
        if subagent?.status == .running { return true }
        if workflowAgent?.state.isRunning == true { return true }
        if let workflow { return appKitWorkflowHasLiveWork(workflow) }
        return false
    }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        backButton.title = "Agents"
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        backButton.imagePosition = .imageLeading
        backButton.bezelStyle = .inline
        backButton.font = .systemFont(ofSize: 10, weight: .medium)
        backButton.target = self
        backButton.action = #selector(back)
        backButton.setAccessibilityLabel("Back to agents")
        addSubview(backButton)

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        addSubview(titleField)
        statusField.font = .systemFont(ofSize: 10, weight: .semibold)
        statusField.alignment = .right
        addSubview(statusField)

        copyButton.isBordered = false
        copyButton.image = NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: nil)
        copyButton.target = self
        copyButton.action = #selector(copyDetails)
        copyButton.toolTip = "Copy agent details"
        copyButton.setAccessibilityLabel("Copy agent details")
        addSubview(copyButton)

        AppKitAgentStopStyle.apply(to: stopButton)
        stopButton.target = self
        stopButton.action = #selector(stopTask)
        configureStopButtonCopy("Stop this agent")
        addSubview(stopButton)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 13)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        addSubview(scrollView)

        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor
            .mechanicianCGColor(in: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        backButton.frame = NSRect(x: 8, y: 8, width: 73, height: 24)
        stopButton.frame = NSRect(x: max(88, bounds.width - 29), y: 8, width: 23, height: 23)
        copyButton.frame = NSRect(
            x: max(88, bounds.width - (stopButton.isHidden ? 31 : 56)),
            y: 8,
            width: 23,
            height: 23)
        let headerActionsMinX = copyButton.frame.minX
        statusField.frame = NSRect(
            x: max(90, headerActionsMinX - 112),
            y: 10,
            width: 102,
            height: 18)
        titleField.frame = NSRect(
            x: 88,
            y: 9,
            width: max(30, statusField.frame.minX - 96),
            height: 20)
        scrollView.frame = NSRect(
            x: 0,
            y: 39,
            width: bounds.width,
            height: max(0, bounds.height - 39))
        textView.frame.size.width = max(1, scrollView.contentSize.width)
    }

    func configure(
        subagent: SubagentRun,
        ordinal: Int?,
        activity: [AgentActivityRecord],
        now: Date
    ) {
        selection = .subagent(key: subagent.key, ordinal: ordinal)
        self.subagent = subagent
        workflow = nil
        workflowAgent = nil
        self.activity = activity
        self.now = now
        configureStopButtonCopy("Stop this agent")
        renderSubagent()
    }

    func configure(workflow: WorkflowRun, now: Date) {
        selection = .workflow(key: workflow.runKey)
        self.workflow = workflow
        subagent = nil
        workflowAgent = nil
        self.now = now
        configureStopButtonCopy("Stop this workflow")
        renderWorkflow()
    }

    func configure(
        workflowAgent: WorkflowAgent,
        in workflow: WorkflowRun,
        activity: [AgentActivityRecord],
        now: Date
    ) {
        selection = .workflowAgent(runKey: workflow.runKey, agentKey: workflowAgent.id)
        self.workflowAgent = workflowAgent
        self.workflow = workflow
        subagent = nil
        self.activity = activity
        self.now = now
        configureStopButtonCopy("Stop this workflow")
        renderWorkflowAgent()
    }

    @discardableResult
    func refreshIfNeeded(
        subagents: [String: SubagentRun],
        workflowRuns: [String: WorkflowRun],
        activity: [AgentActivityRecord]
    ) -> Bool {
        switch selection {
        case .subagent(let key, _):
            guard let updated = subagents[key] else { return false }
            guard updated != subagent || self.activity != activity else { return true }
            subagent = updated
            self.activity = activity
            renderSubagent()
            return true
        case .workflow(let key):
            guard let updated = workflowRuns[key] else { return false }
            guard updated != workflow else { return true }
            workflow = updated
            renderWorkflow()
            return true
        case .workflowAgent(let runKey, let agentKey):
            guard let run = workflowRuns[runKey],
                  let agent = run.agents[agentKey] else { return false }
            guard run != workflow || agent != workflowAgent || self.activity != activity else {
                return true
            }
            workflow = run
            workflowAgent = agent
            self.activity = activity
            renderWorkflowAgent()
            return true
        case .none:
            return false
        }
    }

    func tick(now: Date) {
        self.now = now
        if let subagent, subagent.status == .running {
            updateSubagentStatus(subagent)
        } else if let workflowAgent, let workflow, workflowAgent.state.isRunning {
            updateWorkflowAgentStatus(workflowAgent, run: workflow)
        } else if let workflow, appKitWorkflowHasLiveWork(workflow) {
            updateWorkflowStatus(workflow)
        }
    }

    @objc private func back() {
        onBack?()
    }

    @objc private func copyDetails() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    @objc private func stopTask() {
        guard let taskID = currentTaskID else { return }
        onStopTask?(taskID)
    }

    private func configureStopButtonCopy(_ text: String) {
        stopButton.toolTip = text
        stopButton.setAccessibilityLabel(text)
    }

    private func renderSubagent() {
        guard let subagent else { return }
        let ordinal: Int?
        if case .subagent(_, let value) = selection { ordinal = value } else { ordinal = nil }
        titleField.stringValue = [
            ordinal.map { "A\($0)" },
            subagent.subagentType.isEmpty ? "Agent" : subagent.subagentType,
        ].compactMap { $0 }.joined(separator: " · ")
        updateSubagentStatus(subagent)

        let laneID = AgentActivityIdentity.subagent(subagent.key)
        let index = activityIndexCache.index(for: activity)
        let snapshot = index.cardSnapshot(agentID: laneID, now: now)
        let step = snapshot.currentStep?.isTerminal == true ? nil : snapshot.currentStep
        var sections: [(String, String)] = []
        sections.append(("Status", [
            "Started \(agentRowStamp(subagent.startedAt))",
            agentElapsed(
                durationMs: subagent.durationMs,
                startedAt: subagent.startedAt,
                endedAt: subagent.endedAt,
                now: now),
            subagent.reportedTokens.map { "\(formatTokens($0)) tokens" },
            subagent.reportedToolUses.map { "\($0) \(subagent.toolMetricLabel)" },
        ].compactMap { $0 }.joined(separator: " · ")))
        if let model = appKitReportedChildModel(subagent.model) {
            sections.append(("Model", model))
        }
        if !subagent.task.isEmpty { sections.append(("Task", subagent.task)) }
        if let step {
            sections.append((
                snapshot.isStalled ? "Current step · possibly stalled" : "Current step",
                [
                    step.label,
                    step.target,
                    agentStepDurationLabel(step.duration),
                ].compactMap { $0 }.joined(separator: " · ")))
        }
        if let summary = nonempty(subagent.summary) { sections.append(("Summary", summary)) }
        if !snapshot.toolComposition.isEmpty {
            sections.append((
                "Tool mix",
                snapshot.toolComposition.map { "\($0.name)  \($0.count)" }.joined(separator: "\n")))
        }
        if !subagent.toolEvents.isEmpty {
            sections.append((
                "Tool timeline",
                subagent.toolEvents.map {
                    "\(agentRowStamp($0.at))  \($0.name)"
                }.joined(separator: "\n")))
        }
        if let result = nonempty(subagent.resultPreview) { sections.append(("Result", result)) }
        if let error = nonempty(subagent.error) { sections.append(("Error", error)) }
        textView.textStorage?.setAttributedString(attributedSections(sections))
        setAccessibilityLabel([
            titleField.stringValue,
            subagent.model.map { "Model \($0)" },
            subagent.status.label,
            subagent.task,
        ].compactMap { $0 }.joined(separator: ", "))
    }

    private func renderWorkflow() {
        guard let workflow else { return }
        let presentation = appKitWorkflowCardPresentation(
            workflow,
            expanded: true,
            now: now)
        let status = presentation.status
        let stats = runStats(workflow)
        titleField.stringValue = workflow.workflowName ?? "Workflow"
        updateWorkflowStatus(workflow)

        var sections: [(String, String)] = []
        sections.append(("Status", [
            "Started \(agentRowStamp(workflow.startedAt))",
            agentElapsed(
                durationMs: status == .running && effectiveRunStatus(workflow).isTerminal
                    ? 0
                    : (workflow.usage?.durationMs ?? 0),
                startedAt: workflow.startedAt,
                endedAt: appKitWorkflowHasLiveWork(workflow) ? nil : workflow.endedAt,
                now: now),
            "\(stats.done)/\(stats.agents) agents",
            stats.tokens > 0 ? "\(formatTokens(stats.tokens)) tokens" : nil,
            stats.toolUses > 0 ? "\(stats.toolUses) tools" : nil,
        ].compactMap { $0 }.joined(separator: " · ")))
        if !workflow.description.isEmpty { sections.append(("Task", workflow.description)) }
        let agents = workflow.agents.values.sorted {
            if $0.phaseIndex != $1.phaseIndex { return $0.phaseIndex < $1.phaseIndex }
            return $0.index < $1.index
        }
        if !agents.isEmpty {
            sections.append((
                "Agents",
                agents.map {
                    let name = $0.label.isEmpty ? "Agent \($0.index)" : $0.label
                    return "\(name)  ·  \($0.state.label)"
                        + ($0.lastToolName.map { "  ·  \($0)" } ?? "")
                }.joined(separator: "\n")))
        }
        if let summary = nonempty(workflow.summary) { sections.append(("Summary", summary)) }
        if let output = nonempty(workflow.outputFile) { sections.append(("Output", output)) }
        if let error = nonempty(workflow.error) { sections.append(("Error", error)) }
        textView.textStorage?.setAttributedString(attributedSections(sections))
        setAccessibilityLabel(
            "\(titleField.stringValue), \(status.label), \(stats.done) of \(stats.agents) agents")
    }

    private func renderWorkflowAgent() {
        guard let agent = workflowAgent, let workflow else { return }
        let name = agent.label.isEmpty ? "Agent \(agent.index)" : agent.label
        titleField.stringValue = name
        updateWorkflowAgentStatus(agent, run: workflow)

        let laneID = AgentActivityIdentity.workflow(
            runKey: workflow.runKey,
            agentKey: agent.id)
        let snapshot = activityIndexCache.index(for: activity).cardSnapshot(
            agentID: laneID,
            now: now)
        let step = snapshot.currentStep?.isTerminal == true ? nil : snapshot.currentStep
        var sections: [(String, String)] = []
        let started = agent.startedAt ?? workflow.startedAt
        sections.append(("Status", [
            "Workflow \(workflow.workflowName ?? "Workflow")",
            "Phase \(agent.phaseTitle.isEmpty ? "\(agent.phaseIndex + 1)" : agent.phaseTitle)",
            agent.attempt.flatMap { $0 > 1 ? "Attempt \($0)" : nil },
            "Started \(agentRowStamp(started))",
            agentElapsed(
                durationMs: agent.durationMs ?? 0,
                startedAt: started,
                endedAt: agent.endedAt,
                now: now),
            agent.reportedTokens.map { "\(formatTokens($0)) tokens" },
            agent.reportedToolCalls.map { "\($0) tool calls" },
        ].compactMap { $0 }.joined(separator: " · ")))
        if let model = appKitReportedChildModel(agent.model) {
            sections.append(("Model", model))
        }
        if let prompt = nonempty(agent.promptPreview) { sections.append(("Task", prompt)) }
        if let step {
            sections.append(("Current step", [
                step.label,
                step.target,
                agentStepDurationLabel(step.duration),
            ].compactMap { $0 }.joined(separator: " · ")))
        } else if let tool = nonempty(agent.lastToolName) {
            sections.append(("Latest tool", [
                tool,
                nonempty(agent.lastToolSummary),
            ].compactMap { $0 }.joined(separator: " · ")))
        }
        if !agent.toolEvents.isEmpty {
            sections.append((
                "Tool timeline",
                agent.toolEvents.map {
                    "\(agentRowStamp($0.at))  \($0.name)"
                }.joined(separator: "\n")))
        }
        if let result = nonempty(agent.resultPreview) { sections.append(("Result", result)) }
        if let error = nonempty(agent.error) { sections.append(("Error", error)) }
        textView.textStorage?.setAttributedString(attributedSections(sections))
        setAccessibilityLabel([
            name,
            "Workflow agent",
            agent.model.map { "Model \($0)" },
            agent.attempt.flatMap { $0 > 1 ? "Attempt \($0)" : nil },
            agent.state.label,
        ].compactMap { $0 }.joined(separator: ", "))
    }

    private func attributedSections(_ sections: [(String, String)]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let headingAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ]
        for (index, section) in sections.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n\n", attributes: bodyAttributes))
            }
            result.append(NSAttributedString(
                string: section.0.uppercased() + "\n",
                attributes: headingAttributes))
            result.append(NSAttributedString(string: section.1, attributes: bodyAttributes))
        }
        return result
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func statusColor(_ status: WorkflowStatus) -> NSColor {
        switch status {
        case .running: return .nInfoText
        case .completed: return .nSuccessText
        case .failed, .killed: return .nErrorText
        case .paused, .stopped: return .nWarningText
        case .pending: return .secondaryLabelColor
        }
    }

    private func updateSubagentStatus(_ subagent: SubagentRun) {
        let elapsed = agentElapsed(
            durationMs: subagent.durationMs,
            startedAt: subagent.startedAt,
            endedAt: subagent.endedAt,
            now: now)
        statusField.stringValue = "\(subagent.status.label) · \(elapsed)"
        statusField.textColor = statusColor(subagent.status)
        stopButton.isHidden = subagent.status != .running
        needsLayout = true
    }

    private func updateWorkflowStatus(_ workflow: WorkflowRun) {
        let aggregateStatus = effectiveRunStatus(workflow)
        let liveChildren = workflow.agents.values.filter { !$0.state.isTerminal }.count
        let parentEndedBeforeChildren = aggregateStatus.isTerminal && liveChildren > 0
        let status: WorkflowStatus = parentEndedBeforeChildren ? .running : aggregateStatus
        let elapsed = agentElapsed(
            durationMs: parentEndedBeforeChildren ? 0 : (workflow.usage?.durationMs ?? 0),
            startedAt: workflow.startedAt,
            endedAt: appKitWorkflowHasLiveWork(workflow) ? nil : workflow.endedAt,
            now: now)
        statusField.stringValue = liveChildren > 0
            ? "\(liveChildren) \(liveChildren == 1 ? "agent" : "agents") active · \(elapsed)"
            : "\(status.label) · \(elapsed)"
        statusField.textColor = statusColor(status)
        stopButton.isHidden = !appKitWorkflowHasLiveWork(workflow)
        needsLayout = true
    }

    private func updateWorkflowAgentStatus(_ agent: WorkflowAgent, run: WorkflowRun) {
        let status: WorkflowStatus
        switch agent.state {
        case .queued: status = .pending
        case .start, .progress: status = .running
        case .done: status = .completed
        case .failed: status = .failed
        case .stopped: status = .stopped
        }
        let elapsed = agentElapsed(
            durationMs: agent.durationMs ?? 0,
            startedAt: agent.startedAt ?? run.startedAt,
            endedAt: agent.endedAt,
            now: now)
        statusField.stringValue = "\(status.label) · \(elapsed)"
        statusField.textColor = statusColor(status)
        stopButton.isHidden = !agent.state.isRunning
        needsLayout = true
    }

    /// The id Stop should carry. Falls back to the run's own key when the provider never sent the
    /// SDK's task_* events, so a run with no `taskId` can still be stopped — see the card's
    /// `configure(subagent:)` for why hiding the button instead was wrong.
    private var currentTaskID: String? {
        if let subagent, subagent.status == .running { return subagent.taskId ?? subagent.key }
        if let workflowAgent, workflowAgent.state.isRunning { return workflow.map(runStopID) }
        if let workflow {
            if appKitWorkflowHasLiveWork(workflow) { return runStopID(workflow) }
        }
        return nil
    }

    private func runStopID(_ run: WorkflowRun) -> String {
        run.runTaskId ?? run.toolUseId ?? run.runKey
    }
}
