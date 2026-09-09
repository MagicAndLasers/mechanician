import SwiftUI

/// Identifies an artifact to pop into its own window — by IDENTITY (conversation + title),
/// never by value, so a live revision re-renders the SAME window instead of spawning a new
/// one. (Artifact is Codable/Equatable but not Hashable, so we never embed it in the payload.)
struct PreviewPayload: Codable, Hashable {
    let conv: UUID
    let title: String
    var key: String { "\(conv.uuidString)\u{001F}\(title)" }
}

/// Live in-memory registry of poppable artifacts, keyed "conv:title". Seeded at pop-out time
/// and mirrored from the source window's AgentBridge, so a popped-out artifact keeps
/// re-rendering as Claude revises it — without going through the disk-lagged
/// GlobalArtifactsStore. Shared across windows (the pop-out is its own top-level window).
@MainActor final class PreviewRegistry: ObservableObject {
    static let shared = PreviewRegistry()
    @Published private(set) var artifacts: [String: Artifact] = [:]
    private init() {}

    private func key(_ conv: UUID, _ title: String) -> String { "\(conv.uuidString)\u{001F}\(title)" }

    /// Seed/refresh one artifact (called at pop-out time).
    func put(_ artifact: Artifact, conv: UUID) {
        artifacts[key(conv, artifact.title)] = artifact
    }

    /// Mirror a conversation's whole artifact set live (called from AgentBridge on update).
    func sync(_ arts: [Artifact], conv: UUID) {
        for a in arts { artifacts[key(conv, a.title)] = a }
    }

    func artifact(for payload: PreviewPayload) -> Artifact? { artifacts[payload.key] }

    /// Drop an artifact (e.g. it was deleted in the manager) so a pop-out window shows the
    /// "no longer available" state instead of a stale copy.
    func remove(conv: UUID, title: String) { artifacts[key(conv, title)] = nil }
}

/// The pop-out window: renders a live artifact full-size via the shared `ArtifactPreview`
/// path (no Magnifier/scaleEffect — that crashes over the hosted WKWebView during resize).
struct PreviewWindowView: View {
    let payload: PreviewPayload
    @ObservedObject private var registry = PreviewRegistry.shared

    var body: some View {
        Group {
            if let artifact = registry.artifact(for: payload) {
                VStack(spacing: 0) {
                    header(artifact)
                    Divider()
                    ArtifactPreview(artifact: artifact)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.slash").font(.largeTitle).foregroundStyle(.secondary)
                    Text("This artifact is no longer available.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Color.nBg)
    }

    private func header(_ a: Artifact) -> some View {
        HStack(spacing: 8) {
            Text(a.title).font(.headline).lineLimit(1)
            Text(a.type.uppercased())
                .font(.caption2.weight(.bold).monospaced())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.nAccent.opacity(0.25)))
            if a.revisions > 1 {
                Text("v\(a.revisions)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { ArtifactActions.copySource(a) } label: {
                Label("Copy Source", systemImage: "doc.on.doc")
            }
            .buttonStyle(PillButtonStyle(kind: .neutral))
            .help("Copy artifact source")
        }
        .padding(10)
    }
}
