import AppKit
import Foundation

/// One-time repair for a short-lived sidebar persistence bug.
///
/// Before the wider conversation sidebar shipped, AppKit could report the split item's initial
/// 220-point minimum while the window was being constructed. That value was then written into both
/// the per-workspace preference and the session ledger even though the person had not resized the
/// divider. There is no provenance bit on records written by those releases, so the migration is
/// deliberately exact and one-time: it clears only that construction minimum. Once its marker is
/// present, a person may intentionally choose 220 points and that choice remains an ordinary saved
/// width.
enum WorkspaceSidebarWidthMigration {
    static let legacyConstructionMinimum = 220.0
    static let preferenceKeyPrefix = "mech.ws.sidebar."
    static let markerKey = "mech.ws.sidebar-construction-minimum-migration-v1"
    private static let version = 1

    static func migrateIfNeeded(in defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: markerKey) < version else { return }

        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(preferenceKeyPrefix) {
            guard isLegacyConstructionMinimum(defaults.object(forKey: key)) else { continue }
            // Removing rather than writing 340 keeps the value a genuine product default instead
            // of fabricating a per-workspace preference the person never selected.
            defaults.removeObject(forKey: key)
        }

        migrateSessionLayouts(in: defaults)
        defaults.set(version, forKey: markerKey)
    }

    private static func migrateSessionLayouts(in defaults: UserDefaults) {
        guard let data = defaults.data(forKey: WorkspaceSessionLedger.defaultsKey),
              var ledger = try? JSONDecoder().decode(WorkspaceSessionLedger.self, from: data),
              ledger.version <= WorkspaceSessionLedger.currentVersion else { return }

        var changed = false
        for index in ledger.windows.indices {
            guard var layout = ledger.windows[index].layout,
                  isLegacyConstructionMinimum(layout.sidebarWidth) else { continue }
            // A nil layout field follows the existing compatibility rule: per-workspace preference
            // first, then the current product default. That also lets an explicit non-220 legacy
            // preference remain authoritative when the ledger happened to capture construction.
            layout.sidebarWidth = nil
            ledger.windows[index].layout = layout
            changed = true
        }
        if changed { ledger.save(to: defaults) }
    }

    private static func isLegacyConstructionMinimum(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return number.doubleValue == legacyConstructionMinimum
    }

    private static func isLegacyConstructionMinimum(_ value: Double?) -> Bool {
        value == legacyConstructionMinimum
    }
}

