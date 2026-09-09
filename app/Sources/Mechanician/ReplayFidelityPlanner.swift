import Foundation

/// A stable, machine-readable reason why today's dialog-only provider replay cannot represent the
/// complete durable Conversation. Raw values are part of the portable diagnostic contract; the
/// `unknown` case lets an older reader retain a category introduced by a newer producer.
enum ReplayDegradationCategory: Hashable, Codable {
    case withdrawnOrSupersededContent
    case systemContext
    case providerReview
    case toolLifecycle
    case interactionLifecycle
    case compaction
    case historyReduction
    case agentLifecycle
    case workflowLifecycle
    case artifactContent
    case media
    case unknown(String)

    var rawValue: String {
        switch self {
        case .withdrawnOrSupersededContent: "withdrawn-or-superseded-content-omitted"
        case .systemContext: "system-context-omitted"
        case .providerReview: "provider-review-omitted"
        case .toolLifecycle: "tool-lifecycle-omitted"
        case .interactionLifecycle: "interaction-lifecycle-omitted"
        case .compaction: "compaction-omitted"
        case .historyReduction: "history-reduction-omitted"
        case .agentLifecycle: "agent-lifecycle-omitted"
        case .workflowLifecycle: "workflow-lifecycle-omitted"
        case .artifactContent: "artifact-content-omitted"
        case .media: "media-omitted"
        case .unknown(let rawValue): rawValue
        }
    }

    private var sortKey: (Int, String) {
        let index = switch self {
        case .withdrawnOrSupersededContent: 0
        case .systemContext: 1
        case .providerReview: 2
        case .toolLifecycle: 3
        case .interactionLifecycle: 4
        case .compaction: 5
        case .historyReduction: 6
        case .agentLifecycle: 7
        case .workflowLifecycle: 8
        case .artifactContent: 9
        case .media: 10
        // 11 is retired (the recall category the Memory subsystem produced). Never reuse it: the
        // ordinal is the diagnostic's sort position, and renumbering reorders recorded output.
        case .unknown: 12
        }
        return (index, rawValue)
    }

    static func ordered(_ categories: some Sequence<Self>) -> [Self] {
        Set(categories).sorted {
            if $0.sortKey.0 != $1.sortKey.0 { return $0.sortKey.0 < $1.sortKey.0 }
            return $0.sortKey.1 < $1.sortKey.1
        }
    }

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = switch rawValue {
        case "withdrawn-or-superseded-content-omitted": .withdrawnOrSupersededContent
        case "system-context-omitted": .systemContext
        case "provider-review-omitted": .providerReview
        case "tool-lifecycle-omitted": .toolLifecycle
        case "interaction-lifecycle-omitted": .interactionLifecycle
        case "compaction-omitted": .compaction
        case "history-reduction-omitted": .historyReduction
        case "agent-lifecycle-omitted": .agentLifecycle
        case "workflow-lifecycle-omitted": .workflowLifecycle
        case "artifact-content-omitted": .artifactContent
        case "media-omitted": .media
        default: .unknown(rawValue)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The provider payload is intentionally the same role/text dictionary shape AgentBridge sends
/// today. Fidelity information travels beside it and can never alter provider input accidentally.
struct ReplayFidelityPlan: Equatable, Codable {
    let providerPayload: [[String: String]]
    let degradationCategories: [ReplayDegradationCategory]

    var isEquivalent: Bool { degradationCategories.isEmpty }

    init(
        providerPayload: [[String: String]],
        degradationCategories: [ReplayDegradationCategory]
    ) {
        self.providerPayload = providerPayload
        self.degradationCategories = ReplayDegradationCategory.ordered(
            degradationCategories)
    }

    private enum CodingKeys: String, CodingKey {
        case providerPayload, degradationCategories
    }

    /// Normalize an imported diagnostic list too. Producers may repeat categories or write them in
    /// discovery order; consumers should see the same stable contract as a locally generated plan.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            providerPayload: try container.decode(
                [[String: String]].self, forKey: .providerPayload),
            degradationCategories: try container.decodeIfPresent(
                [ReplayDegradationCategory].self, forKey: .degradationCategories) ?? [])
    }
}

/// Process-local lifetime policy for the fresh-session disclosure.
///
/// A provider-acknowledged fresh replay earns one notice. Once that replacement session proves it
/// can resume on a later acknowledged Conversation turn, the old notice is no longer a current
/// transition and must disappear. Review turns do not own Conversation continuation state and
/// therefore leave any existing notice alone.
enum ReplayContinuationNoticeLifecycle {
    static func categoriesAfterAcknowledgement(
        existing: [ReplayDegradationCategory]?,
        freshReplay: [ReplayDegradationCategory]?,
        isConversationTurn: Bool
    ) -> [ReplayDegradationCategory]? {
        guard isConversationTurn else { return existing }
        return freshReplay.map(ReplayDegradationCategory.ordered)
    }
}

