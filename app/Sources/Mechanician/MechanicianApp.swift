import Darwin
import SwiftUI

/// SQLite is the only product authority. A pristine installation is provisioned before this
/// decision; a migrated installation arrives with a verified marker/database pair. Everything
/// else is recovery-only and no longer constructs the retired JSON library.
enum StorageAuthorityLaunchDecision: Equatable, Sendable {
    case product
    case recovery

    static func resolve(
        recognition: StorageAuthorityRecognition,
        ownsProcessLease: Bool
    ) -> Self {
        guard ownsProcessLease,
              case .sqlite(_, let database) = recognition.disposition,
              database.authorityState == .active else { return .recovery }
        return .product
    }
}

/// Process-owned scene decision shared by SwiftUI and every non-scene ingress gate.
@MainActor
final class StorageAuthorityLaunchState: ObservableObject {
    static let shared = StorageAuthorityLaunchState()

    @Published private(set) var recognition = StorageAuthorityRecognition.legacyDefault(
        root: MechanicianEnvironment.currentSupportRoot())
    @Published private(set) var decision = StorageAuthorityLaunchDecision.recovery
    private(set) var isConfigured = false

    var sceneRecognition: StorageAuthorityRecognition {
        guard decision == .recovery else { return recognition }
        return StorageAuthorityRecognition(
            anchorRoot: recognition.anchorRoot,
            effectiveSupportRoot: recognition.effectiveSupportRoot,
            marker: recognition.marker,
            disposition: .blocked(
                recognition.disposition.blockingMessage
                    ?? "Storage recovery must finish before Mechanician can open this library."))
    }

    @discardableResult
    func configure(
        recognition: StorageAuthorityRecognition,
        decision: StorageAuthorityLaunchDecision
    ) -> Bool {
        guard !isConfigured else { return false }
        self.recognition = recognition
        self.decision = decision
        isConfigured = true
        return true
    }
}
import AppKit
import CoreSpotlight

struct ApplicationOpenURLPartition: Equatable {
    let conversationRecords: [URL]
    let enterpriseProfiles: [URL]
    let attachmentFiles: [URL]
    let links: [URL]

    init(_ urls: [URL]) {
        conversationRecords = urls.filter(ExperimentalConversationRecordFileType.matches)
        enterpriseProfiles = urls.filter(TenantProfile.matchesProfileDocument)
        attachmentFiles = urls.filter {
            $0.isFileURL
                && !ExperimentalConversationRecordFileType.matches($0)
                && !TenantProfile.matchesProfileDocument($0)
        }
        links = urls.filter { !$0.isFileURL }
    }
}