/// A workspace window frame expressed as plain Codable values.
///
/// AppKit's geometry types are not the persistence contract. Keeping the four values explicit makes
/// an older ledger tolerant of future layout additions, while `rect` is the one validation boundary
/// before untrusted defaults can move or resize a window.
struct WorkspaceWindowFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: NSRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.size.width)
        height = Double(rect.size.height)
    }

    var rect: NSRect? {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0 else { return nil }
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

/// The presentation state of one workspace tab/window.
///
/// Every field is optional deliberately. A ledger written before layout capture existed, or one
/// containing one damaged preference, still restores its windows and falls back to the legacy
/// per-workspace/default value for only the missing part.
struct WorkspaceWindowLayout: Codable, Equatable {
    var frame: WorkspaceWindowFrame?
    var showsSidebar: Bool?
    var sidebarWidth: Double?
    var showsInspector: Bool?
    var inspectorPreferredWidth: Double?
    var showsTerminal: Bool?
    var terminalHeight: Double?

    init(
        frame: WorkspaceWindowFrame? = nil,
        showsSidebar: Bool? = nil,
        sidebarWidth: Double? = nil,
        showsInspector: Bool? = nil,
        inspectorPreferredWidth: Double? = nil,
        showsTerminal: Bool? = nil,
        terminalHeight: Double? = nil
    ) {
        self.frame = frame
        self.showsSidebar = showsSidebar
        self.sidebarWidth = sidebarWidth
        self.showsInspector = showsInspector
        self.inspectorPreferredWidth = inspectorPreferredWidth
        self.showsTerminal = showsTerminal
        self.terminalHeight = terminalHeight
    }

    enum CodingKeys: String, CodingKey {
        case frame, showsSidebar, sidebarWidth, showsInspector, inspectorPreferredWidth
        case showsTerminal, terminalHeight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Each field is independently tolerant. A malformed width must not cost the frame, and a
        // malformed frame must not cost the session topology around it.
        frame = try? container.decode(WorkspaceWindowFrame.self, forKey: .frame)
        showsSidebar = try? container.decode(Bool.self, forKey: .showsSidebar)
        sidebarWidth = try? container.decode(Double.self, forKey: .sidebarWidth)
        showsInspector = try? container.decode(Bool.self, forKey: .showsInspector)
        inspectorPreferredWidth = try? container.decode(
            Double.self, forKey: .inspectorPreferredWidth)
        showsTerminal = try? container.decode(Bool.self, forKey: .showsTerminal)
        terminalHeight = try? container.decode(Double.self, forKey: .terminalHeight)
    }

    func validSidebarWidth(_ range: ClosedRange<Double>) -> Double? {
        valid(sidebarWidth, in: range)
    }

    func validInspectorWidth(_ range: ClosedRange<Double>) -> Double? {
        valid(inspectorPreferredWidth, in: range)
    }

    func validTerminalHeight(_ range: ClosedRange<Double>) -> Double? {
        valid(terminalHeight, in: range)
    }

    private func valid(_ value: Double?, in range: ClosedRange<Double>) -> Double? {
        guard let value, value.isFinite, range.contains(value) else { return nil }
        return value
    }
}

/// The workspace windows that were open at quit, so relaunch returns the session instead of one
/// window.
///
/// **Strictly additive.** `lastLocationProjectID` and `lastConversationID` keep being written and
/// remain the fallback whenever the ledger is missing, empty, or unreadable. Delete this key and
/// behavior is byte-for-byte what it was before — which is also exactly what the first launch after
/// upgrade does, since no ledger exists yet.
///
/// One authority, extended from one window to N. `NSWindowRestoration` was rejected for this: it
/// would be a second restorer racing `openLastLocationOrHome`, and it silently does nothing when the
/// user has "Close windows when quitting an app" checked — the state-loss invariant failing for an
/// invisible reason.
struct WorkspaceSessionLedger: Equatable {
    /// Bumped only for a change this type cannot read tolerantly. An unknown version is treated as
    /// unreadable, which degrades to the fallback rather than guessing at a future layout.
    static let currentVersion = 1

    var version: Int = currentVersion
    var windows: [Entry] = []

    /// One workspace window. Windows sharing a `groupIndex` were one native tab group and come back
    /// as one, ordered by `tabIndex`.
    struct Entry: Equatable {
        /// The canonical workspace id. `nil` with an empty `cwd` is Home; nil + non-empty cwd is
        /// tolerated only when decoding a legacy ledger and must resolve to one existing Project.
        var projectID: UUID?
        /// The workspace's synchronized execution folder, retained so replay can construct the
        /// folder-backed bridge representation without using it as independent ownership evidence.
        var cwd: String = ""
        /// The conversation this window was showing.
        var conversationID: UUID?
        var groupIndex: Int = 0
        var tabIndex: Int = 0
        /// The window that had focus at quit. This selects the frontmost group's tab when replay
        /// orders it front; `wasSelected` separately preserves selection in every background group.
        var wasKey: Bool = false
        /// The selected tab in this native group. `wasKey` identifies the selected tab only in the
        /// frontmost group; every background group needs its own selection bit as well.
        var wasSelected: Bool = false
        /// Nil in ledgers written before per-window presentation capture. Replay then falls back to
        /// the existing per-workspace/default layout without losing the window itself.
        var layout: WorkspaceWindowLayout? = nil
        /// An explicit, settled empty tab is a window the person arranged. Older ledgers also contain
        /// nil-conversation placeholder rows produced by races, so absence of this marker keeps the
        /// historical safety rule: prune the row rather than manufacture a duplicate Home window.
        var restoresBlankTab: Bool = false

        var isHome: Bool { projectID == nil && cwd.isEmpty }
    }
}

// MARK: - Persistence

extension WorkspaceSessionLedger: Codable {
    enum CodingKeys: String, CodingKey { case version, windows }

    /// Tolerant by hand, not by synthesis. A synthesized `Decodable` ignores property defaults, so a
    /// field added later would make every older ledger fail to decode as a whole — the trap that
    /// quarantined conversations in 0.11.7. Here that would silently cost a session on upgrade.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        windows = try container.decodeIfPresent([Entry].self, forKey: .windows) ?? []
    }
}

