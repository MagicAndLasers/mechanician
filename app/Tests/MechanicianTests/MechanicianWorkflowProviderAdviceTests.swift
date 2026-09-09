import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import Mechanician

final class MechanicianWorkflowProviderAdviceTests: XCTestCase {
    func testSignedGoalMatchingRanksCurrentReviewedDemonstrations() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let databaseURL = fixture.databaseURL
        let identity = fixture.identity
        let retrieval = MechanicianHelpProviderRetrieval(openStore: {
            try MechanicianHelpStore(databaseURL: databaseURL, expectedBuild: identity)
        })

        let source = try await retrieval.workflowMatches(goal: "inspect saved automations")

        XCTAssertFalse(source.matches.isEmpty)
        XCTAssertEqual(source.metadata.corpusID, "mechanician.public")
        XCTAssertEqual(source.matches.first?.demonstration.id, "mac.inspect-saved-capabilities")
        XCTAssertTrue(source.matches.allSatisfy {
            $0.demonstration.lifecycle == .current && !$0.groundingHits.isEmpty
        })
        XCTAssertLessThanOrEqual(
            source.matches.count,
            MechanicianHelpProviderRetrieval.workflowMatchLimit)
    }

    func testNoGroundedCurrentDemonstrationIsAnExplicitEmptySource() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let databaseURL = fixture.databaseURL
        let retrieval = MechanicianHelpProviderRetrieval(openStore: {
            try MechanicianHelpStore(databaseURL: databaseURL)
        })

        let source = try await retrieval.workflowMatches(
            goal: "quasarxylophoneunrelatedsentinel")

        XCTAssertTrue(source.matches.isEmpty)
    }

    func testExactCurrentDemonstrationIDNeverFuzzySubstitutes() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let retrieval = MechanicianHelpProviderRetrieval(openStore: {
            try MechanicianHelpStore(databaseURL: fixture.databaseURL)
        })

        let exact = try await retrieval.workflowMatches(
            goal: "unrelated bounded context",
            demonstrationID: "inspector.create-artifact-preview")
        XCTAssertEqual(exact.matches.count, 1)
        let match = try XCTUnwrap(exact.matches.first)
        XCTAssertEqual(match.demonstration.id, "inspector.create-artifact-preview")
        XCTAssertEqual(
            match.groundingHits.map(\.claim.key),
            match.demonstration.claimKeys)

        let unknown = try await retrieval.workflowMatches(
            goal: "inspect saved automations",
            demonstrationID: "mac.does-not-exist")
        XCTAssertTrue(unknown.matches.isEmpty)
    }

    func testExactHistoricalDemonstrationIDIsAnExplicitEmptySource() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let copy = try fixture.copy(named: "historical-workflow.sqlite")
        try executeWorkflowTestSQL(
            copy,
            "UPDATE help_demo SET lifecycle = 'historical' "
                + "WHERE id = 'mac.inspect-saved-capabilities'")
        let retrieval = MechanicianHelpProviderRetrieval(openStore: {
            try MechanicianHelpStore(databaseURL: copy)
        })

        let source = try await retrieval.workflowMatches(
            goal: "inspect saved automations",
            demonstrationID: "mac.inspect-saved-capabilities")

        XCTAssertTrue(source.matches.isEmpty)
    }

    func testInvalidGoalFailsBeforeOpeningTheAuthority() async {
        let retrieval = MechanicianHelpProviderRetrieval(openStore: {
            XCTFail("invalid workflow goals must fail before opening Help")
            throw MechanicianHelpError.cannotOpen
        })

        for goal in ["   ", String(repeating: "x", count: 4_097)] {
            do {
                _ = try await retrieval.workflowMatches(goal: goal)
                XCTFail("invalid goal should fail")
            } catch {
                XCTAssertEqual(
                    error as? MechanicianHelpProviderRetrievalError,
                    .invalidQuery)
            }
        }
    }

    func testOversizedExactDemonstrationIDFailsBeforeOpeningTheAuthority() async {
        let retrieval = MechanicianHelpProviderRetrieval(openStore: {
            XCTFail("an oversized workflow id must fail before opening Help")
            throw MechanicianHelpError.cannotOpen
        })

        do {
            _ = try await retrieval.workflowMatches(
                goal: "bounded",
                demonstrationID: String(repeating: "x", count: 97))
            XCTFail("oversized demonstration id should fail")
        } catch {
            XCTAssertEqual(error as? MechanicianHelpProviderRetrievalError, .invalidQuery)
        }
    }

    func testWorkflowSearchNeverPunchesAnOversizedRankHole() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let copy = try fixture.copy(named: "workflow-rank-one.sqlite")
        let query = "workflowprefixsentinel"
        try updateWorkflowTestClaim(
            copy,
            key: "getting-started.overview",
            heading: String(repeating: "\(query) ", count: 100),
            body: String(repeating: "payload ", count: 19_000) + query)
        try updateWorkflowTestClaim(
            copy,
            key: "mac.overview",
            heading: "Mac overview",
            body: "A lower-ranked demonstration claim contains \(query).")
        let store = try MechanicianHelpStore(databaseURL: copy)
        let prefix = try await store.searchCompleteRankedPrefix(MechanicianHelpSearchRequest(
            text: query,
            mode: .question,
            includeHistory: false,
            limit: 12
        )) { candidate in
            candidate.count <= 1
        }
        XCTAssertEqual(prefix.first?.claim.key, "getting-started.overview")

        let retrieval = MechanicianHelpProviderRetrieval(openStore: {
            try MechanicianHelpStore(databaseURL: copy)
        })
        do {
            _ = try await retrieval.workflowMatches(goal: query)
            XCTFail("oversized rank one must fail rather than expose a lower workflow")
        } catch {
            XCTAssertEqual(error as? MechanicianHelpProviderRetrievalError, .resultTooLarge)
        }
    }

    func testProviderProjectionIsBoundedUntrustedAdviceWithoutRouteSecrets() throws {
        let source = workflowSource(count: 4)
        let assessments = Dictionary(uniqueKeysWithValues: source.matches.map {
            ($0.demonstration.id, assessment(.ready(mayRequestApproval: false)))
        })

        let answer = try MechanicianWorkflowProviderAdvice.providerAnswer(
            source: source,
            assessments: assessments,
            routeEvidence: reportedRoute())
        let root = try jsonObject(answer.text)

        XCTAssertFalse(answer.empty)
        XCTAssertEqual(answer.receipt?.claimCount, 3)
        XCTAssertLessThanOrEqual(
            answer.text.utf8.count,
            MechanicianWorkflowProviderAdvice.providerResultEncodedByteLimit)
        XCTAssertTrue(answer.text.hasPrefix(
            "Mechanician is returning signed workflow recipes"))
        XCTAssertEqual(root["schema"] as? String, "mechanician.workflow-advice.v2")
        let route = try XCTUnwrap(root["routeEvidence"] as? [String: Any])
        XCTAssertEqual(route["profile"] as? String, "standard")
        XCTAssertEqual(route["coverage"] as? String, "complete")
        XCTAssertNil(route["conversationID"])
        XCTAssertNil(route["cwd"])
        XCTAssertNil(route["account"])
        let workflows = try XCTUnwrap(root["workflows"] as? [[String: Any]])
        XCTAssertEqual(workflows.count, 3)
        XCTAssertEqual(workflows.first?["authorization"] as? String, "not-granted")
        XCTAssertEqual(workflows.first?["liveResourceState"] as? String, "not-inspected")
        let readiness = try XCTUnwrap(workflows.first?["readiness"] as? [String: Any])
        XCTAssertEqual(readiness["state"] as? String, "ready")
        XCTAssertEqual(readiness["label"] as? String, "Ready to try here")
        XCTAssertEqual(readiness["nextAction"] as? String, "follow-reviewed-preflight")
        XCTAssertEqual(readiness["canProceed"] as? Bool, true)
        XCTAssertEqual(readiness["mayRequestApproval"] as? Bool, false)
        XCTAssertFalse(answer.text.contains("secret-commit"))
        XCTAssertFalse(answer.text.contains("secret-diff"))
    }

    func testEmptyAdviceHasNoReceipt() throws {
        let source = MechanicianHelpWorkflowSource(metadata: metadata, matches: [])
        let answer = try MechanicianWorkflowProviderAdvice.providerAnswer(
            source: source,
            assessments: [:],
            routeEvidence: unreportedRoute(permissionMode: "plan"))
        let root = try jsonObject(answer.text)

        XCTAssertTrue(answer.empty)
        XCTAssertNil(answer.receipt)
        XCTAssertEqual((root["workflows"] as? [Any])?.count, 0)
        XCTAssertEqual(
            (root["routeEvidence"] as? [String: Any])?["surface"] as? String,
            "not-verified")
    }

    func testReadinessUsesStableLabelsActionsAndCurrentApprovalSemantics() throws {
        let readOnly = demo(1)
        let execution = actionDemo(2)
        let cases: [(
            MechanicianHelpDemonstration,
            MechanicianWorkflowCapabilityAssessment,
            MechanicianWorkflowRouteEvidence,
            String, String, Bool, Bool
        )] = [
            (readOnly, assessment(.ready(mayRequestApproval: false)), reportedRoute(),
             "Ready to try here", "follow-reviewed-preflight", true, false),
            (execution, assessment(.needsModeChange), reportedRoute(permissionMode: "plan"),
             "Switch out of Plan", "switch-mode-and-reassess", false, false),
            (readOnly, assessment(.unavailableHere, unobserved: ["ListCapabilities"]),
             reportedRoute(), "Not available in this conversation",
             "choose-another-reviewed-workflow", false, false),
            (readOnly, assessment(.notVerified, unobserved: ["ListCapabilities"]),
             unreportedRoute(), "Not verified yet", "re-establish-exact-tool-surface",
             false, false),
        ]

        for (demo, assessment, route, label, nextAction, canProceed, mayApprove) in cases {
            let source = source(for: demo)
            let answer = try MechanicianWorkflowProviderAdvice.providerAnswer(
                source: source,
                assessments: [demo.id: assessment],
                routeEvidence: route)
            let root = try jsonObject(answer.text)
            let workflows = try XCTUnwrap(root["workflows"] as? [[String: Any]])
            let readiness = try XCTUnwrap(workflows.first?["readiness"] as? [String: Any])
            XCTAssertEqual(readiness["label"] as? String, label)
            XCTAssertEqual(readiness["nextAction"] as? String, nextAction)
            XCTAssertEqual(readiness["canProceed"] as? Bool, canProceed)
            XCTAssertEqual(readiness["mayRequestApproval"] as? Bool, mayApprove)
        }
    }

    func testContradictoryRouteEvidenceOrAssessmentFailsClosed() {
        let current = demo(1)
        let source = source(for: current)
        let ready = assessment(.ready(mayRequestApproval: false))
        let contradictions = [
            MechanicianWorkflowRouteEvidence(
                permissionMode: "default", surfaceReported: false, coverage: .complete),
            unreportedRoute(),
        ]

        for route in contradictions {
            XCTAssertThrowsError(try MechanicianWorkflowProviderAdvice.providerAnswer(
                source: source,
                assessments: [current.id: ready],
                routeEvidence: route
            )) { error in
                XCTAssertEqual(
                    error as? MechanicianWorkflowProviderAdviceError,
                    .invalidAssessment)
            }
        }
    }

    func testOversizedFirstRecipeFailsAsACompleteUnit() {
        let oversized = demo(
            1,
            instruction: String(repeating: "\"untrusted recipe\" ", count: 3_000))
        let match = MechanicianHelpWorkflowMatch(
            demonstration: oversized,
            articleTitle: "Article 1",
            groundingHits: [hit(1)])
        let source = MechanicianHelpWorkflowSource(metadata: metadata, matches: [match])

        XCTAssertThrowsError(try MechanicianWorkflowProviderAdvice.providerAnswer(
            source: source,
            assessments: [oversized.id: assessment(
                .notVerified,
                unobserved: ["ListCapabilities"])],
            routeEvidence: unreportedRoute())) { error in
                XCTAssertEqual(
                    error as? MechanicianWorkflowProviderAdviceError,
                    .resultTooLarge)
            }
    }

    private let metadata = MechanicianHelpMetadata(
        schemaVersion: 2,
        corpusID: "mechanician.public",
        applicationVersion: "9.9.9",
        applicationBuild: "999",
        bundleIdentifier: "ai.mechanician.tests",
        tenantID: "default",
        sourceCommit: "secret-commit",
        sourceDiffSHA256: "secret-diff",
        contentSHA256: "secret-content")

    private func workflowSource(count: Int) -> MechanicianHelpWorkflowSource {
        MechanicianHelpWorkflowSource(
            metadata: metadata,
            matches: (1...count).map { index in
                MechanicianHelpWorkflowMatch(
                    demonstration: demo(index),
                    articleTitle: "Article \(index)",
                    groundingHits: [hit(index)])
            })
    }

    private func source(
        for demonstration: MechanicianHelpDemonstration
    ) -> MechanicianHelpWorkflowSource {
        MechanicianHelpWorkflowSource(
            metadata: metadata,
            matches: [MechanicianHelpWorkflowMatch(
                demonstration: demonstration,
                articleTitle: "Article \(demonstration.ordinal)",
                groundingHits: [hit(demonstration.ordinal)])])
    }

    private func assessment(
        _ readiness: AgentWorkflowReadiness,
        unobserved: [String] = []
    ) -> MechanicianWorkflowCapabilityAssessment {
        MechanicianWorkflowCapabilityAssessment(
            readiness: readiness,
            unobservedRequiredToolIDs: unobserved)
    }

    private func reportedRoute(
        permissionMode: String = "default",
        coverage: AgentToolSurfaceCoverage = .complete
    ) -> MechanicianWorkflowRouteEvidence {
        MechanicianWorkflowRouteEvidence(
            permissionMode: permissionMode,
            surfaceReported: true,
            coverage: coverage)
    }

    private func unreportedRoute(
        permissionMode: String = "default"
    ) -> MechanicianWorkflowRouteEvidence {
        MechanicianWorkflowRouteEvidence(
            permissionMode: permissionMode,
            surfaceReported: false,
            coverage: nil)
    }

    private func demo(
        _ index: Int,
        instruction: String = "Inspect the exact live inventory."
    ) -> MechanicianHelpDemonstration {
        MechanicianHelpDemonstration(
            id: "article-\(index).demo-\(index)",
            articleID: "article-\(index)",
            title: "Workflow \(index)",
            outcome: "Visible outcome \(index)",
            lifecycle: .current,
            ordinal: index,
            claimKeys: ["claim-\(index)"],
            requirements: MechanicianHelpDemoRequirements(
                session: .interactive,
                mode: .readOnlyOkay,
                tools: ["ListCapabilities"]),
            risk: .readOnly,
            reversibility: MechanicianHelpDemoReversibility(
                kind: .notNeeded,
                instructions: "Nothing changes."),
            userConfirmation: .none,
            steps: [MechanicianHelpDemoStep(
                id: "observe-\(index)",
                kind: .observe,
                tool: "ListCapabilities",
                instruction: instruction)],
            verification: [MechanicianHelpDemoVerification(
                kind: .toolSucceeded,
                stepID: "observe-\(index)",
                instruction: "Use only the returned inventory.")],
            fallback: [MechanicianHelpDemoFallback(
                when: .emptyResult,
                action: .explain,
                demoID: nil,
                instruction: "Explain the empty inventory.")],
            evidence: [evidence(index)])
    }

    private func actionDemo(_ index: Int) -> MechanicianHelpDemonstration {
        MechanicianHelpDemonstration(
            id: "article-\(index).demo-\(index)",
            articleID: "article-\(index)",
            title: "Workflow \(index)",
            outcome: "Visible outcome \(index)",
            lifecycle: .current,
            ordinal: index,
            claimKeys: ["claim-\(index)"],
            requirements: MechanicianHelpDemoRequirements(
                session: .interactive,
                mode: .executionEnabled,
                tools: ["ListCapabilities", "RunCapability"]),
            risk: .dynamic,
            reversibility: MechanicianHelpDemoReversibility(
                kind: .dynamic,
                instructions: "The selected capability defines reversal."),
            userConfirmation: .beforeAct,
            steps: [
                MechanicianHelpDemoStep(
                    id: "observe-\(index)", kind: .observe, tool: "ListCapabilities",
                    instruction: "List the choices."),
                MechanicianHelpDemoStep(
                    id: "act-\(index)", kind: .act, tool: "RunCapability",
                    instruction: "Run only the chosen capability."),
            ],
            verification: [MechanicianHelpDemoVerification(
                kind: .toolSucceeded,
                stepID: "act-\(index)",
                instruction: "Use the returned result.")],
            fallback: [MechanicianHelpDemoFallback(
                when: .actionFailed,
                action: .explain,
                demoID: nil,
                instruction: "Explain the failure.")],
            evidence: [evidence(index)])
    }

    private func hit(_ index: Int) -> MechanicianHelpSearchHit {
        MechanicianHelpSearchHit(
            claim: MechanicianHelpClaim(
                key: "claim-\(index)",
                articleID: "article-\(index)",
                heading: "Heading \(index)",
                body: "Claim body \(index)",
                kind: .howTo,
                lifecycle: .current,
                ordinal: index),
            article: MechanicianHelpArticleSummary(
                id: "article-\(index)",
                sectionID: "using",
                title: "Article \(index)",
                icon: "wrench",
                blurb: "Blurb \(index)",
                kind: .howTo,
                lifecycle: .current,
                ordinal: index),
            evidence: [evidence(index)],
            score: Double(index))
    }

    private func evidence(_ index: Int) -> MechanicianHelpEvidence {
        MechanicianHelpEvidence(
            id: "evidence-\(index)",
            kind: .canonicalDoc,
            path: "docs/guide.md",
            anchor: "#workflow-\(index)",
            sourceSHA256: "not-provider-facing",
            anchorSHA256: "not-provider-facing")
    }

    private func jsonObject(_ framed: String) throws -> [String: Any] {
        let boundary = try XCTUnwrap(framed.range(of: "\n\n"))
        return try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(framed[boundary.upperBound...].utf8)) as? [String: Any])
    }
}

