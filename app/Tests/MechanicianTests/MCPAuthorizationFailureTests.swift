import XCTest
@testable import Mechanician

final class MCPAuthorizationFailureTests: XCTestCase {
    private func failure(
        message: String = "Authorization failed.",
        kind: MCPAuthorizationFailure.Kind? = nil,
        action: MCPAuthorizationFailure.SuggestedAction? = nil,
        retryable: Bool? = nil
    ) -> MCPAuthorizationFailure {
        MCPAuthorizationFailure(
            message: message,
            kind: kind,
            suggestedAction: action,
            retryable: retryable)
    }

    func testWireInitializerPreservesTypedDiagnosticsAndBoundsHTTPStatus() {
        let value = MCPAuthorizationFailure(
            message: "The token endpoint rejected the grant.",
            wireStage: "token_exchange",
            wireKind: "oauth_error",
            code: " EHTTP ",
            status: 400,
            oauth: " invalid_grant ",
            wireSuggestedAction: "try_again",
            retryable: true)

        XCTAssertEqual(value.stage, .tokenExchange)
        XCTAssertEqual(value.kind, .oauth)
        XCTAssertEqual(value.code, "EHTTP")
        XCTAssertEqual(value.status, 400)
        XCTAssertEqual(value.oauth, "invalid_grant")
        XCTAssertEqual(value.suggestedAction, .retry)
        XCTAssertEqual(value.retryable, true)

        let invalidStatus = MCPAuthorizationFailure(
            message: "Failure",
            status: 42)
        XCTAssertNil(invalidStatus.status)
    }

    func testEventDecoderAcceptsStablePrefixedKeysAndLegacyMessageOnlyEvents() {
        let current = MCPAuthorizationFailure(event: [
            "message": "Registration is unsupported.",
            "errorStage": "client_registration",
            "errorKind": "protocol",
            "errorCode": "dynamic_client_registration_unsupported",
            "httpStatus": NSNumber(value: 400),
            "oauthError": "invalid_client_metadata",
            "suggestedAction": "manual_credentials",
            "retryable": false,
        ])

        XCTAssertEqual(current.message, "Registration is unsupported.")
        XCTAssertEqual(current.stage, .clientRegistration)
        XCTAssertEqual(current.kind, .protocol)
        XCTAssertEqual(current.code, "dynamic_client_registration_unsupported")
        XCTAssertEqual(current.status, 400)
        XCTAssertEqual(current.oauth, "invalid_client_metadata")
        XCTAssertEqual(current.suggestedAction, .manualCredentials)
        XCTAssertEqual(current.retryable, false)

        let legacy = MCPAuthorizationFailure(event: ["message": "Old runtime failure"])
        XCTAssertEqual(legacy, .legacy("Old runtime failure"))
    }

    func testStableOAuthStagesMapToNamedCases() {
        let expected: [(String, MCPAuthorizationFailure.Stage)] = [
            ("authorization_setup", .authorizationSetup),
            ("callback_listener", .callbackListener),
            ("protected_resource_discovery", .protectedResourceDiscovery),
            ("authorization_server_discovery", .authorizationServerDiscovery),
            ("client_registration", .clientRegistration),
            ("authorization_redirect", .authorizationRedirect),
            ("authorization_callback", .authorizationCallback),
            ("token_exchange", .tokenExchange),
            ("credential_storage", .credentialStorage),
            ("same_origin_browser", .sameOriginBrowser),
        ]

        for (wire, stage) in expected {
            XCTAssertEqual(
                MCPAuthorizationFailure.Stage(wireValue: wire),
                stage,
                "wire stage \(wire)")
        }
        XCTAssertEqual(
            MCPAuthorizationFailure.Stage(wireValue: "future-stage"),
            .other("future_stage"))
    }

