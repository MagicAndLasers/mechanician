import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Mechanician

final class ExperimentalConversationRecordTests: XCTestCase {
    private func sampleConversation() -> Conversation {
        var tool = TranscriptEntry(
            kind: .tool,
            text: "run PRIVATE_TOOL_INPUT with PRIVATE_PROVIDER_RESUME_HANDLE")
        tool.toolName = "Bash"
        tool.toolUseId = "provider-tool-handle-PRIVATE"
        tool.toolResult = "PRIVATE_TOOL_RESULT for PRIVATE_PROVIDER_RESUME_HANDLE"
        tool.captureOrdinal = 2
        tool.toolResultCaptureOrdinal = 3

        var conversation = Conversation(
            title: "Portable example PRIVATE_PROVIDER_RESUME_HANDLE",
            cwd: "/Users/private/PRIVATE_CWD",
            sdkSessionId: "PRIVATE_PROVIDER_RESUME_HANDLE",
            messages: [
                TranscriptEntry(
                    id: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!,
                    kind: .user,
                    text: "Please inspect /Users/private/repository/source.swift",
                    captureOrdinal: 1),
                tool,
                TranscriptEntry(
                    id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
                    kind: .assistant,
                    text: "Inspection complete.",
                    captureOrdinal: 4),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_786_000_000),
            queuedPrompts: ["PRIVATE_QUEUED_PROMPT"],
            draft: "PRIVATE_UNSENT_DRAFT",
            projectID: UUID(uuidString: "99999999-8888-4777-8666-555555555555"))
        conversation.pendingTurnPrompt = "PRIVATE_PENDING_TURN"
        return conversation
    }

    private func temporaryURL(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExperimentalConversationRecordTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent(name)
    }

