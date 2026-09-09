import XCTest
@testable import Mechanician

@MainActor
final class MCPPostAuthorizationBoundaryTests: XCTestCase {
    private let testAccountInstanceID = UUID(
        uuidString: "A1FAED81-8EBA-4242-97FA-B3A5D9212585")!
    private let claudeRouteScope = "anthropic:subscription:builtin"
    private let codexRouteScope = "codex:subscription:builtin"

    private func agentBridgeSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Mechanician/AgentBridge.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testCredentialActivationPhasesHaveDistinctSessionAndReadinessEffects() {
        let activating = MCPPostAuthorizationTransition.effect(for: .activating)
        XCTAssertTrue(activating.retireSessions)
        XCTAssertFalse(activating.createReadiness)
        XCTAssertFalse(activating.retireReadiness)
        XCTAssertFalse(activating.resolveAttempt)
        XCTAssertFalse(activating.authorized)

        let ready = MCPPostAuthorizationTransition.effect(for: .ready)
        XCTAssertTrue(ready.retireSessions)
        XCTAssertTrue(ready.createReadiness)
        XCTAssertFalse(ready.retireReadiness)
        XCTAssertTrue(ready.resolveAttempt)
        XCTAssertTrue(ready.authorized)

        let cleared = MCPPostAuthorizationTransition.effect(for: .cleared)
        XCTAssertTrue(cleared.retireSessions)
        XCTAssertFalse(cleared.createReadiness)
        XCTAssertTrue(cleared.retireReadiness)
        XCTAssertTrue(cleared.resolveAttempt)
        XCTAssertFalse(cleared.authorized)

        let failed = MCPPostAuthorizationTransition.effect(for: .failed)
        XCTAssertTrue(failed.retireSessions)
        XCTAssertFalse(failed.createReadiness)
        XCTAssertFalse(failed.retireReadiness)
        XCTAssertFalse(failed.resolveAttempt)
        XCTAssertFalse(failed.authorized)
    }

    func testPendingReadinessLedgerSurvivesRelaunchAndKeepsProviderLanesIsolated() throws {
        let viceID = try XCTUnwrap(UUID(uuidString: "7F661A72-4885-42AD-BCE1-242B6741D88A"))
        let githubID = try XCTUnwrap(UUID(uuidString: "E65B4B19-4CF3-4F45-B65D-4536BF6BF023"))
        let vice = MCPReadinessClaim(
            name: "VICE", changeId: "vice-generation", source: .configured,
            serverID: viceID, accountInstanceID: testAccountInstanceID,
            routeIdentity: claudeRouteScope)
        let github = MCPReadinessClaim(
            name: "GitHub", changeId: "github-generation", source: .configured,
            serverID: githubID, accountInstanceID: testAccountInstanceID,
            routeIdentity: codexRouteScope)
        var authorizingProcess = MCPPendingReadinessLedger()
        XCTAssertTrue(authorizingProcess.mark(vice, for: .claudeSubscription))
        XCTAssertTrue(authorizingProcess.mark(github, for: .codexSubscription))
        XCTAssertFalse(authorizingProcess.mark(vice, for: .claudeSubscription))

        let persisted = try JSONEncoder().encode(authorizingProcess)
        var relaunchedProcess = try JSONDecoder().decode(
            MCPPendingReadinessLedger.self, from: persisted)

        XCTAssertEqual(relaunchedProcess.claims(for: .claudeSubscription), [vice])
        XCTAssertEqual(relaunchedProcess.claims(for: .codexSubscription), [github])
        XCTAssertTrue(relaunchedProcess.resolve(vice, for: .claudeSubscription))
        XCTAssertEqual(relaunchedProcess.claims(for: .claudeSubscription), [])
        XCTAssertEqual(
            relaunchedProcess.claims(for: .codexSubscription), [github],
            "A real terminal inventory on one provider lane must not consume another lane's "
                + "pending authorization.")
    }

    func testConfiguredReadinessRequiresStableServerIdentity() throws {
        let serverID = try XCTUnwrap(UUID(uuidString: "7F661A72-4885-42AD-BCE1-242B6741D88A"))
        let accountID = try XCTUnwrap(UUID(uuidString: "A1FAED81-8EBA-4242-97FA-B3A5D9212585"))
        var ledger = MCPPendingReadinessLedger()

        XCTAssertFalse(ledger.mark(MCPReadinessClaim(
            name: "VICE", changeId: "configured-without-id", source: .configured,
            accountInstanceID: accountID, routeIdentity: claudeRouteScope),
            for: .claudeSubscription))
        XCTAssertTrue(ledger.mark(MCPReadinessClaim(
            name: "VICE", changeId: "configured-with-id", source: .configured,
            serverID: serverID, accountInstanceID: accountID,
            routeIdentity: claudeRouteScope),
            for: .claudeSubscription))
        XCTAssertTrue(ledger.mark(MCPReadinessClaim(
            name: "Provider Connector", changeId: "provider-owned", source: .providerConnector,
            accountInstanceID: accountID,
            routeIdentity: claudeRouteScope),
            for: .claudeSubscription))
    }

    func testReadinessClaimWireCarriesAccountAndRouteIdentity() throws {
        let serverID = try XCTUnwrap(UUID(uuidString: "7F661A72-4885-42AD-BCE1-242B6741D88A"))
        let accountID = try XCTUnwrap(UUID(uuidString: "A1FAED81-8EBA-4242-97FA-B3A5D9212585"))
        let claim = MCPReadinessClaim(
            name: "VICE", changeId: "credential-generation", source: .configured,
            serverID: serverID, accountInstanceID: accountID,
            routeIdentity: claudeRouteScope)

        XCTAssertEqual(
            claim.wireValue["serverId"] as? String,
            serverID.uuidString.lowercased())
        XCTAssertEqual(
            claim.wireValue["accountInstanceId"] as? String,
            accountID.uuidString.lowercased())
        XCTAssertEqual(
            claim.wireValue["routeIdentity"] as? String,
            claudeRouteScope)
    }

