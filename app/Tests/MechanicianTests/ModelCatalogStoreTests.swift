import XCTest
@testable import Mechanician

@MainActor
final class ModelCatalogStoreTests: XCTestCase {
    private let access = ModelAccess.codexSubscription
    private let scope = "account"

    private var model: ModelCatalogEntry {
        ModelCatalogEntry(
            selection: ModelSelection(access: access, modelID: "model-a"),
            displayName: "Model A",
            description: "",
            resolvedModelID: nil,
            isDefault: true,
            supportedEfforts: ["high"],
            capabilities: ["effort"])
    }

    // MARK: - Recovery when a connected account's catalog request fails

    /// A managed deployment may not carry the newest generation at all: an enterprise Vertex project
    /// with only 4.8 answers `claude-opus-5` with a 404. The built-in list has to contain a model
    /// such an account can actually run, or its only offer is one that errors.
    func testBuiltInClaudeModelsOfferBothCurrentOpusGenerations() {
        for access in [ModelAccess.claudeSubscription, .anthropicAPI, .claudeVertex] {
            let ids = AgentBridge.builtInModels(for: access).map(\.1)
            XCTAssertTrue(ids.contains("claude-opus-5"), access.displayName)
            XCTAssertTrue(ids.contains("claude-opus-4-8"), access.displayName)
        }
    }

    func testBuiltInFirstPartyClaudeModelsOfferFable51WithoutDroppingFable5() {
        for access in [ModelAccess.claudeSubscription, .anthropicAPI] {
            let ids = AgentBridge.builtInModels(for: access).map(\.1)
            XCTAssertTrue(ids.contains("claude-fable-5-1"), access.displayName)
            XCTAssertTrue(ids.contains("claude-fable-5"), access.displayName)
        }
    }

    func testBuiltInVertexFallbackOffersFable51WithoutMovingItsColdStartDefault() {
        let ids = AgentBridge.builtInModels(for: .claudeVertex).map(\.1)

        XCTAssertEqual(ids.first, "claude-opus-4-8")
        XCTAssertTrue(ids.contains("claude-fable-5-1"))
    }

    func testClaudeCatalogResolutionCarriesConcreteContextIdentityWithoutReplacingTheAlias() {
        let selection = ModelSelection(access: .claudeSubscription, modelID: "fable")
        let entry = ModelCatalogEntry(
            selection: selection,
            displayName: "Fable",
            description: "",
            resolvedModelID: "claude-fable-5-1",
            isDefault: false,
            supportedEfforts: ["high"],
            capabilities: ["effort"])

        XCTAssertEqual(
            AgentBridge.catalogResolvedModelID(for: selection, catalogEntry: entry),
            "claude-fable-5-1")
        XCTAssertEqual(selection.modelID, "fable", "the provider wire value stays the alias")
        XCTAssertNil(AgentBridge.catalogResolvedModelID(
            for: ModelSelection(access: .openAIAPI, modelID: "fable"),
            catalogEntry: entry))
    }

    /// Several cold-start paths take `availableModels[0]` as the default selection, so the order of
    /// the built-in list is load-bearing, not cosmetic.
    ///
    /// The OpenAI answer is `gpt-5.5` rather than the newest generation for the same reason managed
    /// Vertex leads with 4.8: this list is only ever reached when the live catalog FAILED, so it has
    /// to name something the account is known to serve. `/v1/models` on an API-key account does not
    /// list a bare `gpt-5.6`; the 5.6 generation reaches that lane, when it reaches it at all,
    /// through the live catalog, which no longer filters ids this build has not heard of.
    func testBuiltInModelOrderKeepsTheColdStartDefaultStable() {
        XCTAssertEqual(AgentBridge.builtInModels(for: .claudeSubscription).first?.1, "claude-opus-5")
        XCTAssertEqual(AgentBridge.builtInModels(for: .openAIAPI).first?.1, "gpt-5.5")
        XCTAssertEqual(AgentBridge.builtInModels(for: .codexSubscription).first?.1, "gpt-5.6-sol")
    }

    /// The two OpenAI lanes answer different catalogs, and a fallback row that names the other
    /// lane's id is a row that fails on click. `model/list` on the Codex subscription serves the
    /// 5.6 generation as -Sol/-Terra/-Luna and has no bare `gpt-5.6`, no `-pro`, and no
    /// `gpt-5.3-codex`; those belong to the API-key lane.
    func testBuiltInOpenAILanesDoNotBorrowEachOthersModelIDs() {
        let codex = AgentBridge.builtInModels(for: .codexSubscription).map(\.1)
        let api = AgentBridge.builtInModels(for: .openAIAPI).map(\.1)

        XCTAssertTrue(codex.contains("gpt-5.6-sol"))
        XCTAssertTrue(codex.contains("gpt-5.6-terra"))
        XCTAssertTrue(codex.contains("gpt-5.6-luna"))
        XCTAssertFalse(codex.contains("gpt-5.4-pro"))
        XCTAssertFalse(codex.contains("gpt-5.3-codex"))
        XCTAssertFalse(api.contains { $0.hasPrefix("gpt-5.6-") })
    }

