import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import Mechanician

final class MechanicianHelpStoreTests: XCTestCase {
    func testCatalogIsOrderedAndIncludesExpertTopics() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let store = try MechanicianHelpStore(
            databaseURL: fixture.databaseURL,
            expectedBuild: fixture.identity)

        let sections = try await store.listSections()

        XCTAssertEqual(sections.map(\.id), ["using", "building", "history"])
        XCTAssertEqual(sections.flatMap(\.articles).count, 15)
        XCTAssertTrue(sections.flatMap(\.articles).contains { $0.id == "mechanician-help" })
        XCTAssertTrue(sections.flatMap(\.articles).contains { $0.id == "extending-mechanician" })
        XCTAssertTrue(sections.flatMap(\.articles).contains { $0.id == "diagnosing-bugs" })
        XCTAssertEqual(store.metadata.corpusID, "mechanician.public")
    }

    func testSearchReturnsAtomicCurrentClaimsWithEvidence() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let store = try MechanicianHelpStore(databaseURL: fixture.databaseURL)

        let hits = try await store.search(MechanicianHelpSearchRequest(
            text: "scheduled task permissions",
            includeHistory: false))

        let hit = try XCTUnwrap(hits.first { $0.claim.key == "scheduled-tasks.overview" })
        XCTAssertEqual(hit.claim.lifecycle, .current)
        XCTAssertFalse(hit.evidence.isEmpty)
        XCTAssertTrue(hit.evidence.contains { $0.id == "security-unattended" })
        XCTAssertFalse(hit.claim.body.contains("run unattended in trust-all mode"))
    }

    func testTypeaheadUsesPrefixTermsAndAliases() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let store = try MechanicianHelpStore(databaseURL: fixture.databaseURL)

        let schedule = try await store.search(MechanicianHelpSearchRequest(
            text: "sched perm",
            mode: .typeahead,
            limit: 8))
        XCTAssertTrue(schedule.contains { $0.article.id == "scheduled-tasks" })

        let productHelp = try await store.search(MechanicianHelpSearchRequest(
            text: "SearchMechanicianHelp",
            mode: .typeahead,
            limit: 8))
        XCTAssertTrue(productHelp.contains { $0.article.id == "mechanician-help" })
    }

    func testCurrentSearchExcludesHistoricalClaimsUntilRequested() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let store = try MechanicianHelpStore(databaseURL: fixture.databaseURL)

        let current = try await store.search(MechanicianHelpSearchRequest(
            text: "Runtime Service authenticated XPC",
            includeHistory: false,
            limit: 20))
        let withHistory = try await store.search(MechanicianHelpSearchRequest(
            text: "Runtime Service authenticated XPC",
            includeHistory: true,
            limit: 20))

        XCTAssertFalse(current.contains { $0.claim.key == "history.the-runtime-service" })
        let historical = try XCTUnwrap(withHistory.first {
            $0.claim.key == "history.the-runtime-service"
        })
        XCTAssertEqual(historical.claim.lifecycle, .historical)
    }

    func testHistorySearchRanksCurrentAuthorityBeforeHistoricalClaims() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let store = try MechanicianHelpStore(databaseURL: fixture.databaseURL)

        let hits = try await store.search(MechanicianHelpSearchRequest(
            text: "storage",
            includeHistory: true,
            limit: 20))

        let currentIndex = try XCTUnwrap(hits.firstIndex {
            $0.claim.key == "diagnosing-bugs.storage-uncertainty"
        })
        let historicalIndex = try XCTUnwrap(hits.firstIndex {
            $0.claim.key == "history.the-storage-migration-lesson"
        })
        XCTAssertLessThan(currentIndex, historicalIndex)
    }

    func testHistorySearchCanReturnAnHistoricalArticle() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let copy = try fixture.copy(named: "historical-article.sqlite")
        try mutateDatabase(copy, sql: """
            UPDATE help_article SET lifecycle = 'historical' WHERE id = 'diagnosing-bugs'
            """)
        let store = try MechanicianHelpStore(databaseURL: copy)

        let current = try await store.search(MechanicianHelpSearchRequest(
            text: "storage uncertainty",
            includeHistory: false))
        let withHistory = try await store.search(MechanicianHelpSearchRequest(
            text: "storage uncertainty",
            includeHistory: true))

        XCTAssertFalse(current.contains { $0.article.id == "diagnosing-bugs" })
        let historicalArticle = try XCTUnwrap(withHistory.first {
            $0.article.id == "diagnosing-bugs"
        })
        XCTAssertEqual(historicalArticle.article.lifecycle, .historical)
        XCTAssertEqual(historicalArticle.claim.lifecycle, .current)
    }

    func testProviderRetrievalUsesTheSignedStoreAndHonorsHistoryFlag() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let databaseURL = fixture.databaseURL
        let identity = fixture.identity
        let retrieval = MechanicianHelpProviderRetrieval(openStore: {
            try MechanicianHelpStore(databaseURL: databaseURL, expectedBuild: identity)
        })

        let current = try await retrieval.search(
            query: "Runtime Service authenticated XPC",
            includeHistory: false)
        let historical = try await retrieval.search(
            query: "Runtime Service authenticated XPC",
            includeHistory: true)

        XCTAssertFalse(current.text.contains("history.the-runtime-service"))
        XCTAssertTrue(historical.text.contains("history.the-runtime-service"))
        XCTAssertEqual(historical.receipt?.corpusID, "mechanician.public")
        XCTAssertLessThanOrEqual(
            historical.receipt?.claimCount ?? 0,
            MechanicianHelpProviderRetrieval.resultLimit)
    }

    func testProviderRetrievalNeverHolePunchesAnOversizedRankOneFromASealedCorpus() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let copy = try fixture.copy(named: "provider-oversized-rank-one.sqlite")
        let query = "providerprefixsentinel"
        try updateClaimBody(
            databaseURL: copy,
            claimKey: "getting-started.overview",
            body: String(repeating: "payload ", count: 19_000) + query)
        try updateClaimBody(
            databaseURL: copy,
            claimKey: "history.the-runtime-service",
            body: "A lower-ranked historical claim contains \(query).")

        // The reader's deliberately best-effort 128 KiB UI budget still skips the oversized row.
        // This proves the fixture has exactly the hole the stricter provider seam must close.
        let reader = try MechanicianHelpStore(databaseURL: copy)
        let readerHits = try await reader.search(MechanicianHelpSearchRequest(
            text: query,
            includeHistory: true))
        XCTAssertFalse(readerHits.contains { $0.claim.key == "getting-started.overview" })
        XCTAssertTrue(readerHits.contains { $0.claim.key == "history.the-runtime-service" })

        let sealedIdentity = try fixture.identity(sealing: copy)
        let retrieval = MechanicianHelpProviderRetrieval(openStore: {
            try MechanicianHelpStore(databaseURL: copy, expectedBuild: sealedIdentity)
        })
        do {
            _ = try await retrieval.search(query: query, includeHistory: true)
            XCTFail("rank one must fail as a complete unit rather than exposing a lower claim")
        } catch {
            XCTAssertEqual(
                error as? MechanicianHelpProviderRetrievalError,
                .resultTooLarge)
        }
    }

    func testArticleReturnsOnlyItsDistinctEvidence() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let store = try MechanicianHelpStore(databaseURL: fixture.databaseURL)

        let loaded = try await store.article(id: "mechanician-help")
        let article = try XCTUnwrap(loaded)

        XCTAssertEqual(article.evidence.map(\.id), [
            "help-agent-boundary", "help-package-identity",
        ])
        XCTAssertTrue(article.markdown.contains(
            "Mechanician Help is the product's signed, build-matched knowledge system"))
        XCTAssertTrue(article.demonstrations.isEmpty)
        XCTAssertEqual(article.guides.map(\.id), ["mechanician-help.inspector-tour"])
    }

    func testArticleAttachesOrderedTypedDemonstrationsWithClaimEvidence() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let store = try MechanicianHelpStore(databaseURL: fixture.databaseURL)

        let loadedMac = try await store.article(id: "mac")
        let mac = try XCTUnwrap(loadedMac)
        XCTAssertEqual(mac.demonstrations.map(\.id), [
            "mac.discover-app-actions",
            "mac.inspect-shortcuts",
            "mac.inspect-saved-capabilities",
            "mac.run-user-chosen-capability",
        ])
        let run = try XCTUnwrap(mac.demonstrations.last)
        XCTAssertEqual(run.requirements.session, .interactive)
        XCTAssertEqual(run.requirements.mode, .executionEnabled)
        XCTAssertEqual(run.requirements.tools, ["ListCapabilities", "RunCapability"])
        XCTAssertEqual(run.risk, .dynamic)
        XCTAssertEqual(run.reversibility.kind, .dynamic)
        XCTAssertEqual(run.userConfirmation, .beforeAct)
        XCTAssertEqual(run.steps.map(\.kind), [.observe, .ask, .act, .explain])
        XCTAssertEqual(run.verification.map(\.stepID), ["run-capability"])
        XCTAssertEqual(run.evidence.map(\.id), ["guide-mac"])

        let direct = try await store.demonstrations(articleID: "inspector")
        let artifact = try XCTUnwrap(direct.first)
        XCTAssertEqual(artifact.id, "inspector.create-artifact-preview")
        XCTAssertEqual(artifact.requirements.mode, .planCompatibleAction)
        XCTAssertEqual(artifact.claimKeys, [
            "getting-started.where-things-appear", "inspector.artifacts",
        ])
        XCTAssertEqual(artifact.risk, .additive)
        XCTAssertEqual(artifact.reversibility.kind, .manual)
        XCTAssertEqual(artifact.evidence.map(\.id), ["guide-mental-model", "guide-inspector"])
    }

    func testReaderAttachesOrderedTypedNativeGuidesWithClaimEvidence() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let store = try MechanicianHelpStore(databaseURL: fixture.databaseURL)

        let all = try await store.guides()
        XCTAssertEqual(all.map(\.id), [
            "composer.controls-tour",
            "inspector.changes-tour",
            "inspector.agents-tour",
            "inspector.artifacts-tour",
            "inspector.skills-tour",
            "inspector.files-tour",
            "mechanician-help.inspector-tour",
        ])
        // Only the Help-local reader tour stays manual. Every other signed guide presents an
        // ordinary product surface, which is what makes "show me the Changes panel" navigate.
        XCTAssertEqual(
            all.filter { $0.surface.isAgentCallable }.map(\.id).sorted(),
            [
                "composer.controls-tour",
                "inspector.agents-tour",
                "inspector.artifacts-tour",
                "inspector.changes-tour",
                "inspector.files-tour",
                "inspector.skills-tour",
            ])
        let loadedChanges = try await store.guide(id: "inspector.changes-tour")
        let changes = try XCTUnwrap(loadedChanges)
        XCTAssertEqual(changes.surface, .conversationWorkspace)
        XCTAssertEqual(changes.claimKeys, ["inspector.changes"])
        XCTAssertEqual(changes.steps.map(\.target), [
            .conversationChangesTab,
            .conversationComposer,
        ])
        XCTAssertEqual(changes.steps.map(\.revealAction), [
            .showChangesInspector,
            .showConversationControls,
        ])
        let direct = try await store.guide(id: "mechanician-help.inspector-tour")
        let guide = try XCTUnwrap(direct)
        XCTAssertEqual(guide.articleID, "mechanician-help")
        XCTAssertEqual(guide.surface, .helpWorkspaceInspector)
        XCTAssertEqual(guide.claimKeys, [
            "mechanician-help.guided-tours",
            "mechanician-help.workspace-inspector",
            "mechanician-help.search",
        ])
        XCTAssertEqual(guide.steps.map(\.target), [
            .helpInspectorTab,
            .helpTopics,
            .helpSearchField,
            .helpArticleContent,
            .helpArticleEvidence,
        ])
        XCTAssertEqual(guide.steps.map(\.revealAction), [
            .showHelpInspector,
            .showHelpTopics,
            .showHelpTopics,
            .showGuideArticle,
            .showGuideEvidence,
        ])
        XCTAssertTrue(guide.steps.allSatisfy { $0.completion == .userAdvance })
        XCTAssertEqual(guide.steps.map(\.ordinal), [0, 1, 2, 3, 4])
        XCTAssertEqual(guide.evidence.map(\.id), ["help-agent-boundary"])

        let loadedArticle = try await store.article(id: "mechanician-help")
        let article = try XCTUnwrap(loadedArticle)
        XCTAssertEqual(article.guides, [guide])
        let helpGuides = try await store.guides(articleID: "mechanician-help")
        let inspectorGuides = try await store.guides(articleID: "inspector")
        XCTAssertEqual(helpGuides, [guide])
        let changesGuide = try XCTUnwrap(
            inspectorGuides.first { $0.id == "inspector.changes-tour" })
        XCTAssertEqual(changesGuide.surface, .conversationWorkspace)
        XCTAssertEqual(changesGuide.claimKeys, ["inspector.changes"])
        XCTAssertEqual(
            changesGuide.steps.map(\.target),
            [.conversationChangesTab, .conversationComposer])
        XCTAssertEqual(changesGuide.steps.map(\.revealAction), [
            .showChangesInspector, .showConversationControls,
        ])
        XCTAssertTrue(changesGuide.summary.localizedCaseInsensitiveContains(
            "this conversation's own window"))
    }

    func testMissingCorpusIsUnavailableRatherThanEmpty() {
        XCTAssertThrowsError(try MechanicianHelpStore.databaseURL(resourceURL: nil)) { error in
            XCTAssertEqual(error as? MechanicianHelpError, .unavailable)
        }
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        XCTAssertThrowsError(try MechanicianHelpStore.databaseURL(resourceURL: empty)) { error in
            XCTAssertEqual(error as? MechanicianHelpError, .unavailable)
        }
    }

    func testReaderOpensImmutableAndRejectsWrongBuild() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let store = try MechanicianHelpStore(
            databaseURL: fixture.databaseURL,
            expectedBuild: fixture.identity)

        let readOnly = await store.databaseIsReadOnly()
        XCTAssertTrue(readOnly)

        let wrong = MechanicianHelpBuildIdentity(
            applicationVersion: fixture.identity.applicationVersion,
            applicationBuild: "different",
            bundleIdentifier: fixture.identity.bundleIdentifier,
            tenantID: fixture.identity.tenantID,
            sourceCommit: nil,
            sourceDiffSHA256: nil,
            helpCorpusSchemaVersion: nil,
            helpCorpusSHA256: nil)
        XCTAssertThrowsError(try MechanicianHelpStore(
            databaseURL: fixture.databaseURL,
            expectedBuild: wrong)) { error in
            XCTAssertEqual(error as? MechanicianHelpError, .buildMismatch("application build"))
        }
    }

    func testReaderRejectsCorpusDigestSchemaAndTenantFromPackagedIdentity() throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }

        let wrongDigest = MechanicianHelpBuildIdentity(
            applicationVersion: fixture.identity.applicationVersion,
            applicationBuild: fixture.identity.applicationBuild,
            bundleIdentifier: fixture.identity.bundleIdentifier,
            tenantID: fixture.identity.tenantID,
            sourceCommit: fixture.identity.sourceCommit,
            sourceDiffSHA256: fixture.identity.sourceDiffSHA256,
            helpCorpusSchemaVersion: fixture.identity.helpCorpusSchemaVersion,
            helpCorpusSHA256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try MechanicianHelpStore(
            databaseURL: fixture.databaseURL,
            expectedBuild: wrongDigest)) { error in
            XCTAssertEqual(error as? MechanicianHelpError, .buildMismatch("corpus digest"))
        }

        let wrongSchema = MechanicianHelpBuildIdentity(
            applicationVersion: fixture.identity.applicationVersion,
            applicationBuild: fixture.identity.applicationBuild,
            bundleIdentifier: fixture.identity.bundleIdentifier,
            tenantID: fixture.identity.tenantID,
            sourceCommit: fixture.identity.sourceCommit,
            sourceDiffSHA256: fixture.identity.sourceDiffSHA256,
            helpCorpusSchemaVersion: 99,
            helpCorpusSHA256: fixture.identity.helpCorpusSHA256)
        XCTAssertThrowsError(try MechanicianHelpStore(
            databaseURL: fixture.databaseURL,
            expectedBuild: wrongSchema)) { error in
            XCTAssertEqual(error as? MechanicianHelpError, .buildMismatch("corpus schema"))
        }

        let wrongTenant = MechanicianHelpBuildIdentity(
            applicationVersion: fixture.identity.applicationVersion,
            applicationBuild: fixture.identity.applicationBuild,
            bundleIdentifier: fixture.identity.bundleIdentifier,
            tenantID: "different",
            sourceCommit: fixture.identity.sourceCommit,
            sourceDiffSHA256: fixture.identity.sourceDiffSHA256,
            helpCorpusSchemaVersion: fixture.identity.helpCorpusSchemaVersion,
            helpCorpusSHA256: fixture.identity.helpCorpusSHA256)
        XCTAssertThrowsError(try MechanicianHelpStore(
            databaseURL: fixture.databaseURL,
            expectedBuild: wrongTenant)) { error in
            XCTAssertEqual(error as? MechanicianHelpError, .buildMismatch("tenant"))
        }
    }

    func testReaderRejectsSchemaThreeBundleRatherThanMigratingASealedResource() throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let copy = fixture.directory.appendingPathComponent("schema-three.sqlite")
        try FileManager.default.copyItem(at: fixture.databaseURL, to: copy)
        try setUserVersion(3, databaseURL: copy)

        XCTAssertThrowsError(try MechanicianHelpStore(databaseURL: copy)) { error in
            XCTAssertEqual(
                error as? MechanicianHelpError,
                .unsupportedSchema(found: 3, expected: MechanicianHelpStore.schemaVersion))
        }
    }

    func testReaderRequiresAliasRelationDemonstrationAndGuideSchemaObjects() throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }

        for table in [
            "help_article_alias", "help_relation", "help_demo", "help_demo_claim",
            "help_guide", "help_guide_claim", "help_guide_step",
        ] {
            let copy = try fixture.copy(named: "missing-\(table).sqlite")
            let drop: String
            switch table {
            case "help_demo":
                drop = "DROP TABLE help_demo_claim; DROP TABLE help_demo"
            case "help_guide":
                drop = "DROP TABLE help_guide_step; DROP TABLE help_guide_claim; DROP TABLE help_guide"
            default:
                drop = "DROP TABLE \(table)"
            }
            try mutateDatabase(copy, sql: drop)
            XCTAssertThrowsError(try MechanicianHelpStore(databaseURL: copy)) { error in
                XCTAssertEqual(error as? MechanicianHelpError, .malformed("schema objects"))
            }
        }
    }

    func testReaderRejectsRegularTableMasqueradingAsFTS() throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let copy = try fixture.copy(named: "fake-fts.sqlite")
        try mutateDatabase(copy, sql: """
            DROP TABLE help_claim_fts;
            CREATE TABLE help_claim_fts (
                claim_key TEXT,
                article_id TEXT,
                title TEXT,
                aliases TEXT,
                heading TEXT,
                body TEXT
            );
            """)

        XCTAssertThrowsError(try MechanicianHelpStore(databaseURL: copy)) { error in
            XCTAssertEqual(error as? MechanicianHelpError, .malformed("schema objects"))
        }
    }

    func testReaderRejectsFTSTextThatDiffersFromAuthority() throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let copy = try fixture.copy(named: "mismatched-fts.sqlite")
        try mutateDatabase(copy, sql: """
            UPDATE help_claim_fts SET body = body || ' tampered' WHERE rowid = 1
            """)

        XCTAssertThrowsError(try MechanicianHelpStore(databaseURL: copy)) { error in
            XCTAssertEqual(error as? MechanicianHelpError, .malformed("claim FTS parity"))
        }
    }

    func testReaderRejectsCurrentClaimWithoutEvidence() throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let copy = try fixture.copy(named: "missing-evidence.sqlite")
        try mutateDatabase(copy, sql: """
            DELETE FROM help_claim_evidence
            WHERE claim_key = (
                SELECT key FROM help_claim WHERE lifecycle = 'current' ORDER BY key LIMIT 1
            )
            """)

        XCTAssertThrowsError(try MechanicianHelpStore(databaseURL: copy)) { error in
            XCTAssertEqual(error as? MechanicianHelpError, .malformed("current claim evidence"))
        }
    }

    func testReaderRejectsUngroundedCurrentDemonstration() throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let copy = try fixture.copy(named: "ungrounded-demonstration.sqlite")
        try mutateDatabase(copy, sql: """
            DELETE FROM help_demo_claim WHERE demo_id = 'mac.discover-app-actions'
            """)

        XCTAssertThrowsError(try MechanicianHelpStore(databaseURL: copy)) { error in
            XCTAssertEqual(
                error as? MechanicianHelpError,
                .malformed("demonstration claim grounding"))
        }
    }

    func testReaderRejectsUngroundedOrMalformedNativeGuides() throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }

        let ungrounded = try fixture.copy(named: "ungrounded-guide.sqlite")
        try mutateDatabase(ungrounded, sql: """
            DELETE FROM help_guide_claim
            WHERE guide_id = 'mechanician-help.inspector-tour'
            """)
        XCTAssertThrowsError(try MechanicianHelpStore(databaseURL: ungrounded)) { error in
            XCTAssertEqual(error as? MechanicianHelpError, .malformed("guide claim grounding"))
        }

        let lifecycleMismatch = try fixture.copy(named: "guide-lifecycle-mismatch.sqlite")
        try mutateDatabase(lifecycleMismatch, sql: """
            UPDATE help_claim SET lifecycle = 'historical'
            WHERE key = 'inspector.changes'
            """)
        XCTAssertThrowsError(try MechanicianHelpStore(databaseURL: lifecycleMismatch)) { error in
            XCTAssertEqual(error as? MechanicianHelpError, .malformed("guide claim grounding"))
        }

        let unknownSurface = try fixture.copy(named: "unknown-guide-surface.sqlite")
        try mutateDatabase(unknownSurface, sql: """
            UPDATE help_guide SET surface = 'arbitraryWorkspace'
            WHERE id = 'inspector.changes-tour'
            """)
        XCTAssertThrowsError(try MechanicianHelpStore(databaseURL: unknownSurface)) { error in
            XCTAssertEqual(error as? MechanicianHelpError, .malformed("guide identity"))
        }

        let mismatchedSurface = try fixture.copy(named: "mismatched-guide-surface.sqlite")
        try mutateDatabase(mismatchedSurface, sql: """
            UPDATE help_guide SET surface = 'helpWorkspaceInspector'
            WHERE id = 'inspector.changes-tour'
            """)
        XCTAssertThrowsError(try MechanicianHelpStore(databaseURL: mismatchedSurface)) { error in
            XCTAssertEqual(error as? MechanicianHelpError, .malformed("guide surface target"))
        }

        let unknownTarget = try fixture.copy(named: "unknown-guide-target.sqlite")
        try mutateDatabase(unknownTarget, sql: """
            UPDATE help_guide_step SET target = 'arbitrarySelector'
            WHERE guide_id = 'mechanician-help.inspector-tour' AND ordinal = 0
            """)
        XCTAssertThrowsError(try MechanicianHelpStore(databaseURL: unknownTarget)) { error in
            XCTAssertEqual(error as? MechanicianHelpError, .malformed("guide step vocabulary"))
        }

        let mismatchedReveal = try fixture.copy(named: "mismatched-guide-reveal.sqlite")
        try mutateDatabase(mismatchedReveal, sql: """
            UPDATE help_guide_step SET reveal_action = 'showGuideArticle'
            WHERE guide_id = 'mechanician-help.inspector-tour' AND ordinal = 0
            """)
        XCTAssertThrowsError(try MechanicianHelpStore(databaseURL: mismatchedReveal)) { error in
            XCTAssertEqual(error as? MechanicianHelpError, .malformed("guide reveal target"))
        }

        let encodedURL = try fixture.copy(named: "encoded-guide-url.sqlite")
        try mutateDatabase(encodedURL, sql: """
            UPDATE help_guide_step SET instruction = 'Open https://example.com instead.'
            WHERE guide_id = 'mechanician-help.inspector-tour' AND ordinal = 0
            """)
        XCTAssertThrowsError(try MechanicianHelpStore(databaseURL: encodedURL)) { error in
            XCTAssertEqual(error as? MechanicianHelpError, .malformed("guide step identity"))
        }

        for (name, copy) in [
            ("scheme-uri", "Open mechanician:open-help."),
            ("python-command", "Run python -c print(1)."),
            ("css-pseudo-selector", "Find button:nth-child(2)."),
            ("click-coordinate-pair", "Click 120, 240."),
            ("raw-uuid", "Open 95A2B134-3C53-4B16-9E55-52B168588867."),
            ("raw-workspace-id", "Open workspaceID before continuing."),
            ("mutation", "Delete the Memory page before continuing."),
        ] {
            let encoded = try fixture.copy(named: "encoded-guide-\(name).sqlite")
            try mutateDatabase(encoded, sql: """
                UPDATE help_guide_step SET instruction = '\(copy)'
                WHERE guide_id = 'mechanician-help.inspector-tour' AND ordinal = 0
                """)
            XCTAssertThrowsError(try MechanicianHelpStore(databaseURL: encoded)) { error in
                XCTAssertEqual(error as? MechanicianHelpError, .malformed("guide step identity"))
            }
        }

        for (name, copy) in [
            ("colon-prose", "Note: the tour waits for the person to continue."),
            ("language-prose", "Python integrations can be discussed as ordinary product knowledge."),
            ("button-prose", "Use the second button in the Help inspector."),
            ("number-list", "Read steps 2, 3, and 4 in order."),
            ("variable-prose", "Compare x and y before continuing."),
        ] {
            let ordinary = try fixture.copy(named: "ordinary-guide-\(name).sqlite")
            try mutateDatabase(ordinary, sql: """
                UPDATE help_guide_step SET instruction = '\(copy)'
                WHERE guide_id = 'mechanician-help.inspector-tour' AND ordinal = 0
                """)
            XCTAssertNoThrow(try MechanicianHelpStore(databaseURL: ordinary))
        }

        let skippedOrdinal = try fixture.copy(named: "skipped-guide-ordinal.sqlite")
        try mutateDatabase(skippedOrdinal, sql: """
            UPDATE help_guide_step SET ordinal = 8
            WHERE guide_id = 'mechanician-help.inspector-tour' AND ordinal = 4
            """)
        XCTAssertThrowsError(try MechanicianHelpStore(databaseURL: skippedOrdinal)) { error in
            XCTAssertEqual(error as? MechanicianHelpError, .malformed("guide step ordinal"))
        }

        let arbitraryPayload = try fixture.copy(named: "guide-arbitrary-payload.sqlite")
        try mutateDatabase(arbitraryPayload, sql: """
            ALTER TABLE help_guide ADD COLUMN payload TEXT
            """)
        XCTAssertThrowsError(try MechanicianHelpStore(databaseURL: arbitraryPayload)) { error in
            XCTAssertEqual(error as? MechanicianHelpError, .malformed("schema objects"))
        }
    }

    func testReaderBoundsAndStrictlyValidatesDemonstrationRecipeJSON() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }

        let unknownTool = try fixture.copy(named: "unknown-demo-tool.sqlite")
        var recipe = try readDemoRecipe(
            databaseURL: unknownTool,
            id: "mac.inspect-saved-capabilities")
        recipe = recipe.replacingOccurrences(
            of: "ListCapabilities",
            with: "InventedAutomation")
        try replaceDemoRecipe(
            databaseURL: unknownTool,
            id: "mac.inspect-saved-capabilities",
            recipe: recipe)
        let unknownToolStore = try MechanicianHelpStore(databaseURL: unknownTool)
        await XCTAssertThrowsHelpError(.malformed("demonstration tools")) {
            try await unknownToolStore.article(id: "mac")
        }

        let unknownKey = try fixture.copy(named: "unknown-demo-key.sqlite")
        recipe = try readDemoRecipe(
            databaseURL: unknownKey,
            id: "mac.discover-app-actions")
        recipe.removeLast()
        recipe += ",\"unexpected\":true}"
        try replaceDemoRecipe(
            databaseURL: unknownKey,
            id: "mac.discover-app-actions",
            recipe: recipe)
        let unknownKeyStore = try MechanicianHelpStore(databaseURL: unknownKey)
        await XCTAssertThrowsHelpError(.malformed("demonstration recipe keys")) {
            try await unknownKeyStore.article(id: "mac")
        }

        let oversized = try fixture.copy(named: "oversized-demo.sqlite")
        recipe = try readDemoRecipe(databaseURL: oversized, id: "mac.inspect-shortcuts")
        recipe = recipe.replacingOccurrences(
            of: "List the installed Apple Shortcuts.",
            with: String(repeating: "x", count: 70_000))
        try replaceDemoRecipe(
            databaseURL: oversized,
            id: "mac.inspect-shortcuts",
            recipe: recipe)
        let oversizedStore = try MechanicianHelpStore(databaseURL: oversized)
        await XCTAssertThrowsHelpError(.malformed("demonstration recipe size")) {
            try await oversizedStore.article(id: "mac")
        }
    }

    func testReaderRejectsDemonstrationToolClassMismatches() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }

        let disguisedCapability = try fixture.copy(named: "disguised-capability-demo.sqlite")
        var recipe = try readDemoRecipe(
            databaseURL: disguisedCapability,
            id: "mac.run-user-chosen-capability")
        recipe = recipe
            .replacingOccurrences(
                of: #""kind":"act","tool":"RunCapability""#,
                with: #""kind":"observe","tool":"RunCapability""#)
            .replacingOccurrences(of: #""mode":"executionEnabled""#, with: #""mode":"readOnlyOkay""#)
            .replacingOccurrences(of: #""kind":"dynamic""#, with: #""kind":"notNeeded""#)
            .replacingOccurrences(of: #""risk":"dynamic""#, with: #""risk":"readOnly""#)
            .replacingOccurrences(of: #""userConfirmation":"beforeAct""#, with: #""userConfirmation":"none""#)
        try replaceDemoRecipe(
            databaseURL: disguisedCapability,
            id: "mac.run-user-chosen-capability",
            recipe: recipe)
        let disguisedCapabilityStore = try MechanicianHelpStore(databaseURL: disguisedCapability)
        await XCTAssertThrowsHelpError(.malformed("demonstration tool step class")) {
            try await disguisedCapabilityStore.article(id: "mac")
        }

        let relabeledInventory = try fixture.copy(named: "relabeled-inventory-demo.sqlite")
        recipe = try readDemoRecipe(
            databaseURL: relabeledInventory,
            id: "mac.inspect-saved-capabilities")
        recipe = recipe
            .replacingOccurrences(of: #""kind":"notNeeded""#, with: #""kind":"notGuaranteed""#)
            .replacingOccurrences(of: #""risk":"readOnly""#, with: #""risk":"sensitiveRead""#)
            .replacingOccurrences(of: #""userConfirmation":"none""#, with: #""userConfirmation":"beforeDemo""#)
        try replaceDemoRecipe(
            databaseURL: relabeledInventory,
            id: "mac.inspect-saved-capabilities",
            recipe: recipe)
        let relabeledInventoryStore = try MechanicianHelpStore(databaseURL: relabeledInventory)
        await XCTAssertThrowsHelpError(.malformed("demonstration tool class contract")) {
            try await relabeledInventoryStore.article(id: "mac")
        }

        let relabeledArtifact = try fixture.copy(named: "relabeled-artifact-demo.sqlite")
        recipe = try readDemoRecipe(
            databaseURL: relabeledArtifact,
            id: "inspector.create-artifact-preview")
        recipe = recipe
            .replacingOccurrences(of: #""kind":"manual""#, with: #""kind":"dynamic""#)
            .replacingOccurrences(of: #""risk":"additive""#, with: #""risk":"dynamic""#)
            .replacingOccurrences(of: #""userConfirmation":"beforeDemo""#, with: #""userConfirmation":"beforeAct""#)
        try replaceDemoRecipe(
            databaseURL: relabeledArtifact,
            id: "inspector.create-artifact-preview",
            recipe: recipe)
        let relabeledArtifactStore = try MechanicianHelpStore(databaseURL: relabeledArtifact)
        await XCTAssertThrowsHelpError(.malformed("demonstration tool class contract")) {
            try await relabeledArtifactStore.article(id: "inspector")
        }
    }

    func testSearchBoundsOversizedInputLimitAndExhaustiveKindFilter() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let store = try MechanicianHelpStore(databaseURL: fixture.databaseURL)

        let repeatedQuery = String(repeating: "permissions ", count: 100_000)
        let hits = try await store.search(MechanicianHelpSearchRequest(
            text: repeatedQuery,
            includeHistory: true,
            kinds: Set(MechanicianHelpClaimKind.allCases),
            limit: .max))
        let oversizedToken = String(repeating: "x", count: 100_000)
        let oversizedTokenHits = try await store.search(MechanicianHelpSearchRequest(
            text: oversizedToken,
            includeHistory: true,
            limit: .max))

        XCTAssertLessThanOrEqual(hits.count, 24)
        XCTAssertTrue(hits.allSatisfy { MechanicianHelpClaimKind.allCases.contains($0.claim.kind) })
        XCTAssertTrue(oversizedTokenHits.isEmpty)
    }

    func testSearchResultBudgetDropsAnOversizedClaimAsACompleteUnit() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let copy = try fixture.copy(named: "oversized-result.sqlite")
        let body = String(repeating: "payload ", count: 19_000) + "budgetneedle"
        try updateClaimBody(
            databaseURL: copy,
            claimKey: "getting-started.overview",
            body: body)
        let store = try MechanicianHelpStore(databaseURL: copy)

        let hits = try await store.search(MechanicianHelpSearchRequest(text: "budgetneedle"))

        XCTAssertTrue(hits.isEmpty)
    }

    private func setUserVersion(_ version: Int, databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE,
            nil) == SQLITE_OK,
              let database else {
            throw NSError(domain: "MechanicianHelpStoreTests", code: 1)
        }
        defer { sqlite3_close_v2(database) }
        guard sqlite3_exec(database, "PRAGMA user_version = \(version)", nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "MechanicianHelpStoreTests", code: 2)
        }
    }
}

struct HelpCorpusFixture {
    let directory: URL
    let databaseURL: URL
    let identity: MechanicianHelpBuildIdentity

    static func make() throws -> HelpCorpusFixture {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MechanicianTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // repository
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MechanicianHelpTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("MechanicianHelp.sqlite")
        let identity = MechanicianHelpBuildIdentity(
            applicationVersion: "9.9.9",
            applicationBuild: "999",
            bundleIdentifier: "ai.mechanician.tests",
            tenantID: "default",
            sourceCommit: nil,
            sourceDiffSHA256: nil,
            helpCorpusSchemaVersion: nil,
            helpCorpusSHA256: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "node",
            repository.appendingPathComponent("scripts/build-help-corpus.mjs").path,
            "--repo-root", repository.path,
            "--source", repository.appendingPathComponent("help/corpus.json").path,
            "--output", databaseURL.path,
            "--app-version", identity.applicationVersion,
            "--app-build", identity.applicationBuild,
            "--bundle-id", identity.bundleIdentifier,
            "--tenant-id", try XCTUnwrap(identity.tenantID),
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8) ?? "unknown compiler failure"
            throw NSError(
                domain: "MechanicianHelpCorpusCompiler",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail])
        }
        let sealedIdentity = MechanicianHelpBuildIdentity(
            applicationVersion: identity.applicationVersion,
            applicationBuild: identity.applicationBuild,
            bundleIdentifier: identity.bundleIdentifier,
            tenantID: identity.tenantID,
            sourceCommit: identity.sourceCommit,
            sourceDiffSHA256: identity.sourceDiffSHA256,
            helpCorpusSchemaVersion: MechanicianHelpStore.schemaVersion,
            helpCorpusSHA256: SHA256.hash(data: try Data(contentsOf: databaseURL))
                .map { String(format: "%02x", $0) }
                .joined())
        return HelpCorpusFixture(
            directory: directory,
            databaseURL: databaseURL,
            identity: sealedIdentity)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func copy(named name: String) throws -> URL {
        let copy = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: databaseURL, to: copy)
        return copy
    }

    func identity(sealing databaseURL: URL) throws -> MechanicianHelpBuildIdentity {
        MechanicianHelpBuildIdentity(
            applicationVersion: identity.applicationVersion,
            applicationBuild: identity.applicationBuild,
            bundleIdentifier: identity.bundleIdentifier,
            tenantID: identity.tenantID,
            sourceCommit: identity.sourceCommit,
            sourceDiffSHA256: identity.sourceDiffSHA256,
            helpCorpusSchemaVersion: MechanicianHelpStore.schemaVersion,
            helpCorpusSHA256: SHA256.hash(data: try Data(contentsOf: databaseURL))
                .map { String(format: "%02x", $0) }
                .joined())
    }
}

private func mutateDatabase(_ databaseURL: URL, sql: String) throws {
    let database = try openWritableDatabase(databaseURL)
    defer { sqlite3_close_v2(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw sqliteTestError(database, operation: "mutate database")
    }
}

private func updateClaimBody(databaseURL: URL, claimKey: String, body: String) throws {
    let database = try openWritableDatabase(databaseURL)
    defer { sqlite3_close_v2(database) }
    let digest = SHA256.hash(data: Data(body.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for sql in [
        "UPDATE help_claim SET body = ?1, body_sha256 = ?2 WHERE key = ?3",
        "UPDATE help_claim_fts SET body = ?1 WHERE claim_key = ?3",
    ] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteTestError(database, operation: "prepare claim update")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, body, -1, transient)
        if sql.contains("body_sha256") {
            sqlite3_bind_text(statement, 2, digest, -1, transient)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        sqlite3_bind_text(statement, 3, claimKey, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
            throw sqliteTestError(database, operation: "update claim")
        }
    }
}

private func readDemoRecipe(databaseURL: URL, id: String) throws -> String {
    let database = try openWritableDatabase(databaseURL)
    defer { sqlite3_close_v2(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        "SELECT recipe_json FROM help_demo WHERE id = ?1",
        -1,
        &statement,
        nil) == SQLITE_OK,
          let statement else {
        throw sqliteTestError(database, operation: "prepare demonstration read")
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, id, -1, transient)
    guard sqlite3_step(statement) == SQLITE_ROW,
          let raw = sqlite3_column_text(statement, 0) else {
        throw sqliteTestError(database, operation: "read demonstration recipe")
    }
    let recipe = String(cString: raw)
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw sqliteTestError(database, operation: "read demonstration recipe")
    }
    return recipe
}

private func replaceDemoRecipe(databaseURL: URL, id: String, recipe: String) throws {
    let database = try openWritableDatabase(databaseURL)
    defer { sqlite3_close_v2(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        "UPDATE help_demo SET recipe_json = ?1, recipe_sha256 = ?2 WHERE id = ?3",
        -1,
        &statement,
        nil) == SQLITE_OK,
          let statement else {
        throw sqliteTestError(database, operation: "prepare demonstration update")
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let digest = SHA256.hash(data: Data(recipe.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    sqlite3_bind_text(statement, 1, recipe, -1, transient)
    sqlite3_bind_text(statement, 2, digest, -1, transient)
    sqlite3_bind_text(statement, 3, id, -1, transient)
    guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
        throw sqliteTestError(database, operation: "update demonstration recipe")
    }
}

private func XCTAssertThrowsHelpError<T>(
    _ expected: MechanicianHelpError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? MechanicianHelpError, expected, file: file, line: line)
    }
}

private func openWritableDatabase(_ databaseURL: URL) throws -> OpaquePointer {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil) == SQLITE_OK,
          let database else {
        if let database { sqlite3_close_v2(database) }
        throw NSError(domain: "MechanicianHelpStoreTests", code: 10)
    }
    return database
}

private func sqliteTestError(_ database: OpaquePointer, operation: String) -> NSError {
    let detail = sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown SQLite error"
    return NSError(
        domain: "MechanicianHelpStoreTests",
        code: 11,
        userInfo: [NSLocalizedDescriptionKey: "\(operation): \(detail)"])
}