    private func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffffffff
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 {
                value = value & 1 == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1
            }
        }
        return value ^ 0xffffffff
    }

    private func replacingCommit(
        in bytes: Data,
        mutate: (inout [String: Any]) -> Void
    ) throws -> Data {
        var offset = 16
        var finalFrameStart = offset
        while offset < bytes.count {
            finalFrameStart = offset
            let length = Int(littleEndianUInt32(bytes, at: offset))
            offset += 8 + length
        }
        let payloadStart = finalFrameStart + 8
        let payloadLength = Int(littleEndianUInt32(bytes, at: finalFrameStart))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: bytes.subdata(in: payloadStart..<(payloadStart + payloadLength)))
                as? [String: Any])
        XCTAssertEqual(object["frameType"] as? String, "commit")
        mutate(&object)
        let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var length = UInt32(payload.count).littleEndian
        var checksum = crc32(payload).littleEndian
        var result = bytes.prefix(finalFrameStart)
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &checksum) { result.append(contentsOf: $0) }
        result.append(payload)
        return Data(result)
    }

    private func encodeFrame(_ object: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var length = UInt32(payload.count).littleEndian
        var checksum = crc32(payload).littleEndian
        var result = Data()
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &checksum) { result.append(contentsOf: $0) }
        result.append(payload)
        return result
    }

    /// Rebuild a structurally valid committed record after changing its semantic frames. This keeps
    /// the negative tests from passing merely because a stale CRC or commit digest was detected.
    private func replacingCommittedFrames(
        in bytes: Data,
        mutate: (inout [[String: Any]]) throws -> Void
    ) throws -> Data {
        let preludeLength = 16
        var frames: [[String: Any]] = []
        var offset = preludeLength
        while offset < bytes.count {
            let length = Int(littleEndianUInt32(bytes, at: offset))
            let payloadStart = offset + 8
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: bytes.subdata(in: payloadStart..<(payloadStart + length)))
                    as? [String: Any])
            offset = payloadStart + length
            if object["frameType"] as? String == "commit" { break }
            frames.append(object)
        }

        try mutate(&frames)
        var committedPrefix = Data(bytes.prefix(preludeLength))
        for frame in frames {
            committedPrefix.append(try encodeFrame(frame))
        }
        let digest = SHA256.hash(data: committedPrefix)
            .map { String(format: "%02x", $0) }
            .joined()
        let commit: [String: Any] = [
            "frameType": "commit",
            "committedFrameCount": frames.count,
            "committedByteLength": committedPrefix.count,
            "contentDigestSHA256": digest,
        ]
        committedPrefix.append(try encodeFrame(commit))
        return committedPrefix
    }

    private func assertSemanticMutationRejected(
        _ name: String,
        mutate: (inout [[String: Any]]) throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let destination = try temporaryURL("semantic-\(name).convrec")
        _ = try ExperimentalConversationRecordExporter.exportSynchronously(
            conversation: sampleConversation(),
            profile: .localFull,
            destination: destination)
        let mutated = try replacingCommittedFrames(
            in: Data(contentsOf: destination), mutate: mutate)
        try mutated.write(to: destination)
        XCTAssertThrowsError(
            try ExperimentalConversationRecordValidator.validate(destination),
            file: file,
            line: line
        ) {
            XCTAssertEqual(
                $0 as? ExperimentalConversationRecordError,
                .malformedFrame,
                file: file,
                line: line)
        }
    }

    func testShareSnapshotRoundTripsAndExcludesPrivateAndSensitiveProfileContent() throws {
        let conversation = sampleConversation()
        let sourceBefore = try ConversationStore.makeEncoder().encode(conversation)
        let destination = try temporaryURL("share.convrec")

        let report = try ExperimentalConversationRecordExporter.exportSynchronously(
            conversation: conversation,
            profile: .shareSnapshot,
            destination: destination)
        let independentlyRead = try ExperimentalConversationRecordValidator.validate(destination)
        let raw = try String(decoding: Data(contentsOf: destination), as: UTF8.self)

        XCTAssertEqual(report, independentlyRead)
        XCTAssertEqual(report.profile, ExperimentalConversationRecordProfile.shareSnapshot.rawValue)
        XCTAssertEqual(report.events, 2, "Share retains user/assistant dialog and omits tool frames.")
        XCTAssertTrue(raw.contains("Inspection complete."))
        XCTAssertTrue(raw.contains("[absolute path omitted]"))
        for privateValue in [
            "PRIVATE_CWD", "PRIVATE_PROVIDER_RESUME_HANDLE", "PRIVATE_QUEUED_PROMPT",
            "PRIVATE_UNSENT_DRAFT", "PRIVATE_PENDING_TURN", "PRIVATE_TOOL_INPUT",
            "PRIVATE_TOOL_RESULT", "provider-tool-handle-PRIVATE",
            conversation.id.uuidString,
            "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
        ] {
            XCTAssertFalse(raw.contains(privateValue), "Leaked \(privateValue)")
        }
        XCTAssertEqual(try ConversationStore.makeEncoder().encode(conversation), sourceBefore)
        XCTAssertTrue(report.lineageID.hasPrefix("urn:uuid:"))
        XCTAssertEqual(report.lineageID.dropFirst("urn:uuid:".count).dropFirst(14).first, "8")
    }

    func testLocalFullRetainsMappedToolFactsButNeverPrivateOperativeState() throws {
        let conversation = sampleConversation()
        let destination = try temporaryURL("local.convrec")

        let report = try ExperimentalConversationRecordExporter.exportSynchronously(
            conversation: conversation,
            profile: .localFull,
            destination: destination)
        let raw = try String(decoding: Data(contentsOf: destination), as: UTF8.self)

        XCTAssertEqual(report.events, 4)
        XCTAssertTrue(raw.contains(
            "run PRIVATE_TOOL_INPUT with [private operative value omitted]"))
        XCTAssertTrue(raw.contains(
            "PRIVATE_TOOL_RESULT for [private operative value omitted]"))
        XCTAssertTrue(raw.contains(
            "Portable example [private operative value omitted]"))
        XCTAssertFalse(raw.contains("provider-tool-handle-PRIVATE"),
                       "Provider correlation must be reminted bundle-locally.")
        XCTAssertFalse(raw.contains("PRIVATE_PROVIDER_RESUME_HANDLE"))
        XCTAssertFalse(raw.contains("PRIVATE_UNSENT_DRAFT"))
        XCTAssertTrue(report.omissions.contains {
            $0.code == "private-operative-value-echoes" && $0.count >= 2
        })
    }

    func testInspectorReturnsBoundedDialogAndAgentsWithoutReopeningOrMutatingTheFile() throws {
        let destination = try temporaryURL("inspect.convrec")
        _ = try ExperimentalConversationRecordExporter.exportSynchronously(
            conversation: sampleConversation(),
            profile: .shareSnapshot,
            destination: destination)
        let before = try Data(contentsOf: destination)

        let inspection = try ExperimentalConversationRecordValidator.inspect(destination)

        XCTAssertEqual(inspection.displayName, "Shared Conversation")
        XCTAssertEqual(inspection.report.events, 2)
        XCTAssertEqual(inspection.agents.map(\.displayID), ["root"])
        XCTAssertEqual(inspection.dialog.map(\.kind), ["user_message", "assistant_message"])
        XCTAssertTrue(inspection.dialog[0].text.contains("Please inspect"))
        XCTAssertEqual(inspection.dialog[1].text, "Inspection complete.")
        XCTAssertEqual(inspection.omittedDialogEntryCount, 0)
        XCTAssertEqual(inspection.truncatedDialogEntryCount, 0)
        XCTAssertEqual(try Data(contentsOf: destination), before)

        // The detached model remains the validated snapshot even if the selected pathname later
        // points at different bytes. The inspector never lazily reopens it for display.
        try Data("replacement".utf8).write(to: destination, options: .atomic)
        XCTAssertEqual(inspection.dialog[1].text, "Inspection complete.")
    }

    func testInspectorRendersHostileMarkupLiterallyAndBoundsText() throws {
        var conversation = sampleConversation()
        let hostile = """
        [file](file:///etc/passwd) ![remote](https://example.invalid/image.png)
        <script>fetch('https://example.invalid')</script><iframe src="ssh://host"></iframe>
        \u{202e}\u{0001}
        """ + String(
            repeating: "x",
            count: ExperimentalConversationRecordValidator.maximumInspectionDialogEntryUTF8Bytes + 64)
        conversation.messages[2].text = hostile
        let destination = try temporaryURL("hostile-display.convrec")
        _ = try ExperimentalConversationRecordExporter.exportSynchronously(
            conversation: conversation,
            profile: .shareSnapshot,
            destination: destination)

        let inspection = try ExperimentalConversationRecordValidator.inspect(destination)
        let displayed = try XCTUnwrap(inspection.dialog.last)

        XCTAssertTrue(displayed.text.contains("[file]("))
        XCTAssertTrue(displayed.text.contains("![remote](https://example.invalid"))
        XCTAssertTrue(displayed.text.contains("<script>"))
        XCTAssertTrue(displayed.text.contains("<iframe"))
        XCTAssertFalse(displayed.text.contains("\u{202e}"))
        XCTAssertFalse(displayed.text.contains("\u{0001}"))
        XCTAssertTrue(displayed.text.contains("\u{fffd}"))
        XCTAssertTrue(displayed.wasTruncated)
        XCTAssertEqual(inspection.truncatedDialogEntryCount, 1)
        XCTAssertGreaterThanOrEqual(inspection.replacedControlCharacterCount, 2)
        XCTAssertLessThanOrEqual(
            displayed.text.utf8.count,
            ExperimentalConversationRecordValidator.maximumInspectionDialogEntryUTF8Bytes)
    }

    func testInspectorCapsVisibleDialogRowsAndIgnoresCommittedTailContent() throws {
        var conversation = sampleConversation()
        conversation.messages = (0...ExperimentalConversationRecordValidator.maximumInspectionDialogCount)
            .map { index in
                TranscriptEntry(
                    kind: .assistant,
                    text: "row \(index)",
                    captureOrdinal: UInt64(index + 1))
            }
        let destination = try temporaryURL("bounded-rows.convrec")
        _ = try ExperimentalConversationRecordExporter.exportSynchronously(
            conversation: conversation,
            profile: .shareSnapshot,
            destination: destination)
        let maliciousTail = try encodeFrame([
            "frameType": "event",
            "event": [
                "kind": "assistant_message",
                "eventId": "tail-event",
                "agentId": "root",
                "text": "UNCOMMITTED TAIL MUST NOT DISPLAY",
            ],
        ])
        let handle = try FileHandle(forWritingTo: destination)
        try handle.seekToEnd()
        try handle.write(contentsOf: maliciousTail)
        try handle.close()

        let inspection = try ExperimentalConversationRecordValidator.inspect(destination)

        XCTAssertEqual(
            inspection.dialog.count,
            ExperimentalConversationRecordValidator.maximumInspectionDialogCount)
        XCTAssertEqual(inspection.omittedDialogEntryCount, 1)
        XCTAssertFalse(inspection.dialog.contains {
            $0.text.contains("UNCOMMITTED TAIL MUST NOT DISPLAY")
        })
        XCTAssertEqual(inspection.report.trailingUncommittedBytes, maliciousTail.count)
    }

    func testValidatorResourceCapsAndCancellationFailClosed() throws {
        XCTAssertNoThrow(try ExperimentalConversationRecordValidator.validateGraphEntityCounts(
            agents: ExperimentalConversationRecordValidator.maximumAgentCount,
            workflows: ExperimentalConversationRecordValidator.maximumWorkflowCount,
            phases: ExperimentalConversationRecordValidator.maximumWorkflowPhaseCount))
        XCTAssertThrowsError(try ExperimentalConversationRecordValidator.validateGraphEntityCounts(
            agents: ExperimentalConversationRecordValidator.maximumAgentCount + 1,
            workflows: 0,
            phases: 0)) {
            XCTAssertEqual($0 as? ExperimentalConversationRecordError, .malformedFrame)
        }
        XCTAssertNoThrow(try ExperimentalConversationRecordValidator.validateCanAppendEvent(
            currentCount: ExperimentalConversationRecordValidator.maximumEventCount - 1))
        XCTAssertThrowsError(try ExperimentalConversationRecordValidator.validateCanAppendEvent(
            currentCount: ExperimentalConversationRecordValidator.maximumEventCount)) {
            XCTAssertEqual($0 as? ExperimentalConversationRecordError, .malformedFrame)
        }
        XCTAssertEqual(
            try ExperimentalConversationRecordValidator.validateCanRetainSemanticBytes(
                currentBytes: ExperimentalConversationRecordValidator.maximumRetainedSemanticBytes - 64,
                addingUTF8Bytes: 0),
            ExperimentalConversationRecordValidator.maximumRetainedSemanticBytes)
        XCTAssertThrowsError(
            try ExperimentalConversationRecordValidator.validateCanRetainSemanticBytes(
                currentBytes: ExperimentalConversationRecordValidator.maximumRetainedSemanticBytes,
                addingUTF8Bytes: 0)) {
            XCTAssertEqual($0 as? ExperimentalConversationRecordError, .malformedFrame)
        }

        let destination = try temporaryURL("cancelled-inspection.convrec")
        _ = try ExperimentalConversationRecordExporter.exportSynchronously(
            conversation: sampleConversation(),
            profile: .shareSnapshot,
            destination: destination)
        XCTAssertThrowsError(try ExperimentalConversationRecordValidator.inspect(
            destination, isCancelled: { true })) {
            XCTAssertEqual($0 as? ExperimentalConversationRecordError, .validationCancelled)
        }
    }

    func testValidatorRejectsNamedPipesAndSymlinksWithoutBlockingOrFollowing() throws {
        let pipe = try temporaryURL("selected-pipe")
        let madePipe = pipe.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) }
        XCTAssertEqual(madePipe, 0)

        let startedAt = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try ExperimentalConversationRecordValidator.inspect(pipe)) {
            XCTAssertEqual($0 as? ExperimentalConversationRecordError, .notRegularFile)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 1)

        let destination = try temporaryURL("real.convrec")
        _ = try ExperimentalConversationRecordExporter.exportSynchronously(
            conversation: sampleConversation(),
            profile: .shareSnapshot,
            destination: destination)
        let link = destination.deletingLastPathComponent().appendingPathComponent("link.convrec")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        XCTAssertThrowsError(try ExperimentalConversationRecordValidator.inspect(link))
    }

    func testInspectorBoundsALongAgentChainAndParentageValidationStaysLinear() throws {
        let destination = try temporaryURL("long-agent-chain.convrec")
        _ = try ExperimentalConversationRecordExporter.exportSynchronously(
            conversation: sampleConversation(),
            profile: .shareSnapshot,
            destination: destination)
        var agents: [[String: Any]] = [["id": "root", "type": "root"]]
        for index in 1...ExperimentalConversationRecordValidator.maximumInspectionAgentCount {
            agents.append([
                "id": "agent-\(index)",
                "parentId": index == 1 ? "root" : "agent-\(index - 1)",
                "type": "subagent",
            ])
        }
        let mutated = try replacingCommittedFrames(
            in: Data(contentsOf: destination)
        ) { frames in
            var manifest = frames[0]
            var counts = try XCTUnwrap(manifest["counts"] as? [String: Any])
            counts["agents"] = agents.count
            manifest["counts"] = counts
            frames[0] = manifest

            var graphFrame = frames[1]
            var graph = try XCTUnwrap(graphFrame["graph"] as? [String: Any])
            graph["agents"] = agents
            graphFrame["graph"] = graph
            frames[1] = graphFrame
        }
        try mutated.write(to: destination)

        let inspection = try ExperimentalConversationRecordValidator.inspect(destination)

        XCTAssertEqual(inspection.report.agents, agents.count)
        XCTAssertEqual(
            inspection.agents.count,
            ExperimentalConversationRecordValidator.maximumInspectionAgentCount)
        XCTAssertEqual(inspection.omittedAgentCount, 1)
        XCTAssertEqual(inspection.agents.last?.parentID, "agent-1998")
    }

    func testInspectorUsesStableRowIdentityWhenHostileAgentLabelsSanitizeTheSame() throws {
        let destination = try temporaryURL("hostile-agent-labels.convrec")
        _ = try ExperimentalConversationRecordExporter.exportSynchronously(
            conversation: sampleConversation(),
            profile: .shareSnapshot,
            destination: destination)
        let hostileAgents: [[String: Any]] = [
            ["id": "root", "type": "root"],
            ["id": "agent-\u{202d}-a", "parentId": "root", "type": "subagent"],
            ["id": "agent-\u{202e}-a", "parentId": "root", "type": "subagent"],
        ]
        let mutated = try replacingCommittedFrames(
            in: Data(contentsOf: destination)
        ) { frames in
            var manifest = frames[0]
            var counts = try XCTUnwrap(manifest["counts"] as? [String: Any])
            counts["agents"] = hostileAgents.count
            manifest["counts"] = counts
            frames[0] = manifest

            var graphFrame = frames[1]
            var graph = try XCTUnwrap(graphFrame["graph"] as? [String: Any])
            graph["agents"] = hostileAgents
            graphFrame["graph"] = graph
            frames[1] = graphFrame
        }
        try mutated.write(to: destination)

        let inspection = try ExperimentalConversationRecordValidator.inspect(destination)

        XCTAssertEqual(inspection.agents.count, 3)
        XCTAssertEqual(Set(inspection.agents.map(\.id)).count, 3)
        XCTAssertEqual(inspection.agents[1].displayID, inspection.agents[2].displayID)
        XCTAssertTrue(inspection.agents[1].displayID.contains("\u{fffd}"))
    }

    func testValidatorRejectsExcessiveJSONNestingBeforeMaterializingIt() throws {
        try assertSemanticMutationRejected("json-depth") { frames in
            var frame = frames[2]
            var event = try XCTUnwrap(frame["event"] as? [String: Any])
            var nested: Any = "leaf"
            for _ in 0...ExperimentalConversationRecordValidator.maximumInspectionDialogCount / 25 {
                nested = [nested]
            }
            event["ignoredNestedValue"] = nested
            frame["event"] = event
            frames[2] = frame
        }
    }

    func testConversationRecordTypeIsExportedAndOwnedByThePublicBundle() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MechanicianTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .appendingPathComponent("Mechanician-Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any])

        let exported = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try XCTUnwrap(exported.first {
            $0["UTTypeIdentifier"] as? String == ExperimentalConversationRecordFileType.identifier
        })
        XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], ["public.data"])
        let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(
            tags["public.filename-extension"] as? [String],
            [ExperimentalConversationRecordFileType.filenameExtension])

        let documents = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let document = try XCTUnwrap(documents.first {
            ($0["LSItemContentTypes"] as? [String])?
                .contains(ExperimentalConversationRecordFileType.identifier) == true
        })
        XCTAssertEqual(document["CFBundleTypeRole"] as? String, "Viewer")
        XCTAssertEqual(document["LSHandlerRank"] as? String, "Owner")
    }

    func testAlternateBundlesImportConversationRecordTypeWithoutStealingFinderOwnership() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MechanicianTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repository
        let devScript = try String(
            contentsOf: repository.appendingPathComponent("dev.sh"), encoding: .utf8)
        let packagedScript = try String(
            contentsOf: repository.appendingPathComponent("build-app.sh"), encoding: .utf8)
        for script in [devScript, packagedScript] {
            XCTAssertTrue(script.contains("downgrade-conversation-record-plist.sh"))
        }
        XCTAssertTrue(packagedScript.contains(
            #"if [ "$BUNDLE_IDENTIFIER" != "ai.mechanician.app" ]; then"#))

        let sourcePlist = repository.appendingPathComponent("app/Mechanician-Info.plist")
        let sourceData = try Data(contentsOf: sourcePlist)
        var plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: sourceData, options: [], format: nil) as? [String: Any])
        var exported = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        exported.insert([
            "UTTypeIdentifier": "com.example.tenant-first",
            "UTTypeConformsTo": ["public.data"]
        ], at: 0)
        plist["UTExportedTypeDeclarations"] = exported
        plist["UTImportedTypeDeclarations"] = [[
            "UTTypeIdentifier": "com.example.existing-import",
            "UTTypeConformsTo": ["public.data"]
        ]]
        var documents = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        documents.insert([
            "CFBundleTypeName": "Tenant First",
            "CFBundleTypeRole": "Viewer",
            "LSHandlerRank": "Owner",
            "LSItemContentTypes": ["com.example.tenant-first"]
        ], at: 0)
        plist["CFBundleDocumentTypes"] = documents

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("convrec-plist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let transformedPlist = temporaryDirectory.appendingPathComponent("Info.plist")
        let transformedData = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try transformedData.write(to: transformedPlist)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            repository.appendingPathComponent(
                "scripts/downgrade-conversation-record-plist.sh").path,
            transformedPlist.path
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let errorOutput = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorOutput)

        let resultData = try Data(contentsOf: transformedPlist)
        let result = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: resultData, options: [], format: nil) as? [String: Any])
        let resultExported = try XCTUnwrap(
            result["UTExportedTypeDeclarations"] as? [[String: Any]])
        XCTAssertFalse(resultExported.contains {
            $0["UTTypeIdentifier"] as? String
                == ExperimentalConversationRecordFileType.identifier
        })
        XCTAssertTrue(resultExported.contains {
            $0["UTTypeIdentifier"] as? String == "com.example.tenant-first"
        })
        let resultImported = try XCTUnwrap(
            result["UTImportedTypeDeclarations"] as? [[String: Any]])
        XCTAssertTrue(resultImported.contains {
            $0["UTTypeIdentifier"] as? String
                == ExperimentalConversationRecordFileType.identifier
        })
        XCTAssertTrue(resultImported.contains {
            $0["UTTypeIdentifier"] as? String == "com.example.existing-import"
        })
        let resultDocuments = try XCTUnwrap(result["CFBundleDocumentTypes"] as? [[String: Any]])
        let resultConversationDocument = try XCTUnwrap(resultDocuments.first {
            ($0["LSItemContentTypes"] as? [String])?
                .contains(ExperimentalConversationRecordFileType.identifier) == true
        })
        XCTAssertEqual(resultConversationDocument["LSHandlerRank"] as? String, "Alternate")
        let resultTenantDocument = try XCTUnwrap(resultDocuments.first {
            ($0["LSItemContentTypes"] as? [String])?.contains("com.example.tenant-first") == true
        })
        XCTAssertEqual(resultTenantDocument["LSHandlerRank"] as? String, "Owner")

        var duplicatePlist = plist
        var duplicateExports = try XCTUnwrap(
            duplicatePlist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let conversationExport = try XCTUnwrap(duplicateExports.first {
            $0["UTTypeIdentifier"] as? String
                == ExperimentalConversationRecordFileType.identifier
        })
        duplicateExports.append(conversationExport)
        duplicatePlist["UTExportedTypeDeclarations"] = duplicateExports
        let duplicateURL = temporaryDirectory.appendingPathComponent("Duplicate.plist")
        try PropertyListSerialization.data(
            fromPropertyList: duplicatePlist, format: .xml, options: 0
        ).write(to: duplicateURL)
        let duplicateProcess = Process()
        duplicateProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
        duplicateProcess.arguments = [
            repository.appendingPathComponent(
                "scripts/downgrade-conversation-record-plist.sh").path,
            duplicateURL.path
        ]
        duplicateProcess.standardOutput = Pipe()
        duplicateProcess.standardError = Pipe()
        try duplicateProcess.run()
        duplicateProcess.waitUntilExit()
        XCTAssertNotEqual(
            duplicateProcess.terminationStatus,
            0,
            "ambiguous duplicate Conversation Record ownership declarations must fail closed")
    }

    func testOpenURLPartitionNeverRoutesConversationRecordsAsAttachments() {
        let lower = URL(fileURLWithPath: "/tmp/One.convrec")
        let upper = URL(fileURLWithPath: "/tmp/Two.CONVREC")
        let profile = URL(fileURLWithPath: "/tmp/Company.MECHANICIAN-PROFILE")
        let ordinary = URL(fileURLWithPath: "/tmp/notes.txt")
        let link = URL(string: "mechanician://conversation/example")!

        let partition = ApplicationOpenURLPartition([ordinary, lower, link, profile, upper])

        XCTAssertEqual(partition.conversationRecords, [lower, upper])
        XCTAssertEqual(partition.enterpriseProfiles, [profile])
        XCTAssertEqual(partition.attachmentFiles, [ordinary])
        XCTAssertEqual(partition.links, [link])
    }

    func testInspectorSourceHasNoActiveContentOrLiveStoreSurface() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MechanicianTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .appendingPathComponent("Sources/Mechanician/ExperimentalConversationRecordInspector.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        for forbidden in [
            "MarkdownText(", "NativeAssistantCell", "TranscriptLinkHandler", "WKWebView",
            "NSImage(contentsOf:", "ConversationStore", "ProjectStore", "ProjectionStore",
            "SpotlightIndex", "AgentBridge", "NSWorkspace.shared.open", "openURL(",
        ] {
            XCTAssertFalse(source.contains(forbidden), "Inspector gained active surface: \(forbidden)")
        }
        XCTAssertTrue(source.contains("Text(verbatim: entry.text)"))
        XCTAssertTrue(source.contains("OpenURLAction { _ in .discarded }"))
    }

    func testExportCopyDoesNotClaimRetiredJSONAuthority() throws {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MechanicianTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .appendingPathComponent("Sources/Mechanician")
        let actions = try String(
            contentsOf: appSources.appendingPathComponent(
                "ExperimentalConversationRecordActions.swift"),
            encoding: .utf8)
        let bridge = try String(
            contentsOf: appSources.appendingPathComponent("AgentBridge.swift"),
            encoding: .utf8)

        XCTAssertTrue(actions.contains(
            "Mechanician's library.db remains the product authority"))
        XCTAssertTrue(actions.contains(
            "editing this file does not change the live conversation"))
        XCTAssertFalse(actions.contains("existing Mechanician JSON remains authoritative"))
        XCTAssertTrue(bridge.contains("the library.db publication must succeed first"))
        XCTAssertFalse(bridge.contains("the ordinary JSON write must succeed first"))
    }

    func testValidatorAcceptsCommittedRecordWithTrailingTailWithoutMutatingIt() throws {
        let destination = try temporaryURL("tail.convrec")
        _ = try ExperimentalConversationRecordExporter.exportSynchronously(
            conversation: sampleConversation(),
            profile: .shareSnapshot,
            destination: destination)
        let original = try Data(contentsOf: destination)
        let tail = Data(repeating: 0xaa, count: 2 * 1024 * 1024 + 5)
        let handle = try FileHandle(forWritingTo: destination)
        try handle.seekToEnd()
        try handle.write(contentsOf: tail)
        try handle.close()

        let report = try ExperimentalConversationRecordValidator.validate(destination)

        XCTAssertEqual(report.trailingUncommittedBytes, tail.count)
        XCTAssertEqual(try Data(contentsOf: destination), original + tail)
    }

    func testValidatorRejectsCorruptionBeforeCommitAndDoesNotRepairFile() throws {
        let destination = try temporaryURL("corrupt.convrec")
        _ = try ExperimentalConversationRecordExporter.exportSynchronously(
            conversation: sampleConversation(),
            profile: .shareSnapshot,
            destination: destination)
        var corrupted = try Data(contentsOf: destination)
        corrupted[24] ^= 0x01 // First manifest payload byte; its saved CRC must now fail.
        try corrupted.write(to: destination)

        XCTAssertThrowsError(try ExperimentalConversationRecordValidator.validate(destination)) {
            XCTAssertEqual($0 as? ExperimentalConversationRecordError, .checksumMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: destination), corrupted)
    }

    func testValidatorRejectsOverlongAndNonIntegerCommittedScalars() throws {
        let destination = try temporaryURL("hostile-scalars.convrec")
        _ = try ExperimentalConversationRecordExporter.exportSynchronously(
            conversation: sampleConversation(),
            profile: .shareSnapshot,
            destination: destination)
        let valid = try Data(contentsOf: destination)

        let overlongDigest = try replacingCommit(in: valid) { object in
            object["contentDigestSHA256"] = (object["contentDigestSHA256"] as! String) + "0"
        }
        try overlongDigest.write(to: destination)
        XCTAssertThrowsError(try ExperimentalConversationRecordValidator.validate(destination)) {
            XCTAssertEqual($0 as? ExperimentalConversationRecordError, .commitMismatch)
        }

        let booleanCount = try replacingCommit(in: valid) { object in
            object["committedFrameCount"] = true
        }
        try booleanCount.write(to: destination)
        XCTAssertThrowsError(try ExperimentalConversationRecordValidator.validate(destination)) {
            XCTAssertEqual($0 as? ExperimentalConversationRecordError, .commitMismatch)
        }

        let fractionalLength = try replacingCommit(in: valid) { object in
            let length = (object["committedByteLength"] as! NSNumber).doubleValue
            object["committedByteLength"] = length + 0.5
        }
        try fractionalLength.write(to: destination)
        XCTAssertThrowsError(try ExperimentalConversationRecordValidator.validate(destination)) {
            XCTAssertEqual($0 as? ExperimentalConversationRecordError, .commitMismatch)
        }
    }

    func testValidatorRejectsSemanticallyInvalidGraphIdentityCountsAndParentage() throws {
        try assertSemanticMutationRejected("duplicate-agent") { frames in
            var manifest = frames[0]
            var counts = try XCTUnwrap(manifest["counts"] as? [String: Any])
            counts["agents"] = 2
            manifest["counts"] = counts
            frames[0] = manifest

            var graphFrame = frames[1]
            var graph = try XCTUnwrap(graphFrame["graph"] as? [String: Any])
            var agents = try XCTUnwrap(graph["agents"] as? [[String: Any]])
            agents.append(agents[0])
            graph["agents"] = agents
            graphFrame["graph"] = graph
            frames[1] = graphFrame
        }

        try assertSemanticMutationRejected("parent-cycle") { frames in
            var manifest = frames[0]
            var counts = try XCTUnwrap(manifest["counts"] as? [String: Any])
            counts["agents"] = 2
            manifest["counts"] = counts
            frames[0] = manifest

            var graphFrame = frames[1]
            var graph = try XCTUnwrap(graphFrame["graph"] as? [String: Any])
            graph["agents"] = [
                ["id": "root", "parentId": "child", "type": "root"],
                ["id": "child", "parentId": "root", "type": "agent"],
            ]
            graphFrame["graph"] = graph
            frames[1] = graphFrame
        }

        try assertSemanticMutationRejected("record-identity") { frames in
            var graphFrame = frames[1]
            var graph = try XCTUnwrap(graphFrame["graph"] as? [String: Any])
            var record = try XCTUnwrap(graph["record"] as? [String: Any])
            record["recordVersionID"] = "urn:uuid:00000000-0000-8000-8000-000000000000"
            graph["record"] = record
            graphFrame["graph"] = graph
            frames[1] = graphFrame
        }

        try assertSemanticMutationRejected("workflow-count") { frames in
            var manifest = frames[0]
            var counts = try XCTUnwrap(manifest["counts"] as? [String: Any])
            counts["workflows"] = 1
            manifest["counts"] = counts
            frames[0] = manifest
        }
    }

    func testValidatorRejectsUnknownDuplicateAndDanglingEventReferences() throws {
        try assertSemanticMutationRejected("unknown-kind") { frames in
            var frame = frames[2]
            var event = try XCTUnwrap(frame["event"] as? [String: Any])
            event["kind"] = "future_unreviewed_kind"
            frame["event"] = event
            frames[2] = frame
        }

        try assertSemanticMutationRejected("duplicate-event-id") { frames in
            let first = try XCTUnwrap(frames[2]["event"] as? [String: Any])
            let firstID = try XCTUnwrap(first["eventId"] as? String)
            var frame = frames[3]
            var event = try XCTUnwrap(frame["event"] as? [String: Any])
            event["eventId"] = firstID
            frame["event"] = event
            frames[3] = frame
        }

        try assertSemanticMutationRejected("unknown-agent") { frames in
            var frame = frames[2]
            var event = try XCTUnwrap(frame["event"] as? [String: Any])
            event["agentId"] = "agent-not-in-graph"
            frame["event"] = event
            frames[2] = frame
        }

        try assertSemanticMutationRejected("dangling-tool-call") { frames in
            let index = try XCTUnwrap(frames.firstIndex {
                ($0["event"] as? [String: Any])?["kind"] as? String == "tool_result"
            })
            var frame = frames[index]
            var event = try XCTUnwrap(frame["event"] as? [String: Any])
            event["toolUseId"] = "missing-tool-call"
            frame["event"] = event
            frames[index] = frame
        }

        try assertSemanticMutationRejected("dangling-interaction") { frames in
            var frame = frames[2]
            var event = try XCTUnwrap(frame["event"] as? [String: Any])
            event["kind"] = "authorization_response"
            event["interactionId"] = "missing-request"
            frame["event"] = event
            frames[2] = frame
        }

        try assertSemanticMutationRejected("dangling-event") { frames in
            var frame = frames[2]
            var event = try XCTUnwrap(frame["event"] as? [String: Any])
            event["kind"] = "supersession"
            event["targetEventId"] = "missing-event"
            frame["event"] = event
            frames[2] = frame
        }
    }

    func testValidatorRejectsChronologyCountsExtremaAndSerializationOrder() throws {
        try assertSemanticMutationRejected("chronology-count") { frames in
            var graphFrame = frames[1]
            var graph = try XCTUnwrap(graphFrame["graph"] as? [String: Any])
            var chronology = try XCTUnwrap(graph["chronology"] as? [String: Any])
            chronology["eventCount"] = 5
            graph["chronology"] = chronology
            graphFrame["graph"] = graph
            frames[1] = graphFrame
        }

        try assertSemanticMutationRejected("chronology-maximum") { frames in
            var graphFrame = frames[1]
            var graph = try XCTUnwrap(graphFrame["graph"] as? [String: Any])
            var chronology = try XCTUnwrap(graph["chronology"] as? [String: Any])
            chronology["maximumCaptureOrdinal"] = 400
            graph["chronology"] = chronology
            graphFrame["graph"] = graph
            frames[1] = graphFrame
        }

        try assertSemanticMutationRejected("chronology-order") { frames in
            frames.swapAt(2, 3)
        }

        try assertSemanticMutationRejected("chronology-counter-overflow") { frames in
            var graphFrame = frames[1]
            var graph = try XCTUnwrap(graphFrame["graph"] as? [String: Any])
            graph["chronology"] = [
                "status": "degraded",
                "eventCount": 2,
                "capturedOrdinalEventCount": 2,
                "missingCaptureOrdinalEventCount": Int.max,
                "invalidCaptureOrdinalEventCount": 1,
                "stableEventIdEventCount": 2,
                "missingStableEventIdEventCount": 0,
                "duplicateStableEventIdEventCount": 0,
                "legacySummaryEventCount": 0,
            ]
            graphFrame["graph"] = graph
            frames[1] = graphFrame
        }

        try assertSemanticMutationRejected("chronology-explicit-null") { frames in
            var graphFrame = frames[1]
            var graph = try XCTUnwrap(graphFrame["graph"] as? [String: Any])
            graph["chronology"] = [
                "status": "degraded",
                "eventCount": 2,
                "capturedOrdinalEventCount": 2,
                "missingCaptureOrdinalEventCount": 0,
                "invalidCaptureOrdinalEventCount": 0,
                "stableEventIdEventCount": 2,
                "missingStableEventIdEventCount": 0,
                "duplicateStableEventIdEventCount": 0,
                "legacySummaryEventCount": 0,
                "degradedWorkflowSummaryEventCount": NSNull(),
            ]
            graphFrame["graph"] = graph
            frames[1] = graphFrame
        }
    }

    func testExportRefusesToOverwriteAFileThatAlreadyExists() throws {
        let destination = try temporaryURL("already-exists.convrec")
        let existing = Data("concurrent owner".utf8)
        try existing.write(to: destination)

        XCTAssertThrowsError(try ExperimentalConversationRecordExporter.exportSynchronously(
            conversation: sampleConversation(),
            profile: .shareSnapshot,
            destination: destination
        )) {
            XCTAssertEqual(
                $0 as? ExperimentalConversationRecordError,
                .destinationAlreadyExists)
        }
        XCTAssertEqual(try Data(contentsOf: destination), existing)
    }

    @MainActor
    func testExportDestinationAddsTheProvisionalSuffixExactlyOnce() {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        XCTAssertEqual(
            ExperimentalConversationRecordActions.exportDestination(
                for: root.appendingPathComponent("example")),
            root.appendingPathComponent("example.convrec"))
        XCTAssertEqual(
            ExperimentalConversationRecordActions.exportDestination(
                for: root.appendingPathComponent("example.convrec")),
            root.appendingPathComponent("example.convrec"))
        XCTAssertEqual(
            ExperimentalConversationRecordActions.exportDestination(
                for: root.appendingPathComponent("example.CONVREC")),
            root.appendingPathComponent("example.CONVREC"))
    }

