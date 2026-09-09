import XCTest
@testable import Mechanician

@MainActor
final class ProviderAccountSemanticsTests: XCTestCase {
    func testSubscriptionConnectionActionUsesOnePolicyForBothProviders() {
        for state in [
            ProviderAccountStore.State.checking,
            .disconnected,
            .unavailable("runtime unavailable"),
        ] {
            XCTAssertEqual(
                ProviderAccountStore.subscriptionConnectionAction(
                    state: state, requiresReconnect: false),
                .connect)
        }

        for state in [
            ProviderAccountStore.State.connected(detail: "ChatGPT Pro"),
            .configured,
            .managed(detail: "Managed externally", usable: true),
        ] {
            XCTAssertEqual(
                ProviderAccountStore.subscriptionConnectionAction(
                    state: state, requiresReconnect: false),
                .reconnect)
        }
        for state in [
            ProviderAccountStore.State.checking,
            .disconnected,
            .unavailable("runtime unavailable"),
        ] {
            XCTAssertEqual(
                ProviderAccountStore.subscriptionConnectionAction(
                    state: state, requiresReconnect: true),
                .reconnect)
        }
    }

    func testAccountStatusLanguageDoesNotChangeByProvider() {
        XCTAssertEqual(
            ProviderAccountStore.State.connected(detail: "ChatGPT Pro").statusLabel,
            "Connected")
        XCTAssertEqual(
            ProviderAccountStore.State.connected(detail: "Claude subscription").statusLabel,
            "Connected")
        XCTAssertEqual(ProviderAccountStore.State.disconnected.statusLabel, "Not connected")
        XCTAssertEqual(
            ProviderAccountStore.State.configured.statusLabel,
            "Sign-in saved, verified when used")
    }

    func testOnlyVerifiedConnectAndReconnectCompletionsReactivateTheApp() {
        XCTAssertTrue(
            ProviderAccountStore.shouldReactivateApp(
                afterVerifiedCompletionOf: .connecting))
        XCTAssertTrue(
            ProviderAccountStore.shouldReactivateApp(
                afterVerifiedCompletionOf: .reconnecting))

        for operation in [
            ProviderAccountStore.Operation.signingOut,
            .savingCredential,
            .removingCredential,
        ] {
            XCTAssertFalse(
                ProviderAccountStore.shouldReactivateApp(
                    afterVerifiedCompletionOf: operation),
                "\(operation) must not steal focus when it finishes")
        }
        XCTAssertFalse(
            ProviderAccountStore.shouldReactivateApp(afterVerifiedCompletionOf: nil),
            "passive cold-start readiness has no user-owned account operation")
    }

    func testVertexSavedSignInDemotionRequiresGoogleReauthentication() {
        let store = ProviderAccountStore()
        store.report(access: .claudeVertex, connected: true, detail: "Claude (Vertex)")

        let message = store.reportRuntimeAccountState(
            access: .claudeVertex,
            connected: false,
            previousRuntimeReady: true,
            previousRuntimeLoggedIn: true,
            accountStatus: "disconnected")

        XCTAssertEqual(
            message,
            "Your Google sign-in expired or was revoked. Reauthenticate with Google to continue using Google Vertex.")
        XCTAssertEqual(store.state(for: .claudeVertex), .disconnected)
        XCTAssertEqual(store.error(for: .claudeVertex), message)
        XCTAssertTrue(store.requiresReconnect(.claudeVertex))
        XCTAssertEqual(store.subscriptionConnectionAction(for: .claudeVertex), .reconnect)
        XCTAssertEqual(
            store.subscriptionConnectionLabel(for: .claudeVertex),
            "Reauthenticate with Google")

        let presentation = ProviderSetupBannerPresentation(
            access: .claudeVertex,
            requiresReconnect: store.requiresReconnect(.claudeVertex))
        XCTAssertEqual(presentation.title, "Google reauthentication required")
        XCTAssertEqual(
            presentation.detail,
            "Reauthenticate with Google to resume the conversation.")

        // A later coarse disconnected report must not erase the stronger rejection, while a
        // provider-verified ready snapshot is the authoritative edge that clears it.
        store.report(access: .claudeVertex, connected: false)
        XCTAssertTrue(store.requiresReconnect(.claudeVertex))
        XCTAssertEqual(store.error(for: .claudeVertex), message)
        store.report(access: .claudeVertex, connected: true, detail: "Claude (Vertex)")
        XCTAssertFalse(store.requiresReconnect(.claudeVertex))
        XCTAssertNil(store.error(for: .claudeVertex))
    }

