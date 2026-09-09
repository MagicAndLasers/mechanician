import XCTest
@testable import Mechanician

/// FR-103 M1: the Claude-on-Vertex route is a first-class `ModelAccess` lane, activated only by a
/// tenant profile. These tests pin the identity plumbing and prove the public app is unchanged.
final class ModelAccessRouteTests: XCTestCase {

    @MainActor
    func testManagedClaudeRouteAuthoringOffersFable51() {
        XCTAssertTrue(ManagedConfigurationView.knownClaudeModels.contains {
            $0.id == "claude-fable-5-1" && $0.label == "Fable 5.1"
        })
    }

    func testExplicitSameAccessContextVariantChangeRetiresEverySessionScopedFact() {
        let previous = ModelSelection(
            access: .claudeVertex,
            modelID: "claude-sonnet-5")
        let replacement = ModelSelection(
            access: .claudeVertex,
            modelID: "claude-opus-4-8")
        var conversation = Conversation(
            title: "Vertex",
            cwd: "/tmp",
            sdkSessionId: "one-million-session",
            sdkSessionRouteIdentity: "route",
            sdkSessionExtensionRevision: UUID(),
            sdkSessionWorkspaceInstructionsRevision: "instructions",
            modelSelection: previous,
            messages: [TranscriptEntry(kind: .user, text: "Keep this history")],
            updatedAt: Date(),
            contextTokens: 118_927,
            contextWindow: 1_000_000,
            contextModel: previous.modelID)
        conversation.claudeEffectiveModel = previous.modelID

        XCTAssertTrue(AgentBridge.applyExplicitSameAccessModelSelection(
            replacement,
            to: &conversation))
        XCTAssertEqual(conversation.modelSelection, replacement)
        XCTAssertNil(conversation.sdkSessionId)
        XCTAssertNil(conversation.sdkSessionRouteIdentity)
        XCTAssertNil(conversation.sdkSessionExtensionRevision)
        XCTAssertNil(conversation.sdkSessionWorkspaceInstructionsRevision)
        XCTAssertNil(conversation.claudeEffectiveModel)
        XCTAssertNil(conversation.contextTokens)
        XCTAssertNil(conversation.contextWindow)
        XCTAssertNil(conversation.contextModel)
    }

    func testExplicitSameAccessModelChangeWorksInBothDirections() {
        let standard = ModelSelection(
            access: .claudeVertex,
            modelID: "claude-opus-4-8")
        let oneMillion = ModelSelection(
            access: .claudeVertex,
            modelID: "claude-sonnet-5")
        var conversation = Conversation(
            title: "Vertex",
            cwd: "/tmp",
            sdkSessionId: "standard-session",
            modelSelection: standard,
            messages: [],
            updatedAt: Date())

        XCTAssertTrue(AgentBridge.applyExplicitSameAccessModelSelection(
            oneMillion,
            to: &conversation))
        XCTAssertNil(conversation.sdkSessionId)
        conversation.sdkSessionId = "one-million-session"
        XCTAssertTrue(AgentBridge.applyExplicitSameAccessModelSelection(
            standard,
            to: &conversation))
        XCTAssertNil(conversation.sdkSessionId)
    }

    func testExactNoOpModelSelectionPreservesSessionAndMeter() {
        let selection = ModelSelection(
            access: .claudeVertex,
            modelID: "claude-sonnet-5")
        let revision = UUID()
        var conversation = Conversation(
            title: "Vertex",
            cwd: "/tmp",
            sdkSessionId: "healthy-session",
            sdkSessionRouteIdentity: "route",
            sdkSessionExtensionRevision: revision,
            sdkSessionWorkspaceInstructionsRevision: "instructions",
            modelSelection: selection,
            messages: [],
            updatedAt: Date(),
            contextTokens: 42_000,
            contextWindow: 1_000_000,
            contextModel: selection.modelID)

        XCTAssertFalse(AgentBridge.applyExplicitSameAccessModelSelection(
            selection,
            to: &conversation))
        XCTAssertEqual(conversation.sdkSessionId, "healthy-session")
        XCTAssertEqual(conversation.sdkSessionRouteIdentity, "route")
        XCTAssertEqual(conversation.sdkSessionExtensionRevision, revision)
        XCTAssertEqual(conversation.sdkSessionWorkspaceInstructionsRevision, "instructions")
        XCTAssertEqual(conversation.contextTokens, 42_000)
        XCTAssertEqual(conversation.contextWindow, 1_000_000)
        XCTAssertEqual(conversation.contextModel, selection.modelID)
    }

