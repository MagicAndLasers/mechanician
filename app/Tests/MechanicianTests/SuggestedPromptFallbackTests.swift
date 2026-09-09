import XCTest
@testable import Mechanician

final class SuggestedPromptFallbackTests: XCTestCase {
    func testSnapshotUsesFinalDialogueAndExcludesSystemAndToolRows() throws {
        let oldUser = TranscriptEntry(kind: .user, text: "An older request")
        let user = TranscriptEntry(kind: .user, text: "Implement the suggested prompt fallback")
        let system = TranscriptEntry(kind: .system, text: "SYSTEM ENVELOPE SENTINEL")
        let tool = TranscriptEntry(kind: .tool, text: "TOOL PAYLOAD SENTINEL")
        let assistant = TranscriptEntry(kind: .assistant, text: "The focused implementation is ready.")

        let snapshot = try XCTUnwrap(SuggestedPromptFallback.snapshot(
            from: [oldUser, user, system, tool, assistant],
            turnID: "turn-1",
            rootPromptEntryID: user.id))

        XCTAssertTrue(snapshot.context.contains("User:\nImplement the suggested prompt fallback"))
        XCTAssertTrue(snapshot.context.contains(
            "Assistant (final message):\n"
                + "The focused implementation is ready."))
        XCTAssertFalse(snapshot.context.contains("SYSTEM ENVELOPE SENTINEL"))
        XCTAssertFalse(snapshot.context.contains("TOOL PAYLOAD SENTINEL"))
        XCTAssertEqual(snapshot.latestUserPrompt, user.text)
        XCTAssertEqual(snapshot.currentTurnUserPrompts, [user.text])
        XCTAssertEqual(snapshot.userPromptsToAvoid, [oldUser.text, user.text])
        XCTAssertFalse(snapshot.context.contains(oldUser.text))
        XCTAssertFalse(snapshot.resumedFromWaitMode)
        XCTAssertTrue(snapshot.sourceEntryIDs.contains(user.id))
        XCTAssertTrue(snapshot.sourceEntryIDs.contains(assistant.id))
        XCTAssertEqual(snapshot.assistantEntryID, assistant.id)
    }


    func testSnapshotIsBoundedAndRequiresACompletedAssistantExchange() throws {
        let long = String(repeating: "context ", count: 2_000)
        let user = TranscriptEntry(kind: .user, text: long)
        XCTAssertNil(SuggestedPromptFallback.snapshot(
            from: [user], turnID: "turn", rootPromptEntryID: user.id))

        let assistant = TranscriptEntry(kind: .assistant, text: long)
        let snapshot = try XCTUnwrap(SuggestedPromptFallback.snapshot(
            from: [user, assistant],
            turnID: "turn",
            rootPromptEntryID: user.id))
        XCTAssertLessThanOrEqual(
            snapshot.context.count,
            SuggestedPromptFallback.maximumContextCharacters)

        let newerUser = TranscriptEntry(kind: .user, text: "One more request")
        XCTAssertNil(SuggestedPromptFallback.snapshot(
            from: [user, assistant, newerUser],
            turnID: "turn",
            rootPromptEntryID: user.id))
    }

    func testExampleTurnCannotMineQuotedPromptsForANewAction() throws {
        let user = TranscriptEntry(
            kind: .user,
            text: "I’d like to see an example of the improved suggested prompts")
        let assistant = TranscriptEntry(kind: .assistant, text: """
        Here’s the exact example observed in the Dev app:

        - User prompt: “Can you suggest a debounce for duplicate follow-ups?”
        - Assistant response: Explained the debounce pattern.
        - Suggested prompt: “How can I extend this debounce with a timeout?”

        It advances the discussion instead of repeating the original request.
        """)

        let snapshot = try XCTUnwrap(SuggestedPromptFallback.snapshot(
            from: [user, assistant],
            turnID: "turn-1",
            rootPromptEntryID: user.id))

        XCTAssertEqual(snapshot.sourceEntryIDs, [user.id, assistant.id])
        XCTAssertNil(SuggestedPromptFallback.compiledHandoff(from: snapshot))
        XCTAssertNil(SuggestedPromptFallback.selectCandidate(
            ["Can you explain how to integrate the debounce pattern with a timeout "
                + "for follow-ups in the sample repo?"],
            avoiding: snapshot.latestUserPrompt,
            userPromptsToAvoid: snapshot.userPromptsToAvoid,
            grounding: snapshot.candidateGrounding).suggestion)
    }

    func testSnapshotRetainsTheFullUserHistoryForLocalEchoRejectionOnly() throws {
        let olderUsers = (1...4).map {
            TranscriptEntry(kind: .user, text: "Historical command \($0)")
        }
        var entries: [TranscriptEntry] = []
        for user in olderUsers {
            entries.append(user)
            entries.append(TranscriptEntry(kind: .assistant, text: "Completed \(user.text)."))
        }
        let current = TranscriptEntry(kind: .user, text: "Improve the current suggestion.")
        let assistant = TranscriptEntry(
            kind: .assistant,
            text: "The current exchange now has a distinct continuation.")
        entries.append(contentsOf: [current, assistant])

        let snapshot = try XCTUnwrap(SuggestedPromptFallback.snapshot(
            from: entries,
            turnID: "turn",
            rootPromptEntryID: current.id))

        XCTAssertEqual(snapshot.userPromptsToAvoid, olderUsers.map(\.text) + [current.text])
        for older in olderUsers {
            XCTAssertFalse(snapshot.context.contains(older.text))
            XCTAssertFalse(snapshot.sourceEntryIDs.contains(older.id))
        }
    }

    func testSyntheticWaitModeResumeUsesLatestGenuineUserGoalWithoutDisclosingSyntheticRow() throws {
        let user = TranscriptEntry(
            kind: .user,
            text: "Continue implementing Beacon after the dogfood build is installed.")
        let earlierAssistant = TranscriptEntry(
            kind: .assistant,
            text: "The build is ready for installation.")
        let resume = TranscriptEntry(
            kind: .user,
            text: "[wait-mode] The build stamp changed. Continue where you left off.")
        let progress = (1...6).map {
            TranscriptEntry(kind: .assistant, text: "Progress update \($0)")
        }
        let steering = TranscriptEntry(
            kind: .user,
            text: "Stop the inspector check and diagnose the transcript regression first.")
        let assistant = TranscriptEntry(
            kind: .assistant,
            text: "The installed build passed the live restatement check.")

        let snapshot = try XCTUnwrap(SuggestedPromptFallback.snapshot(
            from: [user, earlierAssistant, resume] + progress + [steering, assistant],
            turnID: "turn",
            rootPromptEntryID: resume.id))

        XCTAssertEqual(snapshot.latestUserPrompt, steering.text)
        XCTAssertEqual(snapshot.currentTurnUserPrompts, [user.text, steering.text])
        XCTAssertEqual(snapshot.userPromptsToAvoid, [user.text, steering.text])
        XCTAssertTrue(snapshot.resumedFromWaitMode)
        XCTAssertTrue(snapshot.context.contains(user.text))
        XCTAssertTrue(snapshot.context.contains(steering.text))
        XCTAssertTrue(snapshot.context.contains(assistant.text))
        XCTAssertFalse(snapshot.context.contains("[wait-mode]"))
        XCTAssertFalse(snapshot.context.contains("Progress update"))
        XCTAssertTrue(snapshot.sourceEntryIDs.contains(user.id))
        XCTAssertTrue(snapshot.sourceEntryIDs.contains(steering.id))
        XCTAssertFalse(snapshot.sourceEntryIDs.contains(resume.id))
    }

    func testSyntheticResumeUsesOnlyTheFinalAssistantMessage() throws {
        let goal = TranscriptEntry(
            kind: .user,
            text: "Make suggested prompts persist across relaunches and conversation changes.")
        let ready = TranscriptEntry(
            kind: .assistant,
            text: "The dogfood candidate is ready for installation.")
        let resume = TranscriptEntry(
            kind: .user,
            text: "[wait-mode] The installed provenance now matches.")
        let handoff = TranscriptEntry(
            kind: .assistant,
            text: "The exact candidate is installed. After this response, verify that its "
                + "suggestion survives navigation and a same-build relaunch.")
        let finalStatus = TranscriptEntry(
            kind: .assistant,
            text: "Installed build verified. Waiting briefly for local generation to finish.")

        let snapshot = try XCTUnwrap(SuggestedPromptFallback.snapshot(
            from: [goal, ready, resume, handoff, finalStatus],
            turnID: "wait-turn",
            rootPromptEntryID: resume.id))
        XCTAssertFalse(snapshot.context.contains(handoff.text))
        XCTAssertTrue(snapshot.context.contains(finalStatus.text))
        XCTAssertEqual(snapshot.assistantHandoff, finalStatus.text)
        XCTAssertFalse(snapshot.sourceEntryIDs.contains(handoff.id))
        XCTAssertTrue(snapshot.sourceEntryIDs.contains(finalStatus.id))
        XCTAssertEqual(snapshot.assistantEntryID, finalStatus.id)
        XCTAssertFalse(snapshot.sourceEntryIDs.contains(ready.id))
        XCTAssertFalse(snapshot.sourceEntryIDs.contains(resume.id))
        XCTAssertNil(SuggestedPromptFallback.compiledHandoff(from: snapshot))
    }

