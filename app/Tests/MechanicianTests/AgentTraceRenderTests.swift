import XCTest
import AppKit
@testable import Mechanician

/// AppKit retains tooltip owners weakly. These controls therefore have to remain their own stable
/// owners while tracking regions are removed and recreated.
final class AppKitActivitySegmentedControlToolTipTests: XCTestCase {
    func testTrackingAreaRebuildKeepsTooltipTextOnTheStableOwner() {
        let helpText = ["Show the execution trace", "Show token usage"]
        let view = AppKitActivitySegmentedControl(
            titles: ["Trace", "Usage"],
            helpText: helpText)
        view.frame = NSRect(x: 0, y: 0, width: 180, height: 20)

        view.updateTrackingAreas()
        XCTAssertEqual(Set(view.toolTipTextByTag.values), Set(helpText))
        XCTAssertEqual(view.toolTipTextByTag.count, helpText.count)
        for (tag, text) in view.toolTipTextByTag {
            XCTAssertEqual(
                view.view(view, stringForToolTip: tag, point: .zero, userData: nil),
                text)
        }

        view.updateTrackingAreas()
        XCTAssertEqual(
            view.toolTipTextByTag.count,
            helpText.count,
            "re-registering regions replaces the retained tooltip text instead of accumulating it")
        for (tag, text) in view.toolTipTextByTag {
            XCTAssertEqual(
                view.view(view, stringForToolTip: tag, point: .zero, userData: nil),
                text)
        }
    }
}