    func testSameAccessSelectionCannotRetagAConversationOwnedByAnotherLane() {
        var conversation = Conversation(
            title: "Claude",
            cwd: "/tmp",
            sdkSessionId: "subscription-session",
            modelSelection: .init(
                access: .claudeSubscription,
                modelID: "claude-opus-4-8"),
            messages: [],
            updatedAt: Date())

        XCTAssertFalse(AgentBridge.applyExplicitSameAccessModelSelection(
            .init(access: .claudeVertex, modelID: "claude-sonnet-5"),
            to: &conversation))
        XCTAssertEqual(conversation.sdkSessionId, "subscription-session")
        XCTAssertEqual(conversation.modelSelection?.access, .claudeSubscription)
    }

    func testAutomaticCatalogHealingCannotReuseUnavailableModelsOpaqueSession() {
        let unavailable = ModelSelection(
            access: .claudeVertex,
            modelID: "claude-opus-5")
        let healed = ModelSelection(
            access: .claudeVertex,
            modelID: "claude-opus-4-8")
        var conversation = Conversation(
            title: "Catalog changed",
            cwd: "/tmp",
            sdkSessionId: "unavailable-model-session",
            sdkSessionRouteIdentity: "route",
            sdkSessionExtensionRevision: UUID(),
            sdkSessionWorkspaceInstructionsRevision: "instructions",
            modelSelection: unavailable,
            messages: [TranscriptEntry(kind: .assistant, text: "Earlier work")],
            updatedAt: Date(),
            contextTokens: 118_927,
            contextWindow: 1_000_000,
            contextModel: unavailable.modelID)
        conversation.claudeEffectiveModel = unavailable.modelID

        XCTAssertTrue(AgentBridge.applyAutomaticModelHealing(
            healed,
            replacing: unavailable,
            to: &conversation))
        XCTAssertEqual(conversation.modelSelection, healed)
        XCTAssertNil(conversation.sdkSessionId)
        XCTAssertNil(conversation.sdkSessionRouteIdentity)
        XCTAssertNil(conversation.sdkSessionExtensionRevision)
        XCTAssertNil(conversation.sdkSessionWorkspaceInstructionsRevision)
        XCTAssertNil(conversation.claudeEffectiveModel)
        XCTAssertNil(conversation.contextTokens)
        XCTAssertNil(conversation.contextWindow)
        XCTAssertNil(conversation.contextModel)

        var raced = conversation
        raced.modelSelection = ModelSelection(
            access: .claudeVertex,
            modelID: "claude-sonnet-4-6")
        raced.sdkSessionId = "newer-session"
        XCTAssertFalse(AgentBridge.applyAutomaticModelHealing(
            healed,
            replacing: unavailable,
            to: &raced))
        XCTAssertEqual(raced.sdkSessionId, "newer-session")
        XCTAssertEqual(raced.modelSelection?.modelID, "claude-sonnet-4-6")
    }