    /// The bug this guards: a CONNECTED account whose catalog request timed out rendered no rows at
    /// all, so the user could not switch to a model that would have worked.
    func testFailedCatalogStillOffersSelectableModels() {
        let store = ModelCatalogStore(cacheURL: nil)
        let entries = AgentBridge.fallbackEntries(for: .claudeVertex, scope: "account")

        XCTAssertFalse(entries.isEmpty)
        XCTAssertTrue(entries.contains { $0.selection.modelID == "claude-opus-4-8" })
        XCTAssertTrue(entries.allSatisfy { $0.selection.access == .claudeVertex })
        _ = store
    }

    func testClaudeFamilyAliasPresentsItsResolvedGeneration() {
        func entry(_ displayName: String, resolvedModelID: String) -> ModelCatalogEntry {
            ModelCatalogEntry(
                selection: ModelSelection(
                    access: .claudeSubscription,
                    modelID: displayName.lowercased()),
                displayName: displayName,
                description: "",
                resolvedModelID: resolvedModelID,
                isDefault: false,
                supportedEfforts: [],
                capabilities: [])
        }

        XCTAssertEqual(
            entry("Sonnet", resolvedModelID: "claude-sonnet-5").versionedDisplayName,
            "Sonnet 5")
        XCTAssertEqual(
            entry("Fable", resolvedModelID: "claude-fable-5-1").versionedDisplayName,
            "Fable 5.1")
        XCTAssertEqual(
            entry("Opus", resolvedModelID: "claude-opus-4-8[1m]").versionedDisplayName,
            "Opus 4.8")
        XCTAssertEqual(
            entry("Opus", resolvedModelID: "claude-opus-5").versionedDisplayName,
            "Opus 5")
        XCTAssertEqual(
            entry("Opus (1M context)", resolvedModelID: "claude-opus-5[1m]")
                .versionedDisplayName,
            "Opus 5 (1M context)")
        XCTAssertEqual(
            entry("Haiku", resolvedModelID: "claude-haiku-4-5-20251001")
                .versionedDisplayName,
            "Haiku 4.5")
        XCTAssertEqual(
            entry("Default (recommended)", resolvedModelID: "claude-opus-4-8[1m]")
                .versionedDisplayName,
            "Default (recommended)")
    }

    func testDisabledCatalogRetainsLastKnownRowsWithoutKeepingThemSelectable() {
        let store = ModelCatalogStore()
        XCTAssertTrue(store.alignCredentialEpoch(0, for: access))
        XCTAssertTrue(store.publishAutomatic(
            [model], access: access, scope: scope, credentialEpoch: 0))

        store.disable(
            access: access, credentialEpoch: 0, message: "Reconnect required")

        XCTAssertEqual(
            store.snapshot(for: access, scope: scope).phase,
            .failed("Reconnect required"))
        XCTAssertTrue(store.entries(for: access, scope: scope).isEmpty)
        XCTAssertEqual(store.lastKnownEntries(for: access, scope: scope), [model])
    }

    func testLastKnownRowsSurviveCredentialEpochInvalidationForRecoveryDisplay() {
        let store = ModelCatalogStore()
        XCTAssertTrue(store.alignCredentialEpoch(0, for: access))
        XCTAssertTrue(store.publishAutomatic(
            [model], access: access, scope: scope, credentialEpoch: 0))

        XCTAssertTrue(store.alignCredentialEpoch(1, for: access))

        XCTAssertEqual(store.snapshot(for: access, scope: scope).phase, .idle)
        XCTAssertEqual(store.lastKnownEntries(for: access, scope: scope), [model])
    }

    func testNewAuthoritativeEmptyCatalogClearsLastKnownRows() {
        let store = ModelCatalogStore()
        XCTAssertTrue(store.alignCredentialEpoch(0, for: access))
        XCTAssertTrue(store.publishAutomatic(
            [model], access: access, scope: scope, credentialEpoch: 0))
        XCTAssertTrue(store.alignCredentialEpoch(1, for: access))
        XCTAssertTrue(store.publishAutomatic(
            [], access: access, scope: scope, credentialEpoch: 1))

        XCTAssertEqual(store.snapshot(for: access, scope: scope).phase, .ready)
        XCTAssertTrue(store.lastKnownEntries(for: access, scope: scope).isEmpty)
    }

    /// The bug this guards, seen on a live Codex lane: several daemons share one CODEX_HOME, they
    /// all asked for a proactive refresh of a single-use grant at once, and the losers got
    /// `refresh_token_reused`. The daemon reported that as a sign-out and published an id-less empty
    /// catalog at the SAME credential epoch. Nothing had actually changed about the credential, but
    /// the rows were retired, the empty list was persisted, and a READY-and-empty snapshot reads to
    /// the picker as "this account has no models" — so the entire Codex section went blank and
    /// stayed blank across relaunches.
    func testAutomaticEmptyCatalogAtTheSameEpochKeepsCachedRows() {
        let store = ModelCatalogStore(cacheURL: nil)
        XCTAssertTrue(store.alignCredentialEpoch(0, for: access))
        XCTAssertTrue(store.publishAutomatic(
            [model], access: access, scope: scope, credentialEpoch: 0))

        XCTAssertTrue(store.publishAutomatic(
            [], access: access, scope: scope, credentialEpoch: 0))

        XCTAssertEqual(store.lastKnownEntries(for: access, scope: scope), [model])
        // Still retryable: a lifecycle clear is not a completed enumeration.
        XCTAssertFalse(store.hasProviderReportedCatalog(for: access, scope: scope))
    }

