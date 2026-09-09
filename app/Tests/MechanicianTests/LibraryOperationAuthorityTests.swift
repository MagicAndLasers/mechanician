import CryptoKit
import Foundation
import XCTest
@testable import Mechanician

final class LibraryOperationAuthorityTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "library-operation-authority-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSlot(
        conversationID: UUID = UUID(),
        token: UUID = UUID(),
        root: URL
    ) throws -> (url: URL, conversationID: UUID, token: UUID) {
        let slot = root
            .appendingPathComponent("trash/conversations", isDirectory: true)
            .appendingPathComponent(
                "\(conversationID.uuidString)-\(token.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        return (slot, conversationID, token)
    }

    private func writeSidecar(
        _ bytes: Data,
        conversationID: UUID,
        slot: URL
    ) throws -> URL {
        let url = slot.appendingPathComponent("\(conversationID.uuidString).json")
        try bytes.write(to: url)
        return url
    }

    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func testValidLegacySlotPublishesBoundedDeleteAndRetainedSourceEdges() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let slot = try makeSlot(root: root)
        let sidecarBytes = Data("{\"id\":\"\(slot.conversationID.uuidString)\",\"messages\":[]}".utf8)
        _ = try writeSidecar(sidecarBytes, conversationID: slot.conversationID, slot: slot.url)
        let mediaDirectory = slot.url.appendingPathComponent(
            slot.conversationID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let imageBytes = Data("image recovery bytes".utf8)
        let attachmentBytes = Data("attachment recovery bytes".utf8)
        try imageBytes.write(to: mediaDirectory.appendingPathComponent("image.png"))
        try attachmentBytes.write(to: mediaDirectory.appendingPathComponent("brief.pdf"))

        let scan = LibraryConversationTrashScanner.scan(supportRoot: root)
        XCTAssertEqual(scan.operations.count, 1)
        let candidate = try XCTUnwrap(scan.operations.first)
        let payload = try candidate.operation.conversationDeletePayload()

        XCTAssertTrue(scan.hasCompleteCensus)
        XCTAssertTrue(scan.hasCompleteInventory)
        XCTAssertTrue(scan.issues.isEmpty)
        XCTAssertEqual(candidate.operation.kind, .conversationDelete)
        XCTAssertEqual(candidate.operation.state, .committed)
        XCTAssertLessThan(candidate.operation.payload.count, 1_024)
        XCTAssertEqual(payload.conversationID, slot.conversationID)
        XCTAssertEqual(
            payload.trashSlotIdentity,
            "trash/conversations/\(slot.url.lastPathComponent)")
        XCTAssertEqual(payload.queuePauseState, .unknownSafePaused)
        XCTAssertTrue(payload.queuePauseState.shouldRestorePaused)

        XCTAssertEqual(scan.retainedSources.count, 3)
        XCTAssertEqual(
            Set(scan.retainedSources.map(\.kind)),
            [.conversationSidecar, .conversationMedia])
        XCTAssertEqual(
            Set(scan.retainedSources.map(\.source.digest)),
            [digest(sidecarBytes), digest(imageBytes), digest(attachmentBytes)])
        XCTAssertEqual(scan.retainedSourceEdges.count, 3)
        XCTAssertEqual(
            Set(scan.retainedSourceEdges.map(\.role)),
            [.conversationSidecar, .conversationMedia])
        XCTAssertEqual(
            Set(scan.retainedSourceEdges.map(\.operationID)),
            [candidate.operation.id])
        XCTAssertEqual(
            Set(scan.retainedSourceEdges.map(\.retainedSourceIdentity)),
            Set(scan.retainedSources.map(\.source.identity)))
        XCTAssertFalse(
            candidate.operation.payload.range(of: sidecarBytes) != nil,
            "The operation payload must reference retained bytes, never embed the Conversation.")
    }

    func testOperationIdentityIsStableForOneSlotAndDistinctAcrossDeleteTokens() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = UUID()
        let first = try makeSlot(conversationID: conversationID, root: root)
        let second = try makeSlot(conversationID: conversationID, root: root)
        _ = try writeSidecar(
            Data("first".utf8), conversationID: conversationID, slot: first.url)
        _ = try writeSidecar(
            Data("second".utf8), conversationID: conversationID, slot: second.url)

        let initial = LibraryConversationTrashScanner.scan(supportRoot: root)
        let repeated = LibraryConversationTrashScanner.scan(supportRoot: root)

        XCTAssertEqual(initial.operations.count, 2)
        XCTAssertEqual(
            initial.operations.map(\.operation.id),
            repeated.operations.map(\.operation.id))
        XCTAssertEqual(Set(initial.operations.map(\.operation.id)).count, 2)
        for candidate in initial.operations {
            XCTAssertEqual(
                candidate.operation.id,
                LibraryConversationTrashScanner.stableOperationID(
                    slotName: candidate.slotIdentity.split(separator: "/").last.map(String.init)!))
        }
    }

    func testSymlinkedSidecarMediaAndSlotAreReportedWithoutFollowingTargets() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let slot = try makeSlot(root: root)
        let outsideSidecar = root.appendingPathComponent("private-source.json")
        let outsideMedia = root.appendingPathComponent("private-media.png")
        let privateSidecarBytes = Data("private sidecar must not hash".utf8)
        let privateMediaBytes = Data("private media must not hash".utf8)
        try privateSidecarBytes.write(to: outsideSidecar)
        try privateMediaBytes.write(to: outsideMedia)
        try FileManager.default.createSymbolicLink(
            at: slot.url.appendingPathComponent("\(slot.conversationID.uuidString).json"),
            withDestinationURL: outsideSidecar)
        let mediaDirectory = slot.url.appendingPathComponent(
            slot.conversationID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: mediaDirectory.appendingPathComponent("linked.png"),
            withDestinationURL: outsideMedia)

        let realSlot = try makeSlot(root: root)
        _ = try writeSidecar(
            Data("real".utf8),
            conversationID: realSlot.conversationID,
            slot: realSlot.url)
        let symlinkSlotName = "\(UUID().uuidString)-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(
            at: realSlot.url.deletingLastPathComponent().appendingPathComponent(symlinkSlotName),
            withDestinationURL: realSlot.url)

        let scan = LibraryConversationTrashScanner.scan(supportRoot: root)
        let quarantined = try XCTUnwrap(scan.operations.first {
            $0.conversationID == slot.conversationID
        })

        XCTAssertEqual(quarantined.operation.state, .quarantined)
        XCTAssertTrue(scan.hasCompleteCensus)
        XCTAssertFalse(scan.hasCompleteInventory)
        XCTAssertTrue(scan.issues.contains {
            $0.source.identity.hasSuffix("\(slot.conversationID.uuidString).json")
        })
        XCTAssertTrue(scan.issues.contains { $0.source.identity.hasSuffix("linked.png") })
        XCTAssertTrue(scan.issues.contains { $0.source.identity.hasSuffix(symlinkSlotName) })
        XCTAssertFalse(scan.retainedSources.contains { $0.source.digest == digest(privateSidecarBytes) })
        XCTAssertFalse(scan.retainedSources.contains { $0.source.digest == digest(privateMediaBytes) })
    }

    func testMalformedAndUnknownSlotEntriesRemainVisibleAndQuarantined() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent("trash/conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: trash.appendingPathComponent("not-a-generated-slot"),
            withIntermediateDirectories: true)
        let slot = try makeSlot(root: root)
        _ = try writeSidecar(
            Data("sidecar".utf8), conversationID: slot.conversationID, slot: slot.url)
        try Data("unknown".utf8).write(to: slot.url.appendingPathComponent("future.receipt"))

        let scan = LibraryConversationTrashScanner.scan(supportRoot: root)
        XCTAssertEqual(scan.operations.count, 1)
        let operation = try XCTUnwrap(scan.operations.first)

        XCTAssertEqual(operation.operation.state, .quarantined)
        XCTAssertFalse(scan.hasCompleteCensus)
        XCTAssertFalse(scan.hasCompleteInventory)
        XCTAssertEqual(scan.retainedSources.count, 1)
        XCTAssertEqual(scan.issues.count, 2)
        XCTAssertTrue(scan.issues.contains { $0.diagnostics.contains("slot name") })
        XCTAssertTrue(scan.issues.contains { $0.diagnostics.contains("unknown entry") })
    }

    func testMissingSidecarKeepsOperationAndPhysicalSlotIssueIdentitiesDistinct() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeSlot(root: root)

        let scan = LibraryConversationTrashScanner.scan(supportRoot: root)
        let operation = try XCTUnwrap(scan.operations.first)
        let issue = try XCTUnwrap(scan.issues.first)

        XCTAssertEqual(operation.operation.state, .quarantined)
        XCTAssertEqual(operation.slotIdentity, issue.source.identity)
        XCTAssertNotEqual(operation.authoritySourceIdentity, issue.source.identity)
        XCTAssertTrue(operation.authoritySourceIdentity.hasPrefix("operation-intents/"))
        XCTAssertTrue(scan.hasCompleteCensus)
    }

    func testDerivedOperationIDCollisionPublishesNoAmbiguousOperationsOrEdges() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for bytes in ["one", "two"] {
            let slot = try makeSlot(root: root)
            _ = try writeSidecar(
                Data(bytes.utf8), conversationID: slot.conversationID, slot: slot.url)
        }
        let collisionID = UUID(uuidString: "AAAAAAAA-AAAA-5AAA-8AAA-AAAAAAAAAAAA")!

        let scan = LibraryConversationTrashScanner.scan(
            supportRoot: root,
            operationIDDeriver: { _ in collisionID })

        XCTAssertTrue(scan.operations.isEmpty)
        XCTAssertTrue(scan.retainedSourceEdges.isEmpty)
        XCTAssertEqual(scan.retainedSources.count, 2, "Physical bytes remain inventoried.")
        XCTAssertEqual(scan.issues.filter { $0.kind == .duplicate }.count, 2)
        XCTAssertFalse(scan.hasCompleteInventory)
    }

    func testVersionKindUnknownStateAndOversizedPayloadFailClosed() throws {
        let payload = LibraryConversationDeleteOperationPayload(
            conversationID: UUID(),
            trashSlotIdentity: "trash/conversations/slot",
            queuePauseState: .unknownSafePaused)
        let snapshot = try LibraryOperationSnapshot.conversationDelete(
            id: UUID(),
            state: .committed,
            idempotencyKey: "legacy-trash:slot",
            recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
            payload: payload)
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(LibraryOperationSnapshot.self, from: encoded), snapshot)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["state"] = "future_state"
        XCTAssertThrowsError(try JSONDecoder().decode(
            LibraryOperationSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)))

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["payloadVersion"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(
            LibraryOperationSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object))) { error in
                XCTAssertEqual(
                    error as? LibraryOperationAuthorityError,
                    .unsupportedPayloadVersion(kind: .conversationDelete, version: 2))
            }

        let tooManyMembers = Array(
            repeating: UUID(),
            count: LibraryWorkspaceMoveOperationPayload.maximumMemberCount + 1)
        XCTAssertThrowsError(try LibraryWorkspaceMoveOperationPayload(
            memberKind: .conversation,
            memberIDs: tooManyMembers,
            sourceWorkspaceID: UUID(),
            destinationWorkspaceID: UUID()))

        XCTAssertThrowsError(try LibraryOperationSnapshot.backgroundAdoption(
            id: UUID(),
            state: .prepared,
            idempotencyKey: "adopt",
            recordedAt: Date(),
            payload: LibraryBackgroundAdoptionOperationPayload(
                sourceIdentity: String(
                    repeating: "x", count: LibraryOperationSnapshot.maximumPayloadBytes + 1),
                sourceRevision: "1",
                sourceDigest: String(repeating: "a", count: 64),
                conversationID: nil))) { error in
                    guard case LibraryOperationAuthorityError.payloadTooLarge = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                }
    }

    func testReceiptRoundTripsAndRejectsUnknownState() throws {
        let details = try LibraryOperationReceiptDetails(
            diagnostics: "Recovered from a legacy trash slot.", retainedSourceCount: 3)
        let receipt = try LibraryOperationReceiptSnapshot(
            id: UUID(),
            operationID: UUID(),
            operationKind: .conversationDelete,
            state: .applied,
            attempt: 1,
            recordedAt: Date(timeIntervalSince1970: 1_800_000_001),
            details: details)
        let encoded = try JSONEncoder().encode(receipt)

        XCTAssertEqual(
            try JSONDecoder().decode(LibraryOperationReceiptSnapshot.self, from: encoded),
            receipt)
        XCTAssertEqual(try receipt.details(), details)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["state"] = "unknown"
        XCTAssertThrowsError(try JSONDecoder().decode(
            LibraryOperationReceiptSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try LibraryOperationReceiptDetails(
            diagnostics: String(
                repeating: "x",
                count: LibraryOperationReceiptDetails.maximumDiagnosticsBytes + 1),
            retainedSourceCount: 0))
    }

    func testMissingTrashRootIsACompleteEmptyInventory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = LibraryConversationTrashScanner.scan(supportRoot: root)

        XCTAssertTrue(scan.hasCompleteCensus)
        XCTAssertTrue(scan.hasCompleteInventory)
        XCTAssertTrue(scan.operations.isEmpty)
        XCTAssertTrue(scan.retainedSources.isEmpty)
        XCTAssertTrue(scan.issues.isEmpty)
    }
}
