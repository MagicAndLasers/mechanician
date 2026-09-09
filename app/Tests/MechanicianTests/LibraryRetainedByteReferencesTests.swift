import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Mechanician

final class LibraryRetainedByteReferencesTests: XCTestCase {
    func testExtractionCoversEveryDurableOwnerAndDeduplicatesEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let transcriptFile = fixture.fileReference(name: fixture.names[0], bytes: 11)
        let transcriptImage = fixture.ownedPath(name: fixture.names[1])
        let toolImageName = fixture.names[2]
        let draftFile = fixture.fileReference(name: fixture.names[3], bytes: 13)
        let draftImage = fixture.ownedPath(name: fixture.names[4])
        let queueFile = fixture.fileReference(name: fixture.names[5], bytes: 15)
        let pendingFile = fixture.fileReference(name: fixture.names[6], bytes: 16)
        let accessFile = fixture.fileReference(name: fixture.names[7], bytes: 17)
        let external = fixture.root.appendingPathComponent("external.png")
        try Data("external".utf8).write(to: external)

        var entry = TranscriptEntry(
            kind: .user,
            text: transcriptFile.promptToken + "\n" + transcriptImage + "\n" + external.path)
        entry.id = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        // `imagePaths` is a derived presentation copy of the same text edge. It must enrich one
        // candidate's evidence, not manufacture a second retained-byte edge.
        entry.imagePaths = [transcriptImage, external.path]
        entry.toolImage = ToolImageReference(fileName: toolImageName, width: 10, height: 20)
        let access = ProviderAccessRequest(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            maker: .openAI,
            reason: "resume",
            resumePrompts: [accessFile.promptToken])
        var conversation = Conversation(
            id: fixture.conversationID,
            title: "References",
            cwd: "",
            sdkSessionId: nil,
            messages: [entry],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            queuedPrompts: [queueFile.promptToken],
            draft: draftFile.promptToken + "\n" + draftImage,
            providerAccessRequest: access)
        conversation.pendingTurnPrompt = pendingFile.promptToken

        let extracted = LibraryRetainedByteReferenceExtractor.extract(
            from: conversation,
            supportRoot: fixture.root)
        XCTAssertEqual(extracted.managedReferences.count, 8)
        XCTAssertEqual(extracted.externalAbsolutePaths.count, 1)
        XCTAssertTrue(extracted.invalidManagedReferences.isEmpty)
        XCTAssertEqual(
            extracted,
            LibraryRetainedByteReferenceExtractor.extract(
                from: conversation,
                supportRoot: fixture.root),
            "extraction and ordering must be deterministic")