/// Offscreen rendering of the real trace view.
///
/// Three things about this panel are properties of what it *paints*, and none of them can be
/// checked through the render model: whether it is legible in Light Mode, whether the EVENTS rail
/// draws anything at all, and what a draw actually costs. All three had been carried as unverified
/// debt. This renders the shipping view into a bitmap under an explicit appearance and asserts on
/// the pixels.
///
/// Set `MECHANICIAN_TRACE_RENDER_DUMP=/some/dir` to also write the PNGs for eyeballing.
final class AgentTraceRenderTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 10_000)

    // MARK: - Fixtures

    /// A turn with every mark the trace can draw: model and tool spans on both tracks, a wait, the
    /// initial prompt, a compaction, user guidance, token samples and a terminal state.
    private func richTurn(
        guidanceOffset: TimeInterval = 10,
        historyReductionOffset: TimeInterval = 8.5
    ) -> (records: [AgentActivityRecord], summary: AgentActivityTurnSummary) {
        let child = AgentActivityIdentity.subagent("a1")
        let other = AgentActivityIdentity.subagent("a2")
        var records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", detail: "Reasoning", at: start),
            .initialPrompt(
                "Inspect the activity timeline.",
                turnID: "turn",
                at: start),
            .tokens(
                turnID: "turn",
                input: 12_000,
                cachedInput: 9_000,
                output: 400,
                at: start.addingTimeInterval(1)),
            .state(.tool, turnID: "turn", detail: "Bash", at: start.addingTimeInterval(2)),
            .tool(
                "Bash",
                turnID: "turn",
                agentID: AgentActivityIdentity.root,
                target: "swift build",
                at: start.addingTimeInterval(2)),
            .state(.model, turnID: "turn", at: start.addingTimeInterval(6)),

            .state(.model, turnID: "turn", agentID: child, at: start.addingTimeInterval(2)),
            .state(.tool, turnID: "turn", agentID: child, detail: "Read", at: start.addingTimeInterval(4)),
            .tool(
                "Read",
                turnID: "turn",
                agentID: child,
                target: "AgentBridge.swift",
                at: start.addingTimeInterval(4)),
            .state(.model, turnID: "turn", agentID: child, at: start.addingTimeInterval(9)),
            .state(.completed, turnID: "turn", agentID: child, at: start.addingTimeInterval(12)),

            .state(.waiting, turnID: "turn", agentID: other, at: start.addingTimeInterval(3)),
            .state(.model, turnID: "turn", agentID: other, at: start.addingTimeInterval(5)),
            .state(.tool, turnID: "turn", agentID: other, detail: "Grep", at: start.addingTimeInterval(8)),
            .tool("Grep", turnID: "turn", agentID: other, at: start.addingTimeInterval(8)),
            .state(.failed, turnID: "turn", agentID: other, at: start.addingTimeInterval(11)),

            // The two later marks the EVENTS rail exists for.
            .compaction(
                turnID: "turn",
                trigger: "auto",
                preTokens: 180_000,
                postTokens: 38_000,
                at: start.addingTimeInterval(7)),
            .historyReduction(
                turnID: "turn",
                omittedMessages: 3,
                shortenedMessages: 1,
                reason: "context_compaction_failed",
                at: start.addingTimeInterval(historyReductionOffset))!,
            .interjection(
                "stop after this",
                disposition: .delivered,
                turnID: "turn",
                at: start.addingTimeInterval(guidanceOffset)),

            .context(
                turnID: "turn",
                tokens: 42_000,
                window: 258_400,
                at: start.addingTimeInterval(9)),
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(14)),
        ]
        records.sort { $0.at < $1.at }
        let summary = AgentActivityTurnSummary(
            id: "turn",
            startedAt: start,
            endedAt: start.addingTimeInterval(14),
            providerAccess: nil,
            modelID: nil,
            isTerminal: true,
            inputTokens: 12_000,
            cachedInputTokens: 9_000,
            outputTokens: 400,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        return (records, summary)
    }

    private func makeChart(
        appearance: NSAppearance.Name,
        size: NSSize = NSSize(width: 900, height: 380),
        guidanceOffset: TimeInterval = 10,
        historyReductionOffset: TimeInterval = 8.5,
        includesTokenUsage: Bool = true
    ) -> AppKitAgentActivityChartView {
        var turn = richTurn(
            guidanceOffset: guidanceOffset,
            historyReductionOffset: historyReductionOffset)
        if !includesTokenUsage {
            turn.records.removeAll { $0.kind == .tokens }
            turn.summary.inputTokens = 0
            turn.summary.cachedInputTokens = 0
            turn.summary.outputTokens = 0
            turn.summary.reasoningOutputTokens = 0
            turn.summary.aggregateOnlyTokens = 0
        }
        let view = AppKitAgentActivityChartView()
        view.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(origin: .zero, size: size)
        view.laneGutterWidth = 132
        view.fitsWidth = true
        _ = view.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: turn.records,
                summary: turn.summary,
                aliases: [:],
                labels: [
                    AgentActivityIdentity.subagent("a1"): "A1 · reader",
                    AgentActivityIdentity.subagent("a2"): "A2 · searcher",
                ]),
            now: turn.summary.endedAt)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func makeSinglePhaseChart(
        _ phase: AgentActivityPhase,
        appearance: NSAppearance.Name
    ) -> AppKitAgentActivityChartView {
        let turnID = "single-\(phase.rawValue)"
        let endedAt = start.addingTimeInterval(8)
        let detail: String? = switch phase {
        case .model: "Reasoning"
        case .tool: "Read"
        default: nil
        }
        var records: [AgentActivityRecord] = [
            .state(phase, turnID: turnID, detail: detail, at: start),
        ]
        if phase == .compacting {
            records.append(.compaction(
                turnID: turnID,
                trigger: "auto",
                preTokens: nil,
                postTokens: nil,
                at: endedAt))
        }
        records.append(.state(.completed, turnID: turnID, at: endedAt))
        let summary = AgentActivityTurnSummary(
            id: turnID,
            startedAt: start,
            endedAt: endedAt,
            providerAccess: nil,
            modelID: nil,
            isTerminal: true,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let view = AppKitAgentActivityChartView()
        view.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(x: 0, y: 0, width: 620, height: 180)
        view.laneGutterWidth = 132
        view.fitsWidth = true
        _ = view.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: records,
                summary: summary,
                aliases: [:],
                labels: [:]),
            now: endedAt)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// A live fixed-scale trace whose document is wider than its viewport. The chart is installed
    /// in the scroll view before rebuilding so its frozen gutter is measured from the real narrow
    /// viewport, while the activity spans and accessibility frames are built against the final
    /// document width.
    private func makeLiveFixedScaleChart(
        duration: TimeInterval,
        viewportWidth: CGFloat
    ) -> (scrollView: NSScrollView, chart: AppKitAgentActivityChartView) {
        let turnID = "live-fixed-\(duration)"
        let summary = AgentActivityTurnSummary(
            id: turnID,
            startedAt: start,
            endedAt: start,
            providerAccess: nil,
            modelID: nil,
            isTerminal: false,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let input = AppKitAgentActivityRenderInput(
            records: [
                .state(.model, turnID: turnID, detail: "Reasoning", at: start),
            ],
            summary: summary,
            aliases: [:],
            labels: [:])
        let now = start.addingTimeInterval(duration)

        // Ask an identically configured chart for the document width before building the real
        // chart's accessibility geometry. Resizing after `rebuild` would leave those frames at the
        // probe width and test stale geometry instead of the pixels the document draws.
        let probe = AppKitAgentActivityChartView()
        probe.frame = NSRect(x: 0, y: 0, width: viewportWidth, height: 180)
        probe.laneGutterWidth = 132
        _ = probe.rebuild(input: input, now: now)
        let documentWidth = probe.preferredWidth(viewportWidth: viewportWidth)

        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: viewportWidth, height: 180))
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        let chart = AppKitAgentActivityChartView()
        chart.frame = NSRect(x: 0, y: 0, width: documentWidth, height: 180)
        chart.laneGutterWidth = 132
        scrollView.documentView = chart
        scrollView.layoutSubtreeIfNeeded()
        _ = chart.rebuild(input: input, now: now)
        chart.layoutSubtreeIfNeeded()
        return (scrollView, chart)
    }

    private func firstTraceSpan(
        in chart: AppKitAgentActivityChartView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSAccessibilityElement {
        let lanes = try XCTUnwrap(
            chart.accessibilityChildren() as? [NSAccessibilityElement],
            file: file,
            line: line)
        let lane = try XCTUnwrap(
            lanes.first { $0.accessibilityRole() == .group },
            file: file,
            line: line)
        let spans = try XCTUnwrap(
            lane.accessibilityChildren() as? [NSAccessibilityElement],
            file: file,
            line: line)
        return try XCTUnwrap(spans.first, file: file, line: line)
    }

    // MARK: - Pixel helpers

    private func render(
        _ view: NSView,
        appearance: NSAppearance.Name,
        dumpName: String
    ) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(
            view.bitmapImageRepForCachingDisplay(in: view.bounds),
            "the view must be able to produce a bitmap for its own bounds")
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        if let dir = ProcessInfo.processInfo.environment["MECHANICIAN_TRACE_RENDER_DUMP"],
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(dumpName).png"))
        }
        return rep
    }

    /// Points-to-pixels for the cached rep, which is backing-scale sized (2x on Retina). Sampling
    /// in raw pixel indices silently probed the wrong region — the "ruler" assertion was reading
    /// empty space well below it.
    private func scale(_ rep: NSBitmapImageRep, _ view: NSView) -> Int {
        max(1, rep.pixelsWide / max(1, Int(view.bounds.width)))
    }

    private func luminance(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
    }

    /// Spread of luminance in a region. A region that draws nothing is flat.
    private func contrast(
        _ rep: NSBitmapImageRep,
        _ view: NSView,
        x: Range<Int>,
        y: Range<Int>
    ) -> CGFloat {
        let s = scale(rep, view)
        var low: CGFloat = 1
        var high: CGFloat = 0
        for px in (x.lowerBound * s..<x.upperBound * s).clamped(to: 0..<rep.pixelsWide) {
            for py in (y.lowerBound * s..<y.upperBound * s).clamped(to: 0..<rep.pixelsHigh) {
                let value = luminance(rep, px, py)
                low = min(low, value)
                high = max(high, value)
            }
        }
        return high - low
    }

    private func brightPixelCount(
        _ rep: NSBitmapImageRep,
        _ view: NSView,
        x: Range<Int>,
        y: Range<Int>,
        threshold: CGFloat
    ) -> Int {
        let s = scale(rep, view)
        var count = 0
        for px in (x.lowerBound * s..<x.upperBound * s).clamped(to: 0..<rep.pixelsWide) {
            for py in (y.lowerBound * s..<y.upperBound * s).clamped(to: 0..<rep.pixelsHigh)
                where luminance(rep, px, py) >= threshold {
                count += 1
            }
        }
        return count
    }

    private func differingPixelCount(
        _ lhs: NSBitmapImageRep,
        _ rhs: NSBitmapImageRep,
        view: NSView,
        x: Range<Int>,
        y: Range<Int>
    ) -> Int {
        let s = scale(lhs, view)
        var count = 0
        for px in (x.lowerBound * s..<x.upperBound * s).clamped(to: 0..<lhs.pixelsWide) {
            for py in (y.lowerBound * s..<y.upperBound * s).clamped(to: 0..<lhs.pixelsHigh) {
                guard let a = lhs.colorAt(x: px, y: py)?.usingColorSpace(.sRGB),
                      let b = rhs.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else {
                    continue
                }
                let delta = abs(a.redComponent - b.redComponent)
                    + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)
                    + abs(a.alphaComponent - b.alphaComponent)
                if delta > 0.02 {
                    count += 1
                }
            }
        }
        return count
    }

    // MARK: - Fixed-scale live geometry

    /// The follow policy and the chart must agree on the pixel that means "now." The live document
    /// reserves 160 points after that pixel; normalizing time across the whole document instead
    /// placed the drawn end only ten points from the document edge and 150 points to the right of
    /// `liveEdgeX`, which is enough to push it outside a narrow inspector.
    func testLiveFixedScaleKeepsTheRunwayAfterTheDrawnCurrentEdge() throws {
        let fixture = makeLiveFixedScaleChart(duration: 60, viewportWidth: 300)
        let chart = fixture.chart
        let currentSpan = try firstTraceSpan(in: chart)
        let spanFrame = currentSpan.accessibilityFrameInParentSpace()

        withExtendedLifetime(fixture.scrollView) {
            XCTAssertEqual(
                chart.inspectionLines(at: NSPoint(x: chart.liveEdgeX, y: 0)).first,
                "1:00",
                "the coordinate followed as now must inspect the render model's exact end")
            XCTAssertEqual(
                spanFrame.maxX,
                chart.liveEdgeX,
                accuracy: 0.5,
                "the open span's drawn tail and the live-follow edge must be the same pixel")
            XCTAssertGreaterThanOrEqual(
                chart.bounds.maxX - spanFrame.maxX,
                AppKitAgentActivityChartView.liveRunway - 0.5,
                "the runway belongs after the time axis, not inside its normalized coordinates")
        }
    }

    /// A one-second turn is intentionally much narrower than this viewport. Fixed scale still
    /// means one second occupies exactly one `pointsPerSecond` interval; filling the spare width
    /// would make every earlier span slide and compress as a live turn grows.
    func testShortLiveFixedScaleDoesNotStretchTimeToFillTheViewport() throws {
        let fixture = makeLiveFixedScaleChart(duration: 1, viewportWidth: 380)
        let chart = fixture.chart
        let currentSpan = try firstTraceSpan(in: chart)
        let spanFrame = currentSpan.accessibilityFrameInParentSpace()

        withExtendedLifetime(fixture.scrollView) {
            XCTAssertEqual(spanFrame.width, chart.pointsPerSecond, accuracy: 0.5)
            XCTAssertEqual(
                chart.inspectionLines(at: NSPoint(x: spanFrame.midX, y: 0)).first,
                "0.5s",
                "halfway through a one-second fixed-scale span must inspect as half a second")
            XCTAssertEqual(
                chart.inspectionLines(at: NSPoint(x: chart.liveEdgeX, y: 0)).first,
                "1.0s")
        }
    }

    // MARK: - Light Mode

    /// The panel had never been rendered in Light Mode. It previously shipped a legend whose chips
    /// filled `nElevated @ 0.5` — identical to `windowBackgroundColor` in light — so they were
    /// invisible, and several colours are still written as literals. This asserts the appearance
    /// actually resolves light and that the chart's regions carry contrast rather than flat fill.
    func testTraceIsLegibleInLightMode() throws {
        let view = makeChart(appearance: .aqua)
        let rep = try render(view, appearance: .aqua, dumpName: "trace-light")

        let background = luminance(rep, 8, rep.pixelsHigh - 8)
        XCTAssertGreaterThan(
            background, 0.55,
            "Light Mode must resolve a light backdrop; a dark one means the appearance never applied")

        // Lane gutter: agent names and their per-lane metrics.
        XCTAssertGreaterThan(
            contrast(rep, view, x: 0..<130, y: 40..<210), 0.25,
            "Lane names and metrics must contrast with the gutter in Light Mode")

        // Plot: bars against their rails.
        XCTAssertGreaterThan(
            contrast(rep, view, x: 140..<880, y: 40..<210), 0.30,
            "Trace bars must contrast with their rails in Light Mode")

        // Ruler.
        XCTAssertGreaterThan(
            contrast(rep, view, x: 140..<880, y: 240..<268), 0.15,
            "Ruler tick labels must remain readable in Light Mode")
    }

    func testLightReasoningSpanPaintsWhiteLabelInk() throws {
        let view = makeSinglePhaseChart(.model, appearance: .aqua)
        _ = try render(
            view,
            appearance: .aqua,
            dumpName: "trace-reasoning-label-light")

        // The rendered fixture above proves the real chart reaches its labeled model-span path.
        // Pin the ink policy directly instead of counting fully white raster pixels: GitHub's 1x
        // hosted runner can antialias every 8-point glyph pixel with the 4% dark outline, while a
        // Retina render leaves a bright core. Both are the same white-fill AppKit draw operation.
        XCTAssertEqual(
            appKitAgentActivitySpanLabelColor(
                .model,
                background: .nElevated,
                appearance: NSAppearance(named: .aqua)!),
            .white,
            "Light model-blue spans must use white label ink")
    }

    /// WHITE READS ON THE FILL, WITH NOTHING DRAWN AROUND THE LETTERS. This used to pass because
    /// every glyph carried a dark outline; David reported that outline as a black fringe that made
    /// small text harder to read. The requirement is unchanged and now has to be met by the fill:
    /// `waiting` stopped using a text colour as a fill, and `compacting` stopped being so
    /// translucent that a white label floated on the card behind it.
    func testWhiteLabelsReadOnTheQuietestPhaseFills() throws {
        let cases: [(phase: AgentActivityPhase, appearance: NSAppearance.Name, dump: String)] = [
            (.waiting, .darkAqua, "trace-waiting-label-dark"),
            (.compacting, .aqua, "trace-compacting-label-light"),
        ]
        for fixture in cases {
            let view = makeSinglePhaseChart(fixture.phase, appearance: fixture.appearance)
            let rep = try render(view, appearance: fixture.appearance, dumpName: fixture.dump)
            let span = try firstTraceSpan(in: view).accessibilityFrameInParentSpace()
            let textX = Int(span.minX + 3)..<Int(min(span.maxX - 3, span.minX + 150))
            let textY = Int(span.minY + 1)..<Int(span.maxY - 1)

            XCTAssertGreaterThan(
                brightPixelCount(rep, view, x: textX, y: textY, threshold: 0.82),
                3,
                "\(fixture.phase) must keep its white glyph interior in \(fixture.appearance.rawValue)")
            XCTAssertGreaterThan(
                contrast(rep, view, x: textX, y: textY),
                0.18,
                "\(fixture.phase) must carry white glyphs on its own fill in \(fixture.appearance.rawValue)")
        }
    }

    func testTracePaintsTokenHistogramAndPeakLabelInLightMode() throws {
        let populated = makeChart(appearance: .aqua)
        let empty = makeChart(appearance: .aqua, includesTokenUsage: false)
        let populatedRep = try render(
            populated,
            appearance: .aqua,
            dumpName: "trace-token-track-light")
        let emptyRep = try render(
            empty,
            appearance: .aqua,
            dumpName: "trace-token-track-empty-light")
        let costTop = Int(
            TraceLayoutProbe.eventRailHeight
                + CGFloat(3) * TraceLayoutProbe.laneHeight)
        let costBottom = costTop + Int(TraceLayoutProbe.costTrackHeight)

        XCTAssertGreaterThan(
            differingPixelCount(
                populatedRep,
                emptyRep,
                view: populated,
                x: 132..<880,
                y: costTop..<costBottom),
            100,
            "nonzero token samples must paint visible histogram columns in the lower track")
        XCTAssertGreaterThan(
            differingPixelCount(
                populatedRep,
                emptyRep,
                view: populated,
                x: 0..<132,
                y: costTop..<costBottom),
            10,
            "nonzero token samples must paint the peak label beside the lower track")

        let tokenVolume = try XCTUnwrap(
            (populated.accessibilityChildren() as? [NSAccessibilityElement])?.first {
                $0.accessibilityLabel() == "Token volume over time"
            })
        XCTAssertEqual(
            tokenVolume.accessibilityValue() as? String,
            "peak \(formatTokens(12_400)) tokens in one interval")
        XCTAssertFalse(
            (empty.accessibilityChildren() as? [NSAccessibilityElement])?.contains {
                $0.accessibilityLabel() == "Token volume over time"
            } ?? true)
    }

    func testTraceIsLegibleInDarkMode() throws {
        let view = makeChart(appearance: .darkAqua)
        let rep = try render(view, appearance: .darkAqua, dumpName: "trace-dark")

        let background = luminance(rep, 8, rep.pixelsHigh - 8)
        XCTAssertLessThan(background, 0.35, "Dark Mode must resolve a dark backdrop")
        XCTAssertGreaterThan(
            contrast(rep, view, x: 0..<130, y: 40..<210), 0.25,
            "Lane names and metrics must contrast with the gutter in Dark Mode")
        XCTAssertGreaterThan(
            contrast(rep, view, x: 140..<880, y: 40..<210), 0.30,
            "Trace bars must contrast with their rails in Dark Mode")
    }

    // MARK: - EVENTS rail

    /// The EVENTS rail had never been seen rendering anything: no capture taken during development
    /// contained a compaction or a user message, so its badges, symbols and per-lane verticals were
    /// entirely unproven. The fixture contains the initial prompt, compaction and later guidance.
    func testEventRailDrawsCompactionAndInterjection() throws {
        let view = makeChart(appearance: .darkAqua)
        let rep = try render(view, appearance: .darkAqua, dumpName: "trace-events")

        // The rail is the top 34 points, and the badges sit right of the frozen gutter.
        let railContrast = contrast(rep, view, x: 140..<880, y: 0..<Int(TraceLayoutProbe.eventRailHeight))
        XCTAssertGreaterThan(
            railContrast, 0.12,
            "A turn with its prompt, a compaction and guidance must draw marks in the EVENTS rail")

        // And the rail must be labelled, so an empty rail is still explicable.
        XCTAssertGreaterThan(
            contrast(rep, view, x: 0..<130, y: 0..<Int(TraceLayoutProbe.eventRailHeight)), 0.10,
            "The EVENTS rail keeps its frozen label")
    }

    func testInitialPromptMarkerIsVisibleInspectableAndAccessibleAtTurnStart() throws {
        let view = makeChart(appearance: .darkAqua)
        let rep = try render(view, appearance: .darkAqua, dumpName: "trace-initial-prompt")

        // t=0 is the frozen gutter boundary. The stem remains there, while the entire 16-point
        // badge must sit on the plot side instead of being painted under the gutter.
        XCTAssertGreaterThan(
            contrast(rep, view, x: 132..<149, y: 0..<18), 0.20,
            "the initial-prompt badge must remain fully visible at the left timeline boundary")

        let lines = view.inspectionLines(at: NSPoint(x: 140, y: 8))
        XCTAssertEqual(lines.first, "Initial prompt")
        XCTAssertTrue(lines.contains("Inspect the activity timeline."))

        let labels = (view.accessibilityChildren() as? [NSAccessibilityElement])?
            .compactMap { $0.accessibilityLabel() } ?? []
        XCTAssertTrue(labels.contains {
            $0.contains("Initial prompt") && $0.contains("Inspect the activity timeline.")
        })
    }

    func testNearStartHistoryMarkerDoesNotCoverInitialPromptAndKeepsMatchingInteractionGeometry()
        throws
    {
        let view = makeChart(
            appearance: .darkAqua,
            historyReductionOffset: 0.05)
        let rep = try render(
            view,
            appearance: .darkAqua,
            dumpName: "trace-near-start-history-reduction")

        // Both timestamps fall inside the opening badge's clamped footprint. The event layout
        // keeps their truthful stems near t=0, but advances the second badge far enough that both
        // glyphs remain visible and independently inspectable.
        XCTAssertGreaterThan(
            contrast(rep, view, x: 150..<167, y: 0..<18),
            0.20,
            "the near-start history badge must be painted beside, not over, the opening prompt")
        XCTAssertEqual(
            view.inspectionLines(at: NSPoint(x: 140, y: 8)).first,
            "Initial prompt")
        XCTAssertEqual(
            view.inspectionLines(at: NSPoint(x: 158, y: 8)).first,
            "History reduced · 3 messages omitted · 1 message shortened")

        let elements = view.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        let prompt = try XCTUnwrap(elements.first {
            $0.accessibilityLabel()?.hasPrefix("Initial prompt") == true
        })
        let reduction = try XCTUnwrap(elements.first {
            $0.accessibilityLabel()?.hasPrefix("History reduced") == true
        })
        XCTAssertLessThanOrEqual(
            prompt.accessibilityFrameInParentSpace().maxX,
            reduction.accessibilityFrameInParentSpace().minX,
            "VoiceOver frames must use the same separated badge geometry as the visible glyphs")
    }

    func testLightEventBadgeDrawsItsWhiteSymbolInsteadOfTemplateBlack() throws {
        let view = makeChart(appearance: .aqua)
        let rep = try render(view, appearance: .aqua, dumpName: "trace-event-symbol-light")

        // The prompt badge occupies x=132...148/y=1...17. Restrict this probe to its inner symbol
        // box so the white outline cannot make a black template glyph look like a passing result.
        XCTAssertGreaterThan(
            brightPixelCount(
                rep,
                view,
                x: 136..<145,
                y: 4..<14,
                threshold: 0.78),
            3,
            "the Light blue badge must paint the configured white SF Symbol inside its border")
    }

    func testScrolledGuidanceBadgeDoesNotLeakIntoFrozenLaneGutter() throws {
        func scrolledChart(guidanceOffset: TimeInterval) -> (
            scrollView: NSScrollView,
            chart: AppKitAgentActivityChartView
        ) {
            let chart = makeChart(
                appearance: .aqua,
                size: NSSize(width: 1_200, height: 380),
                guidanceOffset: guidanceOffset)
            chart.fitsWidth = false
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 380))
            scrollView.hasHorizontalScroller = true
            scrollView.documentView = chart
            scrollView.layoutSubtreeIfNeeded()
            scrollView.contentView.scroll(to: NSPoint(x: 760, y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            chart.layoutSubtreeIfNeeded()
            return (scrollView, chart)
        }

        // At 9.2 seconds the guidance badge is under the frozen 132-point gutter after scrolling.
        // At 12.2 seconds it is in the visible plot. Both turns have the same event count and chrome,
        // so their gutter pixels must be identical.
        let hidden = scrolledChart(guidanceOffset: 9.2)
        let visible = scrolledChart(guidanceOffset: 12.2)
        let hiddenRep = try render(
            hidden.chart,
            appearance: .aqua,
            dumpName: "trace-guidance-behind-gutter")
        let visibleRep = try render(
            visible.chart,
            appearance: .aqua,
            dumpName: "trace-guidance-in-plot")
        withExtendedLifetime((hidden.scrollView, visible.scrollView)) {
            XCTAssertEqual(
                differingPixelCount(
                    hiddenRep,
                    visibleRep,
                    view: hidden.chart,
                    x: 760..<892,
                    y: 0..<18),
                0,
                "a guidance badge behind the frozen gutter must not remain visible through its chrome")
        }
    }

    /// A turn with no global events must leave the rail blank rather than drawing stray marks.
    func testEventRailStaysBlankWithoutEvents() throws {
        let view = AppKitAgentActivityChartView()
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 380)
        view.fitsWidth = true
        let summary = AgentActivityTurnSummary(
            id: "turn",
            startedAt: start,
            endedAt: start.addingTimeInterval(4),
            providerAccess: nil,
            modelID: nil,
            isTerminal: true,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        _ = view.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: [
                    .state(.model, turnID: "turn", at: start),
                    .state(.completed, turnID: "turn", at: start.addingTimeInterval(4)),
                ],
                summary: summary,
                aliases: [:],
                labels: [:]),
            now: summary.endedAt)
        view.layoutSubtreeIfNeeded()
        let rep = try render(view, appearance: .darkAqua, dumpName: "trace-events-empty")
        XCTAssertLessThan(
            contrast(rep, view, x: 300..<880, y: 0..<20), 0.10,
            "With no compaction or interjection the rail must stay empty")
    }

    // MARK: - ADR-004 draw benchmark

    /// ADR-004 requires a native *rendering* benchmark before any end-to-end speedup claim; the only
    /// measurement that existed covered trace construction, which is derived data rather than
    /// drawing. This measures a full draw of the shipping view at the persisted ledger limit.
    func testTraceDrawCostAtLedgerLimit() throws {
        let laneCount = 8
        var records: [AgentActivityRecord] = []
        var moment = start
        var index = 0
        while records.count < 1_600 {
            let agent = index % (laneCount + 1) == 0
                ? AgentActivityIdentity.root
                : AgentActivityIdentity.subagent("a\(index % laneCount)")
            records.append(.state(index.isMultiple(of: 2) ? .model : .tool, turnID: "turn", agentID: agent, at: moment))
            records.append(.tokens(turnID: "turn", agentID: agent, input: 900, cachedInput: 600, output: 40, at: moment))
            moment = moment.addingTimeInterval(0.25)
            index += 1
        }
        let summary = AgentActivityTurnSummary(
            id: "turn",
            startedAt: start,
            endedAt: moment,
            providerAccess: nil,
            modelID: nil,
            isTerminal: true,
            inputTokens: 900 * index,
            cachedInputTokens: 600 * index,
            outputTokens: 40 * index,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)

        let view = AppKitAgentActivityChartView()
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        view.fitsWidth = true
        _ = view.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: records,
                summary: summary,
                aliases: [:],
                labels: [:]),
            now: summary.endedAt)
        view.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        measure {
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: view.bounds, to: rep)
            }
        }
    }

    func testInterjectionMarkerUsesAdaptiveHighContrastPalette() throws {
        let view = AppKitAgentActivityChartView()
        let light = view.agentTraceEventMarkerPalette(
            kind: .interjection,
            appearance: try XCTUnwrap(NSAppearance(named: .aqua)))
        let dark = view.agentTraceEventMarkerPalette(
            kind: .interjection,
            appearance: try XCTUnwrap(NSAppearance(named: .darkAqua)))

        XCTAssertGreaterThan(colorContrast(light.fill, light.symbol), 4.5)
        XCTAssertGreaterThan(colorContrast(light.fill, light.stroke), 4.5)
        XCTAssertGreaterThan(colorContrast(light.fill, .white), 4.5)
        XCTAssertGreaterThan(colorContrast(dark.fill, dark.symbol), 4.5)
        XCTAssertGreaterThan(colorContrast(dark.fill, dark.stroke), 4.5)
        XCTAssertGreaterThan(colorContrast(dark.fill, .black), 4.5)
        XCTAssertLessThan(
            colorLuminance(light.fill),
            colorLuminance(dark.fill),
            "the marker flips polarity instead of reusing one low-contrast translucent teal")
    }

    func testInitialPromptUsesDistinctAdaptiveBlueMarker() throws {
        let view = AppKitAgentActivityChartView()
        let prompt = AgentActivityRecord.initialPrompt(
            "Start here",
            turnID: "turn",
            at: start)
        let light = view.agentTraceEventMarkerPalette(
            event: prompt,
            appearance: try XCTUnwrap(NSAppearance(named: .aqua)))
        let dark = view.agentTraceEventMarkerPalette(
            event: prompt,
            appearance: try XCTUnwrap(NSAppearance(named: .darkAqua)))
        let guidance = view.agentTraceEventMarkerPalette(
            kind: .interjection,
            appearance: try XCTUnwrap(NSAppearance(named: .darkAqua)))

        XCTAssertGreaterThan(colorContrast(light.fill, light.symbol), 4.5)
        XCTAssertGreaterThan(colorContrast(dark.fill, dark.symbol), 4.5)
        XCTAssertNotEqual(
            dark.fill.usingColorSpace(.sRGB),
            guidance.fill.usingColorSpace(.sRGB),
            "the opening prompt must not look like later guidance")
        XCTAssertEqual(view.agentTraceEventTitle(prompt), "Initial prompt")

        var legacy = AgentActivityRecord.interjection(
            "Older guidance",
            disposition: .delivered,
            turnID: "turn",
            at: start)
        legacy.userEventKind = nil
        XCTAssertEqual(view.agentTraceEventTitle(legacy), "User guidance")
    }

    func testHistoryReductionUsesDistinctMarkerTitleAndInspectableCounts() throws {
        let view = makeChart(appearance: .aqua)
        let rep = try render(
            view,
            appearance: .aqua,
            dumpName: "trace-history-reduction-light")
        let darkView = makeChart(appearance: .darkAqua)
        let darkRep = try render(
            darkView,
            appearance: .darkAqua,
            dumpName: "trace-history-reduction-dark")
        let event = try XCTUnwrap(
            view.renderModel.globalEvents.first {
                $0.contextEventKind == .historyReduction
            })
        XCTAssertEqual(
            view.agentTraceEventTitle(event),
            "History reduced · 3 messages omitted · 1 message shortened")
        XCTAssertEqual(view.agentTraceEventSymbolName(event), "text.badge.minus")

        let reduction = view.agentTraceEventMarkerPalette(
            event: event,
            appearance: try XCTUnwrap(NSAppearance(named: .aqua)))
        let darkReduction = view.agentTraceEventMarkerPalette(
            event: event,
            appearance: try XCTUnwrap(NSAppearance(named: .darkAqua)))
        let compactionEvent = try XCTUnwrap(
            view.renderModel.globalEvents.first { $0.kind == .compaction })
        let compaction = view.agentTraceEventMarkerPalette(
            event: compactionEvent,
            appearance: try XCTUnwrap(NSAppearance(named: .aqua)))
        XCTAssertNotEqual(
            reduction.fill.usingColorSpace(.sRGB),
            compaction.fill.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(colorContrast(reduction.fill, reduction.symbol), 4.5)
        XCTAssertGreaterThan(colorContrast(darkReduction.fill, darkReduction.symbol), 4.5)
        XCTAssertGreaterThan(
            contrast(rep, view, x: 584..<601, y: 0..<18),
            0.20,
            "the history-reduction badge must be visibly painted at its event-rail timestamp")
        XCTAssertGreaterThan(
            contrast(darkRep, darkView, x: 584..<601, y: 0..<18),
            0.20,
            "the history-reduction badge must remain visible in Dark Mode")

        // 8.5 seconds of a 14-second turn in the 758-point plot lands at x≈592.
        let lines = view.inspectionLines(at: NSPoint(x: 592, y: 8))
        XCTAssertEqual(
            lines.first,
            "History reduced · 3 messages omitted · 1 message shortened")

        let accessibilityLabels = (view.accessibilityChildren() as? [NSAccessibilityElement])?
            .compactMap { $0.accessibilityLabel() } ?? []
        XCTAssertTrue(accessibilityLabels.contains {
            $0.hasPrefix("History reduced")
                && $0.contains("3 messages omitted")
                && $0.contains("1 message shortened")
        })
    }

    func testUsageModeDoesNotExposeInvisibleTraceEventsToAccessibility() {
        let view = makeChart(appearance: .aqua)
        let traceLabels = (view.accessibilityChildren() as? [NSAccessibilityElement])?
            .compactMap { $0.accessibilityLabel() } ?? []
        XCTAssertTrue(traceLabels.contains { $0.hasPrefix("History reduced") })

        view.mode = .usage
        let usageLabels = (view.accessibilityChildren() as? [NSAccessibilityElement])?
            .compactMap { $0.accessibilityLabel() } ?? []
        XCTAssertFalse(usageLabels.contains { $0.hasPrefix("Initial prompt") })
        XCTAssertFalse(usageLabels.contains { $0.hasPrefix("Compaction") })
        XCTAssertFalse(usageLabels.contains { $0.hasPrefix("History reduced") })
        XCTAssertFalse(usageLabels.contains { $0.hasPrefix("User guidance") })
    }

    func testUsageTokenAnatomyPreservesMissingAndNeverOverplotsInput() {
        let missing = appKitActivityTokenAnatomy(records: [])
        XCTAssertNil(missing.inputTotal)
        XCTAssertNil(missing.cacheRead)
        XCTAssertNil(missing.cacheWrite)
        XCTAssertNil(missing.processed)

        let explicitZero = appKitActivityTokenAnatomy(records: [
            .tokens(
                turnID: "zero",
                input: 0,
                uncachedInput: 0,
                cachedInput: 0,
                cacheWriteInput: 0,
                output: 0,
                reasoningOutput: 0),
        ])
        XCTAssertEqual(explicitZero.inputTotal, 0)
        XCTAssertEqual(explicitZero.cacheWrite, 0)
        XCTAssertEqual(explicitZero.processed, 0)

        let overspecified = appKitActivityTokenAnatomy(records: [
            .tokens(
                turnID: "bounded",
                input: 100,
                cachedInput: 80,
                cacheWriteInput: 70,
                output: 20,
                reasoningOutput: 10),
        ])
        XCTAssertEqual(overspecified.plottedCacheRead, 80)
        XCTAssertEqual(overspecified.plottedCacheWrite, 20)
        XCTAssertEqual(overspecified.inputRemainder, 0)
        XCTAssertEqual(
            overspecified.inputRemainder! + overspecified.plottedCacheRead
                + overspecified.plottedCacheWrite,
            overspecified.inputTotal)
        XCTAssertEqual(overspecified.processed, 130)

        var provisional = AgentActivityRecord.tokens(
            turnID: "authoritative",
            input: 100,
            uncachedInput: 25,
            cachedInput: 75,
            output: 10)
        provisional.measurementAggregation = .delta
        var final = AgentActivityRecord.tokens(
            turnID: "authoritative",
            input: 120,
            uncachedInput: 30,
            cachedInput: 90,
            output: 12)
        final.measurementAggregation = .final
        let authoritative = appKitActivityTokenAnatomy(records: [provisional, final])
        XCTAssertEqual(authoritative.inputTotal, 120)
        XCTAssertEqual(authoritative.freshInput, 30)
        XCTAssertEqual(authoritative.cacheRead, 90)
        XCTAssertEqual(authoritative.answerOutput, 12)
    }

    func testLaneUsageUsesTheSameAuthoritativeSnapshotsAsTheHeadline() throws {
        let child = AgentActivityIdentity.subagent("child")
        let summary = AgentActivityTurnSummary(
            id: "authoritative-lanes",
            startedAt: start,
            endedAt: start.addingTimeInterval(5),
            providerAccess: .claudeSubscription,
            modelID: "claude-test",
            isTerminal: true,
            inputTokens: 200,
            cachedInputTokens: 0,
            outputTokens: 20,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        var rootDelta = AgentActivityRecord.tokens(
            turnID: summary.id,
            input: 100,
            output: 10,
            at: start.addingTimeInterval(1))
        rootDelta.measurementAggregation = .delta
        var childDelta = AgentActivityRecord.tokens(
            turnID: summary.id,
            agentID: child,
            input: 50,
            output: 5,
            at: start.addingTimeInterval(2))
        childDelta.measurementAggregation = .delta
        var treeFinal = AgentActivityRecord.tokens(
            turnID: summary.id,
            input: 200,
            output: 20,
            at: start.addingTimeInterval(4))
        treeFinal.measurementAggregation = .final
        treeFinal.measurementScope = .agentTree

        let model = AppKitAgentActivityRenderModel()
        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: [
                    .state(.model, turnID: summary.id, at: start),
                    rootDelta,
                    .state(.model, turnID: summary.id, agentID: child,
                           at: start.addingTimeInterval(1)),
                    childDelta,
                    treeFinal,
                    .state(.completed, turnID: summary.id, agentID: child,
                           at: summary.endedAt),
                    .state(.completed, turnID: summary.id, at: summary.endedAt),
                ],
                summary: summary,
                aliases: [:],
                labels: [child: "A1 · child"]),
            now: summary.endedAt)

        XCTAssertEqual(
            try XCTUnwrap(model.lanes.first { $0.id == AgentActivityIdentity.root }).usage.input,
            200)
        XCTAssertTrue(try XCTUnwrap(model.lanes.first { $0.id == child }).usage.isEmpty)
    }

    func testHarnessLanePrecedesRootAndCannotBecomeUsageOrCriticalPath() {
        let summary = AgentActivityTurnSummary(
            id: "harness-turn",
            startedAt: start,
            endedAt: start.addingTimeInterval(5),
            providerAccess: .codexSubscription,
            modelID: "gpt-test",
            isTerminal: true,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let records: [AgentActivityRecord] = [
            .harnessObservation(
                turnID: summary.id,
                lane: .codex,
                event: .phase,
                phase: .providerReady,
                provenance: .mechanicianClock,
                at: start),
            .state(.model, turnID: summary.id, at: start),
            .harnessObservation(
                turnID: summary.id,
                lane: .codex,
                event: .phase,
                phase: .firstOutput,
                provenance: .providerReport,
                at: start.addingTimeInterval(2)),
            .state(.completed, turnID: summary.id, at: summary.endedAt),
        ]
        let harnessSpans = appKitHarnessTraceSpans(records: records, summary: summary)
        XCTAssertFalse(harnessSpans.isEmpty)

        let model = AppKitAgentActivityRenderModel()
        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: records,
                summary: summary,
                aliases: [:],
                labels: [:],
                harnessSpans: harnessSpans),
            now: summary.endedAt)
        XCTAssertEqual(Array(model.lanes.prefix(2).map(\.id)), ["harness", "root"])
        XCTAssertTrue(harnessSpans.allSatisfy { !model.criticalSpanIDs.contains($0.span.id) })
        XCTAssertFalse(model.setUsageAgentID("harness"))
        XCTAssertNil(model.usageAgentID)
    }

    func testHarnessEventsAndToolsExposeSemanticsTimingAndCoverage() throws {
        let summary = AgentActivityTurnSummary(
            id: "semantic-harness",
            startedAt: start,
            endedAt: start.addingTimeInterval(5),
            providerAccess: .codexSubscription,
            modelID: "gpt-test",
            isTerminal: true,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        var tool = AgentActivityRecord.tool(
            "Bash",
            turnID: summary.id,
            agentID: AgentActivityIdentity.root,
            target: "swift test",
            outcome: .success,
            durationMs: 1_000,
            waitDurationMs: 250,
            executionDurationMs: 750,
            at: start)
        tool.measurementProvenance = .providerReport
        var retry = AgentActivityRecord.harnessObservation(
            turnID: summary.id,
            lane: .codex,
            event: .retry,
            provenance: .providerReport,
            at: start.addingTimeInterval(2))
        retry.retryAttempt = 2
        retry.retryMaxAttempts = 3
        retry.retryDelayMs = 500
        retry.httpStatusCode = 429
        var reroute = AgentActivityRecord.harnessObservation(
            turnID: summary.id,
            lane: .codex,
            event: .modelRerouted,
            provenance: .estimated,
            at: start.addingTimeInterval(3))
        reroute.rerouteOriginalModelID = "gpt-a"
        reroute.rerouteModelID = "gpt-b"
        reroute.rerouteReason = "capacity"
        reroute.measurementProvenance = nil
        let records: [AgentActivityRecord] = [
            .state(.tool, turnID: summary.id, detail: "Bash", at: start),
            tool,
            .state(.model, turnID: summary.id, at: start.addingTimeInterval(1)),
            retry,
            reroute,
            .state(.completed, turnID: summary.id, at: summary.endedAt),
        ]
        let view = AppKitAgentActivityChartView()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 230)
        view.laneGutterWidth = 132
        _ = view.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: records,
                summary: summary,
                aliases: [:],
                labels: [:]),
            now: summary.endedAt)
        let children = view.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        let root = try XCTUnwrap(children.first { $0.accessibilityLabel() == "Root agent" })
        let toolLabel = try XCTUnwrap(
            (root.accessibilityChildren() as? [NSAccessibilityElement])?
                .compactMap { $0.accessibilityLabel() }
                .first { $0.contains("tool duration") })
        XCTAssertTrue(toolLabel.contains("approval wait"))
        XCTAssertTrue(toolLabel.contains("outcome success"))
        XCTAssertTrue(toolLabel.contains("Reported by provider"))
        let eventLabels = children.compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(eventLabels.contains {
            $0.contains("Retry scheduled") && $0.contains("attempt 2 of 3")
                && $0.contains("HTTP 429")
        })
        XCTAssertTrue(eventLabels.contains {
            $0.contains("Model rerouted")
                && $0.contains("reroute reason capacity")
                && $0.contains("Measurement provenance — not reported")
        })
    }

    func testDurationTrendScaleUsesNiceMonotonicUnitLabeledTicks() {
        let zero = AppKitDurationTrendScale(observedMaximum: 0)
        XCTAssertEqual(zero.maximum, 1, accuracy: 0.0001)
        XCTAssertEqual(zero.step, 0.5, accuracy: 0.0001)
        XCTAssertEqual(zero.ticks, [0, 0.5, 1])
        XCTAssertEqual(zero.ticks.map(zero.label(for:)), ["0.0s", "0.5s", "1.0s"])

        let subsecond = AppKitDurationTrendScale(observedMaximum: 0.4)
        XCTAssertEqual(subsecond.maximum, 0.6, accuracy: 0.0001)
        XCTAssertEqual(subsecond.step, 0.2, accuracy: 0.0001)
        XCTAssertEqual(subsecond.ticks.count, 4)
        for (actual, expected) in zip(subsecond.ticks, [0, 0.2, 0.4, 0.6]) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001)
        }
        XCTAssertEqual(
            subsecond.ticks.map(subsecond.label(for:)),
            ["0ms", "200ms", "400ms", "600ms"])

        let minute = AppKitDurationTrendScale(observedMaximum: 65)
        XCTAssertEqual(minute.maximum, 100, accuracy: 0.0001)
        XCTAssertEqual(minute.step, 50, accuracy: 0.0001)
        XCTAssertEqual(minute.ticks, [0, 50, 100])
        XCTAssertEqual(minute.ticks.map(minute.label(for:)), ["0s", "50s", "1m 40s"])

        for scale in [zero, subsecond, minute] {
            XCTAssertEqual(scale.ticks.first, 0)
            XCTAssertEqual(scale.ticks.last, scale.maximum)
            XCTAssertTrue(zip(scale.ticks, scale.ticks.dropFirst()).allSatisfy(<))
            XCTAssertTrue(scale.ticks.map(scale.label(for:)).allSatisfy { label in
                label.contains("ms") || label.contains("s")
                    || label.contains("m") || label.contains("h")
            })
        }
    }

    func testDurationTrendTimeLabelsShowAllWideAndDoNotOverlapWhenNarrow() {
        XCTAssertEqual(
            appKitDurationTrendTimeLabelIndices(
                turnCount: 6,
                columnWidth: 80,
                selectedIndex: 3),
            [0, 1, 2, 3, 4, 5])

        let columnWidth: CGFloat = 20
        let minimumSpacing: CGFloat = 54
        let selectedIndex = 4
        let narrow = appKitDurationTrendTimeLabelIndices(
            turnCount: 8,
            columnWidth: columnWidth,
            selectedIndex: selectedIndex,
            minimumSpacing: minimumSpacing)

        XCTAssertEqual(narrow.first, 0)
        XCTAssertEqual(narrow.last, 7)
        XCTAssertTrue(narrow.contains(selectedIndex), "a selected label is retained when it fits")
        XCTAssertTrue(zip(narrow, narrow.dropFirst()).allSatisfy { lhs, rhs in
            CGFloat(rhs - lhs) * columnWidth >= minimumSpacing
        })

        let crowdedSelection = appKitDurationTrendTimeLabelIndices(
            turnCount: 8,
            columnWidth: columnWidth,
            selectedIndex: 1,
            minimumSpacing: minimumSpacing)
        XCTAssertEqual(crowdedSelection.first, 0)
        XCTAssertEqual(crowdedSelection.last, 7)
        XCTAssertFalse(
            crowdedSelection.contains(1),
            "a selected timestamp may be elided when it would collide with an endpoint")
        XCTAssertTrue(zip(crowdedSelection, crowdedSelection.dropFirst()).allSatisfy { lhs, rhs in
            CGFloat(rhs - lhs) * columnWidth >= minimumSpacing
        })
    }

    func testTrendsAreOldestFirstAndKeyboardSelectsProviderTurn() throws {
        func summary(_ id: String, offset: TimeInterval) -> AgentActivityTurnSummary {
            AgentActivityTurnSummary(
                id: id,
                startedAt: start.addingTimeInterval(offset),
                endedAt: start.addingTimeInterval(offset + 4),
                providerAccess: .codexSubscription,
                modelID: "gpt-test",
                isTerminal: true,
                inputTokens: 100,
                cachedInputTokens: 40,
                outputTokens: 10,
                reasoningOutputTokens: 5,
                aggregateOnlyTokens: 0)
        }
        let old = summary("old", offset: 0)
        let new = summary("new", offset: 20)
        var firstOutput = AgentActivityRecord.harnessObservation(
            turnID: old.id,
            lane: .codex,
            event: .phase,
            phase: .firstOutput,
            provenance: .providerReport,
            at: old.startedAt.addingTimeInterval(0.4))
        firstOutput.timeToFirstOutputMs = 400
        let trends = appKitAgentActivityTrendTurns(
            records: [firstOutput],
            summaries: [new, old])
        XCTAssertEqual(trends.map(\.id), ["old", "new"])
        XCTAssertEqual(try XCTUnwrap(trends.first?.ttft), 0.4, accuracy: 0.0001)

        let view = AppKitAgentActivityChartView()
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 190)
        view.laneGutterWidth = 132
        _ = view.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: [],
                summary: new,
                aliases: [:],
                labels: [:],
                trendTurns: trends,
                selectedTrendTurnID: old.id),
            now: new.endedAt)
        view.mode = .trends
        var selected: String?
        view.onSelectTrendTurnID = { selected = $0 }

        let initialChildren = view.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        let initialTurnLabels = initialChildren.compactMap { $0.accessibilityLabel() }.filter {
            $0.hasPrefix("Turn ") || $0.hasPrefix("Selected turn ")
        }
        XCTAssertEqual(initialTurnLabels.count, 2)
        XCTAssertTrue(initialTurnLabels[0].hasPrefix("Selected turn 1 of 2"))
        XCTAssertTrue(initialTurnLabels[0].contains("wall duration 4.0s"))
        XCTAssertTrue(initialTurnLabels[0].contains("first output 0.4s"))
        XCTAssertTrue(initialTurnLabels[1].hasPrefix("Turn 2 of 2"))
        XCTAssertTrue(initialTurnLabels[1].contains("wall duration 4.0s"))
        XCTAssertTrue(initialTurnLabels[1].contains("first output not reported"))
        let summary = try XCTUnwrap(view.accessibilityValue() as? String)
        XCTAssertTrue(summary.contains("selected turn 1"))
        XCTAssertTrue(summary.contains("wall duration 4.0s"))
        XCTAssertTrue(summary.contains("first output 0.4s"))

        XCTAssertTrue(view.moveTrendFocus(1))
        XCTAssertEqual(selected, new.id)
        let focused = try XCTUnwrap(view.accessibilityFocusedUIElement() as? NSAccessibilityElement)
        XCTAssertTrue(focused.accessibilityLabel()?.hasPrefix("Turn 2 of 2") == true)
        XCTAssertTrue(focused.accessibilityLabel()?.contains("first output not reported") == true)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: appearance)
            _ = try render(
                view,
                appearance: appearance,
                dumpName: "trace-trends-duration-\(appearance.rawValue)")
        }
    }

    func testRuntimeTrendLabelsProviderWideAggregatesAndMissingCoverage() throws {
        let summary = AgentActivityTurnSummary(
            id: "runtime",
            startedAt: start,
            endedAt: start.addingTimeInterval(4),
            providerAccess: .codexSubscription,
            modelID: "gpt-test",
            isTerminal: true,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let sample = try XCTUnwrap(HarnessMetricSample(
            name: "request.duration",
            kind: .histogram,
            at: start.addingTimeInterval(3),
            unit: .milliseconds,
            harnessLaneID: .codex,
            count: 4,
            sum: 1_000,
            min: 100,
            max: 400,
            attributes: [.provenance: .string("local_otlp")]))
        let daily = (1...12).compactMap { day in
            HarnessMetricSample(
                name: String(format: "codex.account.tokens.daily.2026-08-%02d", day),
                kind: .gauge,
                at: start.addingTimeInterval(Double(day)),
                unit: .tokens,
                harnessLaneID: .codex,
                value: Double(day * 1_000))
        }
        let view = AppKitAgentActivityChartView()
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 190)
        view.laneGutterWidth = 132
        _ = view.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: [],
                summary: summary,
                aliases: [:],
                labels: [:],
                runtimeSamples: [sample] + daily),
            now: summary.endedAt)
        view.mode = .trends
        view.trendMetric = .runtime
        let labels = (view.accessibilityChildren() as? [NSAccessibilityElement])?
            .compactMap { $0.accessibilityLabel() } ?? []
        XCTAssertTrue(labels.contains {
            $0.contains("Codex") && $0.contains("session-wide aggregate")
        })
        XCTAssertTrue(labels.contains { $0.contains("tokens.daily.recent") })
        XCTAssertFalse(labels.contains { $0.contains("2026-08-") })
        XCTAssertTrue(view.inspectionLines(at: NSPoint(x: 220, y: 75)).contains {
            $0.contains("not attributed")
        })
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: appearance)
            _ = try render(
                view,
                appearance: appearance,
                dumpName: "trace-trends-runtime-\(appearance.rawValue)")
        }

        _ = view.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: [],
                summary: summary,
                aliases: [:],
                labels: [:],
                runtimeSamples: []),
            now: summary.endedAt)
        let missingLabels = (view.accessibilityChildren() as? [NSAccessibilityElement])?
            .compactMap { $0.accessibilityLabel() } ?? []
        XCTAssertEqual(missingLabels, ["Harness metrics not reported for this session"])
    }

    func testHarnessMetricPresentationUsesFriendlySemanticCopy() throws {
        let week = try XCTUnwrap(HarnessMetricSample(
            name: "codex.account.rate_limits.primary.window_seconds.max",
            kind: .gauge,
            at: start,
            unit: .seconds,
            harnessLaneID: .codex,
            value: 7 * 24 * 60 * 60,
            attributes: [.scope: .string("account")]))
        let weekPresentation = appKitRuntimeMetricPresentation(week)
        XCTAssertEqual(weekPresentation.title, "Primary limit window")
        XCTAssertEqual(weekPresentation.value, "7d")
        XCTAssertTrue(weekPresentation.detail.contains("Latest gauge"))
        XCTAssertTrue(weekPresentation.detail.contains("Account"))
        XCTAssertFalse(weekPresentation.title.contains("codex"))

        let reached = try XCTUnwrap(HarnessMetricSample(
            name: "codex.account.rate_limits.reached.any",
            kind: .gauge,
            at: start,
            unit: .count,
            harnessLaneID: .codex,
            value: 1))
        let reachedPresentation = appKitRuntimeMetricPresentation(reached)
        XCTAssertEqual(reachedPresentation.title, "Rate limit reached")
        XCTAssertEqual(reachedPresentation.value, "Yes")
        XCTAssertEqual(reachedPresentation.detail, "Latest gauge")

        let clear = try XCTUnwrap(HarnessMetricSample(
            name: reached.name,
            kind: reached.kind,
            at: start,
            unit: reached.unit,
            harnessLaneID: reached.harnessLaneID,
            value: 0))
        XCTAssertEqual(appKitRuntimeMetricPresentation(clear).value, "No")

        let incompleteHistogram = try XCTUnwrap(HarnessMetricSample(
            name: "codex.request.duration",
            kind: .histogram,
            at: start,
            unit: .milliseconds,
            harnessLaneID: .codex,
            sum: 100,
            min: 0,
            max: 80))
        XCTAssertEqual(appKitRuntimeMetricPresentation(incompleteHistogram).value, "100ms total")

        let measuredSecond = try XCTUnwrap(HarnessMetricSample(
            name: "codex.turn.reached.duration",
            kind: .gauge,
            at: start,
            unit: .seconds,
            harnessLaneID: .codex,
            value: 1))
        XCTAssertEqual(appKitRuntimeMetricPresentation(measuredSecond).value, "1.0s")

        let qualified = try XCTUnwrap(HarnessMetricSample(
            name: "codex.request.count",
            kind: .counter,
            at: start,
            unit: .count,
            harnessLaneID: .codex,
            value: 1,
            attributes: [
                .retryAttempt: .number(2),
                .querySource: .string("tool"),
            ]))
        let qualifiedPresentation = appKitRuntimeMetricPresentation(qualified)
        XCTAssertTrue(qualifiedPresentation.fullDetail.contains("Retry attempt: 2"))
        XCTAssertTrue(qualifiedPresentation.fullDetail.contains("Query source: Tool"))
    }

    func testHarnessMetricTitleAndValueRectsNeverOverlapAtWideOrNarrowWidths() {
        let presentation = AppKitRuntimeMetricPresentation(
            title: "Individual limit remaining",
            value: "9/1/26, 12:23 PM",
            detail: "Latest gauge · Account",
            sortPriority: 0)

        for width: CGFloat in [180, 760] {
            let row = NSRect(x: 12, y: 7, width: width, height: width < 280 ? 41 : 35)
            let layout = appKitRuntimeMetricTextLayout(
                in: row,
                presentation: presentation)

            XCTAssertLessThanOrEqual(
                layout.title.maxX,
                layout.value.minX,
                "title and value must not collide at width \(width)")
            XCTAssertGreaterThanOrEqual(layout.title.minX, row.minX)
            XCTAssertLessThanOrEqual(layout.value.maxX, row.maxX)
            XCTAssertGreaterThanOrEqual(layout.detail.minX, row.minX)
            XCTAssertLessThanOrEqual(layout.detail.maxX, row.maxX)
        }
    }

    func testHarnessMetricKeyboardFocusDoesNotSelectAProviderTurn() throws {
        func summary(_ id: String, offset: TimeInterval) -> AgentActivityTurnSummary {
            AgentActivityTurnSummary(
                id: id,
                startedAt: start.addingTimeInterval(offset),
                endedAt: start.addingTimeInterval(offset + 4),
                providerAccess: .codexSubscription,
                modelID: "gpt-test",
                isTerminal: true,
                inputTokens: 0,
                cachedInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                aggregateOnlyTokens: 0)
        }
        let old = summary("old-runtime-turn", offset: 0)
        let selected = summary("selected-runtime-turn", offset: 20)
        let trends = appKitAgentActivityTrendTurns(records: [], summaries: [selected, old])
        let metrics = [
            HarnessMetricSample(
                name: "codex.tool.duration",
                kind: .histogram,
                at: start,
                unit: .milliseconds,
                harnessLaneID: .codex,
                count: 2,
                sum: 300,
                min: 100,
                max: 200),
            HarnessMetricSample(
                name: "codex.request.count",
                kind: .counter,
                at: start,
                unit: .count,
                harnessLaneID: .codex,
                value: 4),
        ].compactMap { $0 }
        XCTAssertEqual(metrics.count, 2)

        let view = AppKitAgentActivityChartView()
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 230)
        _ = view.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: [],
                summary: selected,
                aliases: [:],
                labels: [:],
                trendTurns: trends,
                selectedTrendTurnID: selected.id,
                runtimeSamples: metrics),
            now: selected.endedAt)
        view.mode = .trends
        view.trendMetric = .runtime
        var selectedTurnID: String?
        view.onSelectTrendTurnID = { selectedTurnID = $0 }

        XCTAssertEqual(view.focusedRuntimeMetricIndex, 0)
        XCTAssertTrue(view.moveTrendFocus(1))
        XCTAssertEqual(view.focusedRuntimeMetricIndex, 1)
        XCTAssertNil(selectedTurnID, "moving among session metrics must not select a turn")
        view.selectFocusedTrendTurn()
        XCTAssertNil(selectedTurnID, "pinning a session metric must not select a turn")

        let focused = try XCTUnwrap(
            view.accessibilityFocusedUIElement() as? NSAccessibilityElement)
        XCTAssertTrue(focused.accessibilityLabel()?.contains("session-wide aggregate") == true)
    }

    func testHarnessMetricInspectionHasNoTrackingLineAndEveryDismissPathWorks() throws {
        let summary = AgentActivityTurnSummary(
            id: "runtime-inspection",
            startedAt: start,
            endedAt: start.addingTimeInterval(4),
            providerAccess: .codexSubscription,
            modelID: "gpt-test",
            isTerminal: true,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let samples = [
            HarnessMetricSample(
                name: "codex.tool.duration",
                kind: .histogram,
                at: start,
                unit: .milliseconds,
                harnessLaneID: .codex,
                count: 2,
                sum: 300,
                min: 100,
                max: 200),
            HarnessMetricSample(
                name: "codex.request.count",
                kind: .counter,
                at: start,
                unit: .count,
                harnessLaneID: .codex,
                value: 4),
        ].compactMap { $0 }
        let view = AppKitAgentActivityChartView()
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 230)
        _ = view.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: [],
                summary: summary,
                aliases: [:],
                labels: [:],
                runtimeSamples: samples),
            now: summary.endedAt)
        view.mode = .trends
        view.trendMetric = .runtime

        let row = try XCTUnwrap(view.runtimeMetricFramesForTesting.first)
        let rowPoint = NSPoint(x: row.midX, y: row.midY)
        let backgroundPoint = NSPoint(x: view.bounds.minX + 1, y: view.bounds.maxY - 1)

        view.pointerMoved(to: backgroundPoint)
        XCTAssertFalse(view.hasVisibleInspectionForTesting)

        view.pointerMoved(to: rowPoint)
        XCTAssertTrue(view.hasVisibleInspectionForTesting)
        XCTAssertFalse(view.hasPinnedInspection)
        XCTAssertFalse(
            view.drawsInspectionTrackingLineForTesting,
            "Harness rows are categorical and must not reuse the timeline crosshair")
        view.pointerExited()
        XCTAssertFalse(view.hasVisibleInspectionForTesting)

        view.pointerPressed(at: rowPoint)
        XCTAssertTrue(view.hasPinnedInspection)
        XCTAssertFalse(view.drawsInspectionTrackingLineForTesting)
        XCTAssertNotNil(view.inspectionDismissRectForTesting)
        XCTAssertTrue(view.accessibilityHelp()?.contains("Escape to dismiss") == true)
        let dismiss = try XCTUnwrap(
            (view.accessibilityChildren() as? [NSAccessibilityElement])?.first(where: {
                $0.accessibilityRole() == .button
                    && $0.accessibilityLabel() == "Dismiss metric details"
            }))
        XCTAssertTrue(dismiss.accessibilityPerformPress())
        XCTAssertFalse(view.hasPinnedInspection)
        XCTAssertFalse(view.hasVisibleInspectionForTesting)

        view.pointerPressed(at: rowPoint)
        XCTAssertTrue(view.hasPinnedInspection)
        view.pointerPressed(at: rowPoint)
        XCTAssertFalse(view.hasPinnedInspection, "clicking the selected row again dismisses details")

        view.pointerPressed(at: rowPoint)
        XCTAssertTrue(view.hasPinnedInspection)
        view.pointerPressed(at: backgroundPoint)
        XCTAssertFalse(view.hasPinnedInspection)
        XCTAssertFalse(view.hasVisibleInspectionForTesting)
    }

    func testHarnessMetricHeightAndAccessibilityIncludeEveryPresentedRow() throws {
        let summary = AgentActivityTurnSummary(
            id: "runtime-many",
            startedAt: start,
            endedAt: start.addingTimeInterval(1),
            providerAccess: .codexSubscription,
            modelID: "gpt-test",
            isTerminal: true,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let samples = (0..<18).compactMap { index in
            HarnessMetricSample(
                name: "codex.request.variant_\(index).count",
                kind: .counter,
                at: start.addingTimeInterval(TimeInterval(index)),
                unit: .count,
                harnessLaneID: .codex,
                value: Double(index))
        }
        XCTAssertEqual(samples.count, 18)

        let view = AppKitAgentActivityChartView()
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 230)
        _ = view.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: [],
                summary: summary,
                aliases: [:],
                labels: [:],
                runtimeSamples: samples),
            now: summary.endedAt)
        view.mode = .trends
        view.trendMetric = .runtime

        XCTAssertGreaterThan(
            view.requiredHeight,
            view.bounds.height,
            "the chart should grow so metrics become scrollable instead of being silently omitted")
        let labels = (view.accessibilityChildren() as? [NSAccessibilityElement])?
            .compactMap { $0.accessibilityLabel() } ?? []
        XCTAssertEqual(labels.count, samples.count)
        for index in 0..<samples.count {
            XCTAssertTrue(labels.contains { $0.contains("exact metric \(samples[index].name)") })
        }
    }

    func testHarnessMetricRequiredHeightUsesTheProposedDocumentWidth() throws {
        let summary = AgentActivityTurnSummary(
            id: "runtime-responsive-height",
            startedAt: start,
            endedAt: start.addingTimeInterval(1),
            providerAccess: .codexSubscription,
            modelID: "gpt-test",
            isTerminal: true,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let samples = [AgentHarnessLaneID.claude, .codex].flatMap { lane in
            (0..<8).compactMap { index in
                HarnessMetricSample(
                    name: "\(lane.rawValue).request.variant_\(index).count",
                    kind: .counter,
                    at: start.addingTimeInterval(TimeInterval(index)),
                    unit: .count,
                    harnessLaneID: lane,
                    value: Double(index))
            }
        }
        let view = AppKitAgentActivityChartView()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 230)
        _ = view.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: [],
                summary: summary,
                aliases: [:],
                labels: [:],
                runtimeSamples: samples),
            now: summary.endedAt)
        view.mode = .trends
        view.trendMetric = .runtime

        let oneColumn = view.requiredHeight(forWidth: 620)
        let twoColumns = view.requiredHeight(forWidth: 900)

        XCTAssertGreaterThan(oneColumn, twoColumns)
        XCTAssertEqual(twoColumns, view.requiredHeight)

        view.layoutSubtreeIfNeeded()
        let wideElements = try XCTUnwrap(
            view.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(wideElements.count, samples.count)
        XCTAssertEqual(
            wideElements[0].accessibilityFrameInParentSpace().minY,
            wideElements[8].accessibilityFrameInParentSpace().minY,
            accuracy: 0.5)

        view.frame.size.width = 620
        view.layoutSubtreeIfNeeded()
        let narrowElements = try XCTUnwrap(
            view.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertGreaterThan(
            narrowElements[8].accessibilityFrameInParentSpace().minY,
            narrowElements[7].accessibilityFrameInParentSpace().maxY,
            "VoiceOver frames must follow the visual provider groups into one column")
    }

    func testRuntimeOnlySummaryKeepsSessionMetricsRenderableWithoutTurns() throws {
        XCTAssertNil(appKitRuntimeOnlySummary(samples: []))

        let earlier = try XCTUnwrap(HarnessMetricSample(
            name: "request.count",
            kind: .counter,
            at: start,
            unit: .count,
            harnessLaneID: .claude,
            value: 2))
        let later = try XCTUnwrap(HarnessMetricSample(
            name: "request.duration",
            kind: .histogram,
            at: start.addingTimeInterval(5),
            unit: .milliseconds,
            harnessLaneID: .claude,
            count: 2,
            sum: 500,
            min: 200,
            max: 300))

        let summary = try XCTUnwrap(appKitRuntimeOnlySummary(samples: [later, earlier]))
        XCTAssertEqual(summary.startedAt, earlier.at)
        XCTAssertEqual(summary.endedAt, later.at)
        XCTAssertTrue(summary.isTerminal)
        XCTAssertEqual(summary.inputTokens, 0)
        XCTAssertNil(summary.providerAccess)

        let view = AppKitAgentActivityChartView()
        _ = view.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: [],
                summary: summary,
                aliases: [:],
                labels: [:],
                runtimeSamples: [later, earlier]),
            now: later.at)
        view.mode = .trends
        view.trendMetric = .runtime
        let labels = (view.accessibilityChildren() as? [NSAccessibilityElement])?
            .compactMap { $0.accessibilityLabel() } ?? []
        XCTAssertTrue(labels.contains {
            $0.contains("Claude") && $0.contains("session-wide aggregate")
        })
    }

    func testRuntimeLatestSeriesKeepsSameTimestampMetricDimensionsDistinct() throws {
        let summary = AgentActivityTurnSummary(
            id: "runtime-dimensions",
            startedAt: start,
            endedAt: start.addingTimeInterval(1),
            providerAccess: .codexSubscription,
            modelID: "gpt-a",
            isTerminal: true,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let first = try XCTUnwrap(HarnessMetricSample(
            name: "codex.request.count",
            kind: .counter,
            at: start,
            unit: .count,
            harnessLaneID: .codex,
            value: 1,
            attributes: [.model: .string("gpt-a"), .success: .bool(true)]))
        let second = try XCTUnwrap(HarnessMetricSample(
            name: first.name,
            kind: first.kind,
            at: first.at,
            unit: first.unit,
            harnessLaneID: first.harnessLaneID,
            value: 2,
            attributes: [.success: .bool(true), .model: .string("gpt-b")]))
        let daily = ["gpt-a", "gpt-b"].flatMap { model in
            (30...31).compactMap { day in
                HarnessMetricSample(
                    name: "codex.account.tokens.daily.2026-08-\(day)",
                    kind: .gauge,
                    at: start,
                    unit: .tokens,
                    harnessLaneID: .codex,
                    value: Double(day),
                    attributes: [.model: .string(model)])
            }
        }

        let view = AppKitAgentActivityChartView()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 190)
        view.laneGutterWidth = 132
        _ = view.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: [],
                summary: summary,
                aliases: [:],
                labels: [:],
                runtimeSamples: [first, second] + daily),
            now: summary.endedAt)
        view.mode = .trends
        view.trendMetric = .runtime

        let labels = (view.accessibilityChildren() as? [NSAccessibilityElement])?
            .compactMap { $0.accessibilityLabel() } ?? []
        XCTAssertEqual(labels.filter { $0.contains("codex.request.count") }.count, 2)
        XCTAssertEqual(labels.filter { $0.contains("tokens.daily.recent") }.count, 2)
    }

    // MARK: - Trace key

    /// Runs of saturated pixels across the swatch row, each reported as how many distinct colours
    /// it contains. Grey marks and the 8-point labels are unsaturated, so they drop out; the ends of
    /// each run are trimmed because a rounded capsule antialiases into the backdrop there.
    private func swatchRuns(_ rep: NSBitmapImageRep, _ view: NSView) -> [Int] {
        let s = scale(rep, view)
        let row = Int(view.bounds.midY) * s
        var runs: [Int] = []
        var current: [NSColor] = []

        func flush() {
            defer { current = [] }
            let core = current.dropFirst(2).dropLast(2)
            guard !core.isEmpty else { return }
            runs.append(
                Set(core.map { color in
                    [color.redComponent, color.greenComponent, color.blueComponent]
                        .map { (($0 * 10).rounded() / 10).description }
                        .joined(separator: ",")
                }).count)
        }

        for px in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: px, y: row)?.usingColorSpace(.sRGB) else { continue }
            let components = [color.redComponent, color.greenComponent, color.blueComponent]
            let saturated = (components.max() ?? 0) - (components.min() ?? 0) > 0.15
            if saturated {
                current.append(color)
            } else {
                flush()
            }
        }
        flush()
        return runs
    }

    /// The key is painted, not composed from labelled subviews, so the colour-policy test cannot see
    /// whether the tool chip's bands actually reach the screen — a wrong clip would leave one flat
    /// colour and still satisfy it. This renders the strip and counts what is really there.
    func testTraceKeyPaintsTheToolMarkAsASpectrum() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let view = AppKitTraceLegendView()
            view.appearance = NSAppearance(named: name)
            view.frame = NSRect(x: 0, y: 0, width: 420, height: 20)
            let rep = try render(view, appearance: name, dumpName: "trace-legend-\(name.rawValue)")
            let runs = swatchRuns(rep, view)

            XCTAssertGreaterThanOrEqual(
                runs.max() ?? 0, 4,
                "\(name.rawValue): the tool chip must paint its bands, not one flat fill")
            XCTAssertTrue(
                runs.contains(1),
                "\(name.rawValue): single-colour marks must stay single, or the counter is just "
                    + "reading antialiasing")
        }
    }

    private func colorContrast(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let first = colorLuminance(lhs)
        let second = colorLuminance(rhs)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func colorLuminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : CGFloat(pow(Double((component + 0.055) / 1.055), 2.4))
        }
        return 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }
}

