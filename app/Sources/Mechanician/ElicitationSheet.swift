import SwiftUI

/// A question a mounted MCP server asked mid-turn, and the form to answer it.
///
/// MCP calls this *elicitation*: a server pausing to ask for something it could not know in advance
/// — which design you want, which account to use, whether to overwrite. agentd used to decline every
/// one of these, so any server that asked a question was unusable no matter which provider mounted
/// it. This is that surface.
///
/// Modelled on the permission prompt rather than invented: it names who is asking before it asks,
/// because "an extension wants something" is not a question anyone can answer safely.
struct ElicitationRequest: Identifiable, Equatable {
    struct Option: Identifiable, Equatable {
        var id: String { value }
        let value: String
        let label: String
    }

    struct Field: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let title: String
        let detail: String
        /// string · number · boolean · select · multiSelect
        let kind: String
        let required: Bool
        let options: [Option]
        let integer: Bool
        let minimum: Double?
        let maximum: Double?
        let minLength: Int?
        let maxLength: Int?
        let format: String?
        let defaultString: String
        let defaultBool: Bool
        let defaultStrings: [String]
    }

    let id: String
    /// `form`, `confirm`, or `url`.
    let mode: String
    let serverName: String
    let message: String
    let fields: [Field]
    let url: URL?
    /// Which lane raised it. The answer has to go back to the same agentd — that process holds the
    /// open JSON-RPC request.
    let access: ModelAccess
}

/// The live elicitation, if any. One at a time by construction: MCP elicitation is a synchronous
/// server-to-client request, so a second cannot arrive while the first is unanswered.
@MainActor
final class ElicitationStore: ObservableObject {
    static let shared = ElicitationStore()
    @Published var pending: ElicitationRequest?

    func present(_ event: [String: Any], from access: ModelAccess) {
        guard let id = event["elicitationId"] as? String else { return }
        let fields = (event["fields"] as? [[String: Any]] ?? []).compactMap(Self.field)
        pending = ElicitationRequest(
            id: id,
            mode: event["mode"] as? String ?? "form",
            serverName: event["serverName"] as? String ?? "An extension",
            message: event["message"] as? String ?? "",
            fields: fields,
            url: (event["url"] as? String).flatMap(URL.init(string:)),
            access: access)
    }

    /// agentd answered on our behalf — it timed out, or the turn went away. Take the sheet down
    /// rather than leave a form that can no longer be submitted.
    func close(_ elicitationID: String) {
        if pending?.id == elicitationID { pending = nil }
    }

    private static func field(_ row: [String: Any]) -> ElicitationRequest.Field? {
        guard let name = row["name"] as? String else { return nil }
        let options = (row["options"] as? [[String: Any]] ?? []).compactMap { option -> ElicitationRequest.Option? in
            guard let value = option["value"] as? String else { return nil }
            return .init(value: value, label: option["label"] as? String ?? value)
        }
        // Bind every field before the initializer call rather than inside it. Each
        // `as? T ?? default` is its own overload-resolution branch, and fourteen of them in one
        // expression multiply into something the type checker abandons: this failed outright on
        // CI's toolchain with "unable to type-check this expression in reasonable time" while
        // still completing locally. Stating each type up front makes the call itself trivial.
        let title = row["title"] as? String ?? name
        let detail = row["description"] as? String ?? ""
        let kind = row["kind"] as? String ?? "string"
        let required = row["required"] as? Bool ?? false
        let integer = row["integer"] as? Bool ?? false
        let minimum = row["minimum"] as? Double
        let maximum = row["maximum"] as? Double
        let minLength = row["minLength"] as? Int
        let maxLength = row["maxLength"] as? Int
        let format = row["format"] as? String
        let defaultBool = row["defaultValue"] as? Bool ?? false
        let defaultStrings = row["defaultValue"] as? [String] ?? []
        let defaultString: String = {
            if let text = row["defaultValue"] as? String { return text }
            if let number = row["defaultValue"] as? Double {
                return number == number.rounded() ? String(Int(number)) : String(number)
            }
            return ""
        }()
        return .init(
            name: name,
            title: title,
            detail: detail,
            kind: kind,
            required: required,
            options: options,
            integer: integer,
            minimum: minimum,
            maximum: maximum,
            minLength: minLength,
            maxLength: maxLength,
            format: format,
            defaultString: defaultString,
            defaultBool: defaultBool,
            defaultStrings: defaultStrings)
    }
}

struct ElicitationSheet: View {
    let request: ElicitationRequest
    let onRespond: (String, [String: Any]) -> Void

    @State private var strings: [String: String] = [:]
    @State private var bools: [String: Bool] = [:]
    @State private var multi: [String: Set<String>] = [:]

