import XCTest
@testable import Mechanician

final class BedrockSessionRouteIdentityTests: XCTestCase {
    func testBedrockSessionResumesOnlyForItsExactSignedRoute() throws {
        let profile = TenantProfile(
            tenantId: "acme",
            displayName: "Acme",
            routes: [
                .init(
                    routeId: "acme-bedrock",
                    adapter: "claude-bedrock",
                    bedrock: .init(region: "us-west-2", profile: "engineering")),
            ])
        let identity = try XCTUnwrap(profile.routeIdentity(for: .claudeBedrock))
        let conversation = Conversation(
            title: "Bedrock",
            cwd: "/tmp",
            sdkSessionId: "bedrock-session",
            sdkSessionRouteIdentity: identity,
            modelSelection: .init(
                access: .claudeBedrock,
                modelID: "global.anthropic.claude-opus-4-8"),
            messages: [],
            updatedAt: Date())

        XCTAssertEqual(
            AgentBridge.resumableSessionID(
                for: conversation,
                access: .claudeBedrock,
                profile: profile),
            "bedrock-session")

        var differentBackend = profile
        differentBackend.routes[0].bedrock?.profile = "production"

        XCTAssertNil(AgentBridge.resumableSessionID(
            for: conversation,
            access: .claudeBedrock,
            profile: differentBackend))
    }
}
