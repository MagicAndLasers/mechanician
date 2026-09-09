import AppKit
import SwiftUI

private func experimentalConversationRecordInertText(
    _ source: String,
    maximumScalars: Int
) -> String {
    var output = String.UnicodeScalarView()
    for scalar in source.unicodeScalars.prefix(maximumScalars) {
        let value = scalar.value
        let unsafe = (value < 0x20 && value != 0x09 && value != 0x0a)
            || (0x7f...0x9f).contains(value)
            || value == 0x061c
            || value == 0x200e
            || value == 0x200f
            || (0x202a...0x202e).contains(value)
            || (0x2066...0x2069).contains(value)
        output.append(unsafe ? "\u{fffd}" : scalar)
    }
    return String(output)
}

private final class ExperimentalConversationRecordInspectionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private enum ExperimentalConversationRecordInspectionOutcome: Sendable {
    case valid(ExperimentalConversationRecordInspection)
    case invalid(String)
    case cancelled
}

@MainActor
final class ExperimentalConversationRecordInspectorModel: ObservableObject {
    enum State {
        case idle
        case loading(URL)
        case valid(URL, ExperimentalConversationRecordInspection)
        case invalid(URL, String)
    }

    @Published private(set) var state: State = .idle

    func begin(_ url: URL) { state = .loading(url) }
    func finish(_ url: URL, inspection: ExperimentalConversationRecordInspection) {
        state = .valid(url, inspection)
    }
    func fail(_ url: URL, message: String) { state = .invalid(url, message) }
    func reset() { state = .idle }
}

/// Owns one reusable, non-document inspector window. Inspected bytes stay only in its bounded model;
/// nothing enters installed conversation state, SQLite, Spotlight, recents, or a provider/runtime surface.
@MainActor
final class ExperimentalConversationRecordInspectorController {
    static let shared = ExperimentalConversationRecordInspectorController()

    private let queue = DispatchQueue(
        label: "ai.mechanician.experimental-convrec-inspect",
        qos: .userInitiated)
    private let model = ExperimentalConversationRecordInspectorModel()
    private var window: NSWindow?
    private var generation = 0
    private var cancellation: ExperimentalConversationRecordInspectionCancellation?

    private init() {}

    func open(_ url: URL) {
        generation += 1
        let requestedGeneration = generation
        cancellation?.cancel()
        let token = ExperimentalConversationRecordInspectionCancellation()
        cancellation = token
        model.begin(url)
        present(url)

        let controller = self
        queue.async {
            let outcome: ExperimentalConversationRecordInspectionOutcome
            do {
                let inspection = try ExperimentalConversationRecordValidator.inspect(
                    url, isCancelled: { token.isCancelled })
                outcome = .valid(inspection)
            } catch ExperimentalConversationRecordError.validationCancelled {
                outcome = .cancelled
            } catch {
                outcome = .invalid(Self.inertErrorMessage(error.localizedDescription))
            }
            Task { @MainActor in
                controller.complete(
                    url: url,
                    generation: requestedGeneration,
                    outcome: outcome)
            }
        }
    }

    private func complete(
        url: URL,
        generation requestedGeneration: Int,
        outcome: ExperimentalConversationRecordInspectionOutcome
    ) {
        guard requestedGeneration == generation else { return }
        switch outcome {
        case .valid(let inspection):
            model.finish(url, inspection: inspection)
        case .invalid(let message):
            model.fail(url, message: message)
        case .cancelled:
            break
        }
    }

    private func present(_ url: URL) {
        let inspectorWindow: NSWindow
        if let window {
            inspectorWindow = window
        } else {
            let view = ExperimentalConversationRecordInspectorView(model: model).appChrome()
            let created = NSWindow(contentViewController: NSHostingController(rootView: view))
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.isReleasedWhenClosed = false
            created.minSize = NSSize(width: 700, height: 500)
            created.setContentSize(NSSize(width: 900, height: 700))
            created.setFrameAutosaveName("ExperimentalConversationRecordInspectorWindow")
            created.center()
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: created,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.didCloseWindow() }
            }
            window = created
            inspectorWindow = created
        }
        let inertName = experimentalConversationRecordInertText(
            url.lastPathComponent, maximumScalars: 512)
        inspectorWindow.title = "\(inertName) — Conversation Record"
        inspectorWindow.representedURL = url
        NSApp.activate(ignoringOtherApps: true)
        inspectorWindow.makeKeyAndOrderFront(nil)
    }

    private func didCloseWindow() {
        generation += 1
        cancellation?.cancel()
        cancellation = nil
        model.reset()
        window?.representedURL = nil
        window?.title = "Conversation Record"
    }

    private nonisolated static func inertErrorMessage(_ source: String) -> String {
        experimentalConversationRecordInertText(source, maximumScalars: 2_048)
    }
}

