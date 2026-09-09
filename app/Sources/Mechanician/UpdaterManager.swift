import SwiftUI
import AppKit
import Combine
import Sparkle

/// Which entries in the signed Sparkle feed this installation accepts. Items without a
/// `sparkle:channel` are Sparkle's default channel and are always eligible; opting into Daily adds
/// the `daily` channel without excluding those stable releases.
enum UpdateChannel: String, Codable, CaseIterable, Identifiable {
    case stable
    case daily

    static let preferenceKey = "mech.update.channel"
    static let dailySparkleChannel = "daily"

    var id: Self { self }

    var allowedSparkleChannels: Set<String> {
        switch self {
        case .stable: return []
        case .daily: return [Self.dailySparkleChannel]
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let rawValue = defaults.string(forKey: preferenceKey),
              let channel = Self(rawValue: rawValue) else {
            // Missing and future/corrupt values fail closed to Sparkle's untagged stable channel.
            return .stable
        }
        return channel
    }

    static func isDailySparkleChannel(_ channel: String?) -> Bool {
        channel == dailySparkleChannel
    }
}

/// The person's affirmative decision about whether the app may contact its signed update feed
/// without a button press. This is intentionally separate from Sparkle's legacy preference:
/// `SUEnableAutomaticChecks` used to come from Info.plist, so its presence is not proof that a
/// person chose background network access.
enum AppUpdateNetworkChoice: String, Codable, Equatable {
    case automatic
    case manual

    static let preferenceKey = "mechanician.update.networkChoice.v1"

    var automaticallyChecks: Bool { self == .automatic }
}

/// Pure precedence rule for the first-run choice. Managed policy is authoritative; otherwise only
/// Mechanician's affirmative-choice key counts. Missing or corrupt state fails closed to manual
/// network behavior until the person chooses.
struct AppUpdateNetworkDecision: Equatable {
    enum Authority: Equatable {
        case mdm
        case managedSparkle
        case user
        case userChoiceRequired
    }

    let authority: Authority
    let choice: AppUpdateNetworkChoice?
    let automaticallyChecks: Bool
    let needsUserChoice: Bool

    static func resolve(
        managedPolicy: ManagedEnterprisePolicy?,
        defaults: UserDefaults
    ) -> AppUpdateNetworkDecision {
        if managedPolicy?.updateAuthority == .mdm {
            return AppUpdateNetworkDecision(
                authority: .mdm,
                choice: nil,
                automaticallyChecks: false,
                needsUserChoice: false)
        }
        if let forced = managedPolicy?.sparkleAutomaticChecks {
            return AppUpdateNetworkDecision(
                authority: .managedSparkle,
                choice: forced ? .automatic : .manual,
                automaticallyChecks: forced,
                needsUserChoice: false)
        }
        if let raw = defaults.string(forKey: AppUpdateNetworkChoice.preferenceKey),
           let choice = AppUpdateNetworkChoice(rawValue: raw) {
            return AppUpdateNetworkDecision(
                authority: .user,
                choice: choice,
                automaticallyChecks: choice.automaticallyChecks,
                needsUserChoice: false)
        }
        return AppUpdateNetworkDecision(
            authority: .userChoiceRequired,
            choice: nil,
            automaticallyChecks: false,
            needsUserChoice: true)
    }

    /// The first alert button is the privacy-preserving default. Any nonstandard dismissal also
    /// resolves to Manual; only an explicit click on the second button authorizes background checks.
    static func choice(forAlertResponse response: NSApplication.ModalResponse)
        -> AppUpdateNetworkChoice {
        response == .alertSecondButtonReturn ? .automatic : .manual
    }
}

/// Drives Sparkle through a CUSTOM user driver so every update dialog is ours (UpdatePanelView) —
/// the stock SPUStandardUpdaterController windows used default alert styling and system buttons
/// that read as a foreign app. The manager IS the SPUUserDriver: Sparkle calls in, we publish
/// phase state, and one panel window renders whatever phase we're in.
///
/// The feed URL and EdDSA public key live in Info.plist (SUFeedURL / SUPublicEDKey); updates are
/// verified against that key independently of Apple notarization — two layers of trust.
@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    static let sparkleAutomaticChecksPreferenceKey = "SUEnableAutomaticChecks"
    static let savedAutomaticChecksPreferenceKey =
        "mechanician.mdm.savedSparkleAutomaticChecks.v1"

    /// Where the update session is right now — exactly one panel layout per phase.
    enum Phase {
        case idle
        case checking
        case found(SUAppcastItem, SPUUserUpdateState)
        case downloading
        case extracting
        case readyToInstall
        case installing(applicationTerminated: Bool)
        case upToDate(latestVersion: String?)
        case error(NSError)
    }