    /// The same clear signal arriving on the launch AFTER a working one. The cache is on disk with
    /// no recorded epoch, and "unknown" must not be read as a credential boundary — that reading is
    /// what made the blank picker survive every restart.
    func testAutomaticEmptyCatalogCannotEraseACacheLoadedFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cacheURL = directory.appendingPathComponent("catalog.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = ModelCatalogStore(cacheURL: cacheURL)
        XCTAssertTrue(first.alignCredentialEpoch(0, for: access))
        XCTAssertTrue(first.publishAutomatic(
            [model], access: access, scope: scope, credentialEpoch: 0))

        let relaunched = ModelCatalogStore(cacheURL: cacheURL)
        XCTAssertTrue(relaunched.alignCredentialEpoch(0, for: access))
        XCTAssertTrue(relaunched.publishAutomatic(
            [], access: access, scope: scope, credentialEpoch: 0))

        XCTAssertEqual(relaunched.lastKnownEntries(for: access, scope: scope), [model])
        let reloaded = ModelCatalogStore(cacheURL: cacheURL)
        XCTAssertEqual(reloaded.lastKnownEntries(for: access, scope: scope), [model])
    }

    /// An EXPLICIT refresh that enumerates nothing is a real answer about the account and still
    /// retires the rows. Only the id-less lifecycle shape is protected above.
    func testExplicitEmptyCatalogStillRetiresCachedRows() throws {
        let store = ModelCatalogStore(cacheURL: nil)
        XCTAssertTrue(store.alignCredentialEpoch(0, for: access))
        XCTAssertTrue(store.publishAutomatic(
            [model], access: access, scope: scope, credentialEpoch: 0))

        let ticket = try XCTUnwrap(store.beginExplicitRequest(
            access: access, scope: scope, credentialEpoch: 0))
        XCTAssertTrue(store.publish([], ticket: ticket))

        XCTAssertTrue(store.lastKnownEntries(for: access, scope: scope).isEmpty)
        XCTAssertTrue(store.hasProviderReportedCatalog(for: access, scope: scope))
    }

    func testLastKnownCatalogSurvivesStoreRelaunchForReconnectPicker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cacheURL = directory.appendingPathComponent("catalog.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = ModelCatalogStore(cacheURL: cacheURL)
        XCTAssertTrue(first.alignCredentialEpoch(0, for: access))
        XCTAssertTrue(first.publishAutomatic(
            [model], access: access, scope: scope, credentialEpoch: 0))

        let relaunched = ModelCatalogStore(cacheURL: cacheURL)
        XCTAssertEqual(relaunched.lastKnownEntries(for: access, scope: scope), [model])
        XCTAssertTrue(relaunched.entries(for: access, scope: scope).isEmpty)
    }
}

// MARK: - A managed Vertex lane must never cold-start on an undeclared model
//
// Reported from a Acme build: every turn failed with "The model claude-opus-5 is not available on
// your vertex deployment" (HTTP 404) even though the profile declares only 4.8, and the toolbar
// showed 4.8. Root cause: `availableModels` fell back to the GENERIC built-in list (Opus 5 first)
// instead of the profile-aware entries the picker and `selectModel` use. Several cold-start paths
// take `availableModels[0]`, so the lane selected `claude-opus-5`, stamped it on the conversation,
// and `modelIsKnownForCurrentAccess` — which consults the same generic list — then judged that
// undeclared id valid, so it was never corrected.

extension ModelCatalogStoreTests {
    private var acmeProfile: TenantProfile {
        TenantProfile(
            tenantId: "acme",
            displayName: "Acme",
            routes: [
                TenantProfile.Route(
                    routeId: "acme-claude-vertex",
                    adapter: "claude-vertex",
                    models: [
                        TenantProfile.Model(
                            id: "claude-opus-4-8", displayName: "Opus 4.8", isDefault: true),
                    ])
            ])
    }

    @MainActor
    func testAProfileDeclaringOnlyOpus48NeverOffersOpus5OnVertex() {
        let entries = AgentBridge.builtInCatalogEntries(for: .claudeVertex, profile: acmeProfile)

        XCTAssertEqual(entries.map(\.selection.modelID), ["claude-opus-4-8"])
        XCTAssertFalse(entries.contains { $0.selection.modelID == "claude-opus-5" },
                       "that deployment answers claude-opus-5 with a 404")
    }

    @MainActor
    func testTheColdStartDefaultForADeclaredVertexRouteIsTheDeclaredDefault() {
        // `availableModels[0]` is the cold-start selection, so the FIRST entry is the one that
        // decides whether a managed account's first turn succeeds or 404s.
        let first = AgentBridge.builtInCatalogEntries(
            for: .claudeVertex, profile: acmeProfile).first
        XCTAssertEqual(first?.selection.modelID, "claude-opus-4-8")
    }

    @MainActor
    func testNewConversationRejectsAStaleWorkspaceDefaultOutsideManagedDeclaration() {
        let selected = AgentBridge.initialModelSelection(
            for: .claudeVertex,
            workspaceSelection: ModelSelection(
                access: .claudeVertex, modelID: "claude-opus-5"),
            catalogEntries: [],
            profile: acmeProfile)

        XCTAssertEqual(selected, ModelSelection(
            access: .claudeVertex, modelID: "claude-opus-4-8"))
    }

