import Foundation

struct PermissionOption: Identifiable, Equatable {
    let mode: String
    let title: String
    let detail: String
    var id: String { mode }
}

struct PermissionRequestDetail: Identifiable, Equatable {
    let label: String
    let value: String
    var monospaced = false
    var id: String { label }
}

/// Why a card exists when the permission mode says nothing should ask.
///
/// Write containment runs ahead of the permission mode: a write landing outside the workspace is
/// asked about in every mode, including Bypass permissions. The card must say so, or the person
/// reads a deliberate boundary as their setting being ignored.
struct PermissionWriteEscape: Equatable {
    let target: String
    let workspace: String?

    /// Grants are remembered per containing folder, not per file (`writeEscapeAllowKey`), so the
    /// card says what "Always allow" will actually cover.
    var folder: String { (target as NSString).deletingLastPathComponent }
}

struct PermissionRequestPresentation: Equatable {
    let title: String
    let summary: String
    let details: [PermissionRequestDetail]
}

enum PermissionPresentation {
    static let validModes = Set(["default", "plan", "acceptEdits", "bypassPermissions"])

    static func normalized(_ mode: String?) -> String {
        guard let mode, validModes.contains(mode) else { return "default" }
        return mode
    }

    static func options(for access: ModelAccess) -> [PermissionOption] {
        let options = allOptions(for: access)
        guard let policy = ManagedEnterprisePolicy.current else { return options }
        return options.filter { policy.allowsPermissionMode($0.mode) }
    }

    private static func allOptions(for access: ModelAccess) -> [PermissionOption] {
        switch access {
        case .codexSubscription:
            return [
                PermissionOption(
                    mode: "default",
                    title: "Workspace access",
                    detail: "Codex can read, edit, and run commands inside this workspace. It asks for untrusted or out-of-sandbox actions."),
                PermissionOption(
                    mode: "plan",
                    title: "Plan (read-only)",
                    detail: "Codex can inspect the workspace but cannot change files or run write-capable actions."),
                PermissionOption(
                    mode: "acceptEdits",
                    title: "Auto-accept edits",
                    detail: "File edits are accepted automatically; commands and broader access still follow Codex approval policy."),
                PermissionOption(
                    mode: "bypassPermissions",
                    title: "Full access",
                    detail: "Codex runs without sandbox or approval prompts. Use only in folders you fully trust."),
            ]
        case .claudeSubscription, .anthropicAPI, .claudeVertex:
            return [
                PermissionOption(
                    mode: "default",
                    title: "Default",
                    detail: "Claude Code asks when a tool needs approval; safe Mechanician actions may run automatically."),
                PermissionOption(
                    mode: "plan",
                    title: "Plan (read-only)",
                    detail: "Claude Code researches and prepares a plan without changing the workspace."),
                PermissionOption(
                    mode: "acceptEdits",
                    title: "Accept edits",
                    detail: "Claude Code may apply file edits automatically while other sensitive tools can still ask."),
                PermissionOption(
                    mode: "bypassPermissions",
                    title: "Bypass permissions",
                    detail: "Claude Code runs tools without approval prompts. Writing to a file outside this workspace still asks. Use only in folders you fully trust."),
            ]
        case .claudeBedrock:
            // The same Claude Code engine, so the same permission vocabulary as every Claude lane.
            return allOptions(for: .claudeSubscription)
        case .openAIAPI:
            return [
                PermissionOption(
                    mode: "default",
                    title: "Ask for changes",
                    detail: "Reads run automatically; edits and commands ask for approval unless remembered for this workspace."),
                PermissionOption(
                    mode: "plan",
                    title: "Plan (read-only)",
                    detail: "The agent can inspect context but cannot change files or run write-capable actions."),
                PermissionOption(
                    mode: "acceptEdits",
                    title: "Auto-accept edits",
                    detail: "File edits run automatically; commands still ask unless remembered for this workspace."),
                PermissionOption(
                    mode: "bypassPermissions",
                    title: "Full access",
                    detail: "Local tools run without approval prompts. Use only in folders you fully trust."),
            ]
        }
    }

    static func option(mode: String, access: ModelAccess) -> PermissionOption {
        let normalizedMode = normalized(mode)
        return options(for: access).first { $0.mode == normalizedMode }
            ?? options(for: access)[0]
    }

    /// A permission card outlives the question it asked. The answer can also arrive without the
    /// person seeing a prompt at all: a remembered rule, the permission mode, or a conversation
    /// reopened from history. So a decided card is written in the past tense, and says what the
    /// agent was or was not allowed to do rather than claiming the person just chose it.
    enum Decision {
        case pending
        case allowed
        case denied
    }