private struct ExperimentalConversationRecordInspectorView: View {
    @ObservedObject var model: ExperimentalConversationRecordInspectorModel

    var body: some View {
        Group {
            switch model.state {
            case .idle:
                EmptyView()
            case .loading(let url):
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Validating Conversation Record…")
                        .font(.headline)
                    inertPath(url)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("convrec-inspector-loading")
            case .invalid(let url, let message):
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("This Conversation Record could not be inspected", systemImage: "xmark.shield")
                            .font(.title2.weight(.semibold))
                        inertPath(url)
                        Text(verbatim: message)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("The file was not modified or imported.")
                            .font(.callout.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
                .accessibilityIdentifier("convrec-inspector-invalid")
            case .valid(let url, let inspection):
                validView(url: url, inspection: inspection)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(Color.nBg)
        .environment(\.openURL, OpenURLAction { _ in .discarded })
    }

    private func validView(
        url: URL,
        inspection: ExperimentalConversationRecordInspection
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: inspection.displayName)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                        Spacer()
                        Text("EXPERIMENTAL V0")
                            .font(.caption2.weight(.bold).monospaced())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                    inertPath(url)
                    Label(
                        "Validated read-only. Nothing was imported, registered, executed, or fetched.",
                        systemImage: "checkmark.shield")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(verbatim: profileDetail(inspection.report.profile))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Snapshot validated when opened; reopen it to validate the current bytes at this path.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("convrec-inspector-header")

                metadata(inspection)
                projectionWarnings(inspection)
                agents(inspection)
                dialog(inspection)
                omissions(inspection.report.omissions)
                integrity(inspection.report)
            }
            .padding(24)
        }
        .accessibilityIdentifier("convrec-inspector-valid")
    }

    private func inertPath(_ url: URL) -> some View {
        Text(verbatim: experimentalConversationRecordInertText(
            url.path, maximumScalars: 4_096))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .textSelection(.enabled)
            .accessibilityIdentifier("convrec-inspector-path")
    }

    private func profileDetail(_ rawProfile: String) -> String {
        ExperimentalConversationRecordProfile(rawValue: rawProfile)?.detail
            ?? "The declared disclosure profile is not recognized by this build."
    }