    @Published var phase: Phase = .idle
    @Published var canCheckForUpdates = false
    @Published var expectedBytes: UInt64 = 0
    @Published var receivedBytes: UInt64 = 0
    @Published var extractionProgress: Double = 0
    @Published private(set) var updateChannel: UpdateChannel
    @Published private(set) var updateNetworkChoice: AppUpdateNetworkChoice?
    @Published private(set) var needsUpdateNetworkChoice: Bool
    /// Release notes fetched from an external releaseNotesURL (nil when the appcast embeds them
    /// in <description>, which UpdatePanelView reads straight off the item).
    @Published var downloadedNotes: String?

    private var updater: SPUUpdater?
    private var started = false
    private let shouldRunUpdater: Bool
    private let defaults: UserDefaults
    private let managedPolicy: ManagedEnterprisePolicy?
    private let updateSessionWasInjected: Bool
    private let updateCycleResetWasInjected: Bool
    private let updaterStartOverride: (() -> Void)?
    private var updateSessionInProgress: () -> Bool
    private var resetUpdateCycleForChannelChange: () -> Void

    // Sparkle's one-shot continuations. Each MUST be resolved exactly once: a stranded reply
    // stalls the whole update session and leaves canCheckForUpdates false forever.
    private var pendingReply: ((SPUUserUpdateChoice) -> Void)?
    private var pendingAcknowledge: (() -> Void)?
    private var pendingCancel: (() -> Void)?
    private var retryTermination: (() -> Void)?

    private var window: NSWindow?
    private var deferredPresentation: Task<Void, Never>?
    private var networkChoicePresentationStarted = false
    private var tearingDown = false   // the close came from Sparkle's teardown, not the user

    /// Host-only disclosure for Settings. Paths, query strings, credentials, and fragments are
    /// deliberately discarded before reaching the UI.
    let updateFeedHost: String?

    override convenience init() {
        self.init(startUpdates: true)
    }

    /// Notification-relay launches use the signed app executable solely to establish native
    /// notification ownership. They must not start a second Sparkle session beside the real app.
    init(
        startUpdates: Bool,
        defaults: UserDefaults = .standard,
        updateSessionInProgress: (() -> Bool)? = nil,
        updateCycleReset: (() -> Void)? = nil,
        managedPolicy: ManagedEnterprisePolicy? = ManagedEnterprisePolicy.current,
        feedConfigured: Bool? = nil,
        feedURLString: String? = nil,
        updaterStartOverride: (() -> Void)? = nil
    ) {
        // Sparkle's automatic-check setter persists into the app's user defaults. Preserve the
        // user's exact prior presence/value before applying a temporary managed overlay, then
        // restore it when the policy key disappears. Reconcile before constructing SPUUpdater so
        // Sparkle reads the effective value without another persistence-writing setter call.
        if startUpdates {
            Self.reconcileAutomaticChecksPreference(
                forcedValue: managedPolicy?.updateAuthority == .sparkle
                    ? managedPolicy?.sparkleAutomaticChecks : nil,
                defaults: defaults)
        }
        let bundledFeedURL = feedURLString
            ?? (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)
        let hasFeed = feedConfigured ?? (bundledFeedURL != nil)
        let networkDecision = AppUpdateNetworkDecision.resolve(
            managedPolicy: managedPolicy,
            defaults: defaults)

        // Only run the updater when a feed is actually configured. A dev `swift run`
        // has no bundled Info.plist (no SUFeedURL), so starting Sparkle there just
        // produces a confusing "can't access updates" error — skip it entirely.
        let shouldStart = startUpdates
            && managedPolicy?.updateAuthority != .mdm
            && hasFeed
        shouldRunUpdater = shouldStart
        self.defaults = defaults
        self.managedPolicy = managedPolicy
        updateFeedHost = NetworkConfigurationDisclosure.host(fromHTTPSURL: bundledFeedURL)
        updateChannel = managedPolicy?.sparkleUpdateChannel ?? UpdateChannel.load(from: defaults)
        updateNetworkChoice = networkDecision.choice
        needsUpdateNetworkChoice = networkDecision.needsUserChoice
        updateSessionWasInjected = updateSessionInProgress != nil
        updateCycleResetWasInjected = updateCycleReset != nil
        self.updaterStartOverride = updaterStartOverride
        self.updateSessionInProgress = updateSessionInProgress ?? { false }
        resetUpdateCycleForChannelChange = updateCycleReset ?? {}

        // Sparkle is not constructed until the choice exists. Persisting the effective value first
        // is defense in depth: even if Sparkle changes its startup scheduling, it cannot interpret
        // the old Info.plist default as permission to make a request.
        if shouldStart {
            defaults.set(
                networkDecision.automaticallyChecks,
                forKey: Self.sparkleAutomaticChecksPreferenceKey)
        }
        super.init()

        if shouldStart, !networkDecision.needsUserChoice {
            startUpdater()
        } else if shouldStart {
            scheduleNetworkChoicePresentation()
        }
    }