/// Pure projection of a durable Conversation into today's provider replay plus an honest account
/// of durable facts that projection leaves behind. No store, provider session or UI state is read.
enum ReplayFidelityPlanner {
    /// Project an explicit retained-history slice while still classifying the other durable fact
    /// classes owned by its Conversation. Retry/fork paths use this overload so diagnostics stay
    /// beside the exact messages already selected by the existing replay machinery.
    static func plan(
        for conversation: Conversation,
        replaying messages: [TranscriptEntry],
        projectUserText: (String) -> String = { $0 }
    ) -> ReplayFidelityPlan {
        var replaySource = conversation
        replaySource.messages = messages
        let payload = plan(
            for: replaySource,
            projectUserText: projectUserText).providerPayload
        return ReplayFidelityPlan(
            providerPayload: payload,
            degradationCategories: degradationCategories(for: conversation))
    }

    /// Build a plan for a Conversation. `projectUserText` is the existing final-boundary attachment
    /// expansion seam: callers that need provider-byte equivalence pass the same transformation
    /// used for an ordinary user prompt; tests and format tools may leave it as identity.
    static func plan(
        for conversation: Conversation,
        projectUserText: (String) -> String = { $0 }
    ) -> ReplayFidelityPlan {
        let payload = conversation.messages.compactMap { entry -> [String: String]? in
            guard isReplayable(entry) else { return nil }
            switch entry.kind {
            case .user:
                return ["role": "user", "text": projectUserText(entry.text)]
            case .assistant:
                return ["role": "assistant", "text": entry.text]
            default:
                return nil
            }
        }

        return ReplayFidelityPlan(
            providerPayload: payload,
            degradationCategories: degradationCategories(for: conversation))
    }

    /// This predicate deliberately mirrors the current AgentBridge replay boundary. In particular,
    /// delivered and sent-next guidance are provider history; queued, sending and cancelled rows
    /// are not. Empty dialog is retained, and durable array order is never re-sorted by timestamp.
    static func isReplayable(_ entry: TranscriptEntry) -> Bool {
        guard !entry.isSuperseded else { return false }
        switch entry.kind {
        case .user:
            return entry.guidanceState != .queued
                && entry.guidanceState != .sending
                && entry.guidanceState != .cancelled
        case .assistant:
            return true
        default:
            return false
        }
    }

    private static func degradationCategories(
        for conversation: Conversation
    ) -> [ReplayDegradationCategory] {
        var categories = Set<ReplayDegradationCategory>()

        for entry in conversation.messages {
            if entry.isSuperseded || entry.guidanceState == .cancelled {
                categories.insert(.withdrawnOrSupersededContent)
            }
            if entry.imagePaths?.isEmpty == false || entry.toolImage != nil {
                categories.insert(.media)
            }

            switch entry.kind {
            case .system:
                // A Help consultation is an audit receipt for a provider tool result, not omitted
                // provider context. Older builds still render its text as an ordinary system row.
                if entry.helpConsultationReceipt != true {
                    categories.insert(.systemContext)
                }
            case .review:
                categories.insert(.providerReview)
            case .tool:
                categories.insert(.toolLifecycle)
            case .permission, .question:
                categories.insert(.interactionLifecycle)
            case .compaction:
                categories.insert(.compaction)
            case .user, .assistant:
                break
            }
        }

        if !conversation.subagents.isEmpty || !conversation.agentActivity.isEmpty {
            categories.insert(.agentLifecycle)
        }
        if !conversation.workflowRuns.isEmpty {
            categories.insert(.workflowLifecycle)
        }
        if !conversation.artifacts.isEmpty {
            categories.insert(.artifactContent)
        }

        for record in conversation.agentActivity {
            if record.kind == .tool { categories.insert(.toolLifecycle) }
            if record.kind == .compaction { categories.insert(.compaction) }
            if record.contextEventKind == .historyReduction {
                categories.insert(.historyReduction)
            }
        }

        for subagent in conversation.subagents.values where !subagent.toolEvents.isEmpty {
            categories.insert(.toolLifecycle)
        }
        for run in conversation.workflowRuns.values
        where run.agents.values.contains(where: { !$0.toolEvents.isEmpty }) {
            categories.insert(.toolLifecycle)
        }

        return ReplayDegradationCategory.ordered(categories)
    }
}