    func testLegacyMessageOnlyFailureRemainsVisibleAndRetryableWithoutProseInference() {
        let state = MCPAuthState.failed(
            "This server does not support dynamic client registration.")
        guard case .failed(let value) = state else {
            return XCTFail("legacy failure should remain a failure")
        }

        XCTAssertNil(value.stage)
        XCTAssertNil(value.kind)
        XCTAssertEqual(value.message, "This server does not support dynamic client registration.")
        XCTAssertEqual(
            MCPAuthorizationFailurePresentation.resolve(
                value,
                hasManualCredentials: false).action,
            .retry,
            "legacy English text must not select the token editor")
    }

    func testStructuredUnsupportedAuthSelectsManualCredentialAction() {
        let unsupported = failure(
            kind: .protocol,
            action: .manualCredentials,
            retryable: false)

        XCTAssertEqual(
            MCPAuthorizationFailurePresentation.resolve(
                unsupported,
                hasManualCredentials: false).action,
            .addToken)
        XCTAssertEqual(
            MCPAuthorizationFailurePresentation.resolve(
                unsupported,
                hasManualCredentials: true).action,
            .editCredentials)
        XCTAssertNil(
            MCPAuthorizationFailurePresentation.resolve(
                unsupported,
                hasManualCredentials: false,
                allowsManualCredentials: false).action)
    }

    func testPresentationHonorsStructuredRetryEditAndNoActionDecisions() {
        XCTAssertEqual(
            MCPAuthorizationFailurePresentation.resolve(
                failure(kind: .timeout, retryable: true),
                hasManualCredentials: false).action,
            .retry)
        XCTAssertEqual(
            MCPAuthorizationFailurePresentation.resolve(
                failure(
                    kind: .network,
                    action: .checkNetwork,
                    retryable: true),
                hasManualCredentials: false).action,
            .retry)
        XCTAssertEqual(
            MCPAuthorizationFailurePresentation.resolve(
                failure(
                    kind: .network,
                    action: .checkVPN,
                    retryable: true),
                hasManualCredentials: false).action,
            .retry)
        XCTAssertEqual(
            MCPAuthorizationFailurePresentation.resolve(
                failure(
                    kind: .configuration,
                    action: .editServer,
                    retryable: false),
                hasManualCredentials: false).action,
            .editServer)
        XCTAssertNil(
            MCPAuthorizationFailurePresentation.resolve(
                failure(
                    kind: .server,
                    action: MCPAuthorizationFailure.SuggestedAction.none,
                    retryable: true),
                hasManualCredentials: false).action)
        XCTAssertNil(
            MCPAuthorizationFailurePresentation.resolve(
                failure(kind: .unknown, retryable: false),
                hasManualCredentials: false).action)
    }

    func testCancellationAndTheWordCancelHaveDifferentStructuralOutcomes() {
        let cancelled = failure(
            message: "Authorization was stopped.",
            kind: .cancelled,
            retryable: false)
        let upstreamFailure = failure(
            message: "The authorization server cancelled its upstream request.",
            kind: .network,
            retryable: true)

        XCTAssertTrue(cancelled.isCancellation)
        XCTAssertNil(
            MCPAuthorizationFailurePresentation.resolve(
                cancelled,
                hasManualCredentials: false).action)
        XCTAssertFalse(upstreamFailure.isCancellation)
        XCTAssertEqual(
            MCPAuthorizationFailurePresentation.resolve(
                upstreamFailure,
                hasManualCredentials: false).action,
            .retry)
    }

