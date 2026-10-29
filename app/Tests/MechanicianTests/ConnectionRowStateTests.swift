import XCTest
@testable import Mechanician

final class ConnectionRowStateTests: XCTestCase {
    private func server(enabled: Bool = true, url: String = "https://jira.example/mcp") -> MCPServer {
        var server = MCPServer(name: "jira")
        server.enabled = enabled
        server.transport = .http
        server.url = url
        return server
    }

    private func resolve(
        _ server: MCPServer? = nil,
        auth: MCPAuthState = .idle,
        connection: MCPConnState = .unknown
    ) -> ConnectionRowState {
        ConnectionRowState.resolve(
            server: server ?? self.server(), auth: auth, connection: connection)
    }

    func testDisabledServerIsOffWhateverItsStaleState() {
        let off = server(enabled: false)
        XCTAssertEqual(resolve(off, auth: .failed("boom"), connection: .needsAuth), .off)
        XCTAssertEqual(resolve(off, connection: .connected(12)), .off)
        XCTAssertNil(ConnectionRowState.off.primaryAction)
    }

    func testInvalidConfigurationIsAProblemWithAnEditAction() {
        let state = resolve(server(url: "  "), connection: .connected(3))
        XCTAssertEqual(state, .problem(.invalidConfiguration))
        XCTAssertEqual(state.primaryAction, .editServer)
    }

    func testSignInProgressOutranksEveryOlderState() {
        for (auth, phase) in [
            (MCPAuthState.preparing, MCPAuthorizationProgressPhase.preparing),
            (.authorizing, .authorizing),
            (.waiting, .waitingForBrowser),
        ] {
            XCTAssertEqual(resolve(auth: auth, connection: .needsAuth), .signingIn(phase))
            XCTAssertEqual(resolve(auth: auth, connection: .connected(5)), .signingIn(phase))
        }
    }

    func testCancelIsOfferedOnlyOnceAnAttemptIsOwned() {
        XCTAssertNil(ConnectionRowState.signingIn(.preparing).primaryAction)
        XCTAssertEqual(ConnectionRowState.signingIn(.authorizing).primaryAction, .cancel)
        XCTAssertEqual(ConnectionRowState.signingIn(.waitingForBrowser).primaryAction, .cancel)
    }

    func testAuthenticationFailureIsOneProblemWithRetryAndFullText() {
        let failure = MCPAuthorizationFailure(message: "Token exchange was rejected by the server.")
        let state = resolve(auth: .failed(failure), connection: .needsAuth)
        XCTAssertEqual(state, .problem(.authenticationFailed(failure)))
        XCTAssertEqual(state.primaryAction, .retry)
        XCTAssertEqual(state.detail, "Token exchange was rejected by the server.")
    }

    func testNeedsAuthOffersSignIn() {
        let state = resolve(connection: .needsAuth)
        XCTAssertEqual(state, .needsSignIn)
        XCTAssertEqual(state.primaryAction, .signIn)
    }

    func testConnectionFailureAndZeroToolsOfferRetry() {
        let failed = resolve(connection: .failed("connection refused"))
        XCTAssertEqual(failed, .problem(.connectionFailed("connection refused")))
        XCTAssertEqual(failed.primaryAction, .retry)
        XCTAssertEqual(failed.detail, "connection refused")

        let empty = resolve(auth: .authorized, connection: .connected(0))
        XCTAssertEqual(empty, .problem(.noTools))
        XCTAssertEqual(empty.primaryAction, .retry)
    }

    func testConnectedIsReadyAndAnOmittedToolCountIsNotZero() {
        XCTAssertEqual(resolve(connection: .connected(28)), .ready(toolCount: 28))
        XCTAssertEqual(resolve(connection: .connected(nil)), .ready(toolCount: nil))
        XCTAssertNil(ConnectionRowState.ready(toolCount: 28).primaryAction)
    }

    /// The Jira case from the audit: a saved login with tools not yet verified in this lane used to
    /// be a silent gray row with no button. It is Unverified with a Retry action, and the panel is
    /// told to refresh it. It is not Checking: the probe can stay indeterminate, so a spinner here
    /// could spin forever.
    func testSavedLoginWithUnverifiedToolsIsUnverifiedWithRetryAndAsksForARefresh() {
        XCTAssertEqual(resolve(auth: .idle, connection: .authenticated), .unverified)
        XCTAssertEqual(ConnectionRowState.unverified.primaryAction, .retry)
        XCTAssertTrue(ConnectionRowState.needsStatusRefresh(connection: .authenticated, auth: .idle))
        XCTAssertTrue(ConnectionRowState.needsStatusRefresh(connection: .unknown, auth: .idle))

        XCTAssertEqual(resolve(connection: .unknown), .unverified)
        XCTAssertEqual(resolve(connection: .checking), .checking)
        XCTAssertNil(ConnectionRowState.checking.primaryAction)
        XCTAssertFalse(ConnectionRowState.needsStatusRefresh(connection: .checking, auth: .idle))
    }

    func testNoRefreshIsRequestedForSettledStatesOrDuringSignIn() {
        for connection in [MCPConnState.connected(4), .needsAuth, .failed("x"), .disabled] {
            XCTAssertFalse(
                ConnectionRowState.needsStatusRefresh(connection: connection, auth: .idle))
        }
        XCTAssertFalse(
            ConnectionRowState.needsStatusRefresh(connection: .unknown, auth: .waiting))
    }

    func testGroupingIsADeterministicSortOnState() {
        XCTAssertEqual(ConnectionRowGroup(.needsSignIn), .notSignedIn)
        XCTAssertEqual(ConnectionRowGroup(.signingIn(.waitingForBrowser)), .notSignedIn)
        XCTAssertEqual(ConnectionRowGroup(.problem(.noTools)), .needsAttention)
        XCTAssertEqual(ConnectionRowGroup(.ready(toolCount: 1)), .ready)
        XCTAssertEqual(ConnectionRowGroup(.checking), .ready)
        XCTAssertEqual(ConnectionRowGroup(.unverified), .ready)
        XCTAssertEqual(ConnectionRowGroup(.off), .off)
        XCTAssertEqual(ConnectionRowGroup.allCases.sorted(), [.needsAttention, .notSignedIn, .ready, .off])
    }

    func testEveryEnabledRowStateHasASummaryAndANamedActionWhenItOffersOne() {
        let states: [ConnectionRowState] = [
            .ready(toolCount: 2), .ready(toolCount: nil), .needsSignIn,
            .signingIn(.preparing), .signingIn(.authorizing), .signingIn(.waitingForBrowser),
            .problem(.invalidConfiguration), .problem(.noTools),
            .problem(.connectionFailed("x")), .checking, .unverified, .off,
        ]
        for state in states {
            XCTAssertFalse(state.summary.isEmpty, "\(state)")
            if let action = state.primaryAction { XCTAssertFalse(action.label.isEmpty) }
        }
    }

    func testAccessibilitySummaryIsOnePhraseWithTheAvailableAction() {
        let failed = ConnectionRowState.problem(.authenticationFailed(
            MCPAuthorizationFailure(message: "no")))
        XCTAssertEqual(
            failed.accessibilitySummary(serverName: "Slack"),
            "Slack, problem: Sign-in failed, Retry available")
        XCTAssertEqual(
            ConnectionRowState.ready(toolCount: 28).accessibilitySummary(serverName: "Jira"),
            "Jira, 28 tools")
    }
}