    @MainActor
    func testNewConversationPreservesAnAllowedManagedWorkspaceDefault() {
        let selected = AgentBridge.initialModelSelection(
            for: .claudeVertex,
            workspaceSelection: ModelSelection(
                access: .claudeVertex, modelID: "claude-opus-4-8"),
            catalogEntries: [],
            profile: acmeProfile)

        XCTAssertEqual(selected.modelID, "claude-opus-4-8")
    }

    @MainActor
    func testUnmanagedConversationRetainsProviderDefaultPlaceholder() {
        let selected = AgentBridge.initialModelSelection(
            for: .claudeSubscription,
            workspaceSelection: nil,
            catalogEntries: [],
            profile: .default)

        XCTAssertEqual(selected, ModelSelection(access: .claudeSubscription, modelID: ""))
    }

    @MainActor
    func testDeclaredVertexModelRemainsVisibleThroughoutCatalogRefresh() {
        let fallback = AgentBridge.builtInCatalogEntries(
            for: .claudeVertex, profile: acmeProfile)
        let phases: [ModelCatalogSnapshot.Phase] = [
            .idle,
            .loading,
            .failed("Vertex rejected provider-default discovery"),
        ]

        for phase in phases {
            let entries = ModelPickerCatalogProjection.entries(
                snapshot: ModelCatalogSnapshot(
                    phase: phase, entries: [], credentialEpoch: 0, updatedAt: nil),
                isEligible: true,
                isReconnectable: false,
                hasAccountOperation: false,
                fallbackEntries: fallback,
                lastKnownEntries: [])

            XCTAssertEqual(entries.map(\.selection.modelID), ["claude-opus-4-8"], "\(phase)")
            XCTAssertFalse(entries.contains { $0.selection.modelID == "claude-opus-5" })
        }
    }

    @MainActor
    func testSignedDeclarationPublishesReadyWithoutClaimingProviderEvidence() {
        let store = ModelCatalogStore(cacheURL: nil)

        XCTAssertTrue(store.publishDeclared(
            access: .claudeVertex,
            scope: "/workspace",
            credentialEpoch: 0,
            profile: acmeProfile))

        let snapshot = store.snapshot(for: .claudeVertex, scope: "/workspace")
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertEqual(snapshot.entries.map(\.selection.modelID), ["claude-opus-4-8"])
        XCTAssertTrue(store.providerReported(for: .claudeVertex, scope: "/workspace").isEmpty)
        XCTAssertFalse(store.hasProviderReportedCatalog(
            for: .claudeVertex, scope: "/workspace"))
    }

    func testAcceptedEmptyProviderCatalogRetainsProviderProvenance() throws {
        let store = ModelCatalogStore(cacheURL: nil)
        let ticket = try XCTUnwrap(store.beginExplicitRequest(
            access: .claudeVertex,
            scope: "/workspace",
            credentialEpoch: 0))

        XCTAssertTrue(store.publish([], ticket: ticket))
        XCTAssertTrue(store.providerReported(
            for: .claudeVertex, scope: "/workspace").isEmpty)
        XCTAssertTrue(store.hasProviderReportedCatalog(
            for: .claudeVertex, scope: "/workspace"))
    }

    func testAutomaticEmptyVertexLifecycleClearRemainsRetryable() {
        let store = ModelCatalogStore(cacheURL: nil)
        XCTAssertTrue(store.alignCredentialEpoch(0, for: .claudeVertex))

        // Vertex sends this same id-less shape while ADC is checking/disconnected. It is a clear
        // signal, not evidence that a provider enumeration found no adjustable effort levels.
        XCTAssertTrue(store.publishAutomatic(
            [], access: .claudeVertex, scope: "/workspace", credentialEpoch: 0))

        XCTAssertFalse(store.hasProviderReportedCatalog(
            for: .claudeVertex, scope: "/workspace"))
        XCTAssertTrue(ConversationEffortCatalogPolicy.shouldRequestProviderRefresh(
            reportedEfforts: [], hasProviderCatalog: false))
    }

    func testSignedDeclarationKeepsRouteValidatedCachedEfforts() {
        let store = ModelCatalogStore(cacheURL: nil)
        XCTAssertTrue(store.alignCredentialEpoch(0, for: .claudeVertex))
        let live = ModelCatalogEntry(
            selection: ModelSelection(
                access: .claudeVertex, modelID: "claude-opus-4-8"),
            displayName: "Opus 4.8",
            description: "Provider-reported",
            resolvedModelID: "claude-opus-4-8",
            isDefault: false,
            supportedEfforts: ["low", "medium", "high", "xhigh", "max"],
            capabilities: ["effort", "adaptive_thinking"])
        XCTAssertTrue(store.publishAutomatic(
            [live], access: .claudeVertex, scope: "/workspace", credentialEpoch: 0))

        XCTAssertTrue(store.publishDeclared(
            access: .claudeVertex,
            scope: "/workspace",
            credentialEpoch: 0,
            profile: acmeProfile))

        XCTAssertEqual(
            store.snapshot(for: .claudeVertex, scope: "/workspace")
                .entries.first?.supportedEfforts,
            ["low", "medium", "high", "xhigh", "max"])
    }

