import SwiftUI

/// Inline card for an `mcp__ask__Question` prompt. Renders 1–4 questions with selectable
/// options (radio for single-select, checkboxes for multi-select) plus a free-text
/// "Other" field, and reports the collected answers back through `onSubmit`.
///
/// The built-in AskUserQuestion tool can't render in Mechanician's headless SDK setup,
/// so agentd routes questions here instead (see agentd's `ask` MCP server).
struct QuestionCard: View {
    let questions: [AskQuestion]
    let scale: CGFloat
    /// answers: question text -> chosen label(s), comma-joined for multi-select.
    /// other: any free-text the user typed, or nil.
    let onSubmit: (_ answers: [String: String], _ other: String?) -> Void
    let isSubmitting: Bool
    let error: String?

    // Per-question selected option indices (a set to support multiSelect).
    @State private var picks: [Int: Set<Int>] = [:]
    // Per-question free-text ("Other").
    @State private var other: [Int: String] = [:]

    init(
        questions: [AskQuestion],
        scale: CGFloat,
        isSubmitting: Bool = false,
        error: String? = nil,
        onSubmit: @escaping (_ answers: [String: String], _ other: String?) -> Void
    ) {
        self.questions = questions
        self.scale = scale
        self.isSubmitting = isSubmitting
        self.error = error
        self.onSubmit = onSubmit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(Color.nInfoText)
                Text(questions.count == 1 ? "A question for you"
                                          : "\(questions.count) questions for you")
                    .font(.system(size: 13 * scale, weight: .semibold))
            }
            ForEach(Array(questions.enumerated()), id: \.offset) { qi, q in
                questionBlock(qi, q)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(Color.nWarningText)
            }
            HStack {
                Spacer()
                Button { submit() } label: {
                    if isSubmitting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Submitting…")
                        }
                    } else {
                        Text("Submit")
                    }
                }
                    .buttonStyle(PillButtonStyle(kind: .accent))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!allAnswered || isSubmitting)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.nElevated))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.nAccent.opacity(0.4)))
    }

    @ViewBuilder
    private func questionBlock(_ qi: Int, _ q: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !q.header.isEmpty {
                Text(q.header.uppercased())
                    .font(.system(size: 10 * scale, weight: .semibold))
                    .foregroundStyle(Color.nInfoText)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.nAccent.opacity(0.18)))
            }
            Text(q.question).font(.system(size: 13 * scale, weight: .medium))
            if q.multiSelect {
                Text("Select all that apply")
                    .font(.system(size: 10 * scale)).foregroundStyle(.secondary)
            }
            ForEach(Array(q.options.enumerated()), id: \.offset) { oi, opt in
                optionButton(qi, oi, opt, multi: q.multiSelect)
            }
            // Free-text "Other" — the tool contract says the UI supplies this, not the model.
            TextField("Other… (type a custom answer)", text: otherBinding(qi))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12 * scale))
        }
    }

    private func optionButton(_ qi: Int, _ oi: Int, _ opt: AskOption, multi: Bool) -> some View {
        let selected = picks[qi]?.contains(oi) == true
        return Button {
            toggle(qi, oi, multi: multi)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: multi
                      ? (selected ? "checkmark.square.fill" : "square")
                      : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(selected ? Color.nInfoText : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(opt.label).font(.system(size: 12 * scale, weight: .medium))
                    if !opt.description.isEmpty {
                        Text(opt.description)
                            .font(.system(size: 11 * scale)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.nAccent.opacity(0.18) : Color.nSurface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ qi: Int, _ oi: Int, multi: Bool) {
        other[qi] = "" // picking an option clears any free text (they're mutually exclusive)
        var set = picks[qi] ?? []
        if multi {
            if set.contains(oi) { set.remove(oi) } else { set.insert(oi) }
        } else {
            set = [oi]
        }
        picks[qi] = set
    }

    private func otherBinding(_ qi: Int) -> Binding<String> {
        Binding(get: { other[qi] ?? "" },
                set: { v in other[qi] = v; if !v.isEmpty { picks[qi] = [] } })
    }

    private func answered(_ qi: Int) -> Bool {
        !(picks[qi]?.isEmpty ?? true)
            || !(other[qi] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
    private var allAnswered: Bool { questions.indices.allSatisfy { answered($0) } }

    private func submit() {
        guard allAnswered, !isSubmitting else { return }
        var answers: [String: String] = [:]
        var frees: [String] = []
        for (qi, q) in questions.enumerated() {
            let free = (other[qi] ?? "").trimmingCharacters(in: .whitespaces)
            if let sel = picks[qi], !sel.isEmpty {
                let labels = sel.sorted().compactMap {
                    q.options.indices.contains($0) ? q.options[$0].label : nil
                }
                answers[q.question] = labels.joined(separator: ", ")
            } else if !free.isEmpty {
                answers[q.question] = free
                frees.append(free)
            }
        }
        onSubmit(answers, frees.isEmpty ? nil : frees.joined(separator: " · "))
    }
}