    static func request(
        tool rawTool: String,
        payload: String,
        writeEscape: PermissionWriteEscape? = nil,
        decision: Decision = .pending
    ) -> PermissionRequestPresentation {
        let tool = rawTool.split(separator: "__").last.map(String.init) ?? rawTool
        let input = decodedObject(payload)
        let subject = writeEscape == nil ? subject(for: tool) : writeEscapeSubject
        let title: String
        let summary: String
        switch decision {
        case .pending:
            title = subject.question
            summary = subject.pendingSummary
        case .allowed:
            title = subject.past
            summary = "The agent was allowed to \(subject.action)."
        case .denied:
            title = subject.past
            summary = "The agent was not allowed to \(subject.action)."
        }
        let category = subject.category

        var details: [PermissionRequestDetail] = []
        if let command = stringValue(input["command"]) {
            details.append(PermissionRequestDetail(
                label: "Command", value: command, monospaced: true))
        }
        if let path = firstString(in: input, keys: ["file_path", "path", "cwd", "grantRoot"]) {
            details.append(PermissionRequestDetail(
                label: category == "edit" ? "File" : "Location",
                value: path,
                monospaced: true))
        }
        if let reason = firstString(in: input, keys: ["reason", "description"]), !reason.isEmpty {
            details.append(PermissionRequestDetail(label: "Why", value: reason))
        }
        if let writeEscape {
            // Containment judged the path with its symlinks resolved. When that differs from what
            // the agent typed, the resolved one is the reason, so show it rather than leaving the
            // person to wonder why a path they read as inside the workspace was refused.
            if let asked = firstString(in: input, keys: ["file_path", "notebook_path", "path"]),
               asked != writeEscape.target {
                details.append(PermissionRequestDetail(
                    label: "Resolves to", value: writeEscape.target, monospaced: true))
            }
            if let workspace = writeEscape.workspace {
                details.append(PermissionRequestDetail(
                    label: "Workspace", value: workspace, monospaced: true))
            }
            if decision == .pending {
                details.append(PermissionRequestDetail(
                    label: "Always allow",
                    value: "Covers everything in \(writeEscape.folder)",
                    monospaced: true))
            }
        }
        return PermissionRequestPresentation(title: title, summary: summary, details: details)
    }

    /// One row of card copy per kind of request, so the pending wording and the decided wording
    /// cannot drift apart as either is edited.
    private struct PermissionSubject {
        /// Chooses the label the path detail carries. Not shown on its own.
        let category: String
        let question: String
        let pendingSummary: String
        /// Heading for a card whose answer is already in.
        let past: String
        /// Verb phrase completing "The agent was (not) allowed to …".
        let action: String
    }

    /// The card for a write the workspace boundary stopped. It replaces the per-tool copy entirely:
    /// "wants to modify files in this workspace" is not merely vague here, it is false — the write
    /// was stopped precisely because the file is NOT in this workspace.
    private static let writeEscapeSubject = PermissionSubject(
        category: "edit",
        question: "Allow a write outside the workspace?",
        pendingSummary: "This file is outside the workspace. Mechanician asks before writing there in every permission mode, including Bypass permissions.",
        past: "Asked to write outside the workspace",
        action: "write outside the workspace")

    private static func subject(for tool: String) -> PermissionSubject {
        let lower = tool.lowercased()
        if ["edit", "write", "multiedit", "notebookedit"].contains(lower)
            || lower.contains("filechange") {
            return PermissionSubject(
                category: "edit",
                question: "Allow file changes?",
                pendingSummary: "The agent wants to modify files in this workspace.",
                past: "Asked to change files",
                action: "modify files in this workspace")
        }
        if lower == "bash" || lower.contains("commandexecution") || lower.contains("shell") {
            return PermissionSubject(
                category: "command",
                question: "Allow this command?",
                pendingSummary: "The agent wants to run a command in this workspace.",
                past: "Asked to run a command",
                action: "run a command in this workspace")
        }
        if lower.contains("webfetch") || lower.contains("network") {
            return PermissionSubject(
                category: "network",
                question: "Allow network access?",
                pendingSummary: "The agent wants to contact an external service.",
                past: "Asked to contact an external service",
                action: "contact an external service")
        }
        let name = friendlyToolName(tool)
        return PermissionSubject(
            category: "other",
            question: "Allow \(name)?",
            pendingSummary: "The agent needs your approval before it can continue with this action.",
            past: "Asked to use \(name)",
            action: "use \(name)")
    }

    private static func decodedObject(_ payload: String) -> [String: Any] {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func firstString(in input: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(input[key]), !value.isEmpty { return value }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let values = value as? [String] { return values.joined(separator: " ") }
        return nil
    }

    private static func friendlyToolName(_ raw: String) -> String {
        let spaced = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1 $2",
                options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return spaced.isEmpty ? "this action" : spaced.lowercased()
    }
}
