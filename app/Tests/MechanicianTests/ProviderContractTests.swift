import XCTest
@testable import Mechanician

/// The seam between agentd's event stream and everything the Agents panel draws.
///
/// Three of this panel's worst defects lived here, and all three were silent:
///
/// - `toolTarget` was declared on `WorkflowUpdate` and read at the far end while the parse line was
///   missing, so every child tool record arrived with no command. Nothing failed to compile.
/// - The producer emitted `"Model call"` while the consumer filtered `"model"`, so the only prose
///   on the trace was a tautology.
/// - Codex reported every child tool as `Bash` with the command discarded upstream.
///
/// `WorkflowUpdate` is parsed by hand from a dictionary, so adding a property does not make it
/// arrive. These tests treat the event shape as a contract and check it end to end.
final class ProviderContractTests: XCTestCase {
    // MARK: - Fixtures

    /// One event carrying a value for every key the parser reads.
    private func fullyPopulatedEvent() -> [String: Any] {
        [
            "phase": "progress",
            "taskId": "thread-1",
            "toolUseId": "call-1",
            "isWorkflowRun": false,
            "workflowName": "review",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "model": "gpt-5.4-mini",
            "description": "inspect the repository",
            "summary": "found 12 matches",
            "resultPreview": "12 matches across 3 files",
            "agentPath": "/root/inspect",
            "parentToolUseId": "call-parent",
            "toolEvent": "Bash",
            "toolEventID": "tool-event-1",
            "providerQuerySequence": 3,
            "toolTarget": "/bin/zsh -lc 'rg -c NSAccessibility app/Sources'",
            "lastToolName": "Bash",
            "status": "completed",
            "outputFile": "/tmp/out.json",
            "error": "",
            "usage": [
                "totalTokens": 1_234,
                "toolUses": 7,
                "durationMs": 4_500,
                "toolUsesObserved": true,
                "inputTokens": 1_000,
                "cachedInputTokens": 800,
                "outputTokens": 200,
                "reasoningOutputTokens": 34,
            ] as [String: Any],
            "workflowProgress": [["phase": "Verify"]] as [[String: Any]],
        ]
    }

    // MARK: - The parse is a contract

    /// Every property the update declares must actually be populated from the event.
    ///
    /// This is the test that would have caught the missing `toolTarget` line, and it catches the
    /// next field added without one — the compiler cannot, because a hand-rolled parser that skips
    /// a key is still valid code.
    func testEveryDeclaredFieldIsParsedFromTheEvent() {
        let update = WorkflowUpdate(fullyPopulatedEvent())
        var unparsed: [String] = []
        for child in Mirror(reflecting: update).children {
            guard let label = child.label else { continue }
            let value = Mirror(reflecting: child.value)
            if value.displayStyle == .optional, value.children.isEmpty {
                unparsed.append(label)
            }
        }
        XCTAssertTrue(
            unparsed.isEmpty,
            "these fields are declared but never read out of the event: \(unparsed.joined(separator: ", "))")
    }

    /// A sparse event must not invent values.
    func testAbsentKeysStayAbsent() {
        let update = WorkflowUpdate(["phase": "progress", "taskId": "t"])
        XCTAssertEqual(update.phase, "progress")
        XCTAssertEqual(update.taskId, "t")
        XCTAssertNil(update.toolTarget)
        XCTAssertNil(update.summary)
        XCTAssertNil(update.model)
        XCTAssertNil(update.usage)
        XCTAssertFalse(update.isWorkflowRun)
    }

    // MARK: - Codex: a child's shell call reaches the card

    /// The whole chain for the defect that started this: agentd carries the command, the update
    /// parses it, the subagent stores it, the record keeps it, and the mix names the program.
    func testCodexChildShellCallSurvivesToTheComposition() {
        let event: [String: Any] = [
            "phase": "progress",
            "taskId": "thread-1",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "toolEvent": "Bash",
            "toolTarget": "/bin/zsh -lc 'rg -c NSAccessibility app/Sources'",
        ]
        let update = WorkflowUpdate(event)
        let subs = applySubagentUpdate([:], update)
        let child = subs.values.first

        XCTAssertEqual(child?.toolEvents.count, 1, "the tool call is recorded")
        XCTAssertEqual(
            child?.toolEvents.first?.target,
            "/bin/zsh -lc 'rg -c NSAccessibility app/Sources'",
            "with the command it ran")
        XCTAssertEqual(
            agentToolCompositionName(
                child?.toolEvents.first?.name ?? "",
                target: child?.toolEvents.first?.target),
            "rg",
            "and the mix names the program, not the shell")
    }