extension WorkspaceSessionLedger.Entry: Codable {
    enum CodingKeys: String, CodingKey {
        case projectID, cwd, conversationID, groupIndex, tabIndex, wasKey, wasSelected
        case layout, restoresBlankTab
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        conversationID = try container.decodeIfPresent(UUID.self, forKey: .conversationID)
        groupIndex = try container.decodeIfPresent(Int.self, forKey: .groupIndex) ?? 0
        tabIndex = try container.decodeIfPresent(Int.self, forKey: .tabIndex) ?? 0
        wasKey = try container.decodeIfPresent(Bool.self, forKey: .wasKey) ?? false
        wasSelected = (try? container.decode(Bool.self, forKey: .wasSelected)) ?? false
        layout = try? container.decode(WorkspaceWindowLayout.self, forKey: .layout)
        restoresBlankTab =
            (try? container.decode(Bool.self, forKey: .restoresBlankTab)) ?? false
    }
}

extension WorkspaceSessionLedger {
    static let defaultsKey = "mech.session.ledger"

    /// `nil` for absent, empty, corrupt, or written by a future version — every one of which means
    /// "fall back to the single-window keys", never "throw" and never "open nothing".
    static func load(from defaults: UserDefaults = .standard) -> WorkspaceSessionLedger? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        guard let ledger = try? JSONDecoder().decode(WorkspaceSessionLedger.self, from: data),
              ledger.version <= currentVersion,
              !ledger.windows.isEmpty else { return nil }
        return ledger
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// Remove only captured window geometry/panel presentation while preserving the windows and tabs
    /// the session ledger is responsible for reopening. Settings uses this alongside the legacy
    /// preference-key reset; deleting the whole ledger would turn "Reset Layout" into "Forget my
    /// open windows".
    static func clearWindowLayouts(from defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: defaultsKey),
              var ledger = try? JSONDecoder().decode(WorkspaceSessionLedger.self, from: data),
              ledger.version <= currentVersion else { return }
        for index in ledger.windows.indices { ledger.windows[index].layout = nil }
        ledger.save(to: defaults)
    }
}

// MARK: - What to reopen

/// The validate / normalize / dedupe / never-empty rules, as a pure function of the ledger and what
/// still exists. Kept separate from replay so the rules can be tested without building an
/// `NSWindow`, a toolbar, a split view, and a started bridge for every case.
enum WorkspaceSessionPlan {
    /// A tab group to rebuild: one canonical Workspace and its durable or explicit blank tabs, in
    /// order.
    struct Group: Equatable {
        var windows: [WorkspaceSessionLedger.Entry]
    }