    func testVertexBackgroundRAPTUsesStructuredTurnFailureCopy() throws {
        let raptMessage = "Your organization requires you to sign in to Google again. Reauthenticate with Google to continue using Google Vertex."
        let ready: [String: Any] = [
            "type": "ready",
            "provider": "anthropic",
            "auth": "vertex",
            "loggedIn": false,
            "accountStatus": "disconnected",
            "accountFailure": [
                "errorKind": "authentication",
                "provider": "anthropic",
                "access": "claude_vertex",
                "message": raptMessage,
                "providerError": [
                    "providerType": "credential_reauth_required",
                    "status": 400,
                    "code": "invalid_rapt",
                ],
                "reconnectRequired": true,
            ],
        ]
        let rejection = try XCTUnwrap(AgentBridge.runtimeAuthenticationRejectionMessage(
            from: ready,
            access: .claudeVertex))
        XCTAssertEqual(rejection, raptMessage)

        let store = ProviderAccountStore()
        XCTAssertEqual(store.reportRuntimeAccountState(
            access: .claudeVertex,
            connected: false,
            previousRuntimeReady: false,
            previousRuntimeLoggedIn: true,
            accountStatus: "disconnected",
            authenticationRejectionMessage: rejection), raptMessage)
        XCTAssertTrue(store.requiresReconnect(.claudeVertex))
        XCTAssertEqual(store.error(for: .claudeVertex), raptMessage)

        // A sibling's weaker launch-time ADC-presence snapshot cannot erase the definitive Google
        // rejection. A verified ready snapshot after reauthentication can.
        XCTAssertEqual(store.reportRuntimeAccountState(
            access: .claudeVertex,
            connected: true,
            previousRuntimeReady: false,
            previousRuntimeLoggedIn: true,
            accountStatus: "checking"), raptMessage)
        XCTAssertTrue(store.requiresReconnect(.claudeVertex))
        XCTAssertNil(store.reportRuntimeAccountState(
            access: .claudeVertex,
            connected: true,
            previousRuntimeReady: true,
            previousRuntimeLoggedIn: false,
            accountStatus: "verified"))
        XCTAssertFalse(store.requiresReconnect(.claudeVertex))
    }

    func testVertexReadyRejectsMissingAndMismatchedAccountFailureMetadata() {
        let missing: [String: Any] = [
            "loggedIn": false,
            "accountStatus": "disconnected",
            "accountFailure": [
                "errorKind": "authentication",
                "provider": "anthropic",
                "access": "claude_vertex",
                "message": "Google credentials are missing.",
                "providerError": ["providerType": "credential_no_credentials"],
                "reconnectRequired": true,
            ],
        ]
        XCTAssertNil(AgentBridge.runtimeAuthenticationRejectionMessage(
            from: missing,
            access: .claudeVertex))

        var verified = missing
        verified["loggedIn"] = true
        XCTAssertNil(AgentBridge.runtimeAuthenticationRejectionMessage(
            from: verified,
            access: .claudeVertex))

        var deferred = missing
        deferred["accountStatus"] = "deferred"
        XCTAssertNil(AgentBridge.runtimeAuthenticationRejectionMessage(
            from: deferred,
            access: .claudeVertex))

        var mismatchedProvider = missing
        var providerFailure = missing["accountFailure"] as! [String: Any]
        providerFailure["provider"] = "openai"
        mismatchedProvider["accountFailure"] = providerFailure
        XCTAssertNil(AgentBridge.runtimeAuthenticationRejectionMessage(
            from: mismatchedProvider,
            access: .claudeVertex))

        var mismatchedAccess = missing
        var accessFailure = missing["accountFailure"] as! [String: Any]
        accessFailure["access"] = "claude_subscription"
        mismatchedAccess["accountFailure"] = accessFailure
        XCTAssertNil(AgentBridge.runtimeAuthenticationRejectionMessage(
            from: mismatchedAccess,
            access: .claudeVertex))
    }

    func testFirstVertexReadyWithoutCredentialsKeepsConnectLanguage() {
        let store = ProviderAccountStore()

        XCTAssertNil(store.reportRuntimeAccountState(
            access: .claudeVertex,
            connected: false,
            previousRuntimeReady: false,
            previousRuntimeLoggedIn: true,
            accountStatus: "disconnected"))
        XCTAssertFalse(store.requiresReconnect(.claudeVertex))
        XCTAssertNil(store.error(for: .claudeVertex))
        XCTAssertEqual(store.subscriptionConnectionAction(for: .claudeVertex), .connect)
        XCTAssertEqual(store.subscriptionConnectionLabel(for: .claudeVertex), "Connect")
    }

