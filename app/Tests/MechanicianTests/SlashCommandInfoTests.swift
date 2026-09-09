import XCTest
@testable import Mechanician

final class SlashCommandInfoTests: XCTestCase {
    func testLegacyClaudeCacheDefaultsToSlashInvocation() throws {
        let data = Data(#"{"name":"review","description":"Review changes","argumentHint":""}"#.utf8)
        let command = try JSONDecoder().decode(SlashCommandInfo.self, from: data)
        XCTAssertEqual(command.prefix, "/")
        XCTAssertEqual(command.invocation, "/review")
    }

    func testCodexSkillRetainsDollarInvocationAcrossCacheRoundTrip() throws {
        let skill = SlashCommandInfo(
            name: "imagegen",
            description: "Generate an image",
            argumentHint: "",
            invocationPrefix: "$")
        let decoded = try JSONDecoder().decode(
            SlashCommandInfo.self,
            from: JSONEncoder().encode(skill))
        XCTAssertEqual(decoded.prefix, "$")
        XCTAssertEqual(decoded.invocation, "$imagegen")
        XCTAssertEqual(decoded.id, "$imagegen")
    }
}
