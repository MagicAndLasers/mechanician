import XCTest
@testable import Mechanician

final class LibraryAmbientAuthorityAdaptersTests: XCTestCase {
    func testEveryDurableAmbientSourceRoundTripsCurrentSemantics() throws {
        let workspaceID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let definition = LibraryAmbientTaskDefinition(
            id: "scheduled-task-1",
            name: "Morning report",
            prompt: "Create the report",
            workspaceID: workspaceID,
            cwd: "",
            enabled: true,
            trigger: AmbientTrigger(
                type: "time",
                schedule: AmbientSchedule(
                    kind: "daily", minutes: nil, hour: 9, minute: 15, at: nil),
                path: nil,
                client: nil,
                filter: nil),
            access: ModelAccess.anthropicAPI.rawValue,
            model: "model-a",
            effort: "high",
            permissionMode: "dontAsk",
            createdAt: "2026-08-04T12:00:00.000Z",
            definitionRevision: "definition-1",
            runRequestID: "request-1")
        try assertRoundTrip(
            [definition],
            kind: .taskDefinitions,
            prettyPrinted: true,
            decodeAs: [LibraryAmbientTaskDefinition].self)

        let runtime = [
            definition.id: LibraryAmbientTaskRuntime(
                definitionRevision: "definition-1",
                lastRun: "2026-08-04T12:30:00.000Z",
                lastResult: "Completed",
                nextRun: 1_800_000_000.5,
                lastMtime: 1_799_999_000.25,
                lastMailId: "mail-1",
                lastRunRequestID: "request-1",
                onceCompleted: false,
                activeRun: AmbientActiveRun(
                    id: "claim-1",
                    startedAt: "2026-08-04T12:29:59.000Z",
                    trigger: "manual")),
        ]
        try assertRoundTrip(
            runtime,
            kind: .schedulerRuntime,
            prettyPrinted: false,
            decodeAs: [String: LibraryAmbientTaskRuntime].self)

        let receipts = [AmbientRun(
            taskId: definition.id,
            at: "2026-08-04T12:30:00.000Z",
            ok: true,
            summary: "Completed",
            conversationID: "20000000-0000-0000-0000-000000000002")]
        try assertRoundTrip(
            receipts,
            kind: .runReceipts,
            prettyPrinted: false,
            decodeAs: [AmbientRun].self)
    }

    func testProcessLivenessSourcesAreExplicitlyExcludedFromAuthority() {
        XCTAssertTrue(
            LibraryAmbientAuthoritySourceKind.taskDefinitions.requiresAuthorityRepresentation)
        XCTAssertTrue(
            LibraryAmbientAuthoritySourceKind.schedulerRuntime.requiresAuthorityRepresentation)
        XCTAssertTrue(
            LibraryAmbientAuthoritySourceKind.runReceipts.requiresAuthorityRepresentation)
        XCTAssertFalse(
            LibraryAmbientAuthoritySourceKind.heartbeat.requiresAuthorityRepresentation)
        XCTAssertFalse(
            LibraryAmbientAuthoritySourceKind.schedulerLease.requiresAuthorityRepresentation)

        for kind in [
            LibraryAmbientAuthoritySourceKind.heartbeat,
            .schedulerLease,
        ] {
            XCTAssertThrowsError(
                try LibraryAmbientAuthorityAdapter.capture(sourceData: Data("{}".utf8), kind: kind))
        }
    }