@MainActor
final class MechanicianWorkflowCapabilityAssessmentTests: XCTestCase {
    func testPlanAllowsAdditiveArtifactButRequiresModeChangeForExternalCapability() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let store = try MechanicianHelpStore(databaseURL: fixture.databaseURL)
        let inspectorDemonstrations = try await store.demonstrations(articleID: "inspector")
        let macDemonstrations = try await store.demonstrations(articleID: "mac")
        let artifact = try XCTUnwrap(inspectorDemonstrations.first)
        let run = try XCTUnwrap(macDemonstrations.first {
            $0.id == "mac.run-user-chosen-capability"
        })
        XCTAssertEqual(artifact.requirements.mode, .planCompatibleAction)

        let artifactCatalog = AgentToolCatalog()
        let artifactSnapshot = readySnapshot(
            catalog: artifactCatalog,
            tools: artifact.requirements.tools,
            permissionMode: "plan",
            coverage: .complete)
        XCTAssertEqual(
            artifactCatalog.workflowAssessment(
                for: artifact,
                snapshot: artifactSnapshot).readiness,
            .ready(mayRequestApproval: false))

        let runCatalog = AgentToolCatalog()
        let runSnapshot = readySnapshot(
            catalog: runCatalog,
            tools: run.requirements.tools,
            permissionMode: "plan",
            coverage: .complete)
        XCTAssertEqual(
            runCatalog.workflowAssessment(
                for: run,
                snapshot: runSnapshot).readiness,
            .needsModeChange)
    }

    func testCompleteAndPartialMissingRequirementsStayDistinct() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let store = try MechanicianHelpStore(databaseURL: fixture.databaseURL)
        let demonstrations = try await store.demonstrations(articleID: "mac")
        let run = try XCTUnwrap(demonstrations.first {
            $0.id == "mac.run-user-chosen-capability"
        })

        for (coverage, expected) in [
            (AgentToolSurfaceCoverage.complete, AgentWorkflowReadiness.unavailableHere),
            (.mechanicianSupplied, .notVerified),
        ] {
            let catalog = AgentToolCatalog()
            let snapshot = readySnapshot(
                catalog: catalog,
                tools: ["ListCapabilities"],
                permissionMode: "default",
                coverage: coverage)
            let result = catalog.workflowAssessment(
                for: run,
                snapshot: snapshot)
            XCTAssertEqual(result.readiness, expected)
            XCTAssertEqual(result.unobservedRequiredToolIDs, ["RunCapability"])
        }
    }

    func testExecutionWorkflowMayStillRequestAppApprovalInEveryNonPlanMode() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let store = try MechanicianHelpStore(databaseURL: fixture.databaseURL)
        let demonstrations = try await store.demonstrations(articleID: "mac")
        let run = try XCTUnwrap(demonstrations.first {
            $0.id == "mac.run-user-chosen-capability"
        })

        for permissionMode in ["default", "acceptEdits", "bypassPermissions"] {
            let catalog = AgentToolCatalog()
            let snapshot = readySnapshot(
                catalog: catalog,
                tools: run.requirements.tools,
                permissionMode: permissionMode,
                coverage: .complete)

            XCTAssertEqual(
                catalog.workflowAssessment(for: run, snapshot: snapshot).readiness,
                .ready(mayRequestApproval: true),
                permissionMode)
        }
    }

    private func readySnapshot(
        catalog: AgentToolCatalog,
        tools: [String],
        permissionMode: String,
        coverage: AgentToolSurfaceCoverage
    ) -> AgentToolSurfaceSnapshot {
        let route = AgentToolSurfaceRoute(
            bridgeID: UUID(),
            runtimeGeneration: UUID(),
            conversationID: UUID(),
            turnID: UUID().uuidString,
            selection: ModelSelection(access: .openAIAPI, modelID: "test"),
            accountInstanceID: ProviderAccountInstanceID(),
            credentialEpoch: 1,
            providerRouteIdentity: "openai:test",
            workspaceIdentity: "home",
            canonicalCWD: "",
            toolProfile: .standard,
            permissionMode: permissionMode,
            providerSessionRevision: UUID(),
            workspaceInstructionsRevision: "instructions")
        catalog.begin(route: route)
        XCTAssertTrue(catalog.publish(
            tools: tools,
            coverage: coverage,
            provenance: .mechanicianAPIRequest,
            adapterRevision: AgentToolCatalog.adapterRevision,
            for: route))
        return try! XCTUnwrap(catalog.snapshot(for: route.conversationID))
    }
}