// A SwiftPM executable launches as an accessory by default; promote to a regular
// foreground app so the window appears and takes focus.
// AppKit invokes this delegate on the main thread; every callback that arrives from a worker is
// explicitly returned to the main queue before touching delegate state.
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let notificationRelayLaunch = BackgroundNotificationRelay.isRequested(
        arguments: ProcessInfo.processInfo.arguments)

    /// Arrival policy for `mechanician://` links. Both pieces are plain values so the rules they
    /// carry are testable without launching an app — see `MechanicianURL`.
    private var linkRateLimiter = URLRouteRateLimiter()
    private var launchLinkQueue = LaunchLinkQueue()

    func applicationWillFinishLaunching(_ notification: Notification) {
        MechanicianTypography.registerBundledProductDisplayFont()
        NotificationManager.shared.configure()
        // Appearance is an application preference, not a property of whichever SwiftUI scene
        // happened to observe AppStorage first. Applying it before any window is constructed makes
        // workspace, Settings, utility, and updater windows inherit one live AppKit appearance.
        MainActor.assumeIsolated { applyAppAppearance() }
        if notificationRelayLaunch {
            // A scheduler relay is a short-lived, UI-less invocation of the signed app executable.
            // Establish the application identity without stealing focus or constructing windows.
            NSApp.setActivationPolicy(.prohibited)
        }
        // Tahoe can automatically merge a newly ordered workspace window into the current
        // full-screen window because every workspace intentionally shares one tabbing identifier.
        // Keep File ▸ New Tab's explicit `addTabbedWindow` path, but never let AppKit reinterpret a
        // Open Workspace in New Window request according to the user's automatic-tabbing
        // preference.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if notificationRelayLaunch {
            deliverBackgroundNotificationAndTerminate()
            return
        }
        let backgroundVerification = Bundle.main.bundleIdentifier == "ai.mechanician.app.dev"
            && ProcessInfo.processInfo.environment["MECHANICIAN_DEV_BACKGROUND"] == "1"
        // Names Edit ▸ Undo/Redo after the action they will undo. Installed before any window
        // exists so the very first menu read is already correct.
        EditMenuActionNames.shared.install()
        // The pristine bootstrap has already run under the process lease. Product and recovery use
        // the same immutable decision SwiftUI consumed; there is no asynchronous migration worker.
        continueNormalLaunch(backgroundVerification: backgroundVerification)
    }

    /// Everything the app does on an ordinary launch, once the storage decision is settled.
    ///
    @MainActor
    private func continueNormalLaunch(backgroundVerification: Bool) {
        // The root decision was made before SwiftUI could materialize a scene-owned store. Recovery
        // mode leaves the recovery-only Scene as the sole UI and constructs no product authority.
        guard StorageAuthorityLaunchState.shared.decision == .product else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.focusStorageRecoveryWindow()
            } }
            return
        }
        if let profileError = TenantProfile.startupError {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Mechanician can't load the enterprise configuration"
            alert.informativeText = profileError + (TenantProfile.currentIsManagedByMDM
                ? " Contact your administrator, then reopen Mechanician."
                : " Remove or replace the profile, then reopen Mechanician.")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        if let configurationError = TenantProfile.configurationError(
            profile: TenantProfile.current,
            bundleIdentifier: Bundle.main.bundleIdentifier
        ) {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Mechanician can't open this enterprise build"
            alert.informativeText = configurationError + " Install the standard Mechanician app instead."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        // Run before any bridge or session ledger is read. Older releases could persist the
        // split view's temporary 220-point construction minimum, which otherwise wins over the
        // newer 340-point conversation-sidebar default during restoration.
        WorkspaceSidebarWidthMigration.migrateIfNeeded()
        // Drag/share exports are scratch files, not user documents. Clear crash leftovers before
        // this session can create a new provider, and clear the paired in-memory identity map too.
        ArtifactActions.pruneTemporaryExports()
        ExperimentalConversationRecordExporter.recoverAbandonedExports()
        // Process-targeted Dev verification must not steal focus from the installed app the user is
        // dogfooding. This opt-in is honored only by the distinct Dev bundle; release launches keep
        // their normal foreground/splash behavior even if an inherited environment is surprising.
        NSApp.setActivationPolicy(backgroundVerification ? .accessory : .regular)
        if !backgroundVerification {
            NSApp.activate(ignoringOtherApps: true)
            showSplashScreen()   // brand the launch + mask the brief scene-window flash (see below)
        }
        let earliestSplashDismissal = Date().addingTimeInterval(2)
        ProviderAccountStore.prepareOnboardingPreference()
        // A signed profile may opt into launch-time refresh. Manual mode makes the same verified
        // check available only from Providers, so an unmanaged install never contacts the
        // publisher merely because Mechanician opened. MDM-supplied configuration is local too.
        Task { await TenantProfileUpdater.shared.checkAutomaticallyIfNeeded() }
        if !backgroundVerification { NotificationManager.shared.requestAuthorization() }
        // A `swift run` dev build has no bundled icon, so its Dock icon is blank.
        // Set it explicitly (bundle first, then a dev path from the env).
        let iconPath = Bundle.main.path(forResource: "Mechanician", ofType: "icns")
            ?? ProcessInfo.processInfo.environment["MECHANICIAN_ICON"]
        if let iconPath, let img = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = img
        }
        // Services: "Mechanician ▸ New Conversation With Selection" and friends, from any app's
        // Services menu. The plist declares them; this is the object those messages are sent to.
        // Skipped for the relay, which has no windows and exists to deliver one notification.
        if !notificationRelayLaunch {
            NSApp.servicesProvider = MainActor.assumeIsolated { MechanicianServiceProvider.shared }
        }
        // Refresh the parameterized App Shortcut phrases ("Open the <conversation> conversation…")
        // with current entity values so Siri/Shortcuts suggestions stay in sync.
        MechanicianShortcuts.updateAppShortcutParameters()
        // No SwiftUI WindowGroup auto-launches a workspace window anymore (every workspace window is
        // hand-built so they all get the flush-left unified toolbar), so open the first workspace
        // here. Every utility Window scene is explicitly launch-suppressed, so there is no delayed
        // window-closing sweep that could race with a user opening Settings just after launch.
        DispatchQueue.main.async { MainActor.assumeIsolated {
            // Register migration and restoration before constructing bridges. Session validation
            // requires the complete authoritative inventory: optimistic pre-ready validation used
            // to turn missing Conversation ids into duplicate blank Home windows on relaunch. The
            // eager/test path remains inline.
            ConversationStore.shared.whenLaunchInventoryResolved {
                let finishWindowPresentation = {
                    if backgroundVerification {
                        NSApp.windows.forEach { $0.orderBack(nil) }
                    } else {
                        let delay = max(0, earliestSplashDismissal.timeIntervalSinceNow)
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            MainActor.assumeIsolated { dismissSplashScreen() }
                        }
                    }
                }
                guard ConversationStore.shared.isReady else {
                    // Fail closed on data, but not on UI. A workspace shell exposes the store's
                    // persistence banner; leaving no window after the splash hid the only error.
                    openLastLocationOrHome()
                    finishWindowPresentation()
                    return
                }
                // The first of the two waits a person actually feels. Recorded before the
                // post-readiness work below so it measures the sidebar becoming usable, not the
                // Spotlight/Workspace/inbox follow-up that runs after it.
                LaunchMetrics.shared.markInventoryReady(
                    usedSQLiteInventory: ConversationStore.shared.usedSQLiteLaunchInventory,
                    conversationCount: ConversationStore.shared.summaries.count)
                // Refresh Spotlight from the already-recovered bounded inventory. The former
                // launch call independently parsed every Conversation JSON file and could contend
                // with the exact transcript the window was trying to reveal.
                SpotlightIndex.reindexAll(
                    conversationSummaries: ConversationStore.shared.summaries)
                ProjectStore.shared.migrateIfNeeded()
                ProjectStore.shared.repairConversationWorkspaceBindings()
                // External/background producers publish immutable create envelopes. Only the
                // lease-owning app may adopt them into today's Legacy authority, and only after
                // the complete inventory and Workspace bindings are ready.
                AuthorityInboxAdopter.shared.start(
                    conversationStore: ConversationStore.shared)
                // Everything above holds the main actor before session restoration asks any window
                // for its Conversation, so it is spent inside the wait for the transcript rather
                // than beside it. Measured separately for exactly that reason.
                LaunchMetrics.shared.mark(.launchFollowUp)
                // Release migration leftovers once the library has been authoritative for a week
                // and has proved itself. Public builds used to skip this behind a dogfood-only
                // shadow flag, stranding multi-gigabyte rollback generations indefinitely.
                ConversationStore.shared.whenLaunchProjectionSettles {
                    // Today's backup first, then the reclaim. The reclaim's precondition is a
                    // VERIFIED backup, so with nothing taking one it could never open — and nothing
                    // had taken one since the migration that owned that call was retired.
                    LibraryBackupLauncher.runAfterLaunch {
                        StorageRollbackReclaimLauncher.runAfterLaunch()
                    }
                    // Independent of that chain, and deliberately not nested inside it: the
                    // reverted Runtime Service's storage is read by nothing, so releasing it needs
                    // no backup, no soak and no integrity proof. Gating it behind the backup would
                    // strand gigabytes on anyone whose backup has not yet been verified.
                    RuntimeResidueReclaimLauncher.runAfterLaunch()
                    // Also independent: the copies schema upgrades leave behind. Its two rules come
                    // from the filenames alone, so it needs neither the backup chain above nor the
                    // migration-era coverage proof.
                    SupersededAuthorityReclaimLauncher.runAfterLaunch()
                }
                restoreWorkspaceSession()
                // All workspace-creating ingress (Spotlight, App Intents, Finder, Dock reopen) was
                // held behind this one-shot fence, so replay is always the first window authority.
                WorkspaceSessionLaunchGate.shared.completeRestore()
                // Restore has run. Anything `mechanician://` delivered during launch can now act on
                // the workspace the user actually left open rather than replacing it.
                for route in self.launchLinkQueue.restored() { ActiveWorkspace.shared.open(route) }
                finishWindowPresentation()
            }
        } }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// End AppKit's nested menu loop before Mechanician gives up activation. A captured incident
    /// left `NSMenuTrackingSession` alive after the menu disappeared, so losing activation is a
    /// recovery edge for an otherwise stranded tracking session.
    func applicationWillResignActive(_ notification: Notification) {
        NSApp.mainMenu?.cancelTrackingWithoutAnimation()
    }

    /// Coming back to Mechanician is the earliest honest evidence that a turn is coming, and the
    /// daemon's idle warm spare has usually lapsed by then. Without this, the first re-arm was the
    /// first keystroke, which on a managed Vertex machine leaves a couple of seconds of typing
    /// against a spin-up measured at about 15 s (#38).
    ///
    /// Only the focused workspace re-arms. A lane holds exactly one spare, so a background window
    /// arming its own would evict the one the user is about to need.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !notificationRelayLaunch,
              MainActor.assumeIsolated({
                  StorageAuthorityLaunchState.shared.decision == .product
              }) else { return }
        MainActor.assumeIsolated {
            ActiveWorkspace.shared.bridge?.noteComposerActivity()
        }
    }

    /// Don't orphan the in-process scheduler child when the app quits (the launchd agent, if
    /// installed, keeps running independently — this only stops the app-owned one).
    func applicationWillTerminate(_ notification: Notification) {
        guard !notificationRelayLaunch else { return }
        guard MainActor.assumeIsolated({
            StorageAuthorityLaunchState.shared.decision == .product
        }) else { return }
        MainActor.assumeIsolated {
            // ⌘Q does not reliably deliver windowWillClose to each window, so the per-window
            // save-on-close is skipped at quit — persist every open workspace's frame + sidebar here
            // so the size you left it at survives to the next launch (FR-96).
            for coordinator in workspaceCoordinators.values { coordinator.saveWindowLayout() }
            // The one capture point for multi-window restore. Quit is the only moment the whole
            // session is both settled and still alive; capturing on window focus instead would fire
            // during replay and shrink the ledger to one entry. See `WorkspaceSessionCapture`.
            let liveBridges = AgentBridge.live.allObjects
            for bridge in liveBridges { bridge.prepareForTermination() }
            // A utility-only session can have no live bridge, and background turns are resident in
            // the shared store rather than any bridge's foreground transcript. Stage every pending
            // live checkpoint once more after all foreground folds, then drain the authority queue.
            ConversationStore.shared.prepareForTermination()
            // An early quit or authority-load failure has no closed inventory with which to judge
            // durable tabs. Preserve the previous ledger instead of overwriting it from a partial
            // projection; the next successful launch can validate it authoritatively.
            if ConversationStore.shared.isReady {
                WorkspaceSessionCapture.current(bridges: liveBridges).save()
            }
            AmbientStore.shared.stopInProcessRunner()
            ExperimentalConversationRecordExporter.cancelAndWaitForExports()
            // Drain the conversation/project write queues here too, not only from a live bridge's
            // willTerminate observer: with all workspace windows closed, no bridge observer exists,
            // so a mutation made from a utility window (rename/delete a workspace in the launcher)
            // could be lost when the process exits before its utility-QoS write block runs.
            ConversationStore.shared.flushSaves()
            ProjectStore.shared.flushSaves()
            ArtifactStore.shared.flushSaves()
            ArtifactActions.pruneTemporaryExports()
            MechanicianRelaunch.launchReplacementIfRequested()
        }
    }

    @MainActor
    private func deliverBackgroundNotificationAndTerminate() {
        let environment = ProcessInfo.processInfo.environment
        let directory = BackgroundNotificationRelay.requestDirectory(
            environment: environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        let launch = BackgroundNotificationRelay.consume(
            arguments: ProcessInfo.processInfo.arguments,
            requestDirectory: directory)
        guard case .deliver(let payload) = launch else {
            NSApp.terminate(nil)
            return
        }

        NotificationManager.shared.notify(
            title: payload.title,
            body: payload.body,
            openWindowID: payload.openWindowID,
            conversationID: payload.conversationID
        ) { error in
            if let error {
                NSLog("Mechanician background notification failed: %@", error.localizedDescription)
            }
            NSApp.terminate(nil)
        }
        // The notification service should always invoke its completion handler, but the relay must
        // never become a stranded duplicate app process if the OS service is unhealthy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            NSApp.terminate(nil)
        }
    }

    /// Dock-icon reopen. With no workspace WindowGroup to recreate a window automatically, open a
    /// hand-built workspace window ourselves when the app is reactivated with no workspace window
    /// visible (e.g. only utility windows open).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard MainActor.assumeIsolated({
            StorageAuthorityLaunchState.shared.decision == .product
        }) else {
            MainActor.assumeIsolated { focusStorageRecoveryWindow() }
            return true
        }
        // Focus an existing workspace window (deminiaturizing a minimized one) instead of spawning a
        // duplicate — a minimized window is not `isVisible`, so the old `isVisible`-only test opened a
        // second window that then re-restored the same conversation.
        focusOrOpenWorkspaceAfterSessionRestore()
        return true
    }

    /// Launch Services sends owned `.convrec` and `.mechanician-profile` documents plus Finder/Dock
    /// attachment drops here. Both owned types are intercepted before the generic `public.item`
    /// route: opening a profile must lead to signed review, never attach configuration bytes to a
    /// conversation.
    /// `mechanician://` links arrive here too — this is the modern replacement for the `kAEGetURL`
    /// Apple Event handler — so all three classes are separated before any is acted on.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard MainActor.assumeIsolated({
            StorageAuthorityLaunchState.shared.decision == .product
        }) else {
            MainActor.assumeIsolated { focusStorageRecoveryWindow() }
            return
        }
        MainActor.assumeIsolated {
            let partition = ApplicationOpenURLPartition(urls)
            // The inspector intentionally owns one reusable window. A normal Finder double-click
            // carries one document; if an automation sends several at once, inspect the first and
            // still keep every `.convrec` out of the attachment/import path.
            if let record = partition.conversationRecords.first {
                ExperimentalConversationRecordInspectorController.shared.open(record)
            }
            // The verified bytes wait in a process-owned inbox while cold-launch session restore
            // finishes. Providers then consumes them into the same review sheet as its file picker.
            if let profileURL = partition.enterpriseProfiles.first {
                EnterpriseProfileImportCoordinator.shared.stage(profileURL)
                WorkspaceSessionLaunchGate.shared.whenOpen {
                    // Providers needs a live bridge for account operations. A user can leave only a
                    // utility window open after closing every workspace, so restore that owner
                    // before asking the scene to consume the queued profile.
                    if ActiveWorkspace.shared.bridge == nil {
                        focusOrOpenWorkspaceAfterSessionRestore()
                    }
                    UtilityWindowVisibility.shared.show(.accounts) {
                        openAppWindowWhenReady(id: "accounts")
                    }
                }
            }
            if !partition.attachmentFiles.isEmpty {
                ActiveWorkspace.shared.open(.files(partition.attachmentFiles))
            }
            for url in partition.links { openLink(url) }
        }
    }

    /// A `mechanician://` link: from Copy Link, a Shortcut, a terminal `open`, or a web page the
    /// user is merely visiting. See `MechanicianURL` for the grammar and why it has no send verb.
    @MainActor private func openLink(_ url: URL) {
        // The background notification relay is a second process of the same bundle, with no windows
        // and no restored state. It exists to deliver one notification and terminate; it must never
        // become the target of a link.
        guard !notificationRelayLaunch else { return }
        guard let route = MechanicianURL.route(for: url, scheme: MechanicianEnvironment.currentURLScheme),
              linkRateLimiter.allows(at: Date()) else { return }
        if let ready = launchLinkQueue.accept(route) { ActiveWorkspace.shared.open(ready) }
    }

    /// Tapping a Mechanician result in Spotlight. Workspace windows are hand-built NSWindows,
    /// not SwiftUI scenes, so this AppKit delegate route is the one that reliably fires —
    /// the previous SwiftUI `.onContinueUserActivity` inside those windows misfired and
    /// logged a repeating "Cannot use Scene methods … without SwiftUI Lifecycle" fault.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard MainActor.assumeIsolated({
            StorageAuthorityLaunchState.shared.decision == .product
        }) else {
            MainActor.assumeIsolated { focusStorageRecoveryWindow() }
            return false
        }
        guard userActivity.activityType == CSSearchableItemActionType,
              let uid = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else {
            return false
        }
        return MainActor.assumeIsolated {
            guard let route = SpotlightIndex.route(for: uid) else { return false }
            ActiveWorkspace.shared.open(route)
            return true
        }
    }

    /// Guard quit: if any window has an in-flight turn, background delegate, or queued prompt,
    /// confirm first so provider work is not silently abandoned. (Queues persist across restart,
    /// but they will not run once the owning daemon is killed.) This delegate method is always
    /// called on the main thread, so it is safe to touch the @MainActor bridge state.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard MainActor.assumeIsolated({
            StorageAuthorityLaunchState.shared.decision == .product
        }) else {
            return .terminateNow
        }
        return MainActor.assumeIsolated {
            guard AgentBridge.live.allObjects.contains(where: { $0.hasPendingWork }) else {
                return .terminateNow
            }
            let alert = NSAlert()
            alert.messageText = "Quit Mechanician?"
            alert.informativeText = "Conversation work is still active, or you have queued prompts. "
                + "It won't finish running if you quit now."
            alert.addButton(withTitle: "Quit")     // .alertFirstButtonReturn
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                return .terminateNow
            }
            MechanicianRelaunch.cancelRequestedRelaunch()
            return .terminateCancel
        }
    }

    /// Called by non-lifecycle product ingress (App Intents, Services, notifications) after the
    /// process-wide store gate refuses access. It focuses the correct blocker without locating a
    /// window by its presentation title.
    @MainActor
    func focusStorageBlocker() {
        if StorageAuthorityLaunchState.shared.decision == .recovery {
            focusStorageRecoveryWindow()
        }
    }

    private func focusStorageRecoveryWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: {
            $0.title == StorageAuthorityScenePresentation.windowTitle(.recovery)
        })?
            .makeKeyAndOrderFront(nil)
    }
}