    /// `nil` means "nothing survivable is in the ledger" — the caller falls back to
    /// `openLastLocationOrHome()`, which is today's behavior and the never-empty guarantee.
    static func restore(
        ledger: WorkspaceSessionLedger,
        projectExists: (UUID) -> Bool,
        conversationExists: (UUID) -> Bool,
        projectIDForLegacyCwd: (String) -> UUID? = { _ in nil },
        conversationBelongsToWorkspace: (UUID, UUID?) -> Bool = { _, _ in true }
    ) -> [Group]? {
        // Stable even when a damaged/older ledger reused the same indices. Swift's sort is not
        // documented stable, so retain the encoded array offset as the final ordering key.
        let ordered = ledger.windows.enumerated().sorted { lhs, rhs in
            if lhs.element.groupIndex != rhs.element.groupIndex {
                return lhs.element.groupIndex < rhs.element.groupIndex
            }
            if lhs.element.tabIndex != rhs.element.tabIndex {
                return lhs.element.tabIndex < rhs.element.tabIndex
            }
            return lhs.offset < rhs.offset
        }

        var kept: [Candidate] = []
        var seen: Set<Key> = []
        var focusTarget: FocusTarget?
        var selectionTargets: [WorkspaceKey: FocusTarget] = [:]
        for recorded in ordered {
            var entry = recorded.element
            let workspace: WorkspaceKey
            // A workspace deleted since quit is not reopened. Home has no id and always survives.
            // Older ledgers represented folder workspaces by cwd alone; accept that only when the
            // full path maps to one existing Project, and persist the canonical id in the plan.
            if let projectID = entry.projectID {
                guard projectExists(projectID) else { continue }
                workspace = .project(projectID)
            } else if !entry.cwd.isEmpty {
                guard let projectID = projectIDForLegacyCwd(entry.cwd),
                      projectExists(projectID) else { continue }
                entry.projectID = projectID
                workspace = .project(projectID)
            } else {
                workspace = .home
            }

            // Remember focus after Workspace validation but before pruning a stale Conversation.
            // If its exact tab is gone, focus can still transfer to another durable tab in the same
            // Workspace rather than falling through to an unrelated first group.
            if entry.wasKey, focusTarget == nil {
                focusTarget = FocusTarget(
                    workspace: workspace,
                    conversationID: entry.conversationID,
                    recordedGroupIndex: entry.groupIndex,
                    recordedTabIndex: entry.tabIndex)
            }

            // Every native group has a selected tab, including groups behind the key window. Record
            // the first credible target per canonical Workspace before pruning so a selected stale
            // Conversation can transfer selection to a surviving sibling in that same group.
            if entry.wasSelected, selectionTargets[workspace] == nil {
                selectionTargets[workspace] = FocusTarget(
                    workspace: workspace,
                    conversationID: entry.conversationID,
                    recordedGroupIndex: entry.groupIndex,
                    recordedTabIndex: entry.tabIndex)
            }

            if let conversationID = entry.conversationID {
                guard conversationExists(conversationID),
                      conversationBelongsToWorkspace(conversationID, entry.projectID)
                else { continue }

                // One Workspace owns one native tab group. A duplicate record of the same
                // Conversation in another former group must not recreate a second tab.
                let key = Key(workspace: workspace, conversationID: conversationID)
                guard seen.insert(key).inserted else { continue }
                // A malformed row cannot be both a durable Conversation and an explicit blank.
                entry.restoresBlankTab = false
            } else {
                // Old ledgers contain nil-conversation placeholder rows that were never real windows
                // to restore. Only the explicit additive marker distinguishes a settled blank tab the
                // person left open, and distinct marked blanks intentionally remain distinct.
                guard entry.restoresBlankTab else { continue }
            }
            entry.wasKey = false
            entry.wasSelected = false
            kept.append(Candidate(
                entry: entry,
                workspace: workspace,
                recordedGroupIndex: entry.groupIndex))
        }
        guard !kept.isEmpty else { return nil }

        if let focusTarget {
            if let focusedIndex = targetIndex(focusTarget, in: kept) {
                kept[focusedIndex].entry.wasKey = true
            }
        }

        // Normalize to exactly one selected tab per canonical Workspace. A key window is necessarily
        // selected and wins a malformed conflict. Otherwise honor the recorded selection, transfer a
        // stale target within its group/workspace, and let an older ledger default to its first tab.
        var canonicalWorkspaceOrder: [WorkspaceKey] = []
        for candidate in kept where !canonicalWorkspaceOrder.contains(candidate.workspace) {
            canonicalWorkspaceOrder.append(candidate.workspace)
        }
        for workspace in canonicalWorkspaceOrder {
            let selectedIndex = kept.firstIndex {
                $0.workspace == workspace && $0.entry.wasKey
            } ?? selectionTargets[workspace].flatMap { targetIndex($0, in: kept) }
                ?? kept.firstIndex { $0.workspace == workspace }
            if let selectedIndex { kept[selectedIndex].entry.wasSelected = true }
        }

        // A malformed ledger can split one Workspace across native groups, or mix Workspaces in a
        // group. Canonical Workspace identity—not the recorded AppKit group—is authoritative. The
        // first surviving appearance orders groups; the stable ledger order above orders their tabs.
        var workspaceOrder: [WorkspaceKey] = []
        var byWorkspace: [WorkspaceKey: [WorkspaceSessionLedger.Entry]] = [:]
        for candidate in kept {
            if byWorkspace[candidate.workspace] == nil {
                workspaceOrder.append(candidate.workspace)
            }
            byWorkspace[candidate.workspace, default: []].append(candidate.entry)
        }
        return workspaceOrder.compactMap { byWorkspace[$0].map(Group.init(windows:)) }
    }

