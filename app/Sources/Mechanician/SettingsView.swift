import SwiftUI
import AppKit
import CoreGraphics
import ApplicationServices
import UniformTypeIdentifiers

enum SettingsTab: Hashable, CaseIterable {
    case general, appearance, permissions, extensions, updates, advanced

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .permissions: return "Permissions"
        case .extensions: return "Extensions"
        case .updates: return "Updates"
        case .advanced: return "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .permissions: return "lock.shield"
        case .extensions: return "puzzlepiece.extension"
        case .updates: return "arrow.triangle.2.circlepath"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

@MainActor final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var selectedTab: SettingsTab = .general
    private init() {}
}

private let settingsWindowIdentifier = NSUserInterfaceItemIdentifier("Mechanician.Settings")

/// SwiftUI's `openWindow` may retain a hidden regular Window scene without bringing its NSWindow
/// back. Give the scene a stable native identity so every Settings entry point can reliably reuse,
/// demiminiaturize, and foreground that one resizable window.
private struct SettingsWindowMarker: NSViewRepresentable {
    final class MarkerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = settingsWindowIdentifier
        }
    }

    func makeNSView(context: Context) -> NSView { MarkerView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.identifier = settingsWindowIdentifier
    }
}

@MainActor private func focusSettingsWindow() -> Bool {
    guard let window = NSApp.windows.first(where: { $0.identifier == settingsWindowIdentifier }) else {
        return false
    }
    if window.isMiniaturized { window.deminiaturize(nil) }
    if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }),
       let screen = NSScreen.main ?? NSScreen.screens.first {
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(
            x: visible.midX - window.frame.width / 2,
            y: visible.midY - window.frame.height / 2))
    }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    return true
}

@MainActor func showSettings(
    tab: SettingsTab = .general,
    using openWindow: OpenWindowAction? = nil
) {
    SettingsNavigation.shared.selectedTab = tab
    if focusSettingsWindow() { return }
    (openWindow ?? appOpenWindow)?(id: "settings")
    DispatchQueue.main.async {
        MainActor.assumeIsolated { _ = focusSettingsWindow() }
    }
}

struct SettingsView: View {
    // Edits the most-recently-active window's workspace (a Settings window taking
    // focus would make @FocusedObject nil, so we track it explicitly).
    @ObservedObject private var active = ActiveWorkspace.shared

    var body: some View {
        Group {
            if let bridge = active.bridge {
                SettingsTabs(bridge: bridge)
            } else {
                Text("Open a window to change settings.")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 720, idealWidth: 820, maxWidth: .infinity,
                           minHeight: 520, idealHeight: 660, maxHeight: .infinity)
                    .background(Color.nBg)
            }
        }
        .background(SettingsWindowMarker().frame(width: 0, height: 0))
    }
}

/// Settings navigation remains explicit because this is a regular, resizable window rather than
/// SwiftUI's fixed-size Settings scene. The icon-and-label bar preserves the familiar macOS
/// preferences layout while allowing the information-dense panes to grow with the window.
private struct SettingsTabs: View {
    @ObservedObject var bridge: AgentBridge
    @ObservedObject private var navigation = SettingsNavigation.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    settingsTabButton(tab)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(.bar)

            Divider()

            selectedPane
        }
        .background(Color.nBg)
        .tint(.nAccent)
    }

    private func settingsTabButton(_ tab: SettingsTab) -> some View {
        let selected = navigation.selectedTab == tab
        return Button {
            navigation.selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .frame(height: 20)
                Text(tab.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.nInfoText : Color.primary)
            .frame(minWidth: 78)
            .padding(.horizontal, 3)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.nAccent.opacity(0.13) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityValue(selected ? "Selected" : "")
    }

    @ViewBuilder
    private var selectedPane: some View {
        switch navigation.selectedTab {
        case .general:
            GeneralSettings(bridge: bridge)
        case .appearance:
            AppearanceSettings()
        case .permissions:
            PermissionsSettings(bridge: bridge)
        case .extensions:
            ExtensionsSettingsLauncher()
        case .updates:
            UpdatesSettings()
        case .advanced:
            AdvancedSettings(bridge: bridge)
        }
    }
}

/// Settings ▸ Extensions is a launcher rather than a second management surface.
private struct ExtensionsSettingsLauncher: View {
    @ObservedObject private var store = ExtensionsStore.shared
    @ObservedObject private var active = ActiveWorkspace.shared
    @Environment(\.openWindow) private var openWindow

    private var connectorCount: Int {
        store.foreignServers(for: active.bridge?.currentModelAccess ?? .claudeSubscription).count
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "link")
                .font(.system(size: 34)).foregroundStyle(Color.nAccent)
            Text("Extensions").font(.system(size: 17, weight: .semibold))
            Text("Manage apps, services, and local MCP connections in one place.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)

            HStack(spacing: 18) {
                summary("\(store.mcpServers.count + connectorCount)", "connection\(store.mcpServers.count + connectorCount == 1 ? "" : "s")")
                if !store.plugins.isEmpty {
                    summary("\(store.plugins.count)", "provider package\(store.plugins.count == 1 ? "" : "s")")
                }
            }
            .padding(.vertical, 4)

            Button { openWindow(id: "extensions") } label: {
                Label("Open Extensions", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(PillButtonStyle(kind: .accent))
            .keyboardShortcut("e", modifiers: [.command, .option])
        }
        .frame(minWidth: 720, idealWidth: 820, maxWidth: .infinity,
               minHeight: 520, idealHeight: 660, maxHeight: .infinity)
        .background(Color.nBg)
    }

    private func summary(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.nText)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Shared look for every settings pane's Form.
private struct SettingsPane: ViewModifier {
    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color.nBg)
            .frame(minWidth: 720, idealWidth: 820, maxWidth: .infinity,
                   minHeight: 520, idealHeight: 660, maxHeight: .infinity)
    }
}
private extension View {
    func settingsPane() -> some View { modifier(SettingsPane()) }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var bridge: AgentBridge
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("menuBarExtra") private var showMenuBar = true
    @State private var onDeviceRefresh = 0

