import XCTest
@testable import Mechanician

@MainActor
final class SkillInventorySeenStateTests: XCTestCase {
    func testViewingInventoryClearsOnlyExistingInvocationIDsAndPersists() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scope = SkillInventoryScope(access: .codexSubscription, routeIdentity: nil)
        let original = [
            skill("review", prefix: "$"),
            skill("test", prefix: "$"),
        ]
        let state = SkillInventorySeenState(defaults: defaults)

        XCTAssertEqual(state.unseenCount(in: original, scope: scope), 2)
        state.markViewed(original, scope: scope)
        XCTAssertEqual(state.unseenCount(in: original, scope: scope), 0)

        // A new instance proves the acknowledgement is durable rather than only published in memory.
        let restored = SkillInventorySeenState(defaults: defaults)
        XCTAssertEqual(restored.unseenCount(in: original, scope: scope), 0)
    }

    func testSameCountReplacementRaisesOnlyTheNewInvocation() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scope = SkillInventoryScope(access: .codexSubscription, routeIdentity: nil)
        let state = SkillInventorySeenState(defaults: defaults)
        state.markViewed([
            skill("alpha", prefix: "$"),
            skill("beta", prefix: "$"),
        ], scope: scope)

        let replacement = [
            skill("beta", prefix: "$"),
            skill("gamma", prefix: "$"),
        ]
        XCTAssertEqual(
            state.unseenInvocationIDs(in: replacement, scope: scope),
            ["$gamma"])

        state.markViewed(replacement, scope: scope)
        let restoredKnownID = [
            skill("alpha", prefix: "$", description: "Description changed"),
            skill("gamma", prefix: "$"),
        ]
        XCTAssertEqual(
            state.unseenInvocationIDs(in: restoredKnownID, scope: scope),
            [],
            "Removing, restoring, or redescribing an invocation already viewed is not new inventory")
    }

    func testSeenInventoriesAreIsolatedByProviderRoute() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = SkillInventorySeenState(defaults: defaults)
        let first = SkillInventoryScope(access: .claudeVertex, routeIdentity: "route-v1:first")
        let second = SkillInventoryScope(access: .claudeVertex, routeIdentity: "route-v1:second")
        let commands = [skill("acme:review", prefix: "/")]

        state.markViewed(commands, scope: first)

        XCTAssertEqual(state.unseenCount(in: commands, scope: first), 0)
        XCTAssertEqual(state.unseenCount(in: commands, scope: second), 1)
    }

    func testBadgeInventoryUsesTheSameVisibilityPolicyAsThePanel() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = SkillInventorySeenState(defaults: defaults)
        let claude = SkillInventoryScope(access: .claudeSubscription, routeIdentity: nil)
        let commands = [
            skill("config", prefix: "/"),
            skill("acme:review", prefix: "/"),
        ]

        XCTAssertEqual(
            SkillInventoryPresentation.visibleCommands(
                commands,
                access: .claudeSubscription
            ).map(\.invocation),
            ["/acme:review"])
        XCTAssertEqual(state.unseenCount(in: commands, scope: claude), 1)
    }

    func testCodexShowsDollarSkillsButNotRegularSlashCommands() throws {
        let commands = [
            skill("system-review", prefix: "$"),
            skill("status", prefix: "/"),
        ]
        let visible = SkillInventoryPresentation.visibleCommands(
            commands,
            access: .codexSubscription)

        XCTAssertEqual(visible.map(\.invocation), ["$system-review"])
        XCTAssertEqual(
            SkillInventoryPresentation.groups(visible).map(\.title),
            ["Codex skills"])

        let scope = SkillInventoryScope(access: .codexSubscription, routeIdentity: nil)
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(
            SkillInventorySeenState(defaults: defaults).unseenCount(
                in: commands,
                scope: scope),
            1)
    }

    func testAvailabilityCopyDescribesProviderInventoryWithoutUsageClaim() {
        let copy = SkillInventoryPresentation.availabilityDescription(
            access: .codexSubscription)
        let normalized = copy.lowercased()

        XCTAssertTrue(normalized.contains("available to this conversation"))
        XCTAssertTrue(normalized.contains("through codex"))
        XCTAssertFalse(normalized.contains("used by"))
        XCTAssertTrue(normalized.contains("does not report its regular slash-command catalog"))
        XCTAssertTrue(normalized.contains("only the $ skills"))
    }

    private func skill(
        _ name: String,
        prefix: String,
        description: String = ""
    ) -> SlashCommandInfo {
        SlashCommandInfo(
            name: name,
            description: description,
            argumentHint: "",
            invocationPrefix: prefix)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "SkillInventorySeenStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
