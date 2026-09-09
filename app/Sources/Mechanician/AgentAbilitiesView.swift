import AppKit
import SwiftUI

/// Route-bound answer to “what can this agent do here?” The outer view follows the active window;
/// the inner view observes that bridge's own capability authority, preventing another window or
/// background conversation from painting its tools into this one.
struct AgentAbilitiesView: View {
    @ObservedObject private var active = ActiveWorkspace.shared

    var body: some View {
        Group {
            if let bridge = active.bridge {
                AgentAbilitiesInventoryView(bridge: bridge)
            } else {
                ScrollView {
                    Text(String(localized: "Open a conversation to see its capabilities."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.nBg)
            }
        }
    }
}

private struct AgentAbilitiesInventoryView: View {
    @ObservedObject var bridge: AgentBridge
    @ObservedObject private var catalog: AgentToolCatalog
    @ObservedObject private var capabilities = CapabilityStore.shared

    init(bridge: AgentBridge) {
        self.bridge = bridge
        _catalog = ObservedObject(wrappedValue: bridge.agentToolCatalog)
    }

    private var snapshot: AgentToolSurfaceSnapshot? {
        bridge.currentAgentToolSurfaceSnapshot
    }

    private var profile: ProviderToolProfile {
        bridge.currentAgentToolProfile ?? .standard
    }

    private var presentation: AgentAbilityPresentation {
        AgentAbilityPresentation.reduce(.init(
            hasConversation: bridge.currentConversation != nil,
            isOpeningConversation: bridge.pendingSelectionID != nil
                || ConversationOpeningPresentation.shouldShow(
                    storeIsReady: bridge.store.isReady,
                    currentID: bridge.currentID,
                    openingConversationID: bridge.openingConversationID,
                    initialViewResolutionPending: bridge.initialViewResolutionPending),
            needsProviderSetup: bridge.needsProviderSetup,
            providerDisplayName: bridge.currentModelAccess.displayName,
            snapshot: snapshot))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if presentation.showsResolvedRoute {
                    boundaryRow(presentation)
                    routeHeader(presentation)
                }
                surfaceSection(presentation)
                savedCapabilitiesSection(presentation)
            }
            .padding(16)
        }
        .background(Color.nBg)
    }

