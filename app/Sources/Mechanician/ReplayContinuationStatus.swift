import SwiftUI

enum ReplayContinuationTone: Equatable {
    case equivalent
    case informational
    case warning
    case error
}

/// User-facing language for the durable replay-fidelity diagnostic. The diagnostic deliberately
/// remains exact and machine-readable; this projection explains its consequence without making a
/// routine fresh provider session look like data loss or exposing internal fact-class names.
struct ReplayContinuationPresentation: Equatable {
    let tone: ReplayContinuationTone
    let title: String
    let systemImage: String
    let summary: String
    let detailLabels: [String]
    let footer: String

    init(categories: [ReplayDegradationCategory]) {
        let ordered = ReplayDegradationCategory.ordered(categories)
        detailLabels = Self.uniqueLabels(for: ordered)

        if ordered.isEmpty {
            tone = .equivalent
            title = "Continued in a new session"
            systemImage = "arrow.clockwise"
            summary = "The conversation's active messages and replies were carried over."
            footer = "No known session details need rechecking, and nothing was removed from this Conversation."
        } else if ordered.contains(where: Self.isReplaySourceDivergence) {
            tone = .error
            title = "Couldn't verify the new session's context"
            systemImage = "exclamationmark.octagon"
            summary = "Mechanician started a new provider session, but couldn't verify that its conversation history matched the replay it prepared. Your saved Conversation is unchanged."
            footer = "Don't rely on this session until you retry the last answer or start a new Conversation with the context you need."
        } else if ordered.contains(where: Self.needsAttention) {
            tone = .warning
            title = "Continued in a new session · some earlier context may need rechecking"
            systemImage = "exclamationmark.circle"
            summary = "The conversation's active messages and replies were carried over. Some earlier activity and content details aren't part of the new model session, but remain saved in this Conversation."
            footer = "The new model may need to reopen, recheck, or ask for this context if it becomes relevant."
        } else {
            tone = .informational
            title = "Continued in a new session"
            systemImage = "arrow.clockwise"
            summary = "The conversation's active messages and replies were carried over. Some earlier activity details aren't part of the new model session, but remain saved in this Conversation."
            footer = "No action is usually needed; the new model can recheck prior work if it becomes relevant."
        }
    }

    var helpText: String {
        guard !detailLabels.isEmpty else { return "\(summary) \(footer)" }
        return "\(summary) Details: \(Self.sentenceList(detailLabels)). \(footer)"
    }

    private static func needsAttention(_ category: ReplayDegradationCategory) -> Bool {
        switch category {
        case .providerReview, .historyReduction, .artifactContent, .media, .unknown:
            true
        case .withdrawnOrSupersededContent, .systemContext, .toolLifecycle,
             .interactionLifecycle, .compaction, .agentLifecycle, .workflowLifecycle:
            false
        }
    }

    private static func isReplaySourceDivergence(
        _ category: ReplayDegradationCategory
    ) -> Bool {
        category == .unknown("provider-replay-source-diverged")
    }

    private static func uniqueLabels(
        for categories: [ReplayDegradationCategory]
    ) -> [String] {
        var seen = Set<String>()
        return categories.compactMap { category in
            let label = switch category {
            case .withdrawnOrSupersededContent:
                "withdrawn or replaced content (intentionally excluded)"
            case .systemContext:
                "earlier app notices"
            case .providerReview:
                "previous review results"
            case .toolLifecycle:
                "previous tool activity"
            case .interactionLifecycle:
                "earlier approvals and answers"
            case .compaction:
                "context-management events"
            case .historyReduction:
                "shortened earlier history"
            case .agentLifecycle:
                "previous agent activity"
            case .workflowLifecycle:
                "previous workflow activity"
            case .artifactContent:
                "artifacts and their activity"
            case .media:
                "attachment and image activity"
            case .unknown(let value):
                value == "provider-replay-source-diverged"
                    ? "conversation replay could not be verified"
                    : "other session details"
            }
            return seen.insert(label).inserted ? label : nil
        }
    }

    private static func sentenceList(_ values: [String]) -> String {
        switch values.count {
        case 0: return ""
        case 1: return values[0]
        case 2: return "\(values[0]) and \(values[1])"
        default:
            return values.dropLast().joined(separator: ", ") + ", and " + values.last!
        }
    }
}

/// The status line stays compact and calm; activating it reveals the exact user-oriented details.
/// Keeping the disclosure in the strip preserves the existing no-bounce transcript geometry.
struct ReplayContinuationStatus: View {
    private let presentation: ReplayContinuationPresentation
    @State private var isShowingDetails = false

    init(categories: [ReplayDegradationCategory]) {
        presentation = ReplayContinuationPresentation(categories: categories)
    }

    var body: some View {
        Button {
            isShowingDetails.toggle()
        } label: {
            Label(presentation.title, systemImage: presentation.systemImage)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundColor)
        .help(presentation.helpText)
        .accessibilityLabel(presentation.title)
        .accessibilityHint("Shows continuation details. \(presentation.helpText)")
        .accessibilityIdentifier("replayContinuationStatus")
        .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
            details
        }
    }

    private var foregroundColor: Color {
        switch presentation.tone {
        case .equivalent: .secondary
        case .informational: .nInfoText
        case .warning: .nWarningText
        case .error: .nErrorText
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Continued in a new session", systemImage: presentation.systemImage)
                .font(.headline)
                .foregroundStyle(foregroundColor)
            Text(presentation.summary)
                .fixedSize(horizontal: false, vertical: true)
            if !presentation.detailLabels.isEmpty {
                Text("Earlier session details")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(presentation.detailLabels, id: \.self) { label in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 4))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(label)
                        }
                    }
                }
            }
            Text(presentation.footer)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
    }
}