private func executeWorkflowTestSQL(_ databaseURL: URL, _ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil) == SQLITE_OK,
          let database else {
        if let database { sqlite3_close_v2(database) }
        throw NSError(domain: "MechanicianWorkflowProviderAdviceTests", code: 1)
    }
    defer { sqlite3_close_v2(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "MechanicianWorkflowProviderAdviceTests", code: 2)
    }
}

private func updateWorkflowTestClaim(
    _ databaseURL: URL,
    key: String,
    heading: String,
    body: String
) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil) == SQLITE_OK,
          let database else {
        if let database { sqlite3_close_v2(database) }
        throw NSError(domain: "MechanicianWorkflowProviderAdviceTests", code: 3)
    }
    defer { sqlite3_close_v2(database) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let digest = SHA256.hash(data: Data(body.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    let updates: [(String, [String])] = [
        ("UPDATE help_claim SET heading = ?1, body = ?2, body_sha256 = ?3 WHERE key = ?4",
         [heading, body, digest, key]),
        ("UPDATE help_claim_fts SET heading = ?1, body = ?2 WHERE claim_key = ?3",
         [heading, body, key]),
    ]
    for (sql, values) in updates {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "MechanicianWorkflowProviderAdviceTests", code: 4)
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
            throw NSError(domain: "MechanicianWorkflowProviderAdviceTests", code: 5)
        }
    }
}