    func testSignedDeclarationProvidesManagedVertexEffortsWithoutLiveDiscovery() {
        var profile = acmeProfile
        profile.routes[0].models[0].supportedEfforts = [
            "low", "medium", "high", "xhigh", "max",
        ]
        let store = ModelCatalogStore(cacheURL: nil)

        XCTAssertTrue(store.publishDeclared(
            access: .claudeVertex,
            scope: "/workspace",
            credentialEpoch: 0,
            profile: profile))

        let entry = store.snapshot(for: .claudeVertex, scope: "/workspace").entries.first
        XCTAssertEqual(entry?.supportedEfforts, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(entry?.capabilities, ["effort"])
        XCTAssertFalse(store.hasProviderReportedCatalog(
            for: .claudeVertex, scope: "/workspace"))
    }

    func testProviderCatalogProvenanceClearsWhenCredentialEpochAdvances() throws {
        let store = ModelCatalogStore(cacheURL: nil)
        let ticket = try XCTUnwrap(store.beginExplicitRequest(
            access: .claudeVertex,
            scope: "/workspace",
            credentialEpoch: 0))
        XCTAssertTrue(store.publish([], ticket: ticket))
        XCTAssertTrue(store.hasProviderReportedCatalog(
            for: .claudeVertex, scope: "/workspace"))

        XCTAssertTrue(store.alignCredentialEpoch(1, for: .claudeVertex))
        XCTAssertFalse(store.hasProviderReportedCatalog(
            for: .claudeVertex, scope: "/workspace"))
    }

    @MainActor
    func testAuthoritativeReadyEmptyCatalogDoesNotInventRows() {
        let fallback = AgentBridge.builtInCatalogEntries(
            for: .claudeVertex, profile: acmeProfile)
        let entries = ModelPickerCatalogProjection.entries(
            snapshot: ModelCatalogSnapshot(
                phase: .ready, entries: [], credentialEpoch: 0, updatedAt: Date()),
            isEligible: true,
            isReconnectable: false,
            hasAccountOperation: false,
            fallbackEntries: fallback,
            lastKnownEntries: [])

        XCTAssertTrue(entries.isEmpty)
    }

    /// A lane offering Reconnect used to render its section with a button and no rows whenever it
    /// had no cached catalog, which told the user nothing about what reconnecting would restore.
    /// The built-in list exists for exactly this and was simply unreachable from this branch.
    @MainActor
    func testAReconnectableLaneWithNoCachedRowsStillShowsTheBuiltInList() {
        let fallback = AgentBridge.fallbackEntries(for: .codexSubscription, scope: "account")
        let entries = ModelPickerCatalogProjection.entries(
            snapshot: ModelCatalogSnapshot(
                phase: .ready, entries: [], credentialEpoch: 0, updatedAt: Date()),
            isEligible: false,
            isReconnectable: true,
            hasAccountOperation: false,
            fallbackEntries: fallback,
            lastKnownEntries: [])

        XCTAssertFalse(entries.isEmpty)
        XCTAssertTrue(entries.contains { $0.selection.modelID == "gpt-5.6-sol" })
    }

    /// Cached rows remain the better answer when there are any: they are what this account was
    /// actually served, and the built-in list is only a guess.
    @MainActor
    func testAReconnectableLanePrefersItsCachedRowsOverTheBuiltInList() {
        let cached = ModelCatalogEntry(
            selection: ModelSelection(access: .codexSubscription, modelID: "gpt-5.6-terra"),
            displayName: "GPT-5.6-Terra",
            description: "",
            resolvedModelID: nil,
            isDefault: false,
            supportedEfforts: ["high"],
            capabilities: ["effort"])
        let entries = ModelPickerCatalogProjection.entries(
            snapshot: ModelCatalogSnapshot(
                phase: .ready, entries: [], credentialEpoch: 0, updatedAt: Date()),
            isEligible: false,
            isReconnectable: true,
            hasAccountOperation: false,
            fallbackEntries: AgentBridge.fallbackEntries(
                for: .codexSubscription, scope: "account"),
            lastKnownEntries: [cached])

        XCTAssertEqual(entries, [cached])
    }

    @MainActor
    func testAVertexRouteDeclaringNoModelsStillNeverGuessesTheNewestGeneration() {
        // Declaring nothing must not produce an empty lane — but it must not guess the newest
        // first-party model either, because a managed deployment is provisioned per project and
        // lags first-party availability.
        let profile = TenantProfile(
            tenantId: "acme", displayName: "Acme",
            routes: [TenantProfile.Route(routeId: "r", adapter: "claude-vertex")])
        let entries = AgentBridge.builtInCatalogEntries(for: .claudeVertex, profile: profile)

        XCTAssertFalse(entries.isEmpty)
        XCTAssertEqual(entries.first?.selection.modelID, "claude-opus-4-8")
        // Still selectable for a deployment that does carry it.
        XCTAssertTrue(entries.contains { $0.selection.modelID == "claude-opus-5" })
    }

    func testVertexColdStartOrderPrefersTheGenerationManagedProjectsActuallyCarry() {
        XCTAssertEqual(AgentBridge.builtInModels(for: .claudeVertex).first?.1, "claude-opus-4-8")
        // First-party lanes are unchanged: they track the newest generation.
        XCTAssertEqual(AgentBridge.builtInModels(for: .claudeSubscription).first?.1, "claude-opus-5")
        XCTAssertEqual(AgentBridge.builtInModels(for: .anthropicAPI).first?.1, "claude-opus-5")
    }
}

// MARK: - A conversation already stamped with an undeclared model must not stay dead
//
// Stopping the bad cold-start selection fixes new conversations. It does nothing for a conversation
// that was ALREADY stamped with `claude-opus-5` on a lane that never carried it: `performSend` sends
// the conversation's stamped selection, so that conversation answers 404 on every turn, forever,
// with no path back other than the user noticing and switching models by hand.

extension ModelCatalogStoreTests {
    private func entry(
        _ modelID: String,
        access: ModelAccess = .claudeVertex,
        resolved: String? = nil,
        isDefault: Bool = false
    ) -> ModelCatalogEntry {
        ModelCatalogEntry(
            selection: ModelSelection(access: access, modelID: modelID),
            displayName: modelID,
            description: "",
            resolvedModelID: resolved,
            isDefault: isDefault,
            supportedEfforts: [],
            capabilities: [])
    }

