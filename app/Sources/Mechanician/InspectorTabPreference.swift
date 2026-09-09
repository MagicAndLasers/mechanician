import Foundation

/// Which inspector tabs a workspace shows, and in what order.
///
/// This is the cheap half of David's extension question: *"Should we be able to remove default tabs
/// and add others to each workspace?"* Tab VISIBILITY is a property of the container, which is the
/// same shape as the existing folder-or-no-folder rule, and it needs no public contract, no trust
/// boundary and no rendering seam. Third-party tabs — a real plugin surface — are a separate
/// decision recorded in FR-269 and deliberately not started here.
///
/// It is stored in `UserDefaults`, per workspace id, alongside `inspectorWidth`. It is a view
/// preference: losing it costs a person one menu visit and never a fact, so it does not belong in
/// either database.
///
/// TWO THINGS ARE NOT PREFERENCES, and keeping them out is the whole safety of this:
///
/// 1. **Files and Changes require a working folder.** Git in a folder-less workspace runs in
///    agentd's global cwd — the last-opened project — so staging, committing and pushing would act
///    on the wrong repository. A person may hide those tabs and may never conjure them.
/// 2. **A workspace may never show nothing.** An empty tab bar is an inspector that looks broken,
///    and the way out of it would be the menu it just hid.
enum InspectorTabPreference {
    static let selectionKeyPrefix = "inspectorSelectedTab."
    static let helpTabMigrationKey = "inspectorTabs.addedHelpWorkspaceTab.v1"

    /// Tabs that cannot be shown without a working folder, whatever anyone prefers. See above.
    static let requiresFolder: Set<InspectorTab> = [.files, .changes]

    /// What a workspace shows when nobody has said otherwise.
    ///
    /// A tab present in every workspace is a tab most workspaces do not want, so a record panel
    /// belongs to the app-owned workspace it is the record for and nowhere else by default.
    static func defaults(cwd: String, workspaceID: UUID?) -> [InspectorTab] {
        // The Help expert's closed profile uses signed Help plus bounded presentation and app
        // operation; it does not create artifacts or run agents or skills. Empty panels for those
        // absent capabilities make that intentional boundary look like missing functionality, so
        // its app-owned workspace starts with the record it is for.
        if workspaceID == HelpWorkspace.id { return [.help] }
        return cwd.isEmpty
            ? [.artifacts, .agents, .skills]
            : [.files, .changes, .artifacts, .agents, .skills]
    }