    @MainActor
    func testRetiredSessionAndMeterConvergeAcrossDuplicateViewers() throws {
        let storeSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-change-store-\(UUID().uuidString)")
        let firstSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-change-first-\(UUID().uuidString)")
        let secondSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-change-second-\(UUID().uuidString)")
        let store = ConversationStore(
            appSupportBaseOverride: storeSupport,
            watchesDirectory: false)
        let first = AgentBridge(
            settingsBaseOverride: firstSupport,
            environmentOverride: [:],
            conversationStoreOverride: store)
        let second = AgentBridge(
            settingsBaseOverride: secondSupport,
            environmentOverride: [:],
            conversationStoreOverride: store)
        let id = UUID()
        let oldSelection = ModelSelection(
            access: .claudeVertex,
            modelID: "claude-sonnet-5")
        let conversation = Conversation(
            id: id,
            title: "Shared Vertex",
            cwd: "/tmp",
            sdkSessionId: "old-session",
            sdkSessionRouteIdentity: "route",
            sdkSessionExtensionRevision: UUID(),
            sdkSessionWorkspaceInstructionsRevision: "instructions",
            modelSelection: oldSelection,
            messages: [TranscriptEntry(kind: .user, text: "Earlier work")],
            updatedAt: Date(),
            contextTokens: 118_927,
            contextWindow: 1_000_000,
            contextModel: oldSelection.modelID)
        store.upsert(conversation)
        defer {
            AgentBridge.live.remove(first)
            AgentBridge.live.remove(second)
            first.currentID = nil
            second.currentID = nil
            first.shutdown()
            second.shutdown()
            store.flushSaves()
            try? FileManager.default.removeItem(at: storeSupport)
            try? FileManager.default.removeItem(at: firstSupport)
            try? FileManager.default.removeItem(at: secondSupport)
        }
        first.currentID = id
        second.currentID = id
        first.restoreContextUsage(from: conversation)
        second.restoreContextUsage(from: conversation)
        AgentBridge.live.add(first)
        AgentBridge.live.add(second)

        var changed = false
        let replacement = ModelSelection(
            access: .claudeVertex,
            modelID: "claude-opus-4-8")
        let updated = try XCTUnwrap(store.update(id) {
            changed = AgentBridge.applyExplicitSameAccessModelSelection(
                replacement,
                to: &$0)
        })
        XCTAssertTrue(changed)
        for bridge in [first, second] {
            bridge.clearLiveProviderSessionContext()
            bridge.restoreContextUsage(from: updated)
            XCTAssertEqual(bridge.contextTokens, 0)
            XCTAssertNil(bridge.reportedContextWindow)
            XCTAssertNil(bridge.reportedCompactionThreshold)
            XCTAssertNil(bridge.contextUsageModel)
        }
        XCTAssertNil(store.conversation(id)?.sdkSessionId)
        XCTAssertEqual(store.conversation(id)?.modelSelection, replacement)
    }

    func testBuiltInCasesAreTheOriginalFour() {
        XCTAssertEqual(
            ModelAccess.builtInCases,
            [.claudeSubscription, .anthropicAPI, .codexSubscription, .openAIAPI])
    }

    func testPublicBuildEnumeratesOnlyBuiltInRoutes() {
        // In tests there is no embedded tenant.json ⇒ TenantProfile.current == .default ⇒ no
        // enterprise routes ⇒ allCases is byte-for-byte the pre-M1 set. This is the guarantee that
        // account probing / the model picker / catalog refresh are unchanged for the public app.
        XCTAssertTrue(TenantProfile.current.isDefault)
        XCTAssertEqual(ModelAccess.allCases, ModelAccess.builtInCases)
        XCTAssertFalse(ModelAccess.allCases.contains(.claudeVertex))
    }

    func testAdapterInitMapsOnlyEnterpriseAdapters() {
        XCTAssertEqual(ModelAccess(adapter: "claude-vertex"), .claudeVertex)
        // Built-in adapters are always present via builtInCases and must not be re-created from a profile.
        XCTAssertNil(ModelAccess(adapter: "claude-subscription"))
        XCTAssertNil(ModelAccess(adapter: "anthropic-api"))
        XCTAssertNil(ModelAccess(adapter: "nonsense"))
    }

    func testProviderAuthInitRecognizesVertex() {
        XCTAssertEqual(ModelAccess(provider: "anthropic", authMode: "vertex"), .claudeVertex)
        // Existing mappings are unchanged.
        XCTAssertEqual(ModelAccess(provider: "anthropic", authMode: "subscription"), .claudeSubscription)
        XCTAssertEqual(ModelAccess(provider: "anthropic", authMode: "apikey"), .anthropicAPI)
        XCTAssertEqual(ModelAccess(provider: "anthropic", authMode: ""), .anthropicAPI)
        XCTAssertEqual(ModelAccess(provider: "codex", authMode: "subscription"), .codexSubscription)
        XCTAssertEqual(ModelAccess(provider: "openai", authMode: "apikey"), .openAIAPI)
    }

    func testVertexIsAClaudeMakerLane() {
        XCTAssertEqual(ModelAccess.claudeVertex.maker, .anthropic)
        XCTAssertEqual(ModelAccess.claudeVertex.rawValue, "claude_vertex")        // Codable stability
        XCTAssertEqual(ModelAccess(rawValue: "claude_vertex"), .claudeVertex)
        XCTAssertEqual(ModelAccess.claudeVertex.accountChoice, "vertex")
        XCTAssertEqual(ModelAccess.claudeVertex.displayName, "Claude (Vertex)")
        XCTAssertEqual(ModelAccess(accountChoice: "vertex"), .claudeVertex)
        XCTAssertEqual(ModelAccess(accountChoice: "subscription"), .claudeSubscription)
        XCTAssertEqual(ModelAccess(accountChoice: "codex"), .codexSubscription)
        XCTAssertEqual(ModelAccess(accountChoice: "openai"), .openAIAPI)
        XCTAssertEqual(ModelAccess(accountChoice: "apikey"), .anthropicAPI)
        XCTAssertTrue(ModelAccess.claudeVertex.usesInteractiveAccountFlow)
        XCTAssertFalse(ModelAccess.anthropicAPI.usesInteractiveAccountFlow)
    }

