import XCTest
@testable import Mechanician

final class ReplayContinuationPresentationTests: XCTestCase {
    func testFreshReplayNoticeClearsAfterTheReplacementSessionResumes() {
        let fresh = ReplayContinuationNoticeLifecycle.categoriesAfterAcknowledgement(
            existing: nil,
            freshReplay: [.agentLifecycle, .toolLifecycle, .agentLifecycle],
            isConversationTurn: true)

        XCTAssertEqual(fresh, [.toolLifecycle, .agentLifecycle])
        XCTAssertNil(ReplayContinuationNoticeLifecycle.categoriesAfterAcknowledgement(
            existing: fresh,
            freshReplay: nil,
            isConversationTurn: true))
    }

    func testEquivalentFreshReplayStillProducesOneQuietNotice() {
        let categories = ReplayContinuationNoticeLifecycle.categoriesAfterAcknowledgement(
            existing: [.toolLifecycle],
            freshReplay: [],
            isConversationTurn: true)

        XCTAssertNotNil(categories)
        XCTAssertEqual(categories, [])
    }

    func testReviewAcknowledgementDoesNotClearConversationContinuationNotice() {
        let existing: [ReplayDegradationCategory] = [.toolLifecycle, .agentLifecycle]

        XCTAssertEqual(
            ReplayContinuationNoticeLifecycle.categoriesAfterAcknowledgement(
                existing: existing,
                freshReplay: nil,
                isConversationTurn: false),
            existing)
    }

    func testEquivalentContinuationIsQuietAndReassuring() {
        let presentation = ReplayContinuationPresentation(categories: [])

        XCTAssertEqual(presentation.tone, .equivalent)
        XCTAssertEqual(presentation.title, "Continued in a new session")
        XCTAssertEqual(presentation.systemImage, "arrow.clockwise")
        XCTAssertEqual(presentation.detailLabels, [])
        XCTAssertTrue(presentation.summary.contains("messages"))
        XCTAssertTrue(presentation.summary.contains("replies"))
        XCTAssertTrue(presentation.footer.contains("nothing was removed"))
    }

    func testOperationalHistoryUsesInformationalPresentationAndUserLanguage() {
        let presentation = ReplayContinuationPresentation(categories: [
            .workflowLifecycle,
            .systemContext,
            .withdrawnOrSupersededContent,
            .interactionLifecycle,
            .toolLifecycle,
            .compaction,
            .agentLifecycle,
        ])

        XCTAssertEqual(presentation.tone, .informational)
        XCTAssertEqual(presentation.title, "Continued in a new session")
        XCTAssertEqual(presentation.systemImage, "arrow.clockwise")
        XCTAssertEqual(presentation.detailLabels, [
            "withdrawn or replaced content (intentionally excluded)",
            "earlier app notices",
            "previous tool activity",
            "earlier approvals and answers",
            "context-management events",
            "previous agent activity",
            "previous workflow activity",
        ])
        XCTAssertTrue(presentation.summary.contains("remain saved"))
        XCTAssertTrue(presentation.footer.hasPrefix("No action is usually needed"))
    }

    func testPotentiallyMaterialContentUsesWarningPresentation() {
        for category in [
            ReplayDegradationCategory.providerReview,
            .historyReduction,
            .artifactContent,
            .media,
        ] {
            let presentation = ReplayContinuationPresentation(categories: [category])

            XCTAssertEqual(presentation.tone, .warning, "Expected warning for \(category)")
            XCTAssertEqual(presentation.systemImage, "exclamationmark.circle")
            XCTAssertTrue(presentation.title.contains("may need rechecking"))
        }
    }

    func testReplaySourceDivergenceUsesAnActionableErrorWithoutFalseReassurance() {
        let rawDiagnostic = "provider-replay-source-diverged"
        let presentation = ReplayContinuationPresentation(categories: [
            .unknown(rawDiagnostic),
        ])

        XCTAssertEqual(presentation.tone, .error)
        XCTAssertEqual(presentation.systemImage, "exclamationmark.octagon")
        XCTAssertEqual(
            presentation.detailLabels,
            ["conversation replay could not be verified"])
        XCTAssertTrue(presentation.title.contains("Couldn't verify"))
        XCTAssertTrue(presentation.summary.contains("saved Conversation is unchanged"))
        XCTAssertFalse(presentation.summary.contains("were carried over"))
        XCTAssertFalse(presentation.helpText.contains(rawDiagnostic))
    }

    func testUnknownFutureDiagnosticFailsClosedWithoutLeakingItsInternalName() {
        let rawDiagnostic = "future-provider-state-omitted"
        let presentation = ReplayContinuationPresentation(categories: [
            .unknown(rawDiagnostic),
            .unknown("another-future-diagnostic"),
        ])

        XCTAssertEqual(presentation.tone, .warning)
        XCTAssertEqual(presentation.detailLabels, ["other session details"])
        XCTAssertFalse(presentation.title.contains(rawDiagnostic))
        XCTAssertFalse(presentation.helpText.contains(rawDiagnostic))
        XCTAssertFalse(presentation.helpText.contains("another-future-diagnostic"))
    }

    func testEveryKnownCategoryHasStableUserFacingDetailsWithoutAlarmistShorthand() {
        let presentation = ReplayContinuationPresentation(categories: [
            .media,
            .artifactContent,
            .workflowLifecycle,
            .agentLifecycle,
            .historyReduction,
            .compaction,
            .interactionLifecycle,
            .toolLifecycle,
            .providerReview,
            .systemContext,
            .withdrawnOrSupersededContent,
        ])

        XCTAssertEqual(presentation.detailLabels, [
            "withdrawn or replaced content (intentionally excluded)",
            "earlier app notices",
            "previous review results",
            "previous tool activity",
            "earlier approvals and answers",
            "context-management events",
            "shortened earlier history",
            "previous agent activity",
            "previous workflow activity",
            "artifacts and their activity",
            "attachment and image activity",
        ])

        let visibleCopy = [
            presentation.title,
            presentation.summary,
            presentation.helpText,
            presentation.footer,
        ].joined(separator: " ").lowercased()
        for internalPhrase in [
            "continuation is degraded",
            "durable fact",
            "system context",
            "provider-replay-source-diverged",
            "omitted:",
            " +",
        ] {
            XCTAssertFalse(
                visibleCopy.contains(internalPhrase),
                "User-facing copy leaked internal phrase: \(internalPhrase)")
        }
    }

    func testHelpTextListsDetailsAsAReadableSentence() {
        let one = ReplayContinuationPresentation(categories: [.toolLifecycle])
        let two = ReplayContinuationPresentation(categories: [
            .toolLifecycle, .interactionLifecycle,
        ])
        let three = ReplayContinuationPresentation(categories: [
            .systemContext, .toolLifecycle, .interactionLifecycle,
        ])

        XCTAssertTrue(one.helpText.contains("Details: previous tool activity."))
        XCTAssertTrue(two.helpText.contains(
            "Details: previous tool activity and earlier approvals and answers."))
        XCTAssertTrue(three.helpText.contains(
            "Details: earlier app notices, previous tool activity, and earlier approvals and answers."))
    }
}
