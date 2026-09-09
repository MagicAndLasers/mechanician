import CryptoKit
import Foundation
import XCTest
@testable import Mechanician

final class AuthorityInboxOperationScannerTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "authority-inbox-operation-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makePrivateDirectory(_ relativePath: String, root: URL) throws -> URL {
        var directory = root
        for component in relativePath.split(separator: "/") {
            directory.appendPathComponent(String(component), isDirectory: true)
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        return directory
    }

    private func envelopeBytes(
        operationID: UUID,
        conversationID: UUID,
        payloadDigestOverride: String? = nil,
        extraTopLevel: [String: Any] = [:]
    ) throws -> Data {
        let conversation = Conversation(
            id: conversationID,
            title: "Ambient result",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .assistant, text: "Completed scheduled work")],
            updatedAt: Date(timeIntervalSince1970: 1_807_091_696))
        let payloadBytes = try ConversationStore.makeEncoder().encode(conversation)
        let payloadDigest = digest(payloadBytes)
        let payloadBase64 = payloadBytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var envelope: [String: Any] = [
            "schemaVersion": 1,
            "operationID": operationID.uuidString,
            "subjectID": conversationID.uuidString,
            "producer": ["id": "ambientd", "build": "0.24.0-208-authority-inbox-v1"],
            "authority": [
                "protocol": "storage-authority-v1",
                "observedGeneration": "legacy-unmarked",
            ],
            "domain": "conversation",
            "kind": "create",
            "definitionRevision": "definition-revision-7",
            "createdAt": "2026-08-05T12:34:56Z",
            "payload": [
                "encoding": "base64url-json",
                "byteCount": payloadBytes.count,
                "sha256": payloadDigestOverride ?? payloadDigest,
                "data": payloadBase64,
            ],
            "retainedBytes": [],
        ]
        for (key, value) in extraTopLevel { envelope[key] = value }
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    @discardableResult
    private func writeEnvelope(
        _ bytes: Data,
        operationID: UUID,
        directory: URL,
        filename: String? = nil
    ) throws -> URL {
        let url = directory.appendingPathComponent(filename ?? "\(operationID.uuidString).json")
        try bytes.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400], ofItemAtPath: url.path)
        return url
    }

    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func testAdoptedConversationEnvelopeProducesStableAppliedOperation() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let adopted = try makePrivateDirectory(
            "authority-inbox/v1/adopted/ambientd", root: root)
        let operationID = UUID()
        let conversationID = UUID()
        let bytes = try envelopeBytes(
            operationID: operationID, conversationID: conversationID)
        _ = try writeEnvelope(bytes, operationID: operationID, directory: adopted)

        let first = LibraryAuthorityInboxOperationScanner.scan(supportRoot: root)
        let repeated = LibraryAuthorityInboxOperationScanner.scan(supportRoot: root)
        XCTAssertTrue(first.hasCompleteCensus)
        XCTAssertTrue(first.issues.isEmpty)
        XCTAssertEqual(first.operations.count, 1)
        XCTAssertEqual(first.operations.map(\.operation), repeated.operations.map(\.operation))
        XCTAssertEqual(first.operations.map(\.receipt), repeated.operations.map(\.receipt))
        let candidate = try XCTUnwrap(first.operations.first)
        let payload = try candidate.operation.backgroundAdoptionPayload()
        XCTAssertEqual(candidate.operation.id, operationID)
        XCTAssertEqual(candidate.operation.state, .committed)
        XCTAssertEqual(candidate.receipt.state, .applied)
        XCTAssertEqual(candidate.receipt.operationID, operationID)
        XCTAssertEqual(payload.conversationID, conversationID)
        XCTAssertEqual(
            payload.sourceIdentity,
            "authority-inbox/v1/adopted/ambientd/\(operationID.uuidString).json")
        XCTAssertEqual(payload.sourceRevision, "sha256:\(digest(bytes))")
        XCTAssertEqual(payload.sourceDigest, digest(bytes))

    }

    func testMalformedEnvelopeAndUnsafeLinkAreSourceIssuesWithoutBeingFollowed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let adopted = try makePrivateDirectory(
            "authority-inbox/v1/adopted/ambientd", root: root)
        let malformedID = UUID()
        let malformed = try envelopeBytes(
            operationID: malformedID,
            conversationID: UUID(),
            payloadDigestOverride: String(repeating: "0", count: 64),
            extraTopLevel: ["futureRoutingAuthority": "library.db"])
        _ = try writeEnvelope(malformed, operationID: malformedID, directory: adopted)

        let outside = root.appendingPathComponent("must-not-follow.json")
        let outsideBytes = Data("private outside bytes".utf8)
        try outsideBytes.write(to: outside)
        let linkedID = UUID()
        try FileManager.default.createSymbolicLink(
            at: adopted.appendingPathComponent("\(linkedID.uuidString).json"),
            withDestinationURL: outside)

        let scan = LibraryAuthorityInboxOperationScanner.scan(supportRoot: root)

        XCTAssertTrue(scan.hasCompleteCensus)
        XCTAssertTrue(scan.operations.isEmpty)
        XCTAssertEqual(scan.issues.count, 2)
        XCTAssertEqual(Set(scan.issues.compactMap(\.operationID)), [malformedID, linkedID])
        XCTAssertTrue(scan.issues.allSatisfy { $0.kind == .malformed })
        XCTAssertFalse(scan.issues.contains { $0.source.digest == digest(outsideBytes) })
    }

    func testQuarantinedEnvelopeBlocksCompleteCensusAndDiagnosticSidecarIsIgnored() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let quarantine = try makePrivateDirectory(
            "authority-inbox/v1/quarantine/ambientd", root: root)
        let operationID = UUID()
        let bytes = try envelopeBytes(operationID: operationID, conversationID: UUID())
        _ = try writeEnvelope(
            bytes,
            operationID: operationID,
            directory: quarantine,
            filename: "\(operationID.uuidString).\(UUID().uuidString).json")
        let diagnostic = quarantine.appendingPathComponent(
            "\(operationID.uuidString).diagnostic.json")
        try Data("{\"reason\":\"collision\"}".utf8).write(to: diagnostic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400], ofItemAtPath: diagnostic.path)

        let scan = LibraryAuthorityInboxOperationScanner.scan(supportRoot: root)

        XCTAssertFalse(scan.hasCompleteCensus)
        XCTAssertTrue(scan.operations.isEmpty)
        XCTAssertEqual(scan.issues.count, 1)
        XCTAssertEqual(scan.issues.first?.operationID, operationID)
        XCTAssertTrue(scan.issues.first?.diagnostics.contains("blocks activation") == true)
    }

    func testPendingCompleteEnvelopeIsUnresolvedAndBlocksCompleteCensus() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = try makePrivateDirectory(
            "authority-inbox/v1/pending/ambientd", root: root)
        let operationID = UUID()
        let conversationID = UUID()
        let bytes = try envelopeBytes(
            operationID: operationID, conversationID: conversationID)
        _ = try writeEnvelope(bytes, operationID: operationID, directory: pending)

        let scan = LibraryAuthorityInboxOperationScanner.scan(supportRoot: root)

        XCTAssertFalse(scan.hasCompleteCensus)
        XCTAssertTrue(scan.operations.isEmpty)
        XCTAssertEqual(scan.issues.count, 1)
        let issue = try XCTUnwrap(scan.issues.first)
        XCTAssertEqual(issue.operationID, operationID)
        XCTAssertEqual(issue.kind, .importFailure)
        XCTAssertEqual(
            issue.source.identity,
            "authority-inbox/v1/pending/ambientd/\(operationID.uuidString).json")
        XCTAssertEqual(issue.source.digest, digest(bytes))
        XCTAssertTrue(issue.diagnostics.contains("awaits app-owned Conversation adoption"))
        XCTAssertTrue(issue.diagnostics.contains("blocks activation"))
    }

    func testTwoLinkPendingAndImmutableStagingAreUnresolvedPublicationEvidence() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = try makePrivateDirectory(
            "authority-inbox/v1/pending/ambientd", root: root)
        let staging = try makePrivateDirectory(
            "authority-inbox/v1/staging/ambientd", root: root)
        let operationID = UUID()
        let bytes = try envelopeBytes(
            operationID: operationID, conversationID: UUID())
        let pendingURL = try writeEnvelope(
            bytes, operationID: operationID, directory: pending)
        let stagingURL = staging.appendingPathComponent(
            ".\(operationID.uuidString).12345.\(UUID().uuidString).tmp")
        try FileManager.default.linkItem(at: pendingURL, to: stagingURL)

        let scan = LibraryAuthorityInboxOperationScanner.scan(supportRoot: root)

        XCTAssertFalse(scan.hasCompleteCensus)
        XCTAssertTrue(scan.operations.isEmpty)
        XCTAssertEqual(scan.issues.count, 2)
        XCTAssertTrue(scan.issues.allSatisfy { $0.operationID == operationID })
        XCTAssertTrue(scan.issues.allSatisfy { $0.kind == .importFailure })
        XCTAssertEqual(
            Set(scan.issues.map(\.source.identity)),
            [
                "authority-inbox/v1/pending/ambientd/\(operationID.uuidString).json",
                "authority-inbox/v1/staging/ambientd/\(stagingURL.lastPathComponent)",
            ])
        XCTAssertTrue(scan.issues.contains {
            $0.diagnostics.contains("hard-link publication window")
        })
        XCTAssertTrue(scan.issues.contains {
            $0.diagnostics.contains("staging alias remains")
        })

        XCTAssertThrowsError(
            try LibraryAuthorityInboxOperationScanner.readConversationCreate(at: pendingURL)
        ) { error in
            XCTAssertTrue(
                LibraryAuthorityInboxOperationScanner.publicationIsIncomplete(error))
        }
    }

    func testMutableStagingWriteIsUnresolvedWithoutBeingDecoded() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try makePrivateDirectory(
            "authority-inbox/v1/staging/ambientd", root: root)
        let operationID = UUID()
        let stagingURL = staging.appendingPathComponent(
            ".\(operationID.uuidString).12345.\(UUID().uuidString).tmp")
        try Data("{\"partial\":".utf8).write(to: stagingURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: stagingURL.path)

        let scan = LibraryAuthorityInboxOperationScanner.scan(supportRoot: root)

        XCTAssertFalse(scan.hasCompleteCensus)
        XCTAssertTrue(scan.operations.isEmpty)
        XCTAssertEqual(scan.issues.count, 1)
        let issue = try XCTUnwrap(scan.issues.first)
        XCTAssertEqual(issue.operationID, operationID)
        XCTAssertEqual(issue.kind, .importFailure)
        XCTAssertTrue(issue.diagnostics.contains("mutable producer write"))
        XCTAssertTrue(issue.diagnostics.contains("blocks activation"))
    }

    func testPendingUUIDDirectoryAndUnsafeFileAreMalformedNotIncompletePublication() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = try makePrivateDirectory(
            "authority-inbox/v1/pending/ambientd", root: root)

        let directoryID = UUID()
        let directoryURL = pending.appendingPathComponent(
            "\(directoryID.uuidString).json", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])

        let unsafeID = UUID()
        let unsafeBytes = try envelopeBytes(
            operationID: unsafeID, conversationID: UUID())
        let unsafeURL = try writeEnvelope(
            unsafeBytes, operationID: unsafeID, directory: pending)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: unsafeURL.path)

        for url in [directoryURL, unsafeURL] {
            XCTAssertThrowsError(
                try LibraryAuthorityInboxOperationScanner.readConversationCreate(at: url)
            ) { error in
                XCTAssertFalse(
                    LibraryAuthorityInboxOperationScanner.publicationIsIncomplete(error))
            }
        }

        let scan = LibraryAuthorityInboxOperationScanner.scan(supportRoot: root)

        XCTAssertFalse(scan.hasCompleteCensus)
        XCTAssertTrue(scan.operations.isEmpty)
        XCTAssertEqual(scan.issues.count, 2)
        XCTAssertEqual(
            Set(scan.issues.compactMap(\.operationID)),
            [directoryID, unsafeID])
        XCTAssertTrue(scan.issues.allSatisfy { $0.kind == .malformed })
    }

    func testThreeLinkPendingEnvelopeIsMalformedNotIncompletePublication() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = try makePrivateDirectory(
            "authority-inbox/v1/pending/ambientd", root: root)
        let operationID = UUID()
        let bytes = try envelopeBytes(
            operationID: operationID, conversationID: UUID())
        let pendingURL = try writeEnvelope(
            bytes, operationID: operationID, directory: pending)
        try FileManager.default.linkItem(
            at: pendingURL,
            to: root.appendingPathComponent("extra-one-\(UUID().uuidString)"))
        try FileManager.default.linkItem(
            at: pendingURL,
            to: root.appendingPathComponent("extra-two-\(UUID().uuidString)"))

        XCTAssertThrowsError(
            try LibraryAuthorityInboxOperationScanner.readConversationCreate(at: pendingURL)
        ) { error in
            XCTAssertFalse(
                LibraryAuthorityInboxOperationScanner.publicationIsIncomplete(error))
        }
        let scan = LibraryAuthorityInboxOperationScanner.scan(supportRoot: root)
        XCTAssertFalse(scan.hasCompleteCensus)
        XCTAssertTrue(scan.operations.isEmpty)
        XCTAssertEqual(scan.issues.count, 1)
        XCTAssertEqual(scan.issues.first?.operationID, operationID)
        XCTAssertEqual(scan.issues.first?.kind, .malformed)
    }

    func testUnsafeQuarantineDiagnosticIsMalformedEvidence() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let quarantine = try makePrivateDirectory(
            "authority-inbox/v1/quarantine/ambientd", root: root)
        let operationID = UUID()
        let diagnostic = quarantine.appendingPathComponent(
            "\(operationID.uuidString).diagnostic.json", isDirectory: true)
        try FileManager.default.createDirectory(
            at: diagnostic,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])

        let scan = LibraryAuthorityInboxOperationScanner.scan(supportRoot: root)

        XCTAssertFalse(scan.hasCompleteCensus)
        XCTAssertTrue(scan.operations.isEmpty)
        XCTAssertEqual(scan.issues.count, 1)
        XCTAssertEqual(scan.issues.first?.operationID, operationID)
        XCTAssertEqual(scan.issues.first?.kind, .malformed)
        XCTAssertTrue(scan.issues.first?.diagnostics.contains("diagnostic is unsafe") == true)
    }
}