    func testEarlierAssistantProgressCannotBecomeTheActionHandoff() throws {
        let goal = TranscriptEntry(
            kind: .user,
            text: "Diagnose the irrelevant memory retrieval and propose the concrete fix.")
        let progress = (1...5).map { index in
            TranscriptEntry(
                kind: .assistant,
                text: "EARLY-PROGRESS-\(index) " + String(repeating: "detail ", count: 40))
        }
        let namedAction = TranscriptEntry(
            kind: .assistant,
            text: "The cause is global admission. Next, implement exact workspace fencing before ranking.")
        let finalStatus = TranscriptEntry(
            kind: .assistant,
            text: "The diagnosis is recorded; no memory data was altered.")

        let snapshot = try XCTUnwrap(SuggestedPromptFallback.snapshot(
            from: [goal] + progress + [namedAction, finalStatus],
            turnID: "turn",
            rootPromptEntryID: goal.id))

        XCTAssertFalse(snapshot.context.contains(namedAction.text))
        XCTAssertTrue(snapshot.context.contains(finalStatus.text))
        XCTAssertFalse(snapshot.context.contains("EARLY-PROGRESS-5"))
        XCTAssertFalse(snapshot.context.contains("EARLY-PROGRESS-1"))
        XCTAssertFalse(snapshot.sourceEntryIDs.contains(namedAction.id))
        XCTAssertTrue(snapshot.sourceEntryIDs.contains(finalStatus.id))
        XCTAssertFalse(snapshot.sourceEntryIDs.contains(progress.last!.id))
        XCTAssertFalse(snapshot.sourceEntryIDs.contains(progress.first!.id))
        XCTAssertEqual(snapshot.assistantEntryID, finalStatus.id)
        XCTAssertNil(SuggestedPromptFallback.compiledHandoff(from: snapshot))
    }

    func testSnapshotKeepsEarlierGoalsOutOfModelContextButRetainsThemForEchoRejection() throws {
        let older = TranscriptEntry(
            kind: .user,
            text: "Implement agent-accrued knowledge capture after prompt persistence works.")
        let olderReply = TranscriptEntry(
            kind: .assistant,
            text: "I will return to knowledge capture after the persistence build.")
        let current = TranscriptEntry(
            kind: .user,
            text: "Make suggested prompts persist across relaunches.")
        let currentReply = TranscriptEntry(
            kind: .assistant,
            text: "The dogfood candidate is ready.")
        let resume = TranscriptEntry(
            kind: .user,
            text: "[wait-mode] The installed provenance now matches.")
        let final = TranscriptEntry(
            kind: .assistant,
            text: "Next, implement agent-accrued knowledge capture.")

        let snapshot = try XCTUnwrap(SuggestedPromptFallback.snapshot(
            from: [older, olderReply, current, currentReply, resume, final],
            turnID: "wait-turn",
            rootPromptEntryID: resume.id))

        XCTAssertFalse(snapshot.context.contains("Recent earlier User goals:"))
        XCTAssertFalse(snapshot.context.contains(older.text))
        XCTAssertTrue(snapshot.context.contains(current.text))
        XCTAssertTrue(snapshot.context.contains(final.text))
        XCTAssertEqual(snapshot.userPromptsToAvoid, [older.text, current.text])
        XCTAssertFalse(snapshot.sourceEntryIDs.contains(older.id))
        XCTAssertTrue(snapshot.sourceEntryIDs.contains(current.id))
        XCTAssertFalse(snapshot.sourceEntryIDs.contains(resume.id))
    }

    func testLongTurnProgressCannotCrowdOutRootSteeringOrFinalOutcome() throws {
        let root = TranscriptEntry(
            kind: .user,
            text: "Verify that the inspector preserves its selected tab.")
        let earlyProgress = (1...5).map {
            TranscriptEntry(kind: .assistant, text: "Inspector progress \($0)")
        }
        let steering = TranscriptEntry(
            kind: .user,
            text: "The transcript is out of control; diagnose that regression instead.")
        let lateProgress = (1...5).map {
            TranscriptEntry(kind: .assistant, text: "Transcript progress \($0)")
        }
        let final = TranscriptEntry(
            kind: .assistant,
            text: "The recording proves that offscreen row realization caused the layout storm.")

        let snapshot = try XCTUnwrap(SuggestedPromptFallback.snapshot(
            from: [root] + earlyProgress + [steering] + lateProgress + [final],
            turnID: "turn",
            rootPromptEntryID: root.id))

        XCTAssertEqual(snapshot.latestUserPrompt, steering.text)
        XCTAssertTrue(snapshot.context.contains(root.text))
        XCTAssertTrue(snapshot.context.contains(steering.text))
        XCTAssertTrue(snapshot.context.contains(final.text))
        XCTAssertFalse(snapshot.context.contains("Inspector progress"))
        XCTAssertFalse(snapshot.context.contains("Transcript progress"))
        XCTAssertEqual(
            snapshot.sourceEntryIDs,
            [root.id, steering.id, final.id])
    }

    func testRoleBudgetsKeepEveryEssentialPartOfALongTurn() throws {
        let root = TranscriptEntry(
            kind: .user,
            text: "ROOT-BEGIN " + String(repeating: "r", count: 2_000) + " ROOT-END")
        let steering = TranscriptEntry(
            kind: .user,
            text: "STEERING-BEGIN " + String(repeating: "s", count: 2_000) + " STEERING-END")
        let final = TranscriptEntry(
            kind: .assistant,
            text: "OUTCOME-BEGIN " + String(repeating: "o", count: 2_000) + " OUTCOME-END")

        let snapshot = try XCTUnwrap(SuggestedPromptFallback.snapshot(
            from: [root, steering, final],
            turnID: "turn",
            rootPromptEntryID: root.id))

        for marker in [
            "ROOT-BEGIN", "ROOT-END",
            "STEERING-BEGIN", "STEERING-END",
            "OUTCOME-BEGIN", "OUTCOME-END",
        ] {
            XCTAssertTrue(snapshot.context.contains(marker), "Missing \(marker)")
        }
        XCTAssertLessThanOrEqual(
            snapshot.context.count,
            SuggestedPromptFallback.maximumContextCharacters)
    }

    func testSyntheticWaitModeResumeWithoutAGenuineUserGoalDoesNotGenerate() {
        let resume = TranscriptEntry(
            kind: .user,
            text: "[wait-mode] The build stamp changed. Continue where you left off.")
        let assistant = TranscriptEntry(kind: .assistant, text: "The build finished.")

        XCTAssertNil(SuggestedPromptFallback.snapshot(
            from: [resume, assistant],
            turnID: "turn",
            rootPromptEntryID: resume.id))
    }

    func testUserAuthoredDiscussionOfWaitModeStillGenerates() {
        let user = TranscriptEntry(
            kind: .user,
            text: "Improve the [wait-mode] suggestion behavior.")
        let assistant = TranscriptEntry(
            kind: .assistant,
            text: "I found the narrow policy seam.")

        XCTAssertNotNil(SuggestedPromptFallback.snapshot(
            from: [user, assistant],
            turnID: "turn",
            rootPromptEntryID: user.id))
    }

    func testCompilerTurnsGroundedNamedActionsIntoDirectCommands() throws {
        XCTAssertEqual(try compiled(
            user: "Improve agent-accrued knowledge capture.",
            assistant: "Next, audit session provenance boundaries for agent-accrued knowledge capture receipts."),
            "Audit session provenance boundaries for agent-accrued knowledge capture receipts.")
        XCTAssertEqual(try compiled(
            user: "Let's get Beacon wired into retrieval.",
            assistant: "The next action is to wire Beacon into live recall."),
            "Wire Beacon into live recall.")
        XCTAssertEqual(try compiled(
            user: "Complete the Beacon confirmation workflow.",
            assistant: """
            The next Beacon sequence is:

            1. Project proposal receipts into Beacon confirmation records.
            2. Create an accepted proposal.
            """),
            "Project proposal receipts into Beacon confirmation records.")
        XCTAssertEqual(try compiled(
            user: "Investigate and harden suggested-prompt publication.",
            assistant: "Next, audit the suggested-prompt queue-reservation publication race."),
            "Audit the suggested-prompt queue-reservation publication race.")
    }

    func testCompilerRejectsAHandoffThatRestatesTheUserPrompt() throws {
        XCTAssertNil(try compiled(
            user: "Implement agent-accrued knowledge capture next.",
            assistant: "The prompt work is complete. Next, implement agent-accrued knowledge capture."))
        XCTAssertNil(try compiled(
            user: "Why are suggested prompts missing?",
            assistant: "Next, investigate why suggested prompts are missing."))
    }

    func testCompilerKeepsAHighOverlapActionWithAssistantIntroducedDetail() throws {
        XCTAssertEqual(try compiled(
            user: "Implement the durable workspace mailbox in safe phases.",
            assistant: "Next, implement the durable workspace mailbox foundation."),
            "Implement the durable workspace mailbox foundation.")
        XCTAssertEqual(try compiled(
            user: "Improve source-backed discovery capture.",
            assistant: "I recommend adding provenance to source-backed discovery capture."),
            "Add provenance to source-backed discovery capture.")
    }