    private func boundaryRow(_ presentation: AgentAbilityPresentation) -> some View {
        let content: (symbol: String, title: String, detail: String)
        switch profile {
        case .helpExpert:
            content = (
                "questionmark.circle",
                String(localized: "Intentionally Help-only"),
                String(localized: "This conversation can search signed Mechanician Help and start reviewed in-app guidance. It cannot use files, shell, web, extensions, arbitrary app control, or Mac automation."))
        case .standard:
            if presentation.readySnapshot?.coverage == .mechanicianSupplied {
                content = (
                    "checkmark.shield",
                    String(localized: "Mechanician tools verified for this conversation"),
                    String(localized: "Codex does not expose a complete native-tool inventory. The list below is complete for Mechanician-supplied tools; Codex may also have provider-native coding abilities."))
            } else if presentation.readySnapshot != nil {
                content = (
                    "checkmark.shield",
                    String(localized: "Capabilities verified for this conversation"),
                    String(localized: "This inventory comes from the exact provider turn and configuration shown below. Individual actions may still require approval or system permission."))
            } else {
                content = (
                    "shield",
                    String(localized: "Capabilities are conversation-specific"),
                    String(localized: "Mechanician will not reuse abilities reported by another conversation, provider route, or window."))
            }
        }

        return HStack(alignment: .top, spacing: 11) {
            Image(systemName: content.symbol)
                .font(.system(size: 17))
                .foregroundStyle(Color.nInfoText)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title).font(.system(size: 14, weight: .semibold))
                Text(content.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.nAccent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.nAccent.opacity(0.25)))
    }

    private func routeHeader(_ presentation: AgentAbilityPresentation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "Current route"))
                .font(.system(size: 14, weight: .semibold))
            Text(routeSubtitle(presentation))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Current capability route"))
        .accessibilityValue(routeSubtitle(presentation))
    }

    @ViewBuilder
    private func surfaceSection(_ presentation: AgentAbilityPresentation) -> some View {
        switch presentation.state {
        case .openingConversation:
            stateRow(
                symbol: "arrow.triangle.2.circlepath",
                text: String(localized: "Opening the selected conversation…"),
                progress: true)
        case .noConversation:
            stateRow(
                symbol: "bubble.left",
                text: String(localized: "Open a conversation to see its capabilities."))
        case .setupRequired(let providerDisplayName):
            stateRow(
                symbol: "person.crop.circle.badge.exclamationmark",
                text: String(localized: "Set up \(providerDisplayName) to verify this conversation's capabilities."))
        case .discovering(let providerDisplayName):
            stateRow(
                symbol: "arrow.triangle.2.circlepath",
                text: String(localized: "Checking what \(providerDisplayName) reports for this conversation…"),
                progress: true)
        case .readyEmpty:
            stateRow(
                symbol: "checkmark.circle",
                text: String(localized: "The provider reported no callable tools in this route."))
        case .ready(let snapshot):
            builtInSection(snapshot)
        case .unavailable(let message):
            stateRow(symbol: "exclamationmark.triangle", text: message)
        case .unverified:
            stateRow(
                symbol: "questionmark.circle",
                text: String(localized: "Capabilities have not been verified for this exact conversation yet. Send a message to check them."))
        }
    }

    private func builtInSection(_ snapshot: AgentToolSurfaceSnapshot) -> some View {
        let groups = AgentToolCatalog.groups(for: snapshot)
        let ungrouped = AgentToolCatalog.ungroupedTools(in: snapshot)
        return VStack(alignment: .leading, spacing: 7) {
            sectionHeader(
                String(localized: "Reported abilities"),
                subtitle: surfaceSubtitle(snapshot))
            ForEach(groups) { group in
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: group.symbol)
                        .foregroundStyle(Color.nInfoText)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.title).fontWeight(.medium)
                        Text(group.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text("\(group.tools.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help(group.tools.joined(separator: ", "))
                        .accessibilityLabel(
                            String(localized: "\(group.tools.count) reported tools: \(group.tools.joined(separator: ", "))"))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.nSurface))
            }
            if !ungrouped.isEmpty {
                Text(String(localized: "Also reported: \(ungrouped.joined(separator: ", "))"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func savedCapabilitiesSection(
        _ presentation: AgentAbilityPresentation
    ) -> some View {
        if profile == .standard,
           let snapshot = presentation.readySnapshot,
           AgentToolCatalog.contains("ListCapabilities", in: snapshot)
                || AgentToolCatalog.contains("RunCapability", in: snapshot) {
            let reportedRun = AgentToolCatalog.contains("RunCapability", in: snapshot)
            let canRun = AgentAbilityPresentation.canRequestSavedCapabilityRun(
                reportedRun: reportedRun,
                from: snapshot)
            let isPlan = snapshot.route.permissionMode == "plan"
            let saved = capabilities.capabilities.filter(\.enabled)
            if !saved.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    sectionHeader(
                        String(localized: "Saved on this Mac"),
                        subtitle: canRun
                            ? String(localized: "This route can inspect and request one of these saved automations. Confirmation, app approval, or macOS permission may still be required.")
                            : isPlan && reportedRun
                                ? String(localized: "This Plan route can inspect these saved automations. Switch out of Plan before asking to run one.")
                                : String(localized: "This route can inspect these saved automations, but cannot run one here."))
                    ForEach(saved) { capability in
                        HStack(spacing: 10) {
                            Image(systemName: "wand.and.stars")
                                .foregroundStyle(Color.nInfoText)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(capability.title).fontWeight(.medium)
                                Text(capability.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if !canRun {
                                Text(String(localized: "Inspect only"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if capability.verification.state == "failed" {
                                Text(String(localized: "Not working"))
                                    .font(.caption2)
                                    .foregroundStyle(Color.nErrorText)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.nSurface))
                    }
                }
            }
        }
    }

    private func routeSubtitle(_ presentation: AgentAbilityPresentation) -> String {
        let conversation = bridge.currentConversation?.title ?? String(localized: "No conversation")
        let workspace = bridge.workspaceDisplayTitle
        let routeSnapshot = snapshot
        let access = routeSnapshot?.route.selection.access
            ?? bridge.currentModelAccess
        let permissionMode = routeSnapshot.map(
            AgentAbilityPresentation.permissionModeTitle(for:))
            ?? String(localized: "Mode not verified")
        let profileLabel: String
        switch profile {
        case .standard: profileLabel = String(localized: "Standard")
        case .helpExpert: profileLabel = String(localized: "Help-only")
        }
        return "\(conversation) · \(workspace) · \(access.displayName) · \(permissionMode) · \(profileLabel)"
    }

    private func surfaceSubtitle(_ snapshot: AgentToolSurfaceSnapshot) -> String {
        let timing = snapshot.isActiveEvidence
            ? String(localized: "Active turn")
            : String(localized: "Last observed turn")
        switch snapshot.coverage {
        case .mechanicianSupplied:
            return String(localized: "\(timing). Complete for Mechanician-supplied tools; provider-native Codex tools are not exhaustively listed.")
        case .complete:
            return String(localized: "\(timing). Complete provider report for this exact route.")
        case nil:
            return String(localized: "\(timing). Waiting for coverage details.")
        }
    }

    private func stateRow(symbol: String, text: String, progress: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 9) {
            if progress {
                ProgressView().controlSize(.small).frame(width: 18)
            } else {
                Image(systemName: symbol).foregroundStyle(Color.nInfoText).frame(width: 18)
            }
            Text(verbatim: text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.nSurface))
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}
