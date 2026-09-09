import XCTest
@testable import Mechanician

final class CodexDiagnosticsExportTests: XCTestCase {
    func testExportReconstructsOnlyAllowlistedRedactedFields() throws {
        let raw: [String: Any] = [
            "format": CodexDiagnosticsExport.format,
            "exportedAt": "2026-07-18T12:00:00.000Z",
            "runtime": [
                "runtimeId": "runtime-1",
                "codexVersion": "0.144.6",
                "schemaHash": "schema-hash",
                "processGeneration": 3,
                "environment": ["OPENAI_API_KEY": "secret"],
            ],
            "entries": [[
                "recordedAt": "2026-07-18T12:00:00.000Z",
                "monotonicMs": 42,
                "conversationHash": "0123456789abcdef",
                "effort": "ultra",
                "event": "reconcile_started",
                "previousState": "providerActive",
                "nextState": "reconciling",
                "activeFlags": ["waitingOnApproval"],
                "prompt": "PRIVATE PROMPT",
                "output": "PRIVATE OUTPUT",
                "toolPayload": ["command": "cat secret"],
                "credentials": "secret",
            ]],
            "prompt": "TOP LEVEL PRIVATE PROMPT",
        ]

        let data = try CodexDiagnosticsExport.encoded(raw)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(decoded["entries"] as? [[String: Any]])
        let entry = try XCTUnwrap(entries.first)

        XCTAssertEqual(decoded["format"] as? String, CodexDiagnosticsExport.format)
        XCTAssertEqual(decoded["entryCount"] as? Int, 1)
        XCTAssertEqual(entry["effort"] as? String, "ultra")
        XCTAssertEqual(entry["activeFlags"] as? [String], ["waitingOnApproval"])
        XCTAssertNil(entry["prompt"])
        XCTAssertNil(entry["output"])
        XCTAssertNil(entry["toolPayload"])
        XCTAssertFalse(text.contains("PRIVATE"))
        XCTAssertFalse(text.contains("OPENAI_API_KEY"))
        XCTAssertFalse(text.contains("cat secret"))
    }

    func testExportRejectsWrongFormatAndUnboundedEntryCount() {
        XCTAssertThrowsError(try CodexDiagnosticsExport.encoded([
            "format": "unknown", "entries": [],
        ]))
        XCTAssertThrowsError(try CodexDiagnosticsExport.encoded([
            "format": CodexDiagnosticsExport.format,
            "entries": Array(repeating: ["event": "fixture"], count: 257),
        ]))
    }

    func testExportWritesAtomicallyReadableJSON() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("diagnostics.json")
        try CodexDiagnosticsExport.write([
            "format": CodexDiagnosticsExport.format,
            "entries": [["event": "turn_terminal", "nextState": "completed"]],
        ], to: destination)

        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: destination))
            as? [String: Any]
        XCTAssertEqual(decoded?["entryCount"] as? Int, 1)
    }
}
