import XCTest
@testable import Mechanician

/// FR-224. `info` is the app's cheapest channel for telling a person that something was subtracted:
/// it carries lines like "Continuing without <server> for this turn". It is turn-scoped whenever it
/// carries an id, so a backgrounded turn always takes `applyBackgroundEvent` — which had no `info`
/// case and fell to `default: break`.
///
/// The result was that the one existing user-facing report of a dropped MCP server reached nobody
/// unless they happened to be looking at that conversation, for exactly the long-running turns
/// people switch away from.
@MainActor
final class BackgroundInfoNoticeTests: XCTestCase {
    private func makeBridge() -> (AgentBridge, URL) {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mechanician-background-info-\(UUID().uuidString)", isDirectory: true)
        return (AgentBridge(settingsBaseOverride: support, environmentOverride: [:]), support)
    }

    func testBothDispatchPathsHandleInfo() {
        let (bridge, support) = makeBridge()
        defer {
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }

        // The rule this test exists to keep: a turn-scoped event that reaches a person must be
        // handled in BOTH dispatch paths. Reading the source is the only way to assert the absence
        // of a `default: break` swallowing it, because the background path writes to the store for
        // a conversation that is not on screen.
        let bridgeSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // MechanicianTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // app
            .appendingPathComponent("Sources/Mechanician/AgentBridge.swift")
        guard let source = try? String(contentsOf: bridgeSource, encoding: .utf8) else {
            return XCTFail("could not read AgentBridge.swift at \(bridgeSource.path)")
        }

        guard let backgroundStart = source.range(of: "private func applyBackgroundEvent") else {
            return XCTFail("applyBackgroundEvent not found")
        }
        let background = String(source[backgroundStart.lowerBound...].prefix(40_000))
        XCTAssertTrue(
            background.contains("case \"info\":"),
            "a backgrounded turn must not silently discard its info notices")
    }

    func testBackgroundNoticeClosesTheOpenAssistantRowAndRetainsEventChronology() {
        var assistant = TranscriptEntry(kind: .assistant, text: "before")
        assistant.captureOrdinal = 40
        var messages = [assistant]

        let notice = AgentBridge.appendBackgroundStructuralNotice(
            &messages,
            "Continuing without Example for this turn.",
            openEntryID: assistant.id,
            captureOrdinal: 41)

        XCTAssertTrue(notice.appended)
        XCTAssertNil(notice.openEntryID)
        XCTAssertEqual(messages.map(\.kind), [.assistant, .system])
        XCTAssertEqual(messages.last?.captureOrdinal, 41)

        let nextOpen = AgentBridge.appendBackgroundAssistantText(
            &messages,
            "after",
            openEntryID: notice.openEntryID,
            captureOrdinal: 42)
        XCTAssertEqual(messages.map(\.kind), [.assistant, .system, .assistant])
        XCTAssertEqual(messages.last?.id, nextOpen)
        XCTAssertEqual(messages.last?.captureOrdinal, 42)

        let duplicate = AgentBridge.appendBackgroundStructuralNotice(
            &messages,
            "duplicate boundary",
            openEntryID: nextOpen,
            captureOrdinal: 43)
        XCTAssertTrue(duplicate.appended)
        let suppressed = AgentBridge.appendBackgroundStructuralNotice(
            &messages,
            "duplicate boundary",
            openEntryID: nextOpen,
            captureOrdinal: 44)
        XCTAssertFalse(suppressed.appended)
        XCTAssertEqual(suppressed.openEntryID, nextOpen)
        XCTAssertEqual(messages.last?.captureOrdinal, 43)
    }
}
