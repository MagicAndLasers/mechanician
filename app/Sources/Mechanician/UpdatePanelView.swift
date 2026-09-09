import SwiftUI
import AppKit
import Sparkle

/// The software-update panel: one window whose content follows UpdaterManager.phase. Pill
/// buttons, card surfaces, and markdown release notes — updating finally looks like Mechanician.
struct UpdatePanelView: View {
    @EnvironmentObject private var updater: UpdaterManager

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        content
            .padding(20)
            .frame(width: 470)
            .background(Color.nBg)
    }

    @ViewBuilder private var content: some View {
        switch updater.phase {
        case .idle:
            // Visible only for the instant between teardown and the window closing.
            Color.clear.frame(height: 1)
        case .checking:
            checking
        case .found(let item, let state):
            found(item, state)
        case .downloading:
            downloading
        case .extracting:
            extracting
        case .readyToInstall:
            ready
        case .installing(let terminated):
            installing(terminated)
        case .upToDate(let latest):
            upToDate(latest)
        case .error(let err):
            errorView(err)
        }
    }

    // MARK: - Shared pieces

    private func header(icon: AnyView? = nil, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if let icon {
                icon
            } else {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 56, height: 56)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func symbolBadge(_ name: String, _ color: Color) -> AnyView {
        AnyView(
            Image(systemName: name)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 56, height: 56)
        )
    }

    // MARK: - Phases

    private var checking: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Checking for Updates…", "Contacting the update server.")
            HStack {
                ProgressView().controlSize(.small)
                Spacer()
                Button("Cancel") { updater.cancelInFlight() }
                    .buttonStyle(PillButtonStyle(kind: .plain))
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func found(_ item: SUAppcastItem, _ state: SPUUserUpdateState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Update Available",
                   "Mechanician \(item.displayVersionString) is available. You have \(currentVersion).")
            if item.isCriticalUpdate {
                Label("Critical update. Install it soon.",
                      systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.nWarningText)
            }
            if UpdateChannel.isDailySparkleChannel(item.channel) {
                Label("Daily build", systemImage: "sun.max.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if let notes = releaseNotes(item) {
                // Fixed height: under NSHostingController intrinsic sizing a ScrollView's
                // ideal height is unreliable (it can collapse to zero with only a maxHeight).
                ScrollView {
                    MarkdownText(text: notes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 190)
                .cardSurface(cornerRadius: 10)
            }
            HStack(spacing: 8) {
                if !item.isInformationOnlyUpdate {
                    Button("Skip This Version") { updater.choose(.skip) }
                        .buttonStyle(PillButtonStyle(kind: .plain))
                }
                Spacer()
                Button("Later") { updater.choose(.dismiss) }
                    .buttonStyle(PillButtonStyle(kind: .plain))
                    .keyboardShortcut(.cancelAction)
                if item.isInformationOnlyUpdate {
                    Button("Learn More…") { updater.openInfoURL(item) }
                        .buttonStyle(PillButtonStyle(kind: .accent))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(state.stage == .installing ? "Install and Relaunch" : "Install Update") {
                        updater.choose(.install)
                    }
                    .buttonStyle(PillButtonStyle(kind: .accent))
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var downloading: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Downloading Update…", byteProgressText)
            if updater.expectedBytes > 0 {
                meter(Double(updater.receivedBytes) / Double(max(updater.expectedBytes, updater.receivedBytes)))
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                Spacer()
                Button("Cancel") { updater.cancelInFlight() }
                    .buttonStyle(PillButtonStyle(kind: .plain))
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    /// The app's capsule meter (same shape as the composer's context meter) — the system
    /// linear ProgressView picked up an alarming red in this window.
    private func meter(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.nMuted.opacity(0.35))
                Capsule().fill(Color.nAccent)
                    .frame(width: max(6, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.2), value: fraction)
    }

    private var byteProgressText: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        let got = f.string(fromByteCount: Int64(updater.receivedBytes))
        guard updater.expectedBytes > 0 else { return got }
        return "\(got) of \(f.string(fromByteCount: Int64(updater.expectedBytes)))"
    }

    private var extracting: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Preparing Update…", "Verifying and unpacking the download.")
            meter(updater.extractionProgress)
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Ready to Install", "Mechanician will relaunch to finish updating.")
            HStack(spacing: 8) {
                Spacer()
                Button("Later") { updater.choose(.dismiss) }
                    .buttonStyle(PillButtonStyle(kind: .plain))
                    .keyboardShortcut(.cancelAction)
                Button("Install and Relaunch") { updater.choose(.install) }
                    .buttonStyle(PillButtonStyle(kind: .accent))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func installing(_ terminated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Installing Update…",
                   terminated ? "Finishing up." : "Waiting for Mechanician to quit.")
            HStack {
                ProgressView().controlSize(.small)
                Spacer()
                if !terminated {
                    Button("Quit Now") { updater.retryQuit() }
                        .buttonStyle(PillButtonStyle(kind: .neutral))
                }
            }
        }
    }

    private func upToDate(_ latest: String?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(icon: symbolBadge("checkmark.seal.fill", Color.nAccent),
                   "You're up to date",
                   "Mechanician \(latest ?? currentVersion) is the newest version available.")
            HStack {
                Spacer()
                Button("OK") { updater.acknowledge() }
                    .buttonStyle(PillButtonStyle(kind: .accent))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func errorView(_ err: NSError) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(icon: symbolBadge("exclamationmark.triangle.fill", .orange),
                   "The update couldn't be completed",
                   err.localizedDescription)
            if let suggestion = err.localizedRecoverySuggestion, !suggestion.isEmpty {
                Text(suggestion)
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("OK") { updater.acknowledge() }
                    .buttonStyle(PillButtonStyle(kind: .accent))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Release notes

    /// Notes downloaded from releaseNotesURL win; else the appcast item's embedded
    /// <description>. HTML gets flattened to text (our own release notes are simple), and
    /// MarkdownText renders the result.
    private func releaseNotes(_ item: SUAppcastItem) -> String? {
        if let notes = updater.downloadedNotes, !notes.isEmpty { return flattenHTMLIfNeeded(notes) }
        if let notes = item.itemDescription, !notes.isEmpty {
            return item.itemDescriptionFormat == "plain-text" ? notes : flattenHTMLIfNeeded(notes)
        }
        return nil
    }

    private func flattenHTMLIfNeeded(_ s: String) -> String {
        guard s.range(of: "</?[a-zA-Z][^>]*>", options: .regularExpression) != nil else { return s }
        var t = s
        for (pattern, replacement) in [
            ("<br ?/?>", "\n"), ("</p>", "\n\n"), ("</li>", "\n"), ("<li[^>]*>", "- "),
            ("</h[1-6]>", "\n\n"), ("<h[1-6][^>]*>", "## "), ("<[^>]+>", ""),
        ] {
            t = t.replacingOccurrences(of: pattern, with: replacement,
                                       options: [.regularExpression, .caseInsensitive])
        }
        return t.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
