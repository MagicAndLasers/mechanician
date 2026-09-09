import AppKit
import Foundation
import PDFKit
import WebKit
import XCTest
@testable import Mechanician

@MainActor
final class ArtifactPDFExportTests: XCTestCase {
    private final class RecordingRenderer: ArtifactHTMLPDFRendering {
        var documents: [String] = []
        var result = makeTestPDFData()

        func renderPDF(document: String) async throws -> Data {
            documents.append(document)
            return result
        }
    }

    private final class SuspendingRenderer: ArtifactHTMLPDFRendering {
        var didStart = false
        var wasCancelled = false

        func renderPDF(document: String) async throws -> Data {
            didStart = true
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return makeTestPDFData()
            } catch {
                wasCancelled = error is CancellationError
                throw error
            }
        }
    }

    func testHTMLExportRendersTheSafePreviewDocument() async throws {
        let artifact = Artifact(
            title: "Launch",
            type: "HTML",
            source: "<script>fetch('https://example.com')</script><h1>Launch</h1>")
        let renderer = RecordingRenderer()

        let data = try await ArtifactPDFExport.pdfData(for: artifact, renderer: renderer)

        XCTAssertEqual(data, renderer.result)
        // The PAPER document, not the screen one. An export is a document rather than a panel, and
        // asserting the paper variant here is what stops the export quietly going back to following
        // the app's appearance (FR-177).
        XCTAssertEqual(renderer.documents,
                       [SafeHTMLPreview.artifactDocument(for: artifact, medium: .paper)])
        XCTAssertFalse(renderer.documents[0].contains("light dark"),
                       "the export rendered a document that follows the app appearance")
        XCTAssertTrue(renderer.documents[0].contains("default-src 'none'"))
        XCTAssertTrue(renderer.documents[0].contains("script-src 'none'"))
    }

    func testNonHTMLTypesAreRejectedBeforeRendering() async {
        let renderer = RecordingRenderer()
        let artifact = Artifact(title: "Diagram", type: "svg", source: "<svg/>")

        do {
            _ = try await ArtifactPDFExport.pdfData(for: artifact, renderer: renderer)
            XCTFail("Expected a non-HTML artifact to be rejected")
        } catch {
            XCTAssertEqual(
                error as? ArtifactPDFExportError,
                .unsupportedArtifactType("svg"))
        }
        XCTAssertTrue(renderer.documents.isEmpty)
    }

    func testRendererMustReturnPDFData() async {
        let renderer = RecordingRenderer()
        renderer.result = Data("not a PDF".utf8)

        do {
            _ = try await ArtifactPDFExport.pdfData(
                for: Artifact(title: "Page", type: "html", source: "<p>Page</p>"),
                renderer: renderer)
            XCTFail("Expected invalid PDF bytes to be rejected")
        } catch {
            XCTAssertEqual(error as? ArtifactPDFExportError, .invalidPDFData)
        }
    }

    func testPDFHeaderWithoutAnyPagesIsRejected() async {
        let renderer = RecordingRenderer()
        renderer.result = Data("%PDF-1.7\n%%EOF".utf8)

        do {
            _ = try await ArtifactPDFExport.pdfData(
                for: Artifact(title: "Page", type: "html", source: "<p>Page</p>"),
                renderer: renderer)
            XCTFail("Expected a header-only PDF to be rejected")
        } catch {
            XCTAssertEqual(error as? ArtifactPDFExportError, .invalidPDFData)
        }
    }

    func testOversizedSourceIsRejectedBeforeRendering() async {
        let renderer = RecordingRenderer()
        let source = String(
            repeating: "x",
            count: ArtifactPDFExport.maximumSourceByteCount + 1)

        do {
            _ = try await ArtifactPDFExport.pdfData(
                for: Artifact(title: "Huge", type: "html", source: source),
                renderer: renderer)
            XCTFail("Expected oversized source to be rejected")
        } catch {
            XCTAssertEqual(error as? ArtifactPDFExportError, .sourceTooLarge)
        }
        XCTAssertTrue(renderer.documents.isEmpty)
    }

    func testSuspendingRendererTimesOutAndIsCancelled() async {
        let renderer = SuspendingRenderer()

        do {
            _ = try await ArtifactPDFExport.pdfData(
                for: Artifact(title: "Stalled", type: "html", source: "<p>Stalled</p>"),
                renderer: renderer,
                renderTimeout: 0.01)
            XCTFail("Expected a stalled renderer to time out")
        } catch {
            XCTAssertEqual(error as? ArtifactPDFExportError, .renderTimedOut)
        }
        XCTAssertTrue(renderer.didStart)
        XCTAssertTrue(renderer.wasCancelled)
    }

    func testCancellingExportCancelsSuspendingRenderer() async {
        let renderer = SuspendingRenderer()
        let task = Task { @MainActor in
            try await ArtifactPDFExport.pdfData(
                for: Artifact(
                    title: "Cancelled",
                    type: "html",
                    source: "<p>Cancelled</p>"),
                renderer: renderer,
                renderTimeout: 10)
        }
        while !renderer.didStart {
            await Task.yield()
        }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(renderer.wasCancelled)
    }

    func testWriteSavesRenderedBytesAtomically() async throws {
        let renderer = RecordingRenderer()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactPDFExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Launch.pdf")

        try await ArtifactPDFExport.write(
            Artifact(title: "Launch", type: "html", source: "<h1>Launch</h1>"),
            to: url,
            renderer: renderer)

        XCTAssertEqual(try Data(contentsOf: url), renderer.result)
    }

    func testFilenameUsesFinderSafeArtifactTitle() {
        XCTAssertEqual(
            ArtifactPDFExport.filename(for: Artifact(
                title: " Sales / Q3: Draft ", type: "html", source: "")),
            "Sales Q3 Draft.pdf")
        XCTAssertEqual(
            ArtifactPDFExport.filename(for: Artifact(
                title: "Launch.pdf", type: "html", source: "")),
            "Launch.pdf")
    }

    func testProductionRendererCreatesAPDFOfTheLoadedHTML() async throws {
        let data = try await ArtifactPDFExport.pdfData(for: Artifact(
            title: "Rendered page",
            type: "html",
            source: "<h1>Rendered after navigation finished</h1>"))

        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue(document.string?.contains("Rendered after navigation finished") == true)
    }

    func testProductionRendererDoesNotClipContentBelowTheInitialViewport() async throws {
        let spacer = Array(
            repeating: "<p>Long report content with enough height to require scrolling.</p>",
            count: 80)
            .joined()
        let marker = "END-OF-LONG-ARTIFACT"
        let data = try await ArtifactPDFExport.pdfData(for: Artifact(
            title: "Long report",
            type: "html",
            source: spacer + "<h2>\(marker)</h2>"))

        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue(
            document.string?.contains(marker) == true,
            "Save as PDF must include content below the preview viewport.")
    }

    func testProductionRendererUsesANonpersistentDataStore() {
        XCTAssertFalse(SafeHTMLPreview.makeConfiguration().websiteDataStore.isPersistent)
    }
}

@MainActor
private func makeTestPDFData() -> Data {
    let image = NSImage(size: NSSize(width: 72, height: 72))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: image.size).fill()
    image.unlockFocus()

    let document = PDFDocument()
    document.insert(PDFPage(image: image)!, at: 0)
    return document.dataRepresentation()!
}
