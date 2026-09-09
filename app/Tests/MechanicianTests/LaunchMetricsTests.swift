import Foundation
import XCTest
@testable import Mechanician

final class LaunchMetricsTests: XCTestCase {
    func testWallClockElapsedIsRejectedWhenItCannotBeTrusted() {
        XCTAssertEqual(
            LaunchClock.plausibleElapsed(processStartEpoch: 1_000, nowEpoch: 1_002.5),
            2.5)
        // A clock change during launch must fall back to the in-process mark rather than report a
        // negative or hour-long launch.
        XCTAssertNil(LaunchClock.plausibleElapsed(processStartEpoch: 1_000, nowEpoch: 999))
        XCTAssertNil(LaunchClock.plausibleElapsed(processStartEpoch: 1_000, nowEpoch: 4_000))
        XCTAssertNil(
            LaunchClock.plausibleElapsed(processStartEpoch: 1_000, nowEpoch: .nan))
    }

    /// `dev.sh` ends in `exec`, so the app inherits the shell's PID and the kernel reports a start
    /// time that includes the whole build. A measured 38.0 s "launch" is how this was found.
    func testAnExecInheritedProcessStartIsNotTreatedAsALaunch() {
        XCTAssertTrue(LaunchClock.trustsProcessStart(secondsElapsedAtAppStart: 0.4))
        XCTAssertTrue(
            LaunchClock.trustsProcessStart(
                secondsElapsedAtAppStart: LaunchClock.maximumPreLaunchSeconds))
        XCTAssertFalse(LaunchClock.trustsProcessStart(secondsElapsedAtAppStart: 27.7))
        XCTAssertFalse(LaunchClock.trustsProcessStart(secondsElapsedAtAppStart: nil))
    }

    func testProcessStartIsReadableForThisProcess() throws {
        let start = try XCTUnwrap(LaunchClock.processStartEpoch())
        let elapsed = try XCTUnwrap(
            LaunchClock.plausibleElapsed(
                processStartEpoch: start,
                nowEpoch: Date().timeIntervalSince1970))
        XCTAssertGreaterThanOrEqual(elapsed, 0)
    }

    func testDurationsReadAsMillisecondsThenSeconds() {
        XCTAssertEqual(LaunchTimingPresentation.duration(480), "480 ms")
        XCTAssertEqual(LaunchTimingPresentation.duration(999), "999 ms")
        XCTAssertEqual(LaunchTimingPresentation.duration(1_000), "1.0 s")
        XCTAssertEqual(LaunchTimingPresentation.duration(1_940), "1.9 s")
        XCTAssertNil(LaunchTimingPresentation.duration(nil))
        XCTAssertNil(LaunchTimingPresentation.duration(-1))
    }

    func testSummaryDegradesHonestlyWhenALaunchOpenedNoConversation() {
        XCTAssertEqual(LaunchTimingPresentation.summary(nil), "Not measured yet")
        XCTAssertEqual(
            LaunchTimingPresentation.summary(record(inventory: 1_940, conversation: nil)),
            "1.9 s to inventory")
        XCTAssertEqual(
            LaunchTimingPresentation.summary(record(inventory: 1_940, conversation: 2_380)),
            "1.9 s to inventory · 2.4 s to conversation")
    }

    func testMedianResistsASingleColdLaunch() {
        let records = [400, 9_000, 460, 420, 480].map { record(inventory: $0) }
        XCTAssertEqual(LaunchTimingPresentation.median(records), "460 ms across 5 launches")
        XCTAssertEqual(
            LaunchTimingPresentation.median([record(inventory: 700)]),
            "700 ms across 1 launch")
        XCTAssertNil(LaunchTimingPresentation.median([]))
    }