    private enum WorkspaceKey: Hashable {
        case home
        case project(UUID)
    }

    private struct Candidate {
        var entry: WorkspaceSessionLedger.Entry
        let workspace: WorkspaceKey
        let recordedGroupIndex: Int
    }

    private struct FocusTarget {
        let workspace: WorkspaceKey
        let conversationID: UUID?
        let recordedGroupIndex: Int
        let recordedTabIndex: Int
    }

    private struct Key: Hashable {
        let workspace: WorkspaceKey
        let conversationID: UUID
    }

    private static func targetIndex(
        _ target: FocusTarget,
        in candidates: [Candidate]
    ) -> Int? {
        let exactConversation = target.conversationID.flatMap { conversationID in
            candidates.firstIndex {
                $0.workspace == target.workspace
                    && $0.entry.conversationID == conversationID
            }
        }
        let exactBlankPosition = target.conversationID == nil ? candidates.firstIndex {
            $0.workspace == target.workspace
                && $0.entry.conversationID == nil
                && $0.recordedGroupIndex == target.recordedGroupIndex
                && $0.entry.tabIndex == target.recordedTabIndex
        } : nil
        let sameRecordedGroup = candidates.firstIndex {
            $0.workspace == target.workspace
                && $0.recordedGroupIndex == target.recordedGroupIndex
        }
        let sameWorkspace = candidates.firstIndex { $0.workspace == target.workspace }
        return exactConversation ?? exactBlankPosition ?? sameRecordedGroup ?? sameWorkspace
    }
}

// MARK: - Capture

/// Reading the current session off the live windows.
///
/// Derived from `AgentBridge.live.allObjects` because `liveWorkspaceWindows` is `private` at file
/// scope in `MechanicianApp.swift` and unreachable from here.
///
/// **Captured at terminate and nowhere else.** The obvious alternative — capturing when a window
/// becomes key — fires *during replay*, so the first restored window would rewrite the ledger to one
/// entry and destroy the session mid-restore. That is the shape of the v0.80 incident. Having one
/// capture point at quit means replay provably cannot shrink the ledger, which is a stronger
/// guarantee than a flag someone has to remember to check.
enum WorkspaceSessionCapture {
    /// Prefer the installed selection, but retain an authoritative row that is still hydrating when
    /// the process quits. An empty current placeholder is skipped in favor of that pending target.
    static func durableConversationID(
        currentID: UUID?,
        pendingSelectionID: UUID?,
        openingConversationID: UUID?,
        isDurable: (UUID) -> Bool
    ) -> UUID? {
        [currentID, pendingSelectionID, openingConversationID]
            .compactMap { $0 }
            .first(where: isDurable)
    }

    /// Whether this window represents an intentional, settled tab with no durable Conversation.
    ///
    /// A current id may name the empty placeholder `prepareForTermination` just pruned, so its mere
    /// presence is not content. Pending/opening ids and unresolved initial presentation are different:
    /// they are work still deciding what the tab is, and must never be reclassified as blank.
    static func restoresBlankTab(
        currentID: UUID?,
        pendingSelectionID: UUID?,
        openingConversationID: UUID?,
        initialViewResolutionPending: Bool,
        isDurable: (UUID) -> Bool
    ) -> Bool {
        guard !initialViewResolutionPending,
              pendingSelectionID == nil,
              openingConversationID == nil else { return false }
        guard let currentID else { return true }
        return !isDurable(currentID)
    }