    func testAssistantNoveltyMustBeNewToTheWholeUserHistory() {
        let currentUser = "Implement the durable workspace mailbox in safe phases."
        let candidate = "Implement the durable workspace mailbox foundation."
        XCTAssertNil(SuggestedPromptFallback.sanitized(
            candidate,
            avoiding: currentUser,
            userPromptsToAvoid: [currentUser],
            grounding: SuggestedPromptCandidateGrounding(
                currentTurnUserPrompts: [currentUser],
                assistantHandoff: "The mailbox work can continue in another safe phase.")))

        XCTAssertNil(SuggestedPromptFallback.sanitized(
            candidate,
            avoiding: currentUser,
            userPromptsToAvoid: [
                "Document the durable workspace mailbox foundation.",
                currentUser,
            ],
            grounding: SuggestedPromptCandidateGrounding(
                currentTurnUserPrompts: [currentUser],
                assistantHandoff:
                    "Next, implement the durable workspace mailbox foundation.")))
    }

    func testAssistantPrescribedActionCategoryCanAdvanceTheSameTarget() {
        let user = "Implement prompt persistence."
        let grounding = SuggestedPromptCandidateGrounding(
            currentTurnUserPrompts: [user],
            assistantHandoff: "Next, test prompt persistence.")
        XCTAssertEqual(SuggestedPromptFallback.sanitized(
            "Test prompt persistence.",
            avoiding: user,
            userPromptsToAvoid: [user],
            grounding: grounding),
            "Test prompt persistence.")

        XCTAssertNil(SuggestedPromptFallback.sanitized(
            "Design prompt persistence.",
            avoiding: user,
            userPromptsToAvoid: [user],
            grounding: SuggestedPromptCandidateGrounding(
                currentTurnUserPrompts: [user],
                assistantHandoff: "Next, design prompt persistence.")))
        XCTAssertNil(SuggestedPromptFallback.sanitized(
            "Investigate why suggested prompts are missing.",
            avoiding: "Why are suggested prompts missing?",
            userPromptsToAvoid: ["Why are suggested prompts missing?"],
            grounding: SuggestedPromptCandidateGrounding(
                currentTurnUserPrompts: ["Why are suggested prompts missing?"],
                assistantHandoff: "Next, investigate why suggested prompts are missing.")))
        XCTAssertNil(SuggestedPromptFallback.sanitized(
            "Test prompt persistence.",
            avoiding: "Implement and test prompt persistence.",
            userPromptsToAvoid: ["Implement and test prompt persistence."],
            grounding: SuggestedPromptCandidateGrounding(
                currentTurnUserPrompts: ["Implement and test prompt persistence."],
                assistantHandoff: "Next, test prompt persistence.")))
    }

    func testCompilerAnswersConcreteOffersAndRecommendationsWithoutAnotherQuestion() throws {
        let user = "Improve source-backed discovery capture before broader learning."
        XCTAssertEqual(try compiled(
            user: user,
            assistant: "Should I add receipt provenance to source-backed discovery capture first?"),
            "Add receipt provenance to source-backed discovery capture first.")
        XCTAssertEqual(try compiled(
            user: user,
            assistant: "I recommend adding receipt provenance to source-backed discovery capture first."),
            "Add receipt provenance to source-backed discovery capture first.")
        XCTAssertEqual(try compiled(
            user: "Prevent duplicate suggestion-chip follow-ups.",
            assistant:
                "A better pattern for this case is to disable the suggestion chip during the request."),
            "Disable the suggestion chip during the request.")
        XCTAssertEqual(try compiled(
            user: "Finish the suggestion-chip timeout path.",
            assistant: "If you’d like, I can add the final suggestion-chip timeout test."),
            "Add the final suggestion-chip timeout test.")
    }

    func testCompilerSupportsCommonRecommendationOfferAndMarkdownPhrasing() throws {
        let user = "Improve duplicate suggestion timeout handling."
        let expected = "Add timeout cancellation to duplicate suggestion follow-ups."
        for assistant in [
            "I recommend you add timeout cancellation to duplicate suggestion follow-ups.",
            "I’d recommend adding timeout cancellation to duplicate suggestion follow-ups.",
            "Recommendation: Add timeout cancellation to duplicate suggestion follow-ups.",
            "The next step would be to add timeout cancellation to duplicate suggestion follow-ups.",
            "My proposed next step is to add timeout cancellation to duplicate suggestion follow-ups.",
            "My next step is to add timeout cancellation to duplicate suggestion follow-ups.",
            "Our next action will be to add timeout cancellation to duplicate suggestion follow-ups.",
            "If you want, I can add timeout cancellation to duplicate suggestion follow-ups.",
            "**Next:** Add timeout cancellation to duplicate suggestion follow-ups.",
        ] {
            XCTAssertEqual(try compiled(user: user, assistant: assistant), expected, assistant)
        }

        XCTAssertEqual(try compiled(
            user: user,
            assistant: """
            ## Next steps
            - Add timeout cancellation to duplicate suggestion follow-ups.
            - Rebuild the dev app.
            """), expected)
    }

    func testCompilerSkipsTrailingRationaleButHonorsNewerTerminalUpdates() throws {
        XCTAssertEqual(try compiled(
            user: "Prevent duplicate suggestion-chip follow-ups.",
            assistant: "I recommend disabling the suggestion chip during the request. "
                + "The suggestion chip stays visible throughout the request."),
            "Disable the suggestion chip during the request.")

        let user = "Improve timeout cancellation for suggestion follow-ups."
        let candidate = "Add timeout cancellation to suggestion follow-ups."
        for assistant in [
            "Next, add timeout cancellation to suggestion follow-ups. "
                + "Adding timeout cancellation to suggestion follow-ups is now complete.",
            "Next, add timeout cancellation to suggestion follow-ups. "
                + "Done — timeout cancellation is in place now.",
            "Next, add timeout cancellation to suggestion follow-ups. "
                + "Timeout cancellation now added.",
            "Next, add timeout cancellation to suggestion follow-ups. Done.",
            "Next, add timeout cancellation to suggestion follow-ups. Complete.",
            "Next, add timeout cancellation to suggestion follow-ups. Fixed.",
            "Next, add timeout cancellation to suggestion follow-ups. Implemented.",
            "Next, add timeout cancellation to suggestion follow-ups. Passed.",
            "Next, add timeout cancellation to suggestion follow-ups. Verified.",
            "Next, add timeout cancellation to suggestion follow-ups. That's done.",
            "Next, add timeout cancellation to suggestion follow-ups. It's done.",
            "Next, add timeout cancellation to suggestion follow-ups. That's already done.",
            "Next, add timeout cancellation to suggestion follow-ups. It has already passed.",
            "Next, add timeout cancellation to suggestion follow-ups. That's already finished.",
            "Next, add timeout cancellation to suggestion follow-ups. Already done.",
            "Next, add timeout cancellation to suggestion follow-ups. "
                + "That is now implemented.",
            "Next, add timeout cancellation to suggestion follow-ups. "
                + "This has been fixed.",
            "Next, add timeout cancellation to suggestion follow-ups. "
                + "I no longer recommend adding timeout cancellation to suggestion follow-ups.",
            "Next, add timeout cancellation to suggestion follow-ups. Don't do that.",
            "Next, add timeout cancellation to suggestion follow-ups. Actually, don't do that.",
            "Next, add timeout cancellation to suggestion follow-ups. Actually, don't.",
            "Next, add timeout cancellation to suggestion follow-ups. Never mind.",
            "Next, add timeout cancellation to suggestion follow-ups. Scratch that.",
            "Next, add timeout cancellation to suggestion follow-ups. Skip that.",
        ] {
            XCTAssertNil(try compiled(user: user, assistant: assistant), assistant)
        }

        let replacement = "Switch suggestion follow-ups to request-scoped cancellation."
        let different = "Next, add timeout cancellation to suggestion follow-ups. "
            + "Instead, I recommend switching suggestion follow-ups to request-scoped cancellation."
        XCTAssertEqual(try compiled(user: user, assistant: different), replacement)
        XCTAssertNil(SuggestedPromptFallback.sanitized(
            candidate,
            avoiding: user,
            userPromptsToAvoid: [user],
            grounding: SuggestedPromptCandidateGrounding(
                currentTurnUserPrompts: [user],
                assistantHandoff: different)))
    }

    func testOnlyExplicitForwardPrescriptionsAuthorizeAHandoff() throws {
        let user = "Improve timeout cancellation for suggestion follow-ups."
        for assistant in [
            "Add timeout cancellation to suggestion follow-ups.",
            "You should add timeout cancellation to suggestion follow-ups.",
            "I can add timeout cancellation to suggestion follow-ups.",
        ] {
            XCTAssertNil(try compiled(user: user, assistant: assistant), assistant)
            XCTAssertNil(SuggestedPromptFallback.sanitized(
                "Add timeout cancellation to suggestion follow-ups.",
                avoiding: user,
                userPromptsToAvoid: [user],
                grounding: SuggestedPromptCandidateGrounding(
                    currentTurnUserPrompts: [user],
                    assistantHandoff: assistant)), assistant)
        }
    }