/// Tool identity and label placement are presentation contracts, not provider contracts.
///
/// Raw provider names still drive policy elsewhere. The trace derives a display name from the
/// command target, and only paints that complete name when it fits inside its own mark.
final class AgentTraceRenderTestsToolPresentation: XCTestCase {
    private let start = Date(timeIntervalSince1970: 15_000)

    private func toolSpans(
        _ calls: [(name: String, target: String?)]
    ) -> [AgentActivityTraceSpan] {
        var records: [AgentActivityRecord] = []
        for (index, call) in calls.enumerated() {
            let offset = Double(index) * 2
            records.append(.state(
                .tool,
                turnID: "turn",
                detail: call.name,
                at: start.addingTimeInterval(offset)))
            records.append(.tool(
                call.name,
                turnID: "turn",
                agentID: AgentActivityIdentity.root,
                target: call.target,
                at: start.addingTimeInterval(offset)))
            records.append(.state(
                .model,
                turnID: "turn",
                at: start.addingTimeInterval(offset + 1)))
        }
        let end = start.addingTimeInterval(Double(calls.count) * 2)
        records.append(.state(.completed, turnID: "turn", at: end))
        return agentActivityTraceSpans(records, start: start, end: end)
            .filter { $0.phase == .tool }
    }

    func testShellTargetsNameTheActualProgramsInTraceMetadata() {
        let calls: [(name: String, target: String?)] = [
            ("Bash", #"/bin/zsh -lc "rg --files""#),
            ("Bash", #"/bin/zsh -lc "git status --short""#),
            ("Bash", #"/bin/zsh -lc "sed -n '1,20p' File.swift""#),
            ("Bash", "bash -c 'find . -name AGENTS.md'"),
            ("Bash", #"/bin/zsh -lc "cd app && swift test""#),
        ]

        let spans = toolSpans(calls)

        XCTAssertEqual(spans.map(\.title), ["rg", "git", "sed", "find", "swift"])
        XCTAssertEqual(spans.map(\.toolNames), [["rg"], ["git"], ["sed"], ["find"], ["swift"]])
    }

    func testSpecificToolsAndDisplayFamiliesKeepUsefulNames() {
        let calls: [(name: String, target: String?)] = [
            ("Read", "AgentBridge.swift"),
            ("Grep", "usage_limit"),
            ("mcp__computer__ComputerScreenshot", nil),
            ("Agent", nil),
        ]

        XCTAssertEqual(
            toolSpans(calls).map(\.title),
            ["Read", "Grep", "computer", "Delegating"])
    }

    func testLabelPlacementRequiresTheWholeMeasuredTitleToFitInside() {
        XCTAssertEqual(
            traceSpanLabelPlacement(textWidth: 12, spanWidth: 20),
            .inside,
            "twelve points of text plus eight points of inset fits exactly")
        XCTAssertEqual(
            traceSpanLabelPlacement(textWidth: 12.01, spanWidth: 20),
            .hidden,
            "a title is never clipped or moved outside merely because it almost fits")
    }

    func testAdjacentNarrowToolMarksNeverRequestOutsideLabels() {
        let narrowMarks: [(text: CGFloat, span: CGFloat)] = [
            (9, 3),
            (11, 4),
            (14, 5),
            (18, 7),
            (22, 8),
        ]

        XCTAssertEqual(
            narrowMarks.map {
                traceSpanLabelPlacement(textWidth: $0.text, spanWidth: $0.span)
            },
            Array(repeating: .hidden, count: narrowMarks.count),
            "adjacent narrow marks remain visible bars; none emits text into its neighbour")
    }

    func testInvalidGeometryFailsClosed() {
        XCTAssertEqual(
            traceSpanLabelPlacement(textWidth: .infinity, spanWidth: 100),
            .hidden)
        XCTAssertEqual(
            traceSpanLabelPlacement(textWidth: 10, spanWidth: -.infinity),
            .hidden)
        XCTAssertEqual(
            traceSpanLabelPlacement(textWidth: -1, spanWidth: 100),
            .hidden)
    }
}

/// Mirrors the private trace geometry the assertions above reason about. Kept deliberately separate
/// so a change to the real layout does not silently rewrite the expectations.
enum TraceLayoutProbe {
    static let eventRailHeight: CGFloat = 34
    static let laneHeight: CGFloat = 58
    static let costTrackHeight: CGFloat = 40
}

/// The agent card's layout, exercised on the row kinds the running app never showed me.
///
/// The card refactor — a `cardRect` derived from the clip view, the disclosure chevron owning the
/// trailing edge, the stop button inboard of it, a height that varies with content — was only ever
/// driven by subagent rows. Workflow and workflow-agent rows take different `configure` paths, and
/// the stop button and chevron were once anchored to the same edge and drew on top of each other.
final class AgentCardLayoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 20_000)

    private func makeCell(width: CGFloat = 420) -> AppKitAgentTableCellView {
        let cell = AppKitAgentTableCellView()
        cell.frame = NSRect(x: 0, y: 0, width: width, height: 120)
        return cell
    }

    private func run(status: WorkflowStatus) -> WorkflowRun {
        var run = WorkflowRun(runKey: "r1")
        run.workflowName = "review-changes"
        run.description = "Review the working diff across four dimensions and verify each finding"
        run.status = status
        run.startedAt = now.addingTimeInterval(-45)
        run.runTaskId = "task-1"
        return run
    }

    private func agent() -> WorkflowAgent {
        WorkflowAgent(
            index: 2,
            label: "verify:correctness",
            phaseIndex: 1,
            phaseTitle: "Verify",
            state: .progress)
    }

    /// Every visible subview must sit inside the card, and no two controls may overlap.
    private func assertNoOverlap(
        _ cell: AppKitAgentTableCellView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        cell.layoutSubtreeIfNeeded()
        let visible = cell.subviews.filter { !$0.isHidden && !$0.frame.isEmpty }
        for view in visible {
            XCTAssertGreaterThanOrEqual(
                view.frame.minX, 0,
                "\(type(of: view)) starts left of the card", file: file, line: line)
            XCTAssertLessThanOrEqual(
                view.frame.maxX, cell.bounds.width + 0.5,
                "\(type(of: view)) runs past the card's trailing edge", file: file, line: line)
        }
        // Controls specifically: text fields may share a row, buttons and glyphs may not.
        let controls = visible.filter { $0 is NSButton || $0 is NSImageView }
        for (i, a) in controls.enumerated() {
            for b in controls.dropFirst(i + 1) where a.frame.intersects(b.frame) {
                XCTFail(
                    "\(type(of: a)) at \(a.frame) overlaps \(type(of: b)) at \(b.frame)",
                    file: file, line: line)
            }
        }
    }

    func testRunningWorkflowRowKeepsControlsApart() {
        let cell = makeCell()
        cell.configure(
            workflow: run(status: .running),
            expanded: true,
            compact: false,
            now: now,
            onStop: { _ in })
        assertNoOverlap(cell)
    }

    func testCompactWorkflowRowKeepsControlsApart() {
        let cell = makeCell()
        cell.configure(
            workflow: run(status: .running),
            expanded: false,
            compact: true,
            now: now,
            onStop: { _ in })
        assertNoOverlap(cell)
    }

    func testWorkflowAgentRowKeepsControlsApart() {
        let cell = makeCell()
        cell.configure(
            workflowAgent: agent(),
            run: run(status: .running),
            ordinal: 1,
            depth: 1,
            compact: false,
            now: now)
        assertNoOverlap(cell)
    }

    func testTerminalWorkflowRowHidesStopButNotContent() {
        let cell = makeCell()
        cell.configure(
            workflow: run(status: .completed),
            expanded: false,
            compact: false,
            now: now,
            onStop: { _ in })
        assertNoOverlap(cell)
    }

    /// A narrow inspector must not push content out of the card.
    func testNarrowCardStillContainsItsContent() {
        let cell = makeCell(width: 240)
        cell.configure(
            workflow: run(status: .running),
            expanded: true,
            compact: false,
            now: now,
            onStop: { _ in })
        assertNoOverlap(cell)
    }
}

/// The agent's task text has to survive all the way to the lane.
///
/// `AppKitAgentActivityLane.detail` was constructed as a literal `nil`, so the field existed, the
/// gutter and the hover readout both read it, and it was always empty — the trace could never say
/// what an agent had been asked to do.
final class AgentLaneDetailTests: XCTestCase {
    func testLaneCarriesTheAgentsTask() {
        let start = Date(timeIntervalSince1970: 30_000)
        let child = AgentActivityIdentity.subagent("a1")
        let summary = AgentActivityTurnSummary(
            id: "turn",
            startedAt: start,
            endedAt: start.addingTimeInterval(5),
            providerAccess: nil,
            modelID: nil,
            isTerminal: true,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let model = AppKitAgentActivityRenderModel()
        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: [
                    .state(.model, turnID: "turn", agentID: child, at: start),
                    .state(.completed, turnID: "turn", agentID: child, at: start.addingTimeInterval(5)),
                ],
                summary: summary,
                aliases: [:],
                labels: [child: "A1 · count files"],
                details: [child: "Count every Swift file under app/Sources and report the total"]),
            now: summary.endedAt)

        let lane = model.lanes.first { $0.id == child }
        XCTAssertEqual(lane?.label, "A1 · count files")
        XCTAssertEqual(
            lane?.detail,
            "Count every Swift file under app/Sources and report the total",
            "The lane must carry the unabridged task, not just its truncated label")
    }

    /// A lane with no task reported must stay nil rather than inventing one.
    func testLaneWithoutTaskHasNoDetail() {
        let start = Date(timeIntervalSince1970: 30_000)
        let summary = AgentActivityTurnSummary(
            id: "turn",
            startedAt: start,
            endedAt: start.addingTimeInterval(2),
            providerAccess: nil,
            modelID: nil,
            isTerminal: true,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let model = AppKitAgentActivityRenderModel()
        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: [
                    .state(.model, turnID: "turn", at: start),
                    .state(.completed, turnID: "turn", at: start.addingTimeInterval(2)),
                ],
                summary: summary,
                aliases: [:],
                labels: [:]),
            now: summary.endedAt)
        XCTAssertNil(model.lanes.first?.detail)
    }
}