    /// The tab group each window belongs to, and its position within it, as AppKit reports them.
    /// A window in no tab group is its own group of one.
    @MainActor static func current(bridges: [AgentBridge]) -> WorkspaceSessionLedger {
        var groupIndexByGroup: [ObjectIdentifier: Int] = [:]
        var standaloneCursor = 0
        var entries: [WorkspaceSessionLedger.Entry] = []

        for bridge in bridges {
            guard let window = bridge.window,
                  window.tabbingIdentifier == kWorkspaceTabbingID else { continue }
            let groupIndex: Int
            let tabIndex: Int
            if let group = window.tabGroup, group.windows.count > 1 {
                let identifier = ObjectIdentifier(group)
                if let existing = groupIndexByGroup[identifier] {
                    groupIndex = existing
                } else {
                    groupIndex = standaloneCursor
                    groupIndexByGroup[identifier] = groupIndex
                    standaloneCursor += 1
                }
                tabIndex = group.windows.firstIndex(of: window) ?? 0
            } else {
                groupIndex = standaloneCursor
                standaloneCursor += 1
                tabIndex = 0
            }
            let projects = ProjectStore.shared.projects
            let isDurable: (UUID) -> Bool = { id in
                guard let summary = bridge.store.summary(id),
                      let scope = WorkspaceScope.resolve(
                          summary: summary,
                          projects: projects)
                else { return false }
                return scope.canonicalBinding(projects: projects) != nil
            }
            let conversationID = durableConversationID(
                currentID: bridge.currentID,
                pendingSelectionID: bridge.pendingSelectionID,
                openingConversationID: bridge.openingConversationID,
                isDurable: isDurable)
            let restoresBlankTab = Self.restoresBlankTab(
                currentID: bridge.currentID,
                pendingSelectionID: bridge.pendingSelectionID,
                openingConversationID: bridge.openingConversationID,
                initialViewResolutionPending: bridge.initialViewResolutionPending,
                isDurable: isDurable)
            let focused = window.isKeyWindow || window.isMainWindow
            let selected = window.tabGroup.map { $0.selectedWindow === window } ?? true
            let frameWindow = window.tabGroup?.selectedWindow ?? window
            let layout = (window.delegate as? WorkspaceToolbarController)?
                .windowLayoutSnapshot(frameWindow: frameWindow)
            let binding: (projectID: UUID?, cwd: String)?
            if let conversationID,
               let summary = bridge.store.summary(conversationID),
               let scope = WorkspaceScope.resolve(summary: summary, projects: projects) {
                // A still-hydrating unscoped bridge has not adopted the target's Workspace yet. The
                // authoritative summary, not that transient bridge scope, owns the ledger pairing.
                binding = scope.canonicalBinding(projects: projects)
            } else if (restoresBlankTab || focused),
                      let scope = WorkspaceScope.resolve(
                          projectID: bridge.projectID,
                          cwd: bridge.cwd,
                          projects: projects) {
                // A settled blank is a real tab and is captured whether or not its group is focused.
                // An unresolved focused row remains an unmarked focus-transfer record; the planner
                // drops it as content but can transfer focus to a surviving sibling.
                binding = scope.canonicalBinding(projects: projects)
            } else {
                binding = nil
            }
            guard let binding else { continue }
            entries.append(WorkspaceSessionLedger.Entry(
                projectID: binding.projectID,
                cwd: binding.cwd,
                conversationID: conversationID,
                groupIndex: groupIndex,
                tabIndex: tabIndex,
                wasKey: focused,
                wasSelected: selected,
                layout: layout,
                restoresBlankTab: restoresBlankTab))
        }
        return WorkspaceSessionLedger(windows: entries)
    }
}