    func testOlderGenerationProofCannotConsumeNewerClaimForSameServer() throws {
        let serverID = try XCTUnwrap(UUID(uuidString: "7F661A72-4885-42AD-BCE1-242B6741D88A"))
        let old = MCPReadinessClaim(
            name: "VICE", changeId: "generation-a", source: .configured,
            serverID: serverID, accountInstanceID: testAccountInstanceID,
            routeIdentity: claudeRouteScope)
        let current = MCPReadinessClaim(
            name: "VICE Renamed", changeId: "generation-b", source: .configured,
            serverID: serverID, accountInstanceID: testAccountInstanceID,
            routeIdentity: claudeRouteScope)
        var ledger = MCPPendingReadinessLedger()

        XCTAssertTrue(ledger.mark(old, for: .claudeSubscription))
        XCTAssertTrue(ledger.mark(current, for: .claudeSubscription))
        XCTAssertEqual(ledger.claims(for: .claudeSubscription), [current])
        XCTAssertFalse(
            ledger.resolve(old, for: .claudeSubscription),
            "A delayed proof for generation A must not consume generation B after rename/re-auth.")
        XCTAssertEqual(ledger.claims(for: .claudeSubscription), [current])
        XCTAssertTrue(ledger.resolve(current, for: .claudeSubscription))
    }

    func testSameNameReplacementCannotInheritConfiguredReadinessClaim() throws {
        let oldID = try XCTUnwrap(UUID(uuidString: "7F661A72-4885-42AD-BCE1-242B6741D88A"))
        let replacementID = try XCTUnwrap(UUID(uuidString: "E65B4B19-4CF3-4F45-B65D-4536BF6BF023"))
        let old = MCPReadinessClaim(
            name: "VICE", changeId: "old-row-auth", source: .configured, serverID: oldID,
            accountInstanceID: testAccountInstanceID, routeIdentity: claudeRouteScope)
        let replacement = MCPReadinessClaim(
            name: "VICE", changeId: "replacement-row-auth", source: .configured,
            serverID: replacementID, accountInstanceID: testAccountInstanceID,
            routeIdentity: claudeRouteScope)
        var ledger = MCPPendingReadinessLedger()

        XCTAssertTrue(ledger.mark(old, for: .claudeSubscription))
        XCTAssertTrue(ledger.mark(replacement, for: .claudeSubscription))
        XCTAssertEqual(Set(ledger.claims(for: .claudeSubscription)), Set([old, replacement]))
        XCTAssertTrue(ledger.resolve(old, for: .claudeSubscription))
        XCTAssertEqual(ledger.claims(for: .claudeSubscription), [replacement])
    }

