import AppKit
import XCTest
@testable import Mechanician

final class AppKitAgentsPanelTests: XCTestCase {
    @MainActor
    func testLiveTickerUsesDefaultModeAndSkipsInactiveApplication() {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-agents-inactive-tick-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        var subagent = SubagentRun(
            key: "inactive-tick-agent",
            subagentType: "Explore",
            task: "Keep the activity clock live")
        subagent.status = .running
        bridge.subagents = [subagent.key: subagent]
        var applicationIsActive = false
        let panel = AppKitAgentsPanelView(
            bridge: bridge,
            applicationIsActive: { applicationIsActive })
        defer {
            panel.shutdown()
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }

        XCTAssertEqual(AppKitAgentsPanelView.presentationRunLoopMode, .default)
        let inactiveBaseline = panel.debugCounters.timerOnlyRedraws
        panel.tickForTesting()
        XCTAssertEqual(panel.debugCounters.timerOnlyRedraws, inactiveBaseline)

        applicationIsActive = true
        panel.tickForTesting()
        XCTAssertEqual(panel.debugCounters.timerOnlyRedraws, inactiveBaseline + 1)
    }

    @MainActor
    func testBridgeReloadWaitsForDefaultModeDuringMenuTracking() {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-agents-menu-reload-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let panel = AppKitAgentsPanelView(
            bridge: bridge,
            liveActivityReloadDelay: 0,
            applicationIsActive: { true })
        defer {
            panel.shutdown()
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }

        let baseline = panel.debugCounters.listSnapshotRebuilds
        bridge.agentActivity = [
            .state(
                .completed,
                turnID: "menu-mode-turn",
                at: Date(timeIntervalSince1970: 1_000)),
        ]

        runMainRunLoop(in: .eventTracking, for: 0.1)
        XCTAssertEqual(panel.debugCounters.listSnapshotRebuilds, baseline)
        XCTAssertTrue(panel.hasPendingPresentationReloadForTesting)

        XCTAssertTrue(runMainRunLoop(in: .default, until: {
            panel.debugCounters.listSnapshotRebuilds == baseline + 1
        }))
        XCTAssertEqual(panel.debugCounters.listSnapshotRebuilds, baseline + 1)
        XCTAssertFalse(panel.hasPendingPresentationReloadForTesting)
    }

    @MainActor
    func testInactiveActivityBurstProducesOneCatchUpReloadOnActivation() {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-agents-activation-reload-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        var applicationIsActive = false
        let panel = AppKitAgentsPanelView(
            bridge: bridge,
            liveActivityReloadDelay: 0,
            applicationIsActive: { applicationIsActive })
        defer {
            panel.shutdown()
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }

        let baseline = panel.debugCounters.listSnapshotRebuilds
        bridge.agentActivity = [
            .state(.model, turnID: "inactive-turn", at: Date(timeIntervalSince1970: 1_100)),
        ]
        bridge.agentActivity.append(
            .state(.tool, turnID: "inactive-turn", at: Date(timeIntervalSince1970: 1_101)))
        bridge.agentActivity.append(
            .state(.completed, turnID: "inactive-turn", at: Date(timeIntervalSince1970: 1_102)))
        XCTAssertTrue(runMainRunLoop(in: .default, until: {
            panel.hasPendingPresentationReloadForTesting
        }))

        XCTAssertEqual(panel.debugCounters.listSnapshotRebuilds, baseline)
        XCTAssertTrue(panel.hasPendingPresentationReloadForTesting)

        applicationIsActive = true
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification,
            object: NSApplication.shared)
        XCTAssertTrue(runMainRunLoop(in: .default, until: {
            panel.debugCounters.listSnapshotRebuilds == baseline + 1
        }))