/// The trace's accessibility contract.
///
/// The chart already exposed a tree of lane groups and span children, but every element was
/// frameless — VoiceOver could read the tree and had nothing to point at, no cursor rectangle and
/// no way to reach a span by position. Keyboard arrows also scrubbed by eight points rather than
/// moving between the marks that mean something, and never changed lane.
final class AgentTraceAccessibilityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 40_000)

    private func chart(width: CGFloat = 900) -> AppKitAgentActivityChartView {
        let child = AgentActivityIdentity.subagent("a1")
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", detail: "Reasoning", at: start),
            .state(.tool, turnID: "turn", detail: "Bash", at: start.addingTimeInterval(3)),
            .state(.model, turnID: "turn", at: start.addingTimeInterval(6)),
            .state(.model, turnID: "turn", agentID: child, at: start.addingTimeInterval(2)),
            .state(.tool, turnID: "turn", agentID: child, detail: "Read", at: start.addingTimeInterval(5)),
            .state(.completed, turnID: "turn", agentID: child, at: start.addingTimeInterval(9)),
            .compaction(
                turnID: "turn",
                trigger: "auto",
                preTokens: 180_000,
                postTokens: 38_000,
                at: start.addingTimeInterval(7)),
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(10)),
        ]
        let summary = AgentActivityTurnSummary(
            id: "turn",
            startedAt: start,
            endedAt: start.addingTimeInterval(10),
            providerAccess: nil,
            modelID: nil,
            isTerminal: true,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let view = AppKitAgentActivityChartView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: 320)
        view.fitsWidth = true
        _ = view.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: records,
                summary: summary,
                aliases: [:],
                labels: [child: "A1 · reader"],
                details: [child: "Read the bridge and report its line count"]),
            now: summary.endedAt)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func narrowShellToolChart() -> AppKitAgentActivityChartView {
        let end = start.addingTimeInterval(100)
        let summary = AgentActivityTurnSummary(
            id: "turn",
            startedAt: start,
            endedAt: end,
            providerAccess: nil,
            modelID: nil,
            isTerminal: true,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let view = AppKitAgentActivityChartView()
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 220)
        view.fitsWidth = true
        _ = view.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: [
                    .state(.model, turnID: "turn", at: start),
                    .state(.tool, turnID: "turn", detail: "Bash",
                           at: start.addingTimeInterval(50)),
                    .tool(
                        "Bash",
                        turnID: "turn",
                        agentID: AgentActivityIdentity.root,
                        target: #"/bin/zsh -lc "rg --files""#,
                        at: start.addingTimeInterval(50)),
                    .state(.model, turnID: "turn", at: start.addingTimeInterval(50.1)),
                    .state(.completed, turnID: "turn", at: end),
                ],
                summary: summary,
                aliases: [:],
                labels: [:]),
            now: end)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func laneElements(_ view: NSView) -> [NSAccessibilityElement] {
        (view.accessibilityChildren() as? [NSAccessibilityElement])?
            .filter { $0.accessibilityRole() == .group } ?? []
    }

    func testDetailedAccessibilityTreeIsLazyAndRefreshesOnDemand() {
        let view = chart()

        XCTAssertEqual(
            view.accessibilityTreeRebuildCount,
            0,
            "live ledger updates keep the cheap chart summary current without eagerly building every AX child")
        XCTAssertGreaterThanOrEqual(laneElements(view).count, 2)
        XCTAssertEqual(view.accessibilityTreeRebuildCount, 1)

        view.laneFilter = .rootOnly

        XCTAssertEqual(
            view.accessibilityTreeRebuildCount,
            1,
            "a visual refresh should only invalidate the detailed tree")
        XCTAssertEqual(laneElements(view).count, 1)
        XCTAssertEqual(view.accessibilityTreeRebuildCount, 2)
    }

    func testEveryElementCarriesALocatableFrame() throws {
        let view = chart()
        let lanes = laneElements(view)
        XCTAssertGreaterThanOrEqual(lanes.count, 2, "root and one delegated lane")
        for lane in lanes {
            XCTAssertFalse(
                lane.accessibilityFrameInParentSpace().isEmpty,
                "A lane VoiceOver cannot locate is a lane it cannot point at")
            let spans = try XCTUnwrap(lane.accessibilityChildren() as? [NSAccessibilityElement])
            XCTAssertFalse(spans.isEmpty, "each lane exposes its spans")
            for span in spans {
                XCTAssertFalse(span.accessibilityFrameInParentSpace().isEmpty)
            }
        }
    }

    /// Span labels must say when and how long, not merely what.
    func testSpanLabelsCarryTimingAndPhase() throws {
        let view = chart()
        let lane = try XCTUnwrap(laneElements(view).first)
        let spans = try XCTUnwrap(lane.accessibilityChildren() as? [NSAccessibilityElement])
        let label = try XCTUnwrap(spans.first?.accessibilityLabel())
        XCTAssertTrue(label.contains("starting"), "a span says when it began: \(label)")
        XCTAssertTrue(
            label.contains("s"),
            "a span says how long it lasted: \(label)")
    }

    /// A compaction has to report what it reclaimed — that is the whole point of the mark.
    func testCompactionAnnouncesWhatItReclaimed() throws {
        let view = chart()
        let statics = (view.accessibilityChildren() as? [NSAccessibilityElement])?
            .filter { $0.accessibilityRole() == .staticText } ?? []
        let compaction = statics.compactMap { $0.accessibilityLabel() }
            .first { $0.hasPrefix("Compaction") }
        let label = try XCTUnwrap(compaction)
        XCTAssertTrue(label.contains("down to"), "compaction states before and after: \(label)")
    }

    /// A tooltip timer can fire after an activity refresh removed the region it was waiting on.
    /// The chart itself remains a valid owner and safely rejects that stale tag.
    func testTooltipOwnerRemainsValidAcrossRegistrationRebuilds() {
        let view = chart()
        let traceToolTips = view.toolTipTextByTag
        XCTAssertFalse(traceToolTips.isEmpty)
        XCTAssertTrue(
            traceToolTips.values.contains { $0.contains("Read the bridge and report its line count") })
        for (tag, text) in traceToolTips {
            XCTAssertEqual(
                view.view(view, stringForToolTip: tag, point: .zero, userData: nil),
                text)
        }

        view.mode = .usage
        XCTAssertTrue(view.toolTipTextByTag.isEmpty)
        for tag in traceToolTips.keys {
            XCTAssertEqual(
                view.view(view, stringForToolTip: tag, point: .zero, userData: nil),
                "",
                "a delayed callback for a removed region must be harmless")
        }

        view.mode = .trace
        XCTAssertFalse(view.toolTipTextByTag.isEmpty)
        for (tag, text) in view.toolTipTextByTag {
            XCTAssertEqual(
                view.view(view, stringForToolTip: tag, point: .zero, userData: nil),
                text)
        }
    }

    /// The lane's full task reaches assistive technology even though the gutter cannot print it.
    func testLaneExposesItsTaskAsHelp() throws {
        let view = chart()
        let delegated = laneElements(view).first { $0.accessibilityLabel() == "A1 · reader" }
        XCTAssertEqual(
            try XCTUnwrap(delegated).accessibilityHelp(),
            "Read the bridge and report its line count")
    }

    /// Filtering to the root must filter what assistive technology reports too. The AX tree read
    /// the unfiltered model, so a hidden lane stayed announced.
    func testAccessibilityFollowsTheLaneFilter() {
        let view = chart()
        XCTAssertGreaterThanOrEqual(laneElements(view).count, 2)
        view.laneFilter = .rootOnly
        view.layoutSubtreeIfNeeded()
        _ = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        XCTAssertEqual(
            laneElements(view).count, 1,
            "A lane the chart is not drawing must not be announced")
    }

    /// Arrows move between marks and between lanes.
    func testKeyboardMovesSpanToSpanAndLaneToLane() {
        let view = chart()
        XCTAssertEqual(view.focusedLane, 0)
        XCTAssertEqual(view.focusedSpan, 0)

        XCTAssertTrue(view.moveFocus(laneDelta: 0, spanDelta: 1))
        XCTAssertEqual(view.focusedSpan, 1, "right moves to the next span")

        XCTAssertTrue(view.moveFocus(laneDelta: 1, spanDelta: 0))
        XCTAssertEqual(view.focusedLane, 1, "down moves to the next lane")
        XCTAssertEqual(view.focusedSpan, 0, "changing lane restarts at its first span")

        XCTAssertFalse(
            view.moveFocus(laneDelta: 0, spanDelta: -1),
            "left at the first span does not wrap")
        XCTAssertFalse(
            view.moveFocus(laneDelta: 1, spanDelta: 0),
            "down past the last lane does nothing")
    }

    /// Keyboard focus and the VoiceOver cursor must be the same span.
    func testFocusedElementTracksKeyboardFocus() throws {
        let view = chart()
        view.moveFocus(laneDelta: 1, spanDelta: 0)
        let focused = try XCTUnwrap(view.accessibilityFocusedUIElement() as? NSAccessibilityElement)
        let lane = try XCTUnwrap(laneElements(view).last)
        let spans = try XCTUnwrap(lane.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(focused.accessibilityLabel(), spans.first?.accessibilityLabel())
    }

    /// A label too narrow to paint is still available at every inspection surface.
    func testHiddenShellLabelRemainsAvailableToHoverKeyboardAndAccessibility() throws {
        let view = narrowShellToolChart()
        let lane = try XCTUnwrap(laneElements(view).first)
        let spans = try XCTUnwrap(lane.accessibilityChildren() as? [NSAccessibilityElement])
        let tool = try XCTUnwrap(spans.first {
            $0.accessibilityLabel()?.hasPrefix("rg,") == true
        })
        let frame = tool.accessibilityFrameInParentSpace()
        let textWidth = ceil(("rg" as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 6.5, weight: .medium),
        ]).width)
        XCTAssertEqual(
            traceSpanLabelPlacement(textWidth: textWidth, spanWidth: frame.width),
            .hidden,
            "the fixture must exercise a title that is absent from the painted mark")

        let point = NSPoint(x: frame.midX, y: frame.midY)
        XCTAssertEqual(view.inspectionLines(at: point).first, "rg")
        XCTAssertTrue(tool.accessibilityLabel()?.contains("rg") == true)

        XCTAssertTrue(view.moveFocus(laneDelta: 0, spanDelta: 1))
        let focused = try XCTUnwrap(
            view.accessibilityFocusedUIElement() as? NSAccessibilityElement)
        XCTAssertTrue(focused.accessibilityLabel()?.contains("rg") == true)
    }
}

