import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Mechanician

/// The artifact drag had two ends that were each tested and a bridge between them that was not.
///
/// `ArtifactsPanelView` / `GlobalArtifactsView` hand SwiftUI's `.onDrag` an `NSItemProvider` that
/// advertises `ai.mechanician.artifact-reference` beside the public file URL. Source tests inspect
/// that provider in-process; destination tests build an eagerly-populated `NSPasteboardItem`.
/// Neither noticed that the identifier was never *declared* by the bundle — so
/// `UTType("ai.mechanician.artifact-reference")` was nil, SwiftUI's `onDrop(of:)` had nothing to
/// resolve, and the Files-tab spring load could never fire.
///
/// AppKit destinations were unaffected, because `registerForDraggedTypes` and
/// `NSPasteboard.data(forType:)` match the raw string and never consult UTType. That asymmetry is
/// exactly why the bug survived: the composer accepted artifact drags while the tab silently did not.
@MainActor
final class ArtifactDragBridgeTests: XCTestCase {
    private var infoPlistURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MechanicianTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .appendingPathComponent("Mechanician-Info.plist")
    }

    /// The declaration is what makes the identifier resolvable at runtime. This asserts the plist
    /// rather than calling `UTType(_:)`, because the test bundle is not the app bundle: resolution
    /// depends on Launch Services reading `Contents/Info.plist`, which only exists in a built app.
    func testPrivateArtifactTypeIsDeclaredByTheBundle() throws {
        let data = try Data(contentsOf: infoPlistURL)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil) as? [String: Any])

        let exported = try XCTUnwrap(
            plist["UTExportedTypeDeclarations"] as? [[String: Any]],
            "The app writes a custom pasteboard type, so it must export a declaration for it.")
        let identifiers = exported.compactMap { $0["UTTypeIdentifier"] as? String }

        XCTAssertTrue(
            identifiers.contains(ArtifactActions.referencePasteboardType.rawValue),
            """
            "\(ArtifactActions.referencePasteboardType.rawValue)" must be declared in \
            UTExportedTypeDeclarations. Without it UTType cannot resolve the identifier, so every \
            SwiftUI `onDrop(of:)` target watching it — the Files-tab spring load — silently never \
            fires. Declared: \(identifiers)
            """)

        let declaration = try XCTUnwrap(
            exported.first {
                $0["UTTypeIdentifier"] as? String
                    == ArtifactActions.referencePasteboardType.rawValue
            })
        XCTAssertEqual(
            declaration["UTTypeConformsTo"] as? [String],
            ["public.data"],
            "An opaque app-private payload conforms to public.data, not to a file or text type.")
    }

    /// The source end, kept honest alongside the declaration: a drag must still carry both the
    /// public file (for other apps) and artifact identity (for drops inside Mechanician).
    func testArtifactDragCarriesBothPublicFileAndPrivateIdentity() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactDragBridgeTests-\(UUID().uuidString)", isDirectory: true)
        let exports = base.appendingPathComponent("exports", isDirectory: true)
        let store = ArtifactStore(
            appSupportBaseOverride: base.appendingPathComponent("support", isDirectory: true),
            watchesDirectory: false)
        defer {
            store.flushSaves()
            ArtifactActions.pruneTemporaryExports(root: exports)
            try? FileManager.default.removeItem(at: base)
        }
        let artifact = store.upsertFromAgent(
            title: "Status Dashboard",
            type: "html",
            source: "<main>Status</main>",
            workspaceID: nil,
            conversationID: nil,
            conversationTitle: "",
            cwd: "")

        let provider = ArtifactActions.itemProvider(
            for: artifact,
            temporaryRoot: exports,
            artifactStore: store)

        XCTAssertTrue(provider.registeredTypeIdentifiers.contains("public.file-url"))
        XCTAssertTrue(provider.registeredTypeIdentifiers.contains(
            ArtifactActions.referencePasteboardType.rawValue))

        // The identity payload must actually load, not merely be advertised.
        let loaded = expectation(description: "private representation")
        var recovered: ArtifactDragReference?
        provider.loadDataRepresentation(
            forTypeIdentifier: ArtifactActions.referencePasteboardType.rawValue
        ) { data, _ in
            recovered = data.flatMap { ArtifactDragReference.decodeProcessPrivate($0) }
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 10)
        XCTAssertEqual(recovered?.artifactID, artifact.uuid)
    }
}
