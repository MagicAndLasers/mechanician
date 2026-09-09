import AppKit
import SwiftUI

/// The only scene materialized when root authority cannot safely select today's Legacy writers.
/// It intentionally owns no Conversation, Workspace, Artifact, Ambient, provider, or shadow-store
/// singleton; recognition therefore remains earlier than every scoped store constructor.
struct StorageAuthorityRecoveryView: View {
    let recognition: StorageAuthorityRecognition
    /// Present so a build that cannot open can still take the one that fixes it. This is the screen
    /// a bad release strands people on, and looking in the menu bar is not the first instinct when
    /// the app appears broken.
    var checkForUpdates: (() -> Void)?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(Color.orange)

            Text("Storage Recovery Required")
                .font(.title2.weight(.semibold))

            Text(recognition.disposition.blockingMessage
                ?? "Mechanician cannot safely select a writable library generation.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Recognition")
                        .foregroundStyle(.secondary)
                    Text(StorageAuthorityProtocol.recognitionID)
                }
                GridRow {
                    Text("Root marker")
                        .foregroundStyle(.secondary)
                    Text(recognition.marker.title)
                }
                GridRow {
                    Text("Launch decision")
                        .foregroundStyle(.secondary)
                    Text(recognition.disposition.title)
                }
            }
            .font(.callout)

            HStack(spacing: 10) {
                Button("Reveal Library Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([recognition.anchorRoot])
                }
                .buttonStyle(PillButtonStyle(kind: .neutral))
                if let checkForUpdates {
                    Button("Check for Updates…", action: checkForUpdates)
                        .buttonStyle(PillButtonStyle(kind: .neutral))
                }
                Button("Quit Mechanician") { NSApp.terminate(nil) }
                    .buttonStyle(PillButtonStyle(kind: .brand))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 560)
    }
}

/// What a scene may materialize for the recognized SQLite root.
enum StorageAuthorityScenePresentation: Equatable {
    case product
    case recovery

    static func resolve(allowsNormalProduct: Bool) -> Self {
        return allowsNormalProduct ? .product : .recovery
    }

    /// Title for the Projects scene. Recovery reuses this suppressed shell only for its blocker.
    static func windowTitle(_ presentation: Self) -> String {
        switch presentation {
        case .product: return "Workspaces"
        case .recovery: return "Storage Recovery"
        }
    }

    var presentsProjectsAtLaunch: Bool { self == .recovery }
}

/// Store-bearing scene content remains a closure until the recognized root permits normal product
/// construction. Even if SwiftUI materializes a suppressed scene while in recovery mode, it cannot
/// initialize one of the scoped singleton stores behind this gate.
struct StorageAuthorityContentGate<Content: View>: View {
    let recognition: StorageAuthorityRecognition
    /// Forwarded to the recovery screen only. A blocked build must keep the one action that can
    /// replace it.
    var checkForUpdates: (() -> Void)?
    private let content: () -> Content

    init(
        recognition: StorageAuthorityRecognition,
        checkForUpdates: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.recognition = recognition
        self.checkForUpdates = checkForUpdates
        self.content = content
    }

    @ViewBuilder var body: some View {
        switch StorageAuthorityScenePresentation.resolve(
            allowsNormalProduct: recognition.disposition.allowsNormalProduct) {
        case .product:
            content()
        case .recovery:
            StorageAuthorityRecoveryView(
                recognition: recognition, checkForUpdates: checkForUpdates)
        }
    }
}
