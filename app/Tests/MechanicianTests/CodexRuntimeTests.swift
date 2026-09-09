import XCTest
@testable import Mechanician

final class CodexRuntimeTests: XCTestCase {
    func testExplicitOverridePrecedesBundledAndSystemRuntimes() {
        let resources = URL(fileURLWithPath: "/Applications/Mechanician.app/Contents/Resources")
        let candidates = CodexRuntime.candidatePaths(
            environment: ["MECHANICIAN_CODEX_BIN": "/tmp/developer-codex"],
            resourceURL: resources,
            homeDirectory: URL(fileURLWithPath: "/tmp/home")
        )

        XCTAssertEqual(candidates[0], "/tmp/developer-codex")
        XCTAssertEqual(
            candidates[1],
            resources.appendingPathComponent(CodexRuntime.bundledRelativePath).path
        )
        XCTAssertEqual(
            candidates[2],
            "/Applications/ChatGPT.app/Contents/Resources/codex"
        )
    }

    func testBundledRuntimeResolvesWithoutASeparateCodexInstall() throws {
        let resources = URL(fileURLWithPath: "/Release/Mechanician.app/Contents/Resources")
        let expected = resources.appendingPathComponent(CodexRuntime.bundledRelativePath).path
        let resolved = CodexRuntime.resolveBinary(
            environment: [:],
            resourceURL: resources,
            homeDirectory: URL(fileURLWithPath: "/tmp/empty-home"),
            isExecutable: { $0 == expected }
        )

        XCTAssertEqual(try XCTUnwrap(resolved).path, expected)
        XCTAssertEqual(CodexRuntime.bundledVersion, "0.148.0")
    }
}