/// Shared tabbing eligibility identifier for every workspace window/tab. It lets
/// `addTabbedWindow` join two windows (AppKit throws when their identifiers differ); actual native
/// groups remain separate, one per canonical Workspace.
let kWorkspaceTabbingID = "MechanicianWorkspace"

/// An existing workspace window (visible OR minimized), for "focus the existing window instead of
/// opening a duplicate" — used by the menu-bar "open" and dock reopen. Deminiaturizes + fronts it.
/// Returns whether one was focused.
@MainActor @discardableResult func focusExistingWorkspaceWindow() -> Bool {
    guard let win = NSApp.windows.first(where: {
        $0.tabbingIdentifier == kWorkspaceTabbingID && ($0.isVisible || $0.isMiniaturized)
    }) else { return false }
    if win.isMiniaturized { win.deminiaturize(nil) }
    win.makeKeyAndOrderFront(nil)
    return true
}

/// Dock/menu-bar reopen may arrive while the authoritative inventory is still loading. Defer the
/// create half until saved-session replay has run; otherwise the eager Home window and replay can
/// produce two top-level groups for the same Workspace.
@MainActor func focusOrOpenWorkspaceAfterSessionRestore() {
    if focusExistingWorkspaceWindow() { return }
    WorkspaceSessionLaunchGate.shared.whenOpen {
        if !focusExistingWorkspaceWindow() {
            makeWorkspaceWindow().makeKeyAndOrderFront(nil)
        }
    }
}

/// Hand-built workspace windows have no other owner once we hand them to AppKit, so retain them here
/// until they close.
@MainActor private var liveWorkspaceWindows: Set<NSWindow> = []

/// Temporary workspace pickers created by File ▸ Open Workspace in New Window. They are
/// intentionally separate from the single reusable All Workspaces window: every command creates
/// its own chooser, then hands the chosen (or newly created) workspace to its one real workspace
/// window.
@MainActor private var liveNewWindowPickers: Set<NSWindow> = []

/// Open the chooser from File ▸ Open Workspace in New Window. Home and every workspace remain
/// selectable: choosing one that already has its one window focuses it; choosing an unopened
/// workspace creates its window. The toolbar switcher is the in-place navigation control; this is
/// the window-level chooser.
@MainActor func openWorkspaceInNewWindowPicker() {
    guard WorkspaceSessionLaunchGate.shared.isOpen else {
        WorkspaceSessionLaunchGate.shared.whenOpen { openWorkspaceInNewWindowPicker() }
        return
    }
    let picker = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    picker.title = "Choose a Workspace"
    picker.isReleasedWhenClosed = false
    picker.contentViewController = NSHostingController(
        rootView: ProjectsLauncherView(purpose: .newWindow) { [weak picker] in picker?.close() }
            .appChrome())
    liveNewWindowPickers.insert(picker)
    // One-shot: remove the observer inside its own handler, or each ⌘⇧N leaks a dead block
    // registration that NotificationCenter still evaluates on every window close app-wide.
    let pickerCloseToken = MainActorBox<NSObjectProtocol?>(nil)
    pickerCloseToken.value = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: picker, queue: .main) { [weak picker] _ in
        MainActor.assumeIsolated {
            if let picker { liveNewWindowPickers.remove(picker) }
            if let token = pickerCloseToken.value { NotificationCenter.default.removeObserver(token) }
        }
    }
    NSApp.activate(ignoringOtherApps: true)
    picker.makeKeyAndOrderFront(nil)
}

/// The AppKit appearance represented by Settings ▸ Appearance. `nil` means inherit the Mac's
/// current appearance. Keeping this policy separate from the mutation makes it directly testable.
func appAppearance(
    for storedValue: String? = UserDefaults.standard.string(forKey: "colorSchemeOverride")
) -> NSAppearance? {
    let preference = MechanicianAppearancePreference(storedValue: storedValue)
    return preference.appKitAppearanceName.flatMap(NSAppearance.init(named:))
}

/// Re-apply the Appearance setting to the application and clear historical per-window overrides.
/// `NSApp.appearance = nil` is the important System transition: every current and future window then
/// follows the Mac, including SwiftUI Settings/utility scenes and hand-built workspace windows.
@MainActor func applyAppAppearance(_ storedValue: String? = nil) {
    let value = storedValue
        ?? UserDefaults.standard.string(forKey: "colorSchemeOverride")
    for window in NSApp.windows {
        window.appearance = nil
    }
    NSApp.appearance = appAppearance(for: value)
}

/// Build a workspace window BY HAND (NSWindow + NSHostingController) so WE control when it is ordered
/// front. `RootView` is self-contained — it creates and owns its own `AgentBridge` (@StateObject) and
/// injects it via `.environmentObject` internally, and reaches everything else through singletons
/// (`ActiveWorkspace.shared`) — so nothing needs to be plumbed in from the scene here.
/// Retain the per-window toolbar controllers (NSToolbar.delegate is weak) until the window closes.
@MainActor private var workspaceCoordinators: [ObjectIdentifier: WorkspaceToolbarController] = [:]

/// Workspace windows have explicit AppKit sizing rules; their hosted SwiftUI content must not
/// publish changing composer measurements back into the window's constraints.
@MainActor
func makeWorkspaceHostingController<Content: View>(
    rootView: Content
) -> NSHostingController<Content> {
    let controller = NSHostingController(rootView: rootView)
    controller.sizingOptions = []
    return controller
}

