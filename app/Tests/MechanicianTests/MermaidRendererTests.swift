import XCTest
import WebKit
@testable import Mechanician

/// FR-334. Mermaid artifacts used to show escaped source, because the preview is script-free by
/// construction and Mermaid is a JavaScript renderer. These cover the way out of that: render once
/// offscreen, freeze the result to SVG, and display markup rather than a program.
///
/// The suite is in two halves. The policy half runs against a fake renderer, so size limits,
/// timeouts, caching and output validation are testable without a web content process. The WebKit
/// half drives the real renderer with the real vendored Mermaid, because the security claims here
/// are about what Mermaid actually emits — a fake renderer cannot tell us whether `click ... href`
/// still puts a live external link in the output.
@MainActor
final class MermaidRendererTests: XCTestCase {

    // MARK: - Fakes

    private final class StubRenderer: MermaidSVGRendering {
        var svg: String
        var receivedSources: [String] = []
        var receivedThemes: [String] = []
        init(svg: String = "<svg xmlns=\"http://www.w3.org/2000/svg\"><g></g></svg>") {
            self.svg = svg
        }
        func renderSVG(source: String, theme: String) async throws -> String {
            receivedSources.append(source)
            receivedThemes.append(theme)
            return svg
        }
    }

    private final class SuspendingRenderer: MermaidSVGRendering {
        var didStart = false
        func renderSVG(source: String, theme: String) async throws -> String {
            didStart = true
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return "<svg></svg>"
        }
    }

    override func setUp() {
        super.setUp()
        MermaidRenderer.resetCacheForTesting()
    }

    override func tearDown() {
        MermaidRenderer.resetCacheForTesting()
        super.tearDown()
    }