/// The lane gutter is draggable.
///
/// It was a hard 132-point cap derived from the viewport, which is the reason an agent's task could
/// never be printed beside its name and had to live in a tooltip instead.
final class AgentTraceGutterTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 50_000)

    private func chart(width: CGFloat = 900) -> AppKitAgentActivityChartView {
        let summary = AgentActivityTurnSummary(
            id: "turn",
            startedAt: start,
            endedAt: start.addingTimeInterval(6),
            providerAccess: nil,
            modelID: nil,
            isTerminal: true,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let view = AppKitAgentActivityChartView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        view.fitsWidth = true
        _ = view.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: [
                    .state(.model, turnID: "turn", at: start),
                    .state(.completed, turnID: "turn", at: start.addingTimeInterval(6)),
                ],
                summary: summary,
                aliases: [:],
                labels: [:]),
            now: summary.endedAt)
        view.layoutSubtreeIfNeeded()
        return view
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "agentsTraceGutterWidth")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "agentsTraceGutterWidth")
        super.tearDown()
    }

    func testDraggingWidensTheGutter() {
        let view = chart()
        let before = view.gutterDividerRect().midX
        view.resizeGutter(toPointerX: 220)
        XCTAssertEqual(view.laneGutterWidth, 220)
        XCTAssertGreaterThan(
            view.gutterDividerRect().midX, before,
            "the divider follows the width it now reports")
    }

    func testGutterClampsToItsRange() {
        let view = chart()
        view.resizeGutter(toPointerX: 10)
        XCTAssertEqual(
            view.laneGutterWidth,
            AppKitAgentActivityChartView.minimumGutterWidth,
            "dragging past the left edge stops at the minimum")

        view.resizeGutter(toPointerX: 5_000)
        XCTAssertEqual(
            view.laneGutterWidth,
            AppKitAgentActivityChartView.maximumGutterWidth,
            "dragging past the right edge stops at the maximum")
    }

    /// However wide it has been dragged, the gutter must not squeeze the plot out of existence on a
    /// narrow inspector.
    func testGutterNeverTakesMoreThanHalfANarrowViewport() {
        let view = chart(width: 260)
        view.resizeGutter(toPointerX: 300)
        XCTAssertEqual(view.laneGutterWidth, 300)
        XCTAssertLessThanOrEqual(
            view.gutterDividerRect().midX, 260 * 0.5 + 1,
            "the drawn gutter is capped at half the viewport even when stored wider")
    }

    func testGutterWidthPersists() {
        let view = chart()
        view.resizeGutter(toPointerX: 190)
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: "agentsTraceGutterWidth") as? Double,
            190,
            "a width dragged in one session is the width the next one opens with")
    }
}