    func testGenericWhatNextSteeringGroundsAnExplicitAssistantHandoff() throws {
        XCTAssertEqual(try compiled(
            user: "What should I do next?",
            assistant: "Next, add timeout cancellation to the suggestion chip."),
            "Add timeout cancellation to the suggestion chip.")
    }

    func testDeicticNextSliceRecommendationCompilesTheHelpInspectorExchange() throws {
        let user = "should we have a dedicated help workspace with a help inspector tab like how "
            + "the memory workspace has the memory tab? thoughts?"
        let assistant = """
        Yes. The dedicated Help workspace already exists; the missing half is its own inspector. \
        Currently it gets generic Artifacts, Agents, and Skills tabs even though `help-expert` is \
        Search-only, which feels incoherent.

        I’d shape it like this:

        - Help conversation on the left.
        - Help tab on the right, selected by default with a roughly 560-point width.
        - Search, topics, claim-level answers, history, evidence, and “Show me” in the inspector.
        - Read-only presentation—unlike Memory, there are no editing or curation controls.
        - Hide the self-referential “Ask Mechanician” button inside the Help workspace.
        - Keep demonstrations handing off to a standard conversation; never widen `help-expert`.
        - Make Help optionally addable to other workspaces, but visible by default only in Help.
        - Keep the standalone Help window for quick lookup and storage-recovery situations where \
          workspaces cannot open.

        Implementation should reuse `HelpLibrary` and the signed `MechanicianHelpStore`, but not \
        embed the existing 900-point `HelpWindowView` wholesale. We should extract a responsive \
        `HelpBrowserView`, with standalone and compact inspector hosts sharing the same reader \
        components.

        One useful follow-up would be an explicit “Ask about this” action. It should draft the \
        selected article or claim ID into the composer; inspector selection alone should not \
        silently alter agent context.

        So: mirror Memory’s interaction pattern, while preserving Help’s immutable, read-only \
        authority boundary. I’d make this the next Help slice.
        """

        XCTAssertEqual(
            try compiled(user: user, assistant: assistant),
            "Make this the next Help slice.")
    }

    func testDeicticNextSliceRecommendationRequiresCurrentUserGrounding() throws {
        XCTAssertNil(try compiled(
            user: "Improve provider account recovery.",
            assistant: "I’d make this the next Help slice."))
        XCTAssertNil(try compiled(
            user: "Can you help me improve provider account recovery?",
            assistant: "I’d make this the next Help slice."))
        XCTAssertNil(try compiled(
            user: "Improve the Help inspector.",
            assistant: "I’d make this the next slice."))
    }

    func testIllustrativeOrVetoedDeicticNextSliceIsNotAHandoff() throws {
        let user = "Build a dedicated Help workspace inspector."
        XCTAssertNil(try compiled(
            user: user,
            assistant: """
            Example:
            I’d make this the next Help slice.
            """))
        XCTAssertNil(try compiled(
            user: user,
            assistant: "I’d make this the next Help slice. Actually, don’t."))
    }

    func testOrderedHandoffDoesNotReachIntoALaterSection() throws {
        XCTAssertNil(try compiled(
            user: "Improve cached suggested prompts during migration.",
            assistant: """
            Next steps:
            No action is required yet.

            Risks:
            - Delete cached prompts during migration.
            """))
    }

    func testCompilerPreservesDottedFilenamesInPrescribedActions() throws {
        XCTAssertEqual(try compiled(
            user: "Improve memory rejection in SuggestedPromptFallback.swift.",
            assistant:
                "Next, update SuggestedPromptFallback.swift to reject memory-only context."),
            "Update SuggestedPromptFallback.swift to reject memory-only context.")
        XCTAssertEqual(try compiled(
            user: "Improve memory rejection in prompts.mjs.",
            assistant: "Next, update prompts.mjs to reject memory-only candidate context."),
            "Update prompts.mjs to reject memory-only candidate context.")

        let user = "Improve memory rejection in prompts.mjs."
        XCTAssertNil(SuggestedPromptFallback.sanitized(
            "Update prompts-mjs to reject memory-only candidate context.",
            avoiding: user,
            userPromptsToAvoid: [user],
            grounding: SuggestedPromptCandidateGrounding(
                currentTurnUserPrompts: [user],
                assistantHandoff:
                    "Next, update prompts.mjs to reject memory-only candidate context.")))
    }

    func testExamplesAndCodeNeverAuthorizeButFilteringResetsForARealHandoff() throws {
        let user = "Show an example of a debounce follow-up."
        for assistant in [
            """
            Here is an example of a handoff:

            Next, add timeout cancellation to the debounce follow-up.
            """,
            """
            Sample code:
            ~~~text
            Next, add timeout cancellation to the debounce follow-up.
            ~~~
            """,
            """
            ### Example output

            Next, add timeout cancellation to the debounce follow-up.
            """,
            """
            Suggested prompt example:

            Next, add timeout cancellation to the debounce follow-up.
            """,
            """
            Here are examples:

            Next, add timeout cancellation to the debounce follow-up.
            """,
            """
            Here are three examples:

            Next, add timeout cancellation to the debounce follow-up.
            """,
            """
            Some examples:

            Next, add timeout cancellation to the debounce follow-up.
            """,
            """
            For instance:

            Next, add timeout cancellation to the debounce follow-up.
            """,
            """
            Here’s an example

            Next, add timeout cancellation to the debounce follow-up.
            """,
            """
            Example response

            Next, add timeout cancellation to the debounce follow-up.
            """,
            """
            Here are three examples

            Next, add timeout cancellation to the debounce follow-up.
            """,
            "For example. Next, add timeout cancellation to the debounce follow-up.",
            "Example. Next, add timeout cancellation to the debounce follow-up.",
            "Sample. Next, add timeout cancellation to the debounce follow-up.",
            """
            Example response: this is the direct-action shape
            Next: Add timeout cancellation to the debounce follow-up.
            """,
            """
            Suggested prompt:

            Next: Add timeout cancellation to the debounce follow-up.
            """,
            """
            Here is an example:

            Suppose a request is already in flight.

            Next, add timeout cancellation to the debounce follow-up.
            """,
            "`Next, add timeout cancellation to the debounce follow-up.`",
            "- `Next, add timeout cancellation to the debounce follow-up.`",
            "`Next, add timeout cancellation to the debounce follow-up.`.",
            "- `Next, add timeout cancellation to the debounce follow-up.`.",
            "**`Next, add timeout cancellation to the debounce follow-up.`**",
            "- **`Next, add timeout cancellation to the debounce follow-up.`**",
            """
            ## Example response

            ### Next steps:
            - Add timeout cancellation to the debounce follow-up.
            """,
            """
            ### Example
            ## Another example
            ### Next steps:
            - Add timeout cancellation to the debounce follow-up.
            """,
            """
            Example response:

            ## Next steps
            - Add timeout cancellation to the debounce follow-up.
            """,
            """
            Example response:

            Recommended next steps:
            Next: Add timeout cancellation to the debounce follow-up.
            """,
            """
            Example response:

            Proposed next step:
            Next: Add timeout cancellation to the debounce follow-up.
            """,
        ] {
            XCTAssertNil(try compiled(user: user, assistant: assistant), assistant)
        }

        XCTAssertEqual(try compiled(
            user: "Prevent duplicate suggestion-chip follow-ups.",
            assistant: """
            Example response:

            Next, add timeout cancellation to the suggestion chip.

            ## Actual next step
            - Disable the suggestion chip during the request.
            """),
            "Disable the suggestion chip during the request.")

        XCTAssertEqual(try compiled(
            user: "Improve timeout handling in the example app.",
            assistant: """
            ## Recommended next step for the example app
            Next: Add timeout cancellation to the example app.
            """),
            "Add timeout cancellation to the example app.")
    }

    func testFullMessageFilteringRemovesAFenceBeforeHeadTailBounding() throws {
        let userEntry = TranscriptEntry(
            kind: .user,
            text: "Show a debounce follow-up example.")
        let assistantText = String(repeating: "Background context. ", count: 45)
            + "\n```text\n"
            + String(repeating: "fenced sample body ", count: 35)
            + "\nNext, add timeout cancellation to the debounce follow-up.\n```\n"
        let assistantEntry = TranscriptEntry(kind: .assistant, text: assistantText)
        let snapshot = try XCTUnwrap(SuggestedPromptFallback.snapshot(
            from: [userEntry, assistantEntry],
            turnID: "turn",
            rootPromptEntryID: userEntry.id))

        XCTAssertGreaterThan(assistantText.count, 1_100)
        XCTAssertFalse(snapshot.assistantHandoff.contains("timeout cancellation"))
        XCTAssertNil(SuggestedPromptFallback.compiledHandoff(from: snapshot))
        XCTAssertNil(SuggestedPromptFallback.sanitized(
            "Add timeout cancellation to the debounce follow-up.",
            avoiding: userEntry.text,
            userPromptsToAvoid: [userEntry.text],
            grounding: snapshot.candidateGrounding))
    }

