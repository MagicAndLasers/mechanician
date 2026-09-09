import XCTest
@testable import Mechanician

final class AgentStepInsightTests: XCTestCase {
    private let agent = AgentActivityIdentity.subagent("a1")
    private let other = AgentActivityIdentity.subagent("a2")
    private let start = Date(timeIntervalSince1970: 1_000)

    private func at(_ offset: TimeInterval) -> Date { start.addingTimeInterval(offset) }

    func testCurrentStepNamesTheToolAndWhatItActedOn() {
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "t", agentID: agent, detail: "Responding", at: at(0)),
            .state(.tool, turnID: "t", agentID: agent, detail: "Read", at: at(10)),
            .tool("Read", turnID: "t", agentID: agent, target: "Mechanician/AgentBridge.swift",
                  at: at(10)),
        ]

        let step = agentCurrentStep(records, agentID: agent, now: at(43))
        XCTAssertEqual(step?.phase, .tool)
        XCTAssertEqual(step?.label, "Read")
        XCTAssertEqual(step?.target, "Mechanician/AgentBridge.swift")
        // The figure the card could not previously show: time in THIS step, not total elapsed.
        XCTAssertEqual(step?.duration, 33)
    }

    func testCurrentStepIgnoresOtherAgentsAndFallsBackToThePhase() {
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "t", agentID: agent, detail: "Reasoning", at: at(0)),
            .state(.tool, turnID: "t", agentID: other, detail: "Bash", at: at(30)),
            .tool("Bash", turnID: "t", agentID: other, target: "swift build", at: at(30)),
        ]

        let mine = agentCurrentStep(records, agentID: agent, now: at(40))
        XCTAssertEqual(mine?.label, "Reasoning")
        XCTAssertNil(mine?.target, "a model step has no tool target")

        let theirs = agentCurrentStep(records, agentID: other, now: at(40))
        XCTAssertEqual(theirs?.label, "Bash")
        XCTAssertEqual(theirs?.target, "swift build")
    }

    func testCurrentStepIsNilWhenTheAgentHasNoStateYet() {
        XCTAssertNil(agentCurrentStep([], agentID: agent))
    }

    /// The root summary row reads the same functions the delegated cards do, keyed on the root id.
    /// If root and subagent activity bled together, that row would report a delegated agent's tool
    /// as the conversation's own work — the exact confusion it exists to remove.
    func testRootActivityIsTrackedSeparatelyFromItsDelegatedAgents() {
        let root = AgentActivityIdentity.root
        let records: [AgentActivityRecord] = [
            .state(.tool, turnID: "t", agentID: root, detail: "Agent", at: at(0)),
            .tool("Agent", turnID: "t", agentID: root, target: "Explore ×2", at: at(0)),
            .state(.tool, turnID: "t", agentID: agent, detail: "Bash", at: at(5)),
            .tool("Bash", turnID: "t", agentID: agent, target: "swift build", at: at(5)),
            .tool("Read", turnID: "t", agentID: agent, at: at(6)),
        ]

        let rootStep = agentCurrentStep(records, agentID: root, now: at(9))
        XCTAssertEqual(rootStep?.label, "Agent")
        XCTAssertEqual(rootStep?.target, "Explore ×2")
        XCTAssertEqual(rootStep?.duration, 9, "the root's step is not ended by a child's step")

        XCTAssertEqual(agentToolComposition(records, agentID: root).map(\.name), ["Delegating"])
        // `swift`, not `Bash`: the breakdown names the program the shell actually ran.
        XCTAssertEqual(agentToolComposition(records, agentID: agent).map(\.name), ["Read", "swift"])
    }

    func testStallIsJudgedAgainstTheAgentsOwnPaceNotAFixedThreshold() {
        // Ten quick 2-second steps, then one that has run for five minutes.
        var records: [AgentActivityRecord] = (0..<10).map { index in
            .state(.tool, turnID: "t", agentID: agent, detail: "Read \(index)",
                   at: at(Double(index) * 2))
        }
        records.append(.state(.tool, turnID: "t", agentID: agent, detail: "Bash", at: at(20)))

        XCTAssertTrue(agentStepIsStalled(records, agentID: agent, now: at(320)))
        // The very same elapsed time is unremarkable a few seconds in.
        XCTAssertFalse(agentStepIsStalled(records, agentID: agent, now: at(24)))
    }

    func testASlowAgentIsNotFlaggedForWorkingAtItsNormalPace() {
        // Every step takes four minutes; the current one is no different.
        var records: [AgentActivityRecord] = (0..<10).map { index in
            .state(.tool, turnID: "t", agentID: agent, detail: "Bash \(index)",
                   at: at(Double(index) * 240))
        }
        records.append(.state(.tool, turnID: "t", agentID: agent, detail: "Bash", at: at(2_400)))

        XCTAssertFalse(
            agentStepIsStalled(records, agentID: agent, now: at(2_640)),
            "a fixed threshold would have cried wolf on every step of this agent")
    }

    func testStallNeedsEnoughHistoryAndNeverFiresOnAFinishedAgent() {
        let sparse: [AgentActivityRecord] = [
            .state(.tool, turnID: "t", agentID: agent, detail: "Read", at: at(0)),
            .state(.tool, turnID: "t", agentID: agent, detail: "Bash", at: at(1)),
        ]
        XCTAssertFalse(
            agentStepIsStalled(sparse, agentID: agent, now: at(600)),
            "two samples cannot establish a pace")

        var finished: [AgentActivityRecord] = (0..<10).map { index in
            .state(.tool, turnID: "t", agentID: agent, detail: "Read \(index)",
                   at: at(Double(index) * 2))
        }
        finished.append(.state(.completed, turnID: "t", agentID: agent, at: at(20)))
        XCTAssertFalse(
            agentStepIsStalled(finished, agentID: agent, now: at(9_000)),
            "a completed agent is not stalled, however long ago it finished")
    }

    func testToolCompositionRanksByCallCountAndSharesSumToOne() {
        let records: [AgentActivityRecord] =
            (0..<6).map { _ in .tool("Read", turnID: "t", agentID: agent) }
            + (0..<3).map { _ in .tool("Bash", turnID: "t", agentID: agent) }
            + [.tool("Grep", turnID: "t", agentID: agent)]
            + [.tool("Read", turnID: "t", agentID: other)]   // another agent's call must not count

        let composition = agentToolComposition(records, agentID: agent)

        XCTAssertEqual(composition.map(\.name), ["Read", "Bash", "Grep"])
        XCTAssertEqual(composition.map(\.count), [6, 3, 1])
        XCTAssertEqual(composition.reduce(0) { $0 + $1.share }, 1, accuracy: 0.0001)
        XCTAssertEqual(composition[0].share, 0.6, accuracy: 0.0001)
    }

    func testToolCompositionFoldsTheTailInsteadOfDroppingIt() {
        let names = ["A", "B", "C", "D", "E", "F", "G"]
        let records = names.enumerated().flatMap { index, name in
            (0...(names.count - index)).map { _ in
                AgentActivityRecord.tool(name, turnID: "t", agentID: agent)
            }
        }

        let composition = agentToolComposition(records, agentID: agent, limit: 3)

        XCTAssertEqual(composition.count, 4)
        XCTAssertEqual(composition.last?.name, "other")
        // Silently truncating would understate the agent's work; the fold keeps the total honest.
        XCTAssertEqual(
            composition.reduce(0) { $0 + $1.count },
            records.count)
        XCTAssertEqual(composition.reduce(0) { $0 + $1.share }, 1, accuracy: 0.0001)
    }

    func testToolCompositionIsEmptyWhenNoToolsWereUsed() {
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "t", agentID: agent, detail: "Responding"),
        ]
        XCTAssertTrue(agentToolComposition(records, agentID: agent).isEmpty)
    }

    func testToolTargetPicksTheMeaningfulKeyAndStaysBounded() {
        XCTAssertEqual(agentToolTarget(["command": "swift test --filter Activity"]),
                       "swift test --filter Activity")
        // A path is recognizable by its tail; leading directories are noise in a narrow control.
        XCTAssertEqual(agentToolTarget(["file_path": "/Users/x/dev/app/Sources/Mechanician/Foo.swift"]),
                       "Mechanician/Foo.swift")
        XCTAssertEqual(agentToolTarget(["pattern": "func agentCurrentStep"]), "func agentCurrentStep")
        XCTAssertNil(agentToolTarget(["unrelated": 5]))
        XCTAssertNil(agentToolTarget(nil))

        // A write tool's input can carry a whole file body — the card must never grow to fit it.
        let huge = agentToolTarget(["command": String(repeating: "x", count: 5_000)])
        XCTAssertEqual(huge?.count, 73)
        XCTAssertEqual(huge?.hasSuffix("…"), true)

        // Newlines would break the single-line row.
        XCTAssertEqual(agentToolTarget(["command": "one\ntwo"]), "one two")
    }

    func testStepDurationLabelSwitchesToMinutes() {
        XCTAssertEqual(agentStepDurationLabel(9), "9s")
        XCTAssertEqual(agentStepDurationLabel(59), "59s")
        XCTAssertEqual(agentStepDurationLabel(60), "1:00")
        XCTAssertEqual(agentStepDurationLabel(247), "4:07")
        XCTAssertEqual(agentStepDurationLabel(-5), "0s")
    }

    /// The ledger gained `toolTarget`; an older sidecar without it must still decode.
    func testActivityRecordWithoutAToolTargetStillDecodes() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","at":0,"kind":"tool","agentID":"root","detail":"Read"}
        """.utf8)
        let record = try JSONDecoder().decode(AgentActivityRecord.self, from: json)

        XCTAssertEqual(record.detail, "Read")
        XCTAssertNil(record.toolTarget)
        XCTAssertNil(record.startsNewLifecycleGeneration)
    }
}

/// Naming tools in the composition breakdown.
///
/// A provider that runs everything through a shell reports one tool name for every call, so the
/// breakdown collapsed to a single bar reading "Bash 243" — true, and of no use whatsoever.
final class AgentToolCompositionNameTests: XCTestCase {
    func testShellCallsAreNamedByTheProgramTheyRun() {
        XCTAssertEqual(
            agentToolCompositionName("Bash", target: #"/bin/zsh -lc "rg --files -g '*.swift'""#),
            "rg")
        XCTAssertEqual(
            agentToolCompositionName("Bash", target: #"/bin/zsh -lc "git status --short""#),
            "git")
        XCTAssertEqual(
            agentToolCompositionName("Bash", target: "bash -c 'find . -name AGENTS.md'"),
            "find")
        XCTAssertEqual(
            agentToolCompositionName("Bash", target: "sed -n '1,40p' AgentBridge.swift"),
            "sed")
    }

    /// The `cd` prefix a provider adds is scaffolding, not the work.
    func testLeadingDirectoryChangeIsSkipped() {
        XCTAssertEqual(
            agentToolCompositionName("Bash", target: #"/bin/zsh -lc "cd app && swift build""#),
            "swift")
    }

    func testEnvironmentAssignmentsArePassedOver() {
        XCTAssertEqual(
            agentToolCompositionName("Bash", target: "sh -c 'FOO=1 BAR=2 pytest -q'"),
            "pytest")
    }

    func testAbsolutePathsAreReducedToTheProgram() {
        XCTAssertEqual(
            agentToolCompositionName("Bash", target: #"/bin/zsh -lc "/usr/bin/git log""#),
            "git")
    }

    /// A provider that already reports distinct tool names is left completely alone.
    func testNonShellToolsKeepTheirReportedName() {
        XCTAssertEqual(agentToolCompositionName("Read", target: "AgentBridge.swift"), "Read")
        XCTAssertEqual(agentToolCompositionName("Grep", target: "pattern"), "Grep")
        // MCP tools are the exception: they are counted under their server, because individually
        // they fragment the largest activity in a conversation into unreadable pieces.
        XCTAssertEqual(agentToolCompositionName("mcp__computer__ComputerWait", target: nil), "computer")
    }

    func testSharedDisplayProjectionNamesDelegationAsAnAction() {
        XCTAssertEqual(traceToolDisplayName(toolName: "Agent", target: "Explore"), "Delegating")
        XCTAssertEqual(traceToolDisplayName(toolName: "Task", target: "Review"), "Delegating")
        XCTAssertEqual(
            traceToolDisplayName(toolName: "Bash", target: "swift test"),
            "swift")
        XCTAssertEqual(
            traceToolDisplayName(toolName: "Read", target: "File.swift"),
            "Read")
    }

    /// With no command to inspect there is nothing better to say than the tool's own name.
    func testShellWithoutACommandKeepsItsName() {
        XCTAssertEqual(agentToolCompositionName("Bash", target: nil), "Bash")
        XCTAssertEqual(agentToolCompositionName("Bash", target: "   "), "Bash")
    }
}

/// Grouping an MCP server's tools into one family.
///
/// Counted individually they shatter the biggest activity in a conversation into a dozen
/// fragments, each too long to render: a real conversation held nine `mcp__computer__*` entries
/// totalling 75 calls, shown as two truncated rows both reading `mcp__computer__Comput…`.
final class AgentMCPCompositionNameTests: XCTestCase {
    func testMCPToolsAreCountedUnderTheirServer() {
        XCTAssertEqual(agentToolCompositionName("mcp__computer__ComputerClick", target: nil), "computer")
        XCTAssertEqual(agentToolCompositionName("mcp__computer__ComputerKey", target: nil), "computer")
        XCTAssertEqual(agentToolCompositionName("mcp__computer__ComputerScreenshot", target: nil), "computer")
    }

    func testDifferentServersStayApart() {
        XCTAssertEqual(agentToolCompositionName("mcp__artifacts__CreateOrUpdate", target: nil), "artifacts")
        XCTAssertEqual(agentToolCompositionName("mcp__automation__RunAppleScript", target: nil), "automation")
    }

    /// A name that merely starts with the prefix but carries no tool is not an MCP call.
    func testMalformedMCPNamesAreLeftAlone() {
        XCTAssertEqual(agentToolCompositionName("mcp__", target: nil), "mcp__")
        XCTAssertEqual(agentToolCompositionName("mcp__server", target: nil), "mcp__server")
    }

    /// The provider's own semantic tools are already the right granularity.
    func testFirstPartyToolsAreUntouched() {
        XCTAssertEqual(agentToolCompositionName("Read", target: "x.swift"), "Read")
        XCTAssertEqual(agentToolCompositionName("Write", target: "x.swift"), "Write")
        XCTAssertEqual(agentToolCompositionName("Edit", target: "x.swift"), "Edit")
        XCTAssertEqual(agentToolCompositionName("ToolSearch", target: nil), "ToolSearch")
    }
}

/// Shell parsing has to fail safely.
///
/// Commands nest quotes, redirections and subshells in ways a deliberately simple scan will
/// sometimes land in the middle of. Real data produced a fragment like `conversations";`, and
/// labelling a bar with that is worse than falling back to the tool's own name.
final class AgentShellProgramFallbackTests: XCTestCase {
    func testFragmentsThatCannotBeProgramsFallBack() {
        XCTAssertEqual(
            agentToolCompositionName("Bash", target: #"/bin/zsh -lc "for f in *; do echo "$f"; done""#),
            "for",
            "a real keyword is still a plausible label")
        XCTAssertEqual(agentToolCompositionName("Bash", target: #"/bin/zsh -lc "';'""#), "Bash")
        XCTAssertEqual(agentToolCompositionName("Bash", target: #"/bin/zsh -lc "\"\"""#), "Bash")
    }

    func testOrdinaryProgramsStillResolve() {
        XCTAssertEqual(agentToolCompositionName("Bash", target: "sh -c 'python3 -m pytest'"), "python3")
        XCTAssertEqual(agentToolCompositionName("Bash", target: "sh -c 'swift-format --version'"), "swift-format")
    }
}

/// Merging the tool mix so every drawn segment is worth drawing.
///
/// Taking the top N by rank put a quarter of all calls into "other" on a real conversation while
/// drawing slivers for tools used once or twice.
final class AgentCompositionMergeTests: XCTestCase {
    private func records(_ counts: [String: Int]) -> [AgentActivityRecord] {
        var out: [AgentActivityRecord] = []
        var moment = Date(timeIntervalSince1970: 90_000)
        for (name, count) in counts.sorted(by: { $0.key < $1.key }) {
            for _ in 0..<count {
                out.append(.tool(name, turnID: "t", agentID: AgentActivityIdentity.root, at: moment))
                moment = moment.addingTimeInterval(1)
            }
        }
        return out
    }

    func testTinyToolsFoldIntoTheResidue() {
        let mix = agentToolComposition(
            records(["Read": 50, "Bash": 40, "Grep": 2, "Glob": 1, "Edit": 1]),
            agentID: AgentActivityIdentity.root)
        XCTAssertEqual(mix.map(\.name), ["Read", "Bash", "other"])
        XCTAssertEqual(mix.last?.count, 4, "the three tools under the threshold are the residue")
    }

    func testAnEvenMixKeepsItsSegments() {
        let mix = agentToolComposition(
            records(["Read": 10, "Bash": 10, "Grep": 10, "Edit": 10]),
            agentID: AgentActivityIdentity.root)
        XCTAssertEqual(Set(mix.map(\.name)), ["Read", "Bash", "Grep", "Edit"])
        XCTAssertFalse(mix.contains { $0.name == "other" }, "nothing is below the threshold here")
    }

    /// Even a mix so flat that nothing clears the threshold must still name its leader.
    func testTheLeaderSurvivesAFlatMix() {
        var counts: [String: Int] = [:]
        for index in 0..<40 { counts["tool\(index)"] = 1 }
        let mix = agentToolComposition(records(counts), agentID: AgentActivityIdentity.root)
        XCTAssertGreaterThanOrEqual(mix.count, 2)
        XCTAssertEqual(mix.last?.name, "other")
        XCTAssertNotEqual(mix.first?.name, "other", "the bar always names something concrete")
    }

    func testNoToolsMeansNoComposition() {
        XCTAssertTrue(agentToolComposition([], agentID: AgentActivityIdentity.root).isEmpty)
    }
}

/// A card has to find its own agent's activity after the provider reconciles identities.
///
/// A Codex child is first seen under its tool-call id and later reconciled to its thread id, so its
/// activity lands under one identity while its card is keyed by the other. The lookup then returns
/// nothing — and an agent whose activity cannot be found looks exactly like one that did nothing.
final class AgentActivityAliasTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 100_000)

    private func records(under agentID: String) -> [AgentActivityRecord] {
        [
            .state(.tool, turnID: "t", agentID: agentID, detail: "Bash", at: at),
            .tool("Bash", turnID: "t", agentID: agentID,
                  target: "/bin/zsh -lc 'git status'", at: at),
            .tool("Bash", turnID: "t", agentID: agentID,
                  target: "/bin/zsh -lc 'rg -c foo src'", at: at.addingTimeInterval(1)),
        ]
    }

    func testActivityUnderTheProviderIdReachesTheCardsIdentity() {
        let providerID = AgentActivityIdentity.subagent("019f-thread")
        let cardID = AgentActivityIdentity.subagent("call_abc")
        let index = AgentActivityLedgerIndex(
            records(under: providerID),
            aliases: [providerID: cardID])

        XCTAssertEqual(
            Set(index.toolComposition(agentID: cardID).map(\.name)), ["git", "rg"],
            "the card finds the work its agent actually did")
        XCTAssertTrue(
            index.toolComposition(agentID: providerID).isEmpty,
            "and it is attributed to one identity, not counted twice")
    }

    /// Without the mapping the lookup is empty — the bug this guards against.
    func testWithoutTheAliasTheCardFindsNothing() {
        let providerID = AgentActivityIdentity.subagent("019f-thread")
        let cardID = AgentActivityIdentity.subagent("call_abc")
        let index = AgentActivityLedgerIndex(records(under: providerID))
        XCTAssertTrue(index.toolComposition(agentID: cardID).isEmpty)
    }

    /// An agent never reconciled keeps working exactly as before.
    func testUnaliasedActivityIsUnaffected() {
        let cardID = AgentActivityIdentity.subagent("call_abc")
        let index = AgentActivityLedgerIndex(records(under: cardID), aliases: [:])
        XCTAssertEqual(Set(index.toolComposition(agentID: cardID).map(\.name)), ["git", "rg"])
    }

    /// The alias map is part of the cache key: reconciliation changes what the same records mean.
    func testCacheRebuildsWhenTheAliasMapChanges() {
        let providerID = AgentActivityIdentity.subagent("019f-thread")
        let cardID = AgentActivityIdentity.subagent("call_abc")
        let cache = AgentActivityLedgerIndexCache()
        let sample = records(under: providerID)

        _ = cache.index(for: sample)
        XCTAssertEqual(cache.rebuildCount, 1)
        _ = cache.index(for: sample)
        XCTAssertEqual(cache.rebuildCount, 1, "identical input is served from the cache")

        let reconciled = cache.index(for: sample, aliases: [providerID: cardID])
        XCTAssertEqual(cache.rebuildCount, 2, "a new alias map is a new index")
        XCTAssertFalse(reconciled.toolComposition(agentID: cardID).isEmpty)
    }
}

/// The trace and the cards must resolve agent identity the same way.
///
/// They had a copy each, and that is exactly how they came to disagree: the lanes reconciled a
/// child's provisional id to its durable one, the cards did not, and every card lookup silently
/// returned nothing.
final class AgentIdentityAliasSharingTests: XCTestCase {
    private func subagent(key: String, taskId: String?) -> SubagentRun {
        var run = SubagentRun(key: key, subagentType: "Codex", task: "work")
        run.taskId = taskId
        return run
    }

    func testProvisionalAndDurableIdsBothResolveToTheCard() {
        let subs = ["call_1": subagent(key: "call_1", taskId: "thread_1")]
        let aliases = agentActivityAliases(subagents: subs)
        let canonical = AgentActivityIdentity.subagent("call_1")

        XCTAssertEqual(aliases[AgentActivityIdentity.subagent("thread_1")], canonical)
        XCTAssertEqual(aliases[canonical], canonical, "the canonical id maps to itself")
        XCTAssertEqual(aliases[AgentActivityIdentity.root], AgentActivityIdentity.root)
    }

    /// An agent whose provider id never changed must not vanish from the map.
    func testUnreconciledAgentMapsToItself() {
        let subs = ["call_1": subagent(key: "call_1", taskId: "call_1")]
        let aliases = agentActivityAliases(subagents: subs)
        let canonical = AgentActivityIdentity.subagent("call_1")
        XCTAssertEqual(aliases[canonical], canonical)
    }

    /// A workflow agent resolves onto the subagent card that represents it.
    func testWorkflowAgentResolvesToItsSubagent() {
        let subs = ["call_1": subagent(key: "call_1", taskId: "thread_1")]
        var run = WorkflowRun(runKey: "run_1")
        var agent = WorkflowAgent(
            index: 1, label: "verify", phaseIndex: 0, phaseTitle: "Verify", state: .progress)
        agent.agentId = "thread_1"
        run.agents = ["a1": agent]

        let aliases = agentActivityAliases(subagents: subs, workflowRuns: ["run_1": run])
        XCTAssertEqual(
            aliases[AgentActivityIdentity.workflow(runKey: "run_1", agentKey: "a1")],
            AgentActivityIdentity.subagent("call_1"))
    }

    /// Activity recorded under either identity reaches one card, counted once.
    func testActivityUnderEitherIdentityLandsOnOneCard() {
        let subs = ["call_1": subagent(key: "call_1", taskId: "thread_1")]
        let aliases = agentActivityAliases(subagents: subs)
        let records: [AgentActivityRecord] = [
            .tool("Bash", turnID: "t", agentID: AgentActivityIdentity.subagent("thread_1"),
                  target: "/bin/zsh -lc 'git status'"),
            .tool("Bash", turnID: "t", agentID: AgentActivityIdentity.subagent("call_1"),
                  target: "/bin/zsh -lc 'git log'"),
        ]
        let index = AgentActivityLedgerIndex(records, aliases: aliases)
        let mix = index.toolComposition(agentID: AgentActivityIdentity.subagent("call_1"))
        XCTAssertEqual(mix.map(\.name), ["git"])
        XCTAssertEqual(mix.first?.count, 2, "both identities feed the same card, counted once each")
    }
}