@MainActor func makeWorkspaceWindow(initialFolder: String? = nil, initialProjectID: UUID? = nil,
                                    initialConversationID: UUID? = nil,
                                    startsFreshConversation: Bool = false,
                                    initialTabModelSelection: ModelSelection? = nil,
                                    initialWindowLayout: WorkspaceWindowLayout? = nil) -> NSWindow {
    // AppKit window shell (NSWindow + NSToolbar + NSSplitViewController) hosting SwiftUI content — the
    // native-Mac chrome the SwiftUI-bridged toolbar couldn't express. Each window owns its bridge,
    // created here and injected into the two hosted SwiftUI views so the AppKit toolbar reaches its
    // state. The tracking separator (in the toolbar controller) tracks THIS split view — public API,
    // no private-view coupling — giving the Mail-style sidebar-anchored toolbar on every window.
    let bridge = AgentBridge(
        initialFolder: initialFolder,
        initialProjectID: initialProjectID,
        initialConversationID: initialConversationID,
        startsFreshConversation: startsFreshConversation,
        initialTabModelSelection: initialTabModelSelection,
        initialWindowLayout: initialWindowLayout)

    let sidebarHC = makeWorkspaceHostingController(
        rootView: SidebarView().environmentObject(bridge))
    let detailHC = makeWorkspaceHostingController(rootView: DetailView(bridge: bridge))
    // The split view and NSWindow own workspace sizing. NSHostingController's default
    // `.standardBounds` exports SwiftUI's changing min/ideal/max measurements into AppKit
    // constraints; on Tahoe, adding composer lines can then enlarge the entire window. Suppress
    // that content-driven feedback loop and retain the explicit window/split minimums below.
    // We own the whole toolbar, including the conversation title (a toolbar item over the content, so
    // the sidebar toggle can stay leading over the sidebar). Hide the titlebar's own title — the
    // coordinator keeps win.title set for the Window menu / Mission Control.

    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHC)
    sidebarItem.minimumThickness = 220
    sidebarItem.maximumThickness = 420
    sidebarItem.canCollapse = true
    let contentItem = NSSplitViewItem(viewController: detailHC)

    let splitVC = NSSplitViewController()
    splitVC.addSplitViewItem(sidebarItem)
    splitVC.addSplitViewItem(contentItem)

    let win = WorkspaceWindow(contentViewController: splitVC)
    // Let the split content's app background continue under the unified toolbar/titlebar. The native
    // opaque material is markedly darker in dark mode and made the chrome read as a separate strip.
    win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    win.toolbarStyle = .unified
    win.titlebarAppearsTransparent = true
    win.backgroundColor = .nBg
    win.tabbingIdentifier = kWorkspaceTabbingID
    win.collectionBehavior.insert(.fullScreenPrimary)   // green-button full screen + tabbable in FS
    win.contentMinSize = NSSize(width: 900, height: 560)
    win.isReleasedWhenClosed = false
    win.titleVisibility = .hidden   // the conversation title is a toolbar item; keep win.title for menus
    // Inherit NSApp.appearance. Appearance is application-wide so this hand-built window changes in
    // lockstep with Settings and every utility scene.
    win.appearance = nil

    let coordinator = WorkspaceToolbarController(bridge: bridge, splitVC: splitVC, window: win)
    win.delegate = coordinator
    // FR-96: restore this workspace's saved frame + sidebar width (or the defaults) before observing,
    // so the first workspace-switch notification during observe() is a no-op rather than a reset.
    coordinator.applyInitialLayout(restoring: initialWindowLayout)
    win.toolbar = coordinator.makeToolbar()

    bridge.window = win
    bridge.start()                          // was RootView.onAppear
    ActiveWorkspace.shared.bridge = bridge

    liveWorkspaceWindows.insert(win)
    workspaceCoordinators[ObjectIdentifier(win)] = coordinator
    // Block observers are retained by NotificationCenter until their token is removed, and both
    // blocks strongly capture `win`, `bridge`, and `coordinator`. Capture both tokens and remove
    // them when the window closes — otherwise every closed window leaks its whole object graph
    // (bridge + transcript + NSWindow + hosted SwiftUI trees + scroll-wheel monitor) for the
    // process lifetime.
    let willCloseToken = MainActorBox<NSObjectProtocol?>(nil)
    let didBecomeKeyToken = MainActorBox<NSObjectProtocol?>(nil)
    didBecomeKeyToken.value = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: win, queue: .main) { _ in
        MainActor.assumeIsolated {
            ActiveWorkspace.shared.bridge = bridge   // was KeyWindowClaim
            // Track the focused PLACE for launch-restore (the window you were last in): a Project sets
            // its id, Home clears it (restore where you were).
            let placeID = bridge.projectID ?? ProjectStore.shared.projectID(forCwd: bridge.cwd, createIfMissing: false)
            if let placeID { UserDefaults.standard.set(placeID.uuidString, forKey: lastLocationKey) }
            else { UserDefaults.standard.removeObject(forKey: lastLocationKey) }
            // A terminal commit / checkout / external edit while we were in the background leaves the
            // Changes badge stale even when its inspector is closed. Focus is a concrete invalidation
            // edge; the bridge coalesces this with edit/turn events without polling.
            bridge.scheduleGitRefresh()
        }
    }
    willCloseToken.value = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: win, queue: .main) { _ in
        MainActor.assumeIsolated {
            coordinator.saveWindowLayout()  // FR-96: final capture while the window is still alive
            bridge.shutdown()               // was RootView.onDisappear
            ActiveWorkspace.shared.workspaceDidClose(bridge)
            coordinator.invalidate()
            liveWorkspaceWindows.remove(win)
            workspaceCoordinators[ObjectIdentifier(win)] = nil
            if let token = didBecomeKeyToken.value { NotificationCenter.default.removeObserver(token) }
            if let token = willCloseToken.value { NotificationCenter.default.removeObserver(token) }
        }
    }
    // Sidebar width (default or per-workspace saved) is applied by coordinator.applyInitialLayout()
    // above, which defers the setPosition until after the split view lays out.
    return win
}

// MARK: - Launch splash

/// The branded launch splash: the Magic & Lasers mark — the mechanician holding magic in one
/// hand and lasers in the other — shown the instant the app launches. It also covers the
/// momentary SwiftUI scene-window flash (see the AppDelegate launch comment) while the first
/// workspace window is being hand-built. Borderless, click-through, floats above the app until
/// it fades out ~2s in. No-ops when the art isn't found (e.g. an un-bundled `swift run` dev
/// build — set `MECHANICIAN_SPLASH` to a PNG path to show it there too).
@MainActor private var splashWindow: NSWindow?

@MainActor
final class SplashStatusModel: ObservableObject {
    static let shared = SplashStatusModel()
    @Published var message: String?

    private init() {}
}

enum MechanicianRelaunch {
    static let waitArgument = "--mechanician-relaunch-after-pid"
    @MainActor private(set) static var isRequested = false

    /// `open -n` starts the replacement before this process relinquishes its writer lease. Wait
    /// before process bootstrap so the replacement can never mistake that expected overlap for a
    /// competing writer or construct stores from the pre-cutover root decision.
    static func waitForPreviousProcessIfRequested(arguments: [String]) {
        guard let index = arguments.firstIndex(of: waitArgument),
              arguments.indices.contains(index + 1),
              let rawPID = Int32(arguments[index + 1]),
              rawPID > 1,
              rawPID != getpid() else { return }
        let deadline = Date().addingTimeInterval(30)
        while kill(rawPID, 0) == 0, Date() < deadline {
            usleep(50_000)
        }
    }

    /// Requests normal app termination. The replacement is not spawned until AppDelegate reaches
    /// `applicationWillTerminate`, so cancelling the active-work quit confirmation cannot leave a
    /// second process waiting on a relaunch that never happened.
    @MainActor @discardableResult
    static func afterCurrentProcessExits() -> Bool {
        isRequested = true
        NSApp.terminate(nil)
        return isRequested
    }

    @MainActor
    static func cancelRequestedRelaunch() {
        isRequested = false
    }

    @MainActor
    static func launchReplacementIfRequested() {
        guard isRequested else { return }
        isRequested = false
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = [
            "-n", Bundle.main.bundleURL.path, "--args", waitArgument, "\(getpid())",
        ]
        do {
            try launcher.run()
        } catch {
            NSLog("Mechanician could not launch its replacement: %@", error.localizedDescription)
        }
    }
}

@MainActor func showSplashScreen() {
    guard splashWindow == nil else { return }
    let path = Bundle.main.path(forResource: "magic-and-lasers", ofType: "png")
        ?? Bundle.main.path(forResource: "figure-source", ofType: "png")
        ?? ProcessInfo.processInfo.environment["MECHANICIAN_SPLASH"]
    guard let path, let image = NSImage(contentsOfFile: path) else { return }

    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 410),
                       styleMask: [.borderless], backing: .buffered, defer: false)
    win.isOpaque = false
    win.backgroundColor = .clear
    win.hasShadow = true
    win.level = .floating
    win.ignoresMouseEvents = true
    win.isReleasedWhenClosed = false
    win.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
    win.contentView = NSHostingView(rootView: SplashView(image: image))
    win.setContentSize(NSSize(width: 560, height: 410))
    win.center()
    win.orderFrontRegardless()
    splashWindow = win
}

@MainActor func dismissSplashScreen() {
    guard let win = splashWindow else { return }
    splashWindow = nil
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.4
        win.animator().alphaValue = 0
    } completionHandler: {
        MainActor.assumeIsolated { win.orderOut(nil) }
    }
}