    @MainActor
    func testStoreNormalizesOnlyTypedCancellationToIdleAndKeepsLaneIsolation() {
        let store = ExtensionsStore.shared
        let name = "oauth-failure-\(UUID().uuidString)"
        let firstAccess = ModelAccess.anthropicAPI
        let otherAccess = ModelAccess.openAIAPI
        defer {
            store.setAuthState(name, .idle, for: firstAccess)
            store.setAuthState(name, .idle, for: otherAccess)
            store.setAuthURL(nil, for: name, access: firstAccess)
            store.setAuthURL(nil, for: name, access: otherAccess)
        }

        store.setAuthURL("https://first.example/authorize", for: name, access: firstAccess)
        store.setAuthURL("https://other.example/authorize", for: name, access: otherAccess)
        store.setAuthState(
            name,
            .failed(failure(message: "Stopped", kind: .cancelled)),
            for: firstAccess)
        XCTAssertEqual(store.authState(for: name, access: firstAccess), .idle)
        XCTAssertNil(store.authURL(for: name, access: firstAccess))
        XCTAssertEqual(
            store.authURL(for: name, access: otherAccess),
            "https://other.example/authorize")

        store.setAuthState(
            name,
            .failed("The upstream request was cancelled by its proxy."),
            for: firstAccess)
        guard case .failed(let legacy) = store.authState(for: name, access: firstAccess) else {
            return XCTFail("message-only events must not be parsed as cancellation")
        }
        XCTAssertEqual(legacy.message, "The upstream request was cancelled by its proxy.")
        XCTAssertEqual(store.authState(for: name, access: otherAccess), .idle)
    }

    func testAttentionResolverCarriesTheTypedFailureUnchanged() {
        var server = MCPServer(name: "remote")
        server.transport = .http
        server.url = "https://example.com/mcp"
        let authFailure = failure(
            message: "Dynamic client registration is unavailable.",
            kind: .protocol,
            action: .manualCredentials,
            retryable: false)

        XCTAssertEqual(
            MCPAttentionResolver.primary(
                servers: [server],
                authStates: [server.name: .failed(authFailure)],
                connectionStates: [:]),
            MCPAttention(
                serverName: server.name,
                kind: .authenticationFailed(authFailure)))
    }
}

/// GitHub's MCP server does not support Dynamic Client Registration, and Codex reports that only in
/// prose. Detection was code-only, so the policy fell through to "Try Again" — a button that cannot
/// ever succeed. David hit exactly this and could not authenticate the server at all.
final class MCPUnsupportedDynamicRegistrationTests: XCTestCase {
    private var githubFailure: MCPAuthorizationFailure {
        .legacy(
            "failed to login to MCP server 'github': Registration failed: Dynamic registration "
                + "failed: Registration failed: Dynamic client registration not supported")
    }

    func testProseOnlyDynamicRegistrationFailureIsRecognized() {
        XCTAssertTrue(githubFailure.indicatesUnsupportedDynamicRegistration)
    }

    func testItOffersATokenRatherThanARetryThatCannotSucceed() {
        let presentation = MCPAuthorizationFailurePresentation.resolve(
            githubFailure, hasManualCredentials: false)
        XCTAssertEqual(presentation.action, .addToken)
        XCTAssertNotEqual(presentation.action, .retry)
        XCTAssertEqual(presentation.title, "This server needs a token")
        XCTAssertFalse(
            presentation.message.contains("Registration failed"),
            "the person is told what to do, not handed four nested provider clauses")
    }

    func testAnExistingTokenIsEditedRatherThanAdded() {
        XCTAssertEqual(
            MCPAuthorizationFailurePresentation.resolve(
                githubFailure, hasManualCredentials: true).action,
            .editCredentials)
    }

    /// A lane that cannot take manual credentials must not offer an action it cannot honour, but it
    /// still must not claim retrying will help.
    func testALaneWithoutManualCredentialsOffersNoDeadEndAction() {
        let presentation = MCPAuthorizationFailurePresentation.resolve(
            githubFailure, hasManualCredentials: false, allowsManualCredentials: false)
        XCTAssertNil(presentation.action)
    }

    /// Unrelated prose must not be swept in by the text fallback.
    func testAnOrdinaryFailureStillRetries() {
        let presentation = MCPAuthorizationFailurePresentation.resolve(
            .legacy("failed to login to MCP server 'github': the network is unreachable"),
            hasManualCredentials: false)
        XCTAssertEqual(presentation.action, .retry)
    }
}