    func testProfileRoutesBecomeEnterpriseAccesses() {
        let profile = TenantProfile(
            tenantId: "acme",
            displayName: "Mechanician for Acme",
            routes: [
                TenantProfile.Route(routeId: "acme-claude-vertex", adapter: "claude-vertex", isDefault: true),
                // A duplicate and a built-in adapter must not add extra lanes.
                TenantProfile.Route(routeId: "dup", adapter: "claude-vertex"),
                TenantProfile.Route(routeId: "builtin", adapter: "claude-subscription"),
            ])
        XCTAssertEqual(profile.enterpriseAccesses, [.claudeVertex])
    }

    func testDefaultProfileActivatesNoEnterpriseRoutes() {
        XCTAssertTrue(TenantProfile.default.enterpriseAccesses.isEmpty)
    }

    func testVertexSessionResumesOnlyForItsExactSignedRoute() {
        let profile = TenantProfile(
            tenantId: "acme",
            displayName: "Acme",
            routes: [
                .init(
                    routeId: "acme-vertex",
                    adapter: "claude-vertex",
                    vertex: .init(projectId: "acme-claude-code", region: "global")),
            ])
        let identity = try! XCTUnwrap(profile.routeIdentity(for: .claudeVertex))
        var conversation = Conversation(
            title: "Vertex",
            cwd: "/tmp",
            sdkSessionId: "vertex-session",
            sdkSessionRouteIdentity: identity,
            modelSelection: .init(access: .claudeVertex, modelID: "claude-opus"),
            messages: [],
            updatedAt: Date())

        XCTAssertEqual(
            AgentBridge.resumableSessionID(
                for: conversation, access: .claudeVertex, profile: profile),
            "vertex-session")

        var differentBackend = profile
        differentBackend.routes[0].vertex?.projectId = "other-project"
        XCTAssertNil(AgentBridge.resumableSessionID(
            for: conversation, access: .claudeVertex, profile: differentBackend))

        conversation.sdkSessionRouteIdentity = nil // legacy Vertex sidecar
        XCTAssertNil(AgentBridge.resumableSessionID(
            for: conversation, access: .claudeVertex, profile: profile))
    }

    func testBuiltInSessionResumeBehaviorDoesNotRequireEnterpriseFingerprint() {
        let conversation = Conversation(
            title: "Claude",
            cwd: "/tmp",
            sdkSessionId: "subscription-session",
            modelSelection: .init(access: .claudeSubscription, modelID: "claude-opus"),
            messages: [],
            updatedAt: Date())

        XCTAssertEqual(
            AgentBridge.resumableSessionID(
                for: conversation, access: .claudeSubscription, profile: .default),
            "subscription-session")
    }

    func testClaudeSessionResumesOnlyWithTheMCPConfigurationItMounted() {
        let mountedRevision = UUID()
        let conversation = Conversation(
            title: "Claude with Confluence",
            cwd: "/tmp",
            sdkSessionId: "subscription-session",
            sdkSessionExtensionRevision: mountedRevision,
            modelSelection: .init(access: .claudeSubscription, modelID: "claude-opus"),
            messages: [],
            updatedAt: Date())

        XCTAssertEqual(
            AgentBridge.resumableSessionID(
                for: conversation, access: .claudeSubscription, profile: .default,
                extensionRevision: mountedRevision),
            "subscription-session")
        XCTAssertNil(AgentBridge.resumableSessionID(
            for: conversation, access: .claudeSubscription, profile: .default,
            extensionRevision: UUID()))
        // Removing all external tools is also a schema change: do not retain the old MCP tools.
        XCTAssertNil(AgentBridge.resumableSessionID(
            for: conversation, access: .claudeSubscription, profile: .default,
            extensionRevision: nil))
    }