/// Which spans actually determined the turn's length.
///
/// A waterfall shows where time went; it does not say which of the overlapping bars *caused* the
/// total. These pin the answer, because the chart now draws it.
final class AgentCriticalPathTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 60_000)

    private func model(
        _ records: [AgentActivityRecord],
        endsAfter seconds: TimeInterval
    ) -> AppKitAgentActivityRenderModel {
        let summary = AgentActivityTurnSummary(
            id: "turn",
            startedAt: start,
            endedAt: start.addingTimeInterval(seconds),
            providerAccess: nil,
            modelID: nil,
            isTerminal: true,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let model = AppKitAgentActivityRenderModel()
        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: records.sorted { $0.at < $1.at },
                summary: summary,
                aliases: [:],
                labels: [:]),
            now: summary.endedAt)
        return model
    }

    private func spans(_ model: AppKitAgentActivityRenderModel, lane id: String)
        -> [AgentActivityTraceSpan] {
        (model.lanes.first { $0.id == id }?.spans ?? []).map(\.span)
    }

    /// The slowest of several parallel delegates is what the root waits for; the faster ones could
    /// have taken longer without costing the turn anything.
    func testSlowestParallelDelegateIsCritical() {
        let fast = AgentActivityIdentity.subagent("fast")
        let slow = AgentActivityIdentity.subagent("slow")
        let model = model([
            .state(.model, turnID: "turn", at: start),
            .state(.waiting, turnID: "turn", at: start.addingTimeInterval(1)),

            .state(.model, turnID: "turn", agentID: fast, at: start.addingTimeInterval(1)),
            .state(.completed, turnID: "turn", agentID: fast, at: start.addingTimeInterval(4)),

            .state(.model, turnID: "turn", agentID: slow, at: start.addingTimeInterval(1)),
            .state(.completed, turnID: "turn", agentID: slow, at: start.addingTimeInterval(9)),

            .state(.model, turnID: "turn", at: start.addingTimeInterval(9)),
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(10)),
        ], endsAfter: 10)

        let slowSpan = spans(model, lane: slow).first { !$0.phase.isTerminal }
        let fastSpan = spans(model, lane: fast).first { !$0.phase.isTerminal }
        XCTAssertTrue(
            model.criticalSpanIDs.contains(try! XCTUnwrap(slowSpan).id),
            "the delegate the root waits for is on the critical path")
        XCTAssertFalse(
            model.criticalSpanIDs.contains(try! XCTUnwrap(fastSpan).id),
            "a delegate that finished early did not determine the total")
    }

    /// With no delegates at all, the root's own work is the whole chain.
    func testRootOnlyTurnIsEntirelyCritical() {
        let model = model([
            .state(.model, turnID: "turn", at: start),
            .state(.tool, turnID: "turn", detail: "Bash", at: start.addingTimeInterval(2)),
            .state(.model, turnID: "turn", at: start.addingTimeInterval(5)),
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(8)),
        ], endsAfter: 8)

        let working = spans(model, lane: AgentActivityIdentity.root)
            .filter { !$0.phase.isTerminal && $0.duration > 0 }
        XCTAssertFalse(working.isEmpty)
        for span in working {
            XCTAssertTrue(
                model.criticalSpanIDs.contains(span.id),
                "with nothing running in parallel every root span gates the turn")
        }
    }

    /// The chain's total cannot exceed the turn, and should account for most of it when the turn is
    /// busy throughout.
    func testCriticalDurationIsBoundedByTheTurn() {
        let child = AgentActivityIdentity.subagent("c")
        let model = model([
            .state(.model, turnID: "turn", at: start),
            .state(.waiting, turnID: "turn", at: start.addingTimeInterval(1)),
            .state(.model, turnID: "turn", agentID: child, at: start.addingTimeInterval(1)),
            .state(.completed, turnID: "turn", agentID: child, at: start.addingTimeInterval(7)),
            .state(.model, turnID: "turn", at: start.addingTimeInterval(7)),
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(8)),
        ], endsAfter: 8)

        XCTAssertGreaterThan(model.criticalPathDuration, 0)
        XCTAssertLessThanOrEqual(
            model.criticalPathDuration, 8.001,
            "the chain cannot claim more time than the turn lasted")
    }

    /// An empty turn must not invent a path.
    func testEmptyTurnHasNoCriticalPath() {
        let model = model([], endsAfter: 1)
        XCTAssertTrue(model.criticalSpanIDs.isEmpty)
        XCTAssertEqual(model.criticalPathDuration, 0)
    }
}