private struct SplashView: View {
    let image: NSImage
    @ObservedObject private var status = SplashStatusModel.shared

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: image)
                .resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 508, maxHeight: 278)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(TenantProfile.current.displayName)
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .foregroundStyle(.primary)
            Text("MAGIC & LASERS")
                .font(.system(size: 10, weight: .medium))
                .kerning(2.2)
                .foregroundStyle(.secondary)
            if let message = status.message {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .frame(width: 560, height: 410)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// The About box: the Magic & Lasers mark over the required About-panel contents (name, version +
/// build, copyright), in the app's own visual language instead of the stock panel's.
struct AboutView: View {
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(BuildVersionLabel.make(version: v, build: b))"
    }
    private var artwork: NSImage? {
        let path = Bundle.main.path(forResource: "magic-and-lasers", ofType: "png")
            ?? ProcessInfo.processInfo.environment["MECHANICIAN_SPLASH"]
        return path.flatMap { NSImage(contentsOfFile: $0) }
    }

    var body: some View {
        VStack(spacing: 8) {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 470)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.bottom, 6)
            }
            Text(TenantProfile.current.displayName)
                .font(.system(size: 24, weight: .semibold, design: .serif))
            Text(version)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("MAGIC & LASERS")
                .font(.system(size: 10, weight: .medium))
                .kerning(2.2)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Text(TenantProfile.current.branding.copyright ?? "© 2026 Magic & Lasers")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            HStack(spacing: 2) {
                Button(TenantProfile.current.isDefault ? "mechanician.ai" : "Enterprise support") {
                    let target = TenantProfile.current.branding.supportURL ?? "https://mechanician.ai"
                    if let url = URL(string: target) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(PillButtonStyle(kind: .plain))
                Text("·").foregroundStyle(.tertiary)
                Button("magicandlasers.com") {
                    NSWorkspace.shared.open(URL(string: "https://magicandlasers.com")!)
                }
                .buttonStyle(PillButtonStyle(kind: .plain))
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 520)
        .background(Color.nBg)
    }
}

/// Prompt for a folder and open it in a new *standalone* workspace window. Shared by the File menu
/// and the toolbar's folder switcher. (Its own Space in full screen is the expected macOS behavior
/// for a new window, and matches what "Open in New Window" always did.)
@MainActor func promptOpenFolderInNewWindow() {
    guard WorkspaceSessionLaunchGate.shared.isOpen else {
        WorkspaceSessionLaunchGate.shared.whenOpen { promptOpenFolderInNewWindow() }
        return
    }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Open Folder"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    // Focus-or-create the folder's Workspace group — not a forced duplicate top-level group.
    if let pid = ProjectStore.shared.projectID(forCwd: url.path), let p = ProjectStore.shared.project(pid) {
        openProject(p)
    }
}

/// ⌘T / File → New Tab: add a new empty workspace as a REAL native tab of the current window. This
/// is Space-safe in full screen because we build the window ourselves and join it to the tab group
/// BEFORE it is ever ordered front — so it never exists as a standalone window that macOS would give
/// its own (then-orphaned, blank) Space. (The old approach used SwiftUI's `openWindow`, which orders
/// a standalone scene window front first; no post-hoc collectionBehavior/tabbing fix can reclaim the
/// Space it's handed in that instant.)
@MainActor func openWorkspaceTab(initialConversationID: UUID? = nil) {
    guard WorkspaceSessionLaunchGate.shared.isOpen else {
        WorkspaceSessionLaunchGate.shared.whenOpen {
            openWorkspaceTab(initialConversationID: initialConversationID)
        }
        return
    }
    let aw = ActiveWorkspace.shared
    let liveWindows = liveWorkspaceWindowIdentities()
    let keyWindowBridgeID = AgentBridge.live.allObjects.first {
        $0.window === NSApp.keyWindow
    }?.bridgeID
    let sourceBridgeID = WorkspaceTabRouting.sourceBridgeID(
        keyWindowBridgeID: keyWindowBridgeID,
        activeBridgeID: aw.bridge?.bridgeID,
        among: liveWindows)
    // Resolve the host before `makeWorkspaceWindow`: the factory publishes the new bridge as the
    // active one immediately, which would otherwise erase the source when a utility window is key.
    let sourceBridge = liveWorkspaceBridge(sourceBridgeID)
    let hostWindow = sourceBridge?.window
    let sourceIdentity = liveWindows.first { $0.bridgeID == sourceBridgeID }
    let sourceModelSelection = WorkspaceTabRouting.freshConversationModelSelection(
        source: sourceIdentity,
        sourceConversation: sourceBridge?.currentConversation,
        sourceProjectedSelection: sourceBridge?.selectedModelSelection,
        projects: ProjectStore.shared.projects)
    let intent = WorkspaceTabRouting.intent(
        source: sourceIdentity,
        initialConversationID: initialConversationID,
        sourceModelSelection: sourceModelSelection)
    // Scope, named destination, fresh/default choice, and an eligible source model all belong to
    // this exact bridge. The old process-global payload could be overwritten by a second rapid ⌘T
    // before the first tab readied.
    let newWin = makeWorkspaceWindow(
        initialFolder: intent.initialFolder,
        initialProjectID: intent.initialProjectID,
        initialConversationID: intent.initialConversationID,
        startsFreshConversation: intent.startsFreshConversation,
        initialTabModelSelection: intent.initialFreshModelSelection)
    // The command can be invoked while Settings / Artifacts / another utility is key. Route back to
    // the selected window in the source Workspace's group; both windows carry the workspace-only
    // tabbing identifier, so AppKit can join them safely in the same Space.
    if let host = hostWindow?.tabGroup?.selectedWindow ?? hostWindow {
        host.addTabbedWindow(newWin, ordered: .above)  // join the group IN PLACE (same Space)
    }
    newWin.makeKeyAndOrderFront(nil)                    // now this only SELECTS the tab — no Space alloc
}

/// The bridge menu commands should act on. `@FocusedObject` is fed by SwiftUI's *scene* focus
/// (`.focusedSceneObject`), so a hand-built (non-scene) workspace tab window can leave it nil even
/// while it's key. When that happens, fall back to the last active workspace's bridge.
///
/// That fallback applies whichever window is key, including Settings and the artifact/ambient
/// browsers, so a command like ⌘N stays enabled there and acts on the last workspace. An earlier
/// version of this comment claimed the fallback was gated on a workspace window actually being key.
/// It never was, and it deliberately should not be: the only way to know which window is key is to
/// read `NSApp.keyWindow`, and doing that here — during command-body evaluation — is exactly what
/// left ⌘N permanently disabled on macOS 26.
///
/// A command that genuinely must act on the key window (undo, print) needs the key-window bridge
/// resolved **inside its action closure**, where reading `NSApp.keyWindow` is safe. `AgentBridge.live`
/// plus each bridge's `weak var window` is the seam for that; it is how `RootView` and `openProject`
/// already resolve cross-window bridges.
@MainActor func activeMenuBridge(_ focused: AgentBridge?) -> AgentBridge? {
    // The focused workspace when SwiftUI provides it; otherwise the active workspace's bridge.
    // This is driven by OBSERVED state — ActiveWorkspace.shared publishes `bridge` and the command
    // structs observe it — NOT by reading NSApp.keyWindow at command-eval time. That read happened
    // at the wrong moment and (on macOS 26) left ⌘N / New Conversation permanently disabled.
    focused ?? ActiveWorkspace.shared.bridge
}

// MARK: - Menu bar

