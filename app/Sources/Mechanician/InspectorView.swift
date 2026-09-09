import SwiftUI
import AppKit

/// Delayed hover activation shared by the Files tab and its focused tests. A DispatchWorkItem makes
/// leaving the tab cancel synchronously, before a queued main-run-loop callback can switch panels.
final class InspectorTabSpringLoader {
    static let artifactHoverDelay: TimeInterval = 0.65

    private var pending: DispatchWorkItem?
    private var pendingToken: UUID?

    var hasPendingActivation: Bool { pendingToken != nil }

    func setTargeted(
        _ targeted: Bool,
        delay: TimeInterval = artifactHoverDelay,
        activate: @escaping () -> Void
    ) {
        cancel()
        guard targeted else { return }

        let token = UUID()
        pendingToken = token
        let work = DispatchWorkItem { [weak self] in
            guard self?.pendingToken == token else { return }
            self?.pending = nil
            self?.pendingToken = nil
            activate()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancel() {
        pendingToken = nil
        pending?.cancel()
        pending = nil
    }

    deinit {
        pending?.cancel()
    }
}

/// Keeps the ArtifactsPanelView (and therefore SwiftUI's drag source) alive after spring-loading the
/// Files tab. The final mouse-up/drop or Escape ends retention on the next run-loop turn; a bounded
/// expiry is a crash/cancel fallback for drags that end outside this process.
final class InspectorArtifactDragRetention: ObservableObject {
    @Published private(set) var active = false
    private var endMonitor: Any?
    private var expiration: DispatchWorkItem?
    private var buttonReleasePoll: DispatchWorkItem?

    @MainActor
    func begin(expirationDelay: TimeInterval = 60, monitorEvents: Bool = true) {
        active = true
        expiration?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.end()
        }
        expiration = work
        DispatchQueue.main.asyncAfter(deadline: .now() + expirationDelay, execute: work)

        guard monitorEvents, endMonitor == nil else { return }
        endMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) {
            [weak self] event in
            let ended = event.type == .leftMouseUp
                || (event.type == .keyDown && event.keyCode == 53) // Escape
            if ended {
                // Let the destination consume the provider before removing its originating view.
                DispatchQueue.main.async { self?.end() }
            }
            return event
        }
        pollForButtonRelease()
    }

    @MainActor
    func end() {
        expiration?.cancel()
        expiration = nil
        buttonReleasePoll?.cancel()
        buttonReleasePoll = nil
        if let endMonitor {
            NSEvent.removeMonitor(endMonitor)
            self.endMonitor = nil
        }
        active = false
    }

    /// A drag released outside the process may not produce a local mouse-up event. AppKit's global
    /// pressed-button bit remains observable without accessibility permission, so polling it while
    /// the short retention lease is active closes that cancellation path too.
    @MainActor
    private func pollForButtonRelease() {
        buttonReleasePoll?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active else { return }
            if NSEvent.pressedMouseButtons & 1 == 0 {
                self.end()
            } else {
                self.pollForButtonRelease()
            }
        }
        buttonReleasePoll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    deinit {
        expiration?.cancel()
        buttonReleasePoll?.cancel()
        if let endMonitor {
            NSEvent.removeMonitor(endMonitor)
        }
    }
}