    func testCommonActionVerbsRemainCompilableAndCategorized() throws {
        let commands = [
            "Rerun the focused prompt tests.",
            "Relaunch the dev app.",
            "Open the provider settings.",
            "Move prompt validation into the sanitizer.",
            "Merge the prompt evidence paths.",
            "Set the prompt timeout.",
            "Guard prompt publication with generation checks.",
            "Persist the prompt suggestion.",
            "Cancel stale prompt generation.",
            "Stop stale prompt publication.",
            "Start the prompt fallback.",
            "Switch the prompt source.",
            "Read the prompt provenance.",
            "Delete the stale prompt record.",
            "Push the prompt fix.",
            "Revert the prompt fallback.",
            "Rebuild the dev app.",
            "Run the focused prompt tests.",
        ]
        for command in commands {
            XCTAssertEqual(try compiled(
                user: "What should I do next?",
                assistant: "Next, \(command)"), command, command)
        }
        XCTAssertEqual(SuggestedPromptFallback.uncategorizedPromptActionWords, [])
        XCTAssertEqual(try compiled(
            user: "What should I do next?",
            assistant: "I recommend rerunning the focused prompt tests."),
            "Rerun the focused prompt tests.")
    }

    func testCompilerDeclinesUnresolvedChoicesUserSideTestsAndStatus() throws {
        XCTAssertNil(try compiled(
            user: "Choose the next Beacon learning slice.",
            assistant: """
            Next, implement Beacon capture.
            Should I implement capture first or skills first?
            """))
        XCTAssertNil(try compiled(
            user: "Test suggestion persistence through navigation and relaunch.",
            assistant: """
            Next, implement suggestion persistence.
            After this response, verify that its suggestion survives navigation and a same-build relaunch.
            """))
        XCTAssertNil(try compiled(
            user: "Finish live Beacon retrieval.",
            assistant: "Waiting for the corrected 6814d23 dogfood build to be installed."))
        XCTAssertNil(try compiled(
            user: "Show a locally generated follow-up prompt in the existing suggestion bar.",
            assistant: "The suggestion bar is ready. After this response, show a locally generated follow-up prompt."))
    }

    func testCompilerRejectsStaleConditionalAndUngroundedActions() throws {
        XCTAssertNil(try compiled(
            user: "Continue current Beacon implementation.",
            assistant: "Next, validate the suggestion from 0f27118; if it is useful, move directly to agent-accrued knowledge capture."))
        XCTAssertNil(try compiled(
            user: "Diagnose the library.db retrieval problem without changing authority.",
            assistant: "Next, remove library.db."))
    }

    func testCompilerDoesNotPromoteAnEarlierConversationGoalOverTheLatestUserGoal() throws {
        let visualizationGoal = TranscriptEntry(
            kind: .user,
            text: "Build the Beacon visualization panel.")
        let visualizationReply = TranscriptEntry(
            kind: .assistant,
            text: "I will prepare the visualization next.")
        let learningGoal = TranscriptEntry(
            kind: .user,
            text: "Continue learning and get it to the next dogfood stage.")
        let learningReply = TranscriptEntry(
            kind: .assistant,
            text: "Next, build the Beacon visualization panel.")

        let snapshot = try XCTUnwrap(SuggestedPromptFallback.snapshot(
            from: [visualizationGoal, visualizationReply, learningGoal, learningReply],
            turnID: "learning-turn",
            rootPromptEntryID: learningGoal.id))

        XCTAssertTrue(snapshot.userPromptsToAvoid.contains(visualizationGoal.text))
        XCTAssertFalse(snapshot.context.contains(visualizationGoal.text))
        XCTAssertEqual(snapshot.latestUserPrompt, learningGoal.text)
        XCTAssertNil(SuggestedPromptFallback.compiledHandoff(from: snapshot))
    }

    func testCompilerGroundsAHandoffInTheRootGoalWhenSteeringIsTerse() throws {
        let root = TranscriptEntry(
            kind: .user,
            text: "Implement the durable workspace mailbox in safe phases.")
        let steering = TranscriptEntry(kind: .user, text: "Yes, please.")
        let assistant = TranscriptEntry(
            kind: .assistant,
            text: "Next, add lease-backed delivery receipts to the durable workspace mailbox.")
        let snapshot = try XCTUnwrap(SuggestedPromptFallback.snapshot(
            from: [root, steering, assistant],
            turnID: "turn",
            rootPromptEntryID: root.id))

        XCTAssertEqual(snapshot.latestUserPrompt, steering.text)
        XCTAssertEqual(snapshot.currentTurnUserPrompts, [root.text, steering.text])
        XCTAssertEqual(
            SuggestedPromptFallback.compiledHandoff(from: snapshot),
            "Add lease-backed delivery receipts to the durable workspace mailbox.")
    }

    func testSanitizerRejectsObservedStaleStatusAndVerificationPrompts() {
        for candidate in [
            "Validate the suggestion from 0f27118; if it is useful, move directly to agent-accrued knowledge capture.",
            "Verify Beacon sequence completion and confirm whether agent-accrued knowledge capture should follow.",
            "Confirm Beacon installation is complete and ready for testing.",
        ] {
            XCTAssertNil(
                SuggestedPromptFallback.sanitized(candidate, avoiding: "Continue Beacon."),
                "Accepted stale status prompt: \(candidate)")
        }
    }

    func testSanitizerAcceptsOnePlainBoundedPrompt() {
        XCTAssertEqual(
            SuggestedPromptFallback.sanitized(
                "Suggested prompt: \"Add the focused race test next.\"",
                avoiding: "Implement the fallback"),
            "Add the focused race test next.")
        XCTAssertEqual(
            SuggestedPromptFallback.sanitized(
                "- Run the Codex fallback in the dev app.",
                avoiding: "Implement the fallback"),
            "Run the Codex fallback in the dev app.")
        XCTAssertEqual(
            SuggestedPromptFallback.sanitized(
                "Capture learning from user feedback.",
                avoiding: "Implement the fallback"),
            "Capture learning from user feedback.")
    }

    func testSanitizerRejectsAmbiguousBlankRepeatedAndOversizedOutput() {
        XCTAssertNil(SuggestedPromptFallback.sanitized(
            "First prompt\nSecond prompt", avoiding: "Something else"))
        XCTAssertNil(SuggestedPromptFallback.sanitized(
            "No suggestion", avoiding: "Something else"))
        XCTAssertNil(SuggestedPromptFallback.sanitized(
            "Implement the fallback", avoiding: "  IMPLEMENT   THE FALLBACK "))
        XCTAssertNil(SuggestedPromptFallback.sanitized(
            String(repeating: "x", count: SuggestedPromptFallback.maximumSuggestionCharacters + 1),
            avoiding: "Something else"))
        XCTAssertNil(SuggestedPromptFallback.sanitized("   ", avoiding: "Something else"))
    }

    func testSanitizerRejectsAddressedQuestionRestatementsButKeepsANewQuestion() {
        let earlierUserMessage = """
        This suggestion is still wrong:

        Why aren’t my suggest prompts persisting across restarts, especially after changes to other conversations?
        """
        XCTAssertNil(SuggestedPromptFallback.sanitized(
            "Why aren’t my suggest prompts persisting across restarts, especially after changes to other conversations?",
            avoiding: "Why does Wayfinder memory appear here?",
            userPromptsToAvoid: [earlierUserMessage]))
        XCTAssertNil(SuggestedPromptFallback.sanitized(
            "Why don't suggested prompts persist after restarts and conversation changes?",
            avoiding: "Why does Wayfinder memory appear here?",
            userPromptsToAvoid: [earlierUserMessage]))

        let newQuestion = "How should we verify the workspace fence under real work?"
        XCTAssertEqual(SuggestedPromptFallback.sanitized(
            newQuestion,
            avoiding: "Why does Wayfinder memory appear here?",
            userPromptsToAvoid: [earlierUserMessage]), newQuestion)
    }

    func testSanitizerRejectsCommandsCopiedFromAnyUserTurnAcrossPunctuationAndVoice() {
        let olderCommand = "Implement durable prompt persistence"
        XCTAssertNil(SuggestedPromptFallback.sanitized(
            "Implement durable prompt persistence.",
            avoiding: "Improve prompt relevance.",
            userPromptsToAvoid: [olderCommand, "Improve prompt relevance."]))

        let designRequest = """
        What do you think of implementing a mechanism for agents operating in different \
        conversations in a workspace to have a channel to communicate with each other?
        """
        XCTAssertNil(SuggestedPromptFallback.sanitized(
            "Design a simple messaging channel between agents in different workspaces.",
            avoiding: designRequest,
            userPromptsToAvoid: [designRequest]))

        XCTAssertNil(SuggestedPromptFallback.sanitized(
            "Fix why suggested prompts are missing.",
            avoiding: "Why are suggested prompts missing?",
            userPromptsToAvoid: ["Why are suggested prompts missing?"]))
    }

    func testSanitizerRejectsANarrowUserSubactionWithoutAssistantIntroducedDetail() {
        let user = "Wire Beacon into live recall, then fix suggested prompts."
        let assistant = "Live recall is wired. Suggested prompts are the remaining work."
        XCTAssertNil(SuggestedPromptFallback.sanitized(
            "Fix the suggested prompts next.",
            avoiding: user,
            userPromptsToAvoid: [user],
            grounding: SuggestedPromptCandidateGrounding(
                currentTurnUserPrompts: [user],
                assistantHandoff: assistant)))
    }