    @MainActor
    func testAStampedModelTheLaneDoesNotOfferIsHealedToItsDefault() {
        let healed = AgentBridge.healedSelection(
            stamped: ModelSelection(access: .claudeVertex, modelID: "claude-opus-5"),
            authoritativeEntries: [entry("claude-opus-4-8", isDefault: true)])

        XCTAssertEqual(healed?.modelID, "claude-opus-4-8")
        // The lane itself is never changed — this repairs a model, not a route.
        XCTAssertEqual(healed?.access, .claudeVertex)
    }

    @MainActor
    func testWithNoAuthoritativeListNothingIsChanged() {
        // THE load-bearing case. Treating a guess as authority is the original defect; healing
        // against a guess would repeat it with more confidence. A cold start with no published
        // catalog and no declared route must leave the stamp exactly as it found it.
        XCTAssertNil(AgentBridge.healedSelection(
            stamped: ModelSelection(access: .claudeVertex, modelID: "claude-opus-5"),
            authoritativeEntries: []))
    }

    @MainActor
    func testAnOfferedModelIsLeftAlone() {
        let stamped = ModelSelection(access: .claudeVertex, modelID: "claude-opus-4-8")
        XCTAssertNil(AgentBridge.healedSelection(
            stamped: stamped,
            authoritativeEntries: [
                entry("claude-opus-4-8", isDefault: true), entry("claude-opus-5"),
            ]),
            "an explicit, offered choice is never rewritten")
    }

    @MainActor
    func testAnAliasCountsAsOfferedRatherThanUnavailable() {
        // `sonnet` and its resolved generation are the same model. Rewriting one to the other would
        // be a visible model change with no cause behind it.
        XCTAssertNil(AgentBridge.healedSelection(
            stamped: ModelSelection(access: .claudeSubscription, modelID: "claude-sonnet-5-20260115"),
            authoritativeEntries: [
                entry("sonnet", access: .claudeSubscription,
                      resolved: "claude-sonnet-5-20260115", isDefault: true),
            ]))
    }

    @MainActor
    func testCodexEmptyModelIdIsADefaultNotAnUnavailableModel() {
        // Codex spells "the account default" as an empty id. Healing it would invent a selection the
        // user never made and break a lane that was working.
        XCTAssertNil(AgentBridge.healedSelection(
            stamped: ModelSelection(access: .codexSubscription, modelID: ""),
            authoritativeEntries: [entry("gpt-5.4-codex", access: .codexSubscription)]))
    }

    @MainActor
    func testManagedVertexEmptyPlaceholderHealsToConcreteDeclaredModel() {
        let healed = AgentBridge.healedSelection(
            stamped: ModelSelection(access: .claudeVertex, modelID: ""),
            authoritativeEntries: [entry("claude-opus-4-8", isDefault: true)])

        XCTAssertEqual(healed, ModelSelection(
            access: .claudeVertex, modelID: "claude-opus-4-8"))
    }

    @MainActor
    func testWithNoDeclaredDefaultTheFirstOfferedModelIsUsed() {
        let healed = AgentBridge.healedSelection(
            stamped: ModelSelection(access: .claudeVertex, modelID: "claude-opus-5"),
            authoritativeEntries: [entry("claude-opus-4-8"), entry("claude-haiku-4-5")])

        XCTAssertEqual(healed?.modelID, "claude-opus-4-8")
    }

    @MainActor
    func testTheAcmeDeploymentHealsOpus5ToTheModelItActuallyCarries() {
        // End to end against the shipped profile, through the same entry construction the picker
        // uses — this is the exact reported failure, in one assertion.
        let entries = AgentBridge.builtInCatalogEntries(for: .claudeVertex, profile: acmeProfile)
        let healed = AgentBridge.healedSelection(
            stamped: ModelSelection(access: .claudeVertex, modelID: "claude-opus-5"),
            authoritativeEntries: entries)

        XCTAssertEqual(healed?.modelID, "claude-opus-4-8")
    }