/// Only artifact drags advertise Mechanician's private reference type. Watching that type rather
/// than every file URL prevents ordinary Finder drags across the inspector chrome from changing tabs.
private struct ArtifactFilesTabSpringLoadTarget: ViewModifier {
    let enabled: Bool
    let onTargeted: (Bool) -> Void
    @State private var targeted = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrop(
                    of: [ArtifactActions.referencePasteboardType.rawValue],
                    isTargeted: Binding(
                        get: { targeted },
                        set: {
                            targeted = $0
                            onTargeted($0)
                        }),
                    perform: { _ in false })
                .onDisappear {
                    if targeted {
                        targeted = false
                        onTargeted(false)
                    }
                }
        } else {
            content
        }
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    // Shortcuts stays an AGENT capability (the RunShortcut tool), not a user inspector tab.
    // Build was retired: the agent builds and fixes its own errors (results land as tool cards).
    // Changes has two explicit sources: current Git state and this conversation's agent activity.
    // Skills sits here rather than in the Extensions window because a skill is only
    // meaningful relative to the next message you send — and this placement answers the
    // provider question without a selector, since the conversation already declares its lane.
    // Help is GLOBAL scope: the same record whichever workspace or conversation you are in, which
    // is why it sits after its own divider rather than beside Artifacts.
    //
    // RAW VALUES ARE STORED: per-workspace tab choices persist by raw value and an unknown one is
    // dropped, so renaming a case silently resets every customised tab bar. That drop is also what
    // makes a retired tab safe — a saved `wiki` from before the Memory removal reads as no choice
    // rather than as a decode failure.
    case files, changes, artifacts, agents, skills, help
    var id: String { rawValue }
    /// Localized here rather than at each call site.
    ///
    /// `label` is a plain `String`, so `Text(label)` takes SwiftUI's verbatim overload and never
    /// translates — which is what the localization ratchet counts. Doing it once means every reader
    /// can use `Text(verbatim:)` and be both localized and honest about it.
    var label: String {
        switch self {
        case .files: return String(localized: "Files")
        case .changes: return String(localized: "Changes")
        case .artifacts: return String(localized: "Artifacts")
        case .agents: return String(localized: "Agents")
        case .skills: return String(localized: "Skills")
        case .help: return String(localized: "Help")
        }
    }
    /// The semantic Guided Help anchor for this tab. Naming it here keeps the guide vocabulary and
    /// the tab bar from developing two different ideas of which control "Changes" means.
    var guidedHelpTarget: GuidedHelpPresentationTarget {
        switch self {
        case .files: return .conversationFilesTab
        case .changes: return .conversationChangesTab
        case .artifacts: return .conversationArtifactsTab
        case .agents: return .conversationAgentsTab
        case .skills: return .conversationSkillsTab
        case .help: return .helpInspectorTab
        }
    }
    var icon: String {
        switch self {
        case .files: return "folder"
        case .changes: return "arrow.triangle.branch"
        case .artifacts: return "square.stack.3d.up"
        case .agents: return "person.2"
        case .skills: return "sparkles"
        // The Help workspace's own glyph, so the tab and the place it opens read as one thing.
        case .help: return HelpWorkspace.iconSymbol
        }
    }
}

/// A person activated an inspector tab, including a second press on the tab already on screen.
///
/// `inspectorTab` alone cannot carry this event: assigning the same enum case publishes no state
/// change to a surface that is already visible. The revision makes each explicit press observable
/// without conflating it with automatic tab restoration.
struct InspectorTabUserActivation: Equatable {
    let tab: InspectorTab
    let revision: UInt64
}

/// Responsive chrome for one inspector tab.
///
/// The inspector itself deliberately has no fixed maximum width. Its controls still need one: a
/// Help workspace starts with a single tab, and allowing that tab to accept an infinite proposal
/// turns its selection pill (and Guided Help target) into a banner across a wide inspector. The
/// zero minimum keeps the existing cramped-panel behavior: tabs may compress before the native
/// inspector resize contract or its protected chat floor is disturbed.
enum InspectorTabBarMetrics {
    static let idealTabWidth: CGFloat = 52
    static let maximumTabWidth: CGFloat = 68

    static func boundedTabWidth(proposed: CGFloat) -> CGFloat {
        guard proposed.isFinite else { return proposed > 0 ? maximumTabWidth : 0 }
        return min(max(0, proposed), maximumTabWidth)
    }

    static func accessibilityIdentifier(for tab: InspectorTab) -> String {
        "inspector.tab.\(tab.rawValue)"
    }
}

/// The bounded, testable tab control shared by every inspector group.
///
/// Keep the semantic Guided Help anchor on this exact bounded button. Attaching it to a flexible
/// group would make the spotlight describe empty toolbar space rather than the control it names.
struct InspectorTabButtonChrome: View {
    let tab: InspectorTab
    let active: Bool
    let badgeText: String?
    let badgeIsLive: Bool
    let highlighted: Bool
    let guideRegistry: GuidedHelpTargetRegistry?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: tab.icon)
                    .scaledFont(13, weight: active ? .semibold : .regular)
                    .overlay(alignment: .topTrailing) {
                        if let badgeText {
                            InspectorTabBadge(text: badgeText, live: badgeIsLive)
                                .offset(x: 11, y: -6)
                        }
                    }
                Text(verbatim: tab.label)
                    .scaledFont(10, weight: active ? .semibold : .regular)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(active ? Color.nInfoText : .secondary)
            .frame(
                minWidth: 0,
                idealWidth: InspectorTabBarMetrics.idealTabWidth,
                maxWidth: InspectorTabBarMetrics.maximumTabWidth)
            .padding(.vertical, 5)
            // The accent tint the rest of the app already uses to say "this one is on" — the
            // toolbar's own toggles, the activity panel's selected segment, and `PillButtonStyle`
            // all fill at 0.16. It replaces an `nElevated` fill that was legible only because this
            // column used to be a white surface: on the window background it is 0.925 against
            // 0.940 in Light Mode, so the active tab would have had no marker at all. The label is
            // already accent-coloured when active, so the pill agrees with it rather than
            // introducing a second idea of selection.
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(active || highlighted
                    ? Color.nAccent.opacity(0.16)
                    : Color.clear))
            .overlay {
                if highlighted && !active {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.nAccent.opacity(0.65), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(
            minWidth: 0,
            idealWidth: InspectorTabBarMetrics.idealTabWidth,
            maxWidth: InspectorTabBarMetrics.maximumTabWidth)
        .help(tab.label)
        .accessibilityIdentifier(InspectorTabBarMetrics.accessibilityIdentifier(for: tab))
        .guidedHelpTarget(tab.guidedHelpTarget, registry: guideRegistry)
    }
}

