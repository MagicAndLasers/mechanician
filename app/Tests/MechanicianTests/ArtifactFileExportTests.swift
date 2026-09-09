import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Mechanician

final class ArtifactFileExportTests: XCTestCase {
    func testFileExtensionMapsKnownTypesAndFallsBackToTxt() {
        XCTAssertEqual(ArtifactFileExport.fileExtension(for: "html"), "html")
        XCTAssertEqual(ArtifactFileExport.fileExtension(for: "SVG"), "svg")
        XCTAssertEqual(ArtifactFileExport.fileExtension(for: "mermaid"), "mmd")
        XCTAssertEqual(ArtifactFileExport.fileExtension(for: "csv"), "csv")
        XCTAssertEqual(ArtifactFileExport.fileExtension(for: "markdown"), "md")
        XCTAssertEqual(ArtifactFileExport.fileExtension(for: "md"), "md")
        XCTAssertEqual(ArtifactFileExport.fileExtension(for: "wat"), "txt")
    }

    func testFilenameIsFinderSafeAndCarriesTheTypeExtension() {
        XCTAssertEqual(
            ArtifactFileExport.filename(for: Artifact(
                title: " Sales / Q3: Draft ", type: "csv", source: "a,b")),
            "Sales Q3 Draft.csv")
        // A title made entirely of forbidden characters must not produce a dotfile or a bare ext.
        XCTAssertEqual(
            ArtifactFileExport.filename(for: Artifact(
                title: ":/\n\t", type: "html", source: "<b>hi</b>")),
            "Artifact.html")
    }