/// File menu — conversation + workspace commands. Replaces the default New/Open group so
/// ⌘N creates a new conversation (the common action in a chat app) rather than a window.
struct FileCommands: Commands {
    @FocusedObject private var bridge: AgentBridge?
    @ObservedObject private var workspace = ActiveWorkspace.shared   // re-evaluate enablement when the active bridge appears/changes
    @Environment(\.openWindow) private var openWindow
    private var activeBridge: AgentBridge? { activeMenuBridge(bridge) }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Conversation") { activeBridge?.newConversation() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(activeBridge == nil)
            // ⌘T makes a workspace tab — unless the terminal is focused, in which case the
            // terminal view intercepts the key (performKeyEquivalent) and makes a terminal tab.
            Button("New Tab") { openWorkspaceTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(activeBridge == nil)
            // This explicit name matters: the command opens a workspace chooser rather than a
            // blank generic window. Home and every workspace are selectable; an existing window
            // is focused and an unopened workspace gets one.
            Button("Open Workspace in New Window…") {
                openWorkspaceInNewWindowPicker()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(activeBridge == nil)
            Button("New Workspace…") {
                performWorkspaceCreatingIngress {
                    NSApp.activate(ignoringOtherApps: true)
                    ProjectStore.shared.pendingNewProjectRequest = true
                    openWindow(id: "projects")
                }
            }
            .disabled(activeBridge == nil)
            Divider()
            Button("Open Folder…") { activeBridge?.chooseFolder() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(activeBridge == nil)
            Menu("Open Recent") {
                let recents = activeBridge?.recentFolders ?? []
                if recents.isEmpty {
                    Button("No Recent Folders") {}.disabled(true)
                } else {
                    ForEach(recents.prefix(10), id: \.self) { path in
                        Button((path as NSString).lastPathComponent) { activeBridge?.openFolder(path) }
                    }
                }
            }
            .disabled(activeBridge == nil)
            Button("Open Folder in New Window…") { promptOpenFolderInNewWindow() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(activeBridge == nil)
            // `.convrec` is a deferred interchange format with no import and no compatibility
            // promise — one of these items says "Experimental v0" in the File menu of a shipped
            // app. It stays available where it is used, on dogfood builds, and out of the way for
            // everyone else. The same `#if DEBUG` convention gates every other internal surface.
            if BuildProvenance.current?.dogfood == true {
                Divider()
                Button("Open Conversation Record Read-Only…") {
                    ExperimentalConversationRecordActions.openInspector()
                }
                Button("Export Conversation Record Snapshot (Experimental v0)…") {
                    guard let bridge = activeBridge else { return }
                    ExperimentalConversationRecordActions.export(from: bridge)
                }
                .disabled(activeBridge?.currentID == nil)
                Button("Validate Conversation Record…") {
                    ExperimentalConversationRecordActions.validate(from: activeBridge)
                }
            }
            Divider()
            // In the `.newItem` group rather than `.printItem`. `.printItem` lands after a Save
            // group, and this app has no document scene to put one there — every placement it ships
            // is non-document. Bottom of File, after a divider, is where Print sits in a Mac app
            // that has no Save.
            //
            // Always enabled, never gated on whether the conversation has content: a disabled menu
            // item does not perform its key equivalent, which is the trap that has already killed
            // ⌘Z, ⌘E, and ⌘G once each in this codebase. `TranscriptPrinting.print` no-ops when
            // there is nothing printable.
            Button("Print…") {
                guard let bridge = activeBridge else { return }
                TranscriptPrinting.print(
                    title: bridge.currentConversation?.displayTitle ?? "Conversation",
                    entries: bridge.entries,
                    in: bridge.window)
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(activeBridge == nil)
        }
    }
}

/// Use the command environment's live scene action for cold Settings creation. Once created,
/// `showSettings` also reuses and foregrounds the retained native window by identifier.
struct SettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                showSettings(using: openWindow)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

/// Commands are scene-owned and may be evaluated even when their window is launch-suppressed.
/// Keep every command that observes a scoped store behind the same bootstrap result as scene
/// content. Recovery mode retains the system Quit command but exposes no product mutation command.
struct StorageAuthorityCommandSet: Commands {
    let recognition: StorageAuthorityRecognition
    let updater: UpdaterManager

    @CommandsBuilder var body: some Commands {
        // Updating is not a product mutation: it is how a build that cannot open gets replaced by
        // one that can. Recovery mode used to omit this command, so an installation blocked by a bad
        // release had no in-app way to take the fix — someone hit exactly that and had to download
        // the app again. It stays available in every mode, and the About window with it, so the
        // version can be read while reporting the problem.
        CommandGroup(replacing: .appInfo) {
            Button("About \(TenantProfile.current.displayName)") {
                NSApp.activate(ignoringOtherApps: true)
                appOpenWindow?(id: "about")
            }
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
        }
        // The signed Help corpus is independent of library.db and is most valuable when launch is
        // blocked: it can explain recovery without asking the uncertain product authority to open.
        HelpCommands()
        if recognition.disposition.allowsNormalProduct {
            FileCommands()
            EditCommands()
            WorkspaceCommands()
            ConversationCommands()
            ViewCommands()
            WindowMenuCommands()
            SettingsCommands()
        } else {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {}
        }
    }
}

/// Edit menu additions — Find focuses the sidebar's conversation search.
struct EditCommands: Commands {
    @FocusedObject private var bridge: AgentBridge?
    @ObservedObject private var workspace = ActiveWorkspace.shared   // re-evaluate enablement when the active bridge appears/changes
    private var activeBridge: AgentBridge? { activeMenuBridge(bridge) }

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            // The standard Mac split, and decision 5 (David, 2026-08-01): ⌘F searches what you are
            // reading, the list filter takes the modifier. It is why a Mac user's ⌘F reflex works in
            // an app they have never opened, and it is the reflex this app was answering oddly.
            Button("Find…") { activeBridge?.openFind() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(activeBridge == nil)
            // Never gated on the match count, and this is not an oversight. A disabled menu item
            // does not perform its key equivalent, and SwiftUI evaluates these bodies on its own
            // schedule — so gating on `find.matches` produced a ⌘G that silently did nothing while
            // the bar plainly read "1 of 9". Verified live. Same rule as Undo/Redo above and ⌘E
            // below: always enabled, no-op when there is nothing to do. `step` already guards.
            Button("Find Next") { activeBridge?.findNext() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(activeBridge == nil)
            Button("Find Previous") { activeBridge?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(activeBridge == nil)
            // Always enabled, deliberately. Reading the first responder during command-body
            // evaluation to find out whether there is a selection is precisely what left ⌘N
            // permanently disabled on macOS 26 (see `activeMenuBridge`), so this is a no-op with no
            // selection instead of a disabled item.
            Button("Use Selection for Find") { activeBridge?.useSelectionForFind() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(activeBridge == nil)
            Divider()
            Button("Find Conversations…") { activeBridge?.focusSearch() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(activeBridge == nil)
        }
        // SwiftUI's stock Undo/Redo are removed here and rebuilt in AppKit by
        // `installResponderChainUndoItems()`. SwiftUI binds them to `@Environment(\.undoManager)`,
        // which is nil in this app because workspace windows are hand-built NSWindows rather than
        // scenes — yet the items still claim ⌘Z, so nothing else could ever receive it. Verified
        // live: a workspace move registered correctly and ⌘Z did not reverse it.
        //
        // The replacement is empty rather than a pair of SwiftUI Buttons on purpose. Buttons would
        // put enablement on published state, and a disabled menu item does not perform its key
        // equivalent — that is what breaks ⌘Z for every text field in the app.
        // Undo/Redo, owned here rather than inserted into the menu from AppKit.
        //
        // An earlier attempt built real `NSMenuItem`s at launch and inserted them. Measured: they
        // survive a few seconds and are then gone — SwiftUI rebuilds the Edit menu and discards
        // anything it did not put there. At the moment ⌘Z was pressed the menu held 17 items
        // starting at a separator, with no Undo at all, so the keystroke matched nothing.
        //
        // These are deliberately never disabled. SwiftUI enablement would have to come from
        // published state, and a disabled menu item does not perform its key equivalent — which is
        // exactly how ⌘Z would break for every text field in the app. Always-enabled keeps the
        // keystroke flowing; `WorkspaceWindow` decides what it does, including doing nothing.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { performWorkspaceUndo() }
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { performWorkspaceRedo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }
}


/// ⌘Z, resolved against whichever window is key.
///
/// A workspace window routes it itself, weighing the composer against the library stack. A utility
/// window — Artifacts, Ambient, Settings — has no routing of its own, and sending `undo:` into its
/// responder chain reaches `NSWindow`, which quietly acts on an undo manager nothing registers on.
/// Since moving an artifact is a thing you do *from* the Artifacts window, that would have left the
/// action visible and its undo unreachable. Utility windows therefore fall back to the active
/// workspace's stack, which is exactly where the move registered.
@MainActor func performWorkspaceUndo() {
    performWorkspaceUndo(keyWindow: NSApp.keyWindow, activeBridge: ActiveWorkspace.shared.bridge)
}

@MainActor func performWorkspaceRedo() {
    performWorkspaceRedo(keyWindow: NSApp.keyWindow, activeBridge: ActiveWorkspace.shared.bridge)
}

/// The explicit form. Separate from the wrapper above because a default argument is evaluated
/// outside the main actor, and because the rule is worth testing without a key window or the
/// process-global active workspace.
@MainActor func performWorkspaceUndo(keyWindow: NSWindow?, activeBridge: AgentBridge?) {
    if let workspace = keyWindow as? WorkspaceWindow { workspace.undo(nil) }
    else if !WorkspaceAdoption.isPlacementOperationInProgress {
        workspaceUndoManager(for: activeBridge)?.undo()
    }
}

@MainActor func performWorkspaceRedo(keyWindow: NSWindow?, activeBridge: AgentBridge?) {
    if let workspace = keyWindow as? WorkspaceWindow { workspace.redo(nil) }
    else if !WorkspaceAdoption.isPlacementOperationInProgress {
        workspaceUndoManager(for: activeBridge)?.redo()
    }
}

/// What Edit ▸ Undo should read, resolved exactly the way `performWorkspaceUndo` resolves what it
/// will act on. Kept beside it so the name and the action cannot drift apart.
///
/// The bare fallbacks go through the catalogue. These titles are written over the ones SwiftUI
/// already localized for `Button("Undo")`, so a plain literal here silently un-localizes the menu
/// the moment anything registers an undo. `undoMenuItemTitle` composes AppKit's own localized
/// "Undo %@" around the action name, which the registering sites localize.
@MainActor func workspaceUndoMenuTitle(keyWindow: NSWindow?, activeBridge: AgentBridge?) -> String {
    if let workspace = keyWindow as? WorkspaceWindow { return workspace.undoMenuTitle }
    guard !WorkspaceAdoption.isPlacementOperationInProgress,
          let manager = workspaceUndoManager(for: activeBridge), manager.canUndo
    else { return String(localized: "Undo") }
    return manager.undoMenuItemTitle
}

@MainActor func workspaceRedoMenuTitle(keyWindow: NSWindow?, activeBridge: AgentBridge?) -> String {
    if let workspace = keyWindow as? WorkspaceWindow { return workspace.redoMenuTitle }
    guard !WorkspaceAdoption.isPlacementOperationInProgress,
          let manager = workspaceUndoManager(for: activeBridge), manager.canRedo
    else { return String(localized: "Redo") }
    return manager.redoMenuItemTitle
}

/// Names Edit ▸ Undo/Redo after the work they will actually undo.
///
/// AppKit normally does this itself, but only for items whose action is `undo:`/`redo:`. Ours are
/// SwiftUI buttons, deliberately — a disabled menu item does not fire its key equivalent, which
/// would break ⌘Z for every text field in the app — so AppKit's title vending never runs and every
/// `setActionName` in the codebase was invisible to the user.
///
/// Titles are pushed just before the menu bar is read, rather than through a menu delegate: SwiftUI
/// owns these menus, and taking their delegate would be a fight over ownership for no gain.
@MainActor
final class EditMenuActionNames {
    static let shared = EditMenuActionNames()
    private var observer: NSObjectProtocol?

    func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                EditMenuActionNames.shared.refresh(
                    mainMenu: NSApp.mainMenu,
                    keyWindow: NSApp.keyWindow,
                    activeBridge: ActiveWorkspace.shared.bridge)
            }
        }
    }

    /// Located by key equivalent rather than by title — both the menu and the items — because the
    /// title is the thing being changed, and because a title is not a stable identifier.
    ///
    /// This used to find the Edit menu with `submenu?.title == "Edit"`. That works in English and
    /// stops working the moment the app is translated, at which point Undo/Redo silently keep the
    /// generic titles: a defect that would have shipped looking like the feature simply regressed.
    /// ⌘Z and ⇧⌘Z identify these two items in any language, so nothing here reads a title.
    ///
    /// Every input is an explicit parameter. A default argument would be evaluated outside the main
    /// actor — the trap `performWorkspaceUndo` documents — and `NSApp` is nil under `xctest`, so
    /// reaching for it here would make this untestable as well as unsafe.
    func refresh(mainMenu: NSMenu?, keyWindow: NSWindow?, activeBridge: AgentBridge?) {
        guard let mainMenu else { return }
        for submenu in mainMenu.items.compactMap(\.submenu) {
            for item in submenu.items where item.keyEquivalent == "z" {
                if item.keyEquivalentModifierMask == [.command] {
                    item.title = workspaceUndoMenuTitle(
                        keyWindow: keyWindow, activeBridge: activeBridge)
                } else if item.keyEquivalentModifierMask == [.command, .shift] {
                    item.title = workspaceRedoMenuTitle(
                        keyWindow: keyWindow, activeBridge: activeBridge)
                }
            }
        }
    }
}

/// Current-workspace management belongs in the main menu bar as well as the toolbar. Besides being
/// visible beside File/Edit/View, these commands become searchable through macOS menu search.
struct WorkspaceCommands: Commands {
    @FocusedObject private var bridge: AgentBridge?
    @ObservedObject private var workspace = ActiveWorkspace.shared
    @ObservedObject private var projects = ProjectStore.shared
    @Environment(\.openWindow) private var openWindow
    private var activeBridge: AgentBridge? { activeMenuBridge(bridge) }

    private var currentProject: Project? {
        guard let activeBridge else { return nil }
        return WorkspaceManagementPresentation.project(
            projectID: activeBridge.projectID,
            cwd: activeBridge.cwd,
            projects: projects.projects)
    }

    private var instructionTarget: WorkspaceInstructionsTarget? {
        guard let activeBridge else { return nil }
        return WorkspaceInstructionsPresentation.target(
            projectID: activeBridge.projectID,
            cwd: activeBridge.cwd,
            projects: projects.projects)
    }

    private var folderActionTitle: String? {
        guard let activeBridge else { return nil }
        return WorkspaceManagementPresentation.folderActionTitle(
            projectID: activeBridge.projectID,
            cwd: activeBridge.cwd,
            projects: projects.projects)
    }

    private var folderPath: String? {
        guard let activeBridge else { return nil }
        return WorkspaceManagementPresentation.folderPath(
            projectID: activeBridge.projectID,
            cwd: activeBridge.cwd,
            projects: projects.projects)
    }

    var body: some Commands {
        CommandMenu("Workspace") {
            Button("Home") {
                let origin = activeBridge
                performWorkspaceCreatingIngress {
                    goHome(from: origin)
                }
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Divider()
            Button(WorkspaceInstructionsPresentation.actionTitle) {
                activeBridge?.presentWorkspaceInstructions()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(instructionTarget == nil)

            Divider()
            Button(folderActionTitle ?? WorkspaceManagementPresentation.homeFolderActionTitle) {
                chooseOrOpenFolder()
            }
            .disabled(folderActionTitle == nil)
            Button(WorkspaceManagementPresentation.revealFolderActionTitle) {
                revealFolder()
            }
            .disabled(folderPath == nil)
            Button(WorkspaceManagementPresentation.editWorkspaceActionTitle) {
                editWorkspace()
            }
            .disabled(!canEditCurrentWorkspace)

            Divider()
            Button("New Workspace…") {
                performWorkspaceCreatingIngress {
                    NSApp.activate(ignoringOtherApps: true)
                    projects.pendingNewProjectRequest = true
                    openWindow(id: "projects")
                }
            }
            Button(WorkspaceManagementPresentation.allWorkspacesActionTitle) {
                performWorkspaceCreatingIngress {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "projects")
                }
            }
        }
    }

    private func chooseOrOpenFolder() {
        guard let activeBridge else { return }
        if let currentProject {
            _ = WorkspaceFolderAssignment.chooseFolder(for: currentProject)
        } else if activeBridge.projectID == nil && activeBridge.cwd.isEmpty {
            activeBridge.chooseFolder()
        }
    }

    private func revealFolder() {
        guard let folderPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: folderPath, isDirectory: true),
        ])
    }

    private func editWorkspace() {
        guard canEditCurrentWorkspace, let currentProject else { return }
        performWorkspaceCreatingIngress {
            projects.pendingEditProjectRequest = currentProject.id
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "projects")
        }
    }

    private var canEditCurrentWorkspace: Bool {
        guard let activeBridge else { return false }
        return WorkspaceManagementPresentation.canEditWorkspace(
            projectID: activeBridge.projectID,
            cwd: activeBridge.cwd,
            projects: projects.projects)
    }
}

/// Conversation menu — app-specific commands for the active conversation.
struct ConversationCommands: Commands {
    @FocusedObject private var bridge: AgentBridge?
    @ObservedObject private var workspace = ActiveWorkspace.shared   // re-evaluate enablement when the active bridge appears/changes
    private var activeBridge: AgentBridge? { activeMenuBridge(bridge) }

