import AppKit
import XCTest
@testable import Mechanician

final class ActivityGroupingTests: XCTestCase {
    @MainActor
    func testOrbitingDotsUseThreeNonTerminalLaserAnchorsInBothAppearances() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let view = OrbitingDotsLayerView()
            view.appearance = NSAppearance(named: appearanceName)
            view.configure(color: nil, reduceMotion: true)

            let actual = view.coreColorsForTesting
            let expected = MagicLaserSpectrum.resolvedColors(
                MagicLaserSpectrum.spinnerColors,
                in: try XCTUnwrap(view.appearance))
            XCTAssertEqual(actual.count, 3)
            for (lhs, rhs) in zip(actual, expected) {
                XCTAssertEqual(lhs.redComponent, rhs.redComponent, accuracy: 0.01)
                XCTAssertEqual(lhs.greenComponent, rhs.greenComponent, accuracy: 0.01)
                XCTAssertEqual(lhs.blueComponent, rhs.blueComponent, accuracy: 0.01)
            }
        }
    }

    @MainActor
    func testOrbitingDotsPreserveMonochromeOverrides() {
        let view = OrbitingDotsLayerView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        view.configure(color: .white, reduceMotion: true, showsGlow: false)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.coreColorsForTesting.count, 3)
        XCTAssertTrue(
            view.coreDiametersForTesting.allSatisfy { $0 >= 5.5 },
            "removing the selected-row halo should spend its footprint on legible cores")
        XCTAssertTrue(
            view.glowsAreHiddenForTesting,
            "selected white dots must not acquire a disc-like halo")
        for color in view.coreColorsForTesting {
            let resolved = color.usingColorSpace(.sRGB)!
            XCTAssertEqual(resolved.redComponent, 1, accuracy: 0.01)
            XCTAssertEqual(resolved.greenComponent, 1, accuracy: 0.01)
            XCTAssertEqual(resolved.blueComponent, 1, accuracy: 0.01)
        }

        view.configure(color: nil, reduceMotion: true)
        XCTAssertFalse(
            view.glowsAreHiddenForTesting,
            "ordinary three-color spinners retain their restrained brand glow")
    }

    @MainActor
    func testOrbitingDotsClipByDefaultButAllowConversationRowHaloOverflow() {
        let view = OrbitingDotsLayerView()

        XCTAssertEqual(view.layer?.masksToBounds, true)

        view.configure(color: nil, reduceMotion: true, allowsVisualOverflow: true)
        XCTAssertEqual(
            view.layer?.masksToBounds,
            false,
            "Conversation rows have enough reserved space for the complete animated halo.")

        view.configure(color: nil, reduceMotion: true)
        XCTAssertEqual(
            view.layer?.masksToBounds,
            true,
            "Compact transcript activity rows must retain their glow containment.")
    }

    func testConsecutiveRoutineToolsBecomeOneActivitySpan() {
        let entries = [
            TranscriptEntry(kind: .user, text: "Please fix it"),
            tool("Read"),
            tool("Edit"),
            tool("Bash"),
            TranscriptEntry(kind: .assistant, text: "Done"),
        ]

        XCTAssertEqual(transcriptRowSpans(entries), [
            TranscriptRowSpan(kind: .entry, range: 0..<1),
            TranscriptRowSpan(kind: .activity, range: 1..<4),
            TranscriptRowSpan(kind: .entry, range: 4..<5),
        ])
    }

    func testSingleRoutineToolStartsAsActivityWhileProviderWorkflowRemainsIndependent() {
        let entries = [
            tool("Read"),
            TranscriptEntry(kind: .assistant, text: "Found it"),
            tool("Workflow"),
            tool("Edit"),
            tool("Bash"),
        ]

        XCTAssertEqual(transcriptRowSpans(entries), [
            TranscriptRowSpan(kind: .activity, range: 0..<1),
            TranscriptRowSpan(kind: .entry, range: 1..<2),
            TranscriptRowSpan(kind: .entry, range: 2..<3),
            TranscriptRowSpan(kind: .activity, range: 3..<5),
        ])
    }

    func testGeneratedImageRemainsAnInlineTranscriptEntry() {
        let entries = [
            tool("Read"),
            tool("ImageGeneration"),
            tool("Edit"),
        ]

        XCTAssertEqual(transcriptRowSpans(entries), [
            TranscriptRowSpan(kind: .activity, range: 0..<1),
            TranscriptRowSpan(kind: .entry, range: 1..<2),
            TranscriptRowSpan(kind: .activity, range: 2..<3),
        ])
    }

    func testActivitySummaryBreaksActionsOutByStableCategoryCounts() {
        let actions = [
            activity("edit-1", "Edit", .running),
            activity("edit-2", "Write", .succeeded),
            activity("read-1", "Read", .succeeded),
            activity("bash-1", "Bash", .running),
            activity("bash-2", "Bash", .succeeded),
            activity("bash-3", "Bash", .failed),
        ]

        XCTAssertEqual(activitySummary(actions), "2 writes · 1 read · 3 commands")
        XCTAssertEqual(
            activitySummary(actions.map { action in
                AppKitActivityAction(
                    id: action.id, sourceIndex: action.sourceIndex,
                    toolName: action.toolName, rawInput: action.rawInput,
                    state: .succeeded)
            }),
            "2 writes · 1 read · 3 commands",
            "Terminal state changes must not rewrite or resize the category summary.")
    }

    func testSupersededActivityPresentationCountsAndExplainsRetainedEvidence() {
        let ordinary = activity("read", "Read", .succeeded)
        let superseded = AppKitActivityAction(
            id: AnyHashable("bash"),
            sourceIndex: 1,
            toolName: "Bash",
            rawInput: "{}",
            state: .succeeded,
            isSuperseded: true)
        let group = AppKitActivityGroup(
            id: AnyHashable("activity"),
            actions: [ordinary, superseded],
            chatScale: 1)

        XCTAssertEqual(group.supersededCount, 1)
        XCTAssertEqual(
            supersededActionAccessibilityLabel("Ran tests.", isSuperseded: true),
            "Ran tests. Superseded. Retained as audit evidence because this action may already have run.")
        XCTAssertEqual(
            supersededActionAccessibilityLabel("Read file", isSuperseded: false),
            "Read file")
        XCTAssertEqual(
            activityGroupAccessibilityLabel("1 read · 1 command", supersededCount: 1),
            "1 read · 1 command. 1 superseded action is retained as audit evidence.")
    }

    func testHistoricalResultlessToolIsStoppedWhileLiveToolStillRuns() {
        let historical = tool("Bash")
        XCTAssertEqual(historical.resolvedToolState, .stopped)

        var live = tool("Bash")
        live.toolState = .running
        XCTAssertEqual(live.resolvedToolState, .running)

        live.toolResult = "Exit code: 143"
        live.toolIsError = true
        XCTAssertEqual(live.resolvedToolState, .failed,
                       "A terminal result must override a stale running lifecycle value.")
    }

    func testHistoricalToolWithoutLifecycleFieldStillDecodesAsStopped() throws {
        let json = #"{"id":"10400000-0000-4000-8000-000000000099","kind":"tool","text":"legacy command","toolName":"Bash","toolUseId":"legacy","toolIsError":false,"permDecided":false,"permAllowed":false}"#
        let entry = try JSONDecoder().decode(TranscriptEntry.self, from: Data(json.utf8))

        XCTAssertNil(entry.toolState)
        XCTAssertEqual(entry.resolvedToolState, .stopped)
    }

    func testTerminalReconciliationStopsOnlyUnfinishedTools() {
        var live = tool("Bash")
        live.toolState = .running
        var finished = tool("Read")
        finished.toolState = .running
        finished.toolResult = "contents"
        var entries = [live, finished, TranscriptEntry(kind: .assistant, text: "Done")]

        XCTAssertTrue(stopUnfinishedToolEntries(&entries))
        XCTAssertEqual(entries[0].resolvedToolState, .stopped)
        XCTAssertEqual(entries[1].resolvedToolState, .succeeded)
        XCTAssertFalse(stopUnfinishedToolEntries(&entries), "Reconciliation must be idempotent.")
    }

    func testToolResultMatchesStableIDAfterTransientIndexCacheIsLost() {
        var first = tool("Bash")
        first.toolUseId = "first"
        first.toolState = .running
        var second = tool("Bash")
        second.toolUseId = "second"
        second.toolState = .running
        let entries = [first, second]

        XCTAssertEqual(toolEntryIndex(for: "first", in: entries), 0)
        XCTAssertEqual(toolEntryIndex(for: "second", in: entries), 1)
        XCTAssertNil(toolEntryIndex(for: "unknown", in: entries),
                     "An identified result must never complete a different tool row.")
    }

    @MainActor
    func testTerminalToolInputBackfillsAQueryMissingAtStart() {
        var entry = tool("WebSearch")
        entry.text = #"{"query":""}"#
        entry.toolState = .running

        AgentBridge.applyToolResult([
            "input": ["query": "macOS toolbar toggle guidance"],
            "result": "Search completed.",
            "status": "success",
        ], to: &entry)

        XCTAssertEqual(entry.text, #"{"query":"macOS toolbar toggle guidance"}"#)
        XCTAssertEqual(entry.toolResult, "Search completed.")
        XCTAssertEqual(entry.resolvedToolState, .succeeded)
    }

    @MainActor
    func testTerminalToolInputDoesNotReplaceAQueryKnownAtStart() {
        var entry = tool("WebSearch")
        entry.text = #"{"query":"original query"}"#

        AgentBridge.applyToolResult([
            "input": ["query": "late query"],
            "result": "Search completed.",
            "status": "success",
        ], to: &entry)

        XCTAssertEqual(entry.text, #"{"query":"original query"}"#)
        XCTAssertEqual(entry.resolvedToolState, .succeeded)
    }

    @MainActor
    func testLiveToolStatusUsesStableSemanticLabelsInsteadOfArguments() {
        XCTAssertEqual(
            AgentBridge.toolStatus(
                name: "Bash",
                input: ["command": "rm -rf /a/path-that-must-never-appear-in-status"]),
            "Running command…")
        XCTAssertEqual(
            AgentBridge.toolStatus(name: "Read", input: ["file_path": "/secret/Feature.swift"]),
            "Reading file…")
        XCTAssertEqual(
            AgentBridge.toolStatus(name: "Edit", input: ["file_path": "/secret/Feature.swift"]),
            "Writing file…")
        XCTAssertEqual(
            AgentBridge.toolStatus(name: "mcp__example__privateTool", input: ["value": "secret"]),
            "Using extension…")
    }

    func testCommandOutputLanguageInferenceRestoresSourceHighlighting() {
        let language = inferredCommandOutputLanguage("sed -n '1,80p' Sources/Feature.swift")
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(inferredCommandOutputLanguage("cat config.json"), "json")
        XCTAssertEqual(inferredCommandOutputLanguage("npm test"), nil)
        let highlighted = SyntaxHighlighter.highlight(
            "let answer = 42 // restored in Activity detail",
            language: language,
            fontSize: 11)
        XCTAssertGreaterThan(
            highlighted.runs.count,
            2,
            "Inferred source output must reach the token highlighter, not a flat text renderer.")
    }

    private func activity(
        _ id: String,
        _ name: String,
        _ state: AppKitActivityAction.State
    ) -> AppKitActivityAction {
        AppKitActivityAction(
            id: AnyHashable(id), sourceIndex: 0, toolName: name,
            rawInput: "{}", state: state)
    }

    private func tool(_ name: String) -> TranscriptEntry {
        var entry = TranscriptEntry(kind: .tool)
        entry.toolName = name
        return entry
    }
}
