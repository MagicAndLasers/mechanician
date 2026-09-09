import XCTest
@testable import Mechanician

final class AgentRootActivitySnapshotTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 20_000)

    private func at(_ offset: TimeInterval) -> Date {
        start.addingTimeInterval(offset)
    }

    private func attributed(
        _ record: AgentActivityRecord,
        access: ModelAccess,
        modelID: String
    ) -> AgentActivityRecord {
        var copy = record
        copy.providerAccess = access
        copy.modelID = modelID
        return copy
    }

    func testSnapshotUsesOnlyTheSelectedTurnsRootLane() throws {
        let child = AgentActivityIdentity.subagent("child")
        let records: [AgentActivityRecord] = [
            attributed(
                .state(.model, turnID: "old", detail: "Responding", at: at(0)),
                access: .claudeSubscription,
                modelID: "old-root-model"),
            .tool(
                "Read",
                turnID: "old",
                agentID: AgentActivityIdentity.root,
                at: at(1)),
            .tokens(turnID: "old", input: 900, at: at(2)),
            .state(.completed, turnID: "old", at: at(3)),

            attributed(
                .state(.model, turnID: "selected", detail: "Responding", at: at(100)),
                access: .codexSubscription,
                modelID: "gpt-root"),
            attributed(
                .state(.tool, turnID: "selected", agentID: child, detail: "Read", at: at(101)),
                access: .claudeSubscription,
                modelID: "child-model-must-not-leak"),
            .tool(
                "Bash",
                turnID: "selected",
                agentID: AgentActivityIdentity.root,
                target: "rg RootSnapshot",
                at: at(102)),
            .tool("Read", turnID: "selected", agentID: child, at: at(103)),
            .tokens(
                turnID: "selected",
                agentID: AgentActivityIdentity.root,
                input: 100,
                cachedInput: 80,
                output: 20,
                at: at(104)),
            .tokens(turnID: "selected", agentID: child, total: 5_000, at: at(105)),
        ]

        let snapshot = try XCTUnwrap(
            AgentConversationActivityIndex(records).rootSnapshot(
                isRootWorking: true,
                now: at(110)))

        XCTAssertEqual(snapshot.turnID, "selected")
        XCTAssertEqual(snapshot.providerAccess, .codexSubscription)
        XCTAssertEqual(snapshot.requestedModelID, "gpt-root")
        XCTAssertNil(snapshot.providerReportedModelID)
        XCTAssertEqual(snapshot.phase, .model)
        XCTAssertEqual(snapshot.startedAt, at(100))
        XCTAssertNil(snapshot.terminalAt)
        XCTAssertEqual(snapshot.tokenUsage.processed, 120)
        XCTAssertEqual(snapshot.tokenUsage.cachedInput, 80)
        XCTAssertEqual(snapshot.observedToolCount, 1)
        XCTAssertEqual(snapshot.toolComposition.map(\.name), ["rg"])
        XCTAssertTrue(snapshot.isActive)
        XCTAssertEqual(snapshot.duration, 10, accuracy: 0.001)
    }

    func testMaintenanceOnlyTurnDoesNotSynthesizeRootCard() {
        let records: [AgentActivityRecord] = [
            .state(
                .compacting,
                turnID: "maintenance",
                detail: "Compacting context",
                at: at(0)),
            .compaction(
                turnID: "maintenance",
                trigger: "idle",
                preTokens: nil,
                postTokens: nil,
                at: at(1)),
            .state(
                .model,
                turnID: "maintenance",
                detail: "Context compacted",
                at: at(2)),
        ]

        XCTAssertNil(
            AgentConversationActivityIndex(records).rootSnapshot(
                isRootWorking: false,
                now: at(100)))
    }

    func testRootDelegationIsObservedRootToolActivity() throws {
        let records: [AgentActivityRecord] = [
            .tool(
                "Agent",
                turnID: "delegation",
                agentID: AgentActivityIdentity.root,
                target: "Explore activity projection",
                at: at(0)),
        ]

        let snapshot = try XCTUnwrap(
            AgentConversationActivityIndex(records).rootSnapshot(
                isRootWorking: false,
                now: at(100)))

        XCTAssertEqual(snapshot.observedToolCount, 1)
        XCTAssertEqual(snapshot.toolComposition, [
            AgentToolShare(name: "Delegating", count: 1, share: 1),
        ])
        XCTAssertFalse(snapshot.isActive)
        XCTAssertEqual(snapshot.duration, 0, accuracy: 0.001)
    }

    func testRootDurationFreezesWhileSelectedTurnsChildContinues() throws {
        let child = AgentActivityIdentity.subagent("tail")
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "live-tail", at: at(0)),
            .state(.model, turnID: "live-tail", agentID: child, at: at(5)),
            .state(.completed, turnID: "live-tail", at: at(10)),

            .state(.model, turnID: "newer-complete", at: at(20)),
            .state(.completed, turnID: "newer-complete", at: at(30)),
        ]

        XCTAssertEqual(
            agentActivityActiveOrLatestTurn(agentActivityTurnSummaries(records))?.id,
            "live-tail")
        let snapshot = try XCTUnwrap(
            AgentConversationActivityIndex(records).rootSnapshot(
                isRootWorking: false,
                now: at(1_000)))

        XCTAssertEqual(snapshot.turnID, "live-tail")
        XCTAssertEqual(snapshot.phase, .completed)
        XCTAssertEqual(snapshot.terminalAt, at(10))
        XCTAssertFalse(snapshot.isActive)
        XCTAssertEqual(snapshot.duration, 10, accuracy: 0.001)
    }

    func testTerminalBoundaryWinsOverBufferedProgressAndMaintenance() throws {
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", detail: "Responding", at: at(0)),
            .state(.stopped, turnID: "turn", detail: "Stopped by user", at: at(10)),
            // Both records arrived after Stop. Neither may reopen or extend the root.
            .state(.model, turnID: "turn", detail: "Buffered progress", at: at(20)),
            .state(.compacting, turnID: "turn", detail: "Compacting context", at: at(30)),
            .compaction(
                turnID: "turn",
                trigger: "idle",
                preTokens: nil,
                postTokens: nil,
                at: at(40)),
            // A later terminal record can refine the outcome, but not the duration boundary.
            .state(.failed, turnID: "turn", detail: "Provider failed", at: at(50)),
        ]

        let snapshot = try XCTUnwrap(
            AgentConversationActivityIndex(records).rootSnapshot(
                isRootWorking: true,
                now: at(1_000)))

        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertEqual(snapshot.terminalAt, at(10))
        XCTAssertNil(snapshot.currentStep)
        XCTAssertFalse(snapshot.isActive)
        XCTAssertFalse(snapshot.isStalled)
        XCTAssertEqual(snapshot.duration, 10, accuracy: 0.001)
    }

    func testChildAndContextRecordsAloneDoNotCreateRootCard() {
        let child = AgentActivityIdentity.subagent("only-child")
        let records: [AgentActivityRecord] = [
            .context(turnID: "turn", tokens: 100, window: 1_000, at: at(0)),
            .state(.model, turnID: "turn", agentID: child, at: at(1)),
            .tool("Read", turnID: "turn", agentID: child, at: at(2)),
            .tokens(turnID: "turn", agentID: child, total: 300, at: at(3)),
        ]

        XCTAssertNil(
            AgentConversationActivityIndex(records).rootSnapshot(
                isRootWorking: false,
                now: at(100)))
    }

    func testProviderIdentityEnrichesRootWithoutReplacingRequestedModel() throws {
        let requested = attributed(
            .state(.model, turnID: "turn", at: at(0)),
            access: .codexSubscription,
            modelID: "requested-model")
        let reported = attributed(
            .identity(turnID: "turn", at: at(1)),
            access: .codexSubscription,
            modelID: "provider-reported-model")

        let snapshot = try XCTUnwrap(
            AgentConversationActivityIndex([requested, reported]).rootSnapshot(
                isRootWorking: true,
                now: at(2)))

        XCTAssertEqual(snapshot.requestedModelID, "requested-model")
        XCTAssertEqual(snapshot.providerReportedModelID, "provider-reported-model")
    }

    func testProviderIdentityAloneDoesNotCreateRootCard() {
        let reported = attributed(
            .identity(turnID: "turn", at: at(0)),
            access: .codexSubscription,
            modelID: "provider-reported-model")

        XCTAssertNil(
            AgentConversationActivityIndex([reported]).rootSnapshot(
                isRootWorking: false,
                now: at(100)))
    }

    func testLiveRootExistsBeforeItsFirstLedgerRecord() throws {
        let selection = ModelSelection(
            access: .codexSubscription,
            modelID: "gpt-requested")

        let snapshot = try XCTUnwrap(
            AgentConversationActivityIndex([]).rootSnapshot(
                isRootWorking: true,
                liveSelection: selection,
                liveStartedAt: at(10),
                now: at(15)))

        XCTAssertNil(snapshot.turnID)
        XCTAssertEqual(snapshot.providerAccess, .codexSubscription)
        XCTAssertEqual(snapshot.requestedModelID, "gpt-requested")
        XCTAssertNil(snapshot.providerReportedModelID)
        XCTAssertEqual(snapshot.phase, .model)
        XCTAssertEqual(snapshot.startedAt, at(10))
        XCTAssertNil(snapshot.terminalAt)
        XCTAssertNil(snapshot.currentStep)
        XCTAssertTrue(snapshot.tokenUsage.isEmpty)
        XCTAssertEqual(snapshot.observedToolCount, 0)
        XCTAssertTrue(snapshot.toolComposition.isEmpty)
        XCTAssertFalse(snapshot.isStalled)
        XCTAssertTrue(snapshot.isActive)
        XCTAssertEqual(snapshot.duration, 5, accuracy: 0.001)
    }

    func testNewLiveRootDoesNotReuseThePreviousTurnsStatsOrReportedModel() throws {
        let records: [AgentActivityRecord] = [
            attributed(
                .state(.model, turnID: "previous", at: at(0)),
                access: .codexSubscription,
                modelID: "previous-request"),
            attributed(
                .identity(turnID: "previous", at: at(1)),
                access: .codexSubscription,
                modelID: "previous-reported"),
            .tool(
                "Read",
                turnID: "previous",
                agentID: AgentActivityIdentity.root,
                at: at(2)),
            .tokens(
                turnID: "previous",
                agentID: AgentActivityIdentity.root,
                total: 4_000,
                at: at(3)),
            .state(.completed, turnID: "previous", at: at(4)),
        ]

        let snapshot = try XCTUnwrap(
            AgentConversationActivityIndex(records).rootSnapshot(
                isRootWorking: true,
                liveSelection: ModelSelection(
                    access: .claudeSubscription,
                    modelID: "new-request"),
                liveStartedAt: at(20),
                now: at(25)))

        XCTAssertNil(snapshot.turnID)
        XCTAssertEqual(snapshot.providerAccess, .claudeSubscription)
        XCTAssertEqual(snapshot.requestedModelID, "new-request")
        XCTAssertNil(snapshot.providerReportedModelID)
        XCTAssertEqual(snapshot.startedAt, at(20))
        XCTAssertTrue(snapshot.tokenUsage.isEmpty)
        XCTAssertEqual(snapshot.observedToolCount, 0)
        XCTAssertTrue(snapshot.toolComposition.isEmpty)
        XCTAssertTrue(snapshot.isActive)
        XCTAssertEqual(snapshot.duration, 5, accuracy: 0.001)
    }

    func testPreLedgerProviderIdentityIsUsedOnlyWhenItBelongsToTheLiveTurn() throws {
        let oldIdentity = attributed(
            .identity(turnID: "previous", at: at(5)),
            access: .codexSubscription,
            modelID: "old-provider-model")
        let selection = ModelSelection(
            access: .codexSubscription,
            modelID: "new-request")

        let oldSnapshot = try XCTUnwrap(
            AgentConversationActivityIndex([oldIdentity]).rootSnapshot(
                isRootWorking: true,
                liveSelection: selection,
                liveStartedAt: at(10),
                now: at(11)))
        XCTAssertNil(oldSnapshot.providerReportedModelID)

        let currentIdentity = attributed(
            .identity(turnID: "current", at: at(12)),
            access: .codexSubscription,
            modelID: "current-provider-model")
        let currentSnapshot = try XCTUnwrap(
            AgentConversationActivityIndex([currentIdentity]).rootSnapshot(
                isRootWorking: true,
                liveSelection: selection,
                liveStartedAt: at(10),
                now: at(13)))
        XCTAssertEqual(
            currentSnapshot.providerReportedModelID,
            "current-provider-model")
    }
}