    func testConfiguredRenameMapsPendingIdentityToTheCurrentWireName() throws {
        let serverID = try XCTUnwrap(UUID(uuidString: "7F661A72-4885-42AD-BCE1-242B6741D88A"))
        let accountID = try XCTUnwrap(UUID(uuidString: "A1FAED81-8EBA-4242-97FA-B3A5D9212585"))
        var readiness = MCPPendingReadinessLedger()
        var attempts = MCPPendingAuthorizationLedger()
        XCTAssertTrue(readiness.mark(MCPReadinessClaim(
            name: "VICE", changeId: "same-generation", source: .configured,
            serverID: serverID, accountInstanceID: accountID,
            routeIdentity: claudeRouteScope), for: .claudeSubscription))
        XCTAssertTrue(attempts.begin(MCPPendingAuthorizationAttempt(
            id: "in-flight", name: "VICE", source: .configured,
            operation: .authorize, serverID: serverID, accountInstanceID: accountID,
            routeIdentity: claudeRouteScope,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
            for: .claudeSubscription))

        XCTAssertTrue(readiness.renameConfiguredServer(
            id: serverID, to: "VICE Renamed", for: .claudeSubscription))
        XCTAssertTrue(attempts.renameConfiguredServer(
            id: serverID, to: "VICE Renamed", for: .claudeSubscription))
        XCTAssertEqual(readiness.claims(for: .claudeSubscription).first?.name, "VICE Renamed")
        XCTAssertEqual(attempts.attempts(for: .claudeSubscription).first?.name, "VICE Renamed")
        XCTAssertEqual(
            readiness.claims(for: .claudeSubscription).first?.changeId,
            "same-generation",
            "Rename changes the provider lookup name, not the exact credential generation.")
    }

    func testExplicitRemovalRetiresOnlyTheExactStableServerClaims() throws {
        let removedID = try XCTUnwrap(UUID(uuidString: "7F661A72-4885-42AD-BCE1-242B6741D88A"))
        let replacementID = try XCTUnwrap(UUID(uuidString: "E65B4B19-4CF3-4F45-B65D-4536BF6BF023"))
        let accountID = try XCTUnwrap(UUID(uuidString: "A1FAED81-8EBA-4242-97FA-B3A5D9212585"))
        let removed = MCPReadinessClaim(
            name: "VICE", changeId: "removed-row", source: .configured,
            serverID: removedID, accountInstanceID: accountID,
            routeIdentity: claudeRouteScope)
        let replacement = MCPReadinessClaim(
            name: "VICE", changeId: "replacement-row", source: .configured,
            serverID: replacementID, accountInstanceID: accountID,
            routeIdentity: claudeRouteScope)
        var readiness = MCPPendingReadinessLedger()
        var attempts = MCPPendingAuthorizationLedger()
        XCTAssertTrue(readiness.mark(removed, for: .claudeSubscription))
        XCTAssertTrue(readiness.mark(replacement, for: .claudeSubscription))
        XCTAssertTrue(attempts.begin(MCPPendingAuthorizationAttempt(
            id: "removed-attempt", name: "VICE", source: .configured,
            operation: .authorize, serverID: removedID, accountInstanceID: accountID,
            routeIdentity: claudeRouteScope,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
            for: .claudeSubscription))

        XCTAssertTrue(readiness.retireConfiguredServer(id: removedID, for: .claudeSubscription))
        XCTAssertTrue(attempts.retireConfiguredServer(id: removedID, for: .claudeSubscription))
        XCTAssertTrue(attempts.begin(MCPPendingAuthorizationAttempt(
            id: "replacement-attempt", name: "VICE", source: .configured,
            operation: .authorize, serverID: replacementID, accountInstanceID: accountID,
            routeIdentity: claudeRouteScope,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)),
            for: .claudeSubscription))
        XCTAssertEqual(readiness.claims(for: .claudeSubscription), [replacement])
        XCTAssertEqual(
            attempts.attempts(for: .claudeSubscription).map(\.id),
            ["replacement-attempt"],
            "Same-name replacement has a different identity and must not be retired by name.")
    }

    func testWriteAheadAuthorizationAttemptSurvivesCancelAndRelaunch() throws {
        let serverID = try XCTUnwrap(UUID(uuidString: "7F661A72-4885-42AD-BCE1-242B6741D88A"))
        let accountID = try XCTUnwrap(UUID(uuidString: "A1FAED81-8EBA-4242-97FA-B3A5D9212585"))
        let attempt = MCPPendingAuthorizationAttempt(
            id: "oauth-attempt", name: "VICE", source: .configured,
            operation: .reauthorize, serverID: serverID,
            accountInstanceID: accountID, routeIdentity: claudeRouteScope,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        var beforeCancel = MCPPendingAuthorizationLedger()

        XCTAssertTrue(beforeCancel.begin(attempt, for: .claudeSubscription))
        let persisted = try JSONEncoder().encode(beforeCancel)
        var afterRelaunch = try JSONDecoder().decode(
            MCPPendingAuthorizationLedger.self, from: persisted)
        XCTAssertEqual(afterRelaunch.attempts(for: .claudeSubscription), [attempt])
        XCTAssertTrue(afterRelaunch.resolve(id: attempt.id, for: .claudeSubscription))
        XCTAssertEqual(afterRelaunch.attempts(for: .claudeSubscription), [])
    }

    func testMalformedReadinessSidecarRowDoesNotEraseValidSibling() throws {
        let valid = MCPReadinessClaim(
            name: "VICE", changeId: "valid-generation", source: .providerConnector,
            accountInstanceID: testAccountInstanceID,
            routeIdentity: claudeRouteScope)
        var original = MCPPendingReadinessLedger()
        XCTAssertTrue(original.mark(valid, for: .claudeSubscription))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
                as? [String: Any])
        var byAccess = try XCTUnwrap(object["byAccess"] as? [String: Any])
        var rows = try XCTUnwrap(byAccess[ModelAccess.claudeSubscription.rawValue] as? [Any])
        rows.append(["name": "broken-without-required-fields"])
        byAccess[ModelAccess.claudeSubscription.rawValue] = rows
        object["byAccess"] = byAccess

        let decoded = try JSONDecoder().decode(
            MCPPendingReadinessLedger.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.claims(for: .claudeSubscription), [valid])
    }

    func testAuthorizationSidecarOverlapKeepsOldestValidWriteAheadOwner() throws {
        let first = MCPPendingAuthorizationAttempt(
            id: "first", name: "VICE", source: .providerConnector,
            operation: .authorize, accountInstanceID: testAccountInstanceID,
            routeIdentity: claudeRouteScope,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = MCPPendingAuthorizationAttempt(
            id: "second", name: "GitHub", source: .providerConnector,
            operation: .authorize, accountInstanceID: testAccountInstanceID,
            routeIdentity: claudeRouteScope,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        var firstLedger = MCPPendingAuthorizationLedger()
        var secondLedger = MCPPendingAuthorizationLedger()
        XCTAssertTrue(firstLedger.begin(first, for: .claudeSubscription))
        XCTAssertTrue(secondLedger.begin(second, for: .claudeSubscription))

        var firstObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(firstLedger))
                as? [String: Any])
        let secondObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(secondLedger))
                as? [String: Any])
        var firstByAccess = try XCTUnwrap(firstObject["byAccess"] as? [String: Any])
        let secondByAccess = try XCTUnwrap(secondObject["byAccess"] as? [String: Any])
        var rows = try XCTUnwrap(
            firstByAccess[ModelAccess.claudeSubscription.rawValue] as? [Any])
        rows.append(["id": "broken-without-required-fields"])
        rows.append(contentsOf: try XCTUnwrap(
            secondByAccess[ModelAccess.claudeSubscription.rawValue] as? [Any]))
        firstByAccess[ModelAccess.claudeSubscription.rawValue] = rows
        firstObject["byAccess"] = firstByAccess