/// One right-hand inspector with a segmented tab bar — the single tool area, rather
/// than four competing columns.
struct InspectorView: View {
    @EnvironmentObject private var bridge: AgentBridge
    @ObservedObject private var skillSeenState = SkillInventorySeenState.shared
    @ObservedObject private var guidanceRouter = MechanicianGuidanceRouter.shared
    @AppStorage("uiTypeStep") private var typeStep = 0
    @State private var filesSpringLoader = InspectorTabSpringLoader()
    @State private var filesTabDragTargeted = false
    @StateObject private var artifactDragRetention = InspectorArtifactDragRetention()
    @State private var guidedHelpCoordinator: GuidedHelpPresentationCoordinator?

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
        .environment(\.uiScale, uiScale(typeStep)) // scale panel text with ⌘+/-
        // Panel utility icons (refresh, push, stage, etc.) are monochrome — tint drives
        // borderless-button content color. The active tab and primary (.borderedProminent)
        // buttons set their own accent explicitly, so they're unaffected.
        .tint(.secondary)
        // Width is owned by RootView (draggable + persisted); icon tabs stay legible even
        // when the panel is narrow, so no minWidth floor is needed here.
        //
        // THE WINDOW BACKGROUND, and it must stay that. The window is `fullSizeContentView` with a
        // transparent titlebar on purpose, so this column's frame reaches the top of the window and
        // its background paints through the toolbar. Any colour but the window's own draws a band
        // across the titlebar and a vertical seam beside the chat, running the full height of the
        // window — which is exactly what an `nSurface` column did here, invisibly while it was
        // 360pt against the window's edge and glaring the moment the wiki opened it wide.
        //
        // Three attempts tried to keep the surface and hide it under the toolbar instead: an inset
        // by `safeAreaInsets.top` (0 for a column hosted in an AppKit split view, so nothing
        // changed), an inset by a measured titlebar height (cut a white band through the middle of
        // the tab bar), and an overlay strip in `detailColumnsBody` (the measurement read 0 at the
        // moment it was used). All three were geometry, and geometry is what kept being wrong.
        // Matching the window needs no measurement at all, which is the whole reason it holds.
        //
        // The consequence is that panels here draw their own surfaces, as the chat's do — cards and
        // wells fill `nSurface` over this, and a state marker cannot use `nElevated`: measured off
        // the running app, it is 0.925 against this background's 0.940 in Light Mode — four levels
        // at 8 bits, which is a fill nobody can see.
        .background(Color.nBg)
        // Both columns are the window's colour now, so nothing separates them. A hairline does the
        // work the colour change used to do by accident — the same one the AppKit split view draws
        // down the sidebar's edge, and it runs the full height for the same reason that one does.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                // TO THE TOP OF THE WINDOW, like the sidebar's. `.background` takes the ShapeStyle
                // overload, which ignores the safe area by default and is why this column's fill
                // reached the titlebar at all; an overlay has no such default and stopped at the
                // toolbar's lower edge. Measured, not assumed: the split view's own divider is
                // there at y=24, and a right-hand divider that begins 50 points lower than the
                // left-hand one reads as the short one being broken.
                .ignoresSafeArea()
                .accessibilityHidden(true)
                // The real resize target is a topmost overlay spanning both columns. This line is
                // visual only; if it participates in hit testing, a natural click on the divider
                // lands on the inspector instead of beginning the drag.
                .allowsHitTesting(false)
        }
        .onAppear {
            ensureVisibleTab()
            if bridge.inspectorTab == .changes { bridge.refreshGit() }
            reconcileGuidedHelpCoordinator()
            // The AppKit window claim can settle one run-loop after its SwiftUI content appears.
            DispatchQueue.main.async { reconcileGuidedHelpCoordinator() }
        }
        // Selection is per workspace. Switching workspaces restores where that workspace was left
        // rather than carrying an unavailable tab across and collapsing it to Artifacts.
        .onChange(of: bridge.projectID) {
            bridge.restoreInspectorTabSelection()
            reconcileGuidedHelpCoordinator()
            DispatchQueue.main.async { reconcileGuidedHelpCoordinator() }
        }
        .onChange(of: bridge.currentID) {
            reconcileGuidedHelpCoordinator()
            DispatchQueue.main.async { reconcileGuidedHelpCoordinator() }
        }
        .onDisappear {
            guidedHelpCoordinator?.exit()
            guidedHelpCoordinator = nil
            filesSpringLoader.cancel()
            artifactDragRetention.end()
        }
        .onChange(of: bridge.inspectorTab) { _, tab in
            if tab == .changes { bridge.refreshGit() }
            if tab == .help {
                reconcileGuidedHelpCoordinator()
                DispatchQueue.main.async { reconcileGuidedHelpCoordinator() }
            } else {
                guidedHelpCoordinator?.exit()
                guidedHelpCoordinator = nil
            }
            if artifactDragRetention.active,
               tab != .files,
               tab != .artifacts {
                artifactDragRetention.end()
            }
        }
        .onChange(of: bridge.cwd) {
            bridge.restoreInspectorTabSelection()
            if bridge.cwd.isEmpty {
                filesTabDragTargeted = false
                filesSpringLoader.cancel()
                artifactDragRetention.end()
            }
        }
    }

    // A persisted `.git` selection from before the merge decodes to nil (case removed) and falls
    // back to the default tab — no migration needed.

    /// Which tabs this workspace shows.
    ///
    /// Per-workspace now rather than one global list. The rules that are NOT preferences live in
    /// `InspectorTabPreference`: Files and Changes need a working folder, because git in a
    /// folder-less workspace runs in agentd's global cwd and would stage the wrong repository; and a
    /// workspace may never show nothing, because the way back would be the menu it just hid.
    private var visibleTabs: [InspectorTab] {
        let stored = bridge.visibleInspectorTabs()
        // Presentation-only. A signed guide may reveal the exact semantic tabs it points at while
        // it is active, but it never edits the person's per-workspace UserDefaults choice, and the
        // folder rule still refuses Files and Changes in a folderless workspace.
        return MechanicianGuidanceInspectorTabs.visible(
            stored: stored,
            forced: guidanceRouter.forcedInspectorTabs(for: bridge),
            allowsFolderTabs: !bridge.cwd.isEmpty)
    }

    private func ensureVisibleTab() {
        if !visibleTabs.contains(bridge.inspectorTab) {
            bridge.restoreInspectorTabSelection()
        }
    }

    private func reconcileGuidedHelpCoordinator() {
        guard bridge.inspectorTab == .help,
              HelpWorkspace.owns(bridge.projectID),
              let window = bridge.window else {
            guidedHelpCoordinator?.exit()
            guidedHelpCoordinator = nil
            return
        }
        if guidedHelpCoordinator?.owner.matches(bridge: bridge, window: window) == true {
            return
        }
        guidedHelpCoordinator?.exit()
        guidedHelpCoordinator = GuidedHelpPresentationCoordinator(
            bridge: bridge,
            window: window)
    }

    /// A divider keeps workspace state distinct from the active conversation without adding
    /// another navigation level or visual clutter.
    private var tabBar: some View {
        let hasWorkspaceOrConversationTab = visibleTabs.contains {
            [.files, .changes, .artifacts, .agents, .skills].contains($0)
        }
        let hasGlobalRecordTab = visibleTabs.contains(.help)
        return HStack(alignment: .top, spacing: 8) {
            tabGroup("Workspace", tabs: [.files, .changes])
            if visibleTabs.contains(.files) {
                Rectangle()
                    .fill(Color.nMuted.opacity(0.42))
                    .frame(width: 1, height: 38)
                    .padding(.top, 14)
                    .accessibilityHidden(true)
            }
            tabGroup("Conversation", tabs: [.artifacts, .agents, .skills])
            // Conditional like the first one. The global records are absent from most workspaces
            // by default, and an unconditional divider would leave a hairline with nothing after it.
            if hasWorkspaceOrConversationTab, hasGlobalRecordTab {
                Rectangle()
                    .fill(Color.nMuted.opacity(0.42))
                    .frame(width: 1, height: 38)
                    .padding(.top, 14)
                    .accessibilityHidden(true)
            }
            tabGroup("Everywhere", tabs: [.help])
            // Tabs describe controls, not available width. Any room left after the bounded groups
            // belongs here, keeping a one-tab Help workspace from painting a selected banner.
            Spacer(minLength: 0)
            customizeButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // Right-click the bar to choose what it holds. A context menu rather than another control:
        // the bar is already three groups and two dividers at a 180pt minimum width, and David would
        // rather drop a feature than ship a crowded one. The same menu is in the workspace menu, so
        // it is discoverable without knowing to right-click.
        .contextMenu { tabCustomizationMenu }
    }

    /// The visible way in. A context menu alone is not discoverable, and one menu with two triggers
    /// is better than a second copy of it built in AppKit for the workspace toolbar.
    private var customizeButton: some View {
        Menu {
            tabCustomizationMenu
        } label: {
            Image(systemName: "slider.horizontal.3").scaledFont(11)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.top, 10)
        .help("Choose which tabs this workspace shows")
        .accessibilityLabel("Choose which tabs this workspace shows")
    }

    /// The menu that manages the bar, shared by its two triggers so they cannot offer different
    /// sets.
    @ViewBuilder
    var tabCustomizationMenu: some View {
        ForEach(InspectorTab.allCases) { tab in
            let shown = visibleTabs.contains(tab)
            let allowed = !bridge.cwd.isEmpty
                || !InspectorTabPreference.requiresFolder.contains(tab)
            // A TOGGLE, not a Button with a drawn checkmark. AppKit renders a menu item's state as
            // the platform checkmark; a `Button` label containing an `Image` is not guaranteed to
            // draw it, and `Image(systemName: "")` for the unchecked case is not a symbol at all —
            // so the menu showed no state and there was no way to see what was already displayed.
            //
            // This is the one place a stock control is right: a checkmark in a menu IS the Mac
            // idiom, and drawing our own inside a system menu would be the thing that looks wrong.
            Toggle(isOn: Binding(
                get: { shown },
                set: { wanted in
                    bridge.setInspectorTabVisible(wanted, tab: tab)
                    bridge.inspectorTabRevision &+= 1
                    ensureVisibleTab()
                })) {
                Text(verbatim: tab.label)
            }
            .disabled(!allowed)
        }
        Divider()
        Button {
            bridge.resetInspectorTabVisibility()
            bridge.inspectorTabRevision &+= 1
            ensureVisibleTab()
        } label: {
            Text("Restore Default Tabs")
        }
        .disabled(!bridge.hasCustomizedInspectorTabVisibility())
    }

    @ViewBuilder
    private func tabGroup(_ title: String, tabs: [InspectorTab]) -> some View {
        let available = tabs.filter(visibleTabs.contains)
        if !available.isEmpty {
            HStack(spacing: 2) {
                ForEach(available) { tabButton($0) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
        }
    }

    /// Icon + label tabs stay compact at narrow panel widths; the active tab uses the accent.
    private func tabButton(_ tab: InspectorTab) -> some View {
        let active = bridge.inspectorTab == tab
        let tabBadge = badge(for: tab)
        let routedRegistry = guidanceRouter.registry(for: bridge)
        return InspectorTabButtonChrome(
            tab: tab,
            active: active,
            badgeText: tabBadge?.text,
            badgeIsLive: tabBadge?.live ?? false,
            highlighted: tab == .files && filesTabDragTargeted,
            guideRegistry: routedRegistry ?? guidedHelpCoordinator?.registry,
            action: { bridge.userSelectedInspectorTab(tab) })
        .modifier(ArtifactFilesTabSpringLoadTarget(enabled: tab == .files) {
            updateFilesTabSpringLoad(targeted: $0)
        })
    }

    private func updateFilesTabSpringLoad(targeted: Bool) {
        filesTabDragTargeted = targeted
        if targeted, bridge.inspectorTab == .artifacts {
            artifactDragRetention.begin()
        } else if !targeted, bridge.inspectorTab == .artifacts {
            // The drag left before the delayed switch; the ordinary visible source needs no lease.
            artifactDragRetention.end()
        }
        guard targeted,
              bridge.inspectorTab != .files,
              visibleTabs.contains(.files) else {
            filesSpringLoader.cancel()
            return
        }
        filesSpringLoader.setTargeted(true) {
            guard !bridge.cwd.isEmpty else { return }
            bridge.userSelectedInspectorTab(.files)
        }
    }

    /// A small count badge on a tab so you can see, without opening it, that a panel has
    /// something: artifacts made, files changed, agents running, or build errors.
    ///
    /// `live` marks a count that is *happening* rather than accumulated. Agents are the only such
    /// count: rendered identically to the static ones it read as "3 things exist in there" instead of
    /// "3 agents are working right now", which is the one thing worth interrupting a glance for.
    private func badge(for tab: InspectorTab) -> (text: String, live: Bool)? {
        switch tab {
        case .help:
            // Deliberately no badge. A count of statements is inventory, and inventory on a tab
            // reads as "something needs you". Help claims are immutable build inventory for the
            // same reason, not an attention count.
            return nil
        case .skills:
            // This is attention, not inventory: opening Skills acknowledges the current route's
            // visible invocation identities, and only genuinely new identities raise it again.
            let n = skillSeenState.unseenCount(
                in: bridge.slashCommands,
                scope: .current(for: bridge))
            return n > 0 ? (n > 99 ? "99+" : "\(n)", false) : nil
        case .artifacts:
            let n = bridge.artifacts.count
            return n > 0 ? (n > 99 ? "99+" : "\(n)", false) : nil
        case .agents:
            // Use the same workflow-aware, provider-id-de-duplicated count as the transcript.
            let n = bridge.runningAgentCount
            return n > 0 ? ("\(n)", true) : nil
        case .changes:
            let n: Int
            if bridge.git.belongs(to: bridge.cwd), bridge.git.isRepo {
                n = Set(bridge.git.files.map(\.path)).count
            } else if bridge.git.belongs(to: bridge.cwd), bridge.git.probe == .notRepository {
                n = bridge.currentID.flatMap { bridge.touchedFiles[$0] }?
                    .filter { $0.edits > 0 }.count ?? 0
            } else {
                n = 0
            }
            return n > 0 ? (n > 99 ? "99+" : "\(n)", false) : nil
        case .files:
            return nil
        }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            // Keep this first child structurally stable while the Files view is inserted above it.
            // Opacity alone is insufficient unless the source remains in the hierarchy.
            if bridge.inspectorTab == .artifacts || artifactDragRetention.active {
                ArtifactsPanelView()
                    .opacity(bridge.inspectorTab == .artifacts ? 1 : 0)
                    .allowsHitTesting(bridge.inspectorTab == .artifacts)
                    .accessibilityHidden(bridge.inspectorTab != .artifacts)
            }
            if bridge.inspectorTab != .artifacts {
                nonArtifactContent
            }
        }
    }

    @ViewBuilder
    private var nonArtifactContent: some View {
        switch bridge.inspectorTab {
        case .files: FileBrowserPanelView()
        case .changes:
            ChangesPanelView(
                evidence: bridge.changesInspectorEvidence,
                evidenceLoadFailed: bridge.conversationWorkEvidenceLoadFailed,
                onRequestContext: bridge.queueConversationWorkContext)
        case .agents: AgentsPanel()
        case .skills: SkillsPanel()
        // THE FOLD. The wiki tab used to be a narrow read-only lens whose pop-out opened a second
        // window over the same workspace. It is the record itself now — pages, article, review
        // queue, curation, build — in the one window the workspace has. `WikiPanelView` is retired;
        // re-implementing the record beside the record is how the last lookalike surface diverged.
        case .help: HelpInspectorView(guideCoordinator: guidedHelpCoordinator)
        case .artifacts: EmptyView()
        }
    }
}

/// A tab count badge. A `live` badge breathes and carries a halo, so work in progress is
/// distinguishable at a glance from a count of things that merely exist.
private struct InspectorTabBadge: View {
    let text: String
    let live: Bool
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .scaledFont(8, weight: .bold)
            .foregroundStyle(.white)
            .padding(.horizontal, 3).padding(.vertical, 0.5)
            .background(Capsule().fill(Color.nSolidActionFill))
            .overlay {
                if live {
                    Capsule()
                        .stroke(
                            Color.nSolidActionFill.opacity(pulsing ? 0.0 : 0.55),
                            lineWidth: pulsing ? 3.5 : 0)
                }
            }
            .fixedSize()
            .onAppear {
                // Respect Reduce Motion: the halo still marks it as live, it just does not animate.
                guard live, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    pulsing = true
                }
            }
            .accessibilityLabel(live ? "\(text) running" : text)
    }
}
