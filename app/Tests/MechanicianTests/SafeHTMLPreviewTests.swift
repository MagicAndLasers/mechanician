import XCTest
@testable import Mechanician

final class SafeHTMLPreviewTests: XCTestCase {
    func testArtifactDocumentAppliesRestrictiveContentSecurityPolicy() {
        let artifact = Artifact(
            title: "Untrusted",
            type: "html",
            source: "<script>fetch('https://example.com')</script><p>Hello</p>")

        let document = SafeHTMLPreview.artifactDocument(for: artifact)

        XCTAssertTrue(document.contains("default-src 'none'"))
        XCTAssertTrue(document.contains("connect-src 'none'"))
        XCTAssertTrue(document.contains("script-src 'none'"))
        XCTAssertTrue(document.contains("form-action 'none'"))
        XCTAssertTrue(document.contains("<p>Hello</p>"))
    }

    func testMermaidPreviewDoesNotLoadExecutableCodeAndEscapesSource() {
        let artifact = Artifact(
            title: "Diagram",
            type: "mermaid",
            source: "graph TD; A[<script>alert(1)</script>] --> B")

        let document = SafeHTMLPreview.artifactDocument(for: artifact)

        XCTAssertFalse(document.contains("cdn.jsdelivr.net"))
        XCTAssertFalse(document.contains("mermaid.initialize"))
        XCTAssertFalse(document.contains("<script>alert(1)</script>"))
        XCTAssertTrue(document.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    func testFileDocumentHasNoLocalFileBaseURLOrNetworkAllowance() {
        let document = SafeHTMLPreview.fileDocument(
            "<img src=\"file:///Users/example/.ssh/id_rsa\"><img src=\"https://example.com/pixel\">")

        XCTAssertTrue(document.contains("default-src 'none'"))
        XCTAssertTrue(document.contains("img-src data:"))
        XCTAssertFalse(document.contains("img-src https:"))
        XCTAssertTrue(document.contains("base-uri 'none'"))
    }

    // MARK: - Medium (FR-177)

    /// Exporting in Dark Mode used to produce light text on a dark background: `color-scheme:
    /// light dark` let the document follow the app. On paper that is a page of solid ink.
    func testPaperDocumentsNeverFollowTheAppAppearance() {
        let artifact = Artifact(title: "Report", type: "html", source: "<p>hello</p>")
        let paper = SafeHTMLPreview.artifactDocument(for: artifact, medium: .paper)
        XCTAssertTrue(paper.contains("color-scheme: light;"))
        XCTAssertFalse(paper.contains("light dark"), "a printed document followed the app appearance")
    }

    /// The other half, and the reason this is a parameter rather than a pin at the export site: a
    /// preview panel inside a dark window must stay dark, or fixing the PDF hands every Dark Mode
    /// user a glaring white slab in two places.
    func testScreenDocumentsStillFollowTheAppAppearance() {
        let artifact = Artifact(title: "Report", type: "html", source: "<p>hello</p>")
        XCTAssertTrue(SafeHTMLPreview.artifactDocument(for: artifact).contains("color-scheme: light dark;"))
        XCTAssertTrue(SafeHTMLPreview.fileDocument("<p>x</p>").contains("color-scheme: light dark;"))
        XCTAssertTrue(SafeHTMLPreview.document(body: "<p>x</p>").contains("color-scheme: light dark;"))
    }

    /// Every artifact type goes through the same builder, so the medium has to reach all of them —
    /// svg and mermaid take their own branches.
    func testEveryArtifactTypeHonorsPaper() {
        for type in ["html", "svg", "mermaid", "markdown", "csv"] {
            let artifact = Artifact(title: "A", type: type, source: "<p>x</p>")
            let paper = SafeHTMLPreview.artifactDocument(for: artifact, medium: .paper)
            XCTAssertFalse(paper.contains("light dark"), "\(type) followed the app appearance on paper")
        }
    }
}