    func testSanitizerKeepsAUsefulNextActionNamedByTheAssistant() {
        XCTAssertEqual(SuggestedPromptFallback.sanitized(
            "Implement the restatement evidence path for existing claims.",
            avoiding: "What is the next action?"),
            "Implement the restatement evidence path for existing claims.")
    }

    func testGroundedSuggestionsMustBeActionsPrescribedByTheFinalAssistantMessage() {
        let user = "Prevent duplicate suggestion-chip follow-ups."
        let prescribed = SuggestedPromptCandidateGrounding(
            currentTurnUserPrompts: [user],
            assistantHandoff:
                "A better pattern for this case is to disable the suggestion chip during the request.")

        XCTAssertEqual(SuggestedPromptFallback.sanitized(
            "Disable the suggestion chip during the request.",
            avoiding: user,
            userPromptsToAvoid: [user],
            grounding: prescribed),
            "Disable the suggestion chip during the request.")
        XCTAssertEqual(SuggestedPromptFallback.sanitized(
            "Can you disable the suggestion chip during the request?",
            avoiding: user,
            userPromptsToAvoid: [user],
            grounding: prescribed),
            "Disable the suggestion chip during the request.")

        for candidate in [
            "How should we extend the debounce timeout?",
            "Explain how to integrate this with the sample repo.",
            "Add a timeout to the follow-up action.",
            "I will disable the suggestion chip during the request.",
            "We should disable the suggestion chip during the request.",
            "To disable the suggestion chip during the request.",
            "Disabling the suggestion chip during the request.",
        ] {
            XCTAssertNil(SuggestedPromptFallback.sanitized(
                candidate,
                avoiding: user,
                userPromptsToAvoid: [user],
                grounding: prescribed), "Accepted unprescribed candidate: \(candidate)")
        }
    }

    func testGroundedSuggestionLengthKeepsTheActionBarConcise() {
        XCTAssertEqual(SuggestedPromptFallback.maximumSuggestionCharacters, 120)
        XCTAssertEqual(SuggestedPromptFallback.maximumSuggestionWords, 12)
        let user = "Improve suggested-prompt action handoffs."
        let longAction = "Add a focused regression that verifies every generated suggestion "
            + "follows only the final assistant recommendation without unrelated context."
        XCTAssertGreaterThan(
            longAction.split(whereSeparator: { $0.isWhitespace }).count,
            SuggestedPromptFallback.maximumSuggestionWords)
        XCTAssertNil(SuggestedPromptFallback.sanitized(
            longAction,
            avoiding: user,
            userPromptsToAvoid: [user],
            grounding: SuggestedPromptCandidateGrounding(
                currentTurnUserPrompts: [user],
                assistantHandoff: "Next, \(longAction.lowercased())")))
    }

    func testModelMayOnlyShortenAnOverlongPrescriptionByRemovingFiller() {
        let user = "Improve timeout cancellation in final-assistant suggestions."
        let prescribed = "Add a focused regression for the final assistant recommendation "
            + "and timeout cancellation behavior."
        let shortened = "Add focused regression for the final assistant recommendation "
            + "and timeout cancellation behavior."
        let grounding = SuggestedPromptCandidateGrounding(
            currentTurnUserPrompts: [user],
            assistantHandoff: "Next, \(prescribed.lowercased())")

        XCTAssertGreaterThan(
            prescribed.split(whereSeparator: { $0.isWhitespace }).count,
            SuggestedPromptFallback.maximumSuggestionWords)
        XCTAssertEqual(
            shortened.split(whereSeparator: { $0.isWhitespace }).count,
            SuggestedPromptFallback.maximumSuggestionWords)
        XCTAssertEqual(SuggestedPromptFallback.sanitized(
            shortened,
            avoiding: user,
            userPromptsToAvoid: [user],
            grounding: grounding), shortened)

        XCTAssertNil(SuggestedPromptFallback.sanitized(
            "Add focused regression for the final assistant timeout cancellation behavior.",
            avoiding: user,
            userPromptsToAvoid: [user],
            grounding: grounding))
        XCTAssertNil(SuggestedPromptFallback.sanitized(
            "Replace focused regression for the final assistant recommendation "
                + "and timeout cancellation behavior.",
            avoiding: user,
            userPromptsToAvoid: [user],
            grounding: grounding))

        let genericUser = "What should we do next?"
        for (prescription, reversal) in [
            (
                "Move timeout handling from the provider fallback to the local fallback "
                    + "after generation.",
                "Move timeout handling from local fallback to provider fallback after generation."
            ),
            (
                "Add 2 provider timeout tests and 3 local fallback tests after generation completes.",
                "Add 3 provider timeout tests and 2 local fallback tests after generation."
            ),
            (
                "Configure the prompt cache for release, but don't delete the existing rollback "
                    + "generation after verification.",
                "Configure prompt cache for release and delete existing rollback generation "
                    + "after verification."
            ),
            (
                "Add a focused provider timeout test before publishing the final suggested "
                    + "prompt response.",
                "Add focused provider timeout tests before publishing final suggested "
                    + "prompt response."
            ),
            (
                "Update the prompts.mjs validator to reject memory-only context before publishing "
                    + "the final suggested prompt.",
                "Update prompts-mjs validator to reject memory-only context before publishing "
                    + "final suggested prompt."
            ),
        ] {
            XCTAssertNil(SuggestedPromptFallback.sanitized(
                reversal,
                avoiding: genericUser,
                userPromptsToAvoid: [genericUser],
                grounding: SuggestedPromptCandidateGrounding(
                    currentTurnUserPrompts: [genericUser],
                    assistantHandoff: "Next, \(prescription.lowercased())")),
                "Accepted meaning-reversing shortening: \(reversal)")
        }
    }

    func testSanitizerAllowsAnExplicitlyGroundedVerificationAction() {
        XCTAssertEqual(SuggestedPromptFallback.sanitized(
            "Test the repaired suggestion in the dev app.",
            avoiding: "Repair suggestion generation.",
            userPromptsToAvoid: ["Repair suggestion generation."],
            grounding: SuggestedPromptCandidateGrounding(
                currentTurnUserPrompts: ["Repair suggestion generation."],
                assistantHandoff:
                    "The repair is ready. Next, test the repaired suggestion in the dev app.")),
            "Test the repaired suggestion in the dev app.")
    }

    func testSanitizerDoesNotTurnACompletedVerificationBackIntoWork() {
        let user = "Test the suggested-prompt fix."
        XCTAssertNil(SuggestedPromptFallback.sanitized(
            "Test the suggested-prompt fix in the dev app.",
            avoiding: user,
            userPromptsToAvoid: [user],
            grounding: SuggestedPromptCandidateGrounding(
                currentTurnUserPrompts: [user],
                assistantHandoff:
                    "I tested the suggested-prompt fix in the dev app; it passed.")))
    }

    func testNewestAssistantStatusForTheVerificationTargetWins() {
        let user = "Repair suggested-prompt generation."
        let candidate = "Test the suggested-prompt fix in the dev app."
        let grounding: (String) -> SuggestedPromptCandidateGrounding = { assistant in
            SuggestedPromptCandidateGrounding(
                currentTurnUserPrompts: [user],
                assistantHandoff: assistant)
        }

        for assistant in [
            "Testing the suggested-prompt fix in the dev app is complete.",
            "Next, test the suggested-prompt fix in the dev app. "
                + "Testing the suggested-prompt fix in the dev app is now complete.",
            "Next, test the signed dogfood installer.",
        ] {
            XCTAssertNil(SuggestedPromptFallback.sanitized(
                candidate,
                avoiding: user,
                userPromptsToAvoid: [user],
                grounding: grounding(assistant)),
                "Accepted completed or mismatched verification: \(assistant)")
        }

        XCTAssertEqual(SuggestedPromptFallback.sanitized(
            candidate,
            avoiding: user,
            userPromptsToAvoid: [user],
            grounding: grounding(
                "Testing the suggested-prompt fix in the dev app was incomplete. "
                    + "Next, test the suggested-prompt fix in the dev app.")),
            candidate)
    }

    func testSanitizerCanonicalizesObservedAssistantPermissionVoice() {
        XCTAssertEqual(SuggestedPromptFallback.sanitized(
            "Please confirm whether you'd like to proceed with the agent-accrued knowledge capture path.",
            avoiding: "What should we do next?"),
            "Proceed with the agent-accrued knowledge capture path.")
        XCTAssertEqual(SuggestedPromptFallback.sanitized(
            "Please confirm whether you would like to proceed with source-backed learning",
            avoiding: "What should we do next?"),
            "Proceed with source-backed learning.")
        XCTAssertEqual(SuggestedPromptFallback.sanitized(
            "Please confirm whether you’d like to proceed with Beacon?",
            avoiding: "What should we do next?"),
            "Proceed with Beacon.")
    }

    func testSanitizerRejectsOtherHighConfidenceAssistantPermissionVoice() {
        for candidate in [
            "Would you like me to implement it?",
            "Do you want me to build the dogfood release?",
            "Let me know if you'd like me to continue.",
            "If you’d like, I can run the tests.",
            "I can implement it if you would like.",
        ] {
            XCTAssertNil(
                SuggestedPromptFallback.sanitized(candidate, avoiding: "Continue"),
                "Accepted assistant voice: \(candidate)")
        }
    }