    @MainActor
    func testOnlyTheFirstReadinessAndFirstTranscriptCountAsTheLaunch() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "launch-metrics-\(UUID().uuidString)"))
        let metrics = LaunchMetrics(defaults: defaults, loadsHistory: false)
        metrics.markAppStart()

        // A transcript cannot be attributed to a launch that never became ready.
        metrics.markFirstConversationVisible()
        XCTAssertTrue(metrics.history.isEmpty)

        metrics.markInventoryReady(usedSQLiteInventory: true, conversationCount: 96)
        XCTAssertEqual(metrics.history.count, 1)
        XCTAssertNil(metrics.lastLaunch?.conversationMilliseconds)
        XCTAssertEqual(metrics.lastLaunch?.conversationCount, 96)
        XCTAssertEqual(metrics.lastLaunch?.usedSQLiteInventory, true)

        metrics.markInventoryReady(usedSQLiteInventory: false, conversationCount: 1)
        XCTAssertEqual(metrics.history.count, 1, "readiness is announced once per launch")

        metrics.markFirstConversationVisible()
        let first = metrics.lastLaunch?.conversationMilliseconds
        XCTAssertNotNil(first)
        // Later navigation reuses the same opening view; it must not overwrite the launch.
        metrics.markFirstConversationVisible()
        XCTAssertEqual(metrics.lastLaunch?.conversationMilliseconds, first)
    }

    /// The breakdown reports time spent *in* each segment, so the largest number names the thing
    /// to fix rather than restating a cumulative clock.
    func testBreakdownReportsPerSegmentTimeInStageOrder() {
        var measured = record(inventory: 2_481, conversation: 4_133)
        measured.stages = [
            LaunchStage.appCode.rawValue: 900,
            LaunchStage.libraryRead.rawValue: 1_200,
            LaunchStage.searchCheck.rawValue: 2_300,
            LaunchStage.inventoryReady.rawValue: 2_481,
            LaunchStage.workspaceVisible.rawValue: 4_133,
        ]
        XCTAssertEqual(
            LaunchTimingPresentation.breakdown(measured),
            "startup 900 ms · library 300 ms · search 1.1 s · sidebar 181 ms · transcript 1.7 s",
            "a stage the launch never reached is skipped, not counted as zero")
        XCTAssertNil(LaunchTimingPresentation.breakdown(record(inventory: 100)))
        XCTAssertNil(LaunchTimingPresentation.breakdown(nil))
    }

    /// The transcript wait was one opaque segment, which is why nobody could say what it contained.
    /// These three sub-stages split it into work that can be named, so the breakdown attributes the
    /// wait rather than merely reporting it.
    func testTheTranscriptWaitIsAttributedToNamedWork() {
        var measured = record(inventory: 1_133, conversation: 3_176)
        measured.stages = [
            LaunchStage.appCode.rawValue: 348,
            LaunchStage.storeOpen.rawValue: 644,
            LaunchStage.libraryRead.rawValue: 1_133,
            LaunchStage.inventoryReady.rawValue: 1_133,
            LaunchStage.launchFollowUp.rawValue: 1_700,
            LaunchStage.conversationRequested.rawValue: 1_750,
            LaunchStage.conversationRecord.rawValue: 3_100,
            LaunchStage.conversationInstalled.rawValue: 3_140,
            LaunchStage.workspaceVisible.rawValue: 3_176,
        ]
        XCTAssertEqual(
            LaunchTimingPresentation.breakdown(measured),
            "startup 348 ms · app setup 296 ms · library 489 ms · sidebar 0 ms"
                + " · follow-up 567 ms · requested 50 ms · record 1.4 s"
                + " · install 40 ms · transcript 36 ms")
    }

    /// A launch that reaches the transcript without recording the new sub-stages still reads
    /// correctly, so an older record and a path that skips them are both reported honestly.
    func testASegmentWithoutTheNewSubStagesStillReportsAsOneWait() {
        var measured = record(inventory: 1_133, conversation: 3_176)
        measured.stages = [
            LaunchStage.inventoryReady.rawValue: 1_133,
            LaunchStage.workspaceVisible.rawValue: 3_176,
        ]
        XCTAssertEqual(
            LaunchTimingPresentation.breakdown(measured),
            "sidebar 1.1 s · transcript 2.0 s")
    }

    /// Records written before stages existed must still decode. A non-optional addition would
    /// quarantine them, which is the persisted-struct trap this project has already paid for once.
    func testOlderRecordsWithoutStagesStillDecode() throws {
        let legacy = Data(
            ("[{\"startedAt\":760000000,\"inventoryMilliseconds\":2481,"
             + "\"usedSQLiteInventory\":true,\"conversationCount\":81}]").utf8)
        let decoded = try JSONDecoder().decode([LaunchTimingRecord].self, from: legacy)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded.first?.stages)
        XCTAssertEqual(decoded.first?.inventoryMilliseconds, 2_481)
    }

    @MainActor
    func testStagesAreRecordedOnceAndAttachToTheLaunchRecord() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "launch-stages-\(UUID().uuidString)"))
        let metrics = LaunchMetrics(defaults: defaults, loadsHistory: false)
        metrics.markAppStart()
        metrics.mark(.libraryRead)
        metrics.markInventoryReady(usedSQLiteInventory: true, conversationCount: 81)

        let stages = try XCTUnwrap(metrics.lastLaunch?.stages)
        XCTAssertNotNil(stages[LaunchStage.appCode.rawValue])
        XCTAssertNotNil(stages[LaunchStage.libraryRead.rawValue])
        XCTAssertEqual(
            stages[LaunchStage.inventoryReady.rawValue],
            metrics.lastLaunch?.inventoryMilliseconds)
        XCTAssertNil(stages[LaunchStage.searchCheck.rawValue], "a skipped stage stays absent")

        // A repeated step must not rewrite the segment the person already waited through.
        let firstRead = stages[LaunchStage.libraryRead.rawValue]
        metrics.mark(.libraryRead)
        XCTAssertEqual(metrics.lastLaunch?.stages?[LaunchStage.libraryRead.rawValue], firstRead)

        metrics.markFirstConversationVisible()
        XCTAssertNotNil(metrics.lastLaunch?.stages?[LaunchStage.workspaceVisible.rawValue])
    }

    @MainActor
    func testHistoryIsBoundedAndSurvivesRelaunch() throws {
        let suite = "launch-metrics-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        for index in 0..<(LaunchMetrics.retainedLaunches + 3) {
            let metrics = LaunchMetrics(defaults: defaults)
            metrics.markInventoryReady(usedSQLiteInventory: true, conversationCount: index)
        }

        let reloaded = LaunchMetrics(defaults: defaults)
        XCTAssertEqual(reloaded.history.count, LaunchMetrics.retainedLaunches)
        XCTAssertEqual(
            reloaded.history.last?.conversationCount,
            LaunchMetrics.retainedLaunches + 2,
            "the newest launch must be the one kept")
    }

    private func record(inventory: Int, conversation: Int? = nil) -> LaunchTimingRecord {
        LaunchTimingRecord(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            inventoryMilliseconds: inventory,
            conversationMilliseconds: conversation,
            usedSQLiteInventory: true,
            conversationCount: 96)
    }
}