    func testTemporaryFileWritesTheSourceUnderTheTypedName() throws {
        let artifact = Artifact(title: "Launch Page", type: "html", source: "<h1>Launch</h1>")
        let url = try ArtifactFileExport.temporaryFile(for: artifact)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertEqual(url.lastPathComponent, "Launch Page.html")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "<h1>Launch</h1>")
    }

    func testSharedArtifactActionsMaterializeTheTypedExportFile() throws {
        let artifact = Artifact(title: "Release Notes", type: "markdown", source: "# Shipped")
        let url = try ArtifactActions.exportedFile(for: artifact)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertEqual(url.lastPathComponent, "Release Notes.md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Shipped")
    }

    /// A drag out of the app must arrive named the way the export is named. `NSItemProvider`
    /// appends the registered type's preferred extension to `suggestedName` when it writes the
    /// file, so a suggested name that already carries its extension lands as `Badge.svg.svg`.
    @MainActor
    func testDraggedArtifactArrivesWithASingleTypeExtension() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactDragNameTests-\(UUID().uuidString)", isDirectory: true)
        let store = ArtifactStore(
            appSupportBaseOverride: root.appendingPathComponent("support", isDirectory: true),
            watchesDirectory: false)
        defer {
            store.flushSaves()
            ArtifactActions.pruneTemporaryExports(root: root)
            try? FileManager.default.removeItem(at: root)
        }
        let artifact = store.upsertFromAgent(
            title: "Badge",
            type: "svg",
            source: "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"10\" height=\"10\"/></svg>",
            workspaceID: nil,
            conversationID: nil,
            conversationTitle: "",
            cwd: "")

        let provider = ArtifactActions.itemProvider(
            for: artifact,
            temporaryRoot: root,
            artifactStore: store)

        XCTAssertEqual(
            provider.suggestedName,
            "Badge",
            "suggestedName must omit the extension; the type identifier already supplies it.")

        let expectation = expectation(description: "file representation")
        var deliveredName: String?
        var loadError: Error?
        provider.loadFileRepresentation(
            forTypeIdentifier: UTType.svg.identifier
        ) { url, error in
            deliveredName = url?.lastPathComponent
            loadError = error
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)

        XCTAssertNil(loadError)
        XCTAssertEqual(
            deliveredName,
            "Badge.svg",
            "A dropped artifact must not arrive as Badge.svg.svg.")
    }

    @MainActor
    func testTemporaryExportPruningRemovesDiskAndIdentityMapEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ArtifactExportCleanupTests-\(UUID().uuidString)",
                isDirectory: true)
        let store = ArtifactStore(
            appSupportBaseOverride: root.appendingPathComponent("support"),
            watchesDirectory: false)
        defer {
            store.flushSaves()
            ArtifactActions.pruneTemporaryExports(root: root)
        }
        let artifact = store.upsertFromAgent(
            title: "Drag me",
            type: "markdown",
            source: "# Durable",
            workspaceID: nil,
            conversationID: nil,
            conversationTitle: "",
            cwd: "")

        _ = ArtifactActions.itemProvider(
            for: artifact,
            temporaryRoot: root,
            artifactStore: store)
        let url = try ArtifactActions.exportedFile(for: artifact, temporaryRoot: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(ArtifactActions.reference(forExportedURL: url)?.artifactID, artifact.uuid)

        // `upsertFromAgent` persists on ArtifactStore's serial queue. Drain it before removing the
        // shared temporary root, or that pending write can recreate `root/support` after the prune
        // and make this cleanup assertion depend on queue timing.
        store.flushSaves()
        ArtifactActions.pruneTemporaryExports(root: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertNil(ArtifactActions.reference(forExportedURL: url))
    }

    @MainActor
    func testLiveTemporaryExportIdentityMapIsBounded() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ArtifactExportBoundTests-\(UUID().uuidString)",
                isDirectory: true)
        let store = ArtifactStore(
            appSupportBaseOverride: root.appendingPathComponent("support"),
            watchesDirectory: false)
        defer {
            store.flushSaves()
            ArtifactActions.pruneTemporaryExports(root: root)
        }

        for index in 0...ArtifactActions.maximumLiveExportReferences {
            let artifact = store.upsertFromAgent(
                title: "Artifact \(index)",
                type: "markdown",
                source: "# \(index)",
                workspaceID: nil,
                conversationID: nil,
                conversationTitle: "",
                cwd: "")
            _ = ArtifactActions.itemProvider(
                for: artifact,
                temporaryRoot: root,
                artifactStore: store)
        }

        XCTAssertLessThanOrEqual(
            ArtifactActions.liveExportReferenceCount,
            ArtifactActions.maximumLiveExportReferences)
    }

    func testEvictingAnOldRenamedExportPreservesTheNewSiblingAndMapping() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ArtifactExportRenameEvictionTests-\(UUID().uuidString)",
                isDirectory: true)
        defer { ArtifactFileExport.removeTemporaryExports(root: root) }
        let artifactID = UUID()
        let oldArtifact = Artifact(
            title: "Old name",
            type: "markdown",
            source: "# Old",
            uuid: artifactID)
        let newArtifact = Artifact(
            title: "New name",
            type: "markdown",
            source: "# New",
            uuid: artifactID)
        let oldURL = try ArtifactFileExport.temporaryFile(for: oldArtifact, root: root)
        let newURL = try ArtifactFileExport.temporaryFile(for: newArtifact, root: root)
        var index = ArtifactLiveExportIndex(maximumCount: 1)

        XCTAssertTrue(index.remember(
            ArtifactDragReference(artifact: oldArtifact, sourceURL: oldURL),
            at: oldURL).isEmpty)
        let evicted = index.remember(
            ArtifactDragReference(artifact: newArtifact, sourceURL: newURL),
            at: newURL)

        XCTAssertEqual(evicted, [oldURL])
        evicted.forEach { ArtifactFileExport.removeTemporaryExport(at: $0) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertEqual(try String(contentsOf: newURL, encoding: .utf8), "# New")
        XCTAssertEqual(index.reference(for: newURL)?.title, "New name")
    }

    // FR-102: drag-and-drop IN. The extension→type map must accept what we render and reject the rest,
    // and round-trip cleanly against its export inverse for the core types.
    func testArtifactTypeMapsDroppedExtensionsAndRejectsUnknown() {
        XCTAssertEqual(ArtifactFileExport.artifactType(forFileExtension: "html"), "html")
        XCTAssertEqual(ArtifactFileExport.artifactType(forFileExtension: "HTM"), "html")
        XCTAssertEqual(ArtifactFileExport.artifactType(forFileExtension: "svg"), "svg")
        XCTAssertEqual(ArtifactFileExport.artifactType(forFileExtension: "mmd"), "mermaid")
        XCTAssertEqual(ArtifactFileExport.artifactType(forFileExtension: "csv"), "csv")
        XCTAssertEqual(ArtifactFileExport.artifactType(forFileExtension: "md"), "markdown")
        XCTAssertEqual(ArtifactFileExport.artifactType(forFileExtension: "txt"), "markdown")
        XCTAssertNil(ArtifactFileExport.artifactType(forFileExtension: "png"))
        XCTAssertNil(ArtifactFileExport.artifactType(forFileExtension: ""))
        for type in ["html", "svg", "mermaid", "csv", "markdown"] {
            XCTAssertEqual(
                ArtifactFileExport.artifactType(forFileExtension: ArtifactFileExport.fileExtension(for: type)),
                type, "\(type) must survive an export→import round trip")
        }
    }

    // FR-102: importing dropped files reads supported text files and skips unsupported extensions and
    // non-UTF-8 (binary) content, reporting the skipped names so the user isn't left guessing.
    func testImportsReadsSupportedTextFilesAndSkipsTheRest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let md = dir.appendingPathComponent("Release Notes.md")
        try "# Notes\nShip it.".write(to: md, atomically: true, encoding: .utf8)
        let png = dir.appendingPathComponent("logo.png")          // unsupported extension
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: png)
        let badCsv = dir.appendingPathComponent("garbled.csv")    // supported ext, non-UTF-8 content
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: badCsv)

        let (ready, skipped) = ArtifactActions.imports(from: [md, png, badCsv])
        XCTAssertEqual(ready, [ArtifactActions.Import(title: "Release Notes", type: "markdown",
                                                      source: "# Notes\nShip it.")])
        XCTAssertEqual(Set(skipped), Set(["logo.png", "garbled.csv"]))
    }
}