        let decoded = try JSONDecoder().decode(
            MCPPendingAuthorizationLedger.self,
            from: JSONSerialization.data(withJSONObject: firstObject))
        XCTAssertEqual(
            decoded.attempts(for: .claudeSubscription), [first],
            "A corrupt or duplicate sidecar must not erase uncertainty or authorize overlap.")
    }

    func testCancelCannotStartAnOverlappingProviderAttemptUntilReconciliation() throws {
        let accountID = try XCTUnwrap(UUID(uuidString: "A1FAED81-8EBA-4242-97FA-B3A5D9212585"))
        let first = MCPPendingAuthorizationAttempt(
            id: "connector-attempt-a", name: "VICE", source: .providerConnector,
            operation: .authorize, accountInstanceID: accountID,
            routeIdentity: claudeRouteScope,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let replacement = MCPPendingAuthorizationAttempt(
            id: "connector-attempt-b", name: "VICE", source: .providerConnector,
            operation: .authorize, accountInstanceID: accountID,
            routeIdentity: claudeRouteScope,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        var ledger = MCPPendingAuthorizationLedger()

        XCTAssertTrue(ledger.begin(first, for: .claudeSubscription))
        XCTAssertFalse(
            ledger.begin(replacement, for: .claudeSubscription),
            "Cancel is advisory: a late name-only provider completion from attempt A must not be "
                + "allowed to masquerade as attempt B.")
        XCTAssertEqual(ledger.attempts(for: .claudeSubscription), [first])
        XCTAssertTrue(ledger.resolve(id: first.id, for: .claudeSubscription))
        XCTAssertTrue(ledger.begin(replacement, for: .claudeSubscription))
    }

    func testAuthorizationUncertaintyBlocksAnotherServerOnTheSameAccountRoute() throws {
        let accountID = try XCTUnwrap(UUID(
            uuidString: "A1FAED81-8EBA-4242-97FA-B3A5D9212585"))
        let first = MCPPendingAuthorizationAttempt(
            id: "connector-attempt-a", name: "VICE", source: .providerConnector,
            operation: .authorize, accountInstanceID: accountID,
            routeIdentity: claudeRouteScope,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let differentServer = MCPPendingAuthorizationAttempt(
            id: "connector-attempt-b", name: "GitHub", source: .providerConnector,
            operation: .authorize, accountInstanceID: accountID,
            routeIdentity: claudeRouteScope,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        var ledger = MCPPendingAuthorizationLedger()

        XCTAssertTrue(ledger.begin(first, for: .claudeSubscription))
        XCTAssertFalse(
            ledger.begin(differentServer, for: .claudeSubscription),
            "Provider connector completions can be name-only. Until the first attempt is "
                + "reconciled, another server on the same account route is ambiguous.")
        XCTAssertEqual(ledger.attempts(for: .claudeSubscription), [first])
    }

    func testAuthorizationAttemptRequiresExactSourceAccountAndRouteIdentity() throws {
        let accountID = try XCTUnwrap(UUID(
            uuidString: "A1FAED81-8EBA-4242-97FA-B3A5D9212585"))
        let serverID = try XCTUnwrap(UUID(
            uuidString: "7F661A72-4885-42AD-BCE1-242B6741D88A"))
        var ledger = MCPPendingAuthorizationLedger()

        XCTAssertFalse(ledger.begin(MCPPendingAuthorizationAttempt(
            id: "configured-without-id", name: "VICE", source: .configured,
            operation: .authorize, accountInstanceID: accountID,
            routeIdentity: claudeRouteScope, createdAt: .now), for: .claudeSubscription))
        XCTAssertFalse(ledger.begin(MCPPendingAuthorizationAttempt(
            id: "connector-with-id", name: "VICE", source: .providerConnector,
            operation: .authorize, serverID: serverID, accountInstanceID: accountID,
            routeIdentity: claudeRouteScope, createdAt: .now), for: .claudeSubscription))
        XCTAssertFalse(ledger.begin(MCPPendingAuthorizationAttempt(
            id: "empty-route", name: "VICE", source: .providerConnector,
            operation: .authorize, accountInstanceID: accountID,
            routeIdentity: "", createdAt: .now), for: .claudeSubscription))
        XCTAssertTrue(ledger.begin(MCPPendingAuthorizationAttempt(
            id: "exact", name: "VICE", source: .configured,
            operation: .authorize, serverID: serverID, accountInstanceID: accountID,
            routeIdentity: claudeRouteScope, createdAt: .now), for: .claudeSubscription))
    }

    func testReadinessProofStagesEveryExactClaimUntilItsTurnCommitsSession() throws {
        let accountID = try XCTUnwrap(UUID(uuidString: "A1FAED81-8EBA-4242-97FA-B3A5D9212585"))
        let first = MCPReadinessClaim(
            name: "VICE", changeId: "generation-a", source: .providerConnector,
            accountInstanceID: accountID,
            routeIdentity: claudeRouteScope)
        let second = MCPReadinessClaim(
            name: "GitHub", changeId: "generation-b", source: .providerConnector,
            accountInstanceID: accountID,
            routeIdentity: claudeRouteScope)
        let unrelated = MCPReadinessClaim(
            name: "Linear", changeId: "generation-c", source: .providerConnector,
            accountInstanceID: accountID,
            routeIdentity: claudeRouteScope)
        var ledger = MCPReadinessProofCommitLedger()

        XCTAssertTrue(ledger.stage(turnID: "turn-a", claim: first))
        XCTAssertTrue(ledger.stage(turnID: "turn-a", claim: second))
        XCTAssertFalse(ledger.stage(turnID: "turn-a", claim: first))
        XCTAssertTrue(ledger.stage(turnID: "turn-b", claim: unrelated))

        XCTAssertEqual(ledger.takeForSession(turnID: "turn-a"), [first, second])
        XCTAssertEqual(ledger.takeForSession(turnID: "turn-a"), [])
        XCTAssertEqual(
            ledger.takeForSession(turnID: "turn-b"), [unrelated],
            "Committing one session must not consume another turn's exact proof.")
    }

    func testTerminalWithoutSessionDiscardsProofButCannotConsumeDurableClaim() throws {
        let accountID = try XCTUnwrap(UUID(uuidString: "A1FAED81-8EBA-4242-97FA-B3A5D9212585"))
        let claim = MCPReadinessClaim(
            name: "VICE", changeId: "generation-a", source: .providerConnector,
            accountInstanceID: accountID,
            routeIdentity: claudeRouteScope)
        var readiness = MCPPendingReadinessLedger()
        var proofs = MCPReadinessProofCommitLedger()
        XCTAssertTrue(readiness.mark(claim, for: .claudeSubscription))

        XCTAssertTrue(proofs.stage(turnID: "turn-a", claim: claim))
        proofs.discard(turnID: "turn-a")
        XCTAssertEqual(proofs.takeForSession(turnID: "turn-a"), [])
        XCTAssertEqual(
            readiness.claims(for: .claudeSubscription), [claim],
            "Stop, crash, or terminal-before-session must leave the durable gate for a retry.")
    }

    func testFreshProviderBoundaryQueuesInsteadOfSteeringIntoOldTurn() {
        for canSteerNow in [false, true] {
            for turnStartingSteerable in [false, true] {
                XCTAssertEqual(
                    AgentBridge.steerDisposition(
                        canSteerNow: canSteerNow,
                        turnStartingSteerable: turnStartingSteerable,
                        requiresFreshProviderSession: true),
                    .queueAsNext,
                    "A post-auth follow-up belongs to the replacement session even while the old "
                        + "provider turn still accepts guidance.")
            }
        }
    }

    func testOrdinaryTurnsKeepExistingSteeringContract() {
        XCTAssertEqual(
            AgentBridge.steerDisposition(
                canSteerNow: true,
                turnStartingSteerable: false,
                requiresFreshProviderSession: false),
            .sendNow)
        XCTAssertEqual(
            AgentBridge.steerDisposition(
                canSteerNow: false,
                turnStartingSteerable: true,
                requiresFreshProviderSession: false),
            .bufferUntilActive)
        XCTAssertEqual(
            AgentBridge.steerDisposition(
                canSteerNow: false,
                turnStartingSteerable: false,
                requiresFreshProviderSession: false),
            .queueAsNext)
    }

    func testGenericMCPStatusCannotConsumeDurableAttemptOrReadiness() throws {
        let source = try agentBridgeSource()
        guard let turnStatusStart = source.range(of: "if eventType == \"mcp_server_status\""),
              let credentialStart = source.range(
                  of: "if eventType == \"mcp_credentials_changed\"",
                  range: turnStatusStart.upperBound..<source.endIndex),
              let probeStart = source.range(of: "private func applyMcpStatus"),
              let probeEnd = source.range(
                  of: "func browseFetch(", range: probeStart.upperBound..<source.endIndex)
        else { return XCTFail("MCP status folds were not found") }
        let statusFolds = [
            String(source[turnStatusStart.lowerBound..<credentialStart.lowerBound]),
            String(source[probeStart.lowerBound..<probeEnd.lowerBound]),
        ]

        for status in statusFolds {
            XCTAssertFalse(status.contains("resolveMCPReadiness"))
            XCTAssertFalse(status.contains("resolveMCPAuthorizationAttempt"))
            XCTAssertFalse(status.contains("applyMCPCredentialTransition"))
            XCTAssertFalse(status.contains("handleMCPCredentialEvent"))
        }
    }

    func testTerminalReplayIncludesOutputProducedAfterAuthorization() {
        var boundary = MCPPostAuthorizationReplayBoundary()
        boundary.mark(turnID: "old-turn")

        let beforeAuthorization = TranscriptEntry(kind: .assistant, text: "before auth")
        let afterAuthorization = TranscriptEntry(kind: .assistant, text: "after auth")
        let terminalEntries = [beforeAuthorization, afterAuthorization]

        XCTAssertTrue(boundary.contains(turnID: "old-turn"))
        XCTAssertEqual(
            boundary.terminalReplay(turnID: "old-turn", entries: terminalEntries),
            terminalEntries,
            "Replay must be captured from the terminal transcript, not the OAuth-time prefix.")
        XCTAssertFalse(boundary.contains(turnID: "old-turn"))
        XCTAssertNil(
            boundary.terminalReplay(turnID: "old-turn", entries: terminalEntries),
            "A duplicate terminal cannot stage the replay twice.")
    }

    func testTerminalReplayIsExactTurnScopedAndDiscardable() {
        var boundary = MCPPostAuthorizationReplayBoundary()
        boundary.mark(turnID: "affected")
        boundary.mark(turnID: "deleted-conversation-turn")
        let terminalEntries = [TranscriptEntry(kind: .assistant, text: "complete")]

        XCTAssertNil(boundary.terminalReplay(
            turnID: "unrelated", entries: terminalEntries))
        XCTAssertTrue(boundary.contains(turnID: "affected"))

        boundary.discard(turnIDs: ["deleted-conversation-turn"])
        XCTAssertFalse(boundary.contains(turnID: "deleted-conversation-turn"))
        XCTAssertEqual(
            boundary.terminalReplay(turnID: "affected", entries: terminalEntries),
            terminalEntries)
        XCTAssertTrue(boundary.isEmpty)
    }

    func testLatePreBoundarySessionEventsCannotResurrectAnOpaqueSession() throws {
        let source = try agentBridgeSource()
        let sessionHandlers = source.components(separatedBy: "case \"session\":").dropFirst()
            .map { component in
                guard let end = component.range(of: "case \"session_invalidated\":") else {
                    return component
                }
                return String(component[..<end.lowerBound])
            }

        XCTAssertEqual(
            sessionHandlers.count, 2,
            "Foreground and background provider events must each own a session handler.")
        for handler in sessionHandlers {
            guard let boundaryCheck = handler.range(
                of: "mcpPostAuthorizationReplayBoundary.contains(turnID:"),
                let opaqueWrite = handler.range(of: "sdkSessionId = event[\"sessionId\"]")
                    ?? handler.range(of: "sdkSessionId = sid") else {
                XCTFail("A session handler is missing its post-authorization resurrection fence")
                continue
            }
            XCTAssertLessThan(
                boundaryCheck.lowerBound, opaqueWrite.lowerBound,
                "A late session event from the pre-auth turn must be rejected before its opaque "
                    + "session ID can be stored.")
            let fencedPrefix = String(handler[..<opaqueWrite.lowerBound])
            XCTAssertTrue(fencedPrefix.contains("sdkSessionId = nil"))
            XCTAssertTrue(fencedPrefix.contains("sdkSessionExtensionRevision = nil"))
        }
    }

    func testCredentialMutationRetiresSessionsBeforeItsDurableTransition() throws {
        let source = try agentBridgeSource()
        guard let clearStart = source.range(of: "private static func clearProviderSessions("),
              let clearEnd = source.range(
                  of: "private static func mcpReadinessClaim(",
                  range: clearStart.upperBound..<source.endIndex),
              let handlerStart = source.range(of: "private func handleMCPCredentialEvent("),
              let handlerEnd = source.range(
                  of: "private func commitMCPReadinessSession(",
                  range: handlerStart.upperBound..<source.endIndex) else {
            return XCTFail("Provider-session invalidation boundary not found")
        }
        let clear = String(source[clearStart.lowerBound..<clearEnd.lowerBound])
        let handler = String(source[handlerStart.lowerBound..<handlerEnd.lowerBound])

        XCTAssertTrue(
            clear.contains("store.update(id)"),
            "Session retirement must update the durable conversation authority, not only live "
                + "bridge state.")
        XCTAssertTrue(clear.contains("$0.sdkSessionId = nil"))

        guard let retire = handler.range(of: "clearProviderSessions(for: access)"),
              let transition = handler.range(of: "applyMCPCredentialTransition") else {
            return XCTFail("Session retirement and durable transition were not both found")
        }
        XCTAssertLessThan(
            retire.lowerBound, transition.lowerBound,
            "The old opaque provider session must be durably retired before readiness or clear "
                + "can consume the exact write-ahead attempt.")
        XCTAssertTrue(handler.contains("pendingMCPAuthorizationAttempt("))
        XCTAssertTrue(handler.contains("mcpAttemptMatches(attempt, claim: claim, phase: phase)"))
    }

    func testEveryConversationSendCarriesDurableReadinessAcrossWindowsAndRelaunch() throws {
        let source = try agentBridgeSource()
        guard let sendStart = source.range(of: "private func performSend("),
              let backgroundStart = source.range(of: "private func backgroundSend(") else {
            return XCTFail("Foreground/background send boundaries not found")
        }
        let send = String(source[sendStart.lowerBound...].prefix(18_000))
        let background = String(source[backgroundStart.lowerBound...].prefix(18_000))

        for envelope in [send, background] {
            XCTAssertTrue(envelope.contains("pendingMCPReadinessClaims(for:"))
            XCTAssertTrue(envelope.contains(
                #"req["mcpReadinessClaims"] = mcpReadinessClaims.map(\.wireValue)"#))
            XCTAssertTrue(envelope.contains("pendingMCPAuthorizationAttempts("))
            XCTAssertTrue(envelope.contains("hasMCPAuthorizationPreparation("))
            XCTAssertTrue(envelope.contains("for: selection.access)"))
            guard let attemptGate = envelope.range(
                      of: "guard !MCPAuthorizationProviderExposurePolicy.isBlocked"),
                  let providerRequest = envelope.range(of: "var req: [String: Any]") else {
                return XCTFail("A send path is missing its pre-provider uncertainty gate")
            }
            XCTAssertLessThan(attemptGate.lowerBound, providerRequest.lowerBound)
            let gate = String(envelope[attemptGate.lowerBound..<providerRequest.lowerBound])
            XCTAssertTrue(gate.contains(
                "preparationInFlight: mcpAuthorizationPreparationInFlight"))
            XCTAssertTrue(gate.contains("hasPendingAttempt: !mcpAuthorizationAttempts.isEmpty"))
            XCTAssertTrue(gate.contains("reconcilePendingMCPAuthorization"))
            XCTAssertTrue(gate.contains("return false"))
        }

        let storeSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Mechanician/ExtensionsStore.swift")
        let storeSource = try String(contentsOf: storeSourceURL, encoding: .utf8)
        XCTAssertTrue(storeSource.contains(
            "var pendingMCPReadiness: MCPPendingReadinessLedger? = nil"))
        XCTAssertTrue(storeSource.contains(
            "pendingMCPReadiness = p.pendingMCPReadiness ?? MCPPendingReadinessLedger()"))
        XCTAssertTrue(storeSource.contains(
            "pendingMCPReadiness: pendingMCPReadiness"))
        XCTAssertTrue(storeSource.contains(
            "save(advancingProviderConfiguration: false)"),
            "Consuming readiness must not rotate the revision of the session that just proved it.")
    }

    func testExactReadinessProofWaitsForDurableSessionCommit() throws {
        let source = try agentBridgeSource()
        guard let proofStart = source.range(of: "if eventType == \"mcp_readiness_proof\""),
              let proofEnd = source.range(
                  of: "if eventType == \"mcp_server_status\"",
                  range: proofStart.upperBound..<source.endIndex),
              let commitStart = source.range(of: "private func commitMCPReadinessSession("),
              let commitEnd = source.range(
                  of: "private static func noteMCPBoundaryDuringActiveTurns(",
                  range: commitStart.upperBound..<source.endIndex)
        else { return XCTFail("Readiness proof/session commit boundaries were not found") }
        let proof = String(source[proofStart.lowerBound..<proofEnd.lowerBound])
        let commit = String(source[commitStart.lowerBound..<commitEnd.lowerBound])

        XCTAssertTrue(proof.contains("mcpReadinessProofCommits.stage"))
        XCTAssertTrue(proof.contains("tools > 0"))
        XCTAssertFalse(
            proof.contains("resolveMCPReadiness"),
            "Tool inventory alone must not consume the durable claim before the session receipt.")

        guard let persistence = commit.range(of: "store.updateAwaitingPersistence"),
              let persisted = commit.range(of: "guard persisted"),
              let resolution = commit.range(of: "resolveMCPReadiness") else {
            return XCTFail("Durable session persistence/claim consumption order was not found")
        }
        XCTAssertLessThan(persistence.lowerBound, persisted.lowerBound)
        XCTAssertLessThan(persisted.lowerBound, resolution.lowerBound)
        XCTAssertTrue(commit.contains("Set(proven) == Set(route.mcpReadinessClaims)"))
        XCTAssertTrue(commit.contains("route.mcpAuthorizationAttemptIDs.isEmpty"))
    }

    func testIntermediateCredentialMutationNeverAppearsReady() throws {
        let source = try agentBridgeSource()
        guard let start = source.range(of: "if eventType == \"mcp_credentials_changed\"") else {
            return XCTFail("Unowned credential-mutation handler not found")
        }
        let mutation = String(source[start.lowerBound...].prefix(6_000))

        XCTAssertTrue(mutation.contains("handleMCPCredentialEvent(event, from: access)"))
        guard let handlerStart = source.range(of: "private func handleMCPCredentialEvent("),
              let handlerEnd = source.range(
                  of: "private func commitMCPReadinessSession(",
                  range: handlerStart.upperBound..<source.endIndex) else {
            return XCTFail("Exact credential handler not found")
        }
        let handler = String(source[handlerStart.lowerBound..<handlerEnd.lowerBound])
        guard let failedStart = handler.range(of: "case .failed:"),
              let failedBranchEnd = handler.range(
                  of: "\n        }", range: failedStart.upperBound..<handler.endIndex)
        else { return XCTFail("Failed activation branch not found") }
        let failedBranch = String(handler[failedStart.lowerBound..<failedBranchEnd.lowerBound])
        XCTAssertFalse(
            failedBranch.contains("setAuthState(name, .authorized"),
            "An intermediate/failed provider convergence event must not paint the credential as "
                + "tool-ready merely because the local durable boundary was claimed.")
        XCTAssertFalse(failedBranch.contains("applyMCPCredentialTransition"))
    }

    func testRetryAfterProviderActivationFailureRequestsRealDaemonConvergence() throws {
        let source = try agentBridgeSource()
        guard let start = source.range(of: "private func beginMcpAuthorization("),
              let end = source.range(
                  of: "private func scheduleMCPAuthorizationPreparation(",
                  range: start.upperBound..<source.endIndex) else {
            return XCTFail("Authorization retry path not found")
        }
        let retry = String(source[start.lowerBound..<end.lowerBound])
        guard let pending = retry.range(of: "pendingMCPAuthorizationAttempts(for: access)"),
              let reconcile = retry.range(of: "kind: .reconcile"),
              let ordinaryOAuth = retry.range(of: "let key = MCPAuthorizationKey") else {
            return XCTFail("Pending activation retry and OAuth request path not found")
        }
        let pendingBranch = String(retry[pending.lowerBound..<ordinaryOAuth.lowerBound])

        XCTAssertLessThan(pending.lowerBound, reconcile.lowerBound)
        XCTAssertTrue(pendingBranch.contains("return"))
        guard let performStart = source.range(
                  of: "private func performMCPAuthorizationPreparation("),
              let performEnd = source.range(
                  of: "/// Forget a configured server's route-scoped Keychain authorization.",
                  range: performStart.upperBound..<source.endIndex) else {
            return XCTFail("Deferred retry continuation not found")
        }
        let perform = String(source[performStart.lowerBound..<performEnd.lowerBound])
        guard let explicitRetry = perform.range(of: "if case .reconcile = kind"),
              let convergence = perform.range(
                  of: "reconcilePendingMCPAuthorization(",
                  range: explicitRetry.upperBound..<perform.endIndex),
              let newAttempt = perform.range(
                  of: "let attempt = Self.makeMCPAuthorizationAttempt(",
                  range: convergence.upperBound..<perform.endIndex) else {
            return XCTFail("Deferred retry and new-attempt paths not found")
        }
        XCTAssertLessThan(convergence.lowerBound, newAttempt.lowerBound)
        XCTAssertTrue(String(perform[explicitRetry.lowerBound..<newAttempt.lowerBound])
            .contains("return"))
        guard let reconcileStart = source.range(of: "private func reconcilePendingMCPAuthorization("),
              let reconcileEnd = source.range(
                  of: "// MCP status probe bookkeeping",
                  range: reconcileStart.upperBound..<source.endIndex)
        else { return XCTFail("Reconciliation implementation not found") }
        let reconciliation = String(source[reconcileStart.lowerBound..<reconcileEnd.lowerBound])
        XCTAssertTrue(reconciliation.contains("payload[\"type\"] = \"mcp_reconcile\""))
        XCTAssertTrue(reconciliation.contains("payload[\"resumeIfNeeded\"] = resumeIfNeeded"))
        XCTAssertTrue(reconciliation.contains("mcpAuthorizationPayload(attempt)"))
        XCTAssertFalse(reconciliation.contains("\"mcp_authorize\""))

        for automatic in [
            "reconcilePendingMCPAuthorization(for: selection.access)",
            "reconcilePendingMCPAuthorization(for: access)",
        ] {
            XCTAssertTrue(
                source.contains(automatic),
                "Automatic send/runtime-ready reconciliation must use observation-only default false.")
        }
    }

    func testAuthorizationClickPublishesProgressBeforeDeferredSecurePreflight() throws {
        let source = try agentBridgeSource()
        guard let scheduleStart = source.range(
                  of: "private func scheduleMCPAuthorizationPreparation("),
              let scheduleEnd = source.range(
                  of: "private static func finishMCPAuthorizationPreparation(",
                  range: scheduleStart.upperBound..<source.endIndex) else {
            return XCTFail("Deferred MCP preparation boundary not found")
        }
        let schedule = String(source[scheduleStart.lowerBound..<scheduleEnd.lowerBound])
        guard let preparing = schedule.range(
                  of: "setAuthState(name, .preparing, for: access)"),
              let deferred = schedule.range(of: "DispatchQueue.main.async") else {
            return XCTFail("Immediate MCP progress publication was not found")
        }
        XCTAssertLessThan(
            preparing.lowerBound,
            deferred.lowerBound,
            "The pressed button must become visible progress before persistence/session work starts.")

        guard let performStart = source.range(
                  of: "private func performMCPAuthorizationPreparation("),
              let performEnd = source.range(
                  of: "/// Forget a configured server's route-scoped Keychain authorization.",
                  range: performStart.upperBound..<source.endIndex) else {
            return XCTFail("Prepared MCP authorization continuation not found")
        }
        let perform = String(source[performStart.lowerBound..<performEnd.lowerBound])
        guard let attempt = perform.range(
                  of: "let attempt = Self.makeMCPAuthorizationAttempt("),
              let durable = perform.range(
                  of: "extensions.beginMCPAuthorizationAttempt(attempt, for: key.access)",
                  range: attempt.upperBound..<perform.endIndex),
              let sessionRetirement = perform.range(
                  of: "Self.clearProviderSessions(for: key.access)",
                  range: durable.upperBound..<perform.endIndex),
              let credentialClear = perform.range(
                  of: "extensions.clearMCPAuthorization(key.name)",
                  range: sessionRetirement.upperBound..<perform.endIndex),
              let daemonSend = perform.range(
                  of: "guard let requestID = sendExtensionControl(",
                  range: credentialClear.upperBound..<perform.endIndex),
              let owner = perform.range(
                  of: "Self.mcpAuthorizationOwners[key] = ExtensionOperationOwner(",
                  range: daemonSend.upperBound..<perform.endIndex),
              let authorizing = perform.range(
                  of: "state: .authorizing",
                  range: owner.upperBound..<perform.endIndex) else {
            return XCTFail("Secure MCP preparation ordering was not found")
        }
        XCTAssertLessThan(durable.lowerBound, sessionRetirement.lowerBound)
        XCTAssertLessThan(sessionRetirement.lowerBound, credentialClear.lowerBound)
        XCTAssertLessThan(credentialClear.lowerBound, daemonSend.lowerBound)
        XCTAssertLessThan(daemonSend.lowerBound, owner.lowerBound)
        XCTAssertLessThan(
            owner.lowerBound,
            authorizing.lowerBound,
            "Cancel-capable authorizing UI requires an exact daemon request owner first.")
    }

    func testFailedDurableActivationBlocksTurnsAndRetriesWithoutRepeatingOAuth() throws {
        let source = try agentBridgeSource()
        guard let sendStart = source.range(of: "private func performSend("),
              let backgroundStart = source.range(of: "private func backgroundSend("),
              let authorizeStart = source.range(of: "private func beginMcpAuthorization(") else {
            return XCTFail("MCP send/authorize boundaries not found")
        }
        let send = String(source[sendStart.lowerBound...].prefix(13_000))
        let background = String(source[backgroundStart.lowerBound...].prefix(13_000))
        guard let authorizeEnd = source.range(
                  of: "private func scheduleMCPAuthorizationPreparation(",
                  range: authorizeStart.upperBound..<source.endIndex) else {
            return XCTFail("MCP authorization preparation boundary not found")
        }
        let authorize = String(source[authorizeStart.lowerBound..<authorizeEnd.lowerBound])

        guard let gate = send.range(
                  of: "guard !MCPAuthorizationProviderExposurePolicy.isBlocked"),
              let request = send.range(of: "var req: [String: Any]") else {
            return XCTFail("new turns do not expose a pending MCP activation gate")
        }
        XCTAssertLessThan(
            gate.lowerBound, request.lowerBound,
            "A pending durable generation must block before an opaque session can resume or a "
                + "replacement turn can start.")
        XCTAssertTrue(
            background.contains("guard !MCPAuthorizationProviderExposurePolicy.isBlocked"),
            "Background queue draining must obey the same activation gate as the visible composer.")

        guard let retry = authorize.range(of: "pendingMCPAuthorizationAttempts(for: access)"),
              let reconcile = authorize.range(of: "kind: .reconcile"),
              let ordinaryOAuth = authorize.range(of: "let key = MCPAuthorizationKey") else {
            return XCTFail("activation retry path not found")
        }
        XCTAssertLessThan(retry.lowerBound, ordinaryOAuth.lowerBound)
        XCTAssertLessThan(reconcile.lowerBound, ordinaryOAuth.lowerBound)
        XCTAssertTrue(
            String(authorize[retry.lowerBound..<ordinaryOAuth.lowerBound])
                .contains("return"),
            "Retry activation must return after reusing the saved request boundary and must not "
                + "write another mcp_authorize request.")
    }

    func testReconcileFailureIsAnOwnedTerminalControlEvent() throws {
        let source = try agentBridgeSource()

        XCTAssertTrue(
            source.contains(
                #""mcp_authorize_url", "mcp_reconcile_ok", "mcp_reconcile_error""#),
            "An explicit retry must retain its exact control route while the resumed OAuth URL "
                + "is opened; only the later reconcile result is terminal.")
        XCTAssertTrue(source.contains(
            "return eventType == \"mcp_reconcile_ok\" || eventType == \"mcp_reconcile_error\""))
        XCTAssertTrue(source.contains("\"mcp_reconcile_ok\", \"mcp_reconcile_error\""))
        XCTAssertTrue(source.contains("case \"mcp_reconcile_error\":"))
    }

    func testReviewAndPrewarmCannotBypassPendingMCPBoundary() throws {
        let source = try agentBridgeSource()
        guard let reviewStart = source.range(of: "var canStartCodexReviewCurrentChanges: Bool"),
              let reviewEnd = source.range(
                  of: "var canExportCodexLifecycleDiagnostics: Bool",
                  range: reviewStart.upperBound..<source.endIndex),
              let prewarmStart = source.range(of: "private func prewarmProviderConversation("),
              let prewarmEnd = source.range(
                  of: "static let composerPrewarmInterval:",
                  range: prewarmStart.upperBound..<source.endIndex)
        else { return XCTFail("Codex Review/prewarm boundaries were not found") }

        for boundary in [
            String(source[reviewStart.lowerBound..<reviewEnd.lowerBound]),
            String(source[prewarmStart.lowerBound..<prewarmEnd.lowerBound]),
        ] {
            XCTAssertTrue(boundary.contains("pendingMCPAuthorizationAttempts("))
            XCTAssertTrue(boundary.contains("pendingMCPReadinessClaims(for:"))
            XCTAssertTrue(boundary.contains("MCPAuthorizationProviderExposurePolicy.isBlocked"))
            XCTAssertTrue(boundary.contains("hasMCPAuthorizationPreparation("))
            XCTAssertTrue(boundary.contains(".isEmpty"))
        }
    }
}