    private func startUpdater() {
        guard shouldRunUpdater, !started, !needsUpdateNetworkChoice else { return }
        if let updaterStartOverride {
            started = true
            updaterStartOverride()
            return
        }
        let u = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        updater = u
        if !updateSessionWasInjected {
            self.updateSessionInProgress = { [weak u] in u?.sessionInProgress ?? false }
        }
        if !updateCycleResetWasInjected {
            // The session gate below makes the immediate reset safe and avoids Sparkle silently
            // dropping a delayed reset if its scheduler starts a session first.
            resetUpdateCycleForChannelChange = { [weak u] in
                u?.resetUpdateCycle()
            }
        }
        started = true
        u.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        do { try u.start() } catch { NSLog("Sparkle failed to start: \(error)") }
    }

    private func scheduleNetworkChoicePresentation() {
        WorkspaceSessionLaunchGate.shared.whenOpen { [weak self] in
            // Session replay has selected the window that owns the launch. Let it become key before
            // attaching an application-modal decision to the foreground app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.presentUpdateNetworkChoiceIfNeeded()
            }
        }
    }

    func presentUpdateNetworkChoiceIfNeeded() {
        guard shouldRunUpdater,
              needsUpdateNetworkChoice,
              !networkChoicePresentationStarted else { return }
        networkChoicePresentationStarted = true
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Choose how Mechanician checks for updates")
        let host = updateFeedHost ?? String(localized: "the configured update host")
        alert.informativeText = String(localized: """
            Manual Check, the recommended network-quiet choice, contacts \(host) only when you \
            choose Check Now. Automatic checks may contact it in the background for signed app \
            releases. Neither option sends conversations, configuration, or a system profile.
            """)
        alert.addButton(withTitle: String(localized: "Manual Check Only"))
        alert.addButton(withTitle: String(localized: "Automatic Update Checks"))
        let response = alert.runModal()
        setUpdateNetworkChoice(AppUpdateNetworkDecision.choice(forAlertResponse: response))
        networkChoicePresentationStarted = false
    }

    /// Records an explicit choice before Sparkle exists, then starts Sparkle. Choosing Manual does
    /// not make a request; it only enables the user-triggered Check path for this launch.
    func setUpdateNetworkChoice(_ choice: AppUpdateNetworkChoice) {
        guard canChangeAutomaticUpdateChecks else { return }
        defaults.set(choice.rawValue, forKey: AppUpdateNetworkChoice.preferenceKey)
        defaults.set(choice.automaticallyChecks, forKey: Self.sparkleAutomaticChecksPreferenceKey)
        updateNetworkChoice = choice
        needsUpdateNetworkChoice = false
        updater?.automaticallyChecksForUpdates = choice.automaticallyChecks
        startUpdater()
    }

    /// Whether Sparkle checks for updates automatically in the background.
    var automaticallyChecksForUpdates: Bool {
        get {
            if managedPolicy?.updateAuthority == .mdm { return false }
            return managedPolicy?.sparkleAutomaticChecks
                ?? updateNetworkChoice?.automaticallyChecks
                ?? false
        }
        set {
            setUpdateNetworkChoice(newValue ? .automatic : .manual)
        }
    }

    var canChangeAutomaticUpdateChecks: Bool {
        managedPolicy?.updateAuthority != .mdm
            && managedPolicy?.sparkleAutomaticChecks == nil
    }

    var updatesAreManagedByMDM: Bool {
        managedPolicy?.updateAuthority == .mdm
    }

    var automaticUpdateChecksAreManaged: Bool {
        updatesAreManagedByMDM || managedPolicy?.sparkleAutomaticChecks != nil
    }

    /// Maintains a reversible local overlay for Sparkle's own persisted setting. A dictionary is
    /// used so an absent user value stays distinct from an explicit Boolean; absence falls back to
    /// the signed app's Info.plist when management is later removed.
    static func reconcileAutomaticChecksPreference(
        forcedValue: Bool?,
        defaults: UserDefaults
    ) {
        if let forcedValue {
            if defaults.object(forKey: savedAutomaticChecksPreferenceKey) == nil {
                var snapshot: [String: Any] = ["present": false]
                if let prior = defaults.object(forKey: sparkleAutomaticChecksPreferenceKey) {
                    snapshot = ["present": true, "value": prior]
                }
                defaults.set(snapshot, forKey: savedAutomaticChecksPreferenceKey)
            }
            defaults.set(forcedValue, forKey: sparkleAutomaticChecksPreferenceKey)
            return
        }

        guard let snapshot = defaults.dictionary(forKey: savedAutomaticChecksPreferenceKey),
              let wasPresent = snapshot["present"] as? Bool else { return }
        if wasPresent {
            guard let prior = snapshot["value"] else { return }
            defaults.set(prior, forKey: sparkleAutomaticChecksPreferenceKey)
        } else {
            defaults.removeObject(forKey: sparkleAutomaticChecksPreferenceKey)
        }
        defaults.removeObject(forKey: savedAutomaticChecksPreferenceKey)
    }

    /// Sparkle ignores cycle resets while an update session is in progress. Keep the preference
    /// and the active filter in lockstep by changing channels only after that session returns idle.
    var canChangeUpdateChannel: Bool {
        guard managedPolicy?.updateAuthority != .mdm,
              managedPolicy?.sparkleUpdateChannel == nil else { return false }
        guard case .idle = phase else { return false }
        // Background checks may never present a user-driver phase, and canCheckForUpdates is
        // explicitly not an exact session signal. Read Sparkle's session authority directly.
        return !updateSessionInProgress()
    }

    /// Persist a new feed filter and ask Sparkle to reconsider its next update cycle. This does not
    /// initiate an install and cannot downgrade the app; Sparkle still requires a newer build than
    /// the one currently installed.
    func setUpdateChannel(_ channel: UpdateChannel) {
        guard canChangeUpdateChannel, channel != updateChannel else { return }
        updateChannel = channel
        defaults.set(channel.rawValue, forKey: UpdateChannel.preferenceKey)
        resetUpdateCycleForChannelChange()
    }

    func checkForUpdates() {
        if managedPolicy?.updateAuthority == .mdm {
            let a = NSAlert()
            a.messageText = String(localized: "Software updates are managed by your organization.")
            a.runModal()
            return
        }
        if needsUpdateNetworkChoice {
            presentUpdateNetworkChoiceIfNeeded()
            return
        }
        guard started else {
            let a = NSAlert()
            a.messageText = "Updates are handled by the installed app."
            a.informativeText = "This development build doesn't check for updates. Run Mechanician from /Applications to receive updates."
            a.runModal()
            return
        }
        updater?.checkForUpdates()
    }

    // MARK: - Panel actions (invoked by UpdatePanelView)

    /// Answer the pending install/dismiss/skip question. Guarded so a double-click can't
    /// double-drive Sparkle's state machine.
    func choose(_ choice: SPUUserUpdateChoice) {
        guard let reply = pendingReply else { return }
        pendingReply = nil
        reply(choice)
    }

    /// Acknowledge an informational phase (up to date / error) and put the panel away.
    func acknowledge() {
        guard let ack = pendingAcknowledge else { return }
        pendingAcknowledge = nil
        ack()
    }

    /// Cancel an in-flight check or download (valid until extraction starts).
    func cancelInFlight() {
        let cancel = pendingCancel
        pendingCancel = nil
        cancel?()
    }

    /// Re-send the quit event when installing stalled on "waiting for the app to quit".
    func retryQuit() { retryTermination?() }

    /// An information-only update has nothing to install — open its page instead.
    func openInfoURL(_ item: SUAppcastItem) {
        if let url = item.infoURL { NSWorkspace.shared.open(url) }
        choose(.dismiss)
    }

    // MARK: - The panel window

    private func present(makeKey: Bool) {
        if window == nil {
            let host = NSHostingController(rootView: UpdatePanelView().environmentObject(self))
            let win = NSWindow(contentViewController: host)
            win.title = "Software Update"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            // Inherits the app-wide appearance just like workspace and SwiftUI scene windows.
            win.appearance = nil
            win.center()
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: win, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.windowDidClose() }
            }
            window = win
        }
        guard let window else { return }

        // macOS 27 can abort inside NSRemoteView when a text-completion service is still attached
        // as another window is ordered (FB23642313). The user's crash report points at this exact
        // call. Retire the current editor, then give ViewBridge one short quiet period to detach;
        // later phase callbacks coalesce onto the newest requested presentation.
        deferredPresentation?.cancel()
        _ = RemoteTextServiceSafety.retireActiveEditor(in: NSApp.keyWindow)
        let delay = RemoteTextServiceSafety.presentationDelayNanoseconds(
            forMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        guard delay > 0 else {
            order(window, makeKey: makeKey)
            return
        }
        deferredPresentation = Task { @MainActor [weak self, weak window] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self, let window, self.window === window, self.phase.isPresentable else {
                return
            }
            self.deferredPresentation = nil
            self.order(window, makeKey: makeKey)
        }
    }

    private func order(_ window: NSWindow, makeKey: Bool) {
        if makeKey {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            // A background-scheduled check found something: surface the panel without
            // yanking focus from whatever the user is doing.
            window.orderFront(nil)
        }
    }

    /// The user closed the panel: resolve whatever Sparkle is waiting on with the dismissive
    /// answer so the session ends cleanly instead of stalling.
    private func windowDidClose() {
        guard !tearingDown else { return }
        deferredPresentation?.cancel()
        deferredPresentation = nil
        if let reply = pendingReply { pendingReply = nil; reply(.dismiss) }
        if let ack = pendingAcknowledge { pendingAcknowledge = nil; ack() }
        if let cancel = pendingCancel { pendingCancel = nil; cancel() }
        retryTermination = nil
        phase = .idle
    }

    private func teardownToIdle() {
        deferredPresentation?.cancel()
        deferredPresentation = nil
        pendingReply = nil
        pendingAcknowledge = nil
        pendingCancel = nil
        retryTermination = nil
        phase = .idle
        if let win = window, win.isVisible {
            tearingDown = true
            win.close()
            tearingDown = false
        }
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdaterManager: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        updateChannel.allowedSparkleChannels
    }
}