    func testAnthropicSessionRevisionIncludesBuiltInAndExternalTools() {
        let external = UUID()
        let withoutExternal = AgentBridge.anthropicSessionConfigurationRevision(
            externalRevision: nil,
            use1M: true,
            permissionMode: "default")
        let withExternal = AgentBridge.anthropicSessionConfigurationRevision(
            externalRevision: external,
            use1M: true,
            permissionMode: "default")

        XCTAssertEqual(
            withoutExternal,
            AgentBridge.anthropicSessionConfigurationRevision(
                externalRevision: nil,
                use1M: true,
                permissionMode: "default"))
        XCTAssertEqual(
            withExternal,
            AgentBridge.anthropicSessionConfigurationRevision(
                externalRevision: external,
                use1M: true,
                permissionMode: "default"))
        XCTAssertNotEqual(withoutExternal, withExternal)
        XCTAssertNotEqual(
            withExternal,
            AgentBridge.anthropicSessionConfigurationRevision(
                externalRevision: UUID(),
                use1M: true,
                permissionMode: "default"))
    }

    func testOneMillionPreferenceIsAFirstPartyClaudeSessionRevisionBoundary() {
        let external = UUID()
        for access in [ModelAccess.claudeSubscription, .anthropicAPI] {
            let enabled = AgentBridge.providerSessionConfigurationRevision(
                for: access,
                externalRevision: external,
                use1M: true,
                permissionMode: "default")
            let disabled = AgentBridge.providerSessionConfigurationRevision(
                for: access,
                externalRevision: external,
                use1M: false,
                permissionMode: "default")
            XCTAssertNotEqual(enabled, disabled, "\(access) must not resume across variants")

            var conversation = Conversation(
                title: "First-party Claude",
                cwd: "/tmp",
                sdkSessionId: "one-million-session",
                sdkSessionExtensionRevision: enabled,
                modelSelection: .init(access: access, modelID: "claude-opus-4-8"),
                messages: [],
                updatedAt: Date())
            XCTAssertNil(AgentBridge.resumableSessionID(
                for: conversation,
                access: access,
                profile: .default,
                extensionRevision: disabled))
            conversation.sdkSessionExtensionRevision = disabled
            XCTAssertEqual(AgentBridge.resumableSessionID(
                for: conversation,
                access: access,
                profile: .default,
                extensionRevision: disabled), "one-million-session")
        }
    }

    func testOneMillionPreferencePassesThroughManagedAndOpenAILanes() {
        let external = UUID()
        for access in [
            ModelAccess.claudeVertex, .claudeBedrock, .codexSubscription, .openAIAPI,
        ] {
            XCTAssertEqual(
                AgentBridge.providerSessionConfigurationRevision(
                    for: access,
                    externalRevision: external,
                    use1M: true,
                    permissionMode: "default"),
                AgentBridge.providerSessionConfigurationRevision(
                    for: access,
                    externalRevision: external,
                    use1M: false,
                    permissionMode: "default"),
                "\(access) does not consume the first-party 1M preference")
        }
    }

    func testOneMillionRestartPlanIsFirstPartyAndIncludesSelectedColdLane() {
        XCTAssertEqual(
            AgentBridge.oneMillionContextRestartAccesses(
                runtimeAccesses: [
                    .claudeSubscription, .anthropicAPI, .claudeVertex,
                    .claudeBedrock, .codexSubscription, .openAIAPI,
                ],
                selectedAccess: .claudeVertex),
            [.claudeSubscription, .anthropicAPI])
        XCTAssertEqual(
            AgentBridge.oneMillionContextRestartAccesses(
                runtimeAccesses: [],
                selectedAccess: .claudeSubscription),
            [.claudeSubscription],
            "the selected lane must be replaced even before it reaches the runtime dictionary")
        XCTAssertTrue(AgentBridge.oneMillionContextRestartAccesses(
            runtimeAccesses: [.claudeVertex, .claudeBedrock, .codexSubscription],
            selectedAccess: .claudeBedrock).isEmpty)
    }

    func testOneMillionChangeBlocksOnlyFirstPartyClaudeProviderWork() {
        XCTAssertTrue(AgentBridge.oneMillionContextChangeBlocked(
            activeProviderAccesses: [.claudeSubscription]))
        XCTAssertTrue(AgentBridge.oneMillionContextChangeBlocked(
            activeProviderAccesses: [.anthropicAPI, .claudeVertex]))
        XCTAssertFalse(AgentBridge.oneMillionContextChangeBlocked(
            activeProviderAccesses: [.claudeVertex, .claudeBedrock, .codexSubscription]))
        XCTAssertFalse(AgentBridge.oneMillionContextChangeBlocked(activeProviderAccesses: []))
    }