#if DEBUG
    func testExportPreservesDestinationCreatedAfterStagingValidation() throws {
        let destination = try temporaryURL("appeared-before-publication.convrec")
        let concurrent = Data("won destination race".utf8)
        ExperimentalConversationRecordExporter.publicationTestHook = {
            stage, _, published in
            guard case .beforeExclusiveRename = stage else { return }
            try! concurrent.write(to: published)
        }
        defer { ExperimentalConversationRecordExporter.publicationTestHook = nil }

        XCTAssertThrowsError(try ExperimentalConversationRecordExporter.exportSynchronously(
            conversation: sampleConversation(),
            profile: .shareSnapshot,
            destination: destination
        )) {
            XCTAssertEqual(
                $0 as? ExperimentalConversationRecordError,
                .destinationAlreadyExists)
        }
        XCTAssertEqual(try Data(contentsOf: destination), concurrent)
    }

    func testExportRejectsAndRemovesAStagingFileChangedBeforeExclusivePublication() throws {
        let destination = try temporaryURL("changed-before-publication.convrec")
        ExperimentalConversationRecordExporter.publicationTestHook = {
            stage, staging, _ in
            guard case .beforeExclusiveRename = stage else { return }
            let handle = try! FileHandle(forWritingTo: staging)
            try! handle.seekToEnd()
            try! handle.write(contentsOf: Data([0xaa]))
            try! handle.close()
        }
        defer { ExperimentalConversationRecordExporter.publicationTestHook = nil }

        XCTAssertThrowsError(try ExperimentalConversationRecordExporter.exportSynchronously(
            conversation: sampleConversation(),
            profile: .shareSnapshot,
            destination: destination
        )) {
            XCTAssertEqual($0 as? ExperimentalConversationRecordError, .publicationMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testExportPreservesAConcurrentEditDetectedByFinalValidation() throws {
        let destination = try temporaryURL("changed-after-publication.convrec")
        ExperimentalConversationRecordExporter.publicationTestHook = {
            stage, _, published in
            guard case .afterExclusiveRename = stage else { return }
            let handle = try! FileHandle(forWritingTo: published)
            try! handle.seekToEnd()
            try! handle.write(contentsOf: Data([0xbb]))
            try! handle.close()
        }
        defer { ExperimentalConversationRecordExporter.publicationTestHook = nil }

        XCTAssertThrowsError(try ExperimentalConversationRecordExporter.exportSynchronously(
            conversation: sampleConversation(),
            profile: .shareSnapshot,
            destination: destination
        )) {
            XCTAssertEqual($0 as? ExperimentalConversationRecordError, .publicationMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: destination).last, 0xbb)
    }
#endif
}