    /// The vendored renderer lives beside the sources, not in the test bundle.
    private func vendoredMermaidJS() throws -> String {
        let resources = URL(fileURLWithPath: #filePath)      // …/app/Tests/MechanicianTests/x.swift
            .deletingLastPathComponent()                      // …/app/Tests/MechanicianTests
            .deletingLastPathComponent()                      // …/app/Tests
            .deletingLastPathComponent()                      // …/app
            .appendingPathComponent("Resources/mermaid.min.js")
        return try String(contentsOf: resources, encoding: .utf8)
    }

    // MARK: - Policy

    func testEmptyAndWhitespaceOnlySourceIsRefusedBeforeRendering() async {
        let renderer = StubRenderer()
        for source in ["", "   ", "\n\t "] {
            do {
                _ = try await MermaidRenderer.renderSVG(
                    source: source, theme: .light, renderer: renderer)
                XCTFail("empty source should not reach the renderer")
            } catch {
                XCTAssertEqual(error as? MermaidRenderError, .emptySource)
            }
        }
        XCTAssertTrue(renderer.receivedSources.isEmpty)
    }

    func testOversizedSourceIsRefusedBeforeRendering() async {
        let renderer = StubRenderer()
        let source = String(repeating: "A", count: MermaidRenderer.maximumSourceByteCount + 1)
        do {
            _ = try await MermaidRenderer.renderSVG(
                source: source, theme: .light, renderer: renderer)
            XCTFail("oversized source should not reach the renderer")
        } catch {
            XCTAssertEqual(error as? MermaidRenderError, .sourceTooLarge)
        }
        XCTAssertTrue(renderer.receivedSources.isEmpty)
    }

    func testRenderTimesOutRatherThanHangingThePreview() async {
        let renderer = SuspendingRenderer()
        do {
            _ = try await MermaidRenderer.renderSVG(
                source: "flowchart TD\n A --> B",
                theme: .light,
                renderer: renderer,
                renderTimeout: 0.05)
            XCTFail("a renderer that never returns should time out")
        } catch {
            XCTAssertEqual(error as? MermaidRenderError, .renderTimedOut)
        }
        XCTAssertTrue(renderer.didStart)
    }

    func testThemeReachesTheRendererSoDarkModeIsNotRenderedLight() async throws {
        let renderer = StubRenderer()
        _ = try await MermaidRenderer.renderSVG(source: "flowchart TD\n A --> B",
                                                theme: .dark, renderer: renderer)
        XCTAssertEqual(renderer.receivedThemes, ["dark"])
        XCTAssertEqual(MermaidRenderer.Theme.light.rawValue, "default")
    }

    // MARK: - Output validation (the independent check on the DOM scrub)

    func testValidateAcceptsOrdinaryMermaidOutput() {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><style>#a{fill:#333;}</style>\
        <g><path d="M0 0L1 1" marker-end="url(#arrow)"></path><text>A --> B</text></g></svg>
        """
        XCTAssertNoThrow(try MermaidRenderer.validate(svg))
    }

    func testValidateRejectsExecutableOrExternalOutput() {
        let hostile: [String] = [
            "<svg><script>alert(1)</script></svg>",
            "<svg><a href=\"https://evil.example/x\"><rect/></a></svg>",
            "<svg><a xlink:href=\"http://evil.example/x\"><rect/></a></svg>",
            "<svg><rect onload=\"alert(1)\"/></svg>",
            "<svg><rect onerror=\"alert(1)\"/></svg>",
            "<svg><foreignObject><div>x</div></foreignObject></svg>",
            "<svg><style>@import url(https://evil.example/x.css)</style></svg>",
            "<svg><iframe src=\"about:blank\"></iframe></svg>",
            "<svg><a href=\"javascript:alert(1)\"><rect/></a></svg>",
        ]
        for svg in hostile {
            XCTAssertThrowsError(try MermaidRenderer.validate(svg), "should reject: \(svg)") { error in
                guard case .unsafeOutput = (error as? MermaidRenderError) else {
                    return XCTFail("expected .unsafeOutput for \(svg), got \(error)")
                }
            }
        }
    }

    /// The validator is a blunt substring check running behind a structural sanitizer, so its
    /// failure mode is refusing a diagram that was fine. A label like `x one=2` reads as an inline
    /// event handler to a loose rule, and the person just sees their diagram replaced by source.
    func testValidateAcceptsLabelsThatMerelyLookLikeAttributes() {
        let innocent = [
            "<svg><text>x one=2</text></svg>",
            "<svg><text>set one = 2</text></svg>",
            "<svg><text>only=this</text></svg>",
            "<svg><g transform=\"translate(1,2)\"><rect stroke-width=\"2\"/></g></svg>",
        ]
        for svg in innocent {
            XCTAssertNoThrow(try MermaidRenderer.validate(svg), "wrongly refused: \(svg)")
        }
    }

    func testValidateStillRejectsRealHandlersWithVariedSpacingAndQuoting() {
        let hostile = [
            "<svg><rect onload=\"alert(1)\"/></svg>",
            "<svg><rect onload = \"alert(1)\"/></svg>",
            "<svg><rect onclick='alert(1)'/></svg>",
            "<svg><rect onmouseover=\"alert(1)\"/></svg>",
        ]
        for svg in hostile {
            XCTAssertThrowsError(try MermaidRenderer.validate(svg), "missed: \(svg)") { error in
                guard case .unsafeOutput = (error as? MermaidRenderError) else {
                    return XCTFail("expected .unsafeOutput for \(svg), got \(error)")
                }
            }
        }
    }

    func testValidateRejectsOutputThatIsNotAnSVGAtAll() {
        XCTAssertThrowsError(try MermaidRenderer.validate("<p>not a diagram</p>")) { error in
            XCTAssertEqual(error as? MermaidRenderError, .notSVG)
        }
    }

    func testValidationRunsOnTheRendererResultSoUnsafeOutputNeverReachesTheCaller() async {
        let renderer = StubRenderer(svg: "<svg><script>alert(1)</script></svg>")
        do {
            _ = try await MermaidRenderer.renderSVG(
                source: "flowchart TD\n A --> B", theme: .light, renderer: renderer)
            XCTFail("unsafe renderer output should not be returned")
        } catch {
            guard case .unsafeOutput = (error as? MermaidRenderError) else {
                return XCTFail("expected .unsafeOutput, got \(error)")
            }
        }
    }

    // MARK: - Cache

    func testCacheIsKeyedOnSourceAndThemeTogether() async throws {
        let source = "flowchart TD\n A --> B"
        let renderer = StubRenderer()
        XCTAssertNil(MermaidRenderer.cachedSVG(for: source, theme: .light))

        let light = try await MermaidRenderer.svg(for: source, theme: .light, renderer: renderer)
        XCTAssertEqual(MermaidRenderer.cachedSVG(for: source, theme: .light), light)
        // A dark render is a different diagram, so a light hit must not satisfy it.
        XCTAssertNil(MermaidRenderer.cachedSVG(for: source, theme: .dark))
        XCTAssertNil(MermaidRenderer.cachedSVG(for: source + " ", theme: .light))
    }

    func testASecondRequestForTheSameDiagramIsServedFromCacheRatherThanRenderedAgain() async throws {
        let source = "flowchart TD\n A --> B"
        let renderer = StubRenderer()

        _ = try await MermaidRenderer.svg(for: source, theme: .light, renderer: renderer)
        _ = try await MermaidRenderer.svg(for: source, theme: .light, renderer: renderer)

        XCTAssertEqual(renderer.receivedSources.count, 1, "the diagram was rendered twice")
    }

    // MARK: - Preview documents

    func testRenderedDiagramIsShownAsPlainSVGUnderTheSameRestrictivePolicy() {
        let artifact = Artifact(title: "D", type: "mermaid", source: "flowchart TD\n A --> B")
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><g id=\"diagram\"></g></svg>"

        let document = SafeHTMLPreview.artifactDocument(for: artifact, renderedMermaidSVG: svg)

        XCTAssertTrue(document.contains("<g id=\"diagram\"></g>"), "the diagram should be in the document")
        XCTAssertTrue(document.contains("script-src 'none'"), "a rendered diagram keeps the script ban")
        XCTAssertTrue(document.contains("connect-src 'none'"))
        XCTAssertFalse(document.contains("<pre>"), "a rendered diagram should not also show source")
    }

    func testUnrenderedDiagramStillFallsBackToEscapedSource() {
        let artifact = Artifact(
            title: "D", type: "mermaid", source: "graph TD; A[<script>alert(1)</script>] --> B")

        let document = SafeHTMLPreview.artifactDocument(for: artifact)

        XCTAssertFalse(document.contains("<script>alert(1)</script>"))
        XCTAssertTrue(document.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(document.contains("script-src 'none'"))
    }

    func testFailedDiagramShowsTheParseErrorAboveTheSourceAndEscapesBoth() {
        let document = SafeHTMLPreview.mermaidFailureDocument(
            source: "graph TD; A[<b>x</b>]",
            message: "Parse error on line 1: <unexpected>")

        XCTAssertTrue(document.contains("&lt;unexpected&gt;"), "the message should be escaped")
        XCTAssertTrue(document.contains("&lt;b&gt;x&lt;/b&gt;"), "the source should be escaped")
        XCTAssertFalse(document.contains("<b>x</b>"))
        XCTAssertTrue(document.contains("script-src 'none'"))
    }

    func testPlaceholderIsAQuietNoteRatherThanAnEmptyPane() {
        let document = SafeHTMLPreview.mermaidPlaceholderDocument()
        XCTAssertTrue(document.contains("Rendering diagram"))
        XCTAssertTrue(document.contains("script-src 'none'"))
    }

    func testRenderedDiagramHonorsPaperSoAnExportIsNotDarkMode() {
        let artifact = Artifact(title: "D", type: "mermaid", source: "flowchart TD\n A --> B")
        let paper = SafeHTMLPreview.artifactDocument(
            for: artifact, medium: .paper, renderedMermaidSVG: "<svg><g/></svg>")
        XCTAssertFalse(paper.contains("light dark"))
    }

    // MARK: - The real renderer, with the real vendored Mermaid

    func testVendoredMermaidIsPresentAndIsTheBrowserBuild() throws {
        let js = try vendoredMermaidJS()
        XCTAssertGreaterThan(js.utf8.count, 1_000_000, "the vendored renderer looks truncated")
        XCTAssertTrue(
            js.contains("globalThis[\"mermaid\"]"),
            "expected the IIFE browser build, which assigns globalThis.mermaid")
    }

    func testWebKitRendererProducesASanitizedDiagramFromRealMermaid() async throws {
        let renderer = WebKitMermaidSVGRenderer(mermaidJS: try vendoredMermaidJS())
        let svg = try await renderer.renderSVG(
            source: "flowchart TD\n  A([Start]) --> B{Choice}\n  B -- Yes --> C[Do it]",
            theme: "default")

        XCTAssertTrue(svg.contains("<svg"))
        XCTAssertTrue(svg.contains("Choice"), "the diagram's own labels should survive")
        XCTAssertNoThrow(try MermaidRenderer.validate(svg))
    }

    /// The reason the sanitizer exists. Mermaid's `click ... href` directive emits
    /// `<a xlink:href="https://…">` into the SVG, which would become a live external link in an
    /// exported file, where no navigation delegate is there to refuse it.
    func testClickHrefDirectiveDoesNotSurviveIntoTheRenderedDiagram() async throws {
        let renderer = WebKitMermaidSVGRenderer(mermaidJS: try vendoredMermaidJS())
        let svg = try await renderer.renderSVG(
            source: "graph TD\n  A[Go]\n  click A href \"https://evil.example/x\" \"tip\"",
            theme: "default")

        XCTAssertFalse(svg.contains("evil.example"), "an external link survived into the diagram")
        XCTAssertNoThrow(try MermaidRenderer.validate(svg))
    }

    func testMarkupInLabelsIsRenderedAsTextRatherThanEmbeddedHTML() async throws {
        let renderer = WebKitMermaidSVGRenderer(mermaidJS: try vendoredMermaidJS())
        for source in [
            "graph TD; A[\"<img src=x onerror=alert(1)>\"] --> B",
            "graph TD; A[\"<svg onload=alert(1)>\"] --> B",
            "graph TD; A[\"</svg><script>alert(1)</script>\"] --> B",
            "graph TD; A[\"<style>@import url(https://evil.example/x.css)</style>\"] --> B",
        ] {
            let svg = try await renderer.renderSVG(source: source, theme: "default")
            XCTAssertNoThrow(try MermaidRenderer.validate(svg), "leaked for: \(source)")
            XCTAssertFalse(svg.lowercased().contains("foreignobject"),
                           "htmlLabels should be off, so no embedded HTML: \(source)")
        }
    }

    func testUnparseableDiagramFailsWithMermaidsOwnMessageRatherThanSilence() async throws {
        let renderer = WebKitMermaidSVGRenderer(mermaidJS: try vendoredMermaidJS())
        do {
            _ = try await renderer.renderSVG(source: "flowchart TD\n  A --> --> ][", theme: "default")
            XCTFail("unparseable source should not render")
        } catch {
            guard case .diagramFailed(let message) = (error as? MermaidRenderError) else {
                return XCTFail("expected .diagramFailed, got \(error)")
            }
            XCTAssertTrue(message.lowercased().contains("parse error"),
                          "the author needs Mermaid's own wording, got: \(message)")
        }
    }

    /// The load phase resumes from a navigation callback, and a task group awaits its children at
    /// scope exit — so a render that ignored cancellation would outlive the timeout meant to bound
    /// it and hang the caller instead of failing it.
    func testCancellingARenderReturnsPromptlyRatherThanHanging() async throws {
        let renderer = WebKitMermaidSVGRenderer(mermaidJS: try vendoredMermaidJS())
        let task = Task { @MainActor in
            try await renderer.renderSVG(
                source: "flowchart TD\n  A([Start]) --> B{Choice}", theme: "default")
        }
        task.cancel()

        let finished = expectation(description: "a cancelled render finishes")
        Task { _ = await task.result; finished.fulfill() }
        await fulfillment(of: [finished], timeout: 10)
    }

    /// A diagram that cannot parse produces no cache entry, so the guard against re-rendering is the
    /// only thing standing between a parse error and a fresh render on every SwiftUI update.
    func testADiagramThatFailedToRenderIsNotRenderedAgainOnTheNextUpdate() async {
        let coordinator = ArtifactWebView.Coordinator()
        let web = WKWebView(frame: .zero, configuration: SafeHTMLPreview.makeConfiguration())
        // No bundled renderer on the XCTest search path, so every render here fails fast.
        let artifact = Artifact(title: "D", type: "mermaid", source: "flowchart TD\n A --> B")

        coordinator.update(artifact: artifact, theme: .light, in: web)
        XCTAssertEqual(coordinator.rendersStarted, 1)

        for _ in 0..<5 {
            coordinator.update(artifact: artifact, theme: .light, in: web)
        }
        XCTAssertEqual(coordinator.rendersStarted, 1, "the same diagram was rendered more than once")

        // A different appearance is a different diagram and must still be rendered.
        coordinator.update(artifact: artifact, theme: .dark, in: web)
        XCTAssertEqual(coordinator.rendersStarted, 2)
    }

    func testANonMermaidArtifactNeverStartsARender() {
        let coordinator = ArtifactWebView.Coordinator()
        let web = WKWebView(frame: .zero, configuration: SafeHTMLPreview.makeConfiguration())
        let artifact = Artifact(title: "H", type: "html", source: "<p>hello</p>")

        coordinator.update(artifact: artifact, theme: .light, in: web)

        XCTAssertEqual(coordinator.rendersStarted, 0)
    }

    func testMissingBundledRendererIsReportedRatherThanRenderingNothing() async {
        // No override and no bundled copy on the XCTest search path: the failure a broken build
        // would produce.
        let renderer = WebKitMermaidSVGRenderer()
        do {
            _ = try await renderer.renderSVG(source: "flowchart TD\n A --> B", theme: "default")
            XCTFail("a build with no bundled renderer should report it")
        } catch {
            XCTAssertEqual(error as? MermaidRenderError, .rendererUnavailable)
        }
    }
}