    var body: some Commands {
        CommandMenu("Conversation") {
            Button(activeBridge?.currentConversationHasReservedTurn == true
                   ? "Stop Generating" : "Stop Active Work") {
                activeBridge?.stopConversationWork()
            }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(activeBridge?.hasStoppableConversationWork != true)
            Divider()
            Button("Copy Transcript") {
                guard let c = activeBridge?.currentConversation else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    AgentBridge.transcriptMarkdown(c.messages), forType: .string)
            }
            .disabled(activeBridge?.currentConversation == nil)
            Button("Copy Link") {
                if let id = activeBridge?.currentID { MechanicianURL.copyLink(to: .conversation(id)) }
            }
            .disabled(activeBridge?.currentID == nil)
            Button("Summarize (on-device)") { activeBridge?.summarizeConversation() }
                .disabled(activeBridge?.currentConversation == nil)
            Divider()
            Button("Delete Conversation") {
                if let id = activeBridge?.currentID { activeBridge?.deleteConversation(id) }
            }
            .disabled(activeBridge?.currentID == nil)
        }
    }
}

/// View menu — panel toggles (state-reflecting labels) and the ⌘+/- chat-font zoom.
struct ViewCommands: Commands {
    @FocusedObject private var bridge: AgentBridge?
    @ObservedObject private var workspace = ActiveWorkspace.shared   // re-evaluate enablement when the active bridge appears/changes
    private var activeBridge: AgentBridge? { activeMenuBridge(bridge) }
    @AppStorage("uiTypeStep") private var typeStep = 0

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button((activeBridge?.showSidebar ?? true) ? "Hide Sidebar" : "Show Sidebar") {
                activeBridge?.showSidebar.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(activeBridge == nil)
            Button((activeBridge?.showInspector ?? false) ? "Hide Inspector" : "Show Inspector") {
                activeBridge?.userToggledInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(activeBridge == nil)
            Button((activeBridge?.showTerminal ?? false) ? "Hide Terminal" : "Show Terminal") {
                activeBridge?.showTerminal.toggle()
            }
            // The one panel with no shortcut. ⌃⌘T pairs with the sidebar's ⌃⌘S and stays clear of
            // ⌥⌘T (Scheduled & Ambient Tasks).
            .keyboardShortcut("t", modifiers: [.command, .control])
            .disabled(activeBridge == nil)
            Divider()
            // Bind zoom-in to "=" (the unshifted +/= key) so ⌘= fires reliably;
            // "+" would require ⌘⇧ and often never matches.
            Button("Zoom In") { typeStep = min(typeStep + 1, 6) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { typeStep = max(typeStep - 1, -3) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { typeStep = 0 }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }
    }
}

/// Window-menu entries for the global browsers (also reachable from the toolbar).
struct WindowMenuCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        // `replacing: .singleWindowList`, not `after: .windowList`. SwiftUI auto-generates a Window
        // menu entry for every `Window` scene — nine are declared below — so appending ours listed
        // Workspaces, Artifacts, Scheduled & Ambient Tasks, Skills, Extensions and Providers TWICE.
        // Replacing that auto-generated list keeps exactly one entry each, and keeps the keyboard
        // shortcuts, which the generated copies never had.
        CommandGroup(replacing: .singleWindowList) {
            Button("Providers") { showProviders(using: openWindow) }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button("Workspaces") {
                performWorkspaceCreatingIngress {
                    openWindow(id: "projects")
                }
            }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Artifacts") { openWindow(id: "artifacts") }
                .keyboardShortcut("y", modifiers: [.command, .option])
            Button("Scheduled & Ambient Tasks") { openWindow(id: "ambient") }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Extensions") { openWindow(id: "extensions") }
                .keyboardShortcut("e", modifiers: [.command, .option])
        }
    }
}

/// Help menu — documentation and feedback.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            // ⌘? opens the in-app guides, which is where a Mac user expects Help to go. The
            // web page is still one item down for anyone who wants the full documentation.
            Button("\(TenantProfile.current.displayName) Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
            Button("Documentation on the Web…") {
                let target = TenantProfile.current.branding.supportURL
                    ?? "https://mechanician.ai/help"
                if let u = URL(string: target) {
                    NSWorkspace.shared.open(u)
                }
            }
            Button("Send Feedback…") {
                if let u = URL(string: "https://github.com/magicandlasers/mechanician/issues/new") {
                    NSWorkspace.shared.open(u)
                }
            }
        }
    }
}