    private func metadata(_ inspection: ExperimentalConversationRecordInspection) -> some View {
        let report = inspection.report
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Record")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                metadataRow(
                    "Format",
                    report.formatVersion == 1
                        ? "Conversation Record v1"
                        : "Experimental Conversation Record v\(report.formatVersion) (read-only)")
                metadataRow("Declared profile", report.profileTitle)
                metadataRow("File size", ByteCountFormatter.string(
                    fromByteCount: Int64(report.bytes), countStyle: .file))
                metadataRow("Agents", String(report.agents))
                metadataRow("Events", String(report.events))
                metadataRow("Chronology", report.chronology.capitalized)
                if let exportedAt = inspection.exportedAt {
                    metadataRow("Exported", exportedAt)
                }
                let producer = [
                    inspection.producerName,
                    inspection.producerVersion,
                    inspection.producerBuild.map { "build \($0)" },
                ].compactMap { $0 }.joined(separator: " · ")
                if !producer.isEmpty { metadataRow("Producer", producer) }
                if let revision = inspection.producerSourceRevision {
                    metadataRow("Source revision", revision)
                }
            }
        }
        .accessibilityIdentifier("convrec-inspector-metadata")
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(verbatim: value).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func projectionWarnings(_ inspection: ExperimentalConversationRecordInspection) -> some View {
        let hasWarnings = inspection.omittedAgentCount > 0
            || inspection.omittedDialogEntryCount > 0
            || inspection.truncatedDialogEntryCount > 0
            || inspection.replacedControlCharacterCount > 0
            || inspection.report.trailingUncommittedBytes > 0
        if hasWarnings {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Inspector limits")
                if inspection.omittedAgentCount > 0 {
                    Text("\(inspection.omittedAgentCount) agent rows were omitted from this bounded view.")
                }
                if inspection.omittedDialogEntryCount > 0 {
                    Text("\(inspection.omittedDialogEntryCount) dialog rows were omitted from this bounded view.")
                }
                if inspection.truncatedDialogEntryCount > 0 {
                    Text("\(inspection.truncatedDialogEntryCount) dialog rows were truncated for safe display.")
                }
                if inspection.replacedControlCharacterCount > 0 {
                    Text("\(inspection.replacedControlCharacterCount) control or bidirectional characters were replaced for display.")
                }
                if inspection.report.trailingUncommittedBytes > 0 {
                    Text("\(inspection.report.trailingUncommittedBytes) trailing uncommitted bytes were ignored.")
                }
            }
            .font(.callout)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
            .accessibilityIdentifier("convrec-inspector-warnings")
        }
    }

    private func agents(_ inspection: ExperimentalConversationRecordInspection) -> some View {
        LazyVStack(alignment: .leading, spacing: 9) {
            sectionTitle("Agents")
            if inspection.agents.isEmpty {
                Text("No agent rows are available in the bounded projection.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(inspection.agents) { agent in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: agent.displayID)
                            .font(.body.weight(.medium))
                            .textSelection(.enabled)
                        Text(verbatim: agent.type)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if let parent = agent.parentID {
                            Text("parent")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(verbatim: parent)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if let model = agent.observedModel {
                            Spacer()
                            Text(verbatim: model)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("convrec-inspector-agents")
    }

    private func dialog(_ inspection: ExperimentalConversationRecordInspection) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            sectionTitle("Retained dialog")
            if inspection.dialog.isEmpty {
                Text("This record exposes no retained dialog to the inspector.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(inspection.dialog) { entry in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            Text(dialogTitle(entry.kind))
                                .font(.caption.weight(.semibold))
                            Text(verbatim: entry.actorID)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let observedAt = entry.observedAt {
                                Spacer()
                                Text(verbatim: observedAt)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                            if entry.wasTruncated {
                                Text("TRUNCATED")
                                    .font(.caption2.weight(.bold).monospaced())
                                    .foregroundStyle(.orange)
                            }
                        }
                        // Deliberately plain: no Markdown, HTML, links, images, attachments, file
                        // lookup, live transcript actions, or provider/store integration.
                        Text(verbatim: entry.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
                }
            }
        }
        .accessibilityIdentifier("convrec-inspector-dialog")
    }

    private func dialogTitle(_ kind: String) -> String {
        switch kind {
        case "user_message": return "User"
        case "assistant_message": return "Assistant"
        case "system": return "System"
        default: return "Dialog"
        }
    }

    private func omissions(_ omissions: [ExperimentalConversationRecordOmission]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Recorded omissions")
            let active = omissions.filter { $0.count > 0 }
            if active.isEmpty {
                Text("None recorded").foregroundStyle(.secondary)
            } else {
                ForEach(Array(active.enumerated()), id: \.offset) { _, omission in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(verbatim: inertLabel(omission.code))
                                .font(.callout.weight(.medium).monospaced())
                                .textSelection(.enabled)
                            Spacer()
                            Text(String(omission.count)).font(.callout.monospacedDigit())
                        }
                        Text(verbatim: inertLabel(omission.reason))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .accessibilityIdentifier("convrec-inspector-omissions")
    }

    private func integrity(_ report: ExperimentalConversationRecordReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Identity and integrity")
            integrityRow("Lineage", report.lineageID)
            integrityRow("Version", report.versionID)
            integrityRow("Content SHA-256", report.contentDigestSHA256)
            integrityRow("File SHA-256", report.byteDigestSHA256)
        }
        .accessibilityIdentifier("convrec-inspector-integrity")
    }

    private func integrityRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.headline)
    }

    private func inertLabel(_ source: String) -> String {
        experimentalConversationRecordInertText(source, maximumScalars: 512)
    }
}
