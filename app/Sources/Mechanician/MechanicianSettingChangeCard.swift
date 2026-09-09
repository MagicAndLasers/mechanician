import SwiftUI

/// The card that asks before an agent changes an app setting.
///
/// Every word on it is composed by the app from its own state. The agent named an operation and a
/// target and supplied no copy, so what the person reads here cannot be a provider's description of
/// its own request. Nothing has changed at the moment this appears; the change happens when the
/// person presses the confirming button and not before.
struct MechanicianSettingChangeCard: View {
    @ObservedObject var bridge: AgentBridge
    let request: MechanicianSettingChangeRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(Color.nInfoText)
                    .accessibilityHidden(true)
                Text(verbatim: request.title)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
            }

            Text(verbatim: request.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Not now") { bridge.declinePendingSettingChange() }
                    .buttonStyle(PillButtonStyle(kind: .plain))
                    .help("Leave the setting as it is")
                    .accessibilityLabel("Leave the setting as it is")
                Button(request.confirmLabel) { bridge.approvePendingSettingChange() }
                    .buttonStyle(PillButtonStyle(kind: .accent))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(request.confirmLabel)
            }
        }
        .padding(12)
        .cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Confirm an app setting change")
    }
}