    @MainActor
    func testABackgroundConversationIsScopedToItsOwnWorkspaceNotTheOneOnScreen() {
        // Claude catalogs are workspace-scoped, so a background turn must be judged against its own
        // workspace's list. Scoping it to the foreground workspace could withhold a heal it needs —
        // or, worse, apply one from a workspace whose models have nothing to do with it.
        let bridge = AgentBridge(settingsBaseOverride: FileManager.default.temporaryDirectory
            .appendingPathComponent("heal-scope-\(UUID().uuidString)"), environmentOverride: [:])
        defer { bridge.shutdown() }
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("heal-scope-workspace-\(UUID().uuidString)").path
        let background = Conversation(
            title: "running while another workspace is on screen", cwd: elsewhere,
            sdkSessionId: nil,
            modelSelection: ModelSelection(access: .claudeVertex, modelID: "claude-opus-5"),
            messages: [], updatedAt: Date())

        XCTAssertEqual(bridge.catalogScope(for: .claudeVertex, conversation: background), elsewhere)
        XCTAssertNotEqual(bridge.catalogScope(for: .claudeVertex), elsewhere,
                          "omitting the conversation must still mean the foreground workspace")
        // Account-wide lanes are unaffected by which conversation is asking.
        XCTAssertEqual(bridge.catalogScope(for: .codexSubscription, conversation: background), "")
    }
}

// MARK: - A managed route's declared models outrank the provider's own catalog
//
// The earlier fixes above all live on the FALLBACK path — what a lane offers when its live catalog
// is unavailable. They could not help the Acme deployment, because that catalog is never
// unavailable: `supportedModels()` is answered by the local Claude Code runtime from its own
// build-time list, so it always succeeds and always leads with `default` → `claude-opus-5`.
//
// Measured, not assumed. Probing the pinned SDK with a nonexistent Vertex project, a nonexistent
// ADC file and no credentials of any kind still returned the full first-party catalog:
//
//     { value: "default", resolvedModel: "claude-opus-5", displayName: "Default",
//       description: "Use the default model (currently Opus 5)" }
//
// So on a managed lane that catalog is not evidence about the deployment, and every path that
// treated it as authority — the picker, `availableModels[0]`, the new-conversation stamp, and the
// self-heal's own notion of what the lane offers — selected a model the project answers with 404.

extension ModelCatalogStoreTests {
    /// The exact shape the runtime returns, reduced to the rows that matter.
    private func claudeRuntimeCatalog(access: ModelAccess) -> [ModelCatalogEntry] {
        [
            ModelCatalogEntry(
                selection: ModelSelection(access: access, modelID: "default"),
                displayName: "Default",
                description: "Use the default model (currently Opus 5)",
                resolvedModelID: "claude-opus-5",
                isDefault: false,
                supportedEfforts: ["low", "medium", "high", "xhigh", "max"],
                capabilities: ["effort", "adaptive_thinking"]),
            ModelCatalogEntry(
                selection: ModelSelection(access: access, modelID: "claude-fable-5-1"),
                displayName: "Fable", description: "", resolvedModelID: "claude-fable-5-1",
                isDefault: false, supportedEfforts: ["high"], capabilities: ["effort"]),
            ModelCatalogEntry(
                selection: ModelSelection(access: access, modelID: "claude-opus-4-8"),
                displayName: "Opus 4.8", description: "Previous Opus",
                resolvedModelID: "claude-opus-4-8",
                isDefault: false, supportedEfforts: ["low", "medium", "high", "max"],
                capabilities: ["effort", "adaptive_thinking"]),
        ]
    }

    /// The defect, stated as a test: the runtime's catalog offers `default`, `default` resolves to
    /// Opus 5, and the Acme project answers Opus 5 with a 404 on every single turn.
    @MainActor
    func testTheRuntimeCatalogCannotOfferAModelTheDeploymentNeverDeclared() {
        let constrained = ModelCatalogStore.constrained(
            claudeRuntimeCatalog(access: .claudeVertex),
            for: .claudeVertex,
            profile: acmeProfile)

        XCTAssertEqual(constrained.map(\.selection.modelID), ["claude-opus-4-8"])
        XCTAssertFalse(constrained.contains { $0.resolvedModelID == "claude-opus-5" },
                       "no row may resolve to a model this deployment cannot serve")
    }

    /// The alias trap, and the reason the declared id is always the wire id. `default` is a row the
    /// runtime re-resolves at request time, so honouring one would hand model choice straight back
    /// to the build-time list this constraint exists to overrule.
    @MainActor
    func testAnAliasRowIsNeverKeptEvenWhenItResolvesToADeclaredModel() {
        let aliasToDeclared = [
            ModelCatalogEntry(
                selection: ModelSelection(access: .claudeVertex, modelID: "opus"),
                displayName: "Opus", description: "", resolvedModelID: "claude-opus-4-8",
                isDefault: false, supportedEfforts: ["high"], capabilities: ["effort"]),
        ]
        let constrained = ModelCatalogStore.constrained(
            aliasToDeclared, for: .claudeVertex, profile: acmeProfile)

        XCTAssertEqual(constrained.map(\.selection.modelID), ["claude-opus-4-8"],
                       "the wire id must be the declared id, never the alias")
        XCTAssertNil(constrained.first?.resolvedModelID,
                     "an alias row's resolution must not be claimed by the declared row")
        // The alias row's capability metadata is still worth keeping.
        XCTAssertEqual(constrained.first?.supportedEfforts, ["high"])
    }