    var body: some View {
        // No Done button: "Not Now" / "Deny" IS the way out, and answering a prompt from a
        // third-party server is not somewhere to offer two dismissals with different meanings.
        DetailSheet(width: 480, height: sheetHeight, showsDone: false,
                    onClose: { respond("decline") }) {
            VStack(alignment: .leading, spacing: 14) {
                header
                switch request.mode {
                case "url": urlBody
                case "confirm": EmptyView()   // the message IS the question
                default: ForEach(request.fields) { field in fieldView(field) }
                }
            }
        } actions: {
            Button(request.mode == "confirm" ? "Deny" : "Not Now") { respond("decline") }
                .buttonStyle(PillButtonStyle(kind: .neutral))
            if request.mode == "confirm" {
                Button("Allow") { respond("accept") }
                    .buttonStyle(PillButtonStyle(kind: .accent))
            } else if request.mode == "url" {
                if let url = request.url {
                    Button("Open and Continue") {
                        NSWorkspace.shared.open(url)
                        respond("accept")
                    }
                    .buttonStyle(PillButtonStyle(kind: .accent))
                }
            } else {
                Button("Send") { respond("accept") }
                    .buttonStyle(PillButtonStyle(kind: .accent))
                    .disabled(!isComplete)
            }
        }
        .onAppear(perform: seedDefaults)
    }

    /// Say WHO is asking before saying what. An unattributed prompt is one a person cannot judge,
    /// and this one is arriving from a third-party extension mid-turn.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "questionmark.bubble").foregroundStyle(Color.nInfoText)
                Text("\(request.serverName) is asking")
                    .font(.system(size: 13, weight: .semibold))
            }
            if !request.message.isEmpty {
                Text(request.message)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var urlBody: some View {
        if let url = request.url {
            VStack(alignment: .leading, spacing: 4) {
                Text("It wants to open:").font(.caption).foregroundStyle(.secondary)
                // The full URL, unshortened — an abbreviated one is exactly what a phishing prompt
                // would want.
                Text(url.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.nSurface))
        }
    }

    @ViewBuilder
    private func fieldView(_ field: ElicitationRequest.Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(field.title).font(.caption.weight(.medium))
                if field.required {
                    Text("required").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if !field.detail.isEmpty {
                Text(field.detail).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch field.kind {
            case "boolean":
                Toggle(isOn: boolBinding(field)) { Text(field.title) }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(field.title)
            case "select":
                Picker("", selection: stringBinding(field)) {
                    if !field.required { Text("—").tag("") }
                    ForEach(field.options) { Text($0.label).tag($0.value) }
                }
                .labelsHidden().pickerStyle(.menu)
                .accessibilityLabel(field.title)
            case "multiSelect":
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(field.options) { option in
                        Toggle(isOn: multiBinding(field, option.value)) { Text(option.label).font(.caption) }
                            .toggleStyle(.checkbox)
                    }
                }
            default:
                TextField(placeholder(field), text: stringBinding(field))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(field.title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholder(_ field: ElicitationRequest.Field) -> String {
        switch field.format {
        case "email": return "name@example.com"
        case "uri": return "https://example.com"
        case "date": return "YYYY-MM-DD"
        case "date-time": return "YYYY-MM-DDTHH:MM:SSZ"
        default: return field.kind == "number" ? "Number" : ""
        }
    }

    // MARK: state

    private func seedDefaults() {
        for field in request.fields {
            switch field.kind {
            case "boolean": bools[field.name] = field.defaultBool
            case "multiSelect": multi[field.name] = Set(field.defaultStrings)
            default: strings[field.name] = field.defaultString
            }
        }
    }

    private func stringBinding(_ field: ElicitationRequest.Field) -> Binding<String> {
        Binding(get: { strings[field.name] ?? "" }, set: { strings[field.name] = $0 })
    }
    private func boolBinding(_ field: ElicitationRequest.Field) -> Binding<Bool> {
        Binding(get: { bools[field.name] ?? false }, set: { bools[field.name] = $0 })
    }
    private func multiBinding(_ field: ElicitationRequest.Field, _ value: String) -> Binding<Bool> {
        Binding(
            get: { multi[field.name]?.contains(value) ?? false },
            set: { on in
                var set = multi[field.name] ?? []
                if on { set.insert(value) } else { set.remove(value) }
                multi[field.name] = set
            })
    }

    /// Send stays disabled until every required field has a usable answer. Better a greyed button
    /// than a server rejecting a form the app let you submit.
    private var isComplete: Bool {
        request.fields.allSatisfy { field in
            guard field.required else { return true }
            switch field.kind {
            case "boolean": return true
            case "multiSelect": return !(multi[field.name] ?? []).isEmpty
            case "number":
                let text = (strings[field.name] ?? "").trimmingCharacters(in: .whitespaces)
                return Double(text) != nil
            default:
                return !(strings[field.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            }
        }
    }

    private var sheetHeight: CGFloat {
        switch request.mode {
        case "confirm": return 220
        case "url": return 280
        default: return min(620, 200 + CGFloat(request.fields.count) * 76)
        }
    }

    private func respond(_ action: String) {
        var answers: [String: Any] = [:]
        if action == "accept" {
            for field in request.fields {
                switch field.kind {
                case "boolean": answers[field.name] = bools[field.name] ?? false
                case "multiSelect": answers[field.name] = Array(multi[field.name] ?? [])
                default: answers[field.name] = strings[field.name] ?? ""
                }
            }
        }
        onRespond(action, answers)
    }
}
