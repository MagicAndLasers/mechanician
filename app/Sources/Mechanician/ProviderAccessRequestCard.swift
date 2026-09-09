import SwiftUI

/// App-owned authentication/resume UI. Provider model output can request only a provider family;
/// this card is the sole place a user chooses subscription versus API-key access.
struct ProviderAccessRequestCard: View {
    @ObservedObject var bridge: AgentBridge
    let request: ProviderAccessRequest
    @ObservedObject private var accounts = ProviderAccountStore.shared
    @ObservedObject private var catalogs = ModelCatalogStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var showsPreservedTasks = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .foregroundStyle(Color.nInfoText)
                Text("Connect to \(request.providerName)")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if selectedOperation == nil {
                    Button("Cancel request") {
                        bridge.cancelProviderAccessRequest(request.id)
                    }
                    .buttonStyle(PillButtonStyle(kind: .plain))
                    .help("Cancel this work request without disconnecting any account")
                } else {
                    Text("Connection in progress")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text(request.reason)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !request.resumePrompts.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    DisclosureGroup(isExpanded: $showsPreservedTasks) {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(request.resumePrompts.enumerated()), id: \.offset) { index, task in
                                VStack(alignment: .leading, spacing: 2) {
                                    if request.resumePrompts.count > 1 {
                                        Text("TASK \(index + 1)")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text(task)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.top, 5)
                    } label: {
                        Text(request.resumePrompts.count == 1 ? "PRESERVED TASK" : "PRESERVED TASKS")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text("Everything shown here will be sent to the connection you choose.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.nElevated.opacity(0.7)))
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { routeButtons }
                VStack(alignment: .leading, spacing: 8) { routeButtons }
            }

            if let operation = selectedOperation {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(operation.progressLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let access = request.selectedAccess,
                      let error = accounts.error(for: access), !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.nErrorText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let access = request.selectedAccess,
                      accounts.state(for: access).isAvailable {
                catalogPreparationStatus(access)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.nSurface))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.nAccent.opacity(0.38), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.providerName) access request")
    }

    private var selectedOperation: ProviderAccountStore.Operation? {
        request.selectedAccess.flatMap { accounts.operation(for: $0) }
    }

    @ViewBuilder
    private func catalogPreparationStatus(_ access: ModelAccess) -> some View {
        let snapshot = catalogs.snapshot(for: access, scope: bridge.catalogScope(for: access))
        switch snapshot.phase {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing \(access.displayName)…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.nErrorText)
                .fixedSize(horizontal: false, vertical: true)
        case .ready:
            if snapshot.entries.isEmpty {
                Text("This connection did not report a selectable model.")
                    .font(.caption)
                    .foregroundStyle(Color.nErrorText)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Preparing the preserved task…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var routeButtons: some View {
        ForEach(request.eligibleAccesses, id: \.self) { access in
            routeButton(access)
        }
    }

    @ViewBuilder
    private func routeButton(_ access: ModelAccess) -> some View {
        let state = accounts.state(for: access)
        let busy = accounts.operation(for: access) != nil
        switch state {
        case .connected, .configured:
            Button {
                bridge.chooseProviderAccessRequest(request.id, access: access)
            } label: {
                Label("Continue with \(access.displayName)", systemImage: "arrow.right")
                    .lineLimit(1)
            }
            .buttonStyle(PillButtonStyle(kind: .accent))
            .disabled(busy)
        case .managed(_, let usable):
            if usable == true {
                Button {
                    bridge.chooseProviderAccessRequest(request.id, access: access)
                } label: {
                    Label("Continue with \(access.displayName)", systemImage: "arrow.right")
                        .lineLimit(1)
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .disabled(busy)
            } else {
                Button("Open Providers…") { openAccountSettings(selecting: access) }
                    .buttonStyle(PillButtonStyle(kind: .plain))
                    .disabled(busy)
            }
        case .disconnected:
            switch access {
            case .claudeSubscription, .codexSubscription, .claudeVertex, .claudeBedrock:
                Button {
                    bridge.chooseProviderAccessRequest(request.id, access: access)
                    bridge.connectOrReconnectAccount(access)
                } label: {
                    Label(
                        accounts.subscriptionConnectionLabel(
                            for: access,
                            includingProviderName: true) ?? "Connect \(access.displayName)",
                        systemImage: "person.crop.circle.badge.plus")
                        .lineLimit(1)
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .disabled(busy)
            case .anthropicAPI, .openAIAPI:
                Button(access == .anthropicAPI ? "Add Anthropic API key…" : "Add OpenAI API key…") {
                    openAccountSettings(selecting: access)
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .disabled(busy)
            }
        case .checking, .unavailable:
            if access.usesInteractiveAccountFlow {
                Button {
                    bridge.chooseProviderAccessRequest(request.id, access: access)
                    bridge.connectOrReconnectAccount(access)
                } label: {
                    Label(
                        accounts.subscriptionConnectionLabel(
                            for: access,
                            includingProviderName: true) ?? "Connect \(access.displayName)",
                        systemImage: "person.crop.circle.badge.plus")
                        .lineLimit(1)
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .disabled(busy)
            } else {
                Button("Open Providers…") { openAccountSettings(selecting: access) }
                    .buttonStyle(PillButtonStyle(kind: .plain))
                    .disabled(busy)
            }
        }
    }

    private func openAccountSettings(selecting access: ModelAccess) {
        bridge.chooseProviderAccessRequest(request.id, access: access)
        showProviders(using: openWindow)
    }
}
