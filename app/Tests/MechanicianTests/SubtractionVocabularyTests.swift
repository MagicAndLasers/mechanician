import XCTest
@testable import Mechanician

/// FR-224's spine. Two invariants, chosen because they are the failures this codebase actually
/// keeps having rather than hypothetical ones:
///
/// 1. A reason the daemon can send with no Swift case. The vocabularies live in two languages, and
///    the constraint audit found that duplicated provider facts going stale is the pattern that
///    caused real damage twice. A rename on either side is silent at runtime.
/// 2. A turn-scoped event handled in only one of the two dispatch paths. That is exactly how `info`
///    came to be dropped for every backgrounded turn, which is the bug this FR surfaced.
@MainActor
final class SubtractionVocabularyTests: XCTestCase {
    private func repoFile(_ relative: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MechanicianTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(relative)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testEveryDaemonReasonHasASwiftCaseAndALabel() {
        let daemon = repoFile("agentd/src/agentd.mjs")
        XCTAssertFalse(daemon.isEmpty, "could not read agentd.mjs")

        guard let start = daemon.range(of: "const SUBTRACTION_REASONS = new Set(["),
              let end = daemon.range(
                of: "])", range: start.upperBound..<daemon.endIndex) else {
            return XCTFail("SUBTRACTION_REASONS not found in agentd.mjs")
        }
        let block = String(daemon[start.upperBound..<end.lowerBound])
        let reasons = block
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("'") else { return nil }
                return trimmed.split(separator: "'").first.map(String.init)
            }

        XCTAssertGreaterThan(reasons.count, 5, "parsed too few reasons; the parser is wrong")
        for reason in reasons {
            guard let decoded = AgentSubtractionReason(rawValue: reason) else {
                XCTFail("daemon reason '\(reason)' has no AgentSubtractionReason case")
                continue
            }
            XCTAssertFalse(
                decoded.label.isEmpty,
                "'\(reason)' decodes but renders no label, so its marker would read as bare")
        }
    }

    func testSubtractionIsHandledInBothDispatchPaths() {
        let bridge = repoFile("app/Sources/Mechanician/AgentBridge.swift")
        XCTAssertFalse(bridge.isEmpty, "could not read AgentBridge.swift")

        // Turn-scoped, so a backgrounded turn routes to applyBackgroundEvent.
        XCTAssertTrue(
            bridge.contains("\"compact_boundary\", \"history_reduced\", \"subtraction\""),
            "subtraction must be registered as turn-scoped or it routes as conversation-level")

        guard let backgroundStart = bridge.range(of: "private func applyBackgroundEvent") else {
            return XCTFail("applyBackgroundEvent not found")
        }
        let background = String(bridge[backgroundStart.lowerBound...].prefix(40_000))
        XCTAssertTrue(
            background.contains("case \"subtraction\":"),
            "a backgrounded turn must not silently discard its subtractions")
        XCTAssertEqual(
            bridge.components(separatedBy: "case \"subtraction\":").count - 1, 2,
            "subtraction needs a case in both the foreground and background switches")
    }

    func testMalformedReportsAreDroppedRatherThanDrawn() {
        // Reporting must never be able to draw an unexplained badge.
        XCTAssertNil(AgentActivityRecord.subtraction(
            turnID: "t", subject: nil, reason: "plan_mode_readonly", names: ["Bash"], count: 1))
        XCTAssertNil(AgentActivityRecord.subtraction(
            turnID: "t", subject: "not-a-subject", reason: nil, names: ["Bash"], count: 1))
        XCTAssertNil(AgentActivityRecord.subtraction(
            turnID: "t", subject: "tool", reason: "plan_mode_readonly", names: [], count: 0))

        // A reason a newer daemon invented decodes as nil and the marker still draws: degrade to
        // "withheld, cause unknown" rather than losing the event entirely.
        let future = AgentActivityRecord.subtraction(
            turnID: "t", subject: "tool", reason: "reason_from_a_newer_build",
            names: ["SomeTool"], count: 1)
        XCTAssertNotNil(future)
        XCTAssertEqual(future?.contextEventKind, .subtraction)
        XCTAssertNil(future?.subtractionReason)

        // The wire kind stays `.context` so builds predating this decode it as an ordinary sample
        // and ignore it, instead of rejecting the whole persisted activity ledger.
        XCTAssertEqual(future?.kind, .context)
    }
}