    /// Several distinct commands must produce a breakdown rather than one flat bar — the symptom
    /// that made the panel useless on Codex.
    func testAChildsDistinctCommandsProduceABreakdown() {
        let commands = [
            "/bin/zsh -lc 'git log --oneline -3'",
            "/bin/zsh -lc 'git status --short'",
            #"/bin/zsh -lc "find app -name '*.swift'""#,
            "/bin/zsh -lc 'wc -l Package.swift'",
        ]
        var subs: [String: SubagentRun] = [:]
        for command in commands {
            subs = applySubagentUpdate(subs, WorkflowUpdate([
                "phase": "progress",
                "taskId": "thread-1",
                "taskType": "codex_subagent",
                "subagentType": "Codex",
                "toolEvent": "Bash",
                "toolTarget": command,
            ]))
        }
        let names = (subs.values.first?.toolEvents ?? [])
            .map { agentToolCompositionName($0.name, target: $0.target) }
        XCTAssertEqual(names, ["git", "git", "find", "wc"])
        XCTAssertGreaterThan(
            Set(names).count, 1,
            "a provider that runs everything through a shell still yields a real breakdown")
    }

    // MARK: - Producer and consumer agree on strings

    /// The trace filters uninformative model labels by exact string. The producer's own wording has
    /// to be in that set, or the chart labels a blue bar with the word for "blue bar".
    func testProducerWordingIsCoveredByTheUninformativeFilter() {
        // These are the strings AgentBridge stamps onto a model state record.
        for wording in ["Model call", "model call", "Responding", "Working"] {
            let span = agentActivityTraceSpans(
                [
                    .state(.model, turnID: "t", detail: wording,
                           at: Date(timeIntervalSince1970: 0)),
                    .state(.completed, turnID: "t", at: Date(timeIntervalSince1970: 4)),
                ],
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: 4))
                .first { !$0.phase.isTerminal }
            XCTAssertEqual(
                span?.title, "",
                "\"\(wording)\" restates the mark and must not be drawn on it")
        }
    }

    /// A genuinely informative detail still reaches the bar.
    func testDistinctiveModelDetailIsKept() {
        let span = agentActivityTraceSpans(
            [
                .state(.model, turnID: "t", detail: "Reasoning",
                       at: Date(timeIntervalSince1970: 0)),
                .state(.completed, turnID: "t", at: Date(timeIntervalSince1970: 4)),
            ],
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 4))
            .first { !$0.phase.isTerminal }
        XCTAssertEqual(span?.title, "Reasoning")
    }

    // MARK: - A child's activity reaches its lane and its card

    /// An update stream for one child must produce records the panel can actually find, under the
    /// identity the card is keyed by.
    func testChildActivityIsReachableUnderTheCardsIdentity() {
        var subs = applySubagentUpdate([:], WorkflowUpdate([
            "phase": "started",
            "taskId": "call-1",
            "toolUseId": "call-1",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "description": "count files",
        ]))
        // The provider later reconciles the child onto its durable thread id.
        subs = applySubagentUpdate(subs, WorkflowUpdate([
            "phase": "progress",
            "taskId": "thread-1",
            "toolUseId": "call-1",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "toolEvent": "Bash",
            "toolTarget": "/bin/zsh -lc 'git status'",
        ]))

        let aliases = agentActivityAliases(subagents: subs)
        guard let child = subs.values.first else { return XCTFail("no child recorded") }
        let records: [AgentActivityRecord] = child.toolEvents.map {
            .tool($0.name, turnID: "t",
                  agentID: AgentActivityIdentity.subagent(child.taskId ?? child.key),
                  target: $0.target, at: $0.at)
        }
        let index = AgentActivityLedgerIndex(records, aliases: aliases)
        let mix = index.toolComposition(agentID: AgentActivityIdentity.subagent(child.key))
        XCTAssertEqual(
            mix.map(\.name), ["git"],
            "the card finds the work no matter which identity the provider used")
    }
}