    func testUnknownMembersFutureVersionsAndOversizeSourcesFailClosed() throws {
        let definition = LibraryAmbientTaskDefinition(
            id: "task-1",
            name: "Known",
            prompt: "Known prompt",
            workspaceID: nil,
            cwd: "",
            enabled: true,
            trigger: AmbientTrigger(
                type: "file", schedule: nil, path: "/tmp/watch",
                client: nil, filter: nil),
            access: nil,
            model: nil,
            effort: nil,
            permissionMode: nil,
            createdAt: nil,
            definitionRevision: "definition-1",
            runRequestID: nil)
        let known = try legacyEncoder().encode([definition])
        let captured = try LibraryAmbientAuthorityAdapter.capture(
            sourceData: known, kind: .taskDefinitions)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: known) as? [[String: Any]])
        legacyObject[0]["lastRun"] = "2026-08-04T11:00:00.000Z"
        legacyObject[0]["lastRunRequestID"] = "legacy-request"
        legacyObject[0]["runNow"] = true
        let legacyInlineRuntime = try JSONSerialization.data(
            withJSONObject: legacyObject, options: [.sortedKeys])
        let legacyCaptured = try LibraryAmbientAuthorityAdapter.capture(
            sourceData: legacyInlineRuntime, kind: .taskDefinitions)
        let legacyFresh = try LibraryAmbientAuthorityAdapter.freshLegacyData(
            version: legacyCaptured.version,
            payload: legacyCaptured.payload,
            expectedKind: .taskDefinitions)
        let legacyDecoded = try XCTUnwrap(
            JSONDecoder().decode([LibraryAmbientTaskDefinition].self, from: legacyFresh).first)
        XCTAssertEqual(legacyDecoded.lastRunRequestID, "legacy-request")
        XCTAssertTrue(legacyDecoded.runNow == true)

        XCTAssertThrowsError(try LibraryAmbientAuthorityAdapter.freshLegacyData(
            version: LibraryAmbientAuthorityAdapter.currentVersion + 1,
            payload: captured.payload,
            expectedKind: .taskDefinitions)) { error in
                XCTAssertEqual(
                    error as? LibraryAuthorityAdapterError,
                    .unsupportedPayloadVersion(
                        domain: "Ambient ambient_task_definitions", version: 2))
            }
        XCTAssertThrowsError(try LibraryAmbientAuthorityAdapter.freshLegacyData(
            version: captured.version,
            payload: captured.payload,
            expectedKind: .schedulerRuntime))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: known) as? [[String: Any]])
        object[0]["futureSchedulerContract"] = ["mustRetain": true]
        let futureSource = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(try LibraryAmbientAuthorityAdapter.capture(
            sourceData: futureSource, kind: .taskDefinitions)) { error in
                guard case LibraryAuthorityAdapterError.invalidPayload(let domain, let detail) = error
                else { return XCTFail("unexpected error: \(error)") }
                XCTAssertEqual(domain, "Ambient ambient_task_definitions")
                XCTAssertTrue(detail.contains("/0/futureSchedulerContract"))
            }

        let oversized = Data(
            repeating: 0,
            count: LibraryAmbientAuthorityAdapter.maximumSourceBytes + 1)
        XCTAssertThrowsError(try LibraryAmbientAuthorityAdapter.capture(
            sourceData: oversized, kind: .schedulerRuntime)) { error in
                guard case LibraryAuthorityAdapterError.payloadTooLarge = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
    }

    func testDuplicateTaskDefinitionsFailClosed() throws {
        let value = LibraryAmbientTaskDefinition(
            id: "duplicate",
            name: "One",
            prompt: "Prompt",
            workspaceID: nil,
            cwd: "",
            enabled: true,
            trigger: AmbientTrigger(
                type: "time",
                schedule: AmbientSchedule(
                    kind: "interval", minutes: 60, hour: nil, minute: nil, at: nil),
                path: nil,
                client: nil,
                filter: nil),
            access: nil,
            model: nil,
            effort: nil,
            permissionMode: nil,
            createdAt: nil,
            definitionRevision: nil,
            runRequestID: nil)
        let data = try legacyEncoder().encode([value, value])

        XCTAssertThrowsError(try LibraryAmbientAuthorityAdapter.capture(
            sourceData: data, kind: .taskDefinitions))
    }

    private func assertRoundTrip<Value: Codable & Equatable>(
        _ value: Value,
        kind: LibraryAmbientAuthoritySourceKind,
        prettyPrinted: Bool,
        decodeAs: Value.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let source = try legacyEncoder(prettyPrinted: prettyPrinted).encode(value)
        let captured = try LibraryAmbientAuthorityAdapter.capture(
            sourceData: source, kind: kind)
        XCTAssertEqual(captured.version, LibraryAmbientAuthorityAdapter.currentVersion)
        let fresh = try LibraryAmbientAuthorityAdapter.freshLegacyData(
            version: captured.version,
            payload: captured.payload,
            expectedKind: kind)
        XCTAssertEqual(
            try JSONDecoder().decode(decodeAs, from: fresh),
            value,
            file: file,
            line: line)
    }

    private func legacyEncoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let value = JSONEncoder()
        value.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return value
    }
}