        XCTAssertEqual(panel.debugCounters.listSnapshotRebuilds, baseline + 1)
        XCTAssertFalse(panel.hasPendingPresentationReloadForTesting)
    }

    func testToolCompositionPaletteUsesAllSixMagicAndLasersRays() {
        XCTAssertEqual(MagicLaserSpectrum.sampledComponents.count, 6)
        XCTAssertEqual(MagicLaserSpectrum.meterColors.count, 6)

        let darkAppearance = NSAppearance(named: .darkAqua)!
        for (color, sample) in zip(
            MagicLaserSpectrum.meterColors,
            MagicLaserSpectrum.sampledComponents
        ) {
            let resolved = resolve(color, in: darkAppearance)
            let source = NSColor(
                srgbRed: sample.r,
                green: sample.g,
                blue: sample.b,
                alpha: 1)
            var distance = abs(Double(resolved.hueComponent) - Double(source.hueComponent))
            distance = min(distance, 1 - distance)
            XCTAssertLessThan(
                distance,
                0.035,
                "appearance tuning may change brightness, not the logo ray's hue")
        }
    }

    func testToolCompositionPaletteRemainsVisibleOnCardsInBothAppearances() {
        let appearances: [(NSAppearance, NSColor)] = [
            (NSAppearance(named: .aqua)!, .white),
            (
                NSAppearance(named: .darkAqua)!,
                NSColor(srgbRed: 0.137, green: 0.141, blue: 0.153, alpha: 1)
            ),
        ]

        for (appearance, card) in appearances {
            for (index, color) in MagicLaserSpectrum.meterColors.enumerated() {
                let minimumContrast = appearance.name == .aqua && index == 1
                    ? 1.9
                    : 3.0
                XCTAssertGreaterThanOrEqual(
                    contrastBetween(resolve(color, in: appearance), card),
                    minimumContrast,
                    "brand rays must remain legible as bounded meter keys")
            }
        }
    }

    func testLightActivityBlueIsLiftedAndGoldReadsAsYellowRatherThanMustard() {
        let appearance = NSAppearance(named: .aqua)!
        let gold = resolve(MagicLaserSpectrum.meterColors[1], in: appearance)
        let blue = resolve(MagicLaserSpectrum.meterColors[5], in: appearance)
        let logoGold = MagicLaserSpectrum.sampledComponents[1]

        XCTAssertEqual(Double(gold.redComponent), logoGold.r, accuracy: 0.005)
        XCTAssertEqual(Double(gold.greenComponent), logoGold.g, accuracy: 0.005)
        XCTAssertEqual(Double(gold.blueComponent), logoGold.b, accuracy: 0.005)
        XCTAssertGreaterThan(gold.brightnessComponent, 0.90)
        XCTAssertGreaterThan(gold.hueComponent, 0.11)
        XCTAssertLessThan(gold.hueComponent, 0.14)
        XCTAssertGreaterThan(blue.brightnessComponent, 0.85)
        XCTAssertGreaterThanOrEqual(contrastBetween(blue, .white), 4.5)
    }

    func testUsagePlotExcludesCachedInputFromNewTokenBars() {
        let plotted = appKitUsagePlottedTokens(AgentActivityTokenBreakdown(
            input: 10_000,
            cachedInput: 9_600,
            output: 250,
            reasoningOutput: 150,
            unclassified: 75))

        XCTAssertEqual(plotted.input, 475)
        XCTAssertEqual(plotted.generated, 400)
        XCTAssertEqual(plotted.total, 875)
    }

    func testContextGraphUsesTheFixedActivityBlueInsteadOfTheSystemAccent() {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: appearanceName)!
            let context = resolve(appKitAgentActivityContextColor(), in: appearance)
            let input = resolve(appKitAgentActivityPhaseColor(.model), in: appearance)

            XCTAssertEqual(context.redComponent, input.redComponent, accuracy: 0.005)
            XCTAssertEqual(context.greenComponent, input.greenComponent, accuracy: 0.005)
            XCTAssertEqual(context.blueComponent, input.blueComponent, accuracy: 0.005)
            XCTAssertGreaterThan(context.blueComponent, context.redComponent)
        }
    }

    func testCachedInputTrackUsesAQuietLightBlueInsteadOfGold() {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: appearanceName)!
            let cached = resolve(
                appKitAgentActivityCachedInputColor(in: appearance),
                in: appearance)
            let input = resolve(appKitAgentActivityPhaseColor(.model), in: appearance)

            XCTAssertEqual(cached.hueComponent, input.hueComponent, accuracy: 0.01)
            XCTAssertGreaterThan(cached.blueComponent, cached.redComponent)
            XCTAssertLessThan(
                cached.alphaComponent,
                0.4,
                "cache should remain a quiet backing series rather than a dominant block")
        }
    }

    func testCommonSixSegmentToolBarUsesEveryBrandRayIncludingOther() {
        let appearance = NSAppearance(named: .aqua)!
        let colors = appKitToolCompositionColors(
            forTools: ["Edit", "sed", "rg", "swift", "git", "other"])
            .map { resolve($0, in: appearance) }
        XCTAssertEqual(colors.count, 6)

        let unique = Set(colors.map {
            String(
                format: "%.3f/%.3f/%.3f",
                $0.redComponent,
                $0.greenComponent,
                $0.blueComponent)
        })
        XCTAssertEqual(
            unique.count,
            6,
            "the residue must take the last brand ray instead of turning grey")
    }

    func testTimelineUsesTheSameSixBrandRaysAsAgentCards() {
        let phases: [AgentActivityPhase] = [
            .completed, .stopped, .tool, .failed, .compacting, .model,
        ]
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: appearanceName)!
            let expected = MagicLaserSpectrum.meterColors.map {
                resolve($0, in: appearance)
            }
            let actual = phases.map {
                resolve(appKitAgentActivityPhaseColor($0), in: appearance)
            }
            for (lhs, rhs) in zip(actual, expected) {
                XCTAssertEqual(lhs.redComponent, rhs.redComponent, accuracy: 0.001)
                XCTAssertEqual(lhs.greenComponent, rhs.greenComponent, accuracy: 0.001)
                XCTAssertEqual(lhs.blueComponent, rhs.blueComponent, accuracy: 0.001)
            }
        }
    }

    func testTimelineUsesWhiteInkForEveryLabeledPhase() {
        let phases: [AgentActivityPhase] = [.model, .tool, .waiting, .compacting]
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: appearanceName)!
            let background = resolve(.nElevated, in: appearance)
            for phase in phases {
                let ink = resolve(
                    appKitAgentActivitySpanLabelColor(
                        phase,
                        background: background,
                        appearance: appearance),
                    in: appearance)
                let expected = resolve(.white, in: appearance)
                XCTAssertEqual(ink.redComponent, expected.redComponent, accuracy: 0.01)
                XCTAssertEqual(ink.greenComponent, expected.greenComponent, accuracy: 0.01)
                XCTAssertEqual(ink.blueComponent, expected.blueComponent, accuracy: 0.01)
            }
        }
    }

    func testFlatMeterPaletteIsDeeperAndMoreSaturatedThanTheGlowPalette() {
        let appearance = NSAppearance(named: .darkAqua)!
        let meters = MagicLaserSpectrum.resolvedColors(
            MagicLaserSpectrum.meterColors,
            in: appearance)
        let glow = MagicLaserSpectrum.resolvedColors(in: appearance)

        XCTAssertEqual(meters.count, glow.count)
        for (meter, luminous) in zip(meters, glow) {
            XCTAssertGreaterThan(
                meter.saturationComponent,
                luminous.saturationComponent + 0.04,
                "flat meter rails should not regress to the outline's pastel glow colors")
            XCTAssertLessThanOrEqual(
                meter.brightnessComponent,
                luminous.brightnessComponent,
                "flat meter rails should remain deeper than the interpolated outline")
        }
    }

    func testMechanicianSpinnerUsesThreeDistinctNonTerminalBrandAnchors() {
        let spinner = MagicLaserSpectrum.spinnerColors
        let expected = [1, 4, 5].map { MagicLaserSpectrum.colors[$0] }
        XCTAssertEqual(spinner.count, 3)
        for (spinnerColor, brandColor) in zip(spinner, expected) {
            XCTAssertTrue(spinnerColor === brandColor)
        }

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: appearanceName)!
            let uniqueColors = Set(
                MagicLaserSpectrum.resolvedColors(spinner, in: appearance).map {
                    let color = $0.usingColorSpace(.sRGB)!
                    return String(
                        format: "%.3f/%.3f/%.3f",
                        color.redComponent,
                        color.greenComponent,
                        color.blueComponent)
                })
            XCTAssertEqual(uniqueColors.count, 3)
        }
    }

    func testMechanicianSpinnerPaintFitsEveryAdvertisedCompactDiameter() {
        for diameter: CGFloat in [11, 12, 13, 14, 15, 17, 18, 20] {
            let geometry = OrbitingDotsGeometry.fitted(to: diameter)
            XCTAssertLessThanOrEqual(
                geometry.maximumPaintedRadius,
                diameter / 2,
                "The \(diameter)pt spinner must not rely on a caller disabling clipping.")
            XCTAssertGreaterThan(geometry.coreDiameter, 0)
            if diameter <= 13 {
                XCTAssertGreaterThanOrEqual(
                    geometry.coreDiameter,
                    2,
                    "Every colored core must remain visible at \(diameter)pt.")
            }
            XCTAssertGreaterThan(geometry.orbitRadius, 0)
        }
    }

    func testListSnapshotGroupsTreeRootsAndHonorsFoldStateDeterministically() {
        let start = Date(timeIntervalSince1970: 1_000)
        var parent = SubagentRun(
            key: "parent",
            subagentType: "planner",
            task: "Plan the work")
        parent.startedAt = start
        parent.status = .completed

        var child = SubagentRun(
            key: "child",
            subagentType: "builder",
            task: "Implement the panel")
        child.startedAt = start.addingTimeInterval(1)
        child.parentToolUseId = parent.key
        child.status = .running

        var failed = SubagentRun(
            key: "failed",
            subagentType: "reviewer",
            task: "Review the panel")
        failed.startedAt = start.addingTimeInterval(2)
        failed.status = .failed

        var completed = SubagentRun(
            key: "completed",
            subagentType: "tester",
            task: "Run the tests")
        completed.startedAt = start.addingTimeInterval(3)
        completed.status = .completed

        let first = AppKitAgentsListSnapshot.make(
            subagents: [
                completed.key: completed,
                child.key: child,
                failed.key: failed,
                parent.key: parent,
            ],
            workflowRuns: [:],
            search: "",
            attentionExpanded: true,
            completedExpanded: false)
        let reordered = AppKitAgentsListSnapshot.make(
            subagents: [
                parent.key: parent,
                failed.key: failed,
                child.key: child,
                completed.key: completed,
            ],
            workflowRuns: [:],
            search: "",
            attentionExpanded: true,
            completedExpanded: false)

        XCTAssertEqual(first, reordered)
        XCTAssertEqual(first.activeCount, 2)
        XCTAssertEqual(first.attentionCount, 1)
        XCTAssertEqual(first.completedCount, 1)
        XCTAssertEqual(first.items, [
            .group(.active, count: 2, expanded: true),
            .subagent(key: "parent", depth: 0),
            .subagent(key: "child", depth: 1),
            .group(.attention, count: 1, expanded: true),
            .subagent(key: "failed", depth: 0),
            .group(.completed, count: 1, expanded: false),
        ])
    }

    func testNestedAgentIndentsTheCompleteCardOnceAndKeepsItsTrailingEdgeAligned() {
        let bounds = NSRect(x: 0, y: 0, width: 420, height: 80)
        let parent = appKitAgentCardRect(in: bounds, depth: 0)
        let child = appKitAgentCardRect(in: bounds, depth: 1)
        let grandchild = appKitAgentCardRect(in: bounds, depth: 2)

        XCTAssertEqual(child.minX - parent.minX, AgentCardMetrics.hierarchyIndent)
        XCTAssertEqual(grandchild.minX - child.minX, AgentCardMetrics.hierarchyIndent)
        XCTAssertEqual(parent.maxX, child.maxX)
        XCTAssertEqual(child.maxX, grandchild.maxX)
        XCTAssertEqual(parent.width - child.width, AgentCardMetrics.hierarchyIndent)
        XCTAssertEqual(child.width - grandchild.width, AgentCardMetrics.hierarchyIndent)

        // Content begins at a fixed inset inside each outline. It therefore advances by exactly
        // one hierarchy step—not the two steps produced by indenting both card and contents.
        XCTAssertEqual(
            (child.minX + 10) - (parent.minX + 10),
            AgentCardMetrics.hierarchyIndent)
    }

    @MainActor
    func testProductionListKeepsCardsInsideViewportAtWideAndMinimumWidths() throws {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-agent-list-geometry-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        var subagent = SubagentRun(
            key: "geometry-agent",
            subagentType: "Explore",
            task: "Verify the production card remains inside its scrolling viewport")
        subagent.status = .running
        bridge.subagents = [subagent.key: subagent]

        let panel = AppKitAgentsPanelView(bridge: bridge)
        defer {
            panel.shutdown()
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }

        func assertContained(
            _ geometry: AppKitAgentsListGeometrySnapshot,
            width: CGFloat,
            afterScrollToVisible: Bool,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let state = afterScrollToVisible ? "after scrollToVisible" : "before scrolling"
            XCTAssertEqual(
                geometry.clipBounds.minX,
                0,
                accuracy: 0.5,
                "the hidden horizontal axis must stay at its origin at \(width)pt \(state)",
                file: file,
                line: line)
            XCTAssertLessThanOrEqual(
                geometry.documentFrame.width,
                geometry.clipBounds.width + 0.5,
                "the production table must not create a horizontal scroll range at \(width)pt",
                file: file,
                line: line)
            XCTAssertGreaterThanOrEqual(
                geometry.cellFrameInDocument.minX,
                geometry.viewportInDocument.minX - 0.5,
                file: file,
                line: line)
            XCTAssertLessThanOrEqual(
                geometry.cellFrameInDocument.maxX,
                geometry.viewportInDocument.maxX + 0.5,
                file: file,
                line: line)
            XCTAssertEqual(
                geometry.cardFrameInDocument.minX - geometry.viewportInDocument.minX,
                AgentCardMetrics.inset,
                accuracy: 0.5,
                "the leading card gutter must remain visible at \(width)pt \(state)",
                file: file,
                line: line)
            XCTAssertEqual(
                geometry.viewportInDocument.maxX - geometry.cardFrameInDocument.maxX,
                AgentCardMetrics.inset,
                accuracy: 0.5,
                "the trailing card gutter must remain visible at \(width)pt \(state)",
                file: file,
                line: line)
        }

        for width: CGFloat in [420, 180] {
            panel.frame = NSRect(x: 0, y: 0, width: width, height: 640)
            panel.layoutSubtreeIfNeeded()

            let initial = try XCTUnwrap(panel.listGeometryForTesting())
            assertContained(initial, width: width, afterScrollToVisible: false)

            let scrolled = try XCTUnwrap(
                panel.listGeometryForTesting(scrollingCellToVisible: true))
            assertContained(scrolled, width: width, afterScrollToVisible: true)
        }
    }

    func testListSnapshotSearchesAgentAndWorkflowContent() {
        var subagent = SubagentRun(
            key: "agent",
            subagentType: "Explore",
            task: "Inspect rendering")
        subagent.status = .completed
        var workflow = WorkflowRun(runKey: "workflow")
        workflow.workflowName = "Release"
        workflow.description = "Publish documentation"
        workflow.status = .completed

        let snapshot = AppKitAgentsListSnapshot.make(
            subagents: [subagent.key: subagent],
            workflowRuns: [workflow.runKey: workflow],
            search: "publish",
            attentionExpanded: true,
            completedExpanded: true)

        XCTAssertEqual(snapshot.unfilteredCount, 2)
        XCTAssertEqual(snapshot.completedCount, 1)
        XCTAssertEqual(snapshot.items, [
            .group(.completed, count: 1, expanded: true),
            .workflow(key: "workflow", expanded: false),
        ])
    }

    func testExpandedWorkflowAddsDeterministicPerAgentRows() {
        var workflow = WorkflowRun(runKey: "workflow")
        workflow.status = .running
        workflow.agents = [
            "later": WorkflowAgent(
                index: 2,
                label: "Later",
                phaseIndex: 1,
                phaseTitle: "Build",
                state: .progress),
            "first": WorkflowAgent(
                index: 1,
                label: "First",
                phaseIndex: 0,
                phaseTitle: "Plan",
                state: .done),
        ]

        let snapshot = AppKitAgentsListSnapshot.make(
            subagents: [:],
            workflowRuns: [workflow.runKey: workflow],
            search: "",
            attentionExpanded: true,
            completedExpanded: false,
            expandedWorkflowKeys: [workflow.runKey])

        XCTAssertEqual(snapshot.items, [
            .group(.active, count: 1, expanded: true),
            .workflow(key: "workflow", expanded: true),
            .workflowAgent(runKey: "workflow", agentKey: "0:1", ordinal: 1, depth: 1),
            .workflowAgent(runKey: "workflow", agentKey: "1:2", ordinal: 2, depth: 1),
        ])
    }

    @MainActor
    func testLargeFailedWorkflowActivityReloadReusesAgentOrderingAndOrdinals() async {
        _ = NSApplication.shared
        let compactKey = "agentsCompactRows"
        let timelineKey = "agentsActivityTimelineShown"
        let previousCompact = UserDefaults.standard.object(forKey: compactKey)
        let previousTimeline = UserDefaults.standard.object(forKey: timelineKey)
        UserDefaults.standard.set(false, forKey: compactKey)
        UserDefaults.standard.set(false, forKey: timelineKey)

        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-large-workflow-ordering-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let now = Date(timeIntervalSince1970: 1_700)
        let agentCount = 290
        var agents: [String: WorkflowAgent] = [:]
        for index in (1...agentCount).reversed() {
            var agent = WorkflowAgent(
                index: index,
                label: "Reviewer \(index)",
                phaseIndex: 0,
                phaseTitle: "Review",
                state: .failed)
            agent.startedAt = now.addingTimeInterval(-60)
            agent.endedAt = now
            agents[agent.id] = agent
        }
        var workflow = WorkflowRun(runKey: "large-failed-workflow")
        workflow.workflowName = "Large review"
        workflow.status = .failed
        workflow.startedAt = now.addingTimeInterval(-60)
        workflow.endedAt = now
        workflow.agents = agents
        bridge.workflowRuns = [workflow.runKey: workflow]
        let firstLaneID = AgentActivityIdentity.workflow(
            runKey: workflow.runKey,
            agentKey: "0:1")
        let changedLaneID = AgentActivityIdentity.workflow(
            runKey: workflow.runKey,
            agentKey: "0:290")
        bridge.agentActivity = [
            .tokens(
                turnID: "activity-only-reload",
                agentID: firstLaneID,
                total: 100,
                at: now),
        ]

        let panel = AppKitAgentsPanelView(
            bridge: bridge,
            liveActivityReloadDelay: 0,
            applicationIsActive: { true })
        panel.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        panel.layoutSubtreeIfNeeded()
        defer {
            panel.shutdown()
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
            if let previousCompact {
                UserDefaults.standard.set(previousCompact, forKey: compactKey)
            } else {
                UserDefaults.standard.removeObject(forKey: compactKey)
            }
            if let previousTimeline {
                UserDefaults.standard.set(previousTimeline, forKey: timelineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: timelineKey)
            }
        }

        XCTAssertEqual(panel.debugCounters.workflowAgentOrderingSorts, 1)
        XCTAssertEqual(
            panel.workflowAgentBadgeForTesting(runKey: workflow.runKey, agentKey: "0:1"),
            "A1")
        XCTAssertEqual(
            panel.workflowAgentBadgeForTesting(runKey: workflow.runKey, agentKey: "0:290"),
            "A290")

        let baseline = panel.debugCounters
        let heightMeasurementBaseline = panel.listRowHeightMeasurementCountForTesting
        bridge.agentActivity.append(
            .tokens(
                turnID: "activity-only-reload",
                agentID: changedLaneID,
                total: 200,
                at: now.addingTimeInterval(1)))
        await drainMainQueue()
        panel.flushPendingReloadForTesting()

        let heightMeasurementsAfterReload = panel.listRowHeightMeasurementCountForTesting
        XCTAssertEqual(
            heightMeasurementsAfterReload,
            heightMeasurementBaseline + 1,
            "one appended lane must not remeasure the other 289 workflow-agent rows")

        panel.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            panel.listRowHeightMeasurementCountForTesting,
            heightMeasurementsAfterReload,
            "layout must consume NSTableView's height cache instead of measuring every row again")

        XCTAssertGreaterThan(
            panel.debugCounters.listSnapshotRebuilds,
            baseline.listSnapshotRebuilds)
        XCTAssertEqual(
            panel.debugCounters.workflowAgentOrderingSorts,
            baseline.workflowAgentOrderingSorts,
            "activity-only height and cell refreshes must reuse the cached workflow ordering")
        XCTAssertEqual(
            panel.workflowAgentBadgeForTesting(runKey: workflow.runKey, agentKey: "0:1"),
            "A1")
        XCTAssertEqual(
            panel.workflowAgentBadgeForTesting(runKey: workflow.runKey, agentKey: "0:290"),
            "A290")
    }

    func testListSnapshotBreaksEqualStartTimesByStableKey() {
        let start = Date(timeIntervalSince1970: 1_500)
        var beta = SubagentRun(key: "beta", subagentType: "Agent", task: "Beta")
        beta.startedAt = start
        beta.status = .completed
        var alpha = SubagentRun(key: "alpha", subagentType: "Agent", task: "Alpha")
        alpha.startedAt = start
        alpha.status = .completed

        let snapshot = AppKitAgentsListSnapshot.make(
            subagents: [beta.key: beta, alpha.key: alpha],
            workflowRuns: [:],
            search: "",
            attentionExpanded: true,
            completedExpanded: true)

        XCTAssertEqual(snapshot.items, [
            .group(.completed, count: 2, expanded: true),
            .subagent(key: "alpha", depth: 0),
            .subagent(key: "beta", depth: 0),
        ])
    }

    func testTimerAndPointerUpdatesDoNotRebuildActivityModel() {
        let start = Date(timeIntervalSince1970: 2_000)
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", detail: "Reasoning", at: start),
            .tokens(
                turnID: "turn",
                input: 100,
                output: 20,
                at: start.addingTimeInterval(1)),
        ]
        let summary = AgentActivityTurnSummary(
            id: "turn",
            startedAt: start,
            endedAt: start.addingTimeInterval(1),
            providerAccess: .codexSubscription,
            modelID: "codex",
            isTerminal: false,
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 20,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let input = AppKitAgentActivityRenderInput(
            records: records,
            summary: summary,
            aliases: [AgentActivityIdentity.root: AgentActivityIdentity.root],
            labels: [AgentActivityIdentity.root: "Root agent"])
        let model = AppKitAgentActivityRenderModel()

        XCTAssertTrue(model.rebuild(input, now: start.addingTimeInterval(2)))
        XCTAssertEqual(model.rebuildCount, 1)
        XCTAssertEqual(model.lanes.first?.spans.last?.isOpen, true)
        let originalEnd = model.lanes.first?.spans.last?.span.end

        model.tick(now: start.addingTimeInterval(9))
        model.notePointerRedraw()
        model.notePointerRedraw()

        XCTAssertEqual(model.rebuildCount, 1)
        XCTAssertEqual(model.timerRedrawCount, 1)
        XCTAssertEqual(model.pointerRedrawCount, 2)
        XCTAssertGreaterThan(
            model.lanes.first?.spans.last?.span.end ?? .distantPast,
            originalEnd ?? .distantFuture)
        XCTAssertEqual(
            model.usageBuckets.last?.end,
            start.addingTimeInterval(9),
            "live token buckets must expand with the same end date as the spans and ruler")
        XCTAssertFalse(
            model.rebuild(input, now: start.addingTimeInterval(10)),
            "An identical ledger snapshot must not be rebuilt merely because live time advanced")
        XCTAssertEqual(model.rebuildCount, 1)
    }

    func testLargeActivityTraceRetainsOneAliasedLedgerIndexAcrossLaneQueriesAndTicks() throws {
        let start = Date(timeIntervalSince1970: 2_500)
        let agentCount = 290
        var records: [AgentActivityRecord] = []
        records.reserveCapacity(agentCount * 5)
        var aliases: [String: String] = [:]
        var labels: [String: String] = [:]
        var canonicalIDs: [String] = []
        canonicalIDs.reserveCapacity(agentCount)

        for index in 1...agentCount {
            let providerID = AgentActivityIdentity.subagent("provider-\(index)")
            let canonicalID = AgentActivityIdentity.subagent("canonical-\(index)")
            aliases[providerID] = canonicalID
            labels[canonicalID] = "Agent \(index)"
            canonicalIDs.append(canonicalID)
            records.append(contentsOf: [
                .state(
                    .model,
                    turnID: "large-trace",
                    agentID: providerID,
                    detail: "Planning",
                    at: start),
                .state(
                    .tool,
                    turnID: "large-trace",
                    agentID: providerID,
                    detail: "Read",
                    at: start.addingTimeInterval(1)),
                .state(
                    .model,
                    turnID: "large-trace",
                    agentID: providerID,
                    detail: "Reviewing",
                    at: start.addingTimeInterval(2)),
                .state(
                    .tool,
                    turnID: "large-trace",
                    agentID: providerID,
                    detail: "Search",
                    at: start.addingTimeInterval(3)),
                .state(
                    .model,
                    turnID: "large-trace",
                    agentID: providerID,
                    detail: "Writing agent \(index)",
                    at: start.addingTimeInterval(4)),
            ])
        }

        let summary = AgentActivityTurnSummary(
            id: "large-trace",
            startedAt: start,
            endedAt: start.addingTimeInterval(4),
            providerAccess: .codexSubscription,
            modelID: "codex",
            isTerminal: false,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        var input = AppKitAgentActivityRenderInput(
            records: records,
            summary: summary,
            aliases: aliases,
            labels: labels)
        let model = AppKitAgentActivityRenderModel()

        XCTAssertTrue(model.rebuild(input, now: start.addingTimeInterval(60)))
        XCTAssertEqual(model.lanes.count, agentCount)
        XCTAssertEqual(model.activityIndexRebuildCount, 1)

        // Two display-equivalent passes across the captured incident's lane count must only query
        // the retained index. In particular, canonical IDs must find records stored under the
        // provider IDs from before identity reconciliation.
        for _ in 0..<2 {
            for (offset, agentID) in canonicalIDs.enumerated() {
                let step = try XCTUnwrap(model.currentStep(agentID: agentID))
                XCTAssertEqual(step.label, "Writing agent \(offset + 1)")
                XCTAssertTrue(model.stepIsStalled(agentID: agentID))
            }
        }
        XCTAssertEqual(model.activityIndexRebuildCount, 1)

        _ = model.tick(now: start.addingTimeInterval(120))
        XCTAssertEqual(
            try XCTUnwrap(model.currentStep(agentID: canonicalIDs[0])).duration,
            116,
            accuracy: 0.001)
        XCTAssertEqual(
            model.activityIndexRebuildCount,
            1,
            "advancing live time changes duration and stall queries, not ledger-derived state")

        input.labels[canonicalIDs[0]] = "Renamed agent"
        XCTAssertTrue(model.rebuild(input, now: start.addingTimeInterval(120)))
        XCTAssertEqual(
            model.activityIndexRebuildCount,
            1,
            "label-only render changes must reuse the equal records and aliases value")

        input.records.append(
            .tool(
                "Read",
                turnID: "large-trace",
                agentID: AgentActivityIdentity.subagent("provider-1"),
                at: start.addingTimeInterval(121)))
        XCTAssertTrue(model.rebuild(input, now: start.addingTimeInterval(121)))
        XCTAssertEqual(model.activityIndexRebuildCount, 2)
    }

    @MainActor
    func testTranscriptPublicationDoesNotReloadAgentsPanel() async {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-agents-transcript-invalidation-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let panel = AppKitAgentsPanelView(
            bridge: bridge,
            applicationIsActive: { true })
        defer {
            panel.shutdown()
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }

        await drainMainQueue()
        let baseline = panel.debugCounters

        bridge.entries = [TranscriptEntry(kind: .assistant, text: "A transcript-only update")]
        await drainMainQueue()

        XCTAssertEqual(
            panel.debugCounters,
            baseline,
            "the Agents panel must not scan its ledgers for an unrelated transcript publication")
    }

    @MainActor
    func testActivityVisualizationStartsOnTrace() {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-agents-activity-default-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let panel = AppKitAgentsPanelView(bridge: bridge)
        defer {
            panel.shutdown()
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }

        XCTAssertEqual(panel.activityVisualizationModeForTesting, .trace)
        XCTAssertEqual(panel.activityVisualizationControlModeForTesting, .trace)
    }

    @MainActor
    func testTraceDefaultAndEnteringTrendsPrefersAvailableHarnessMetrics() throws {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-agents-harness-trend-default-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let panel = AppKitAgentsPanelView(bridge: bridge)
        defer {
            panel.shutdown()
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }
        let sample = try XCTUnwrap(HarnessMetricSample(
            name: "codex.request.count",
            kind: .counter,
            at: Date(timeIntervalSince1970: 2_401),
            unit: .count,
            harnessLaneID: .codex,
            value: 1))

        XCTAssertTrue(panel.reloadHarnessMetricSamplesForTesting([sample]))

        XCTAssertEqual(panel.activityVisualizationModeForTesting, .trace)
        XCTAssertEqual(panel.activityVisualizationControlModeForTesting, .trace)

        panel.setActivityVisualizationModeForTesting(.trends)

        XCTAssertEqual(panel.activityVisualizationModeForTesting, .trends)
        XCTAssertEqual(panel.activityTrendMetricForTesting, .runtime)

        panel.setActivityTrendMetricForTesting(.tokens)
        panel.setActivityVisualizationModeForTesting(.trace)
        panel.setActivityVisualizationModeForTesting(.trends)

        XCTAssertEqual(
            panel.activityTrendMetricForTesting,
            .tokens,
            "an explicit Trends metric remains selected for this Activity presentation")
    }

    @MainActor
    func testEnteringTrendsFallsBackToDurationWithoutHarnessMetrics() {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-agents-no-harness-trend-default-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let panel = AppKitAgentsPanelView(bridge: bridge)
        defer {
            panel.shutdown()
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }

        panel.setActivityVisualizationModeForTesting(.trends)

        XCTAssertEqual(panel.activityVisualizationModeForTesting, .trends)
        XCTAssertEqual(panel.activityTrendMetricForTesting, .duration)
    }

    @MainActor
    func testImplicitTrendMetricTracksHarnessMetricArrivalAndClearDuringReload() throws {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-agents-harness-trend-reload-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        bridge.agentActivity = [
            .state(
                .model,
                turnID: "harness-trend-reload",
                detail: "Reasoning",
                at: Date(timeIntervalSince1970: 2_410)),
        ]
        let panel = AppKitAgentsPanelView(bridge: bridge)
        defer {
            panel.shutdown()
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }
        let sample = try XCTUnwrap(HarnessMetricSample(
            name: "codex.request.count",
            kind: .counter,
            at: Date(timeIntervalSince1970: 2_411),
            unit: .count,
            harnessLaneID: .codex,
            value: 1))

        panel.setActivityVisualizationModeForTesting(.trends)
        XCTAssertEqual(panel.activityTrendMetricForTesting, .duration)

        XCTAssertTrue(
            panel.reloadHarnessMetricSamplesForTesting([sample]),
            "sample arrival must traverse the production Activity rebuild")
        XCTAssertEqual(panel.activityTrendMetricForTesting, .runtime)

        XCTAssertTrue(
            panel.reloadHarnessMetricSamplesForTesting([]),
            "sample clearing must traverse the production Activity rebuild")
        XCTAssertEqual(panel.activityTrendMetricForTesting, .duration)
    }

    @MainActor
    func testExplicitTrendMetricSurvivesHarnessMetricArrivalAndClearDuringReload() throws {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-agents-explicit-trend-reload-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        bridge.agentActivity = [
            .state(
                .model,
                turnID: "explicit-trend-reload",
                detail: "Reasoning",
                at: Date(timeIntervalSince1970: 2_420)),
        ]
        let panel = AppKitAgentsPanelView(bridge: bridge)
        defer {
            panel.shutdown()
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }
        let sample = try XCTUnwrap(HarnessMetricSample(
            name: "codex.request.count",
            kind: .counter,
            at: Date(timeIntervalSince1970: 2_421),
            unit: .count,
            harnessLaneID: .codex,
            value: 1))

        panel.setActivityVisualizationModeForTesting(.trends)
        panel.setActivityTrendMetricForTesting(.tokens)

        XCTAssertTrue(panel.reloadHarnessMetricSamplesForTesting([sample]))
        XCTAssertEqual(panel.activityTrendMetricForTesting, .tokens)

        XCTAssertTrue(panel.reloadHarnessMetricSamplesForTesting([]))
        XCTAssertEqual(panel.activityTrendMetricForTesting, .tokens)
    }

    @MainActor
    func testRuntimeMetricsArrivingBeforeATurnDoNotChooseTrends() throws {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-agents-runtime-first-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let panel = AppKitAgentsPanelView(bridge: bridge)
        defer {
            panel.shutdown()
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }
        let sample = try XCTUnwrap(HarnessMetricSample(
            name: "codex.request.count",
            kind: .counter,
            at: Date(timeIntervalSince1970: 2_401),
            unit: .count,
            harnessLaneID: .codex,
            value: 1))

        panel.showRuntimeOnlyActivityForTesting([sample])

        XCTAssertEqual(
            panel.activityVisualizationModeForTesting,
            .trace,
            "session metrics may prepare Harness trends but must not replace the Trace default")
        XCTAssertEqual(panel.activityVisualizationControlModeForTesting, .trace)
    }

    @MainActor
    func testTrendControlsDoNotOverlapAtMinimumOrWideInspectorWidths() {
        _ = NSApplication.shared
        let defaultsKey = "agentsActivityTimelineShown"
        let previousDefault = UserDefaults.standard.object(forKey: defaultsKey)
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-agents-trend-controls-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let panel = AppKitAgentsPanelView(bridge: bridge)
        defer {
            panel.shutdown()
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
            if let previousDefault {
                UserDefaults.standard.set(previousDefault, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
        panel.setTimelineShownForTesting(false)
        panel.setTimelineShownForTesting(true)
        panel.setActivityVisualizationModeForTesting(.trends)

        for width: CGFloat in [180, 360] {
            panel.frame = NSRect(x: 0, y: 0, width: width, height: 540)
            panel.layoutSubtreeIfNeeded()
            let frames = panel.activityControlFramesForTesting()
            XCTAssertFalse(
                frames.mode.intersects(frames.metric),
                "mode and metric controls must not overlap at width \(width)")
            XCTAssertLessThanOrEqual(
                frames.metric.maxY,
                frames.chart.minY,
                "the wrapped metric control must remain above the chart at width \(width)")
        }
    }

    @MainActor
    func testRevealingActivityResetsVisualizationToTrace() {
        _ = NSApplication.shared
        let defaultsKey = "agentsActivityTimelineShown"
        let previousDefault = UserDefaults.standard.object(forKey: defaultsKey)
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-agents-activity-reveal-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let panel = AppKitAgentsPanelView(bridge: bridge)
        defer {
            panel.shutdown()
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
            if let previousDefault {
                UserDefaults.standard.set(previousDefault, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        panel.setTimelineShownForTesting(false)
        panel.setTimelineShownForTesting(true)
        panel.setActivityVisualizationModeForTesting(.trends)
        panel.setTimelineShownForTesting(false)

        XCTAssertEqual(panel.activityVisualizationModeForTesting, .trends)

        panel.setTimelineShownForTesting(true)

        XCTAssertEqual(panel.activityVisualizationModeForTesting, .trace)
        XCTAssertEqual(panel.activityVisualizationControlModeForTesting, .trace)
    }

    @MainActor
    func testActivityReloadPreservesExplicitTrendsSelection() async {
        _ = NSApplication.shared
        let defaultsKey = "agentsActivityTimelineShown"
        let previousDefault = UserDefaults.standard.object(forKey: defaultsKey)
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-agents-activity-reload-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let panel = AppKitAgentsPanelView(
            bridge: bridge,
            applicationIsActive: { true })
        defer {
            panel.shutdown()
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
            if let previousDefault {
                UserDefaults.standard.set(previousDefault, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        panel.setTimelineShownForTesting(false)
        panel.setTimelineShownForTesting(true)
        panel.setActivityVisualizationModeForTesting(.trends)
        let baseline = panel.debugCounters.activityModelRebuilds

        bridge.agentActivity = [
            .state(
                .model,
                turnID: "preserve-trends",
                detail: "Reasoning",
                at: Date(timeIntervalSince1970: 2_400)),
        ]
        await drainMainQueue()
        panel.flushPendingReloadForTesting()

        XCTAssertGreaterThan(panel.debugCounters.activityModelRebuilds, baseline)
        XCTAssertEqual(panel.activityVisualizationModeForTesting, .trends)
        XCTAssertEqual(panel.activityVisualizationControlModeForTesting, .trends)
    }

    @MainActor
    func testReplacingBridgeResetsActivityVisualizationToTrace() throws {
        _ = NSApplication.shared
        let originalSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-agents-activity-original-\(UUID().uuidString)")
        let replacementSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-agents-activity-replacement-\(UUID().uuidString)")
        let original = AgentBridge(settingsBaseOverride: originalSupport, environmentOverride: [:])
        let replacement = AgentBridge(
            settingsBaseOverride: replacementSupport,
            environmentOverride: [:])
        let panel = AppKitAgentsPanelView(bridge: original)
        defer {
            panel.shutdown()
            original.shutdown()
            replacement.shutdown()
            try? FileManager.default.removeItem(at: originalSupport)
            try? FileManager.default.removeItem(at: replacementSupport)
        }
        let sample = try XCTUnwrap(HarnessMetricSample(
            name: "codex.request.count",
            kind: .counter,
            at: Date(timeIntervalSince1970: 2_402),
            unit: .count,
            harnessLaneID: .codex,
            value: 1))

        panel.showRuntimeOnlyActivityForTesting([sample])
        XCTAssertEqual(panel.activityTrendMetricForTesting, .runtime)
        panel.setActivityTrendMetricForTesting(.duration)
        panel.setActivityVisualizationModeForTesting(.trends)
        panel.setBridge(replacement)

        XCTAssertEqual(panel.activityVisualizationModeForTesting, .trace)
        XCTAssertEqual(panel.activityVisualizationControlModeForTesting, .trace)
        panel.showRuntimeOnlyActivityForTesting([sample])
        XCTAssertEqual(
            panel.activityTrendMetricForTesting,
            .runtime,
            "a replacement bridge must prepare its own runtime-only metric presentation")
    }

    @MainActor
    func testDuplicateViewerAddsRootRowWhenAnotherBridgeStartsWork() async throws {
        _ = NSApplication.shared
        let ownerSupport = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mechanician-agents-root-owner-\(UUID().uuidString)")
        let viewerSupport = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mechanician-agents-root-viewer-\(UUID().uuidString)")
        let storeSupport = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mechanician-agents-root-store-\(UUID().uuidString)")
        let store = ConversationStore(
            appSupportBaseOverride: storeSupport,
            watchesDirectory: false)
        let owner = AgentBridge(
            settingsBaseOverride: ownerSupport,
            environmentOverride: [:],
            conversationStoreOverride: store)
        let viewer = AgentBridge(
            settingsBaseOverride: viewerSupport,
            environmentOverride: [:],
            conversationStoreOverride: store)
        let conversationID = UUID()
        let turnID = "cross-window-root"
        let selection = ModelSelection(
            access: .codexSubscription,
            modelID: "gpt-cross-window")
        store.upsert(Conversation(
            id: conversationID,
            title: "Cross-window root",
            cwd: "",
            sdkSessionId: nil,
            modelSelection: selection,
            messages: [],
            updatedAt: Date()))
        owner.currentID = conversationID
        viewer.currentID = conversationID
        AgentBridge.live.add(owner)
        AgentBridge.live.add(viewer)
        let panel = AppKitAgentsPanelView(
            bridge: viewer,
            applicationIsActive: { true })
        panel.frame = NSRect(x: 0, y: 0, width: 480, height: 640)
        panel.layoutSubtreeIfNeeded()
        defer {
            panel.shutdown()
            AgentBridge.live.remove(owner)
            AgentBridge.live.remove(viewer)
            owner.currentID = nil
            viewer.currentID = nil
            owner.shutdown()
            viewer.shutdown()
            ActiveWorkspace.shared.recomputeRunning()
            store.flushSaves()
            try? FileManager.default.removeItem(at: ownerSupport)
            try? FileManager.default.removeItem(at: viewerSupport)
            try? FileManager.default.removeItem(at: storeSupport)
        }

        await drainMainQueue()
        XCTAssertNil(panel.rootStopButtonForTesting)
        let baselineRebuilds = panel.debugCounters.listSnapshotRebuilds

        owner.stageRootWorkForTesting(
            conversationID: conversationID,
            turnID: turnID,
            selection: selection)
        await drainMainQueue()
        panel.layoutSubtreeIfNeeded()

        XCTAssertTrue(AgentBridge.live.allObjects.contains { $0 === owner })
        XCTAssertTrue(owner.hasReservedTurnForTesting(conversationID: conversationID))
        XCTAssertTrue(owner.currentConversationHasRootWork)
        XCTAssertTrue(viewer.currentConversationHasRootWork)
        XCTAssertTrue(ActiveWorkspace.shared.runningConversations.contains(conversationID))
        XCTAssertGreaterThan(panel.debugCounters.listSnapshotRebuilds, baselineRebuilds)
        let stopButton = try XCTUnwrap(panel.rootStopButtonForTesting)
        XCTAssertFalse(stopButton.isHidden)
        XCTAssertEqual(stopButton.accessibilityLabel(), "Stop root agent")
    }

    @MainActor
    func testHiddenActivityDefersOneReloadUntilTimelineIsShown() async {
        _ = NSApplication.shared
        let defaultsKey = "agentsActivityTimelineShown"
        let previousDefault = UserDefaults.standard.object(forKey: defaultsKey)
        defer {
            if let previousDefault {
                UserDefaults.standard.set(previousDefault, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-agents-hidden-activity-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let panel = AppKitAgentsPanelView(
            bridge: bridge,
            liveActivityReloadDelay: 60,
            applicationIsActive: { true })
        panel.setTimelineShownForTesting(false)
        defer {
            panel.shutdown()
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }

        await drainMainQueue()
        let baseline = panel.debugCounters
        bridge.agentActivity = [
            .state(
                .model,
                turnID: "deferred-turn",
                detail: "Reasoning",
                at: Date(timeIntervalSince1970: 2_500)),
        ]
        await drainMainQueue()
        XCTAssertTrue(panel.hasDeferredLiveReloadForTesting)
        panel.flushPendingReloadForTesting()

        XCTAssertTrue(panel.hasDeferredActivityReloadForTesting)
        XCTAssertEqual(panel.debugCounters.activityModelRebuilds, baseline.activityModelRebuilds)
        let afterHiddenPublication = panel.debugCounters

        panel.setTimelineShownForTesting(true)

        XCTAssertFalse(panel.hasDeferredActivityReloadForTesting)
        XCTAssertEqual(
            panel.debugCounters.activityModelRebuilds,
            afterHiddenPublication.activityModelRebuilds + 1)
        XCTAssertEqual(
            panel.debugCounters.listSnapshotRebuilds,
            afterHiddenPublication.listSnapshotRebuilds,
            "revealing Activity must consume its dirty bit without rescanning the list")
    }

    @MainActor
    func testLiveActivityBurstCoalescesAndTerminalStateBypassesDelay() async {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-agents-live-coalescing-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let panel = AppKitAgentsPanelView(
            bridge: bridge,
            liveActivityReloadDelay: 60,
            applicationIsActive: { true })
        defer {
            panel.shutdown()
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }

        await drainMainQueue()
        let baseline = panel.debugCounters
        let start = Date(timeIntervalSince1970: 2_600)
        bridge.agentActivity = [
            .state(.model, turnID: "coalesced-turn", at: start),
        ]
        bridge.agentActivity = [
            .state(.model, turnID: "coalesced-turn", at: start),
            .state(
                .tool,
                turnID: "coalesced-turn",
                detail: "Read",
                at: start.addingTimeInterval(0.1)),
        ]
        await drainMainQueue()

        XCTAssertTrue(panel.hasDeferredLiveReloadForTesting)
        XCTAssertEqual(panel.debugCounters.listSnapshotRebuilds, baseline.listSnapshotRebuilds)
        XCTAssertEqual(panel.debugCounters.activityModelRebuilds, baseline.activityModelRebuilds)

        panel.flushPendingReloadForTesting()
        XCTAssertEqual(panel.debugCounters.listSnapshotRebuilds, baseline.listSnapshotRebuilds + 1)
        XCTAssertEqual(panel.debugCounters.activityModelRebuilds, baseline.activityModelRebuilds + 1)

        let afterBurst = panel.debugCounters
        bridge.agentActivity.append(
            .state(
                .completed,
                turnID: "coalesced-turn",
                at: start.addingTimeInterval(0.2)))
        await drainMainQueue()

        XCTAssertFalse(panel.hasDeferredLiveReloadForTesting)
        XCTAssertEqual(
            panel.debugCounters.listSnapshotRebuilds,
            afterBurst.listSnapshotRebuilds + 1)
        XCTAssertEqual(
            panel.debugCounters.activityModelRebuilds,
            afterBurst.activityModelRebuilds + 1)
    }

    func testTerminalFinalSpanIsMeasuredRatherThanMarkedOpen() {
        let start = Date(timeIntervalSince1970: 3_000)
        let end = start.addingTimeInterval(4)
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", at: start),
            .state(.completed, turnID: "turn", at: end),
        ]
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
        let model = AppKitAgentActivityRenderModel()
        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: records,
                summary: summary,
                aliases: [:],
                labels: [:]),
            now: end.addingTimeInterval(10))

        XCTAssertFalse(model.lanes.flatMap(\.spans).contains(where: \.isOpen))
        XCTAssertEqual(model.end, end)
    }

    func testBufferedProgressCannotResurrectOrExtendATerminalLane() throws {
        let start = Date(timeIntervalSince1970: 3_500)
        let childID = AgentActivityIdentity.subagent("child")
        let terminalAt = start.addingTimeInterval(2)
        let backdatedBufferedProgress = AgentActivityRecord.state(
            .model,
            turnID: "turn",
            agentID: childID,
            detail: "Buffered before Stop",
            at: start.addingTimeInterval(1.5))
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", at: start),
            .state(
                .model,
                turnID: "turn",
                agentID: childID,
                detail: "Working",
                at: start.addingTimeInterval(1)),
            .state(
                .stopped,
                turnID: "turn",
                agentID: childID,
                at: terminalAt),
            // Appended after Stop with an earlier timestamp. Date clipping alone cannot reject it.
            backdatedBufferedProgress,
            // Buffered before Stop, delivered afterward with a newer provider timestamp.
            .state(
                .tool,
                turnID: "turn",
                agentID: childID,
                detail: "Read",
                at: start.addingTimeInterval(4)),
        ]
        let summary = AgentActivityTurnSummary(
            id: "turn",
            startedAt: start,
            endedAt: start.addingTimeInterval(4),
            providerAccess: nil,
            modelID: nil,
            isTerminal: false,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let model = AppKitAgentActivityRenderModel()

        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: records,
                summary: summary,
                aliases: [:],
                labels: [:]),
            now: start.addingTimeInterval(10))

        let child = try XCTUnwrap(model.lanes.first { $0.id == childID })
        XCTAssertFalse(child.isActive)
        XCTAssertFalse(child.spans.contains(where: \.isOpen))
        XCTAssertFalse(child.spans.contains { $0.span.id == backdatedBufferedProgress.id })
        XCTAssertLessThanOrEqual(
            child.spans.map(\.span.end).max() ?? .distantFuture,
            terminalAt,
            "ordinary geometry must stop at the first terminal boundary")
    }

    func testAuthoritativeRetaskDrawsTheNewSameTurnLifecycle() throws {
        let start = Date(timeIntervalSince1970: 3_600)
        let childID = AgentActivityIdentity.subagent("reused-child")
        let firstState = AgentActivityRecord.state(
            .model,
            turnID: "turn",
            agentID: childID,
            detail: "First generation",
            at: start.addingTimeInterval(1))
        let firstTerminal = AgentActivityRecord.state(
            .completed,
            turnID: "turn",
            agentID: childID,
            at: start.addingTimeInterval(2))
        let buffered = AgentActivityRecord.state(
            .model,
            turnID: "turn",
            agentID: childID,
            detail: "Buffered progress",
            at: start.addingTimeInterval(3))
        let priorGenerationLateTool = AgentActivityRecord.tool(
            "Read",
            turnID: "turn",
            agentID: childID,
            at: start.addingTimeInterval(4.5))
        let retask = AgentActivityRecord.state(
            .model,
            turnID: "turn",
            agentID: childID,
            detail: "Second generation",
            startsNewLifecycleGeneration: true,
            at: start.addingTimeInterval(4))
        var records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", at: start),
            firstState,
            firstTerminal,
            buffered,
            // Appended before the retask but carrying a later provider timestamp. Sorting before
            // selecting the lifecycle generation would attach this old tool to the reopened span.
            priorGenerationLateTool,
            retask,
        ]
        let liveSummary = AgentActivityTurnSummary(
            id: "turn",
            startedAt: start,
            endedAt: start.addingTimeInterval(4),
            providerAccess: nil,
            modelID: nil,
            isTerminal: false,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let model = AppKitAgentActivityRenderModel()

        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: records,
                summary: liveSummary,
                aliases: [:],
                labels: [:]),
            now: start.addingTimeInterval(5))

        var child = try XCTUnwrap(model.lanes.first { $0.id == childID })
        XCTAssertTrue(child.isActive)
        XCTAssertEqual(
            child.spans.map(\.span.id),
            [firstState.id, firstTerminal.id, retask.id])
        XCTAssertEqual(child.spans[0].span.start, start.addingTimeInterval(1))
        XCTAssertEqual(child.spans[0].span.end, start.addingTimeInterval(2))
        XCTAssertEqual(child.spans[2].span.start, start.addingTimeInterval(4))
        XCTAssertTrue(child.spans[2].span.toolNames.isEmpty)
        XCTAssertTrue(child.spans[2].isOpen)
        XCTAssertFalse(child.spans.contains { $0.span.id == buffered.id })
        XCTAssertFalse(child.spans.flatMap(\.span.toolNames).contains("Read"))

        let secondTerminal = AgentActivityRecord.state(
            .completed,
            turnID: "turn",
            agentID: childID,
            at: start.addingTimeInterval(6))
        records.append(secondTerminal)
        records.append(.state(.completed, turnID: "turn", at: start.addingTimeInterval(7)))
        var completedSummary = liveSummary
        completedSummary.endedAt = start.addingTimeInterval(7)
        completedSummary.isTerminal = true
        XCTAssertTrue(model.rebuild(
            AppKitAgentActivityRenderInput(
                records: records,
                summary: completedSummary,
                aliases: [:],
                labels: [:]),
            now: start.addingTimeInterval(7)))

        child = try XCTUnwrap(model.lanes.first { $0.id == childID })
        XCTAssertFalse(child.isActive)
        XCTAssertFalse(child.spans.contains(where: \.isOpen))
        XCTAssertEqual(
            child.spans.map(\.span.id),
            [firstState.id, firstTerminal.id, retask.id, secondTerminal.id])
        XCTAssertEqual(child.spans[2].span.start, start.addingTimeInterval(4))
        XCTAssertEqual(child.spans[2].span.end, start.addingTimeInterval(6))
        XCTAssertFalse(child.spans.contains { $0.span.id == buffered.id })
        XCTAssertFalse(child.spans.flatMap(\.span.toolNames).contains("Read"))
    }

    func testRetaskBoundsAnUnterminatedPriorGenerationAtTheNewBoundary() throws {
        let start = Date(timeIntervalSince1970: 3_650)
        let childID = AgentActivityIdentity.subagent("reused-child")
        let firstState = AgentActivityRecord.state(
            .model,
            turnID: "turn",
            agentID: childID,
            detail: "First generation",
            at: start.addingTimeInterval(1))
        let latePriorTool = AgentActivityRecord.tool(
            "Read",
            turnID: "turn",
            agentID: childID,
            at: start.addingTimeInterval(5))
        let retask = AgentActivityRecord.state(
            .model,
            turnID: "turn",
            agentID: childID,
            detail: "Second generation",
            startsNewLifecycleGeneration: true,
            at: start.addingTimeInterval(4))
        let terminal = AgentActivityRecord.state(
            .completed,
            turnID: "turn",
            agentID: childID,
            at: start.addingTimeInterval(6))
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", at: start),
            firstState,
            // Provider clock is later, but append order still assigns this to generation one.
            latePriorTool,
            retask,
            terminal,
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(7)),
        ]
        let model = AppKitAgentActivityRenderModel()

        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: records,
                summary: AgentActivityTurnSummary(
                    id: "turn",
                    startedAt: start,
                    endedAt: start.addingTimeInterval(7),
                    providerAccess: nil,
                    modelID: nil,
                    isTerminal: true,
                    inputTokens: 0,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    reasoningOutputTokens: 0,
                    aggregateOnlyTokens: 0),
                aliases: [:],
                labels: [:]),
            now: start.addingTimeInterval(7))

        let child = try XCTUnwrap(model.lanes.first { $0.id == childID })
        XCTAssertEqual(child.spans.map(\.span.id), [firstState.id, retask.id, terminal.id])
        XCTAssertEqual(child.spans[0].span.end, start.addingTimeInterval(4))
        XCTAssertFalse(child.spans.flatMap(\.span.toolNames).contains("Read"))
    }

    func testAliasReconciliationKeepsOneTerminalMonotonicLane() throws {
        let start = Date(timeIntervalSince1970: 3_700)
        let provisional = AgentActivityIdentity.subagent("provider-child")
        let canonical = AgentActivityIdentity.subagent("spawn-call")
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", at: start),
            .state(
                .model,
                turnID: "turn",
                agentID: provisional,
                at: start.addingTimeInterval(1)),
            .state(
                .completed,
                turnID: "turn",
                agentID: canonical,
                at: start.addingTimeInterval(2)),
            .state(
                .model,
                turnID: "turn",
                agentID: provisional,
                at: start.addingTimeInterval(3)),
        ]
        let summary = AgentActivityTurnSummary(
            id: "turn",
            startedAt: start,
            endedAt: start.addingTimeInterval(3),
            providerAccess: nil,
            modelID: nil,
            isTerminal: false,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let model = AppKitAgentActivityRenderModel()

        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: records,
                summary: summary,
                aliases: [
                    provisional: canonical,
                    canonical: canonical,
                ],
                labels: [:]),
            now: start.addingTimeInterval(10))

        let childLanes = model.lanes.filter { $0.id != AgentActivityIdentity.root }
        XCTAssertEqual(childLanes.count, 1)
        XCTAssertEqual(childLanes.first?.id, canonical)
        XCTAssertEqual(childLanes.first?.isActive, false)
        XCTAssertFalse(childLanes.first?.spans.contains(where: \.isOpen) == true)
    }

    func testBackdatedTerminalRefinementDoesNotMoveTheObservedGeometryBoundary() throws {
        let start = Date(timeIntervalSince1970: 3_800)
        let childID = AgentActivityIdentity.subagent("child")
        let firstObservedTerminal = start.addingTimeInterval(30)
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", at: start),
            .state(
                .model,
                turnID: "turn",
                agentID: childID,
                at: start),
            .state(
                .tool,
                turnID: "turn",
                agentID: childID,
                detail: "Read",
                at: start.addingTimeInterval(20)),
            .state(
                .stopped,
                turnID: "turn",
                agentID: childID,
                at: firstObservedTerminal),
            // Appended later, but with the provider's historical clock. It may refine the outcome;
            // it must not erase the already-observed work from 10–30 seconds.
            .state(
                .failed,
                turnID: "turn",
                agentID: childID,
                at: start.addingTimeInterval(10)),
        ]
        let summary = AgentActivityTurnSummary(
            id: "turn",
            startedAt: start,
            endedAt: firstObservedTerminal,
            providerAccess: nil,
            modelID: nil,
            isTerminal: false,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let model = AppKitAgentActivityRenderModel()

        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: records,
                summary: summary,
                aliases: [:],
                labels: [:]),
            now: firstObservedTerminal)

        let child = try XCTUnwrap(model.lanes.first { $0.id == childID })
        XCTAssertFalse(child.isActive)
        XCTAssertFalse(child.spans.contains(where: \.isOpen))
        XCTAssertEqual(
            child.spans
                .filter { !$0.span.phase.isTerminal }
                .map(\.span.end)
                .max(),
            firstObservedTerminal)
    }

    func testCompletedRootDoesNotCloseAStillRunningChildLane() throws {
        let start = Date(timeIntervalSince1970: 3_900)
        let childID = AgentActivityIdentity.subagent("child")
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", at: start),
            .state(
                .model,
                turnID: "turn",
                agentID: childID,
                at: start.addingTimeInterval(1)),
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(2)),
        ]
        let summary = AgentActivityTurnSummary(
            id: "turn",
            startedAt: start,
            endedAt: start.addingTimeInterval(2),
            providerAccess: nil,
            modelID: nil,
            isTerminal: false,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let model = AppKitAgentActivityRenderModel()

        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: records,
                summary: summary,
                aliases: [:],
                labels: [:]),
            now: start.addingTimeInterval(5))

        let child = try XCTUnwrap(model.lanes.first { $0.id == childID })
        XCTAssertTrue(child.isActive)
        XCTAssertTrue(child.spans.contains(where: \.isOpen))
    }

    func testUsageBucketsCanFilterOneNativeLane() {
        let start = Date(timeIntervalSince1970: 4_000)
        let childID = AgentActivityIdentity.subagent("child")
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", at: start),
            .tokens(turnID: "turn", input: 50, at: start.addingTimeInterval(1)),
            .state(
                .model,
                turnID: "turn",
                agentID: childID,
                at: start.addingTimeInterval(0.5)),
            .tokens(
                turnID: "turn",
                agentID: childID,
                output: 20,
                at: start.addingTimeInterval(2)),
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(3)),
        ]
        let summary = AgentActivityTurnSummary(
            id: "turn",
            startedAt: start,
            endedAt: start.addingTimeInterval(3),
            providerAccess: nil,
            modelID: nil,
            isTerminal: true,
            inputTokens: 50,
            cachedInputTokens: 0,
            outputTokens: 20,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        let model = AppKitAgentActivityRenderModel()
        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: records,
                summary: summary,
                aliases: [:],
                labels: [:]),
            now: summary.endedAt)

        XCTAssertEqual(model.usageBuckets.reduce(0) { $0 + $1.tokens.processed }, 70)
        XCTAssertTrue(model.setUsageAgentID(childID))
        XCTAssertEqual(model.usageBuckets.reduce(0) { $0 + $1.tokens.processed }, 20)
        XCTAssertTrue(model.setUsageAgentID(nil))
        XCTAssertEqual(model.usageBuckets.reduce(0) { $0 + $1.tokens.processed }, 70)
    }

    func testContextSeriesCachesTruthfulPressureHeadroomAndCompactions() {
        let start = Date(timeIntervalSince1970: 5_000)
        let reduction = AgentActivityRecord.historyReduction(
            turnID: "turn",
            omittedMessages: 2,
            shortenedMessages: nil,
            reason: "provider_session_expired",
            at: start.addingTimeInterval(2.5))!
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", at: start),
            .context(
                turnID: "turn",
                tokens: 20_000,
                window: 1_000_000,
                at: start.addingTimeInterval(1)),
            .compaction(
                turnID: "turn",
                trigger: "automatic",
                preTokens: 20_000,
                postTokens: 12_000,
                at: start.addingTimeInterval(2)),
            reduction,
            .context(
                turnID: "turn",
                tokens: 12_000,
                window: 1_000_000,
                at: start.addingTimeInterval(3)),
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(4)),
        ]
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
        let model = AppKitAgentActivityRenderModel()
        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: records,
                summary: summary,
                aliases: [:],
                labels: [:]),
            now: summary.endedAt)

        XCTAssertEqual(model.contextSeries.samples.map(\.tokens), [20_000, 12_000])
        XCTAssertEqual(model.contextSeries.reportedWindow, 1_000_000)
        XCTAssertEqual(model.contextSeries.headroom, 988_000)
        XCTAssertEqual(model.contextSeries.compactionDates, [start.addingTimeInterval(2)])
        XCTAssertTrue(model.globalEvents.contains { $0.contextEventKind == .historyReduction })
        XCTAssertEqual(
            model.globalEvents.filter { $0.kind == .compaction }.count,
            1,
            "history reduction is visible maintenance but never increments provider compaction")
        // The plot scales to the context WINDOW. Scaling to the observed peak made the curve fill
        // the plot for every turn, so a turn at 2% of its window and one at 95% drew the identical
        // picture — which is precisely the comparison this chart exists to support.
        XCTAssertEqual(
            model.contextSeries.scaleMaximum,
            1_000_000,
            "Context pressure scales to the model window, so fill height means share consumed")

        // The property that matters, stated directly: a nearly-full window must not plot at the
        // same height as a nearly-empty one.
        let heavy: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", at: start),
            .context(
                turnID: "turn",
                tokens: 950_000,
                window: 1_000_000,
                at: start.addingTimeInterval(1)),
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(2)),
        ]
        let heavyModel = AppKitAgentActivityRenderModel()
        _ = heavyModel.rebuild(
            AppKitAgentActivityRenderInput(
                records: heavy,
                summary: summary,
                aliases: [:],
                labels: [:]),
            now: summary.endedAt)
        let lightFill = Double(model.contextSeries.samples.map(\.tokens).max() ?? 0)
            / Double(model.contextSeries.scaleMaximum)
        let heavyFill = Double(heavyModel.contextSeries.samples.map(\.tokens).max() ?? 0)
            / Double(heavyModel.contextSeries.scaleMaximum)
        XCTAssertLessThan(lightFill, 0.1)
        XCTAssertGreaterThan(heavyFill, 0.9)
    }

    private func liveTurnSummary(
        start: Date,
        endedAt: Date? = nil,
        isTerminal: Bool = false
    ) -> AgentActivityTurnSummary {
        AgentActivityTurnSummary(
            id: "turn",
            startedAt: start,
            endedAt: endedAt ?? start,
            providerAccess: nil,
            modelID: nil,
            isTerminal: isTerminal,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
    }

    /// A live tick repaints or does nothing; the old partial case left the ruler advancing over
    /// stale bars until an unrelated rebuild repainted the plot all at once.
    func testLiveTickAlwaysPlansAFullRepaintWithoutRebuilding() {
        let start = Date(timeIntervalSince1970: 6_000)
        let model = AppKitAgentActivityRenderModel()
        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: [.state(.model, turnID: "turn", at: start)],
                summary: liveTurnSummary(start: start),
                aliases: [:],
                labels: [:]),
            now: start.addingTimeInterval(1))

        XCTAssertEqual(
            appKitAgentActivityTickInvalidationPlan(
                delta: model.tick(now: start.addingTimeInterval(2))),
            .full)
        // Nothing advanced, so nothing is repainted.
        XCTAssertEqual(
            appKitAgentActivityTickInvalidationPlan(
                delta: model.tick(now: start.addingTimeInterval(2))),
            .none)
        XCTAssertEqual(model.rebuildCount, 1)
    }

    /// The plot running backwards: rebuild took `max(now, endedAt)` while tick took plain `now`, so
    /// a record dated ahead of the caller's clock pushed the horizon out and the next tick pulled it
    /// back, shortening every open span.
    func testLiveHorizonNeverMovesBackwards() {
        let start = Date(timeIntervalSince1970: 6_000)
        let model = AppKitAgentActivityRenderModel()
        let records: [AgentActivityRecord] = [.state(.model, turnID: "turn", at: start)]
        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: records,
                summary: liveTurnSummary(start: start, endedAt: start.addingTimeInterval(9)),
                aliases: [:],
                labels: [:]),
            now: start.addingTimeInterval(1))
        XCTAssertEqual(model.end, start.addingTimeInterval(9))

        XCTAssertNil(
            model.tick(now: start.addingTimeInterval(2)),
            "A tick behind the horizon must not shorten what is already drawn.")
        XCTAssertEqual(model.end, start.addingTimeInterval(9))

        // A rebuild carrying an older clock must not rewind it either.
        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: records + [.state(.tool, turnID: "turn", at: start.addingTimeInterval(3))],
                summary: liveTurnSummary(start: start, endedAt: start.addingTimeInterval(3)),
                aliases: [:],
                labels: [:]),
            now: start.addingTimeInterval(3))
        XCTAssertEqual(model.end, start.addingTimeInterval(9))

        XCTAssertNotNil(model.tick(now: start.addingTimeInterval(12)))
        XCTAssertEqual(model.end, start.addingTimeInterval(12))
    }

    /// Selecting a different turn is not the same turn advancing: a finished, earlier turn must be
    /// allowed to end where it actually ended.
    func testSwitchingTurnsResetsTheHorizonInsteadOfInheritingIt() {
        let start = Date(timeIntervalSince1970: 6_000)
        let model = AppKitAgentActivityRenderModel()
        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: [.state(.model, turnID: "turn", at: start)],
                summary: liveTurnSummary(start: start),
                aliases: [:],
                labels: [:]),
            now: start.addingTimeInterval(60))
        XCTAssertEqual(model.end, start.addingTimeInterval(60))

        let earlier = AgentActivityTurnSummary(
            id: "earlier-turn",
            startedAt: start.addingTimeInterval(-100),
            endedAt: start.addingTimeInterval(-90),
            providerAccess: nil,
            modelID: nil,
            isTerminal: true,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
        _ = model.rebuild(
            AppKitAgentActivityRenderInput(
                records: [.state(.model, turnID: "earlier-turn", at: start.addingTimeInterval(-100))],
                summary: earlier,
                aliases: [:],
                labels: [:]),
            now: start.addingTimeInterval(60))

        XCTAssertEqual(model.end, start.addingTimeInterval(-90))
    }

    func testTimelineEdgeLabelsRemainInsideTheirTicks() {
        let first = appKitTimelineTickLabelRect(
            tickX: 100,
            top: 20,
            width: 84,
            index: 0,
            count: 4)
        let middle = appKitTimelineTickLabelRect(
            tickX: 300,
            top: 20,
            width: 84,
            index: 2,
            count: 4)
        let last = appKitTimelineTickLabelRect(
            tickX: 500,
            top: 20,
            width: 84,
            index: 4,
            count: 4)

        XCTAssertEqual(first.minX, 100)
        XCTAssertEqual(middle.midX, 300)
        XCTAssertEqual(last.maxX, 500)
    }

    func testLiveFollowCentersNowInThePlotBesideTheFrozenGutter() {
        let liveEdgeX: CGFloat = 1_000
        let documentWidth = liveEdgeX + AppKitAgentActivityChartView.liveRunway

        for (viewport, gutter): (CGFloat, CGFloat) in [
            (365, 132),
            (285, 132),
            (180, 92),
        ] {
            let target = appKitAgentActivityLiveFollowTarget(
                liveEdgeX: liveEdgeX,
                documentWidth: documentWidth,
                viewportWidth: viewport,
                gutterWidth: gutter)
            let liveEdgeInViewport = liveEdgeX - target
            let expectedCenter = gutter + (viewport - gutter) / 2

            XCTAssertEqual(liveEdgeInViewport, expectedCenter, accuracy: 0.5)
            XCTAssertGreaterThan(liveEdgeInViewport, gutter)
            XCTAssertLessThan(liveEdgeInViewport, viewport)
        }
    }

    func testFinalTimelineLabelUsesVisibleGlyphsInsteadOfItsWideAlignmentBox() {
        let box = NSRect(x: 44.5, y: 20, width: 84, height: 12)
        let gutterEdge: CGFloat = 92

        XCTAssertLessThan(
            box.minX,
            gutterEdge,
            "the final tick's right-alignment box intentionally reaches under the frozen gutter")
        XCTAssertTrue(appKitTimelineTickLabelFitsPastFrozenGutter(
            box: box,
            measuredTextWidth: 20,
            alignment: .right,
            gutterEdge: gutterEdge))
        XCTAssertFalse(appKitTimelineTickLabelFitsPastFrozenGutter(
            box: box,
            measuredTextWidth: 40,
            alignment: .right,
            gutterEdge: gutterEdge))
    }

    func testConversationSummaryPresentationPrefersActiveAgentCountAndKeepsFullMetrics() {
        let start = Date(timeIntervalSince1970: 7_000)
        let snapshot = AgentConversationActivitySnapshot(
            turnID: "turn",
            overallState: .tool,
            activeAgentCount: 4,
            currentRootStep: AgentStepSnapshot(
                phase: .tool,
                label: "Agent",
                target: "Explore",
                since: start,
                duration: 10),
            toolComposition: [
                AgentToolShare(name: "Read", count: 6, share: 0.6),
                AgentToolShare(name: "rg", count: 4, share: 0.4),
            ],
            delegatedAgentCount: 4,
            tokenUsage: AgentActivityTokenBreakdown(
                input: 100,
                cachedInput: 80,
                output: 20,
                reasoningOutput: 5,
                unclassified: 10),
            contextTokens: 30_000,
            contextWindow: 100_000,
            duration: 65,
            isStalled: false,
            isActive: true)

        let presentation = agentConversationSummaryPresentation(snapshot)

        XCTAssertEqual(presentation.stateText, "4 agents active")
        XCTAssertEqual(
            presentation.metricVariants.first,
            "135 processed · 25 generated · 80% from cache · 30.0K/100.0K context · 1:05")
        XCTAssertTrue(presentation.accessibilityText.contains("4 agents active"))
        XCTAssertTrue(presentation.accessibilityText.contains("135 processed"))
        XCTAssertTrue(presentation.accessibilityText.contains("Tool mix: Read 6, rg 4"))
    }

    func testConversationSummaryLayoutNeverOverlapsAtNarrowDefaultOrWideWidths() {
        let metricWidths: [CGFloat] = [280, 210, 130, 60]
        let cases: [(width: CGFloat, wraps: Bool, metricIndex: Int)] = [
            (240, true, 2),
            (420, true, 0),
            (900, false, 0),
        ]

        for testCase in cases {
            let layout = agentConversationSummaryLayout(
                width: testCase.width,
                titleWidth: 80,
                stateIsEmpty: false,
                metricWidths: metricWidths,
                hasComposition: true)

            XCTAssertEqual(layout.wrapsMetrics, testCase.wraps, "width \(testCase.width)")
            XCTAssertEqual(
                layout.metricsVariantIndex,
                testCase.metricIndex,
                "width \(testCase.width)")
            XCTAssertLessThanOrEqual(layout.height, 77)
            XCTAssertEqual(
                layout.metricsFrame.width,
                metricWidths[testCase.metricIndex],
                "metrics receive their measured width, never the former 190-point cap")
            for frame in layout.visibleFrames {
                XCTAssertGreaterThanOrEqual(frame.minX, 0, "width \(testCase.width)")
                XCTAssertLessThanOrEqual(frame.maxX, testCase.width, "width \(testCase.width)")
            }
            for first in layout.visibleFrames.indices {
                for second in layout.visibleFrames.indices where second > first {
                    XCTAssertFalse(
                        layout.visibleFrames[first].intersects(layout.visibleFrames[second]),
                        "frames \(first) and \(second) overlap at width \(testCase.width)")
                }
            }
        }
    }

    func testConversationSummaryLayoutIsDeterministic() {
        let first = agentConversationSummaryLayout(
            width: 360,
            titleWidth: 80,
            stateIsEmpty: false,
            metricWidths: [250, 180, 100],
            hasComposition: true)
        let second = agentConversationSummaryLayout(
            width: 360,
            titleWidth: 80,
            stateIsEmpty: false,
            metricWidths: [250, 180, 100],
            hasComposition: true)

        XCTAssertEqual(first, second)
    }

    func testConversationSummaryUltraNarrowLayoutKeepsAnEllipsizedMetricRow() {
        let layout = agentConversationSummaryLayout(
            width: 80,
            titleWidth: 80,
            stateIsEmpty: false,
            metricWidths: [280, 210, 130, 60],
            hasComposition: true)

        XCTAssertEqual(layout.metricsVariantIndex, 3)
        XCTAssertTrue(layout.wrapsMetrics)
        XCTAssertGreaterThan(layout.metricsFrame.width, 0)
        XCTAssertEqual(layout.metricsFrame.width, 39)
        XCTAssertFalse(layout.metricsFrame.intersects(layout.compositionFrame))
        XCTAssertTrue(layout.visibleFrames.allSatisfy { $0.maxX <= 80 })
    }

    func testSubagentCardKeepsModelCurrentWorkMetricsSummaryAndToolMixIndependent() {
        let now = Date(timeIntervalSince1970: 8_000)
        var subagent = SubagentRun(
            key: "child",
            subagentType: "Explore",
            task: "Audit the native Agents card")
        subagent.model = "gpt-5.2-codex"
        subagent.summary = "Found the presentation mismatch"
        subagent.tokens = 1_240
        subagent.toolUses = 8
        subagent.toolUsesObserved = true
        subagent.startedAt = now.addingTimeInterval(-65)
        let activity = AgentActivityCardSnapshot(
            currentStep: AgentStepSnapshot(
                phase: .tool,
                label: "Bash",
                target: "rg -n model AppKitAgentsPanel.swift",
                since: now.addingTimeInterval(-5),
                duration: 5),
            toolComposition: [
                AgentToolShare(name: "rg", count: 5, share: 0.625),
                AgentToolShare(name: "Read", count: 3, share: 0.375),
            ],
            tokenUsage: AgentActivityTokenBreakdown(),
            isStalled: false)

        let presentation = appKitSubagentCardPresentation(
            subagent,
            ordinal: 2,
            activity: activity,
            now: now)

        XCTAssertEqual(presentation.badges.map(\.text), ["A2", "Explore", "gpt-5.2-codex"])
        XCTAssertEqual(presentation.modelBadge, "gpt-5.2-codex")
        XCTAssertEqual(presentation.stateBand, "rg · rg -n model AppKitAgentsPanel.swift · 5s")
        XCTAssertEqual(presentation.metrics, "1.2K tokens · 8 observed tools")
        XCTAssertEqual(presentation.summary, "Found the presentation mismatch")
        XCTAssertEqual(presentation.toolComposition.map(\.name), ["rg", "Read"])
        XCTAssertTrue(presentation.accessibilityText.contains("Model gpt-5.2-codex"))
        XCTAssertTrue(presentation.accessibilityText.contains("1.2K tokens · 8 observed tools"))

        let cell = AppKitAgentTableCellView(
            frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        cell.configure(
            subagent: subagent,
            ordinal: 2,
            depth: 0,
            compact: false,
            activityIndex: AgentActivityLedgerIndex([]),
            now: now,
            onStop: { _ in })
        XCTAssertEqual(cell.presentationForTesting?.modelBadge, "gpt-5.2-codex")
        XCTAssertFalse(cell.disclosureForTesting.isHidden)
        XCTAssertEqual(cell.statusTooltipForTesting, "Working")
        XCTAssertTrue(
            cell.subviews.contains { $0 is OrbitingDotsLayerView && !$0.isHidden },
            "Running native cards use Mechanician's orbiting-dots activity mark.")
        XCTAssertFalse(
            cell.subviews.contains { $0 is NSProgressIndicator },
            "Native cards must not fall back to AppKit's stock spinner.")
        XCTAssertTrue(cell.accessibilityLabel()?.contains("Model gpt-5.2-codex") == true)
    }

    func testCardNeverInventsAChildModelWhenProviderReportedNone() {
        var subagent = SubagentRun(
            key: "child",
            subagentType: "Explore",
            task: "Inspect the panel")
        subagent.model = " \n "

        let presentation = appKitSubagentCardPresentation(
            subagent,
            ordinal: 1,
            activity: AgentActivityCardSnapshot(
                currentStep: nil,
                toolComposition: [],
                tokenUsage: AgentActivityTokenBreakdown(),
                isStalled: false),
            now: subagent.startedAt)

        XCTAssertNil(presentation.modelBadge)
        XCTAssertFalse(presentation.badges.contains { $0.tone == .model })
        XCTAssertFalse(presentation.accessibilityText.contains("Model"))
    }

    func testWorkflowAgentCardShowsGlobalOrdinalAttemptReportedModelAndObservedTools() {
        let now = Date(timeIntervalSince1970: 9_000)
        var first = WorkflowAgent(
            index: 1,
            label: "planner",
            phaseIndex: 0,
            phaseTitle: "Plan",
            state: .done)
        first.startedAt = now.addingTimeInterval(-80)
        var agent = WorkflowAgent(
            index: 1,
            label: "correctness",
            phaseIndex: 1,
            phaseTitle: "Verify",
            state: .progress)
        agent.model = "claude-sonnet-4-5"
        agent.attempt = 3
        agent.promptPreview = "Verify every AppKit field"
        agent.tokens = 2_500
        agent.toolCalls = 3
        agent.startedAt = now.addingTimeInterval(-40)
        agent.toolEvents = [
            SubagentToolEvent(name: "Bash", target: "rg -n status AppKitAgentsPanel.swift"),
            SubagentToolEvent(name: "Read", target: "AppKitAgentsPanel.swift"),
            SubagentToolEvent(name: "Bash", target: "rg -n model WorkflowViews.swift"),
        ]
        var run = WorkflowRun(runKey: "run")
        run.workflowName = "review"
        run.startedAt = now.addingTimeInterval(-90)
        run.agents = [first.id: first, agent.id: agent]

        let presentation = appKitWorkflowAgentCardPresentation(
            agent,
            in: run,
            ordinal: 2,
            activity: AgentActivityCardSnapshot(
                currentStep: nil,
                toolComposition: [],
                tokenUsage: AgentActivityTokenBreakdown(),
                isStalled: false),
            now: now)

        XCTAssertEqual(
            presentation.badges.map(\.text),
            ["A2", "correctness", "claude-sonnet-4-5", "↻3"])
        XCTAssertEqual(presentation.metrics, "2.5K tokens · 3 tool calls")
        XCTAssertEqual(presentation.toolComposition.map(\.name), ["rg", "Read"])
        XCTAssertEqual(presentation.toolComposition.map(\.count), [2, 1])
        XCTAssertTrue(presentation.accessibilityText.contains("Attempt 3"))
        XCTAssertTrue(presentation.accessibilityText.contains("Model claude-sonnet-4-5"))
    }

    func testCardPreferredHeightGrowsForIndependentOptionalRows() {
        let base = AppKitAgentCardPresentation(
            status: .completed,
            badges: [],
            title: "Agent",
            task: "Short task",
            stateBand: nil,
            metrics: nil,
            summary: nil,
            error: nil,
            meta: "1:00 PM · 10s",
            toolComposition: [],
            disclosureLabel: "Open",
            accessibilityText: "Agent")
        var rich = base
        rich.stateBand = "rg · query · 5s"
        rich.metrics = "1.2K tokens · 8 observed tools"
        rich.summary = "A two-line summary that remains distinct from both metrics and current work."
        rich.error = "Provider error"
        rich.toolComposition = [AgentToolShare(name: "rg", count: 1, share: 1)]

        let baseHeight = AppKitAgentTableCellView.preferredHeight(
            for: base,
            width: 420,
            depth: 0)
        let richHeight = AppKitAgentTableCellView.preferredHeight(
            for: rich,
            width: 420,
            depth: 0)
        let narrowHeight = AppKitAgentTableCellView.preferredHeight(
            for: rich,
            width: 240,
            depth: 1)

        XCTAssertGreaterThan(richHeight, baseHeight)
        XCTAssertGreaterThanOrEqual(narrowHeight, richHeight)
    }

    func testTerminalWorkflowWithLiveChildRemainsActiveStoppableAndVisiblyLive() {
        let now = Date(timeIntervalSince1970: 10_000)
        var child = WorkflowAgent(
            index: 1,
            label: "background",
            phaseIndex: 0,
            phaseTitle: "Finish",
            state: .progress)
        child.startedAt = now.addingTimeInterval(-30)
        var run = WorkflowRun(runKey: "run")
        run.status = .completed
        run.startedAt = now.addingTimeInterval(-60)
        run.endedAt = now.addingTimeInterval(-10)
        run.runTaskId = "task-run"
        run.agents = [child.id: child]

        let list = AppKitAgentsListSnapshot.make(
            subagents: [:],
            workflowRuns: [run.runKey: run],
            search: "",
            attentionExpanded: true,
            completedExpanded: false)
        XCTAssertEqual(list.activeCount, 1)
        XCTAssertEqual(list.completedCount, 0)
        XCTAssertTrue(list.items.contains(.workflow(key: "run", expanded: false)))

        let presentation = appKitWorkflowCardPresentation(run, expanded: false, now: now)
        XCTAssertEqual(presentation.status, .running)
        XCTAssertTrue(presentation.stateBand?.contains("1 agent active") == true)
        XCTAssertTrue(presentation.meta.hasSuffix("1:00"), presentation.meta)

        let cell = AppKitAgentTableCellView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        cell.configure(
            workflow: run,
            expanded: false,
            compact: false,
            now: now,
            onStop: { _ in })
        XCTAssertFalse(cell.stopButtonForTesting?.isHidden ?? true)
        XCTAssertEqual(cell.presentationForTesting?.status, .running)
    }

    func testExpandedWorkflowCardShowsProgressAndAccessibleOutputOpenAction() throws {
        let now = Date(timeIntervalSince1970: 10_500)
        var completed = WorkflowAgent(
            index: 1,
            label: "writer",
            phaseIndex: 0,
            phaseTitle: "Write",
            state: .done)
        completed.startedAt = now.addingTimeInterval(-60)
        completed.endedAt = now.addingTimeInterval(-20)
        var running = WorkflowAgent(
            index: 2,
            label: "reviewer",
            phaseIndex: 1,
            phaseTitle: "Review",
            state: .progress)
        running.startedAt = now.addingTimeInterval(-20)

        let outputPath = "/tmp/mechanician-workflow-report.md"
        var run = WorkflowRun(runKey: "workflow-progress")
        run.workflowName = "write-report"
        run.status = .running
        run.startedAt = now.addingTimeInterval(-60)
        run.outputFile = outputPath
        run.agents = [completed.id: completed, running.id: running]

        let presentation = appKitWorkflowCardPresentation(run, expanded: true, now: now)
        XCTAssertEqual(
            presentation.progress,
            AppKitAgentProgress(completed: 1, total: 2))
        XCTAssertEqual(presentation.outputFile, outputPath)
        XCTAssertTrue(presentation.accessibilityText.contains("Output \(outputPath)"))
        XCTAssertNil(
            appKitWorkflowCardPresentation(run, expanded: false, now: now).outputFile,
            "The inline output action follows the workflow disclosure just like the SwiftUI card.")

        let height = AppKitAgentTableCellView.preferredHeight(
            for: presentation,
            width: 420,
            depth: 0)
        let cell = AppKitAgentTableCellView(
            frame: NSRect(x: 0, y: 0, width: 420, height: height))
        var opened: [URL] = []
        cell.outputOpener = { opened.append($0) }
        cell.configure(
            workflow: run,
            expanded: true,
            compact: false,
            now: now,
            onStop: { _ in })
        cell.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            cell.workflowProgressForTesting,
            AppKitAgentProgress(completed: 1, total: 2))
        let progress = try XCTUnwrap(cell.subviews.first {
            $0.accessibilityRole() == .progressIndicator
        })
        XCTAssertEqual(progress.accessibilityLabel(), "Workflow progress")
        XCTAssertEqual(
            progress.accessibilityValue() as? String,
            "1 of 2 agents complete")

        let open = cell.openOutputButtonForTesting
        XCTAssertFalse(open.isHidden)
        XCTAssertEqual(
            open.accessibilityLabel(),
            "Open workflow output mechanician-workflow-report.md")
        cell.pressOpenOutputForTesting()
        XCTAssertEqual(opened.map(\.path), [outputPath])
    }

    func testCardErrorsUseAWarningGlyphAndKeepTheFullAccessibleError() {
        let now = Date(timeIntervalSince1970: 10_750)
        var failed = SubagentRun(
            key: "failed",
            subagentType: "reviewer",
            task: "Review the workflow")
        failed.status = .failed
        failed.error = "Provider rejected the request"

        let presentation = appKitSubagentCardPresentation(
            failed,
            ordinal: 1,
            activity: AgentActivityCardSnapshot(
                currentStep: nil,
                toolComposition: [],
                tokenUsage: AgentActivityTokenBreakdown(),
                isStalled: false),
            now: now)
        let cell = AppKitAgentTableCellView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 420,
                height: AppKitAgentTableCellView.preferredHeight(
                    for: presentation,
                    width: 420,
                    depth: 0)))
        cell.configure(
            subagent: failed,
            ordinal: 1,
            depth: 0,
            compact: false,
            activityIndex: AgentActivityLedgerIndex([]),
            now: now,
            onStop: { _ in })
        cell.layoutSubtreeIfNeeded()

        XCTAssertFalse(cell.errorGlyphForTesting.isHidden)
        XCTAssertNotNil(cell.errorGlyphForTesting.image)
        XCTAssertTrue(
            cell.accessibilityLabel()?.contains("Error Provider rejected the request") == true)

        var recovered = failed
        recovered.status = .completed
        recovered.error = nil
        cell.configure(
            subagent: recovered,
            ordinal: 1,
            depth: 0,
            compact: false,
            activityIndex: AgentActivityLedgerIndex([]),
            now: now,
            onStop: { _ in })
        cell.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            cell.errorGlyphForTesting.isHidden,
            "A recycled native cell must not retain a previous agent's warning glyph.")
    }

    func testNativeDetailPanesRetainReportedChildModelsAndAttempt() {
        let now = Date(timeIntervalSince1970: 11_000)
        var subagent = SubagentRun(
            key: "child",
            subagentType: "Explore",
            task: "Audit models")
        subagent.model = "  child/model-1  "
        let detail = AppKitAgentDetailView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 500))
        detail.configure(subagent: subagent, ordinal: 1, activity: [], now: now)
        XCTAssertTrue(detail.detailTextForTesting.contains("MODEL\nchild/model-1"))
        XCTAssertTrue(detail.accessibilityLabel()?.contains("Model   child/model-1  ") == true)

        var agent = WorkflowAgent(
            index: 1,
            label: "reviewer",
            phaseIndex: 0,
            phaseTitle: "Review",
            state: .progress)
        agent.model = "gpt-5.2-codex"
        agent.attempt = 2
        var workflow = WorkflowRun(runKey: "workflow")
        workflow.agents = [agent.id: agent]
        detail.configure(
            workflowAgent: agent,
            in: workflow,
            activity: [],
            now: now)
        XCTAssertTrue(detail.detailTextForTesting.contains("MODEL\ngpt-5.2-codex"))
        XCTAssertTrue(detail.detailTextForTesting.contains("Attempt 2"))
        XCTAssertTrue(detail.accessibilityLabel()?.contains("Model gpt-5.2-codex") == true)
    }

    func testRootRowIsStructuralBeforeChildGroupsAndDoesNotChangeChildCounts() {
        var child = SubagentRun(
            key: "child",
            subagentType: "Explore",
            task: "Inspect activity")
        child.status = .running

        let snapshot = AppKitAgentsListSnapshot.make(
            subagents: [child.key: child],
            workflowRuns: [:],
            search: "",
            attentionExpanded: true,
            completedExpanded: false,
            includeRoot: true)

        XCTAssertEqual(snapshot.items, [
            .root,
            .group(.active, count: 1, expanded: true),
            .subagent(key: "child", depth: 0),
        ])
        XCTAssertEqual(snapshot.activeCount, 1)
        XCTAssertEqual(snapshot.attentionCount, 0)
        XCTAssertEqual(snapshot.completedCount, 0)
        XCTAssertEqual(snapshot.unfilteredCount, 1)

        let rootOnlySearchResult = AppKitAgentsListSnapshot.make(
            subagents: [child.key: child],
            workflowRuns: [:],
            search: "no child matches this",
            attentionExpanded: true,
            completedExpanded: false,
            includeRoot: true)
        XCTAssertEqual(rootOnlySearchResult.items, [.root])
        XCTAssertEqual(rootOnlySearchResult.activeCount, 0)
        XCTAssertEqual(
            rootOnlySearchResult.unfilteredCount,
            1,
            "The structural root is not a child-search result or a child count.")

        let rootWithoutChildren = AppKitAgentsListSnapshot.make(
            subagents: [:],
            workflowRuns: [:],
            search: "",
            attentionExpanded: true,
            completedExpanded: false,
            includeRoot: true)
        XCTAssertEqual(rootWithoutChildren.items, [.root])
        XCTAssertEqual(
            rootWithoutChildren.unfilteredCount,
            0,
            "Root-only panels do not show child filter/density controls.")
    }

    func testRootCardSeparatesRequestedAndProviderReportedModelsAndUsesRootOnlyStats() {
        let now = Date(timeIntervalSince1970: 12_100)
        let requested = AgentRootActivitySnapshot(
            turnID: "turn",
            providerAccess: .codexSubscription,
            requestedModelID: "gpt-requested",
            providerReportedModelID: nil,
            phase: .tool,
            startedAt: now.addingTimeInterval(-65),
            terminalAt: nil,
            currentStep: AgentStepSnapshot(
                phase: .tool,
                label: "Bash",
                target: "rg -n root AppKitAgentsPanel.swift",
                since: now.addingTimeInterval(-5),
                duration: 5),
            tokenUsage: AgentActivityTokenBreakdown(
                input: 100,
                cachedInput: 80,
                output: 20,
                reasoningOutput: 5,
                unclassified: 10),
            observedToolCount: 3,
            toolComposition: [
                AgentToolShare(name: "rg", count: 2, share: 2.0 / 3.0),
                AgentToolShare(name: "Read", count: 1, share: 1.0 / 3.0),
            ],
            isStalled: true,
            isActive: true,
            duration: 65)

        let provisional = appKitRootAgentCardPresentation(requested)
        XCTAssertEqual(provisional.status, .running)
        XCTAssertEqual(
            provisional.badges.map(\.text),
            ["Codex subscription", "Requested · gpt-requested"])
        XCTAssertEqual(
            provisional.badges.map(\.tone),
            [.type, .neutral])
        XCTAssertNil(provisional.modelBadge)
        XCTAssertEqual(
            provisional.stateBand,
            "Possibly stalled · rg · rg -n root AppKitAgentsPanel.swift · 5s")
        XCTAssertEqual(provisional.metrics, "135 processed · 3 tool calls")
        XCTAssertEqual(provisional.toolComposition.map(\.name), ["rg", "Read"])
        XCTAssertFalse(provisional.isExpandable)
        XCTAssertTrue(
            provisional.accessibilityText.contains(
                "Requested model gpt-requested, awaiting provider confirmation"))
        XCTAssertTrue(provisional.accessibilityText.contains("Tool mix rg 2, Read 1"))

        var confirmed = requested
        confirmed.providerReportedModelID = "gpt-provider-reported"
        let providerReported = appKitRootAgentCardPresentation(confirmed)
        XCTAssertEqual(
            providerReported.badges.map(\.text),
            ["Codex subscription", "Reported · gpt-provider-reported"])
        XCTAssertEqual(
            providerReported.badges.map(\.tone),
            [.type, .model])
        XCTAssertEqual(
            providerReported.modelBadge,
            "Reported · gpt-provider-reported")
        XCTAssertTrue(
            providerReported.accessibilityText.contains(
                "Provider-reported model gpt-provider-reported"))
        XCTAssertFalse(
            providerReported.accessibilityText.contains(
                "awaiting provider confirmation"))
    }

    func testRootCardHasIndependentStopControlAndNoChildDisclosure() throws {
        _ = NSApplication.shared
        let now = Date(timeIntervalSince1970: 12_200)
        var root = AgentRootActivitySnapshot(
            turnID: nil,
            providerAccess: .codexSubscription,
            requestedModelID: "gpt-requested",
            providerReportedModelID: nil,
            phase: .model,
            startedAt: now.addingTimeInterval(-2),
            terminalAt: nil,
            currentStep: nil,
            tokenUsage: AgentActivityTokenBreakdown(),
            observedToolCount: 0,
            toolComposition: [],
            isStalled: false,
            isActive: true,
            duration: 2)
        let cell = AppKitAgentTableCellView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 90))
        var stops = 0

        cell.configure(
            root: root,
            compact: false,
            onStop: { stops += 1 })

        let button = try XCTUnwrap(cell.stopButtonForTesting)
        XCTAssertFalse(button.isHidden)
        XCTAssertNotNil(button.image)
        XCTAssertEqual(button.imagePosition, .imageOnly)
        XCTAssertNil(button.contentTintColor)
        XCTAssertEqual(button.toolTip, "Stop root agent")
        XCTAssertEqual(button.accessibilityLabel(), "Stop root agent")
        XCTAssertTrue(cell.disclosureForTesting.isHidden)
        XCTAssertEqual(cell.accessibilityRole(), .group)
        XCTAssertEqual(cell.presentationForTesting?.stateBand, "Starting · 2s")
        cell.pressStopForTesting()
        XCTAssertEqual(stops, 1)

        root.phase = .completed
        root.terminalAt = now
        root.isActive = false
        cell.configure(root: root, compact: false, onStop: { stops += 1 })
        XCTAssertTrue(button.isHidden)
        XCTAssertTrue(cell.disclosureForTesting.isHidden)
        XCTAssertEqual(cell.presentationForTesting?.status, .completed)
        XCTAssertEqual(stops, 1)
    }

    @MainActor
    private func drainMainQueue(passes: Int = 4) async {
        for _ in 0..<passes {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @MainActor
    private func runMainRunLoop(in mode: RunLoop.Mode, for interval: TimeInterval) {
        let end = Date().addingTimeInterval(interval)
        while Date() < end {
            _ = RunLoop.main.run(mode: mode, before: end)
        }
    }

    @MainActor
    @discardableResult
    private func runMainRunLoop(
        in mode: RunLoop.Mode,
        until predicate: () -> Bool,
        timeout: TimeInterval = 1
    ) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < end {
            _ = RunLoop.main.run(mode: mode, before: end)
        }
        return predicate()
    }

    private func resolve(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    private func contrastBetween(_ lhs: NSColor, _ rhs: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let value = color.usingColorSpace(.sRGB)!
            func linear(_ channel: CGFloat) -> Double {
                let component = Double(channel)
                return component <= 0.03928
                    ? component / 12.92
                    : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(value.redComponent)
                + 0.7152 * linear(value.greenComponent)
                + 0.0722 * linear(value.blueComponent)
        }

        let a = luminance(lhs)
        let b = luminance(rhs)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// A tool span wears its own tool's ray, so the trace shows WHICH tool ran rather than repeating
/// "this is a tool" — information the row already carries. Labels use one white treatment while
/// the fill continues to carry tool identity.
final class ToolSpanIdentityColorTests: XCTestCase {
    private func resolve(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        color.mechanicianResolved(in: appearance).usingColorSpace(.sRGB)!
    }

    func testASpanUsesTheSameRayTheAgentCardGivesThatTool() {
        for tool in ["git", "export", "Bash", "Read", "WebSearch"] {
            XCTAssertEqual(
                appKitAgentActivitySpanFillColor(.tool, tool: tool),
                appKitToolColor(forTool: tool),
                "\(tool) must look the same in the trace as on the agent card")
        }
        // Different tools must not collapse to one band, which is what a single phase colour did.
        let distinct = Set(["git", "export", "Bash", "Read"].map {
            appKitToolColor(forTool: $0).mechanicianResolved(in: NSAppearance(named: .aqua)!)
                .usingColorSpace(.sRGB)!.description
        })
        XCTAssertGreaterThan(distinct.count, 1)
    }

    func testEveryToolRayUsesWhiteLabelInk() {
        let tools = ["git", "export", "Bash", "Read", "WebSearch", "Edit", "Glob", "other"]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            let background = resolve(.nElevated, in: appearance)
            for tool in tools {
                let ink = resolve(
                    appKitAgentActivitySpanLabelColor(
                        .tool, tool: tool, background: background, appearance: appearance),
                    in: appearance)
                let white = resolve(.white, in: appearance)
                XCTAssertEqual(ink.redComponent, white.redComponent, accuracy: 0.01)
                XCTAssertEqual(ink.greenComponent, white.greenComponent, accuracy: 0.01)
                XCTAssertEqual(ink.blueComponent, white.blueComponent, accuracy: 0.01)
            }
        }
    }
}

/// A key that names a colour the chart no longer draws is worse than no key: it is read as fact.
/// Tool spans stopped being one orange when they started wearing their own tool's ray, and the
/// legend went on showing a single orange chip. These pin the key to the chart rather than to a
/// remembered colour.
final class TraceLegendSwatchTests: XCTestCase {
    private func key(_ color: NSColor, _ appearance: NSAppearance) -> String {
        color.mechanicianResolved(in: appearance).usingColorSpace(.sRGB)!.description
    }

    /// Every colour a tool span can actually be painted, including the unnamed-tool fallback.
    private func reachableToolColors(in appearance: NSAppearance) -> Set<String> {
        var names = ["git", "Bash", "Read", "Edit", "Glob", "WebSearch", "export", "other"]
        names.append(contentsOf: (0..<200).map { "tool-\($0)" })
        var colors = Set(names.map { key(appKitAgentActivitySpanFillColor(.tool, tool: $0), appearance) })
        colors.insert(key(appKitAgentActivitySpanFillColor(.tool, tool: nil), appearance))
        return colors
    }

    func testTheToolSwatchShowsEveryColourAToolSpanCanTake() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            let swatch = Set(appKitTraceLegendSwatchColors(.tool).map { key($0, appearance) })
            XCTAssertEqual(
                swatch,
                reachableToolColors(in: appearance),
                "\(name.rawValue): the key must show exactly the colours tool spans are drawn in — "
                    + "no missing ray, and no colour the chart never draws")
        }
    }

    /// The specific regression: one orange chip for a mark that is six colours.
    func testTheToolSwatchIsNotASingleColour() {
        let appearance = NSAppearance(named: .aqua)!
        let swatch = Set(appKitTraceLegendSwatchColors(.tool).map { key($0, appearance) })
        XCTAssertGreaterThan(swatch.count, 1)
        XCTAssertNotEqual(
            appKitTraceLegendSwatchColors(.tool).count,
            1,
            "a single chip states that every tool is one colour, which the chart no longer does")
    }

    /// The other marks genuinely are one colour each, and the drawing takes the first entry, so an
    /// empty swatch would crash rather than merely mislead.
    func testEveryOtherMarkIsExactlyItsPhaseColour() {
        let others: [AgentActivityPhase] = [.model, .waiting, .compacting, .completed, .failed, .stopped]
        for phase in others {
            let swatch = appKitTraceLegendSwatchColors(phase)
            XCTAssertEqual(swatch.count, 1, "\(phase) must have one swatch colour")
            XCTAssertEqual(swatch.first, appKitAgentActivityPhaseColor(phase))
        }
        XCTAssertFalse(appKitTraceLegendSwatchColors(.tool).isEmpty)
    }
}