    func testVertexDeferredVerificationAndAccountOperationsDoNotInferReauthentication() {
        XCTAssertNil(ProviderAccountStore.runtimeAuthenticationRejectionMessage(
            access: .claudeVertex,
            previousRuntimeReady: true,
            previousRuntimeLoggedIn: true,
            reportedLoggedIn: true,
            accountStatus: "deferred",
            accountOperationInFlight: false))
        XCTAssertNil(ProviderAccountStore.runtimeAuthenticationRejectionMessage(
            access: .claudeVertex,
            previousRuntimeReady: true,
            previousRuntimeLoggedIn: true,
            reportedLoggedIn: false,
            accountStatus: "disconnected",
            accountOperationInFlight: true))
        XCTAssertNil(ProviderAccountStore.runtimeAuthenticationRejectionMessage(
            access: .claudeSubscription,
            previousRuntimeReady: true,
            previousRuntimeLoggedIn: true,
            reportedLoggedIn: false,
            accountStatus: "disconnected",
            accountOperationInFlight: false))
        XCTAssertNil(ProviderAccountStore.runtimeAuthenticationRejectionMessage(
            access: .claudeVertex,
            previousRuntimeReady: true,
            previousRuntimeLoggedIn: true,
            reportedLoggedIn: true,
            accountStatus: "verified",
            accountOperationInFlight: false,
            authenticationRejectionMessage: "stale failure"))
    }

    func testTerminalAndBuildNeverBlockAccountRecovery() {
        XCTAssertFalse(AgentBridge.accountMutationBlocked(
            hasActiveTurn: false,
            hasExtensionRequest: false,
            hasBrowseRequest: false,
            hasBuild: true,
            hasTerminal: true))

        XCTAssertTrue(AgentBridge.accountMutationBlocked(
            hasActiveTurn: true,
            hasExtensionRequest: false,
            hasBrowseRequest: false,
            hasBuild: false,
            hasTerminal: false))
        XCTAssertTrue(AgentBridge.accountMutationBlocked(
            hasActiveTurn: false,
            hasExtensionRequest: true,
            hasBrowseRequest: false,
            hasBuild: false,
            hasTerminal: false))
    }

    func testAccountReloadBarrierRequiresEveryExactRuntimeIdentity() {
        let owner = UUID()
        let sibling = UUID()
        let expected = ProviderAccountInstanceID()
        var barrier = ProviderAccountReloadBarrier(
            accountInstanceID: expected,
            expectedLoggedIn: true,
            pendingBridgeIDs: [owner, sibling])

        XCTAssertEqual(
            barrier.acknowledge(
                bridgeID: sibling,
                accountInstanceID: ProviderAccountInstanceID(),
                loggedIn: true),
            .wrongAccountIdentity)
        XCTAssertFalse(barrier.isComplete)

        XCTAssertEqual(
            barrier.acknowledge(
                bridgeID: owner,
                accountInstanceID: expected,
                loggedIn: true),
            .accepted)
        XCTAssertFalse(
            barrier.isComplete,
            "the initiating window cannot release a sibling daemon still on the old account")

        let lateWindow = UUID()
        barrier.register(bridgeID: lateWindow)

        XCTAssertEqual(
            barrier.acknowledge(
                bridgeID: sibling,
                accountInstanceID: expected,
                loggedIn: true),
            .accepted)
        XCTAssertFalse(
            barrier.isComplete,
            "a runtime launched during the operation must join the same exact-identity barrier")
        XCTAssertEqual(
            barrier.acknowledge(
                bridgeID: lateWindow,
                accountInstanceID: expected,
                loggedIn: true),
            .accepted)
        XCTAssertTrue(barrier.isComplete)
    }

    func testAccountReloadBarrierRejectsTheWrongSignedInStateAndCanRetireAClosedWindow() {
        let owner = UUID()
        let closedSibling = UUID()
        let expected = ProviderAccountInstanceID()
        var barrier = ProviderAccountReloadBarrier(
            accountInstanceID: expected,
            expectedLoggedIn: false,
            pendingBridgeIDs: [owner, closedSibling])

        XCTAssertEqual(
            barrier.acknowledge(
                bridgeID: owner,
                accountInstanceID: expected,
                loggedIn: true),
            .wrongAccountState)
        XCTAssertFalse(barrier.isComplete)

        XCTAssertEqual(
            barrier.acknowledge(
                bridgeID: owner,
                accountInstanceID: expected,
                loggedIn: false),
            .accepted)
        barrier.retire(bridgeID: closedSibling)
        XCTAssertTrue(barrier.isComplete)
    }

