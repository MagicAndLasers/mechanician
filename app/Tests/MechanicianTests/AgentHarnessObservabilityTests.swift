import XCTest
@testable import Mechanician

final class AgentHarnessObservabilityTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 100_000)

    func testLegacyActivityRowDecodesAndRoundTripsWithoutManufacturingHarnessFacts() throws {
        let legacy = Data(#"{"turnID":"legacy","kind":"tokens","inputTokens":0}"#.utf8)
        let record = try JSONDecoder().decode(AgentActivityRecord.self, from: legacy)

        XCTAssertEqual(record.turnID, "legacy")
        XCTAssertEqual(record.inputTokens, 0, "an observed zero survives")
        XCTAssertNil(record.harnessLaneID)
        XCTAssertNil(record.harnessEventKind)
        XCTAssertNil(record.uncachedInputTokens)
        XCTAssertNil(record.cacheWriteInputTokens)
        XCTAssertNil(record.contextComposition)

        let encoded = try JSONEncoder().encode(record)
        let roundTripped = try JSONDecoder().decode(AgentActivityRecord.self, from: encoded)
        XCTAssertEqual(roundTripped, record)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["harnessEventKind"])
        XCTAssertNil(object["cacheWriteInputTokens"])
        XCTAssertNil(
            AgentActivityKind(rawValue: "harness_observation"),
            "harness observations must not add a persisted activity kind")
    }

    func testCurrentHarnessRecordRoundTripsEveryBoundedField() throws {
        var record = AgentActivityRecord.harnessObservation(
            turnID: "turn",
            lane: .claude,
            event: .result,
            provenance: .providerReport,
            at: origin)
        record.measurementScope = .turn
        record.measurementAggregation = .final
        record.providerQuerySequence = 2
        record.durationMs = 900
        record.apiDurationMs = 700
        record.timeToFirstTokenMs = 120
        record.timeToFirstOutputMs = 130
        record.streamTimeToFirstOutputMs = 125
        record.timeToRequestMs = 40
        record.timeToRequestFromSpawnMs = 60
        record.warm = true
        record.threadAction = .resume
        record.outputKind = .text
        record.terminalOutcome = .completed
        record.inputTokens = 1_000
        record.uncachedInputTokens = 0
        record.cachedInputTokens = 800
        record.cacheWriteInputTokens = 200
        record.outputTokens = 100
        record.contextTokens = 900
        record.contextUsableWindowTokens = 1_800
        record.contextRawWindowTokens = 2_000
        record.contextComposition = AgentContextComposition([
            .systemPrompt: 100,
            .messages: 0,
            .free: 900,
        ])
        record.retryDisposition = .recovered
        record.retryAttempt = 2
        record.retryAttempts = 2
        record.retryMaxAttempts = 4
        record.retryDelayMs = 50
        record.retryWillContinue = false
        record.errorKind = "rate_limit"
        record.httpStatusCode = 429
        record.rerouteOriginalModelID = "claude-original"
        record.rerouteModelID = "claude-fallback"
        record.rerouteReason = "availability"
        record.safetyOutcome = .buffered
        record.safetyReasons = ["safety"]
        record.safetyUseCases = ["security"]
        record.modelVerifications = ["trusted_access"]
        record.safetyFasterModelID = "claude-fast"
        record.safetyShowsBufferingUI = true
        record.compactionDurationMs = 80
        record.compactionSequence = 3
        record.toolUseID = "tool-1"
        record.toolKind = .command
        record.toolOutcome = .success
        record.toolDurationMs = 20
        record.toolWaitDurationMs = 3
        record.toolExecutionDurationMs = 17

        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(AgentActivityRecord.self, from: data), record)
    }

    func testFutureAndMalformedOptionalHarnessFieldsDoNotDropTheRecord() throws {
        let json = Data(#"""
        {
          "kind":"context",
          "harnessLaneID":"not a lane",
          "harnessPhase":"future_phase",
          "harnessEventKind":"context",
          "measurementProvenance":"future_source",
          "elapsedMs":"not-a-number",
          "contextComposition":{
            "messages":0,
            "future_private_category":999,
            "memory":-1
          },
          "safetyReasons":["first","second","third","fourth","fifth","sixth","seventh","eighth","ninth"]
        }
        """#.utf8)

        let record = try JSONDecoder().decode(AgentActivityRecord.self, from: json)
        XCTAssertEqual(record.kind, .context)
        XCTAssertNil(record.harnessLaneID)
        XCTAssertNil(record.harnessPhase)
        XCTAssertEqual(record.harnessEventKind, .context)
        XCTAssertNil(record.measurementProvenance)
        XCTAssertNil(record.elapsedMs)
        XCTAssertEqual(record.contextComposition?[.messages], 0)
        XCTAssertNil(record.contextComposition?[.memory])
        XCTAssertEqual(record.safetyReasons, ["other"])
    }

    func testContextCompositionAndTokenFactoryPreserveZeroWhileBoundingValues() {
        let composition = AgentContextComposition([
            .messages: 0,
            .memory: -1,
            .free: Int.max,
        ])
        XCTAssertEqual(composition[.messages], 0)
        XCTAssertNil(composition[.memory])
        XCTAssertEqual(composition[.free], 4_000_000_000)

        let record = AgentActivityRecord.tokens(
            turnID: "turn",
            input: 0,
            uncachedInput: 0,
            cachedInput: nil,
            cacheWriteInput: 0)
        var ledger: [AgentActivityRecord] = []
        appendAgentActivityRecord(record, to: &ledger)
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger[0].inputTokens, 0)
        XCTAssertEqual(ledger[0].uncachedInputTokens, 0)
        XCTAssertEqual(ledger[0].cacheWriteInputTokens, 0)

        let coverage = agentMeasurementCoverage([0, nil, 7])
        XCTAssertEqual(coverage.sampleCount, 3)
        XCTAssertEqual(coverage.observedCount, 2)
        XCTAssertEqual(coverage.explicitZeroCount, 1)
        XCTAssertEqual(coverage.missingCount, 1)
        XCTAssertEqual(coverage.fraction, 2.0 / 3.0)
    }

    func testCompactionBoundaryAndHarnessTimingMergeIntoOneDurableFact() throws {
        var boundary = AgentActivityRecord.compaction(
            turnID: "turn",
            trigger: "auto",
            preTokens: 80,
            postTokens: 30,
            sequence: 2,
            at: origin)
        boundary.captureOrdinal = 10
        var timed = AgentActivityRecord.harnessObservation(
            turnID: "turn",
            lane: .claude,
            event: .compaction,
            provenance: .mechanicianClock,
            at: origin.addingTimeInterval(0.01))
        timed.measurementScope = .event
        timed.measurementAggregation = .final
        timed.compactionTrigger = "auto"
        timed.compactionDurationMs = 25
        timed.compactionSequence = 2

        var boundaryFirst: [AgentActivityRecord] = []
        appendAgentActivityRecord(boundary, to: &boundaryFirst)
        appendAgentActivityRecord(timed, to: &boundaryFirst)
        let merged = try XCTUnwrap(boundaryFirst.first)
        XCTAssertEqual(boundaryFirst.count, 1)
        XCTAssertEqual(merged.id, boundary.id)
        XCTAssertEqual(merged.captureOrdinal, 10)
        XCTAssertEqual(merged.harnessEventKind, .compaction)
        XCTAssertEqual(merged.measurementProvenance, .mechanicianClock)
        XCTAssertEqual(merged.compactionPreTokens, 80)
        XCTAssertEqual(merged.compactionPostTokens, 30)
        XCTAssertEqual(merged.compactionDurationMs, 25)
        XCTAssertEqual(merged.compactionSequence, 2)
        XCTAssertEqual(
            try XCTUnwrap(agentHarnessReliabilityTrend(boundaryFirst).first).compactionCount,
            1)

        var harnessFirst: [AgentActivityRecord] = []
        appendAgentActivityRecord(timed, to: &harnessFirst)
        appendAgentActivityRecord(boundary, to: &harnessFirst)
        XCTAssertEqual(harnessFirst.count, 1)
        XCTAssertEqual(harnessFirst[0].id, timed.id)
        XCTAssertEqual(harnessFirst[0].compactionPreTokens, 80)
        XCTAssertEqual(harnessFirst[0].compactionDurationMs, 25)

        var later = timed
        later.id = UUID()
        later.at = origin.addingTimeInterval(10)
        appendAgentActivityRecord(later, to: &boundaryFirst)
        XCTAssertEqual(
            boundaryFirst.count,
            2,
            "a later compaction must not enrich an earlier unmatched boundary")

        var mismatched = timed
        mismatched.id = UUID()
        mismatched.compactionSequence = 3
        mismatched.at = origin.addingTimeInterval(0.02)
        var sequenceLedger = [boundary]
        appendAgentActivityRecord(mismatched, to: &sequenceLedger)
        XCTAssertEqual(
            sequenceLedger.count,
            2,
            "nearby observations with different provider sequences are distinct compactions")
    }

    func testVisibleToolAndHarnessCompletionMergeInEitherOrderWithoutCrossingAgents() throws {
        let child = AgentActivityIdentity.subagent("child-a")
        let visible = AgentActivityRecord.tool(
            "Bash",
            turnID: "turn",
            agentID: child,
            agentLabel: "Builder",
            target: "swift test",
            toolUseID: "call-1",
            at: origin)
        var completion = AgentActivityRecord.harnessObservation(
            turnID: "turn",
            lane: .codex,
            event: .tool,
            provenance: .providerReport,
            at: origin.addingTimeInterval(2))
        completion.agentID = child
        completion.measurementScope = .event
        completion.measurementAggregation = .final
        completion.toolUseID = "call-1"
        completion.toolKind = .command
        completion.toolOutcome = .success
        completion.toolDurationMs = 1_800
        completion.toolWaitDurationMs = 300
        completion.toolExecutionDurationMs = 1_500

        func assertMerged(
            _ records: [AgentActivityRecord],
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let record = try XCTUnwrap(records.first, file: file, line: line)
            XCTAssertEqual(records.count, 1, file: file, line: line)
            XCTAssertEqual(record.id, visible.id, file: file, line: line)
            XCTAssertEqual(record.at, visible.at, file: file, line: line)
            XCTAssertEqual(record.detail, "Bash", file: file, line: line)
            XCTAssertEqual(record.toolTarget, "swift test", file: file, line: line)
            XCTAssertEqual(record.agentID, child, file: file, line: line)
            XCTAssertEqual(record.harnessEventKind, .tool, file: file, line: line)
            XCTAssertEqual(record.measurementProvenance, .providerReport, file: file, line: line)
            XCTAssertEqual(record.measurementScope, .event, file: file, line: line)
            XCTAssertEqual(record.measurementAggregation, .final, file: file, line: line)
            XCTAssertEqual(record.toolKind, .command, file: file, line: line)
            XCTAssertEqual(record.toolOutcome, .success, file: file, line: line)
            XCTAssertEqual(record.toolDurationMs, 1_800, file: file, line: line)
            XCTAssertEqual(record.toolWaitDurationMs, 300, file: file, line: line)
            XCTAssertEqual(record.toolExecutionDurationMs, 1_500, file: file, line: line)
        }

        var visibleFirst: [AgentActivityRecord] = []
        appendAgentActivityRecord(visible, to: &visibleFirst)
        appendAgentActivityRecord(completion, to: &visibleFirst)
        try assertMerged(visibleFirst)

        var completionFirst: [AgentActivityRecord] = []
        appendAgentActivityRecord(completion, to: &completionFirst)
        appendAgentActivityRecord(visible, to: &completionFirst)
        try assertMerged(completionFirst)

        var otherAgentCompletion = completion
        otherAgentCompletion.id = UUID()
        otherAgentCompletion.agentID = AgentActivityIdentity.subagent("child-b")
        appendAgentActivityRecord(otherAgentCompletion, to: &visibleFirst)
        XCTAssertEqual(visibleFirst.count, 2, "the same provider item id is agent-scoped")

        let reliability = try XCTUnwrap(agentHarnessReliabilityTrend(visibleFirst).first)
        XCTAssertEqual(reliability.toolCallCount, 2)
        XCTAssertEqual(reliability.toolDurationCoverage.observedCount, 2)
    }

    func testAuthoritativeFinalUsageReplacesProvisionalSamplesForTurnTotals() throws {
        var provisional = AgentActivityRecord.tokens(
            turnID: "turn",
            input: 40,
            cachedInput: 30,
            output: 2,
            at: origin.addingTimeInterval(0.2))
        provisional.measurementAggregation = .delta

        var delegated = AgentActivityRecord.tokens(
            turnID: "turn",
            agentID: AgentActivityIdentity.subagent("child"),
            input: 10,
            output: 3,
            at: origin.addingTimeInterval(0.4))
        delegated.measurementAggregation = .delta

        var final = AgentActivityRecord.tokens(
            turnID: "turn",
            input: 100,
            uncachedInput: 20,
            cachedInput: 70,
            cacheWriteInput: 10,
            output: 12,
            at: origin.addingTimeInterval(0.8))
        final.measurementAggregation = .final
        final.measurementProvenance = .providerReport

        let records = [
            AgentActivityRecord.state(.model, turnID: "turn", at: origin),
            provisional,
            delegated,
            final,
            AgentActivityRecord.state(
                .completed, turnID: "turn", at: origin.addingTimeInterval(1)),
        ]
        let effective = agentActivityEffectiveTokenRecords(records)
        XCTAssertEqual(
            effective.filter { $0.kind == .tokens }.map(\.id),
            [delegated.id, final.id],
            "a main-loop final must not erase separately reported delegate usage")

        let tokens = agentActivityTokenBreakdown(records)
        XCTAssertEqual(tokens.input, 110)
        XCTAssertEqual(tokens.cachedInput, 70)
        XCTAssertEqual(tokens.uncachedInput, 20)
        XCTAssertEqual(tokens.cacheWriteInput, 10)
        XCTAssertEqual(tokens.output, 15)

        let summary = try XCTUnwrap(agentActivityTurnSummaries(records).first)
        XCTAssertEqual(summary.inputTokens, 110)
        XCTAssertEqual(summary.cachedInputTokens, 70)
        XCTAssertEqual(summary.uncachedInputTokens, 20)
        XCTAssertEqual(summary.cacheWriteInputTokens, 10)
        XCTAssertEqual(summary.outputTokens, 15)

        let buckets = agentActivityUsageBuckets(
            records,
            start: origin,
            end: origin.addingTimeInterval(1),
            count: 4)
        XCTAssertEqual(buckets.map(\.tokens.input).reduce(0, +), 110)

        var agentTreeFinal = final
        agentTreeFinal.id = UUID()
        agentTreeFinal.measurementScope = .agentTree
        let treeEffective = agentActivityEffectiveTokenRecords([
            provisional, delegated, agentTreeFinal,
        ])
        XCTAssertEqual(
            treeEffective.filter { $0.kind == .tokens }.map(\.id),
            [agentTreeFinal.id],
            "agent-tree totals already include delegated and auxiliary model calls")
    }

    func testFinalUsageReconcilesOnlyItsProviderQuerySequence() {
        func usage(
            _ input: Int,
            sequence: Int,
            aggregation: AgentMeasurementAggregation,
            scope: AgentMeasurementScope = .request,
            at offset: TimeInterval
        ) -> AgentActivityRecord {
            var record = AgentActivityRecord.tokens(
                turnID: "turn", input: input, at: origin.addingTimeInterval(offset))
            record.providerQuerySequence = sequence
            record.measurementScope = scope
            record.measurementAggregation = aggregation
            return record
        }

        let attemptOneDelta = usage(40, sequence: 1, aggregation: .delta, at: 0.1)
        let attemptOneFinal = usage(
            100, sequence: 1, aggregation: .final, scope: .agentTree, at: 0.2)
        let attemptTwoDelta = usage(80, sequence: 2, aggregation: .delta, at: 0.3)
        let attemptTwoFinal = usage(
            200, sequence: 2, aggregation: .final, scope: .agentTree, at: 0.4)
        let interruptedAttempt = usage(30, sequence: 3, aggregation: .delta, at: 0.5)

        let effective = agentActivityEffectiveTokenRecords([
            attemptOneDelta,
            attemptOneFinal,
            attemptTwoDelta,
            attemptTwoFinal,
            interruptedAttempt,
        ])
        XCTAssertEqual(
            effective.map(\.id),
            [attemptOneFinal.id, attemptTwoFinal.id, interruptedAttempt.id])
        XCTAssertEqual(agentActivityTokenBreakdown(effective).input, 330)
    }

    @MainActor
    func testSharedUsageDecoderPreservesCacheComponentsAndMeasurementSemantics() {
        let record = AgentBridge.usageActivityRecord(
            from: [
                "input": 50,
                "inputUncached": 0,
                "cacheRead": 40,
                "cacheWrite": 10,
                "output": 7,
                "provenance": "provider_report",
                "scope": "request",
                "aggregation": "final",
                "providerQuerySequence": 4,
            ],
            turnID: "turn",
            agentID: AgentActivityIdentity.root,
            at: origin)

        XCTAssertEqual(record.inputTokens, 50)
        XCTAssertEqual(record.uncachedInputTokens, 0)
        XCTAssertEqual(record.cachedInputTokens, 40)
        XCTAssertEqual(record.cacheWriteInputTokens, 10)
        XCTAssertEqual(record.outputTokens, 7)
        XCTAssertEqual(record.measurementProvenance, .providerReport)
        XCTAssertEqual(record.measurementScope, .request)
        XCTAssertEqual(record.measurementAggregation, .final)
        XCTAssertEqual(record.providerQuerySequence, 4)
    }

    func testReliabilityTrendUsesExactOutcomesAndReportsPartialCoverage() throws {
        var records: [AgentActivityRecord] = [
            .state(.model, turnID: "first", at: origin),
        ]
        var firstOutput = AgentActivityRecord.harnessObservation(
            turnID: "first", lane: .codex, event: .phase,
            phase: .firstOutput, provenance: .mechanicianClock,
            at: origin.addingTimeInterval(0.12))
        firstOutput.elapsedMs = 120
        records.append(firstOutput)

        var retry = AgentActivityRecord.harnessObservation(
            turnID: "first", lane: .codex, event: .retry,
            provenance: .providerReport, at: origin.addingTimeInterval(0.2))
        retry.retryDisposition = .scheduled
        retry.retryAttempt = 1
        retry.retryDelayMs = 50
        retry.retryWillContinue = true
        records.append(retry)

        var recovered = AgentActivityRecord.harnessObservation(
            turnID: "first", lane: .codex, event: .retryRecovered,
            provenance: .providerReport, at: origin.addingTimeInterval(0.3))
        recovered.retryDisposition = .recovered
        recovered.retryAttempts = 2
        records.append(recovered)

        records.append(AgentActivityRecord.harnessObservation(
            turnID: "first", lane: .codex, event: .modelRerouted,
            provenance: .providerReport, at: origin.addingTimeInterval(0.35)))

        var safety = AgentActivityRecord.harnessObservation(
            turnID: "first", lane: .codex, event: .modelSafety,
            provenance: .providerReport, at: origin.addingTimeInterval(0.36))
        safety.safetyOutcome = .blocked
        records.append(safety)

        records.append(.tool(
            "Bash", turnID: "first", agentID: AgentActivityIdentity.root,
            toolUseID: "tool-1", toolKind: .command, outcome: nil,
            at: origin.addingTimeInterval(0.4)))
        records.append(.tool(
            "Bash", turnID: "first", agentID: AgentActivityIdentity.root,
            toolUseID: "tool-1", toolKind: .command, outcome: .success, durationMs: 0,
            at: origin.addingTimeInterval(0.45)))
        records.append(.tool(
            "MCP", turnID: "first", agentID: AgentActivityIdentity.root,
            toolUseID: "tool-2", toolKind: .mcp, outcome: .error, durationMs: 40,
            at: origin.addingTimeInterval(0.5)))
        records.append(.context(
            turnID: "first", tokens: 50, window: 120, usableWindow: 100,
            at: origin.addingTimeInterval(0.55)))
        records.append(.context(
            turnID: "first", tokens: 80, window: 120, usableWindow: 100,
            composition: AgentContextComposition([.messages: 60, .free: 20]),
            at: origin.addingTimeInterval(0.6)))
        records.append(.compaction(
            turnID: "first", trigger: "auto", preTokens: 80, postTokens: 30,
            durationMs: 25, at: origin.addingTimeInterval(0.7)))

        var result = AgentActivityRecord.harnessObservation(
            turnID: "first", lane: .codex, event: .result,
            provenance: .providerReport, at: origin.addingTimeInterval(0.9))
        result.durationMs = 900
        result.apiDurationMs = 700
        result.timeToFirstTokenMs = 110
        records.append(result)
        records.append(.state(
            .completed, turnID: "first", at: origin.addingTimeInterval(1)))

        let secondStart = origin.addingTimeInterval(10)
        records.append(.state(.model, turnID: "second", at: secondStart))
        var terminalError = AgentActivityRecord.harnessObservation(
            turnID: "second", lane: .codex, event: .retryExhausted,
            provenance: .providerReport, at: secondStart.addingTimeInterval(1))
        terminalError.retryDisposition = .exhausted
        terminalError.retryAttempt = 1
        records.append(terminalError)
        records.append(.state(
            .stopped, turnID: "second", at: secondStart.addingTimeInterval(2)))

        let trend = agentHarnessReliabilityTrend(records)
        XCTAssertEqual(trend.map(\.id), ["first", "second"])
        let first = try XCTUnwrap(trend.first)
        XCTAssertEqual(first.harnessLaneIDs, [.codex])
        XCTAssertEqual(first.terminalOutcome, .completed)
        XCTAssertEqual(first.wallDurationMs, 1_000)
        XCTAssertEqual(first.reportedDurationMs, 900)
        XCTAssertEqual(first.apiDurationMs, 700)
        XCTAssertEqual(first.timeToFirstTokenMs, 110)
        XCTAssertEqual(first.timeToFirstOutputMs, 120)
        XCTAssertEqual(first.retryEventCount, 1)
        XCTAssertEqual(first.retryAttempts, 2)
        XCTAssertEqual(first.recoveredRetryCount, 1)
        XCTAssertEqual(first.observedRetryDelayMs, 50)
        XCTAssertEqual(first.rerouteCount, 1)
        XCTAssertEqual(first.safetyBlockedCount, 1)
        XCTAssertEqual(first.toolCallCount, 2)
        XCTAssertEqual(first.toolFailureCount, 1)
        XCTAssertEqual(first.observedToolDurationMs, 40)
        XCTAssertEqual(first.toolDurationCoverage.explicitZeroCount, 1)
        XCTAssertEqual(first.toolOutcomeCoverage.observedCount, 2)
        XCTAssertEqual(first.compactionCount, 1)
        XCTAssertEqual(first.observedCompactionDurationMs, 25)
        XCTAssertEqual(first.contextPeakTokens, 80)
        XCTAssertEqual(first.contextLimitTokens, 100)
        XCTAssertEqual(first.contextPeakFraction, 0.8)
        XCTAssertEqual(first.contextComposition?[.free], 20)

        let second = try XCTUnwrap(trend.last)
        XCTAssertEqual(second.terminalOutcome, .interrupted)
        XCTAssertEqual(second.retryEventCount, 0)
        XCTAssertEqual(second.exhaustedRetryCount, 1)
        XCTAssertFalse(second.hadRetries)
        XCTAssertNil(second.reportedDurationMs)
        XCTAssertNil(second.timeToFirstOutputMs)

        let rollup = agentHarnessReliabilityRollup(trend)
        XCTAssertEqual(rollup.turnCount, 2)
        XCTAssertEqual(rollup.completedTurnCount, 1)
        XCTAssertEqual(rollup.interruptedTurnCount, 1)
        XCTAssertEqual(rollup.retryTurnCount, 1)
        XCTAssertEqual(rollup.reroutedTurnCount, 1)
        XCTAssertEqual(rollup.toolFailureCount, 1)
        XCTAssertEqual(rollup.reportedDurationCoverage.observedCount, 1)
        XCTAssertEqual(rollup.reportedDurationCoverage.missingCount, 1)
        XCTAssertEqual(rollup.completionRate, 0.5)
    }

    func testStableHarnessLaneCanBeInferredForLegacyAttributedRows() {
        var legacy = AgentActivityRecord.state(.model, turnID: "turn")
        legacy.providerAccess = .claudeVertex
        XCTAssertNil(legacy.harnessLaneID)
        XCTAssertEqual(legacy.resolvedHarnessLaneID, .claude)

        let attributed = AgentActivityRecord.state(.model, turnID: "turn")
            .attributed(to: ModelSelection(
                access: .codexSubscription,
                modelID: "gpt-5.4"))
        XCTAssertEqual(attributed.harnessLaneID, .codex)
    }

    func testHarnessMetricSampleIsContentFreeBoundedAndRoundTrips() throws {
        let sample = try XCTUnwrap(HarnessMetricSample(
            name: "codex.api_request.duration",
            kind: .histogram,
            at: origin,
            unit: .milliseconds,
            harnessLaneID: .codex,
            count: 0,
            sum: 0,
            min: 0,
            max: 0,
            attributes: [
                .model: .string(String(repeating: "m", count: 400)),
                .success: .bool(true),
                .retryAttempt: .number(0),
            ]))
        guard case .string(let model)? = sample.attributes[.model] else {
            return XCTFail("missing bounded model attribute")
        }
        XCTAssertEqual(model.count, 128)
        XCTAssertEqual(sample.count, 0, "an observed zero histogram count survives")
        XCTAssertEqual(sample.harnessLaneID, .codex)

        let encoded = try JSONEncoder().encode(sample)
        XCTAssertEqual(try JSONDecoder().decode(HarnessMetricSample.self, from: encoded), sample)
        XCTAssertNil(HarnessMetricSample(
            name: "prompt text is not a metric name",
            kind: .counter,
            unit: .count,
            value: 1))
        XCTAssertNil(HarnessMetricSample(
            name: "codex.invalid",
            kind: .histogram,
            unit: .count,
            count: 1,
            min: 2,
            max: 1))
    }

    func testHarnessMetricSeriesIdentitySortsAndPreservesTypedDimensions() throws {
        var firstAttributes: [HarnessMetricAttributeKey: HarnessMetricAttributeValue] = [:]
        firstAttributes[.model] = .string("gpt-test")
        firstAttributes[.success] = .bool(true)
        var reversedAttributes: [HarnessMetricAttributeKey: HarnessMetricAttributeValue] = [:]
        reversedAttributes[.success] = .bool(true)
        reversedAttributes[.model] = .string("gpt-test")

        let first = try XCTUnwrap(HarnessMetricSample(
            name: "codex.request.count",
            kind: .counter,
            at: origin,
            unit: .count,
            harnessLaneID: .codex,
            value: 1,
            attributes: firstAttributes))
        let reversed = try XCTUnwrap(HarnessMetricSample(
            name: first.name,
            kind: first.kind,
            at: first.at,
            unit: first.unit,
            harnessLaneID: first.harnessLaneID,
            value: 2,
            attributes: reversedAttributes))
        let stringBoolean = try XCTUnwrap(HarnessMetricSample(
            name: first.name,
            kind: first.kind,
            at: first.at,
            unit: first.unit,
            harnessLaneID: first.harnessLaneID,
            value: 3,
            attributes: [.model: .string("gpt-test"), .success: .string("true")]))

        XCTAssertEqual(first.seriesIdentity, reversed.seriesIdentity)
        XCTAssertNotEqual(first.seriesIdentity, stringBoolean.seriesIdentity)
        XCTAssertEqual(first.seriesIdentity.attributes.map(\.key.rawValue), ["model", "success"])

        let decoded = try JSONDecoder().decode(
            HarnessMetricSample.self,
            from: JSONEncoder().encode(first))
        XCTAssertEqual(decoded.attributes[.success], .bool(true))
    }

    func testCompleteAccountFamilyReplacementRemovesAbsentGaugesAndDailyBuckets() throws {
        func sample(_ name: String, value: Double) throws -> HarnessMetricSample {
            try XCTUnwrap(HarnessMetricSample(
                name: name,
                kind: .gauge,
                at: origin,
                unit: .count,
                harnessLaneID: .codex,
                value: value))
        }
        let runtime = try sample("codex.runtime.active", value: 1)
        let oldBucketCount = try sample("codex.account.rate_limits.bucket_count", value: 2)
        let staleReset = try sample(
            "codex.account.rate_limits.primary.resets_at.earliest", value: 1_800_000_000)
        let lifetime = try sample("codex.account.tokens.lifetime", value: 50)
        let oldDaily = try sample("codex.account.tokens.daily.2026-08-30", value: 10)
        let emptyBucketCount = try sample("codex.account.rate_limits.bucket_count", value: 0)

        var ledger = agentHarnessUpdatedMetricLedger(
            [runtime, oldBucketCount, staleReset, lifetime, oldDaily],
            appending: [emptyBucketCount],
            replacingAccountFamily: .rateLimits)
        XCTAssertEqual(
            Set(ledger.map(\.name)),
            Set([runtime.name, emptyBucketCount.name, lifetime.name, oldDaily.name]))
        XCTAssertFalse(ledger.contains { $0.name == staleReset.name })

        ledger = agentHarnessUpdatedMetricLedger(
            ledger,
            appending: [],
            replacingAccountFamily: .tokenUsage)
        XCTAssertEqual(Set(ledger.map(\.name)), Set([runtime.name, emptyBucketCount.name]))
        XCTAssertEqual(
            agentHarnessMetricLedgerClearingCodexAccountSamples(ledger).map(\.name),
            [runtime.name])
    }

    func testMetricLedgerAppliesFull2048By512BatchWithStableMergeSemantics() throws {
        func sample(
            index: Int,
            value: Double,
            id: UUID = UUID(),
            at: Date
        ) throws -> HarnessMetricSample {
            try XCTUnwrap(HarnessMetricSample(
                id: id,
                name: "provider.runtime.request.duration",
                kind: .gauge,
                at: at,
                unit: .milliseconds,
                harnessLaneID: index.isMultiple(of: 2) ? .claude : .codex,
                value: value,
                attributes: [
                    .model: .string("model-\(index)"),
                    .success: .bool(true),
                ]))
        }

        let existing = try (0..<2_048).map { index in
            try sample(
                index: index,
                value: Double(index),
                at: origin.addingTimeInterval(Double(index)))
        }
        let unchanged = try (1_536..<1_792).map { index in
            try sample(
                index: index,
                value: Double(index),
                at: origin.addingTimeInterval(10_000 + Double(index)))
        }
        let changed = try (1_792..<2_048).map { index in
            try sample(
                index: index,
                value: Double(index) + 0.5,
                at: origin.addingTimeInterval(20_000 + Double(index)))
        }
        let incoming = unchanged + changed

        let ledger = agentHarnessUpdatedMetricLedger(existing, appending: incoming)
        let retainedIDs = Set(ledger.map(\.id))

        XCTAssertEqual(ledger.count, 2_048)
        XCTAssertEqual(Array(ledger.suffix(512).map(\.id)), incoming.map(\.id))
        XCTAssertEqual(ledger.first?.attributes[.model], .string("model-256"))
        XCTAssertTrue(existing[0..<256].allSatisfy { !retainedIDs.contains($0.id) })
        XCTAssertTrue(existing[256..<1_536].allSatisfy { retainedIDs.contains($0.id) })
        XCTAssertTrue(
            existing[1_536..<1_792].allSatisfy { !retainedIDs.contains($0.id) },
            "an unchanged export refreshes the prior equal point")
        XCTAssertTrue(
            existing[1_792..<2_048].allSatisfy { retainedIDs.contains($0.id) },
            "a changed value remains beside its historical point for the runtime trend")
    }

    func testMetricLedgerReplacesOnlyLatestEqualPointAcrossExistingAndIncomingDuplicates() throws {
        func sample(id: UUID, at offset: TimeInterval) throws -> HarnessMetricSample {
            try XCTUnwrap(HarnessMetricSample(
                id: id,
                name: "provider.runtime.active",
                kind: .gauge,
                at: origin.addingTimeInterval(offset),
                unit: .count,
                harnessLaneID: .claude,
                value: 1,
                attributes: [.model: .string("same-series")]))
        }

        let oldest = try sample(id: UUID(), at: 0)
        let latestExisting = try sample(id: UUID(), at: 1)
        let firstIncoming = try sample(id: UUID(), at: 2)
        let secondIncoming = try sample(id: UUID(), at: 3)

        let ledger = agentHarnessUpdatedMetricLedger(
            [oldest, latestExisting],
            appending: [firstIncoming, secondIncoming])

        XCTAssertEqual(
            ledger.map(\.id),
            [oldest.id, secondIncoming.id],
            "each equal append removes only the then-latest match before moving to the tail")
    }
}