    func testSanitizerPreservesDirectUserCommandsAndQuestions() {
        for candidate in [
            "Implement agent-accrued knowledge capture next.",
            "Can we test this through real work instead of a simulator?",
            "Should I install the dogfood build now?",
            "Shall I install the dogfood build now?",
            "May I see the evidence?",
            "Do you want the diagnostic logs?",
            "Would you like the diagnostic logs?",
        ] {
            XCTAssertEqual(
                SuggestedPromptFallback.sanitized(candidate, avoiding: "Something else"),
                candidate)
        }
    }

    func testCandidateSelectionSkipsAssistantVoiceAndKeepsFirstValidAlternative() {
        XCTAssertEqual(SuggestedPromptFallback.firstSanitizedCandidate(
            [
                "Would you like me to continue?",
                "Implement agent-accrued knowledge capture next.",
                "Discuss the learning algorithm.",
            ],
            avoiding: "What is next?"),
            "Implement agent-accrued knowledge capture next.")
        XCTAssertNil(SuggestedPromptFallback.firstSanitizedCandidate(
            ["Would you like me to continue?", "No suggestion"],
            avoiding: "What is next?"))
    }

    func testCandidateSelectionReportsContentFreeFailureCategories() {
        XCTAssertEqual(
            SuggestedPromptFallback.selectCandidate([], avoiding: "Continue"),
            SuggestedPromptCandidateSelection(
                suggestion: nil,
                candidateCount: 0,
                rejection: .noCandidates))
        XCTAssertEqual(
            SuggestedPromptFallback.selectCandidate(
                ["Would you like me to continue?", "No suggestion"],
                avoiding: "Continue"),
            SuggestedPromptCandidateSelection(
                suggestion: nil,
                candidateCount: 2,
                rejection: .mixed))
        let diagnostics = SuggestedPromptOutputDiagnostics(
            candidateCount: 2,
            rejection: .mixed)
        XCTAssertEqual(
            diagnostics.logDescription,
            "output_rejected candidates=2 rejection=mixed")
    }

    func testModelCandidateMustAdvanceTheNewestUserGoal() {
        let selection = SuggestedPromptFallback.selectCandidate(
            ["Implement an unrelated export feature."],
            avoiding: "Wire Beacon into live recall.",
            userPromptsToAvoid: ["Wire Beacon into live recall."],
            grounding: SuggestedPromptCandidateGrounding(
                currentTurnUserPrompts: ["Wire Beacon into live recall."],
                assistantHandoff:
                    "Live recall is wired; the cache boundary remains unaudited."))
        XCTAssertEqual(selection, SuggestedPromptCandidateSelection(
            suggestion: nil,
            candidateCount: 1,
            rejection: .ungrounded))

        XCTAssertEqual(SuggestedPromptFallback.selectCandidate(
            ["Audit the remaining Beacon cache boundary."],
            avoiding: "Wire Beacon into live recall.",
            userPromptsToAvoid: ["Wire Beacon into live recall."],
            grounding: SuggestedPromptCandidateGrounding(
                currentTurnUserPrompts: ["Wire Beacon into live recall."],
                assistantHandoff:
                    "Live recall is wired. Next, audit the remaining Beacon cache boundary.")).suggestion,
            "Audit the remaining Beacon cache boundary.")
    }