@main
struct MechanicianApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var updater: UpdaterManager
    @StateObject private var authorityState: StorageAuthorityLaunchState
    @AppStorage("menuBarExtra") private var showMenuBar = true
    private let notificationRelayLaunch: Bool

    init() {
        MainActor.assumeIsolated { LaunchMetrics.shared.markAppStart() }
        MechanicianLocalizationProbe.writeIfRequested()
        // Carry the one shared inspector width over to Home once, before any window reads a
        // per-workspace one. Someone who dragged their inspector to a size they like must not find
        // every workspace back at the default because the key moved underneath them.
        InspectorWidthPreference.migrateLegacyWidthIfNeeded()
        InspectorTabPreference.migrateExistingHelpWorkspaceTabIfNeeded()
        MechanicianRelaunch.waitForPreviousProcessIfRequested(
            arguments: ProcessInfo.processInfo.arguments)
        let notificationRelayLaunch = BackgroundNotificationRelay.isRequested(
            arguments: ProcessInfo.processInfo.arguments)
        self.notificationRelayLaunch = notificationRelayLaunch
        let backgroundVerification = Bundle.main.bundleIdentifier == "ai.mechanician.app.dev"
            && ProcessInfo.processInfo.environment["MECHANICIAN_DEV_BACKGROUND"] == "1"
        // The bundle identity, not a particular launcher script, owns public/dev/tenant isolation. Do
        // this before AppDelegate creates any stores or provider runtimes.
        MechanicianEnvironment.bootstrapProcessIfNeeded(
            acquireStorageLease: !notificationRelayLaunch,
            provisionsPristineLibrary: !backgroundVerification)
        // Recognition proves the marker/database pair read-only. Before any normal scene can
        // construct a scoped store, also prove that the active writable repository opens. The
        // repository opener retains that same singleton for Conversation/Workspace/Artifact use;
        // failure rewrites the process decision to the existing recovery-only path.
        let bootstrap = notificationRelayLaunch
            ? StorageAuthorityBootstrap.current
            : StorageAuthorityBootstrap.preflightSQLiteRepository()
        let decision = StorageAuthorityLaunchDecision.resolve(
            recognition: bootstrap,
            ownsProcessLease: StorageAuthorityBootstrap.ownsProcessLease)
        let launchState = MainActor.assumeIsolated { StorageAuthorityLaunchState.shared }
        _ = MainActor.assumeIsolated {
            launchState.configure(recognition: bootstrap, decision: decision)
        }
        _authorityState = StateObject(wrappedValue: launchState)
        _updater = StateObject(
            wrappedValue: UpdaterManager(
                startUpdates: !notificationRelayLaunch
                    && ManagedEnterprisePolicy.startupError == nil
                    && TenantProfile.startupError == nil))
    }

    private var authorityRecognition: StorageAuthorityRecognition {
        authorityState.sceneRecognition
    }

    var body: some Scene {
        // Workspace windows are NOT a SwiftUI WindowGroup — every one is hand-built by
        // `makeWorkspaceWindow` (NSWindow + NSHostingController(RootView)) and opened from
        // AppDelegate on launch / the reroute call sites. This is what gives EVERY workspace window
        // the same flush-left unified toolbar: a scene WindowGroup + NavigationSplitView welds an
        // NSTrackingSeparatorToolbarItem that indents the toolbar past the sidebar, and only hand-
        // hosted windows escape it. The commands below live on the dedicated Settings window scene
        // (they populate the app menu app-wide regardless of which scene hosts them).

        // The Projects launcher (idiom B) — a native gallery of Projects; each card opens/focuses that
        // project's workspace window. The "home" for navigating between project-scoped windows.
        Window(
            StorageAuthorityScenePresentation.windowTitle(
                StorageAuthorityScenePresentation.resolve(
                    allowsNormalProduct: authorityRecognition.disposition.allowsNormalProduct)),
            id: "projects"
        ) {
            StorageAuthorityContentGate(
                recognition: authorityRecognition,
                checkForUpdates: { updater.checkForUpdates() }) {
                ProjectsLauncherView().appChrome()
            }
        }
        .windowResizability(.contentMinSize)
        // Product workspaces have their own hand-built restoration ledger. This scene must never
        // be restored by SwiftUI: 0.26.19 used it as the migration surface, so a saved scene could
        // otherwise reopen beside the dedicated migration window on the very user we are repairing.
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(
            StorageAuthorityScenePresentation.resolve(
                allowsNormalProduct: authorityRecognition.disposition.allowsNormalProduct
            ).presentsProjectsAtLaunch ? .presented : .suppressed)
        .defaultSize(width: 820, height: 560)

        // The custom About box — the Magic & Lasers mark, name, version, copyright.
        Window("About Mechanician", id: "about") {
            StorageAuthorityContentGate(
                recognition: authorityRecognition,
                checkForUpdates: { updater.checkForUpdates() }) {
                AboutView().appChrome()
            }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Scheduled & Ambient Tasks", id: "ambient") {
            StorageAuthorityContentGate(
                recognition: authorityRecognition,
                checkForUpdates: { updater.checkForUpdates() }) {
                AmbientView().appChrome().tracksUtilityWindow(.ambient)
            }
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)   // don't auto-open at launch (opened on demand) — kills the startup flash at the source

        Window("Artifacts", id: "artifacts") {
            StorageAuthorityContentGate(
                recognition: authorityRecognition,
                checkForUpdates: { updater.checkForUpdates() }) {
                GlobalArtifactsView().appChrome().tracksUtilityWindow(.artifacts)
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 760)
        .defaultLaunchBehavior(.suppressed)   // don't auto-open at launch (opened on demand) — kills the startup flash at the source

        // Stable scene id retained from the former Extensions browser for restoration and alerts.
        Window("Mechanician Help", id: "help") {
            HelpWindowView(
                allowsLiveInventory: authorityRecognition.disposition.allowsNormalProduct
            ).appChrome()
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 940, height: 640)

        Window("Extensions", id: "extensions") {
            StorageAuthorityContentGate(
                recognition: authorityRecognition,
                checkForUpdates: { updater.checkForUpdates() }) {
                ExtensionsBrowserView().appChrome().tracksUtilityWindow(.extensions)
            }
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 820, height: 620)


        // A popped-out artifact in its own resizable/full-screenable window. Keyed by
        // PreviewPayload identity, so re-popping the same artifact re-focuses its window and
        // a live revision re-renders in place. Not tab-configured, so it stays out of the
        // workspace tab group.
        WindowGroup("Preview", id: "preview", for: PreviewPayload.self) { $payload in
            StorageAuthorityContentGate(
                recognition: authorityRecognition,
                checkForUpdates: { updater.checkForUpdates() }) {
                if let payload { PreviewWindowView(payload: payload).appChrome() }
            }
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)   // don't auto-open at launch (opened on demand) — kills the startup flash at the source
        .defaultSize(width: 1000, height: 760)

        // Persistent status item for the ambient agent — reachable even with no window open.
        MenuBarExtra(
            isInserted: notificationRelayLaunch
                || !authorityRecognition.disposition.allowsNormalProduct
                ? .constant(false) : $showMenuBar
        ) {
            StorageAuthorityContentGate(
                recognition: authorityRecognition,
                checkForUpdates: { updater.checkForUpdates() }) {
                AmbientMenuContent()
            }
        } label: {
            Image(nsImage: .bowlerHatMenuBar) // the mechanician's bowler, not AI sparkles
                .accessibilityLabel("Mechanician")
        }
        .menuBarExtraStyle(.menu)

        // A normal Window rather than SwiftUI's fixed-size `Settings` scene: the account/catalog
        // surface is information-dense and must resize like the rest of the app. We restore the
        // standard Settings menu item and ⌘, below.
        Window("Settings", id: "settings") {
            StorageAuthorityContentGate(
                recognition: authorityRecognition,
                checkForUpdates: { updater.checkForUpdates() }) {
                SettingsView().environmentObject(updater).appChrome()
            }
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 820, height: 660)

        Window("Providers", id: "accounts") {
            StorageAuthorityContentGate(
                recognition: authorityRecognition,
                checkForUpdates: { updater.checkForUpdates() }) {
                ProviderCenterWindow().appChrome().tracksUtilityWindow(.accounts)
            }
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 820, height: 640)
        // App-wide menu commands. Commands populate the main menu regardless of which scene hosts
        // them, so with the workspace WindowGroup gone they live here. (@FocusedObject resolves the
        // frontmost workspace's bridge via activeMenuBridge, so ⌘N/⌘T/etc. still target the front tab.)
        .commands {
            StorageAuthorityCommandSet(
                recognition: authorityRecognition,
                updater: updater)
        }

    }
}

private extension NSImage {
    /// The menu-bar status-item glyph: the Mechanician's bowler hat (traced from the reference
    /// art), not AI sparkles. A template image so it adapts to light/dark menu bars, embedded as a
    /// small gray+alpha PNG (no asset catalog needed) and rendered ~15pt tall.
    static let bowlerHatMenuBar: NSImage = {
        let b64 = "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"
        let img = Data(base64Encoded: b64).flatMap { NSImage(data: $0) } ?? NSImage()
        img.size = NSSize(width: 27.5, height: 15)   // 99:54 aspect, ~15pt tall
        img.isTemplate = true
        return img
    }()
}
