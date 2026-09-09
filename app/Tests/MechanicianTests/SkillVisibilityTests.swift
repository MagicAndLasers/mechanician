import XCTest
@testable import Mechanician

/// FR-224. `claude-api` is demoted to user-invocable-only on every lane whose context window cannot
/// hold its reference, which is every 200K lane: all of Vertex and Bedrock, plus every 200K model.
/// It deliberately stays in `supportedCommands()` so a person can still type it, and that is exactly
/// why the panel went on advertising it as if the agent could reach for it.
///
/// This is the highest-frequency subtraction in the inventory, and deliberately NOT reported as a
/// `subtraction` event: it is a standing property of the lane rather than something that happens
/// during a turn, so a timeline marker every turn would bury the events that are per-turn.
final class SkillVisibilityTests: XCTestCase {
    func testACommandWithNoOpinionIsAgentInvocable() {
        // The ordinary case, and every cache written before this field existed.
        let ordinary = SlashCommandInfo(
            name: "review", description: "Review a PR", argumentHint: "")
        XCTAssertTrue(ordinary.isAgentInvocable)
        XCTAssertNil(ordinary.agentInvocable)
    }

    func testADemotedCommandStaysRunnableButNotAgentInvocable() {
        let demoted = SlashCommandInfo(
            name: "claude-api", description: "Claude API reference", argumentHint: "",
            invocationPrefix: nil, agentInvocable: false)
        XCTAssertFalse(demoted.isAgentInvocable)
        // Still typable: the demotion budgets the capability, it does not remove it.
        XCTAssertEqual(demoted.invocation, "/claude-api")
    }

    func testTheFieldSurvivesACacheRoundTripAndAnOlderRecord() throws {
        let demoted = SlashCommandInfo(
            name: "claude-api", description: "", argumentHint: "",
            invocationPrefix: nil, agentInvocable: false)
        let restored = try JSONDecoder().decode(
            SlashCommandInfo.self, from: JSONEncoder().encode(demoted))
        XCTAssertFalse(restored.isAgentInvocable)

        // A record written by a build predating the field must still decode, and must not claim the
        // agent is blocked. Same downgrade contract as `invocationPrefix`.
        let legacy = #"{"name":"review","description":"d","argumentHint":""}"#
        let old = try JSONDecoder().decode(
            SlashCommandInfo.self, from: Data(legacy.utf8))
        XCTAssertTrue(old.isAgentInvocable)
    }
}
