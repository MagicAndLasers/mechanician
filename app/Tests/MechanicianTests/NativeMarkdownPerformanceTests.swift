import AppKit
import XCTest
@testable import Mechanician

/// Opt-in construction and layout measurements at the response size where foreground presentation
/// cadence is already reduced. Absolute timings are machine-specific, so ordinary CI skips these;
/// their purpose is to identify which stage is worth optimizing and to compare dogfood revisions
/// on the same Mac.
///
///     MECHANICIAN_RUN_PERF_TESTS=1 swift test --package-path app --arch arm64 \
///       --filter NativeMarkdownPerformanceTests
///
@MainActor
final class NativeMarkdownPerformanceTests: XCTestCase {
    func testRendererConstructionAtLongResponse() throws {
        try requirePerformanceRun()
        let markdown = longMarkdownFixture()
        XCTAssertGreaterThanOrEqual(markdown.utf8.count, 256 * 1_024)
        var renderedLength = 0
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            autoreleasepool {
                renderedLength = NativeMarkdownRenderer.render(markdown, scale: 1).length
            }
        }

        XCTAssertGreaterThan(renderedLength, 200_000)
    }

    func testTextKitInstallAndLayoutAtLongResponse() throws {
        try requirePerformanceRun()
        let markdown = longMarkdownFixture()
        let rendered = NativeMarkdownRenderer.render(markdown, scale: 1)
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(
            width: 600,
            height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        var measuredHeight: CGFloat = 0
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            storage.setAttributedString(rendered)
            layoutManager.ensureLayout(for: container)
            measuredHeight = layoutManager.usedRect(for: container).height
        }

        XCTAssertGreaterThan(measuredHeight, 1_000)
    }

    func testFinalizedCacheHitInstallAndLayoutAtLongResponse() throws {
        try requirePerformanceRun()
        let markdown = longMarkdownFixture()
        let id = AnyHashable("long-finalized-benchmark")
        let cache = FinalizedAssistantDocumentCache()
        _ = cache.insert(
            NativeMarkdownRenderer.render(markdown, scale: 1),
            for: id,
            source: markdown,
            scale: 1)
        XCTAssertEqual(cache.count, 1, "the benchmark fixture must fit the production cache bound")

        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(
            width: 600,
            height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        var measuredHeight: CGFloat = 0
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            guard let cached = cache.document(for: id, source: markdown, scale: 1) else {
                return XCTFail("the finalized benchmark document was unexpectedly evicted")
            }
            storage.setAttributedString(cached)
            layoutManager.ensureLayout(for: container)
            measuredHeight = layoutManager.usedRect(for: container).height
        }

        XCTAssertGreaterThan(measuredHeight, 1_000)
    }

    func testUncachedColdRenderInstallAndLayoutAtLongResponse() throws {
        try requirePerformanceRun()
        let markdown = longMarkdownFixture()
        let (storage, layoutManager, container) = makeLayoutStack()
        var measuredHeight: CGFloat = 0
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            autoreleasepool {
                let rendered = NativeMarkdownRenderer.render(markdown, scale: 1)
                storage.setAttributedString(rendered)
                layoutManager.ensureLayout(for: container)
                measuredHeight = layoutManager.usedRect(for: container).height
            }
        }

        XCTAssertGreaterThan(measuredHeight, 1_000)
    }

    func testFinalizedCacheColdAdmissionAtLongResponse() throws {
        try requirePerformanceRun()
        let markdown = longMarkdownFixture()
        let id = AnyHashable("long-finalized-cold-admission")
        let (storage, layoutManager, container) = makeLayoutStack()
        var measuredHeight: CGFloat = 0
        var admittedCount = 0
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            autoreleasepool {
                let cache = FinalizedAssistantDocumentCache()
                let rendered = NativeMarkdownRenderer.render(markdown, scale: 1)
                let admitted = cache.insert(rendered, for: id, source: markdown, scale: 1)
                admittedCount = cache.count
                storage.setAttributedString(admitted)
                layoutManager.ensureLayout(for: container)
                measuredHeight = layoutManager.usedRect(for: container).height
            }
        }

        XCTAssertEqual(admittedCount, 1, "the benchmark fixture must be admitted")
        XCTAssertGreaterThan(measuredHeight, 1_000)
    }

    private func requirePerformanceRun() throws {
        guard ProcessInfo.processInfo.environment["MECHANICIAN_RUN_PERF_TESTS"] == "1" else {
            throw XCTSkip("Set MECHANICIAN_RUN_PERF_TESTS=1 to run Markdown benchmarks.")
        }
    }

    private func makeLayoutStack() -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(
            width: 600,
            height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        return (storage, layoutManager, container)
    }

    /// Roughly 370 KiB with prose, inline markup, links, tables, and many independently highlighted
    /// code blocks. Repeating complete sections models a long finalized response without making one
    /// synthetic fence exceed the highlighter's deliberate 20K-character ceiling.
    private func longMarkdownFixture() -> String {
        let prose = Array(repeating:
            "Mechanician keeps provider events authoritative while the transcript renders "
                + "**stable Markdown**, `inline code`, and [local evidence](./report.md).",
            count: 14).joined(separator: " ")
        let code = (0..<42).map { line in
            "let measuredValue\(line) = requestCount + \(line) // retained benchmark evidence"
        }.joined(separator: "\n")
        let table = """
        | Stage | Authority | Result |
        |---|---|---|
        | Provider ingress | Harness | Unchanged |
        | Markdown render | Mechanician | Measured |
        | TextKit layout | AppKit | Measured |
        """
        return (0..<72).map { section in
            """
            ## Rendering section \(section)

            \(prose)

            ```swift
            \(code)
            ```

            \(table)
            """
        }.joined(separator: "\n\n")
    }
}
