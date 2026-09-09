import Foundation

/// How wide the inspector is, PER WORKSPACE.
///
/// It used to be one number for every workspace, and that is only defensible while every tab wants
/// the same room. It stopped being true once an inspector could hold a document: a file list reads
/// fine at the ordinary panel width and prose does not. One shared number means widening it for the
/// document widens it for the folder workspace someone was working in, so nobody widens it.
///
/// Keyed and defaulted exactly like `InspectorTabPreference`, including its reasoning about Home:
/// `projectID == nil` is the default workspace, not "nowhere to store this", so it resolves to the
/// same fixed id the library uses for Home rather than a bucket meaning "any window without an id".
///
/// A view preference, so it lives in `UserDefaults` beside the tabs. Losing it costs one drag and
/// never a fact.
enum InspectorWidthPreference {

    static let minimum = 180.0
    static let maximum = 2000.0
    static let keyPrefix = "inspectorWidth."

    /// Canonical identity shared by topic workspaces (`projectID`) and folder workspaces (`cwd`).
    /// Folder-backed bridges intentionally keep `projectID == nil`; treating that as Home made
    /// every folder overwrite Home's inspector width.
    static func workspaceID(
        projectID: UUID?,
        cwd: String,
        projectIDForCwd: (String) -> UUID?
    ) -> UUID? {
        if let projectID { return projectID }
        guard !cwd.isEmpty else { return nil }
        return projectIDForCwd(cwd)
    }

    /// What a workspace opens at when nobody has dragged it.
    ///
    /// The Help workspace is wider because its inspector holds a document: prose, topics and cited
    /// product claims rather than a list of names.
    ///
    /// 560, NOT 720. 720 was chosen for a document panel alone without looking at what the rest of
    /// the window then did: on a 1566pt window it leaves the chat about 500pt, which pushes the
    /// composer's control bar out of its one-line tier into the wrapped one — where the model name
    /// breaks onto two lines inside its pill. That tier is for genuinely narrow windows and it read
    /// as a glitch, because nothing about that window was narrow.
    ///
    /// 560 is an article panel's own minimum (a 200pt list beside a 360pt article), so it is the
    /// least this can be without the article itself becoming the cramped one, and it leaves the
    /// chat the larger share. Anyone who wants more can drag it — the width is theirs and is
    /// remembered per workspace — and the wrapped bar is then a consequence they chose.
    static func `default`(workspaceID: UUID?) -> Double {
        workspaceID == HelpWorkspace.id ? 560 : 420
    }

    static func key(_ workspaceID: UUID?) -> String {
        "\(keyPrefix)\((workspaceID ?? SQLiteLibraryStore.homeWorkspaceID).uuidString)"
    }

    /// The stored width, or this workspace's default.
    ///
    /// A width outside the sane range is treated as absent rather than clamped: a stored 0 or a
    /// NaN from a corrupted plist should open the workspace at a usable size, not at a sliver the
    /// person then has to find and drag.
    static func width(workspaceID: UUID?, store: UserDefaults = .standard) -> Double {
        guard let raw = store.object(forKey: key(workspaceID)) as? Double,
              raw.isFinite, raw >= minimum, raw <= maximum else {
            return `default`(workspaceID: workspaceID)
        }
        return raw
    }

    static func setWidth(_ width: Double, workspaceID: UUID?, store: UserDefaults = .standard) {
        guard width.isFinite, width >= minimum, width <= maximum else { return }
        store.set(width, forKey: key(workspaceID))
    }

    /// The one-time carry-over from the single shared number, so a person who had dragged their
    /// inspector to a size they like does not find every workspace back at the default.
    ///
    /// Applied to Home only. Spraying the old value across every workspace would also give it to
    /// the Help workspace, whose whole point here is to open wider than the old shared value.
    static func migrateLegacyWidthIfNeeded(store: UserDefaults = .standard) {
        let legacyKey = "inspectorWidth"
        guard let legacy = store.object(forKey: legacyKey) as? Double,
              legacy.isFinite, legacy >= minimum, legacy <= maximum else { return }
        let home = key(nil)
        if store.object(forKey: home) == nil { store.set(legacy, forKey: home) }
        store.removeObject(forKey: legacyKey)
    }
}

/// Clears every current workspace-scoped geometry key as well as the retired global ones.
///
/// The Settings button previously removed only `inspectorWidth`, while the app has stored real
/// widths under `inspectorWidth.<workspace>` for years. It therefore claimed to reset the panel but
/// left the exact saved geometry that can put a narrow window on the non-resizable boundary.
enum LayoutPreferenceReset {
    private static let exactKeys = [
        "inspectorWidth", "terminalHeight", "filesPreviewHeight",
        "changesPreviewHeight", ArtifactWindowSplitSizing.preferenceKey,
        "uiTypeStep", "panel.terminal",
        "panel.inspector", "panel.sidebar", "panel.inspectorTab",
    ]
    private static let prefixes = [
        InspectorWidthPreference.keyPrefix,
        InspectorTabPreference.selectionKeyPrefix,
        "mech.ws.sidebar.",
        "NSWindow Frame mech.ws.frame.",
    ]

    static func reset(store: UserDefaults = .standard) {
        for key in exactKeys { store.removeObject(forKey: key) }
        for key in store.dictionaryRepresentation().keys
        where prefixes.contains(where: key.hasPrefix) {
            store.removeObject(forKey: key)
        }
        WorkspaceSessionLedger.clearWindowLayouts(from: store)
    }
}