    func testEachRuntimeReloadExpectationRejectsMissingStaleAndRelabelledReadyEvents() {
        let expected = ProviderAccountInstanceID()
        let stale = ProviderAccountInstanceID()
        let expectation = ProviderRuntimeAccountReloadExpectation(
            accountInstanceID: expected,
            credentialEpoch: 12)

        XCTAssertFalse(expectation.accepts(
            rawAccountInstanceID: nil,
            currentAccountInstanceID: expected,
            currentCredentialEpoch: 12))
        XCTAssertFalse(expectation.accepts(
            rawAccountInstanceID: stale.rawValue.uuidString,
            currentAccountInstanceID: expected,
            currentCredentialEpoch: 12))
        XCTAssertFalse(
            expectation.accepts(
                rawAccountInstanceID: expected.rawValue.uuidString,
                currentAccountInstanceID: expected,
                currentCredentialEpoch: 11),
            "changing only the app-side epoch must not bless a process from the old account")
        XCTAssertTrue(expectation.accepts(
            rawAccountInstanceID: expected.rawValue.uuidString.lowercased(),
            currentAccountInstanceID: expected,
            currentCredentialEpoch: 12))
    }

    func testModelPickerKeepsDisconnectedInteractiveAccountsVisibleWithDirectActions() {
        for access in [ModelAccess.claudeSubscription, .codexSubscription, .claudeVertex] {
            XCTAssertTrue(ModelPickerProviderPolicy.presents(access, state: .disconnected))
            XCTAssertEqual(
                ModelPickerProviderPolicy.connectionAction(
                    for: access,
                    state: .disconnected,
                    requiresReconnect: false,
                    isEnvironmentManaged: false),
                .connect)
            XCTAssertEqual(
                ModelPickerProviderPolicy.connectionAction(
                    for: access,
                    state: .connected(detail: nil),
                    requiresReconnect: true,
                    isEnvironmentManaged: false),
                .reconnect)
            XCTAssertNil(ModelPickerProviderPolicy.connectionAction(
                for: access,
                state: .connected(detail: nil),
                requiresReconnect: false,
                isEnvironmentManaged: false))
        }

        XCTAssertFalse(ModelPickerProviderPolicy.presents(.anthropicAPI, state: .disconnected))
        XCTAssertTrue(ModelPickerProviderPolicy.presents(.anthropicAPI, state: .configured))
    }

    func testModelPickerStartsAuthoritativeRuntimeProbeForCheckingInteractiveAccounts() {
        for access in [ModelAccess.claudeSubscription, .codexSubscription, .claudeVertex] {
            XCTAssertTrue(ModelPickerProviderPolicy.shouldPrepareCatalog(
                for: access, state: .checking))
            XCTAssertTrue(ModelPickerProviderPolicy.shouldPrepareCatalog(
                for: access, state: .connected(detail: nil)))
            XCTAssertFalse(ModelPickerProviderPolicy.shouldPrepareCatalog(
                for: access, state: .disconnected))
            XCTAssertTrue(ModelPickerProviderPolicy.shouldPrepareCatalog(
                for: access, state: .disconnected, hasUsableRuntime: true))
        }

        XCTAssertFalse(ModelPickerProviderPolicy.shouldPrepareCatalog(
            for: .anthropicAPI, state: .checking))
        XCTAssertTrue(ModelPickerProviderPolicy.shouldPrepareCatalog(
            for: .anthropicAPI, state: .configured))
    }
}

/// `checking` is the state that causes `prepareModelCatalog` to launch a lane's daemon. A probe that
/// fails without answering therefore leaves exactly the condition that starts another one, so an
/// unreachable provider was getting a fresh daemon every few minutes for as long as the app was open.
@MainActor
final class ProviderProbeSettlementTests: XCTestCase {
    func testAnUnreachableProbeSettlesTheLaneInsteadOfLeavingItChecking() {
        let store = ProviderAccountStore()
        XCTAssertEqual(store.state(for: .codexSubscription), .checking)

        store.reportProbeUnavailable(
            access: .codexSubscription,
            message: "Mechanician disconnected from the Codex App Server.")

        XCTAssertEqual(
            store.state(for: .codexSubscription),
            .unavailable("Mechanician disconnected from the Codex App Server."),
            "a lane that answered 'unreachable' must not still look like one that has not answered")
        XCTAssertEqual(
            store.error(for: .codexSubscription),
            "Mechanician disconnected from the Codex App Server.")
    }

    func testASettledLaneKeepsItsAnswerAcrossRepeatedFailures() {
        let store = ProviderAccountStore()
        store.reportProbeUnavailable(access: .codexSubscription, message: "first")
        store.reportProbeUnavailable(access: .codexSubscription, message: "second")

        XCTAssertEqual(
            store.state(for: .codexSubscription), .unavailable("first"),
            "settling is not a retry loop; the lane stays settled")
    }

    /// One transient catalog failure must never demote a lane that has already proved itself.
    func testAConnectedLaneIsNotDemotedByACatalogFailure() {
        let store = ProviderAccountStore()
        store.report(access: .codexSubscription, connected: true, detail: "pro")
        let connected = store.state(for: .codexSubscription)

        store.reportProbeUnavailable(access: .codexSubscription, message: "transient")

        XCTAssertEqual(store.state(for: .codexSubscription), connected)
    }
}
