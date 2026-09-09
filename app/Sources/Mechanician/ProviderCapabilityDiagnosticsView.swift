import SwiftUI

/// Read-only visibility into the provider evidence owned by the currently selected
/// account/model/workspace. Product controls must continue to gate behavior independently: this
/// view explains what the provider reports and what the current Mechanician adapter implements.
struct ProviderCapabilityDiagnosticsView: View {
    @ObservedObject var bridge: AgentBridge
    @ObservedObject private var store = ProviderCapabilityStore.shared

    private var selection: ModelSelection { bridge.selectedModelSelection }
    private var key: ProviderCapabilityKey { bridge.currentProviderCapabilityKey() }
    private var snapshot: ProviderCapabilitySnapshot { store.snapshot(for: key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.access.displayName)
                        .font(.callout.weight(.semibold))
                    Text(bridge.modelDisplayName(for: selection))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 12)

                Button {
                    bridge.prepareProviderCapabilities(force: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle(kind: .plain))
                .disabled(snapshot.phase == .loading)
                .accessibilityHint("Refreshes capability evidence for the selected account, model, and workspace")
            }

            Label {
                Text("Diagnostics only. This evidence does not grant tools, change sandboxing, or control permission decisions.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(Color.nInfoText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            capabilityContent

            if let updatedAt = snapshot.updatedAt {
                HStack(spacing: 5) {
                    Text("Updated \(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    if let adapterRevision = snapshot.adapterRevision {
                        Text("·")
                        Text("Adapter \(adapterRevision)")
                            .textSelection(.enabled)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .onAppear {
            bridge.prepareProviderCapabilities()
        }
        .onChange(of: key) { _, _ in
            bridge.prepareProviderCapabilities()
        }
    }

    @ViewBuilder
    private var capabilityContent: some View {
        switch snapshot.phase {
        case .idle:
            diagnosticMessage(
                systemImage: "waveform.path.ecg",
                title: "No capability evidence loaded",
                detail: "Refresh after this account and model are available.")
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading provider capabilities…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .cardSurface(cornerRadius: 10)
        case .failed(let message):
            diagnosticMessage(
                systemImage: "exclamationmark.triangle.fill",
                title: "Capability evidence unavailable",
                detail: message,
                color: .orange)
        case .ready:
            if snapshot.capabilities.isEmpty {
                diagnosticMessage(
                    systemImage: "checkmark.circle",
                    title: "No capabilities reported",
                    detail: "The provider returned an authoritative empty result for this account, model, and workspace.")
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.capabilities) { capability in
                        capabilityRow(capability)
                    }
                }
            }
        }
    }

    private func diagnosticMessage(
        systemImage: String,
        title: String,
        detail: String,
        color: Color = .secondary
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardSurface(cornerRadius: 10)
    }

    private func capabilityRow(_ capability: ProviderCapability) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(capabilityTitle(capability.id))
                    .font(.callout.weight(.semibold))
                symmetryBadge(capability.symmetry)
                Spacer(minLength: 8)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    diagnosticLabel("Provider")
                    statusValue(
                        providerAvailabilityTitle(capability.providerAvailability),
                        color: providerAvailabilityColor(capability.providerAvailability))
                }
                GridRow {
                    diagnosticLabel("Mechanician")
                    statusValue(
                        mechanicianSupportTitle(capability.mechanicianSupport),
                        color: mechanicianSupportColor(capability.mechanicianSupport))
                }
                GridRow(alignment: .top) {
                    diagnosticLabel("Evidence")
                    Text(evidenceDescription(capability.evidence))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !capability.constraints.isEmpty {
                    GridRow(alignment: .top) {
                        diagnosticLabel("Constraints")
                        Text(metadataDescription(capability.constraints))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                if !capability.disclosures.isEmpty {
                    GridRow(alignment: .top) {
                        diagnosticLabel("Disclosure")
                        Text(metadataDescription(capability.disclosures))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 10)
        .accessibilityElement(children: .combine)
    }

    private func diagnosticLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.tertiary)
            .frame(width: 78, alignment: .leading)
    }

    private func statusValue(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption.weight(.medium))
        }
    }

    private func symmetryBadge(_ symmetry: ProviderCapabilitySymmetry) -> some View {
        Text(symmetryTitle(symmetry).uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.nElevated.opacity(0.8)))
    }

    private func capabilityTitle(_ identifier: String) -> String {
        switch identifier {
        case "reasoning_effort": return "Reasoning effort"
        case "ultra": return "Ultra"
        case "claude_ultracode": return "Claude Ultra"
        case "adaptive_thinking": return "Adaptive thinking"
        case "fast_mode": return "Fast mode"
        case "auto_mode": return "Automatic mode"
        case "prompt_suggestions": return "Follow-up prompt suggestions"
        case "turn_guidance": return "Turn guidance"
        case "native_review": return "Native code review"
        case "advisor": return "Opus 5 advisor"
        case "safety_refusal_fallback": return "Automatic safety fallback"
        case "refusal_supersession": return "Refusal supersession handling"
        default:
            let value = identifier.hasPrefix("provider.")
                ? String(identifier.dropFirst("provider.".count))
                : identifier
            return value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func providerAvailabilityTitle(_ availability: ProviderCapabilityAvailability) -> String {
        switch availability {
        case .available: return "Available"
        case .unavailable: return "Unavailable"
        case .experimental: return "Experimental"
        case .deprecated: return "Deprecated"
        case .unknown: return "Not reported"
        }
    }

    private func providerAvailabilityColor(_ availability: ProviderCapabilityAvailability) -> Color {
        switch availability {
        case .available: return .green
        case .unavailable: return .red
        case .experimental, .deprecated: return .orange
        case .unknown: return .secondary
        }
    }

    private func mechanicianSupportTitle(_ support: MechanicianCapabilitySupport) -> String {
        switch support {
        case .implemented: return "Supported"
        case .unimplemented: return "Not implemented"
        case .disabled: return "Disabled"
        }
    }

    private func mechanicianSupportColor(_ support: MechanicianCapabilitySupport) -> Color {
        switch support {
        case .implemented: return .green
        case .unimplemented: return .orange
        case .disabled: return .secondary
        }
    }

    private func symmetryTitle(_ symmetry: ProviderCapabilitySymmetry) -> String {
        switch symmetry {
        case .symmetric: return "Shared"
        case .partial: return "Related"
        case .providerSpecific: return "Provider-specific"
        case .unclassified: return "Unclassified"
        }
    }

    private func evidenceDescription(_ evidence: ProviderCapabilityEvidence) -> String {
        let source: String
        switch evidence.source {
        case .providerResponse: source = "Provider response"
        case .providerContract: source = "Provider contract"
        case .adapterStatic: source = "Mechanician adapter"
        }
        let revision = evidence.revision.map { " · \($0)" } ?? ""
        return "\(source) · \(evidence.operation)\(revision)"
    }

    private func metadataDescription(_ metadata: [String: String]) -> String {
        metadata.keys.sorted().map { key in
            "\(key.replacingOccurrences(of: "_", with: " ")): \(metadata[key] ?? "")"
        }.joined(separator: " · ")
    }
}