    var body: some View {
        Form {
            Section("Agent") {
                Text("Choose the model and reasoning effort for each conversation from the controls at the bottom of its window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Apple Intelligence") {
                let _ = onDeviceRefresh // re-evaluate availability when re-checked
                let ready = OnDeviceModel.isAvailable
                HStack(spacing: 6) {
                    Image(systemName: ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ready ? Color.nSuccessText : Color.nWarningText)
                    Text("On-device model")
                    Spacer()
                    Button("Re-check") { onDeviceRefresh += 1 }.buttonStyle(PillButtonStyle(kind: .plain))
                }
                Text(OnDeviceModel.availabilityReason)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Names new conversations and suggests follow-ups privately, right on your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LibraryBackupSettingsSection()

            Section("Notifications") {
                Toggle("Notify when the agent finishes, asks a question, needs approval, or a workflow completes",
                       isOn: $notificationsEnabled)
                Text("Alerts appear whenever the requesting conversation isn't in the key window (including when another Mechanician window is key), subject to macOS notification permission.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Menu Bar") {
                Toggle("Show the ambient agent in the menu bar", isOn: $showMenuBar)
                Text("A status item to see scheduled tasks, run one now, or start a conversation, even with no window open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsPane()
    }
}

// MARK: - Account

private struct ProfileNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// The one provider-management surface. It is hosted by the persistent Providers utility window;
/// Settings and recovery entry points focus that window instead of maintaining divergent controls.
struct ProviderCenterView: View {
    @ObservedObject var bridge: AgentBridge
    @ObservedObject private var accounts = ProviderAccountStore.shared
    @ObservedObject private var profileUpdater = TenantProfileUpdater.shared
    @ObservedObject private var profileImports = EnterpriseProfileImportCoordinator.shared
    @State private var editingAPI: ModelAccess?
    @State private var apiKeyInputs: [ModelAccess: String] = [:]
    /// Live credential check state for the key field: disables Save while in flight, and carries
    /// the "saved but could not verify" note when the provider was unreachable.
    @State private var verifyingKey = false
    @State private var keyNotice: String?
    @State private var installedProfile: TenantProfile?
    @State private var profileChangedSinceLaunch = false
    @State private var pickingProfile = false
    @State private var pendingProfileImport: PendingProfileImport?
    @State private var confirmingProfileRemoval = false
    @State private var profileNotice: ProfileNotice?
    @State private var inspectingConfiguration = false

    private var mdmSuppliesSignedProfile: Bool {
        ManagedEnterprisePolicy.current?.signedProfile != nil
    }

    private var canEditLocalConfiguration: Bool {
        ManagedEnterprisePolicy.current?.allowLocalConfigurationOverrides ?? true
    }

    private var canMutateLocalProfile: Bool {
        guard let policy = ManagedEnterprisePolicy.current else { return true }
        return policy.signedProfile == nil && policy.allowLocalProfile
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Providers")
                            .font(.system(size: 22, weight: .semibold))
                        Text("Import managed configuration and connect the accounts whose models you want available in Mechanician.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    Button { accounts.refresh() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(PillButtonStyle(kind: .plain))
                }

                if bridge.hasPendingProviderSetupRecovery {
                    providerSetupRecoveryCard
                }

                managedConfigurationCard

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        anthropicCard.frame(minWidth: 360)
                        openAICard.frame(minWidth: 360)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        anthropicCard
                        openAICard
                    }
                }

                Label {
                    Text(bridge.hasPendingProviderSetupRecovery
                         ? "This window was opened from a blocked conversation. The connection you explicitly use, connect, or configure here will resume that conversation; unrelated account changes remain routing-neutral."
                         : "The default connection is used for new conversations. Choose a different connection and model for an existing conversation from the model control at the bottom of its window. Account changes here never retarget existing conversations.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(Color.nInfoText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
            .frame(maxWidth: 980, alignment: .topLeading)
            .padding(24)
        }
        .frame(minWidth: 720, idealWidth: 820, maxWidth: .infinity,
               minHeight: 520, idealHeight: 660, maxHeight: .infinity)
        .background(Color.nBg)
        .onAppear {
            accounts.refresh()
            reloadInstalledProfile()
        }
        .onChange(of: profileImports.delivery?.id, initial: true) { _, id in
            receiveProfileImport(id)
        }
        .onDisappear {
            clearAPIKeyDrafts()
            bridge.cancelProviderSetupRecovery()
        }
        .fileImporter(
            isPresented: $pickingProfile,
            allowedContentTypes: [.mechanicianEnterpriseProfile],
            allowsMultipleSelection: false
        ) { result in
            handleProfileSelection(result)
        }
        .sheet(isPresented: $inspectingConfiguration) {
            ManagedConfigurationView(
                profile: TenantProfile.current,
                signed: TenantProfile.currentSignedProfile,
                installed: installedProfile,
                onDone: { inspectingConfiguration = false })
        }
        .sheet(item: $pendingProfileImport) { pending in
            ProfileImportReview(
                pending: pending,
                replacingExistingProfile: installedProfile != nil,
                onCancel: { pendingProfileImport = nil },
                onInstall: { installProfile(pending) })
        }
        .confirmationDialog(
            "Remove managed configuration?",
            isPresented: $confirmingProfileRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Configuration", role: .destructive) { removeProfile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Vertex AI and managed extension catalogs will be removed after Mechanician restarts.")
        }
        .alert(item: $profileNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK")))
        }
    }

    /// A feed that cannot be reached is an ordinary condition (these are commonly VPN-only), so it
    /// reports as information rather than as a fault the user must act on.
    private var profileUpdateStatus: String {
        switch profileUpdater.lastOutcome {
        case .updated(_, let retired):
            let restart = "Configuration updated. Quit and reopen Mechanician to activate it."
            guard !retired.isEmpty else { return restart }
            // Naming what was taken back matters more than the fact of an update. These are settings
            // the person deliberately changed, and a list that silently reverts reads as the app
            // losing their work rather than their organization republishing it.
            return restart + " Your organization has since changed settings you had edited here, so "
                 + "theirs are in use again: \(retired.joined(separator: ", "))."
        case .failed(let message):
            return "Could not check for a configuration update. \(message)"
        case .notNewer(let installed, let served):
            // Say what happened in terms the person can act on. "Revision 6 does not advance
            // revision 6" is true and useless: it names an internal counter, reads as a fault, and
            // points at nothing. Each branch below names who can actually resolve it.
            guard let served else {
                return "Your organization's feed does not say which version it is, so it was not "
                     + "installed. Your administrator can fix this by publishing a numbered version."
            }
            guard let installed else {
                return "Your organization's feed does not publish a valid positive version for "
                     + "this configuration migration, so nothing was installed. Ask your "
                     + "administrator to publish it as a numbered version."
            }
            if served == installed {
                return "Already using version \(installed). Your organization's feed has changes "
                     + "that are not marked as a new version, so they were not installed. Ask your "
                     + "administrator to publish them as a new version."
            }
            return "This Mac is on version \(installed), which is newer than the version "
                 + "\(served) your organization is publishing. Nothing was changed."
        case .notConfigured:
            return "This configuration was imported manually and does not update on its own."
        case .unchanged, .none:
            guard let checked = profileUpdater.lastCheckedAt else {
                return installedProfile?.update?.effectiveProfileUpdateMode == .manual
                    ? "Checks only when you choose Check for Updates."
                    : "Updates automatically from your organization."
            }
            let prefix = installedProfile?.update?.effectiveProfileUpdateMode == .manual
                ? "Manual check complete." : "Up to date."
            return "\(prefix) Checked \(checked.formatted(date: .abbreviated, time: .shortened))."
        }
    }

    /// Only a real fault, or a state the user must act on, is styled as a problem. A document that
    /// is simply not newer is an ordinary answer and must not be dressed as a failure.
    private var profileUpdateStatusIsProblem: Bool {
        if case .failed = profileUpdater.lastOutcome { return true }
        if case .updated = profileUpdater.lastOutcome { return true }
        return false
    }

    private var providerSetupRecoveryCard: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.nPurpleText)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose a connection to resume the conversation")
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Use a connected account now, or connect/configure one below. Once it is verified, Mechanician will apply its default model without another picker step.")
                    .font(.caption)
                    .foregroundStyle(Color.nSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Cancel") { bridge.cancelProviderSetupRecovery() }
                .buttonStyle(PillButtonStyle(kind: .plain))
        }
        .padding(.leading, 17)
        .padding(.trailing, 10)
        .padding(.vertical, 11)
        .providerRecoverySurface(cornerRadius: 12)
    }

    private var managedConfigurationCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Managed Configuration")
                    .font(.headline)
                if installedProfile != nil || TenantProfile.currentIsManagedByMDM {
                    Group {
                        if TenantProfile.currentIsManagedByMDM {
                            Text("MANAGED")
                        } else {
                            Text("VERIFIED")
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.nSuccessText)
                }
                Spacer()
                if installedProfile != nil || TenantProfile.currentIsManagedByMDM {
                    Text(profileChangedSinceLaunch ? "RESTART REQUIRED" : "ACTIVE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(
                            profileChangedSinceLaunch ? Color.nWarningText : Color.nInfoText)
                }
            }

            if TenantProfile.currentIsManagedByMDM {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        TenantProfile.current.displayName,
                        systemImage: "checkmark.shield.fill")
                        .font(.callout.weight(.semibold))
                    if mdmSuppliesSignedProfile {
                        Text("This profile and its organization policy are enforced through macOS managed preferences.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Organization policy is enforced through macOS managed preferences; local configuration follows that policy.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let revision = ManagedEnterprisePolicy.current?.revision {
                        Text("Policy revision \(revision)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if canEditLocalConfiguration {
                        Button(
                            TenantProfile.current.isDefault
                                ? "Create Configuration…" : "Edit Configuration…"
                        ) { inspectingConfiguration = true }
                            .buttonStyle(PillButtonStyle(kind: .plain))
                            .accessibilityLabel("Edit the managed configuration")
                    }
                    if canMutateLocalProfile {
                        if installedProfile == nil {
                            Button("Import Configuration…") { pickingProfile = true }
                                .buttonStyle(PillButtonStyle(kind: .plain))
                        } else {
                            Button("Replace Configuration…") { pickingProfile = true }
                                .buttonStyle(PillButtonStyle(kind: .plain))
                            Button("Remove") { confirmingProfileRemoval = true }
                                .buttonStyle(PillButtonStyle(kind: .neutral))
                        }
                    }
                    Spacer()
                }
            } else if let profile = installedProfile {
                VStack(alignment: .leading, spacing: 6) {
                    Label(profile.tenantId.capitalized, systemImage: "checkmark.shield.fill")
                        .font(.callout.weight(.semibold))
                    if let vertex = profile.vertexConfig {
                        Label(
                            "Claude on Vertex AI · \(vertex.projectId) · \(vertex.region)",
                            systemImage: "cloud.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    let sourceCount = profile.extensions.managedSources.count
                    if sourceCount > 0 {
                        Label(
                            "\(sourceCount) managed extension catalog\(sourceCount == 1 ? "" : "s")",
                            systemImage: "puzzlepiece.extension")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if profileChangedSinceLaunch {
                        Text("Quit and reopen Mechanician to activate this configuration. Vertex will then appear below as a provider connection.")
                            .font(.caption)
                            .foregroundStyle(Color.nWarningText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if profile.update?.profileFeedURL != nil {
                    HStack(spacing: 7) {
                        if profileUpdater.isChecking {
                            ProgressView().controlSize(.mini)
                        }
                        Text(profileUpdateStatus)
                            .font(.caption)
                            .foregroundStyle(
                                profileUpdateStatusIsProblem ? Color.nWarningText : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    // A managed profile silently sets provider routing, the model list, the MCP
                    // registry and the plugin marketplace. Without this, the only view of any of it
                    // was the one-time import sheet.
                    Button("Show Configuration…") { inspectingConfiguration = true }
                        .buttonStyle(PillButtonStyle(kind: .plain))
                        .accessibilityLabel("Show managed configuration details")
                    Button("Replace Configuration…") { pickingProfile = true }
                        .buttonStyle(PillButtonStyle(kind: .plain))
                    if profile.update?.profileFeedURL != nil {
                        Button("Check for Updates") {
                            Task {
                                await profileUpdater.check()
                                reloadInstalledProfile()
                            }
                        }
                        .buttonStyle(PillButtonStyle(kind: .plain))
                        .disabled(profileUpdater.isChecking)
                    }
                    Button("Remove") { confirmingProfileRemoval = true }
                        .buttonStyle(PillButtonStyle(kind: .neutral))
                    Spacer()
                }
            } else if !TenantProfile.current.isDefault {
                // A configuration can be ACTIVE without a file at the standard install path — it
                // was authored here, or supplied by an administrator override. Reporting either as
                // "removed" told the user the opposite of what the app was actually doing, and hid
                // the only view of a configuration that is demonstrably in effect.
                Text(TenantProfile.currentSignedProfile.isDefault
                     ? "This configuration was created on this Mac. It is not signed, so it applies here only. Export it to share the same setup with others."
                     : "A managed configuration is active for this launch but is not installed in the standard location, so it cannot be replaced or removed from here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Edit Configuration…") { inspectingConfiguration = true }
                        .buttonStyle(PillButtonStyle(kind: .plain))
                        .accessibilityLabel("Edit the managed configuration")
                    Button("Import Configuration…") { pickingProfile = true }
                        .buttonStyle(PillButtonStyle(kind: .plain))
                    Spacer()
                }
            } else {
                Text(profileChangedSinceLaunch
                     ? "The managed configuration has been removed. Quit and reopen Mechanician to finish removing its providers and catalogs."
                     : "No configuration is set up. Create one here to add a provider this build supports but cannot discover on its own, such as Claude on Google Vertex AI or AWS Bedrock, or import a signed .mechanician-profile your organization published.")
                    .font(.caption)
                    .foregroundStyle(
                        profileChangedSinceLaunch ? Color.nWarningText : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Create Configuration…") { inspectingConfiguration = true }
                        .buttonStyle(PillButtonStyle(kind: .accent))
                        .accessibilityLabel("Create a configuration on this Mac")
                    Button("Import Configuration…") { pickingProfile = true }
                        .buttonStyle(PillButtonStyle(kind: .plain))
                    Spacer()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardSurface(cornerRadius: 14, strokeOpacity: 0.45)
    }

    private func reloadInstalledProfile() {
        do {
            installedProfile = try TenantProfile.loadInstalledProfile()
            if mdmSuppliesSignedProfile
                || ManagedEnterprisePolicy.current?.allowLocalProfile == false {
                profileChangedSinceLaunch = false
                return
            }
            let runningProfile: TenantProfile? = if TenantProfile.currentIsManagedByMDM {
                TenantProfile.currentSignedProfile.isDefault
                    ? nil : TenantProfile.currentSignedProfile
            } else {
                TenantProfile.current.isDefault ? nil : TenantProfile.current
            }
            profileChangedSinceLaunch = installedProfile != runningProfile
        } catch {
            installedProfile = nil
            profileNotice = ProfileNotice(
                title: "Configuration Could Not Be Read",
                message: error.localizedDescription)
        }
    }

    private func handleProfileSelection(_ result: Result<[URL], Error>) {
        guard canMutateLocalProfile else { return }
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            profileImports.stage(url)
        case .failure(let error):
            profileNotice = ProfileNotice(
                title: "Configuration Was Not Imported",
                message: error.localizedDescription)
        }
    }

    private func receiveProfileImport(_ id: UUID?) {
        guard let id, let delivery = profileImports.consume(id) else { return }
        switch delivery.result {
        case .verified(let pending):
            guard canMutateLocalProfile else {
                profileNotice = ProfileNotice(
                    title: "Configuration Is Managed",
                    message: "Your organization does not allow local configuration files on this Mac.")
                return
            }
            pendingProfileImport = pending
        case .failed(let message):
            profileNotice = ProfileNotice(
                title: "Configuration Was Not Imported",
                message: message)
        }
    }

    private func installProfile(_ pending: PendingProfileImport) {
        guard canMutateLocalProfile else { return }
        pendingProfileImport = nil
        do {
            installedProfile = try TenantProfile.installSignedProfile(pending.data)
            profileChangedSinceLaunch = true
            if !MechanicianRelaunch.afterCurrentProcessExits() {
                profileNotice = ProfileNotice(
                    title: "Configuration Installed",
                    message: "Relaunch was cancelled. Quit and reopen Mechanician when you are ready to activate the configuration.")
            }
        } catch {
            profileNotice = ProfileNotice(
                title: "Configuration Was Not Installed",
                message: error.localizedDescription)
        }
    }

    private func removeProfile() {
        guard canMutateLocalProfile else { return }
        do {
            try TenantProfile.removeInstalledProfile()
            installedProfile = nil
            profileChangedSinceLaunch = !TenantProfile.current.isDefault
            profileNotice = ProfileNotice(
                title: "Configuration Removed",
                message: profileChangedSinceLaunch
                    ? "Quit and reopen Mechanician to finish removing its managed providers and catalogs."
                    : "The managed configuration was removed.")
        } catch {
            profileNotice = ProfileNotice(
                title: "Configuration Was Not Removed",
                message: error.localizedDescription)
        }
    }

    private var anthropicCard: some View {
        providerCard(
            maker: .anthropic,
            subtitle: TenantProfile.current.enterpriseAccesses.contains(.claudeVertex)
                ? "Use Claude through Vertex AI, your Claude subscription, or a metered Anthropic API key."
                : "Use Claude through your Claude subscription or a metered Anthropic API key.",
            accesses: ModelAccess.selectableCases.filter { $0.maker == .anthropic })
    }

    private var openAICard: some View {
        providerCard(
            maker: .openAI,
            subtitle: "Use Codex through ChatGPT or connect a metered OpenAI API key.",
            accesses: ModelAccess.selectableCases.filter { $0.maker == .openAI })
    }

    private func providerCard(
        maker: ModelMaker,
        subtitle: String,
        accesses: [ModelAccess]
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(maker == .anthropic ? "Anthropic" : "OpenAI")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            ForEach(Array(accesses.enumerated()), id: \.element) { index, access in
                accountRow(access)
                if index < accesses.count - 1 {
                    Divider().padding(.vertical, 2)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardSurface(cornerRadius: 14, strokeOpacity: 0.45)
    }

    private func accountRow(_ access: ModelAccess) -> some View {
        let state = accounts.state(for: access)
        let operation = accounts.operation(for: access)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(access.displayName)
                    .font(.callout.weight(.semibold))
                if bridge.defaultConversationAccess == access {
                    Text("DEFAULT")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.nInfoText)
                }
                Spacer()
                Text(accessKind(access))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: accountIcon(state))
                    .font(.caption)
                    .foregroundStyle(accountColor(state))
                    .frame(width: 14)
                Text(accountStatus(state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = accounts.error(for: access) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.nErrorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 21)
            }
            if let operation {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(operation.progressLabel).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 21)
            } else {
                accountActions(access, state: state)
                    .padding(.leading, 21)
            }
            if editingAPI == access {
                apiKeyEditor(access)
                    .padding(.leading, 21)
            }
        }
        .padding(.vertical, 2)
    }

    private func accessKind(_ access: ModelAccess) -> String {
        switch access {
        case .claudeSubscription, .codexSubscription: return "SUBSCRIPTION"
        case .anthropicAPI, .openAIAPI: return "API · METERED"
        case .claudeVertex: return "VERTEX"
        case .claudeBedrock: return "BEDROCK"
        }
    }

    @ViewBuilder
    private func accountActions(_ access: ModelAccess, state: ProviderAccountStore.State) -> some View {
        let recoveringConversation = bridge.hasPendingProviderSetupRecovery
        let canUseForRecovery = bridge.canOfferPendingProviderSetupRecovery(for: access)
        HStack(spacing: 8) {
            if canUseForRecovery {
                Button(bridge.pendingProviderSetupRecoveryOriginAccess == access
                       ? "Resume Conversation"
                       : "Use for Conversation") {
                    bridge.useProviderForPendingSetupRecovery(access)
                }
                .buttonStyle(PillButtonStyle(kind: .brand))
                .fixedSize(horizontal: true, vertical: false)
            }
            if !recoveringConversation || !canUseForRecovery {
                switch access {
                case .claudeBedrock:
                    // Nothing to connect or disconnect: credentials come from the ordinary AWS
                    // chain, so the only honest action is to re-probe it.
                    Button(recoveringConversation ? "Check & Use" : "Check Again") {
                        if recoveringConversation {
                            bridge.useProviderForPendingSetupRecovery(access)
                        } else {
                            bridge.connectOrReconnectAccount(access)
                        }
                    }
                        .buttonStyle(PillButtonStyle(kind: .plain))
                        .fixedSize(horizontal: true, vertical: false)
                case .claudeSubscription, .codexSubscription, .claudeVertex:
                    switch state {
                    case .connected, .configured:
                        Button(recoveringConversation ? "Reconnect & Use" : "Reconnect") {
                            bridge.connectOrReconnectAccount(access)
                        }
                            .buttonStyle(PillButtonStyle(
                                kind: recoveringConversation ? .brand : .plain))
                            .fixedSize(horizontal: true, vertical: false)
                        if !recoveringConversation {
                            Button("Disconnect") {
                                bridge.disconnectAccount(access)
                            }
                            .buttonStyle(PillButtonStyle(kind: .neutral))
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    case .checking, .disconnected, .unavailable:
                        let action = accounts.subscriptionConnectionAction(for: access) ?? .connect
                        let label = accounts.subscriptionConnectionLabel(for: access)
                            ?? action.label
                        Button(recoveringConversation ? "\(label) & Use" : label) {
                            bridge.connectOrReconnectAccount(access)
                        }
                        .buttonStyle(PillButtonStyle(
                            kind: recoveringConversation ? .brand : .accent))
                        .fixedSize(horizontal: true, vertical: false)
                    case .managed:
                        Text("Change or unset this credential in the app launch environment, then relaunch Mechanician.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .anthropicAPI, .openAIAPI:
                    switch state {
                    case .connected, .configured:
                        Button(recoveringConversation ? "Replace Key & Use…" : "Replace Key…") {
                            beginAPIEdit(access)
                        }
                            .buttonStyle(PillButtonStyle(
                                kind: recoveringConversation ? .brand : .plain))
                            .fixedSize(horizontal: true, vertical: false)
                        if !recoveringConversation {
                            Button("Remove Key") {
                                clearAPIKeyDrafts()
                                bridge.removeAPIKey(for: access)
                            }
                            .buttonStyle(PillButtonStyle(kind: .neutral))
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    case .disconnected:
                        Button(recoveringConversation ? "Add Key & Use…" : "Add Key…") {
                            beginAPIEdit(access)
                        }
                            .buttonStyle(PillButtonStyle(
                                kind: recoveringConversation ? .brand : .accent))
                            .fixedSize(horizontal: true, vertical: false)
                    case .managed:
                        Text("Change this credential in the app launch environment, then relaunch Mechanician.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    case .checking, .unavailable:
                        EmptyView()
                    }
                }
            }
            if state.isAvailable && !recoveringConversation {
                let isDefault = bridge.defaultConversationAccess == access
                Button(isDefault ? "Default" : "Make Default") {
                    bridge.setDefaultConversationAccess(access)
                }
                .buttonStyle(PillButtonStyle(kind: isDefault ? .neutral : .plain))
                .fixedSize(horizontal: true, vertical: false)
                .disabled(isDefault)
                .help(isDefault
                      ? "New conversations use this connection"
                      : "Use this connection for new conversations")
            }
            Spacer()
        }
    }

    private func beginAPIEdit(_ access: ModelAccess) {
        accounts.clearError(for: access)
        clearAPIKeyDrafts()
        apiKeyInputs[access] = ""
        editingAPI = access
    }

    private func clearAPIKeyDrafts() {
        apiKeyInputs.removeAll()
        editingAPI = nil
    }

    private func apiKeyEditor(_ access: ModelAccess) -> some View {
        let binding = Binding(
            get: { apiKeyInputs[access] ?? "" },
            set: { apiKeyInputs[access] = $0 })
        return VStack(alignment: .leading, spacing: 7) {
            SecureField(access == .openAIAPI ? "sk-…" : "sk-ant-…", text: binding)
            if let keyNotice {
                Label(keyNotice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.nWarningText)
            }
            HStack {
                Spacer()
                Button("Cancel") { clearAPIKeyDrafts() }
                    .buttonStyle(PillButtonStyle(kind: .plain))
                Button(verifyingKey
                       ? "Checking…"
                       : bridge.hasPendingProviderSetupRecovery ? "Save & Use" : "Save") {
                    let raw = (apiKeyInputs[access] ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    verifyingKey = true
                    keyNotice = nil
                    Task {
                        // Ask the provider first: a rejected key never reaches the Keychain, so a
                        // bad paste is caught here instead of failing a turn later.
                        let outcome = await ProviderKeyValidation.check(raw, for: access)
                        verifyingKey = false
                        if case .unverified(let note) = outcome { keyNotice = note }
                        if bridge.saveAPIKey(raw, for: access, validation: outcome) {
                            clearAPIKeyDrafts()
                        }
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .disabled(verifyingKey || (apiKeyInputs[access] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func accountStatus(_ state: ProviderAccountStore.State) -> String {
        state.statusLabel
    }

    private func accountIcon(_ state: ProviderAccountStore.State) -> String {
        switch state {
        case .checking: return "arrow.triangle.2.circlepath"
        case .connected: return "checkmark.seal.fill"
        case .configured: return "key.fill"
        case .managed: return "key.horizontal.fill"
        case .disconnected: return "circle.dashed"
        case .unavailable: return "exclamationmark.triangle.fill"
        }
    }

    private func accountColor(_ state: ProviderAccountStore.State) -> Color {
        switch state {
        case .connected: return .nSuccessText
        case .configured: return .nInfoText
        case .managed(_, let usable): return usable == false ? .nWarningText : .nInfoText
        case .unavailable: return .nWarningText
        case .checking, .disconnected: return .secondary
        }
    }

}

/// Provider configuration is application-global but runtime operations need one live bridge to own
/// their daemon command. The active workspace supplies that bridge while every window observes the
/// same process-wide account store.
struct ProviderCenterWindow: View {
    @ObservedObject private var active = ActiveWorkspace.shared

    var body: some View {
        Group {
            if let bridge = active.bridge {
                ProviderCenterView(bridge: bridge)
            } else {
                ProgressView("Loading providers…")
                    .frame(minWidth: 720, idealWidth: 820, maxWidth: .infinity,
                           minHeight: 520, idealHeight: 660, maxHeight: .infinity)
                    .background(Color.nBg)
            }
        }
    }
}

private struct ProfileImportReview: View {
    let pending: PendingProfileImport
    let replacingExistingProfile: Bool
    let onCancel: () -> Void
    let onInstall: () -> Void

    var body: some View {
        let network = NetworkConfigurationDisclosure(profile: pending.profile)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(replacingExistingProfile ? "Replace Managed Configuration" : "Import Managed Configuration")
                        .font(.title3.weight(.semibold))
                    Text("The profile signature is valid.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                profileRow("File", pending.sourceName)
                profileRow("Organization", pending.profile.tenantId.capitalized)
                if let vertex = pending.profile.vertexConfig {
                    profileRow("Provider", "Claude on Vertex AI")
                    profileRow("Project", vertex.projectId)
                    profileRow("Region", vertex.region)
                }
                profileRow(
                    "Catalogs",
                    "\(pending.profile.extensions.managedSources.count) managed extension source\(pending.profile.extensions.managedSources.count == 1 ? "" : "s")")
                if let host = network.profileUpdateHost {
                    profileRow("Profile update host", host)
                    profileRow(
                        "Profile update checks",
                        network.profileUpdateMode == .manual
                            ? "Only when you check" : "Automatic")
                } else {
                    profileRow("Profile update host", "None declared")
                }
                profileRow(
                    "Managed source hosts",
                    network.managedSourceHosts.isEmpty
                        ? "None declared" : network.managedSourceHosts.joined(separator: ", "))
                profileRow(
                    "Managed MCP hosts",
                    network.managedMCPHosts.isEmpty
                        ? "None declared" : network.managedMCPHosts.joined(separator: ", "))
            }

            Text("Network locations above are hostnames only; URL paths, query values, credentials, and configuration secrets are not shown.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Profiles can enable audited provider adapters and catalogs, but cannot change the Mechanician app, icon, update channel, or execute arbitrary commands.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(PillButtonStyle(kind: .plain))
                    .keyboardShortcut(.cancelAction)
                Button(
                    replacingExistingProfile ? "Replace and Relaunch" : "Install and Relaunch",
                    action: onInstall)
                    .buttonStyle(PillButtonStyle(kind: .accent))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Color.nBg)
    }

    @ViewBuilder
    private func profileRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Permissions

private struct PermissionsSettings: View {
    @ObservedObject var bridge: AgentBridge
    @State private var permRefresh = 0

    var body: some View {
        Form {
            Section("Agent Permissions — \(bridge.currentModelAccess.displayName)") {
                Picker("Default mode", selection: $bridge.permissionMode) {
                    ForEach(PermissionPresentation.options(for: bridge.currentModelAccess)) { option in
                        Text(option.title).tag(option.mode)
                    }
                }
                Text(PermissionPresentation.option(
                    mode: bridge.permissionMode,
                    access: bridge.currentModelAccess).detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if bridge.permissionMode == "bypassPermissions" {
                    Label("Every tool, including shell commands and file writes, runs without asking. Use only in folders you trust.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Color.nWarningText)
                }
                Text("Remembered approvals below apply only to \(bridge.currentModelAccess.displayName) in \(workspaceName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if bridge.allowedTools.isEmpty {
                    Text("No tools are always allowed for this provider and workspace yet.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(bridge.allowedTools, id: \.self) { tool in
                        HStack {
                            Text(tool)
                            Spacer()
                            Button(role: .destructive) { bridge.removeAllowedTool(tool) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Stop always-allowing \(tool)")
                            .accessibilityLabel("Stop always-allowing \(tool)")
                        }
                    }
                }
            }

            Section("Computer Use") {
                let _ = permRefresh // re-evaluate the checks when re-checked
                permRow("Screen Recording", granted: CGPreflightScreenCaptureAccess(),
                        privacyKey: "Privacy_ScreenCapture")
                permRow("Accessibility", granted: AXIsProcessTrusted(),
                        privacyKey: "Privacy_Accessibility")
                HStack {
                    Text("Needed for the agent to see the screen and control the mouse/keyboard. Run windowed (not full-screen) so target apps stay visible.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Re-check") { permRefresh += 1 }.buttonStyle(PillButtonStyle(kind: .plain))
                }
            }
        }
        .settingsPane()
    }

    private var workspaceName: String {
        let path = bridge.cwd.isEmpty ? NSHomeDirectory() : bridge.cwd
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func permRow(_ name: String, granted: Bool, privacyKey: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: granted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.nSuccessText : Color.nWarningText)
            Text(name)
            Spacer()
            if granted {
                Text("Granted").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(privacyKey)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .neutral))
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage("colorSchemeOverride") private var colorSchemeOverride = "system"
    @AppStorage("uiTypeStep") private var typeStep = 0

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $colorSchemeOverride) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .onChange(of: colorSchemeOverride) { _, scheme in applyAppAppearance(scheme) }
                Text("Follows your Mac's Light/Dark setting unless overridden here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Text Size") {
                Stepper(value: $typeStep, in: -3...6) {
                    Text("Conversation & panels: \(Int(uiScale(typeStep) * 100))%")
                }
                Text("Also adjustable anytime with ⌘+ / ⌘- / ⌘0.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsPane()
    }
}

// MARK: - Updates

private struct UpdatesSettings: View {
    @EnvironmentObject private var updater: UpdaterManager
    @State private var autoCheck = false

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return BuildVersionLabel.make(version: v, build: b)
    }

    private var channelSelection: Binding<UpdateChannel> {
        Binding(
            get: { updater.updateChannel },
            set: { updater.setUpdateChannel($0) })
    }

    private var backgroundContactSummary: String {
        if updater.updatesAreManagedByMDM {
            return String(localized: "Disabled — app updates are managed by your organization")
        }
        if updater.needsUpdateNetworkChoice {
            return String(localized: "Waiting for your choice")
        }
        let mode = updater.automaticallyChecksForUpdates
            ? String(localized: "Automatic") : String(localized: "Manual Check only")
        return updater.automaticUpdateChecksAreManaged
            ? String(localized: "\(mode) — managed by your organization") : mode
    }

    private func chooseNetworkMode(_ choice: AppUpdateNetworkChoice) {
        updater.setUpdateNetworkChoice(choice)
        autoCheck = choice.automaticallyChecks
    }

    var body: some View {
        Form {
            Section("Software Updates") {
                LabeledContent("Current version", value: version)
                Picker("Update channel", selection: channelSelection) {
                    Text("Stable (Recommended)").tag(UpdateChannel.stable)
                    Text("Daily Builds").tag(UpdateChannel.daily)
                }
                .disabled(!updater.canChangeUpdateChannel)
                switch updater.updateChannel {
                case .stable:
                    Text("Recommended. Receive stable releases after they pass release validation.")
                        .font(.caption).foregroundStyle(.secondary)
                case .daily:
                    Text("Receive daily builds as well as stable releases. Daily builds may be less reliable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Stable does not downgrade Mechanician; future update checks wait for a newer stable release.")
                    .font(.caption).foregroundStyle(.secondary)
                if updater.needsUpdateNetworkChoice {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose whether Mechanician may contact its signed app-update host in the background. Manual Check makes that connection only when you choose Check Now.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Manual Check Only (Recommended)") {
                                chooseNetworkMode(.manual)
                            }
                            .buttonStyle(PillButtonStyle(kind: .accent))
                            Button("Automatic Update Checks") {
                                chooseNetworkMode(.automatic)
                            }
                            .buttonStyle(PillButtonStyle(kind: .plain))
                        }
                    }
                } else {
                    Toggle("Automatically check for updates", isOn: $autoCheck)
                        .onChange(of: autoCheck) { _, enabled in
                            updater.automaticallyChecksForUpdates = enabled
                        }
                        .disabled(!updater.canChangeAutomaticUpdateChecks)
                }
                HStack {
                    Spacer()
                    Button("Check Now…") { updater.checkForUpdates() }
                        .buttonStyle(PillButtonStyle(kind: .neutral))
                        .disabled(!updater.canCheckForUpdates)
                }
            }
            Section("Network & Privacy") {
                LabeledContent(
                    "App update host",
                    value: updater.updateFeedHost ?? String(localized: "Not configured"))
                LabeledContent("Background contact", value: backgroundContactSummary)
                Text("Update checks request signed release metadata only. Mechanician does not send conversations, enterprise configuration, or a macOS system profile to the update host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Text("Updates are signed and verified before installing.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Mechanician is made by Magic & Lasers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsPane()
        .onAppear { autoCheck = updater.automaticallyChecksForUpdates }
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    @ObservedObject var bridge: AgentBridge
    @ObservedObject private var conversationStore = ConversationStore.shared
    @ObservedObject private var launchMetrics = LaunchMetrics.shared
    @AppStorage("use1MContext") private var use1MContext = true
    @State private var diagnosticsExporting = false
    @State private var diagnosticsExportMessage: String?
    @State private var showingRecoveredConversations = false

    private var sqliteHydrationSummary: String {
        let metrics = conversationStore.sqliteReadMetrics
        var value = "\(metrics.sqliteReads) SQLite"
        if let milliseconds = metrics.lastSQLiteMilliseconds {
            value += String(format: " · last %.0f ms", milliseconds)
        }
        return value
    }

    private var sqliteLaunchInventorySummary: String {
        if conversationStore.usedSQLiteLaunchInventory {
            return "SQLite exact inventory"
        }
        return "Legacy recovery"
    }

    private var storageAuthoritySummary: String {
        switch StorageAuthorityBootstrap.current.disposition {
        case .sqlite(_, let database):
            "Active · schema \(database.schemaVersion) · sequence \(database.committedSequence)"
        case .legacyUnmarked: "Unavailable · legacy library requires 0.26.21"
        case .legacyGeneration: "Unavailable · retired rollback generation"
        case .blocked: "Unavailable · open Storage Recovery"
        }
    }

    private var storageProductReadMode: String {
        conversationStore.usesSQLiteAuthority ? "SQLite authority" : "Unavailable"
    }

    var body: some View {
        Form {
            Section("Storage Status") {
                LabeledContent("Current authority") {
                    Text(storageProductReadMode)
                        .fontWeight(.semibold)
                }
                LabeledContent(
                    "Authority recognition",
                    value: StorageAuthorityProtocol.recognitionID)
                LabeledContent(
                    "Root marker",
                    value: StorageAuthorityBootstrap.current.marker.title)
                LabeledContent(
                    "Process writer lease",
                    value: StorageAuthorityBootstrap.ownsProcessLease ? "Held" : "Not held")
                LabeledContent(
                    "Authority state",
                    value: storageAuthoritySummary)
                LabeledContent("Launch inventory", value: sqliteLaunchInventorySummary)
                LabeledContent("Conversation hydration", value: sqliteHydrationSummary)
                LabeledContent(
                    "This launch",
                    value: LaunchTimingPresentation.summary(launchMetrics.lastLaunch))
                if let breakdown = LaunchTimingPresentation.breakdown(launchMetrics.lastLaunch) {
                    LabeledContent("Launch breakdown", value: breakdown)
                }
                if let median = LaunchTimingPresentation.median(launchMetrics.history) {
                    LabeledContent("Median launch", value: median)
                }
                HStack {
                    Spacer()
                    Button("Review Recovered Conversations…") {
                        showingRecoveredConversations = true
                    }
                    .buttonStyle(PillButtonStyle(kind: .neutral))
                }
            }
            Section("Model") {
                Toggle("1M token context window", isOn: Binding(
                    get: { use1MContext },
                    set: { _ = bridge.setOneMillionContextEnabled($0) }
                ))
                if let message = bridge.oneMillionContextChangeMessage {
                    Text(verbatim: message)
                        .font(.caption)
                        .foregroundStyle(Color.nWarningText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("A larger context holds more of your work at once for Claude subscription and Anthropic API models. Uses more tokens. Turn it off to reduce cost.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("Provider Capabilities") {
                ProviderCapabilityDiagnosticsView(bridge: bridge)
            }
            Section("Codex Diagnostics") {
                HStack {
                    Button("Export Redacted Lifecycle Diagnostics…") {
                        exportCodexDiagnostics()
                    }
                    .buttonStyle(PillButtonStyle(kind: .neutral))
                    .disabled(diagnosticsExporting || !bridge.canExportCodexLifecycleDiagnostics)
                    if diagnosticsExporting {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(diagnosticsExportMessage ?? (bridge.canExportCodexLifecycleDiagnostics
                    ? "Exports a bounded lifecycle trace without prompts, responses, tool payloads, environment values, or credentials."
                    : "Open or connect a Codex conversation to export its current runtime trace."))
                    .font(.caption)
                    .foregroundStyle(diagnosticsExportMessage == nil ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if BuildProvenance.current?.dogfood == true {
                Section("Conversation Memory — Dogfood") {
                    LabeledContent(
                        "Current mode",
                        value: conversationStore.activeResidencyMode == .boundedAfterRecovery
                            ? "Bounded cache" : "Eager")
                    LabeledContent(
                        "Full records in memory",
                        value: "\(conversationStore.residentConversationIDs.count) of \(conversationStore.summaries.count)")
                    LabeledContent(
                        "Resident source bytes",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(conversationStore.residentSourceBytes),
                            countStyle: .file))
                    Button(
                        conversationStore.activeResidencyMode == .boundedAfterRecovery
                            ? "Use Eager Loading After Relaunch"
                            : "Use Bounded Cache After Relaunch"
                    ) {
                        let next: ConversationResidencyMode =
                            conversationStore.activeResidencyMode == .boundedAfterRecovery
                                ? .eager : .boundedAfterRecovery
                        UserDefaults.standard.set(
                            next.rawValue, forKey: "conversation.residencyMode")
                    }
                    .buttonStyle(PillButtonStyle(kind: .neutral))
                    Text("The switch changes only how many SQLite-backed Conversations remain decoded in memory. library.db remains authoritative in both modes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("Layout") {
                Button("Reset Window & Panel Sizes") {
                    LayoutPreferenceReset.reset()
                }
                .buttonStyle(PillButtonStyle(kind: .neutral))
                Text("Restores the default sidebar, inspector, terminal, and text sizes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsPane()
        .sheet(isPresented: $showingRecoveredConversations) {
            RecoveredConversationRecoveryView()
        }
    }

    private func exportCodexDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "Export Redacted Codex Diagnostics"
        panel.prompt = "Export"
        panel.nameFieldStringValue = CodexDiagnosticsExport.defaultFilename
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            diagnosticsExporting = true
            diagnosticsExportMessage = nil
            bridge.exportCodexLifecycleDiagnostics(to: destination) { result in
                diagnosticsExporting = false
                switch result {
                case .success:
                    diagnosticsExportMessage = "Exported \(destination.lastPathComponent)."
                case .failure(let error):
                    NSLog("[diagnostics] export failed: %@", error.localizedDescription)
                    diagnosticsExportMessage = "The diagnostics file could not be written. Check "
                        + "that the destination still exists and that you can write to it."
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
