import XCTest
@testable import Mechanician

final class PermissionPresentationTests: XCTestCase {
    func testProviderLabelsDescribeActualPermissionSemantics() {
        XCTAssertEqual(
            PermissionPresentation.option(
                mode: "default", access: .codexSubscription).title,
            "Workspace access")
        XCTAssertEqual(
            PermissionPresentation.option(
                mode: "default", access: .openAIAPI).title,
            "Ask for changes")
        XCTAssertEqual(
            PermissionPresentation.option(
                mode: "default", access: .claudeSubscription).title,
            "Default")
        XCTAssertFalse(PermissionPresentation.options(for: .codexSubscription)
            .contains { $0.title == "Ask each time" })
    }

    func testPersistedPermissionModeNormalizesOnlyUnknownValues() {
        for mode in ["default", "plan", "acceptEdits", "bypassPermissions"] {
            XCTAssertEqual(PermissionPresentation.normalized(mode), mode)
        }
        XCTAssertEqual(PermissionPresentation.normalized(nil), "default")
        XCTAssertEqual(PermissionPresentation.normalized("obsolete"), "default")
    }

    func testFileApprovalHidesTransportMetadataAndExplainsTheAction() {
        let request = PermissionPresentation.request(
            tool: "Edit",
            payload: #"{"grantRoot":null,"itemId":"exec-secret","reason":""}"#)

        XCTAssertEqual(request.title, "Allow file changes?")
        XCTAssertEqual(request.summary, "The agent wants to modify files in this workspace.")
        XCTAssertTrue(request.details.isEmpty)
        XCTAssertFalse(request.summary.contains("itemId"))
    }

    func testCommandApprovalFormatsOnlyMeaningfulDetails() {
        let request = PermissionPresentation.request(
            tool: "Bash",
            payload: #"{"command":"swift test","cwd":"/tmp/project","reason":"Run the focused tests"}"#)

        XCTAssertEqual(request.title, "Allow this command?")
        XCTAssertEqual(request.details, [
            PermissionRequestDetail(label: "Command", value: "swift test", monospaced: true),
            PermissionRequestDetail(label: "Location", value: "/tmp/project", monospaced: true),
            PermissionRequestDetail(label: "Why", value: "Run the focused tests"),
        ])
    }

    func testDecidedCardStatesTheOutcomeInsteadOfAskingAgain() {
        let payload = #"{"command":"swift test","cwd":"/tmp/project"}"#

        let denied = PermissionPresentation.request(
            tool: "Bash", payload: payload, decision: .denied)
        XCTAssertEqual(denied.title, "Asked to run a command")
        XCTAssertEqual(
            denied.summary, "The agent was not allowed to run a command in this workspace.")

        let allowed = PermissionPresentation.request(
            tool: "Bash", payload: payload, decision: .allowed)
        XCTAssertEqual(allowed.title, "Asked to run a command")
        XCTAssertEqual(
            allowed.summary, "The agent was allowed to run a command in this workspace.")

        // The command is the one thing worth reading after the fact, so a decided card keeps it.
        XCTAssertEqual(denied.details.first?.value, "swift test")
    }

    func testDecidedCopyNeverAsksAndNeverCreditsThePerson() {
        // A decision can land with no prompt at all, so the card may not say the person made it.
        for tool in ["Bash", "Edit", "WebFetch", "mcp__automation__RunAppleScript"] {
            for decision in [PermissionPresentation.Decision.allowed, .denied] {
                let request = PermissionPresentation.request(
                    tool: tool, payload: "{}", decision: decision)
                XCTAssertFalse(request.title.hasSuffix("?"), tool)
                XCTAssertTrue(request.summary.hasPrefix("The agent was "), tool)
                XCTAssertFalse(request.summary.lowercased().contains("you"), tool)
            }
        }
    }

    func testAnUndecidedCardStillAsksTheQuestion() {
        // The control for the two tests above: same tools, no decision, unchanged wording.
        for tool in ["Bash", "Edit", "WebFetch", "mcp__automation__RunAppleScript"] {
            let request = PermissionPresentation.request(tool: tool, payload: "{}")
            XCTAssertTrue(request.title.hasSuffix("?"), tool)
            XCTAssertEqual(
                request.title,
                PermissionPresentation.request(
                    tool: tool, payload: "{}", decision: .pending).title,
                tool)
        }
    }

    // MARK: - Writes the workspace boundary stopped

    /// The report that produced this: Bypass permissions set, and a card asking to write
    /// `~/Desktop/notes.md` — while saying the agent "wants to modify files in this workspace".
    /// It asked BECAUSE the file is not in the workspace, and the copy claimed the opposite, so a
    /// deliberate boundary read as the permission setting being ignored.
    func testAWriteOutsideTheWorkspaceSaysThatIsWhyItAsked() {
        let request = PermissionPresentation.request(
            tool: "Write",
            payload: #"{"file_path":"/Users/dl/Desktop/notes.md"}"#,
            writeEscape: PermissionWriteEscape(
                target: "/Users/dl/Desktop/notes.md", workspace: "/Users/dl/dev/project"))

        XCTAssertEqual(request.title, "Allow a write outside the workspace?")
        XCTAssertTrue(request.summary.contains("outside the workspace"), request.summary)
        // The claim that made bypass look broken must not survive.
        XCTAssertFalse(request.summary.contains("in this workspace."), request.summary)
        // Naming the mode is the point: it says the setting is working, not being ignored.
        XCTAssertTrue(request.summary.contains("Bypass permissions"), request.summary)
        XCTAssertEqual(
            request.details.first { $0.label == "Workspace" }?.value,
            "/Users/dl/dev/project")
    }

    /// Grants are remembered per containing folder, not per file, so "Always allow" covers more
    /// than the card names unless the card says so.
    func testTheCardSaysWhatAlwaysAllowWillCover() {
        let request = PermissionPresentation.request(
            tool: "Write",
            payload: #"{"file_path":"/Users/dl/Desktop/notes.md"}"#,
            writeEscape: PermissionWriteEscape(
                target: "/Users/dl/Desktop/notes.md", workspace: "/Users/dl/dev/project"))

        XCTAssertEqual(
            request.details.first { $0.label == "Always allow" }?.value,
            "Covers everything in /Users/dl/Desktop")
    }

    /// Containment judges the path with symlinks resolved. A path that reads as inside the
    /// workspace can resolve outside it, and then the resolved path is the whole explanation.
    func testAPathThatResolvesElsewhereShowsWhereItLands() {
        let request = PermissionPresentation.request(
            tool: "Edit",
            payload: #"{"file_path":"/Users/dl/dev/project/link/notes.md"}"#,
            writeEscape: PermissionWriteEscape(
                target: "/Volumes/external/notes.md", workspace: "/Users/dl/dev/project"))

        XCTAssertEqual(
            request.details.first { $0.label == "Resolves to" }?.value,
            "/Volumes/external/notes.md")
    }

    func testADecidedContainmentCardIsPastTenseAndStopsOfferingTheGrant() {
        let escape = PermissionWriteEscape(
            target: "/Users/dl/Desktop/notes.md", workspace: "/Users/dl/dev/project")
        let allowed = PermissionPresentation.request(
            tool: "Write",
            payload: #"{"file_path":"/Users/dl/Desktop/notes.md"}"#,
            writeEscape: escape,
            decision: .allowed)

        XCTAssertEqual(allowed.title, "Asked to write outside the workspace")
        XCTAssertEqual(allowed.summary, "The agent was allowed to write outside the workspace.")
        XCTAssertNil(allowed.details.first { $0.label == "Always allow" })
    }

    /// An ordinary in-workspace edit is untouched by any of this.
    func testAnOrdinaryEditCardIsUnchanged() {
        let request = PermissionPresentation.request(
            tool: "Edit",
            payload: #"{"file_path":"/Users/dl/dev/project/main.swift"}"#)

        XCTAssertEqual(request.title, "Allow file changes?")
        XCTAssertEqual(request.summary, "The agent wants to modify files in this workspace.")
        XCTAssertNil(request.details.first { $0.label == "Workspace" })
    }

    /// The picker promised "without approval prompts" while containment still asked. Whatever the
    /// copy says, it has to admit the exception.
    func testTheBypassOptionAdmitsTheOneThingThatStillAsks() {
        let detail = PermissionPresentation.option(
            mode: "bypassPermissions", access: .claudeSubscription).detail

        XCTAssertTrue(detail.contains("outside this workspace"), detail)
    }

    // MARK: - Plumbing

    func testTheDaemonsContainmentVerdictReachesTheCard() {
        var entry = TranscriptEntry(kind: .permission)
        AgentBridge.applyWriteEscape(
            [
                "type": "permission_request",
                "name": "Write",
                "writeEscape": [
                    "target": "/Users/dl/Desktop/notes.md",
                    "workspace": "/Users/dl/dev/project",
                ],
            ],
            to: &entry)

        XCTAssertEqual(entry.permWriteEscapeTarget, "/Users/dl/Desktop/notes.md")
        XCTAssertEqual(entry.permWriteEscapeWorkspace, "/Users/dl/dev/project")
    }

    func testAnOrdinaryRequestCarriesNoContainmentVerdict() {
        var entry = TranscriptEntry(kind: .permission)
        AgentBridge.applyWriteEscape(["type": "permission_request", "name": "Bash"], to: &entry)
        XCTAssertNil(entry.permWriteEscapeTarget)

        // A malformed verdict must not produce a card that explains itself with an empty path.
        AgentBridge.applyWriteEscape(["writeEscape": ["target": ""]], to: &entry)
        XCTAssertNil(entry.permWriteEscapeTarget)
    }

    /// A permission request reaches the transcript on two paths — the foreground handler and the
    /// background-conversation one. A card that arrives on the unwired path explains nothing, which
    /// is the bug this fixes, and nothing else in the suite would notice.
    func testBothPermissionRequestPathsCarryTheVerdict() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Mechanician/AgentBridge.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        let handlers = text.components(separatedBy: "case \"permission_request\":")
        XCTAssertEqual(handlers.count - 1, 2, "a new permission_request path needs the verdict too")
        for (index, handler) in handlers.dropFirst().enumerated() {
            let called = handler.prefix(1400).split(separator: "\n").contains { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("Self.applyWriteEscape(")
            }
            XCTAssertTrue(called, "permission_request path \(index) builds a card that cannot say why it asked")
        }
    }
}