        let transcriptOwner = LibraryRetainedByteReferenceCandidate.Owner.event(
            entryID: entry.id,
            messageIndex: 0)
        let image = try XCTUnwrap(extracted.managedReferences.first {
            $0.storageName == fixture.names[1] && $0.owner == transcriptOwner
        })
        XCTAssertEqual(image.evidence, [.imagePathInText, .imagePathsField])
        XCTAssertEqual(image.expectedMediaTypes, [UTType.png.identifier])
        XCTAssertEqual(
            extracted.managedReferences.first { $0.storageName == toolImageName }?.evidence,
            [.toolImage])
        XCTAssertEqual(
            extracted.managedReferences.first { $0.storageName == fixture.names[3] }?.owner,
            .localState(.draft))
        XCTAssertEqual(
            extracted.managedReferences.first { $0.storageName == fixture.names[5] }?.owner,
            .localState(.queuedPrompt(index: 0)))
        XCTAssertEqual(
            extracted.managedReferences.first { $0.storageName == fixture.names[6] }?.owner,
            .localState(.pendingTurnPrompt))
        XCTAssertEqual(
            extracted.managedReferences.first { $0.storageName == fixture.names[7] }?.owner,
            .localState(.providerAccessResumePrompt(requestID: access.id, index: 0)))
        XCTAssertEqual(extracted.externalAbsolutePaths[0].path, external.standardizedFileURL.path)
        XCTAssertEqual(
            extracted.externalAbsolutePaths[0].evidence,
            [.imagePathInText, .imagePathsField])
    }

    func testResolutionKeysByIdentityNotDigestAndReportsMissingAndUnreferenced() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let referencedName = fixture.names[0]
        let missingName = fixture.names[1]
        let sameDigestOtherName = fixture.names[2]
        let referenced = fixture.fileReference(name: referencedName, bytes: 4)
        let missing = fixture.fileReference(name: missingName, bytes: 7)
        // Repeating a token in one owner remains one edge.
        let conversation = Conversation(
            id: fixture.conversationID,
            title: "Resolution",
            cwd: "",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_001),
            draft: referenced.promptToken + referenced.promptToken + missing.promptToken)
        let extraction = LibraryRetainedByteReferenceExtractor.extract(
            from: conversation,
            supportRoot: fixture.root)
        XCTAssertEqual(extraction.managedReferences.count, 2)

        let digest = String(repeating: "a", count: 64)
        let observed = [
            fixture.observed(name: referencedName, digest: digest, bytes: 4),
            fixture.observed(name: sameDigestOtherName, digest: digest, bytes: 4),
        ]
        let resolution = LibraryRetainedByteReferenceExtractor.resolve(
            extraction,
            against: observed)
        XCTAssertEqual(resolution.matched.map(\.source.sourceIdentity), [
            fixture.sourceIdentity(name: referencedName),
        ])
        XCTAssertEqual(resolution.missing.map(\.storageName), [missingName])
        XCTAssertTrue(resolution.mismatched.isEmpty)
        XCTAssertEqual(resolution.unreferenced.map(\.sourceIdentity), [
            fixture.sourceIdentity(name: sameDigestOtherName),
        ], "equal digests never collapse two storage identities")
    }

    func testResolutionRejectsConflictingExpectationsAndExternalPathsNeverBecomeManaged() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let name = fixture.names[0]
        let first = fixture.fileReference(name: name, bytes: 4)
        let second = fixture.fileReference(name: name, bytes: 5)
        let external = fixture.root.appendingPathComponent("outside.jpg")
        let otherConversation = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        let crossOwner = fixture.root
            .appendingPathComponent("conversation-media", isDirectory: true)
            .appendingPathComponent(otherConversation.uuidString, isDirectory: true)
            .appendingPathComponent(fixture.names[1])
        var entry = TranscriptEntry(kind: .user, text: first.promptToken + second.promptToken)
        entry.imagePaths = [external.path, crossOwner.path]
        let conversation = Conversation(
            id: fixture.conversationID,
            title: "Conflicts",
            cwd: "",
            sdkSessionId: nil,
            messages: [entry],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_002))
        let extraction = LibraryRetainedByteReferenceExtractor.extract(
            from: conversation,
            supportRoot: fixture.root)

        XCTAssertEqual(extraction.managedReferences.count, 1)
        XCTAssertEqual(extraction.managedReferences[0].expectedByteCounts, [4, 5])
        XCTAssertEqual(extraction.externalAbsolutePaths.map(\.path), [
            external.standardizedFileURL.path,
        ])
        XCTAssertEqual(extraction.invalidManagedReferences.count, 1)
        XCTAssertEqual(
            extraction.invalidManagedReferences[0].reason,
            .invalidOrCrossOwnerMediaPath)

        let resolution = LibraryRetainedByteReferenceExtractor.resolve(
            extraction,
            against: [fixture.observed(name: name, digest: "digest", bytes: 4)])
        XCTAssertTrue(resolution.matched.isEmpty)
        XCTAssertEqual(resolution.mismatched.count, 1)
        XCTAssertEqual(
            resolution.mismatched[0].reasons,
            [.byteCount(expected: [4, 5], actual: 4)])
    }

    func testPermissionAdoptionTightensOnlyDescriptorVerifiedManagedPath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)
        let media = fixture.root.appendingPathComponent("conversation-media", isDirectory: true)
        let owner = media.appendingPathComponent(
            fixture.conversationID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: media.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: owner.path)
        let retained = owner.appendingPathComponent(fixture.names[0])
        try Data("private bytes".utf8).write(to: retained)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: retained.path)

        let fingerprint = try XCTUnwrap(
            ArtifactMediaSourceScanner.scan(supportRoot: fixture.root)
                .retainedBytes.first?.source)
        let adopted = try LibraryRetainedBytePermissionAdopter.adopt(
            source: fingerprint,
            supportRoot: fixture.root)

        XCTAssertEqual(try permissions(media), 0o700)
        XCTAssertEqual(try permissions(owner), 0o700)
        XCTAssertEqual(try permissions(retained), 0o600)
        XCTAssertEqual(adopted.digest, fingerprint.digest)
        XCTAssertEqual(adopted.byteCount, fingerprint.byteCount)
        XCTAssertEqual(
            try LibraryRetainedBytePermissionAdopter.adopt(
                source: adopted,
                supportRoot: fixture.root),
            adopted,
            "already-protected unchanged bytes must not receive another permission mutation")
        let recovery = try LibraryRetainedBytePermissionAdopter.protectUnclaimedRecovery(
            source: adopted,
            supportRoot: fixture.root)
        XCTAssertEqual(try permissions(retained), 0o400)
        XCTAssertEqual(recovery.digest, adopted.digest)
        XCTAssertEqual(
            try LibraryRetainedBytePermissionAdopter.protectUnclaimedRecovery(
                source: recovery,
                supportRoot: fixture.root),
            recovery,
            "an unchanged recovery source must remain owner-read-only without ctime churn")
        _ = try LibraryRetainedBytePermissionAdopter.adopt(
            source: recovery,
            supportRoot: fixture.root)
        XCTAssertEqual(
            try permissions(retained),
            0o600,
            "a later durable reference may explicitly transition recovery bytes back to live use")
        XCTAssertThrowsError(try LibraryRetainedBytePermissionAdopter.adopt(
            source: ShadowLibrarySourceFingerprint(
                identity: "conversation-media/../outside.png",
                revision: adopted.revision,
                digest: adopted.digest,
                byteCount: adopted.byteCount),
            supportRoot: fixture.root))
    }

    func testPermissionAdoptionRejectsStaleContentAndPathReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)
        let media = fixture.root.appendingPathComponent("conversation-media", isDirectory: true)
        let owner = media.appendingPathComponent(
            fixture.conversationID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: media.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: owner.path)
        let retained = owner.appendingPathComponent(fixture.names[0])
        try Data("private bytes".utf8).write(to: retained)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: retained.path)
        let fingerprint = try XCTUnwrap(
            ArtifactMediaSourceScanner.scan(supportRoot: fixture.root)
                .retainedBytes.first?.source)

        let wrongDigest = ShadowLibrarySourceFingerprint(
            identity: fingerprint.identity,
            revision: fingerprint.revision,
            digest: String(repeating: "0", count: 64),
            byteCount: fingerprint.byteCount)
        XCTAssertThrowsError(try LibraryRetainedBytePermissionAdopter.adopt(
            source: wrongDigest,
            supportRoot: fixture.root))
        let wrongByteCount = ShadowLibrarySourceFingerprint(
            identity: fingerprint.identity,
            revision: fingerprint.revision,
            digest: fingerprint.digest,
            byteCount: fingerprint.byteCount + 1)
        XCTAssertThrowsError(try LibraryRetainedBytePermissionAdopter.adopt(
            source: wrongByteCount,
            supportRoot: fixture.root))
        XCTAssertEqual(try permissions(media), 0o755)
        XCTAssertEqual(try permissions(owner), 0o755)
        XCTAssertEqual(try permissions(retained), 0o644)

        let displaced = owner.appendingPathComponent("displaced")
        XCTAssertThrowsError(try LibraryRetainedBytePermissionAdopter.adopt(
            source: fingerprint,
            supportRoot: fixture.root,
            beforeFinalIdentityValidation: {
                try FileManager.default.moveItem(at: retained, to: displaced)
                try Data("private bytes".utf8).write(to: retained)
            })) { error in
                guard case LibraryRetainedBytePermissionError.verification = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        XCTAssertEqual(
            try permissions(retained),
            0o644,
            "a replacement path must never be reported or persisted as adopted")
    }

    private func permissions(_ url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        return try XCTUnwrap(value as? NSNumber).intValue
    }

    private struct Fixture {
        let root: URL
        let conversationID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let names = (10...17).map {
            String(format: "00000000-0000-0000-0000-0000000000%02d.png", $0)
        }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "mechanician-reference-tests-\(UUID().uuidString)",
                isDirectory: true)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func ownedPath(name: String) -> String {
            root.appendingPathComponent("conversation-media", isDirectory: true)
                .appendingPathComponent(conversationID.uuidString, isDirectory: true)
                .appendingPathComponent(name)
                .path
        }

        func fileReference(name: String, bytes: Int) -> ConversationFileReference {
            ConversationFileReference(
                storageName: name,
                displayName: "attachment.png",
                typeIdentifier: UTType.png.identifier,
                byteCount: bytes)
        }

        func sourceIdentity(name: String) -> String {
            "conversation-media/\(conversationID.uuidString)/\(name)"
        }

        func observed(
            name: String,
            digest: String,
            bytes: Int
        ) -> LibraryRetainedByteObservedSource {
            LibraryRetainedByteObservedSource(
                sourceIdentity: sourceIdentity(name: name),
                digest: digest,
                byteCount: bytes,
                mediaType: UTType.png.identifier)
        }
    }
}
