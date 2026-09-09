import CryptoKit
import XCTest
@testable import Mechanician

final class ConversationFileToolCaptureTests: XCTestCase {
    func testSnapshotHashesASmallStableRegularFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("small.txt")
        let contents = Data("snapshot".utf8)
        try contents.write(to: file)

        let expectedDigest = SHA256.hash(data: contents)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(
            ConversationFileToolCapture.snapshotFile(file.path),
            .init(exists: true, digest: expectedDigest))
    }

    func testSnapshotLeavesOversizedFilesUndigested() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("oversized.txt")
        try Data(
            repeating: 0xA5,
            count: ConversationFileToolCapture.maximumDigestBytes + 1
        ).write(to: file)

        XCTAssertEqual(
            ConversationFileToolCapture.snapshotFile(file.path),
            .init(exists: true, digest: nil))
    }

    func testSnapshotLeavesAFileChangedDuringTheReadUndigested() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("changing.txt")
        try Data(repeating: 0xA5, count: 64 * 1_024).write(to: file)

        let snapshot = ConversationFileToolCapture.snapshotFile(file.path) {
            _ = FileManager.default.createFile(atPath: file.path, contents: Data())
        }

        XCTAssertEqual(snapshot, .init(exists: true, digest: nil))
    }

    func testDirectEditCarriesExactTurnToolPathAndBeforeAfterEvidence() throws {
        let conversationID = UUID()
        let promptID = UUID()
        let draft = try XCTUnwrap(ConversationFileToolCapture.begin(
            conversationID: conversationID,
            turnID: "turn-1",
            toolUseID: "tool-1",
            workingDirectory: "/workspace/project",
            workspaceID: nil,
            rootPromptEntryID: promptID,
            name: "Edit",
            input: [
                "file_path": "Sources/Feature.swift",
                "old_string": "let old = true",
                "new_string": "let old = false",
            ],
            snapshot: { _ in .init(exists: true, digest: "before") }))

        XCTAssertEqual(draft.conversationID, conversationID)
        XCTAssertEqual(draft.turnID, "turn-1")
        XCTAssertEqual(draft.toolUseID, "tool-1")
        XCTAssertEqual(draft.rootPromptEntryID, promptID)
        XCTAssertEqual(draft.operation, .edit)
        XCTAssertEqual(draft.files.map(\.absolutePath), [
            "/workspace/project/Sources/Feature.swift",
        ])
        XCTAssertEqual(draft.files.first?.beforeDigest, "before")
        XCTAssertEqual(draft.files.first?.boundedPatch, "- let old = true\n+ let old = false")

        let completed = ConversationFileToolCapture.finish(draft) { path in
            XCTAssertEqual(path, "/workspace/project/Sources/Feature.swift")
            return .init(exists: true, digest: "after")
        }
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0].beforeDigest, "before")
        XCTAssertEqual(completed[0].afterDigest, "after")
    }

    func testProviderChangeArrayKeepsDistinctCanonicalPathsAndPatches() throws {
        let draft = try XCTUnwrap(ConversationFileToolCapture.begin(
            conversationID: UUID(),
            turnID: "turn",
            toolUseID: "tool",
            workingDirectory: "/repo/subdir",
            workspaceID: UUID(),
            rootPromptEntryID: UUID(),
            name: "Edit",
            input: ["changes": [
                ["path": "../One.swift", "diff": "- one\n+ two"],
                ["path": "/repo/Two.swift", "diff": "+ two"],
                ["path": "../One.swift", "diff": "+ duplicate"],
            ]],
            snapshot: { _ in .init(exists: false, digest: nil) }))

        XCTAssertEqual(draft.files.map(\.absolutePath), [
            "/repo/One.swift", "/repo/Two.swift",
        ])
        XCTAssertEqual(draft.files.map(\.boundedPatch), ["- one\n+ two", "+ two"])
    }

    func testPatchIsUTF8SafeAndBounded() throws {
        let content = String(repeating: "🛠", count: 80_000)
        let draft = try XCTUnwrap(ConversationFileToolCapture.begin(
            conversationID: UUID(),
            turnID: "turn",
            toolUseID: "tool",
            workingDirectory: "/repo",
            workspaceID: nil,
            rootPromptEntryID: nil,
            name: "Write",
            input: ["file_path": "large.txt", "content": content],
            snapshot: { _ in .init(exists: false, digest: nil) }))

        let file = try XCTUnwrap(draft.files.first)
        XCTAssertTrue(file.patchWasTruncated)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(file.boundedPatch).utf8.count,
            ConversationFileObservation.maximumBoundedPatchBytes)
    }

    func testLargeMultiFileEditRetainsEveryNamedPathWhileBoundingContentCapture() throws {
        let changes: [[String: Any]] = (0..<20).map { index in
            ["path": "Sources/File\(index).swift", "diff": "+ let value = \(index)"]
        }
        let draft = try XCTUnwrap(ConversationFileToolCapture.begin(
            conversationID: UUID(),
            turnID: "turn-many",
            toolUseID: "tool-many",
            workingDirectory: "/repo",
            workspaceID: nil,
            rootPromptEntryID: nil,
            name: "Edit",
            input: ["changes": changes],
            snapshot: { _ in .init(exists: true, digest: "captured") }))

        XCTAssertEqual(draft.files.count, 20)
        XCTAssertEqual(draft.files.last?.absolutePath, "/repo/Sources/File19.swift")
        XCTAssertEqual(draft.files.filter(\.capturesContent).count, 16)
        XCTAssertNil(draft.files.last?.beforeDigest)
        XCTAssertNil(draft.files.last?.boundedPatch)

        let finished = ConversationFileToolCapture.finish(draft) { _ in
            .init(exists: true, digest: "after")
        }
        XCTAssertEqual(finished.count, 20)
        XCTAssertNil(finished.last?.afterDigest)
    }

    func testUnknownOrPathlessToolDoesNotCreateEvidence() {
        XCTAssertNil(ConversationFileToolCapture.begin(
            conversationID: UUID(), turnID: "turn", toolUseID: "tool",
            workingDirectory: "/repo", workspaceID: nil, rootPromptEntryID: nil,
            name: "Bash", input: ["command": "touch file"],
            snapshot: { _ in .init(exists: nil, digest: nil) }))
        XCTAssertNil(ConversationFileToolCapture.begin(
            conversationID: UUID(), turnID: "turn", toolUseID: "tool",
            workingDirectory: "/repo", workspaceID: nil, rootPromptEntryID: nil,
            name: "Read", input: [:],
            snapshot: { _ in .init(exists: nil, digest: nil) }))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationFileToolCaptureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