    @MainActor
    func testOneMillionChangeRefusesProcessWideActiveTurnBeforePreferenceMutation() {
        let defaults = UserDefaults.standard
        let priorValue = defaults.object(forKey: "use1MContext")
        let current = (priorValue as? Bool) ?? true
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("one-million-block-\(UUID().uuidString)")
        let store = ConversationStore(
            appSupportBaseOverride: support,
            watchesDirectory: false)
        let requester = AgentBridge(
            settingsBaseOverride: support.appendingPathComponent("requester"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        let worker = AgentBridge(
            settingsBaseOverride: support.appendingPathComponent("worker"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        AgentBridge.live.add(requester)
        AgentBridge.live.add(worker)
        defer {
            AgentBridge.live.remove(requester)
            AgentBridge.live.remove(worker)
            requester.shutdown()
            worker.shutdown()
            store.flushSaves()
            if let priorValue {
                defaults.set(priorValue, forKey: "use1MContext")
            } else {
                defaults.removeObject(forKey: "use1MContext")
            }
            try? FileManager.default.removeItem(at: support)
        }

        worker.stageRootWorkForTesting(
            conversationID: UUID(),
            turnID: "active-first-party-turn",
            selection: .init(
                access: .claudeSubscription,
                modelID: "claude-opus-4-8"))

        XCTAssertFalse(requester.setOneMillionContextEnabled(!current))
        XCTAssertEqual(
            (defaults.object(forKey: "use1MContext") as? Bool) ?? true,
            current,
            "the work audit must finish before UserDefaults advances")
        XCTAssertNotNil(requester.oneMillionContextChangeMessage)
    }

    func testAnthropicContextWindowResolvesOneMillionTokenCatalogAliases() {
        XCTAssertEqual(
            AgentBridge.anthropicContextWindow(
                selectedModelID: "default",
                resolvedModelID: "claude-opus-4-8[1m]",
                use1M: true,
                automaticallyUpgradesBareOpus: true),
            1_000_000)
        XCTAssertEqual(
            AgentBridge.anthropicContextWindow(
                selectedModelID: "claude-opus-4-8[1m]",
                resolvedModelID: nil,
                use1M: true,
                automaticallyUpgradesBareOpus: false),
            1_000_000)
        XCTAssertEqual(
            AgentBridge.anthropicContextWindow(
                selectedModelID: "claude-opus-4-8",
                resolvedModelID: "claude-opus-4-8",
                use1M: true,
                automaticallyUpgradesBareOpus: true),
            200_000)
        for modelID in [
            "claude-fable-5",
            "claude-fable-5-1",
            "claude-mythos-5",
            "claude-mythos-5-1",
            "claude-opus-5",
            "claude-sonnet-5",
        ] {
            XCTAssertEqual(
                AgentBridge.anthropicContextWindow(
                    selectedModelID: modelID,
                    resolvedModelID: modelID,
                    use1M: false,
                    automaticallyUpgradesBareOpus: false),
                1_000_000,
                "\(modelID) has a 1M context window by default")
        }
    }

    /// Mirrors "a third-party route gets 1M only for the model that declares it" in
    /// agentd/test/claude-turn-options.test.mjs. The pinned engine gates 1M on Vertex, Bedrock and
    /// Foundry behind `context.native_1m_3p[route]`, and `claude-sonnet-5` is the only declarer, so
    /// the meter must not show a 1M denominator for Opus 5 on a managed route.
    func testAnthropicContextWindowIsTwoHundredKForNativeOneMillionModelsOnThirdPartyRoutes() {
        for modelID in [
            "claude-fable-5",
            "claude-fable-5-1",
            "claude-mythos-5",
            "claude-mythos-5-1",
            "claude-opus-5",
        ] {
            XCTAssertEqual(
                AgentBridge.anthropicContextWindow(
                    selectedModelID: modelID,
                    resolvedModelID: modelID,
                    use1M: true,
                    automaticallyUpgradesBareOpus: false,
                    thirdPartyRoute: true),
                200_000,
                "\(modelID) is native_1m on first party only")
        }
        XCTAssertEqual(
            AgentBridge.anthropicContextWindow(
                selectedModelID: "claude-sonnet-5",
                resolvedModelID: "claude-sonnet-5",
                use1M: true,
                automaticallyUpgradesBareOpus: false,
                thirdPartyRoute: true),
            1_000_000,
            "claude-sonnet-5 declares native_1m_3p for bedrock, vertex and foundry")
        // A Bedrock inference profile has to canonicalize to the same model.
        XCTAssertEqual(
            AgentBridge.anthropicContextWindow(
                selectedModelID: "global.anthropic.claude-opus-5",
                resolvedModelID: "global.anthropic.claude-opus-5",
                use1M: true,
                automaticallyUpgradesBareOpus: false,
                thirdPartyRoute: true),
            200_000)
        XCTAssertEqual(
            AgentBridge.anthropicContextWindow(
                selectedModelID: "us.anthropic.claude-sonnet-5",
                resolvedModelID: "us.anthropic.claude-sonnet-5",
                use1M: true,
                automaticallyUpgradesBareOpus: false,
                thirdPartyRoute: true),
            1_000_000)
        // First party is unchanged.
        XCTAssertEqual(
            AgentBridge.anthropicContextWindow(
                selectedModelID: "claude-opus-5",
                resolvedModelID: "claude-opus-5",
                use1M: true,
                automaticallyUpgradesBareOpus: true),
            1_000_000)
    }

    func testLegacyClaudeSessionStartsFreshWhenExternalToolsAreConfigured() {
        let conversation = Conversation(
            title: "Legacy",
            cwd: "/tmp",
            sdkSessionId: "legacy-session",
            modelSelection: .init(access: .claudeSubscription, modelID: "claude-opus"),
            messages: [],
            updatedAt: Date())

        XCTAssertNil(AgentBridge.resumableSessionID(
            for: conversation, access: .claudeSubscription, profile: .default,
            extensionRevision: UUID()))
    }

    func testRemovedProfileCannotRestoreVertexAsTheHomeRoute() {
        XCTAssertEqual(
            AgentBridge.startupAccess(
                savedAccess: .claudeVertex,
                availableAccesses: ModelAccess.builtInCases,
                profileDefault: nil),
            .anthropicAPI)
        XCTAssertEqual(
            AgentBridge.startupAccess(
                savedAccess: .claudeVertex,
                availableAccesses: ModelAccess.builtInCases + [.claudeVertex],
                profileDefault: .claudeVertex),
            .claudeVertex)
        XCTAssertEqual(
            AgentBridge.startupAccess(
                savedAccess: .anthropicAPI,
                availableAccesses: [.openAIAPI],
                profileDefault: .claudeVertex),
            .openAIAPI,
            "a disallowed profile default must not beat an available managed lane")
        XCTAssertEqual(
            AgentBridge.startupAccess(
                savedAccess: .anthropicAPI,
                availableAccesses: [.openAIAPI, .claudeSubscription],
                profileDefault: .claudeSubscription),
            .claudeSubscription)
    }

    // MARK: - Codex MCP session invalidation

    /// Measured against the pinned Codex binary: a thread binds its MCP server set when it is
    /// created. After adding a server, `mcpServerStatus/list` shows it process-wide while the
    /// existing thread still answers "unknown MCP server". Without invalidation a Codex
    /// conversation could never reach a server the user just added.
    func testCodexSessionResumesOnlyWithTheMCPConfigurationItMounted() {
        let mounted = AgentBridge.codexSessionConfigurationRevision(externalRevision: UUID())
        var conversation = Conversation(
            title: "Codex",
            cwd: "/tmp",
            sdkSessionId: "codex-thread",
            sdkSessionExtensionRevision: mounted,
            modelSelection: .init(access: .codexSubscription, modelID: "gpt-5.6"),
            messages: [],
            updatedAt: Date())

        XCTAssertEqual(
            AgentBridge.resumableSessionID(
                for: conversation, access: .codexSubscription, profile: .default,
                extensionRevision: mounted),
            "codex-thread")

        let afterAddingAServer = AgentBridge.codexSessionConfigurationRevision(
            externalRevision: UUID())
        XCTAssertNil(
            AgentBridge.resumableSessionID(
                for: conversation, access: .codexSubscription, profile: .default,
                extensionRevision: afterAddingAServer),
            "a changed server set must start a new thread")

        conversation.sdkSessionExtensionRevision = nil
        XCTAssertNil(
            AgentBridge.resumableSessionID(
                for: conversation, access: .codexSubscription, profile: .default,
                extensionRevision: mounted),
            "a pre-MCP Codex session is rebased once")
    }

    /// If both lanes derived the same revision from one extension set, a change on one would look
    /// like no change on the other.
    func testEachMakerDerivesItsOwnSessionRevision() {
        let external = UUID()

        let anthropic = AgentBridge.anthropicSessionConfigurationRevision(
            externalRevision: external,
            use1M: true,
            permissionMode: "default")
        let codex = AgentBridge.codexSessionConfigurationRevision(externalRevision: external)

        XCTAssertNotEqual(anthropic, codex)
        XCTAssertEqual(codex, AgentBridge.codexSessionConfigurationRevision(externalRevision: external),
                       "the same inputs must always give the same revision")
    }

    /// These materials are load-bearing history. Plan's narrower Help schema intentionally
    /// rebases Anthropic sessions once and then separates Plan from the shared non-Plan class;
    /// refactoring must not cause another replay.
    func testPlanHelpToolGenerationIsPinnedForOpaqueProviderSessions() {
        XCTAssertEqual(
            AgentBridge.anthropicSessionConfigurationRevision(
                externalRevision: nil,
                use1M: true,
                permissionMode: "default").uuidString,
            "304FF8B6-7C05-5376-B22C-D4A0EAE36555")
        XCTAssertEqual(
            AgentBridge.anthropicSessionConfigurationRevision(
                externalRevision: nil,
                use1M: false,
                permissionMode: "default").uuidString,
            "ECBD679F-4511-5C14-83B1-2B565B7FDC04")
        XCTAssertEqual(
            AgentBridge.anthropicSessionConfigurationRevision(
                externalRevision: nil,
                use1M: true,
                permissionMode: "plan").uuidString,
            "569C27D8-C4C8-5BCC-A0F9-0072261E54AC")
        XCTAssertEqual(
            AgentBridge.codexSessionConfigurationRevision(externalRevision: nil).uuidString,
            "589BB181-BC79-513C-969B-20C1BACBC2E1")
        XCTAssertEqual(
            AgentBridge.providerSessionConfigurationRevision(
                for: .codexSubscription,
                externalRevision: nil,
                use1M: true,
                permissionMode: "plan").uuidString,
            "93F4825C-C685-52D3-AFA6-594DCD647C83")
    }

    func testProviderResidencyAdvisoryTargetsOnlyTheCodexLane() {
        XCTAssertEqual(
            AgentBridge.providerResidencyActivity(
                for: .codexSubscription, selectedAccess: .codexSubscription),
            true)
        XCTAssertEqual(
            AgentBridge.providerResidencyActivity(
                for: .codexSubscription, selectedAccess: .claudeSubscription),
            false)
        for access in ModelAccess.allCases where access != .codexSubscription {
            XCTAssertNil(AgentBridge.providerResidencyActivity(
                for: access, selectedAccess: .codexSubscription))
        }
    }

    func testProviderResidencyIsReconciledAtEveryCoherentLaneBoundary() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = tests
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Mechanician/AgentBridge.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        func body(from start: String, until end: String) throws -> Substring {
            let startRange = try XCTUnwrap(text.range(of: start))
            let endRange = try XCTUnwrap(text.range(of: end, range: startRange.upperBound..<text.endIndex))
            return text[startRange.lowerBound..<endRange.lowerBound]
        }

        XCTAssertTrue(try body(
            from: "private func applyModelSelectionIfCompatible",
            until: "private func providerSettings").contains("reconcileProviderResidency"))
        XCTAssertTrue(try body(
            from: "private func recordReady",
            until: "private func cacheCodexModels").contains("reconcileProviderResidency"))
        XCTAssertTrue(try body(
            from: "private func activateAccessChange",
            until: "private func retargetCurrentConversation").contains("reconcileProviderResidency"))
        XCTAssertEqual(text.components(separatedBy: "reconcileProviderResidency(").count - 1, 4)
    }

    func testIdleProviderExposureWaitsForSelectedConversationPersistence() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = tests
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Mechanician/AgentBridge.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        func body(from start: String, until end: String) throws -> Substring {
            let startRange = try XCTUnwrap(text.range(of: start))
            let endRange = try XCTUnwrap(
                text.range(of: end, range: startRange.upperBound..<text.endIndex))
            return text[startRange.lowerBound..<endRange.lowerBound]
        }

        XCTAssertTrue(try body(
            from: "var canStartCodexReviewCurrentChanges: Bool",
            until: "var canExportCodexLifecycleDiagnostics").contains(
                "store.isDurablyCurrent(conversation.id)"))
        XCTAssertTrue(try body(
            from: "func noteComposerActivity(now:",
            until: "private func resumableSessionID(").contains(
                "store.isDurablyCurrent(id)"))
    }
}