/// Renders a turn whose critical path is unambiguous, so the marking can be inspected.
final class AgentCriticalPathRenderTests: XCTestCase {
    func testCriticalPathIsDrawnOnTheSlowestChain() throws {
        let start = Date(timeIntervalSince1970: 70_000)
        let fast = AgentActivityIdentity.subagent("fast")
        let slow = AgentActivityIdentity.subagent("slow")
        let mid = AgentActivityIdentity.subagent("mid")
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", detail: "Planning", at: start),
            .state(.waiting, turnID: "turn", at: start.addingTimeInterval(2)),

            .state(.model, turnID: "turn", agentID: fast, at: start.addingTimeInterval(2)),
            .state(.tool, turnID: "turn", agentID: fast, detail: "Bash", at: start.addingTimeInterval(3)),
            .state(.completed, turnID: "turn", agentID: fast, at: start.addingTimeInterval(6)),

            .state(.model, turnID: "turn", agentID: mid, at: start.addingTimeInterval(2)),
            .state(.tool, turnID: "turn", agentID: mid, detail: "Bash", at: start.addingTimeInterval(4)),
            .state(.completed, turnID: "turn", agentID: mid, at: start.addingTimeInterval(10)),

            .state(.model, turnID: "turn", agentID: slow, at: start.addingTimeInterval(2)),
            .state(.tool, turnID: "turn", agentID: slow, detail: "Bash", at: start.addingTimeInterval(5)),
            .state(.completed, turnID: "turn", agentID: slow, at: start.addingTimeInterval(24)),

            .state(.model, turnID: "turn", at: start.addingTimeInterval(24)),
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(26)),
        ]
        let summary = AgentActivityTurnSummary(
            id: "turn",
            startedAt: start,
            endedAt: start.addingTimeInterval(26),
            providerAccess: nil,
            modelID: nil,
            isTerminal: true,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)

        let view = AppKitAgentActivityChartView()
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 340)
        view.fitsWidth = true
        view.showsCriticalPath = true
        _ = view.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: records.sorted { $0.at < $1.at },
                summary: summary,
                aliases: [:],
                labels: [
                    fast: "A1 · fast",
                    mid: "A2 · middling",
                    slow: "A3 · slow",
                ]),
            now: summary.endedAt)
        view.layoutSubtreeIfNeeded()

        // The slow agent gates the turn; the other two finish inside its shadow.
        let slowSpans = (view.renderModel.lanes.first { $0.id == slow }?.spans ?? []).map(\.span)
        let fastSpans = (view.renderModel.lanes.first { $0.id == fast }?.spans ?? []).map(\.span)
        XCTAssertTrue(
            slowSpans.contains { view.renderModel.criticalSpanIDs.contains($0.id) },
            "the agent the root waits for is marked")
        XCTAssertFalse(
            fastSpans.contains { view.renderModel.criticalSpanIDs.contains($0.id) },
            "an agent that finished early is not")

        if let dir = ProcessInfo.processInfo.environment["MECHANICIAN_TRACE_RENDER_DUMP"],
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: view.bounds, to: rep)
            }
            try? rep.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: dir).appendingPathComponent("critical-path.png"))
        }
    }
}

