import SwiftUI

/// Conversation-scoped recovery for an unavailable provider lane.
///
/// This is deliberately an account card rather than a warning wash: the user is choosing how to
/// resume work, not acknowledging a destructive condition. The broad field uses only the cool side
/// of the mark so Light Mode stays clean; the narrow leading rail carries all six logo rays.
struct ProviderSetupBanner: View {
    let access: ModelAccess
    let requiresReconnect: Bool
    let progressLabel: String?
    let error: String?
    let actionLabel: String?
    let action: (() -> Void)?

    private let cornerRadius: CGFloat = 10

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                identity
                copy
                Spacer(minLength: 10)
                actionArea
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    identity
                    copy
                }
                actionArea
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(.caption)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .providerRecoverySurface(cornerRadius: cornerRadius)
        .accessibilityElement(children: .contain)
    }

    private var identity: some View {
        Image(systemName: "person.crop.circle.badge.plus")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.nPurpleText)
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }

    private var copy: some View {
        let presentation = ProviderSetupBannerPresentation(
            access: access,
            requiresReconnect: requiresReconnect)
        return VStack(alignment: .leading, spacing: 2) {
            Text(presentation.title)
                .fontWeight(.semibold)
                .foregroundStyle(Color.nText)
                .accessibilityAddTraits(.isHeader)
            Text(presentation.detail)
                .foregroundStyle(Color.nSecondaryText)
            if let error {
                Text(error)
                    .foregroundStyle(Color.nErrorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var actionArea: some View {
        if let progressLabel {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(progressLabel)
            }
            .foregroundStyle(Color.nSecondaryText)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(progressLabel)
            .accessibilityValue("In progress")
        } else if let actionLabel, let action {
            Button(actionLabel, action: action)
                .buttonStyle(PillButtonStyle(kind: .brand))
                .fixedSize()
        }
    }
}

struct ProviderSetupBannerPresentation: Equatable {
    let title: String
    let detail: String

    init(access: ModelAccess, requiresReconnect: Bool) {
        if access == .claudeVertex, requiresReconnect {
            title = ProviderFailure.googleReauthenticationTitle
            detail = String(localized: "Reauthenticate with Google to resume the conversation.")
        } else if requiresReconnect {
            title = String(localized: "\(access.displayName) needs to reconnect")
            detail = String(localized: "Reconnect this account to resume the conversation.")
        } else {
            title = String(localized: "\(access.displayName) needs a connection")
            detail = access.usesInteractiveAccountFlow
                ? String(localized: "Connect this account to resume the conversation.")
                : String(localized:
                    "Choose or configure a connection to resume the conversation.")
        }
    }
}