    /// The constraint must not cost the user the runtime's capability metadata — efforts drive the
    /// effort control, and dropping them would silently disable it on managed lanes.
    @MainActor
    func testADeclaredModelKeepsTheCapabilitiesTheRuntimeReported() {
        let entry = ModelCatalogStore.constrained(
            claudeRuntimeCatalog(access: .claudeVertex),
            for: .claudeVertex, profile: acmeProfile).first

        XCTAssertEqual(entry?.supportedEfforts, ["low", "medium", "high", "max"])
        XCTAssertEqual(entry?.capabilities, ["effort", "adaptive_thinking"])
        XCTAssertEqual(entry?.resolvedModelID, "claude-opus-4-8")
        XCTAssertEqual(entry?.displayName, "Opus 4.8")
        XCTAssertTrue(entry?.isDefault == true, "the profile's default decides the cold start")
    }

    /// A declared model the runtime has never heard of must still be offered: the deployment is the
    /// authority, and a Vertex publisher id may not appear in the runtime's list at all.
    @MainActor
    func testADeclaredModelAbsentFromTheRuntimeCatalogIsStillOffered() {
        let profile = TenantProfile(
            tenantId: "acme", displayName: "Acme",
            routes: [TenantProfile.Route(
                routeId: "r", adapter: "claude-vertex",
                models: [TenantProfile.Model(
                    id: "claude-opus-4-8@20260101", displayName: "Opus 4.8 (pinned)",
                    isDefault: true)])])

        let constrained = ModelCatalogStore.constrained(
            claudeRuntimeCatalog(access: .claudeVertex), for: .claudeVertex, profile: profile)

        XCTAssertEqual(constrained.map(\.selection.modelID), ["claude-opus-4-8@20260101"])
        XCTAssertEqual(constrained.first?.displayName, "Opus 4.8 (pinned)")
        XCTAssertTrue(constrained.first?.supportedEfforts.isEmpty == true,
                      "claiming efforts nobody reported would be a guess")
    }

    /// An unmanaged lane — and a managed route that declares nothing — must be untouched. This is
    /// the whole first-party product, so a regression here would be far worse than the bug.
    @MainActor
    func testALaneWithNoDeclaredModelsIsReturnedUnchanged() {
        let catalog = claudeRuntimeCatalog(access: .claudeSubscription)
        XCTAssertEqual(
            ModelCatalogStore.constrained(catalog, for: .claudeSubscription,
                                          profile: acmeProfile),
            catalog,
            "the Acme profile declares nothing for the subscription lane")

        let noModels = TenantProfile(
            tenantId: "acme", displayName: "Acme",
            routes: [TenantProfile.Route(routeId: "r", adapter: "claude-vertex")])
        XCTAssertEqual(
            ModelCatalogStore.constrained(claudeRuntimeCatalog(access: .claudeVertex),
                                          for: .claudeVertex, profile: noModels),
            claudeRuntimeCatalog(access: .claudeVertex))
    }

    /// Withholding is the cost of making this subtractive, so it has to be nameable — otherwise an
    /// admin learns about it from a support call instead of from the app.
    @MainActor
    func testWithheldModelsAreNameableRatherThanSilentlyDropped() {
        let withheld = ModelCatalogStore.withheldModelIDs(
            from: claudeRuntimeCatalog(access: .claudeVertex),
            for: .claudeVertex, profile: acmeProfile)

        XCTAssertEqual(withheld, ["default", "claude-fable-5-1"])
        XCTAssertTrue(
            ModelCatalogStore.withheldModelIDs(
                from: claudeRuntimeCatalog(access: .claudeSubscription),
                for: .claudeSubscription, profile: acmeProfile).isEmpty,
            "an unmanaged lane withholds nothing")
    }

    /// End to end through the store, which is what every consumer actually reads.
    @MainActor
    func testPublishingTheRuntimeCatalogOnAManagedLaneStoresOnlyDeclaredModels() {
        let store = ModelCatalogStore(cacheURL: nil)
        store.alignCredentialEpoch(1, for: .claudeVertex)
        store.publishAutomatic(
            claudeRuntimeCatalog(access: .claudeVertex),
            access: .claudeVertex, scope: "/w", credentialEpoch: 1)

        // NOTE: this asserts against the process-wide default profile, so it holds only that a
        // publish routes through the constraint at all; the profile-specific behaviour is covered
        // by the pure tests above.
        let published = store.snapshot(for: .claudeVertex, scope: "/w").entries
        XCTAssertEqual(
            published.map(\.selection.modelID),
            ModelCatalogStore.constrained(
                claudeRuntimeCatalog(access: .claudeVertex), for: .claudeVertex)
                .map(\.selection.modelID))
        // The unconstrained answer is retained for diagnostics, never for selection.
        XCTAssertEqual(store.providerReportedModelIDs(for: .claudeVertex),
                       ["claude-fable-5-1", "claude-opus-4-8", "default"])
    }

    /// The self-heal shipped earlier could not fire while the runtime catalog was authority: an
    /// already-stamped conversation asked "does this lane offer `default`?" and the catalog said
    /// yes. With the catalog constrained, the same conversation heals to a model that works.
    @MainActor
    func testAConversationStampedWithTheRuntimeDefaultHealsOnAManagedLane() {
        let stamped = ModelSelection(access: .claudeVertex, modelID: "default")
        let authoritative = ModelCatalogStore.constrained(
            claudeRuntimeCatalog(access: .claudeVertex),
            for: .claudeVertex, profile: acmeProfile)

        let healed = AgentBridge.healedSelection(
            stamped: stamped, authoritativeEntries: authoritative)

        XCTAssertEqual(healed?.modelID, "claude-opus-4-8")
    }
}