/// Every card lays out identically regardless of where its cell sits.
///
/// The card rect was briefly derived from the enclosing clip view, so each cell's layout depended
/// on its own position in the hierarchy. Recycled cells disagreed — the same list rendered some
/// rows with a card origin of 8 and others of 2, leaving their icons and titles six points apart
/// while the cards themselves lined up.
final class AgentCardAlignmentTests: XCTestCase {
    private func cell(width: CGFloat = 420, offsetX: CGFloat) -> AppKitAgentTableCellView {
        let cell = AppKitAgentTableCellView()
        cell.frame = NSRect(x: offsetX, y: 0, width: width, height: 33)
        var run = WorkflowRun(runKey: "r")
        run.status = .running
        cell.configure(
            workflow: run,
            expanded: false,
            compact: true,
            now: Date(timeIntervalSince1970: 1),
            onStop: { _ in })
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    /// Two cells with identical content must place their content identically, wherever they sit.
    func testContentOriginDoesNotDependOnTheCellsPosition() throws {
        let atOrigin = cell(offsetX: 0)
        let offset = cell(offsetX: 6)

        let a = atOrigin.subviews.filter { !$0.isHidden && !$0.frame.isEmpty }.map(\.frame.minX)
        let b = offset.subviews.filter { !$0.isHidden && !$0.frame.isEmpty }.map(\.frame.minX)
        XCTAssertEqual(a.count, b.count)
        for (lhs, rhs) in zip(a.sorted(), b.sorted()) {
            XCTAssertEqual(
                lhs, rhs, accuracy: 0.01,
                "a cell's contents must not shift because the cell moved")
        }
    }

    /// And the leading content sits one gutter in, not at some inherited offset.
    func testLeadingContentStartsAtTheGutter() throws {
        let view = cell(offsetX: 0)
        let leading = try XCTUnwrap(
            view.subviews.filter { !$0.isHidden && !$0.frame.isEmpty }.map(\.frame.minX).min())
        XCTAssertGreaterThanOrEqual(leading, AgentCardMetrics.inset)
        XCTAssertLessThan(leading, AgentCardMetrics.inset + 24)
    }
}

/// Different inputs must draw differently.
///
/// The context chart scaled its y-axis to the sample peak, so the curve filled the plot in every
/// turn: one at 2% of its window and one at 95% rendered the same picture. No test could fail,
/// because each drew "correctly" — the defect was that the drawing could not distinguish its
/// inputs, and that is the shape of bug eyes are worst at noticing.
final class AgentRenderDifferentialTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 200_000)

    private func summary(seconds: TimeInterval) -> AgentActivityTurnSummary {
        AgentActivityTurnSummary(
            id: "turn",
            startedAt: start,
            endedAt: start.addingTimeInterval(seconds),
            providerAccess: nil,
            modelID: nil,
            isTerminal: true,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
    }

    private func chart(
        _ records: [AgentActivityRecord],
        seconds: TimeInterval,
        mode: AppKitAgentActivityVisualizationMode = .trace,
        labels: [String: String] = [:]
    ) -> AppKitAgentActivityChartView {
        let view = AppKitAgentActivityChartView()
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        view.fitsWidth = true
        view.mode = mode
        _ = view.rebuild(
            input: AppKitAgentActivityRenderInput(
                records: records.sorted { $0.at < $1.at },
                summary: summary(seconds: seconds),
                aliases: [:],
                labels: labels),
            now: start.addingTimeInterval(seconds))
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Share of pixels that differ between two renders of the same view size.
    private func difference(_ a: NSView, _ b: NSView) throws -> Double {
        func pixels(_ view: NSView) throws -> NSBitmapImageRep {
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: view.bounds, to: rep)
            }
            return rep
        }
        let lhs = try pixels(a)
        let rhs = try pixels(b)
        XCTAssertEqual(lhs.pixelsWide, rhs.pixelsWide)
        var differing = 0
        var total = 0
        for x in stride(from: 0, to: lhs.pixelsWide, by: 2) {
            for y in stride(from: 0, to: lhs.pixelsHigh, by: 2) {
                total += 1
                let p = lhs.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                let q = rhs.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                if abs((p?.redComponent ?? 0) - (q?.redComponent ?? 0)) > 0.02
                    || abs((p?.greenComponent ?? 0) - (q?.greenComponent ?? 0)) > 0.02
                    || abs((p?.blueComponent ?? 0) - (q?.blueComponent ?? 0)) > 0.02 {
                    differing += 1
                }
            }
        }
        return total == 0 ? 0 : Double(differing) / Double(total)
    }

    /// Two samples, because a single point has no area to fill and both pressures would then draw
    /// an equally empty chart — the fixture would pass the test for the wrong reason.
    private func context(_ tokens: Int) -> [AgentActivityRecord] {
        [
            .state(.model, turnID: "turn", at: start),
            .context(turnID: "turn", tokens: tokens, window: 200_000,
                     at: start.addingTimeInterval(2)),
            .context(turnID: "turn", tokens: tokens, window: 200_000,
                     at: start.addingTimeInterval(4)),
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(6)),
        ]
    }

    /// The regression this exists for: a nearly empty window and a nearly full one.
    func testContextPressureLooksDifferentWhenItIsDifferent() throws {
        let light = chart(context(4_000), seconds: 6, mode: .usage)
        let heavy = chart(context(190_000), seconds: 6, mode: .usage)
        let delta = try difference(light, heavy)
        XCTAssertGreaterThan(
            delta, 0.01,
            "2% and 95% of the context window must not draw the same picture (differed by \(delta))")
    }

    /// A turn with tool calls must not look like one without.
    func testAToolCallChangesTheTrace() throws {
        let quiet = chart([
            .state(.model, turnID: "turn", at: start),
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(10)),
        ], seconds: 10)
        let busy = chart([
            .state(.model, turnID: "turn", at: start),
            .state(.tool, turnID: "turn", detail: "Bash", at: start.addingTimeInterval(3)),
            .state(.model, turnID: "turn", at: start.addingTimeInterval(7)),
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(10)),
        ], seconds: 10)
        XCTAssertGreaterThan(try difference(quiet, busy), 0.01)
    }

    /// More agents must mean a visibly different chart.
    func testExtraLanesChangeTheTrace() throws {
        let child = AgentActivityIdentity.subagent("c1")
        let one = chart([
            .state(.model, turnID: "turn", at: start),
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(8)),
        ], seconds: 8)
        let two = chart([
            .state(.model, turnID: "turn", at: start),
            .state(.model, turnID: "turn", agentID: child, at: start.addingTimeInterval(1)),
            .state(.completed, turnID: "turn", agentID: child, at: start.addingTimeInterval(6)),
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(8)),
        ], seconds: 8, labels: [child: "A1 · worker"])
        XCTAssertGreaterThan(try difference(one, two), 0.02)
    }

    /// A failed agent must not render identically to a completed one.
    func testFailureLooksDifferentFromSuccess() throws {
        let child = AgentActivityIdentity.subagent("c1")
        func turn(_ ending: AgentActivityPhase) -> [AgentActivityRecord] {
            [
                .state(.model, turnID: "turn", at: start),
                .state(.model, turnID: "turn", agentID: child, at: start.addingTimeInterval(1)),
                .state(ending, turnID: "turn", agentID: child, at: start.addingTimeInterval(5)),
                .state(.completed, turnID: "turn", at: start.addingTimeInterval(8)),
            ]
        }
        let ok = chart(turn(.completed), seconds: 8, labels: [child: "A1 · worker"])
        let bad = chart(turn(.failed), seconds: 8, labels: [child: "A1 · worker"])
        XCTAssertGreaterThan(try difference(ok, bad), 0.0005)
    }

    /// The control: the same input twice must be pixel-identical, or the threshold above is noise.
    func testTheSameInputRendersIdentically() throws {
        let a = chart(context(50_000), seconds: 6, mode: .usage)
        let b = chart(context(50_000), seconds: 6, mode: .usage)
        XCTAssertEqual(try difference(a, b), 0, accuracy: 0.0001)
    }
}