    /// The last tab the person chose in this workspace.
    ///
    /// Selection used to live in one process-global `panel.inspectorTab` value. Restoring a
    /// folder-backed workspace's Files selection into folder-less Home made `InspectorView` replace
    /// it with Artifacts, and that fallback then overwrote the global value. The next open therefore
    /// looked like the inspector always defaulted to Artifacts instead of returning to where the
    /// person left it. Selection is a workspace preference for the same reason tab visibility and
    /// width already are.
    static func selected(
        cwd: String,
        workspaceID: UUID?,
        store: UserDefaults = .standard
    ) -> InspectorTab {
        let shown = visible(cwd: cwd, workspaceID: workspaceID, store: store)
        let primaryKey = selectionKey(workspaceID, cwd: cwd)
        var candidateKeys = [primaryKey]
        if workspaceID != nil, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Carry a choice made during the cwd-before-UUID launch edge into the durable workspace
            // identity as soon as it becomes available.
            candidateKeys.append(selectionKey(nil, cwd: cwd))
        }
        for key in candidateKeys {
            guard let raw = store.string(forKey: key),
                  let tab = InspectorTab(rawValue: raw),
                  shown.contains(tab) else { continue }
            if key != primaryKey { store.set(tab.rawValue, forKey: primaryKey) }
            return tab
        }
        // Reserved record workspaces have meaningful first pages. Once the person chooses another
        // visible tab there, the per-workspace value above wins on every later visit and relaunch.
        if workspaceID == HelpWorkspace.id, shown.contains(.help) { return .help }
        // One-way compatibility for installations that predate per-workspace selection.
        if let raw = store.string(forKey: legacySelectionKey),
           let tab = InspectorTab(rawValue: raw),
           shown.contains(tab) {
            return tab
        }
        return shown.first ?? .artifacts
    }

    /// Record an explicit user selection. Automatic Artifacts/Agents announcements deliberately do
    /// not call this: after that temporary interruption, closing and reopening returns to the tab
    /// the person chose.
    static func setSelected(
        _ tab: InspectorTab,
        cwd: String,
        workspaceID: UUID?,
        store: UserDefaults = .standard
    ) {
        guard visible(cwd: cwd, workspaceID: workspaceID, store: store).contains(tab) else { return }
        store.set(tab.rawValue, forKey: selectionKey(workspaceID, cwd: cwd))
        // Keep the old value current for a rollback to a build that only understands the global key.
        store.set(tab.rawValue, forKey: legacySelectionKey)
    }

    /// The tabs to draw: the person's choice if they made one, otherwise the defaults — with the
    /// folder rule applied last so it cannot be overridden by a stored value or by a workspace that
    /// used to have a folder and no longer does.
    static func visible(
        cwd: String,
        workspaceID: UUID?,
        store: UserDefaults = .standard
    ) -> [InspectorTab] {
        let chosen = stored(workspaceID: workspaceID, store: store)
            ?? defaults(cwd: cwd, workspaceID: workspaceID)
        let allowed = chosen.filter { !cwd.isEmpty || !requiresFolder.contains($0) }
        // Never nothing. A person who hides everything has hidden the menu that would bring it back.
        return allowed.isEmpty ? [.artifacts] : allowed
    }

    /// True when this workspace has a choice of its own, so the menu can offer to undo it.
    static func isCustomized(workspaceID: UUID?, store: UserDefaults = .standard) -> Bool {
        stored(workspaceID: workspaceID, store: store) != nil
    }

    /// Show or hide one tab, keeping the canonical order rather than the order things were toggled.
    ///
    /// Order is `InspectorTab.allCases`, so the bar cannot end up in an arrangement the groups and
    /// their dividers do not expect. Reordering is a separate ask and not this one.
    static func setVisible(
        _ visible: Bool,
        tab: InspectorTab,
        cwd: String,
        workspaceID: UUID?,
        store: UserDefaults = .standard
    ) {
        var tabs = Set(self.visible(cwd: cwd, workspaceID: workspaceID, store: store))
        if visible {
            // The folder rule again, at the write. Refusing here as well as at the read means a
            // stored value can never carry a tab that would run git in the wrong repository.
            guard !cwd.isEmpty || !requiresFolder.contains(tab) else { return }
            tabs.insert(tab)
        } else {
            tabs.remove(tab)
            guard !tabs.isEmpty else { return }
        }
        store.set(
            InspectorTab.allCases.filter(tabs.contains).map(\.rawValue),
            forKey: key(workspaceID))
    }

    /// Back to what this kind of workspace shows out of the box.
    static func reset(workspaceID: UUID?, store: UserDefaults = .standard) {
        store.removeObject(forKey: key(workspaceID))
    }

    /// Put Help into a pre-feature customized Help workspace exactly once.
    ///
    /// Help workspaces shipped before their inspector tab. A person who customized that
    /// workspace already has a stored array, so changing the defaults alone would never expose the
    /// new record to them. Preserve their raw list (including values a newer/older build may know),
    /// append only Help, and mark the migration so hiding it later remains a real choice. When no
    /// custom list exists, write nothing: the defaults should remain defaults rather than becoming
    /// an app-authored preference that future additions cannot evolve.
    static func migrateExistingHelpWorkspaceTabIfNeeded(
        store: UserDefaults = .standard
    ) {
        guard !store.bool(forKey: helpTabMigrationKey) else { return }
        if var raw = store.array(forKey: key(HelpWorkspace.id)) as? [String],
           !raw.contains(InspectorTab.help.rawValue) {
            raw.append(InspectorTab.help.rawValue)
            store.set(raw, forKey: key(HelpWorkspace.id))
        }
        store.set(true, forKey: helpTabMigrationKey)
    }

    // MARK: - Storage

    /// HOME IS A WORKSPACE, and it carries `projectID == nil` in the bridge.
    ///
    /// Treating nil as "nowhere to store this" would have made the default workspace the one
    /// workspace whose tabs could not be chosen — and Home is where most people start. It resolves
    /// to the same fixed id the library already uses for Home, so the key is stable rather than a
    /// bucket meaning "any window without an id".
    static func key(_ workspaceID: UUID?) -> String {
        "inspectorTabs.\((workspaceID ?? SQLiteLibraryStore.homeWorkspaceID).uuidString)"
    }

    static func selectionKey(_ workspaceID: UUID?, cwd: String = "") -> String {
        if let workspaceID {
            return "\(selectionKeyPrefix)\(workspaceID.uuidString)"
        }
        let normalizedCwd = URL(fileURLWithPath: cwd.trimmingCharacters(in: .whitespacesAndNewlines))
            .standardizedFileURL.path
        if !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A folder window can temporarily know its cwd before ProjectStore has published its
            // UUID. A stable path key keeps that window distinct from Home during this launch edge.
            let encoded = Data(normalizedCwd.utf8).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "=", with: "")
            return "\(selectionKeyPrefix)cwd.\(encoded)"
        }
        return "\(selectionKeyPrefix)\(SQLiteLibraryStore.homeWorkspaceID.uuidString)"
    }

    private static let legacySelectionKey = "panel.inspectorTab"

    /// Unknown raw values are dropped rather than failing the whole list: a tab retired in a later
    /// build must not turn someone's customised bar into the defaults without explanation, and a
    /// build that adds one must not be blocked by a stored list that predates it.
    private static func stored(workspaceID: UUID?, store: UserDefaults) -> [InspectorTab]? {
        guard let raw = store.array(forKey: key(workspaceID)) as? [String] else { return nil }
        let tabs = raw.compactMap(InspectorTab.init(rawValue:))
        return tabs.isEmpty ? nil : tabs
    }
}

/// Use the restored Help panel state, otherwise keep the inspector closed.
///
/// The signed Help record remains available from the panel, but a fresh window must not claim
/// screen space before the person has chosen to show it. A bridge applies this only on its first
/// Help entry so switching away and back preserves the choice made in that window.
enum HelpWorkspaceInspectorVisibilityPolicy {
    static func resolve(restoredVisibility: Bool?) -> Bool {
        restoredVisibility ?? false
    }
}