/// Fields that are declared, read by the UI, and never once populated in practice.
///
/// `lane.detail` was constructed as a literal `nil` for as long as it existed; `toolTarget` was nil
/// on 278 consecutive records. Both were invisible because an empty field renders exactly like an
/// agent that had nothing to report. This walks a realistic stream and names anything that is
/// always absent — which is either dead or broken, and worth knowing which.
final class ActivityFieldCoverageTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 300_000)

    /// Content-free harness observations exercising each optional refinement retained by the
    /// production wire decoder. Keeping these as wire events (instead of mutating records in the
    /// test) makes the coverage assertion prove that the fields are actually reachable.
    private func representativeHarnessRecords() -> [AgentActivityRecord] {
        let events: [[String: Any]] = [
            [
                "type": "harness_observation",
                "id": "t",
                "lane": "codex",
                "event": "phase",
                "phase": "terminal",
                "provenance": "mechanician_clock",
                "scope": "turn",
                "aggregation": "point",
                "elapsedMs": NSNumber(value: 8_000),
                "warm": NSNumber(value: true),
                "threadAction": "resume",
                "outputKind": "text",
                "terminalOutcome": "completed",
            ],
            [
                "type": "harness_observation",
                "id": "t",
                "lane": "claude",
                "event": "result",
                "provenance": "provider_report",
                "scope": "agent_tree",
                "aggregation": "final",
                "providerQuerySequence": NSNumber(value: 2),
                "durationMs": NSNumber(value: 7_500),
                "apiDurationMs": NSNumber(value: 7_000),
                "timeToFirstTokenMs": NSNumber(value: 400),
                "timeToFirstOutputMs": NSNumber(value: 500),
                "streamTimeToFirstOutputMs": NSNumber(value: 300),
                "timeToRequestMs": NSNumber(value: 100),
                "timeToRequestFromSpawnMs": NSNumber(value: 75),
                "inputTokens": NSNumber(value: 9_000),
                "uncachedInputTokens": NSNumber(value: 1_500),
                "cacheReadInputTokens": NSNumber(value: 7_000),
                "cacheWriteInputTokens": NSNumber(value: 500),
                "outputTokens": NSNumber(value: 300),
                "reasoningOutputTokens": NSNumber(value: 40),
                "totalTokens": NSNumber(value: 9_340),
            ],
            [
                "type": "harness_observation",
                "id": "t",
                "lane": "codex",
                "event": "retry",
                "provenance": "provider_report",
                "scope": "request",
                "aggregation": "delta",
                "retryDisposition": "scheduled",
                "retryAttempt": NSNumber(value: 2),
                "retryAttempts": NSNumber(value: 2),
                "retryMaxAttempts": NSNumber(value: 3),
                "retryDelayMs": NSNumber(value: 250),
                "willContinue": NSNumber(value: true),
                "errorKind": "connection",
                "httpStatusCode": NSNumber(value: 503),
            ],
            [
                "type": "harness_observation",
                "id": "t",
                "lane": "codex",
                "event": "model_rerouted",
                "provenance": "provider_report",
                "originalModelID": "gpt-original",
                "model": "gpt-rerouted",
                "rerouteReason": "capacity",
            ],
            [
                "type": "harness_observation",
                "id": "t",
                "lane": "codex",
                "event": "model_safety",
                "provenance": "provider_report",
                "safetyOutcome": "buffered",
                "safetyReasons": ["safety"],
                "safetyUseCases": ["coding"],
                "fasterModel": "gpt-fast",
                "showBuffering": NSNumber(value: true),
            ],
            [
                "type": "harness_observation",
                "id": "t",
                "lane": "codex",
                "event": "model_verification",
                "provenance": "provider_report",
                "modelVerifications": ["trusted_access"],
            ],
            [
                "type": "harness_observation",
                "id": "t",
                "lane": "codex",
                "event": "tool",
                "provenance": "provider_report",
                "scope": "event",
                "aggregation": "final",
                "toolUseID": "call-1",
                "toolKind": "command",
                "toolOutcome": "success",
                "toolDurationMs": NSNumber(value: 800),
                "toolWaitDurationMs": NSNumber(value: 100),
                "toolExecutionDurationMs": NSNumber(value: 700),
            ],
            [
                "type": "harness_observation",
                "id": "t",
                "lane": "claude",
                "event": "context",
                "provenance": "provider_report",
                "scope": "thread",
                "aggregation": "snapshot",
                "contextTokens": NSNumber(value: 42_000),
                "contextWindow": NSNumber(value: 200_000),
                "contextUsableWindow": NSNumber(value: 180_000),
                "contextRawWindowTokens": NSNumber(value: 200_000),
                "contextComposition": ["messages": NSNumber(value: 40_000)],
            ],
            [
                "type": "harness_observation",
                "id": "t",
                "lane": "claude",
                "event": "compaction",
                "provenance": "provider_report",
                "scope": "thread",
                "aggregation": "point",
                "compactionTrigger": "auto",
                "compactionPreTokens": NSNumber(value: 180_000),
                "compactionPostTokens": NSNumber(value: 38_000),
                "compactionDurationMs": NSNumber(value: 125),
                "compactionSequence": NSNumber(value: 1),
            ],
        ]
        return events.flatMap {
            agentHarnessActivityRecords(from: $0, receivedAt: start)
        }
    }

    /// A stream exercising every producer path the panel draws from.
    private func representativeRecords() -> [AgentActivityRecord] {
        let child = AgentActivityIdentity.subagent("c1")
        var capturedModelState = AgentActivityRecord.state(
            .model, turnID: "t", detail: "Reasoning", at: start)
        // AgentBridge stamps records after the semantic factory returns because the record-local
        // allocator belongs to ConversationStore, not to these provider-neutral constructors.
        capturedModelState.captureOrdinal = 1
        let reduction = AgentActivityRecord.historyReduction(
            turnID: "t",
            omittedMessages: 3,
            shortenedMessages: 1,
            reason: "context_compaction_failed",
            at: start.addingTimeInterval(4.5))!
        // A refusal the user never saw a prompt for. Present here so the coverage assertion below
        // keeps proving that every field the panel reads is produced by some real path, which is
        // the same discipline FR-224 exists to enforce on the daemon side.
        let withheld = AgentActivityRecord.subtraction(
            turnID: "t",
            subject: "tool",
            reason: "plan_mode_readonly",
            names: ["ReportFindings"],
            count: 1,
            at: start.addingTimeInterval(4.7))!
        return [
            capturedModelState,
            .initialPrompt("Inspect this workspace.", turnID: "t", at: start),
            .tokens(turnID: "t", input: 9_000, cachedInput: 7_000, output: 300,
                    reasoningOutput: 40, total: 9_340, at: start.addingTimeInterval(1)),
            .state(.tool, turnID: "t", detail: "Bash", at: start.addingTimeInterval(2)),
            .tool("Bash", turnID: "t", agentID: AgentActivityIdentity.root,
                  target: "/bin/zsh -lc 'git status'", at: start.addingTimeInterval(2)),
            .context(turnID: "t", tokens: 42_000, window: 200_000,
                     at: start.addingTimeInterval(3)),
            .compaction(turnID: "t", trigger: "auto", preTokens: 180_000, postTokens: 38_000,
                        at: start.addingTimeInterval(4)),
            reduction,
            withheld,
            .interjection("wait", disposition: .delivered, turnID: "t",
                          at: start.addingTimeInterval(5)),
            .state(.model, turnID: "t", agentID: child, agentLabel: "A1",
                   at: start.addingTimeInterval(2)),
            .state(.completed, turnID: "t", agentID: child, at: start.addingTimeInterval(6)),
            .state(.model, turnID: "t", agentID: child, agentLabel: "A1",
                   startsNewLifecycleGeneration: true,
                   at: start.addingTimeInterval(6.25)),
            .state(.completed, turnID: "t", agentID: child,
                   at: start.addingTimeInterval(6.5)),
            .state(.completed, turnID: "t", at: start.addingTimeInterval(8)),
        ] + representativeHarnessRecords()
    }

    /// Every optional the panel reads is populated by at least one record in a realistic stream.
    func testNoFieldIsAlwaysEmpty() {
        let records = representativeRecords()
        var everSet: Set<String> = []
        var everSeen: Set<String> = []
        for record in records {
            for child in Mirror(reflecting: record).children {
                guard let label = child.label else { continue }
                everSeen.insert(label)
                let value = Mirror(reflecting: child.value)
                let isEmptyOptional = value.displayStyle == .optional && value.children.isEmpty
                if !isEmptyOptional { everSet.insert(label) }
            }
        }
        // `compactionError` is genuinely absent unless a compaction fails, so it is exempt.
        let exempt: Set<String> = ["compactionError", "providerAccess", "modelID"]
        let alwaysEmpty = everSeen.subtracting(everSet).subtracting(exempt)
        XCTAssertTrue(
            alwaysEmpty.isEmpty,
            "never populated by any producer path: \(alwaysEmpty.sorted().joined(separator: ", "))")
    }

    /// The lane the panel builds from that stream must carry its own task, not a hardcoded nil.
    func testLaneCarriesEveryFieldTheGutterDraws() throws {
        let child = AgentActivityIdentity.subagent("c1")
        let summary = AgentActivityTurnSummary(
            id: "t", startedAt: start, endedAt: start.addingTimeInterval(8),
            providerAccess: nil, modelID: nil, isTerminal: true,
            inputTokens: 9_000, cachedInputTokens: 7_000, outputTokens: 300,
            reasoningOutputTokens: 40, aggregateOnlyTokens: 0)
        let model = AppKitAgentActivityRenderModel()
        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: representativeRecords(),
                summary: summary,
                aliases: [:],
                labels: [child: "A1 · worker"],
                details: [child: "count every Swift file"]),
            now: summary.endedAt)

        let lane = try XCTUnwrap(model.lanes.first { $0.id == child })
        XCTAssertFalse(lane.label.isEmpty, "the gutter draws a name")
        XCTAssertNotNil(lane.detail, "and the task behind it")
        XCTAssertFalse(lane.records.isEmpty)

        let root = try XCTUnwrap(model.lanes.first { $0.id == AgentActivityIdentity.root })
        XCTAssertFalse(root.usage.isEmpty, "the gutter draws processed tokens")
        XCTAssertFalse(model.globalEvents.isEmpty, "the EVENTS rail has marks to draw")
        XCTAssertFalse(model.contextSeries.samples.isEmpty, "context pressure has samples")
        XCTAssertGreaterThan(model.contextSeries.scaleMaximum, 0)
    }
}
