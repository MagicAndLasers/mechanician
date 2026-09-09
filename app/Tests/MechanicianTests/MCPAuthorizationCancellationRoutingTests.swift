import XCTest
@testable import Mechanician

final class MCPAuthorizationCancellationRoutingTests: XCTestCase {
    private struct Route: Equatable {
        let kind: String
    }

    private struct Owner: Equatable {
        let requestID: String
    }

    func testCancelRetiresOriginalRouteAndOwnerButKeepsItsAcknowledgementRoute() {
        let originalID = "authorize-original"
        let cancelID = "cancel-original"
        var routes = [
            originalID: Route(kind: "authorize"),
            cancelID: Route(kind: "cancel"),
        ]
        var owner: Owner? = Owner(requestID: originalID)

        MCPAuthorizationCancellationRouting.retireOriginal(
            requestID: originalID,
            routes: &routes,
            owner: &owner,
            ownerRequestID: { $0.requestID })

        XCTAssertNil(owner, "the authorization guard must admit an immediate replacement attempt")
        XCTAssertNil(routes[originalID], "a late original terminal must no longer have a route")
        XCTAssertEqual(
            routes[cancelID],
            Route(kind: "cancel"),
            "the cancel acknowledgement must remain independently routable")
    }

    func testRetiringAnOldRequestNeverClearsOrUnroutesANewerAttempt() {
        let oldID = "authorize-old"
        let cancelID = "cancel-old"
        let newID = "authorize-new"
        var routes = [
            oldID: Route(kind: "authorize"),
            cancelID: Route(kind: "cancel"),
            newID: Route(kind: "authorize"),
        ]
        var owner: Owner? = Owner(requestID: newID)

        MCPAuthorizationCancellationRouting.retireOriginal(
            requestID: oldID,
            routes: &routes,
            owner: &owner,
            ownerRequestID: { $0.requestID })

        XCTAssertEqual(owner, Owner(requestID: newID))
        XCTAssertNil(routes[oldID])
        XCTAssertEqual(routes[cancelID], Route(kind: "cancel"))
        XCTAssertEqual(routes[newID], Route(kind: "authorize"))
    }
}