    func testConversationSuggestedPromptRoundTripsAndLegacyJSONDefaultsToNil() throws {
        let root = TranscriptEntry(kind: .user, text: "Keep this conversation")
        let assistant = TranscriptEntry(kind: .assistant, text: "The work is ready.")
        let record = ConversationSuggestedPrompt(
            text: "Implement source-backed discovery capture next.",
            source: .onDevice,
            rootPromptEntryID: root.id,
            assistantEntryID: assistant.id)
        let conversation = Conversation(
            title: "Durable suggestion",
            cwd: "/tmp/durable-suggestion",
            sdkSessionId: nil,
            messages: [root, assistant],
            updatedAt: Date(timeIntervalSinceReferenceDate: 42),
            suggestedPrompt: record)

        let encoder = ConversationStore.makeEncoder()
        let decoder = ConversationStore.makeDecoder()
        let data = try encoder.encode(conversation)
        XCTAssertEqual(
            try decoder.decode(Conversation.self, from: data).suggestedPrompt,
            record)

        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "suggestedPrompt")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try decoder.decode(Conversation.self, from: legacyData).suggestedPrompt)

        var future = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        var futureSuggestion = try XCTUnwrap(future["suggestedPrompt"] as? [String: Any])
        futureSuggestion["source"] = "future-source"
        future["suggestedPrompt"] = futureSuggestion
        let futureData = try JSONSerialization.data(withJSONObject: future)
        let futureDecoded = try decoder.decode(Conversation.self, from: futureData)
        XCTAssertNil(futureDecoded.suggestedPrompt)
        XCTAssertEqual(
            futureDecoded.messages.map(\.text),
            ["Keep this conversation", "The work is ready."])
        XCTAssertTrue(futureDecoded.needsStaleStatePersistence)
        XCTAssertTrue(futureDecoded.decodeNormalizations.contains(.suggestedPrompt))

        var orphaned = conversation
        orphaned.messages.append(TranscriptEntry(kind: .user, text: "A newer turn"))
        let orphanedData = try encoder.encode(orphaned)
        let orphanedDecoded = try decoder.decode(Conversation.self, from: orphanedData)
        XCTAssertNil(orphanedDecoded.suggestedPrompt)
        XCTAssertTrue(orphanedDecoded.decodeNormalizations.contains(.suggestedPrompt))

        var resumed = conversation
        resumed.messages.append(TranscriptEntry(
            kind: .user,
            text: "[wait-mode] The dogfood build was installed."))
        resumed.messages.append(TranscriptEntry(
            kind: .assistant,
            text: "The resumed turn is preparing a replacement suggestion."))
        let resumedDecoded = try decoder.decode(
            Conversation.self,
            from: encoder.encode(resumed))
        XCTAssertEqual(resumedDecoded.suggestedPrompt, record)
        XCTAssertFalse(resumedDecoded.decodeNormalizations.contains(.suggestedPrompt))
    }

    func testOnlyGenuineUserTurnsRetireAnExistingSuggestion() {
        XCTAssertFalse(SuggestedPromptFallback.shouldRetireExistingSuggestion(
            for: "  [wait-mode] The build stamp changed."))
        XCTAssertTrue(SuggestedPromptFallback.shouldRetireExistingSuggestion(
            for: "Improve the [wait-mode] behavior."))
        XCTAssertTrue(SuggestedPromptFallback.shouldRetireExistingSuggestion(
            for: "Start the next task."))
    }

    @MainActor
    func testConversationNavigationRestoresIndependentSuggestionsAndAcceptanceClearsOnlyOne() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Mechanician-suggested-prompt-navigation-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        let first = conversationWithSuggestion(
            title: "First",
            text: "Continue the first conversation.")
        let second = conversationWithSuggestion(
            title: "Second",
            text: "Continue the second conversation.")
        store.upsert(first)
        store.upsert(second)

        let bridge = AgentBridge(
            settingsBaseOverride: base.appendingPathComponent("settings"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        AgentBridge.live.add(bridge)
        defer {
            bridge.currentID = nil
            AgentBridge.live.remove(bridge)
            bridge.shutdown()
            store.flushSaves()
        }

        let openedFirst = await select(first.id, in: bridge)
        XCTAssertTrue(openedFirst)
        XCTAssertEqual(bridge.suggestedPrompt, "Continue the first conversation.")
        let openedSecond = await select(second.id, in: bridge)
        XCTAssertTrue(openedSecond)
        XCTAssertEqual(bridge.suggestedPrompt, "Continue the second conversation.")
        let reopenedFirst = await select(first.id, in: bridge)
        XCTAssertTrue(reopenedFirst)
        XCTAssertEqual(bridge.suggestedPrompt, "Continue the first conversation.")
        let capturedFirst = try XCTUnwrap(bridge.presentedSuggestedPromptRecord)

        let movedToSecond = await select(second.id, in: bridge)
        XCTAssertTrue(movedToSecond)
        XCTAssertFalse(bridge.acceptSuggestedPrompt(
            capturedFirst,
            draft: "Stale first-conversation draft"))
        XCTAssertEqual(store.conversation(second.id)?.draft, "")
        XCTAssertEqual(
            store.presentedSuggestedPrompt(for: second.id)?.text,
            "Continue the second conversation.")
        let returnedToFirst = await select(first.id, in: bridge)
        XCTAssertTrue(returnedToFirst)

        let acceptedDraft = "Existing draft\n\nContinue the first conversation."
        XCTAssertTrue(bridge.acceptSuggestedPrompt(capturedFirst, draft: acceptedDraft))
        XCTAssertNil(bridge.suggestedPrompt)
        XCTAssertNil(store.conversation(first.id)?.suggestedPrompt)
        XCTAssertEqual(store.conversation(first.id)?.draft, acceptedDraft)
        XCTAssertEqual(
            store.conversation(second.id)?.suggestedPrompt?.text,
            "Continue the second conversation.")

        bridge.stageRootWorkForTesting(
            conversationID: second.id,
            turnID: "background-wait-resume",
            selection: ModelSelection(
                access: .codexSubscription,
                modelID: "gpt-test"),
            pendingPrompt: "[wait-mode] The installed provenance now matches.")
        XCTAssertEqual(
            store.conversation(second.id)?.suggestedPrompt?.text,
            "Continue the second conversation.",
            "a synthetic wait turn preserves the old bar until its replacement commits")

        bridge.stageRootWorkForTesting(
            conversationID: second.id,
            turnID: "background-new-turn",
            selection: ModelSelection(
                access: .codexSubscription,
                modelID: "gpt-test"),
            pendingPrompt: "Start newer work in the second conversation")
        XCTAssertNil(
            store.conversation(second.id)?.suggestedPrompt,
            "a background new turn must clear only its owning conversation")
    }

    func testGenerationContractHonorsTheFinalAssistantHandoff() throws {
        let sourceURL = repositoryRoot()
            .appendingPathComponent("app/Sources/Mechanician/OnDeviceModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let compiler = try XCTUnwrap(source.range(of: "compiledHandoff(from: snapshot)"))
        let availability = try XCTUnwrap(source.range(
            of: "SystemLanguageModel.default.availability",
            range: compiler.upperBound..<source.endIndex))
        XCTAssertLessThan(compiler.lowerBound, availability.lowerBound)
        XCTAssertTrue(source.contains("final Assistant message explicitly"))
        XCTAssertTrue(source.contains("Write it as a short direct"))
        XCTAssertTrue(source.contains("Do not ask a question"))
        XCTAssertTrue(source.contains("Return no"))
        XCTAssertTrue(source.contains(".maximumCount(3)"))
        XCTAssertFalse(source.contains(".minimumCount(1)"))
        XCTAssertFalse(source.contains("RequiredSuggestedPrompt"))
        XCTAssertFalse(source.contains("repairInstructions"))
    }

    func testOnlyIdleSuccessfulOrdinaryTurnsWithoutNativeSuggestionsGenerate() {
        XCTAssertTrue(eligible())
        XCTAssertFalse(eligible(isConversationTurn: false))
        XCTAssertFalse(eligible(wasInterrupted: true))
        XCTAssertFalse(eligible(isConversationAvailable: false))
        XCTAssertFalse(eligible(isWorking: true))
        XCTAssertFalse(eligible(isStreaming: true))
        XCTAssertFalse(eligible(hasNativeSuggestion: true))
        XCTAssertTrue(
            eligible(modelIsAvailable: false),
            "the deterministic compiler must run before Foundation Models availability")
    }

    func testNativeAcceptanceNewTurnAndTranscriptChangesRetireLocalResultButNavigationDoesNot() throws {
        let conversationID = UUID()
        let user = TranscriptEntry(kind: .user, text: "Implement it")
        let assistant = TranscriptEntry(kind: .assistant, text: "Implemented")
        let snapshot = try XCTUnwrap(SuggestedPromptFallback.snapshot(
            from: [user, assistant],
            turnID: "turn-a",
            rootPromptEntryID: user.id))
        let attempt = SuggestedPromptFallbackAttempt(
            conversationID: conversationID,
            turnID: "turn-a",
            generation: 7,
            snapshot: snapshot,
            observedSuggestedPrompt: nil)

        XCTAssertTrue(mayPublish(attempt, currentConversationID: conversationID,
                                 currentGeneration: 7, snapshot: snapshot))
        XCTAssertFalse(mayPublish(attempt, currentConversationID: conversationID,
                                  currentGeneration: 8, snapshot: snapshot),
                       "A provider suggestion that arrived and was accepted must remain authoritative.")
        XCTAssertTrue(mayPublish(attempt, currentConversationID: conversationID,
                                 currentGeneration: 7, snapshot: snapshot),
                      "Showing another conversation must not invalidate the originating result.")
        XCTAssertFalse(mayPublish(attempt, currentConversationID: UUID(),
                                  currentGeneration: 7, snapshot: snapshot),
                       "A result may never be written to a different conversation.")
        XCTAssertFalse(mayPublish(attempt, currentConversationID: conversationID,
                                  currentGeneration: 7, snapshot: nil))
        XCTAssertFalse(mayPublish(attempt, currentConversationID: conversationID,
                                  currentGeneration: 7, snapshot: snapshot, isWorking: true))
        XCTAssertFalse(mayPublish(attempt, currentConversationID: conversationID,
                                  currentGeneration: 7, snapshot: snapshot,
                                  currentSuggestedPrompt: ConversationSuggestedPrompt(
                                    text: "A provider value won.",
                                    source: .provider,
                                    rootPromptEntryID: user.id,
                                    assistantEntryID: assistant.id)))

        let old = ConversationSuggestedPrompt(
            text: "Keep the old prompt until replacement.",
            source: .onDevice,
            rootPromptEntryID: user.id,
            assistantEntryID: assistant.id)
        let replacing = SuggestedPromptFallbackAttempt(
            conversationID: conversationID,
            turnID: "turn-a",
            generation: 9,
            snapshot: snapshot,
            observedSuggestedPrompt: old)
        XCTAssertTrue(mayPublish(
            replacing,
            currentConversationID: conversationID,
            currentGeneration: 9,
            snapshot: snapshot,
            currentSuggestedPrompt: old))
        XCTAssertFalse(mayPublish(
            replacing,
            currentConversationID: conversationID,
            currentGeneration: 9,
            snapshot: snapshot,
            currentSuggestedPrompt: nil))
    }

    func testSuccessfulTurnHandlerUsesTheSharedFallbackWithoutChangingTheSuggestionBar() throws {
        let sourceURL = repositoryRoot()
            .appendingPathComponent("app/Sources/Mechanician/AgentBridge.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("scheduleOnDeviceSuggestedPrompt("))
        XCTAssertTrue(source.contains("stageProviderSuggestedPrompt("))
        XCTAssertTrue(source.contains("takeProviderSuggestedPrompt("))
        XCTAssertTrue(source.contains("event[\"suggestion\"] as? String"))
        XCTAssertTrue(source.contains("dispatchAfterTurn() // run any interjection / queued prompt"))

        let contentURL = repositoryRoot()
            .appendingPathComponent("app/Sources/Mechanician/ContentView.swift")
        let content = try String(contentsOf: contentURL, encoding: .utf8)
        XCTAssertTrue(content.contains("if let suggestion = bridge.presentedSuggestedPromptRecord"))
        XCTAssertTrue(content.contains("suggestionBar(suggestion)"))
    }

    private func eligible(
        access: ModelAccess = .codexSubscription,
        isConversationTurn: Bool = true,
        wasInterrupted: Bool = false,
        isConversationAvailable: Bool = true,
        isWorking: Bool = false,
        isStreaming: Bool = false,
        hasNativeSuggestion: Bool = false,
        modelIsAvailable: Bool = true
    ) -> Bool {
        SuggestedPromptFallback.mayGenerate(
            access: access,
            isConversationTurn: isConversationTurn,
            wasInterrupted: wasInterrupted,
            isConversationAvailable: isConversationAvailable,
            isWorking: isWorking,
            isStreaming: isStreaming,
            hasNativeSuggestion: hasNativeSuggestion,
            modelIsAvailable: modelIsAvailable)
    }

    private func mayPublish(
        _ attempt: SuggestedPromptFallbackAttempt,
        currentConversationID: UUID?,
        currentGeneration: UInt64,
        snapshot: SuggestedPromptFallbackSnapshot?,
        isWorking: Bool = false,
        isStreaming: Bool = false,
        currentSuggestedPrompt: ConversationSuggestedPrompt? = nil
    ) -> Bool {
        SuggestedPromptFallback.mayPublish(
            attempt,
            targetConversationID: currentConversationID,
            currentGeneration: currentGeneration,
            currentSnapshot: snapshot,
            isWorking: isWorking,
            isStreaming: isStreaming,
            currentSuggestedPrompt: currentSuggestedPrompt)
    }

    private func compiled(user: String, assistant: String) throws -> String? {
        let userEntry = TranscriptEntry(kind: .user, text: user)
        let assistantEntry = TranscriptEntry(kind: .assistant, text: assistant)
        let snapshot = try XCTUnwrap(SuggestedPromptFallback.snapshot(
            from: [userEntry, assistantEntry],
            turnID: "turn",
            rootPromptEntryID: userEntry.id))
        return SuggestedPromptFallback.compiledHandoff(from: snapshot)
    }

    @MainActor
    private func conversationWithSuggestion(title: String, text: String) -> Conversation {
        let user = TranscriptEntry(kind: .user, text: "Work in \(title)")
        let assistant = TranscriptEntry(kind: .assistant, text: "Finished \(title)")
        return Conversation(
            title: title,
            cwd: "",
            sdkSessionId: nil,
            messages: [user, assistant],
            updatedAt: Date(),
            suggestedPrompt: ConversationSuggestedPrompt(
                text: text,
                source: .onDevice,
                rootPromptEntryID: user.id,
                assistantEntryID: assistant.id))
    }

    @MainActor
    private func select(_ id: UUID, in bridge: AgentBridge) async -> Bool {
        await withCheckedContinuation { continuation in
            bridge.select(id) { continuation.resume(returning: $0) }
        }
    }

    private func repositoryRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent() // MechanicianTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // repository root
    }
}