// MARK: - SPUUserDriver

extension UpdaterManager: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Mechanician owns this choice before constructing Sparkle. Echo that explicit or managed
        // decision, and never authorize Sparkle's optional system-profile transmission.
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: automaticallyChecksForUpdates,
            sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        pendingCancel = cancellation
        phase = .checking
        present(makeKey: true)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingReply = reply
        pendingCancel = nil
        downloadedNotes = nil
        phase = .found(appcastItem, state)
        present(makeKey: state.userInitiated)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        var encoding = String.Encoding.utf8
        if let name = downloadData.textEncodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            }
        }
        downloadedNotes = String(data: downloadData.data, encoding: encoding)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // The found-panel just shows without a notes card — not worth an error state.
        NSLog("Release notes failed to download: \(error.localizedDescription)")
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        pendingAcknowledge = acknowledgement
        let latest = ((error as NSError).userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem)?
            .displayVersionString
        phase = .upToDate(latestVersion: latest)
        present(makeKey: true)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let ns = error as NSError
        // The user canceled the authorization prompt (SUInstallationCanceledError = 4007) —
        // their own action, not an error worth a dialog.
        if ns.domain == SUSparkleErrorDomain, ns.code == 4007 {
            acknowledgement()
            teardownToIdle()
            return
        }
        pendingAcknowledge = acknowledgement
        phase = .error(ns)
        present(makeKey: true)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        pendingCancel = cancellation
        expectedBytes = 0
        receivedBytes = 0
        phase = .downloading
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        // Sparkle may send this more than once per download (e.g. delta, then full):
        // treat each as a fresh total.
        expectedBytes = expectedContentLength
        receivedBytes = 0
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
    }

    func showDownloadDidStartExtractingUpdate() {
        pendingCancel = nil   // cancellation is only valid until extraction begins
        extractionProgress = 0
        phase = .extracting
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        extractionProgress = progress
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingReply = reply
        phase = .readyToInstall
        present(makeKey: true)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        retryTermination = applicationTerminated ? nil : retryTerminatingApplication
        phase = .installing(applicationTerminated: applicationTerminated)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        // Rarely reached (the updater usually dies with the app during relaunch); nothing to show.
        acknowledgement()
    }

    /// "Check for Updates…" hit while the panel is already up — implementing this is also what
    /// keeps canCheckForUpdates true (so the menu item stays live) while our UI is visible.
    func showUpdateInFocus() {
        present(makeKey: true)
    }

    /// Sparkle's universal "reset to idle" — can arrive at any stage (abort, error, finished).
    func dismissUpdateInstallation() {
        teardownToIdle()
    }
}

private extension UpdaterManager.Phase {
    /// A delayed order request must not resurrect a panel Sparkle dismissed in the meantime.
    var isPresentable: Bool {
        if case .idle = self { return false }
        return true
    }
}
