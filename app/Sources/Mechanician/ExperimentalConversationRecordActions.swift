import AppKit
import UniformTypeIdentifiers

enum ExperimentalConversationRecordFileType {
    static let identifier = "ai.mechanician.conversation-record"
    static let filenameExtension = "convrec"

    /// Constructed explicitly so panels work in SwiftPM tests and the isolated dev bundle as well
    /// as in the public app whose Info.plist exports the same declaration to Launch Services.
    static let uniformType = UTType(
        exportedAs: identifier,
        conformingTo: .data)

    static func matches(_ url: URL) -> Bool {
        url.isFileURL
            && url.pathExtension.caseInsensitiveCompare(filenameExtension) == .orderedSame
    }
}

private final class ConversationRecordProfileAccessoryView: NSView {
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let detail = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        popup.addItems(withTitles: ExperimentalConversationRecordProfile.allCases.map(\.title))
        popup.selectItem(at: 0) // Conservative sharing is the safe default.
        popup.target = self
        popup.action = #selector(profileChanged)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3

        let label = NSTextField(labelWithString: "Disclosure profile:")
        label.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let stack = NSStackView(views: [row, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 410),
        ])
        profileChanged()
    }

    required init?(coder: NSCoder) { nil }

    var profile: ExperimentalConversationRecordProfile {
        ExperimentalConversationRecordProfile.allCases[
            min(max(popup.indexOfSelectedItem, 0),
                ExperimentalConversationRecordProfile.allCases.count - 1)]
    }

    @objc private func profileChanged() { detail.stringValue = profile.detail }
}

@MainActor
enum ExperimentalConversationRecordActions {
    private static let validationQueue = DispatchQueue(
        label: "ai.mechanician.experimental-convrec-validate",
        qos: .userInitiated)

    static func export(from bridge: AgentBridge) {
        guard let conversationID = bridge.currentID else { return }
        let panel = NSSavePanel()
        panel.title = "Export Experimental v0 Conversation Record Snapshot"
        panel.prompt = "Export"
        let title = bridge.currentConversation?.displayTitle ?? "Conversation"
        let markdownName = ConversationMarkdownDocument.filename(for: title)
        panel.nameFieldStringValue = String(markdownName.dropLast(3)) + ".convrec"
        panel.allowedContentTypes = [ExperimentalConversationRecordFileType.uniformType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let accessory = ConversationRecordProfileAccessoryView(frame: .zero)
        panel.accessoryView = accessory

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let selectedURL = panel.url else { return }
            let destination = exportDestination(for: selectedURL)
            let profile = accessory.profile
            bridge.prepareCurrentConversationForExperimentalExport(expectedID: conversationID) {
                preparation in
                switch preparation {
                case .failure(let error):
                    presentError(
                        title: "Couldn’t Export Conversation Record",
                        error: error,
                        in: bridge.window)
                case .success(let conversation):
                    ExperimentalConversationRecordExporter.export(
                        conversation: conversation,
                        profile: profile,
                        destination: destination
                    ) { result in
                        bridge.store.trimResidencyIfNeeded()
                        switch result {
                        case .failure(let error):
                            presentError(
                                title: "Couldn’t Export Conversation Record",
                                error: error,
                                in: bridge.window)
                        case .success(let report):
                            presentSuccess(
                                report: report,
                                url: destination,
                                exported: true,
                                in: bridge.window)
                        }
                    }
                }
            }
        }
        if let window = bridge.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    static func exportDestination(for selectedURL: URL) -> URL {
        guard selectedURL.pathExtension.caseInsensitiveCompare(
            ExperimentalConversationRecordFileType.filenameExtension) != .orderedSame else {
            return selectedURL
        }
        return selectedURL.appendingPathExtension(
            ExperimentalConversationRecordFileType.filenameExtension)
    }

    static func validate(from bridge: AgentBridge?) {
        let panel = NSOpenPanel()
        panel.title = "Validate Conversation Record"
        panel.prompt = "Validate"
        // The panel uses the registered portable type; the validator still treats content as the
        // authority and never trusts the extension by itself.
        panel.allowedContentTypes = [ExperimentalConversationRecordFileType.uniformType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            validationQueue.async {
                let result: Result<ExperimentalConversationRecordReport, Error>
                do {
                    result = .success(try ExperimentalConversationRecordValidator.validate(url))
                } catch {
                    result = .failure(error)
                }
                Task { @MainActor in
                    switch result {
                    case .success(let report):
                        presentSuccess(
                            report: report,
                            url: url,
                            exported: false,
                            in: bridge?.window)
                    case .failure(let error):
                        presentError(
                            title: "Conversation Record Is Not Valid",
                            error: error,
                            suffix: "\n\nThe file was neither modified nor imported.",
                            in: bridge?.window)
                    }
                }
            }
        }
        if let window = bridge?.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    static func openInspector() {
        let panel = NSOpenPanel()
        panel.title = "Open Conversation Record Read-Only"
        panel.prompt = "Open Read-Only"
        panel.message = "The file will be validated and shown as bounded plain text. It will not be imported or executed."
        panel.allowedContentTypes = [ExperimentalConversationRecordFileType.uniformType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            ExperimentalConversationRecordInspectorController.shared.open(url)
        }
        // This command remains usable while the reusable inspector or another utility window is
        // key. A standalone panel cannot become a hidden sheet on the last active Workspace.
        panel.begin(completionHandler: completion)
    }

    private static func presentSuccess(
        report: ExperimentalConversationRecordReport,
        url: URL,
        exported: Bool,
        in window: NSWindow?
    ) {
        let activeOmissions = report.omissions.filter { $0.count > 0 }
        let omissionSummary = activeOmissions.isEmpty
            ? "None recorded"
            : activeOmissions.map { "• \($0.code): \($0.count)" }.joined(separator: "\n")
        let trailing = report.trailingUncommittedBytes > 0
            ? "\nWarning: \(report.trailingUncommittedBytes) trailing uncommitted bytes were ignored."
            : ""
        let publication = report.publicationWarning.map { "\nWarning: \($0)" } ?? ""
        let authority = exported
            ? "This experimental v0 snapshot is a portable copy, not the frozen v1 binding. Mechanician's library.db remains the product authority; editing this file does not change the live conversation."
            : "The file was validated read-only and was not imported."
        let disclosureWarning = report.profile
            == ExperimentalConversationRecordProfile.shareSnapshot.rawValue
            ? "This profile still contains user and assistant dialog. Review it before sharing.\n"
            : "This profile may contain sensitive conversation content. Keep it private unless reviewed.\n"
        let formatSummary = report.formatVersion == 1
            ? "Conversation Record format: v1"
            : "Legacy experimental format: v\(report.formatVersion) (read-only compatibility)"
        let alert = NSAlert()
        alert.alertStyle = report.trailingUncommittedBytes > 0 || report.publicationWarning != nil
            ? .warning
            : .informational
        alert.messageText = exported
            ? "Experimental Conversation Record Snapshot Exported"
            : "Conversation Record Is Valid"
        alert.informativeText = """
        \(formatSummary)
        Profile: \(report.profileTitle)
        Agents: \(report.agents)    Events: \(report.events)    Chronology: \(report.chronology)
        Lineage: \(report.lineageID)
        Version: \(report.versionID)
        Content SHA-256: \(report.contentDigestSHA256)
        File SHA-256: \(report.byteDigestSHA256)

        Recorded omissions:
        \(omissionSummary)\(trailing)\(publication)

        \(disclosureWarning)
        \(authority)
        \(url.path)
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        let response: (NSApplication.ModalResponse) -> Void = { value in
            if value == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: response)
        } else {
            response(alert.runModal())
        }
    }

    private static func presentError(
        title: String,
        error: Error,
        suffix: String = "",
        in window: NSWindow?
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        let description = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        alert.informativeText = description + suffix
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
