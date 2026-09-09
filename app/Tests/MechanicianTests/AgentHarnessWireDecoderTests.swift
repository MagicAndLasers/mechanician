import Foundation
import XCTest
@testable import Mechanician

final class AgentHarnessWireDecoderTests: XCTestCase {
    @MainActor
    func testOnlyCorrelatedHarnessObservationsRequireTurnOwnership() {
        XCTAssertTrue(AgentBridge.turnScopedEventTypes.contains("harness_observation"))
        XCTAssertFalse(AgentBridge.turnScopedEventTypes.contains("harness_metrics"))
        XCTAssertFalse(AgentBridge.turnScopedEventTypes.contains("harness_account_usage"))
    }

    func testPhaseObservationUsesClosedVocabularyAndExactClockFields() throws {
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let records = agentHarnessActivityRecords(from: [
            "type": "harness_observation",
            "id": "turn-1",
            "lane": "codex",
            "event": "phase",
            "phase": "thread_ready",
            "provenance": "mechanician_clock",
            "scope": "turn",
            "aggregation": "point",
            "at": "2026-08-31T12:34:56.125Z",
            "elapsedMs": NSNumber(value: 250),
            "warm": NSNumber(value: true),
            "threadAction": "resume",
            "prompt": "private prompt that must not cross",
            "path": "/private/workspace",
        ], receivedAt: receivedAt)

        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(record.turnID, "turn-1")
        XCTAssertEqual(record.harnessLaneID, .codex)
        XCTAssertEqual(record.harnessEventKind, .phase)
        XCTAssertEqual(record.harnessPhase, .threadReady)
        XCTAssertEqual(record.measurementProvenance, .mechanicianClock)
        XCTAssertEqual(record.measurementScope, .turn)
        XCTAssertEqual(record.measurementAggregation, .point)
        XCTAssertEqual(record.elapsedMs, 250)
        XCTAssertEqual(record.warm, true)
        XCTAssertEqual(record.threadAction, .resume)
        XCTAssertEqual(
            record.at,
            try XCTUnwrap(SendableISO8601Formatter.fractional.date(
                from: "2026-08-31T12:34:56.125Z")))
        XCTAssertNil(record.detail)
        XCTAssertNil(record.toolTarget)
    }

    func testFinalResultBecomesAuthoritativeTokenRecordAndRejectsBooleanNumbers() throws {
        let records = agentHarnessActivityRecords(from: [
            "type": "harness_observation",
            "id": "turn-result",
            "lane": "claude",
            "event": "result",
            "provenance": "provider_report",
            "scope": "agent_tree",
            "aggregation": "final",
            "providerQuerySequence": NSNumber(value: 2),
            "durationMs": NSNumber(value: true),
            "apiDurationMs": NSNumber(value: 8_000),
            "timeToFirstTokenMs": NSNumber(value: 700),
            "uncachedInputTokens": NSNumber(value: 100),
            "cacheWriteInputTokens": NSNumber(value: 20),
            "cacheReadInputTokens": NSNumber(value: 300),
            "inputTokens": NSNumber(value: 420),
            "outputTokens": NSNumber(value: 40),
            "result": "private response text",
            "cost_usd": NSNumber(value: 123),
        ])

        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.kind, .tokens)
        XCTAssertEqual(record.harnessEventKind, .result)
        XCTAssertEqual(record.measurementAggregation, .final)
        XCTAssertEqual(record.measurementScope, .agentTree)
        XCTAssertEqual(record.providerQuerySequence, 2)
        XCTAssertNil(record.durationMs)
        XCTAssertEqual(record.apiDurationMs, 8_000)
        XCTAssertEqual(record.timeToFirstTokenMs, 700)
        XCTAssertEqual(record.uncachedInputTokens, 100)
        XCTAssertEqual(record.cacheWriteInputTokens, 20)
        XCTAssertEqual(record.cachedInputTokens, 300)
        XCTAssertEqual(record.inputTokens, 420)
        XCTAssertEqual(record.outputTokens, 40)

        let encoded = try JSONEncoder().encode(record)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("private response"))
        XCTAssertFalse(text.contains("cost_usd"))
    }

    func testToolObservationMapsChildIdentityAndRequiresBoundedToolMetadata() throws {
        let record = try XCTUnwrap(agentHarnessActivityRecords(from: [
            "type": "harness_observation",
            "id": "turn-tool",
            "lane": "codex",
            "event": "tool",
            "provenance": "provider_report",
            "scope": "event",
            "aggregation": "final",
            "agentID": "thread-child-1",
            "toolUseID": "call-1",
            "toolKind": "command",
            "toolOutcome": "success",
            "toolDurationMs": NSNumber(value: 812),
            "command": "cat ~/.ssh/id_ed25519",
            "output": "secret output",
        ]).first)

        XCTAssertEqual(record.kind, .tool)
        XCTAssertEqual(record.agentID, AgentActivityIdentity.subagent("thread-child-1"))
        XCTAssertEqual(record.toolUseID, "call-1")
        XCTAssertEqual(record.toolKind, .command)
        XCTAssertEqual(record.toolOutcome, .success)
        XCTAssertEqual(record.toolDurationMs, 812)
        XCTAssertNil(record.detail)
        XCTAssertNil(record.toolTarget)

        XCTAssertTrue(agentHarnessActivityRecords(from: [
            "type": "harness_observation",
            "id": "turn-tool",
            "lane": "codex",
            "event": "tool",
            "provenance": "provider_report",
            "toolUseID": "call-1",
            "toolKind": "provider invented kind",
        ]).isEmpty)
    }

    func testRetrySafetyAndContextObservationsKeepOnlyTypedMetadata() throws {
        let retry = try XCTUnwrap(agentHarnessActivityRecords(from: [
            "type": "harness_observation",
            "id": "turn-retry",
            "lane": "codex",
            "event": "retry",
            "provenance": "provider_report",
            "scope": "request",
            "aggregation": "delta",
            "retryDisposition": "scheduled",
            "retryAttempt": NSNumber(value: 2),
            "willContinue": NSNumber(value: true),
            "errorKind": "connection",
            "httpStatusCode": NSNumber(value: 503),
            "message": "private response body and path",
        ]).first)
        XCTAssertEqual(retry.retryDisposition, .scheduled)
        XCTAssertEqual(retry.retryAttempt, 2)
        XCTAssertEqual(retry.retryWillContinue, true)
        XCTAssertEqual(retry.errorKind, "connection")
        XCTAssertEqual(retry.httpStatusCode, 503)
        XCTAssertNil(retry.detail)

        let safety = try XCTUnwrap(agentHarnessActivityRecords(from: [
            "type": "harness_observation",
            "id": "turn-safety",
            "lane": "codex",
            "event": "model_safety",
            "provenance": "provider_report",
            "scope": "turn",
            "aggregation": "point",
            "model": "gpt-safe",
            "fasterModel": "gpt-fast",
            "showBuffering": NSNumber(value: true),
            "safetyOutcome": "buffered",
            "safetyReasons": ["safety", "PRIVATE_SECRET_TOKEN", "other", "other"],
            "safetyUseCases": ["research", "PRIVATE_SECRET_TOKEN"],
            "explanation": "provider-authored prose",
        ]).first)
        XCTAssertNil(safety.rerouteModelID)
        XCTAssertEqual(safety.safetyFasterModelID, "gpt-fast")
        XCTAssertEqual(safety.safetyShowsBufferingUI, true)
        XCTAssertEqual(safety.safetyOutcome, .buffered)
        XCTAssertEqual(safety.safetyReasons, ["safety", "other"])
        XCTAssertEqual(safety.safetyUseCases, ["research", "other"])
        XCTAssertNil(safety.detail)

        let context = try XCTUnwrap(agentHarnessActivityRecords(from: [
            "type": "harness_observation",
            "id": "turn-context",
            "lane": "claude",
            "event": "context",
            "provenance": "provider_report",
            "scope": "thread",
            "aggregation": "snapshot",
            "contextTokens": NSNumber(value: 80_000),
            "contextUsableWindow": NSNumber(value: 180_000),
            "contextRawWindowTokens": NSNumber(value: 200_000),
            "contextComposition": [
                "system_prompt": NSNumber(value: 5_000),
                "messages": NSNumber(value: 70_000),
                "free": NSNumber(value: 100_000),
                "memory": NSNumber(value: true),
                "private_category": NSNumber(value: 123),
            ],
        ]).first)
        XCTAssertEqual(context.kind, .context)
        XCTAssertEqual(context.contextTokens, 80_000)
        XCTAssertEqual(context.contextUsableWindowTokens, 180_000)
        XCTAssertEqual(context.contextRawWindowTokens, 200_000)
        XCTAssertEqual(context.contextComposition?[.systemPrompt], 5_000)
        XCTAssertEqual(context.contextComposition?[.messages], 70_000)
        XCTAssertEqual(context.contextComposition?[.free], 100_000)
        XCTAssertNil(context.contextComposition?[.memory])
    }

    func testPrivacyCategoriesAreRevalidatedWithoutPersistingProviderTokens() throws {
        let reroute = try XCTUnwrap(agentHarnessActivityRecords(from: [
            "type": "harness_observation",
            "id": "turn-private",
            "lane": "codex",
            "event": "model_rerouted",
            "provenance": "provider_report",
            "rerouteReason": "PRIVATE_SECRET_TOKEN",
        ]).first)
        XCTAssertEqual(reroute.rerouteReason, "other")

        let verification = try XCTUnwrap(agentHarnessActivityRecords(from: [
            "type": "harness_observation",
            "id": "turn-private",
            "lane": "codex",
            "event": "model_verification",
            "provenance": "provider_report",
            "modelVerifications": ["trusted_access", "PRIVATE_SECRET_TOKEN"],
        ]).first)
        XCTAssertEqual(verification.modelVerifications, ["trusted_access", "other"])

        let compaction = try XCTUnwrap(agentHarnessActivityRecords(from: [
            "type": "harness_observation",
            "id": "turn-private",
            "lane": "claude",
            "event": "compaction",
            "provenance": "provider_report",
            "compactionDurationMs": NSNumber(value: 25),
            "compactionErrorKind": "PRIVATE_SECRET_TOKEN",
            "compactionSequence": NSNumber(value: 3),
        ]).first)
        XCTAssertEqual(compaction.compactionError, "other")
        XCTAssertEqual(compaction.compactionSequence, 3)

        let encoded = try JSONEncoder().encode([reroute, verification, compaction])
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("PRIVATE_SECRET_TOKEN"))
    }

    func testExpectedLaneRejectsCrossProviderObservation() {
        let event: [String: Any] = [
            "type": "harness_observation",
            "id": "turn-1",
            "lane": "codex",
            "event": "phase",
            "phase": "provider_ready",
            "provenance": "mechanician_clock",
        ]
        XCTAssertEqual(
            agentHarnessActivityRecords(from: event, expectedLane: .codex).count,
            1)
        XCTAssertTrue(
            agentHarnessActivityRecords(from: event, expectedLane: .claude).isEmpty)
    }

    func testMalformedOrFutureObservationIsDroppedWithoutInventingState() {
        XCTAssertTrue(agentHarnessActivityRecords(from: [
            "type": "harness_observation",
            "id": "turn-1",
            "lane": "codex",
            "event": "provider_future_event",
            "provenance": "provider_report",
        ]).isEmpty)
        XCTAssertTrue(agentHarnessActivityRecords(from: [
            "type": "harness_observation",
            "id": "turn-1",
            "lane": "codex",
            "event": "phase",
            "phase": "provider_future_phase",
            "provenance": "provider_report",
        ]).isEmpty)
        XCTAssertTrue(agentHarnessActivityRecords(from: [
            "type": "harness_observation",
            "id": "turn with spaces",
            "lane": "codex",
            "event": "result",
            "provenance": "provider_report",
        ]).isEmpty)
    }

    func testRuntimeMetricsParseISO8601InferUnitsAndStripUnknownAttributes() throws {
        let fallback = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = agentHarnessMetricSamples(from: [
            "type": "harness_metrics",
            "provider": "openai",
            "samples": [
                [
                    "name": "codex.tool.duration",
                    "kind": "histogram",
                    "at": "2023-11-14T22:13:20.000Z",
                    "count": NSNumber(value: 2),
                    "sum": NSNumber(value: 14),
                    "minimum": NSNumber(value: 4),
                    "maximum": NSNumber(value: 10),
                    "attributes": [
                        "model": "gpt",
                        "tool": "mcp",
                        "success": NSNumber(value: true),
                        "reason": "private_secret_token",
                        "command": "cat ~/.ssh/id_ed25519",
                        "error": "/private/path failed",
                    ],
                ],
                [
                    "name": "claude_code.token.usage",
                    "kind": "counter",
                    "at": "not-a-date",
                    "value": NSNumber(value: 7),
                ],
                [
                    "name": "codex.invalid.boolean",
                    "kind": "gauge",
                    "value": NSNumber(value: true),
                ],
                [
                    "name": "contains spaces",
                    "kind": "counter",
                    "value": NSNumber(value: 1),
                ],
                [
                    "name": "codex.turn.private_secret.duration.ms",
                    "kind": "histogram",
                    "count": NSNumber(value: 1),
                ],
            ],
        ], receivedAt: fallback)

        XCTAssertEqual(samples.count, 2)
        let codex = try XCTUnwrap(samples.first { $0.name.hasPrefix("codex.tool") })
        XCTAssertEqual(codex.harnessLaneID, .codex)
        XCTAssertEqual(codex.kind, .histogram)
        XCTAssertEqual(codex.unit, .milliseconds)
        XCTAssertEqual(codex.count, 2)
        XCTAssertEqual(codex.sum, 14)
        XCTAssertEqual(codex.min, 4)
        XCTAssertEqual(codex.max, 10)
        XCTAssertEqual(codex.attributes[.model], .string("gpt"))
        XCTAssertEqual(codex.attributes[.toolKind], .string("mcp"))
        XCTAssertEqual(codex.attributes[.success], .bool(true))
        XCTAssertEqual(codex.attributes[.provider], .string("codex"))
        XCTAssertEqual(codex.attributes.count, 4)

        let claude = try XCTUnwrap(samples.first { $0.name.hasPrefix("claude_code") })
        XCTAssertEqual(claude.harnessLaneID, .claude)
        XCTAssertEqual(claude.unit, .tokens)
        XCTAssertEqual(claude.value, 7)
        XCTAssertEqual(claude.at, fallback)
    }

    func testRuntimeMetricBatchIsBoundedAgainInSwift() {
        let rawSamples: [[String: Any]] = (0..<600).map { index in
            [
                "name": "codex.turn.duration",
                "kind": "gauge",
                "unit": "ms",
                "value": NSNumber(value: index),
            ]
        }
        let samples = agentHarnessMetricSamples(from: [
            "type": "harness_metrics",
            "provider": "codex",
            "samples": rawSamples,
        ])
        XCTAssertEqual(samples.count, 512)
    }

    func testRateLimitsBecomeSafeAggregatesWithoutBalancesOrOpaqueIDs() throws {
        let samples = agentHarnessMetricSamples(from: [
            "type": "harness_account_usage",
            "provider": "codex",
            "kind": "rate_limits",
            "provenance": "provider_report",
            "source": "notification",
            "aggregation": "snapshot",
            "complete": NSNumber(value: true),
            "bucketCount": NSNumber(value: 2),
            "resetCreditsAvailable": NSNumber(value: 3),
            "opaqueLimitID": "private-limit-id",
            "buckets": [
                [
                    "planType": "plus",
                    "primary": [
                        "usedPercent": NSNumber(value: 25),
                        "windowDurationMins": NSNumber(value: 300),
                        "resetsAt": NSNumber(value: 1_800_000_000),
                    ],
                    "secondary": [
                        "usedPercent": NSNumber(value: 10),
                        "windowDurationMins": NSNumber(value: 10_080),
                        "resetsAt": NSNumber(value: 1_800_500_000),
                    ],
                    "credits": [
                        "hasCredits": NSNumber(value: true),
                        "unlimited": NSNumber(value: false),
                        "balance": "123.45 private credits",
                    ],
                    "individualLimit": [
                        "remainingPercent": NSNumber(value: 80),
                        "resetsAt": NSNumber(value: 1_800_600_000),
                    ],
                    "rateLimitReached": NSNumber(value: true),
                ],
                [
                    "primary": ["usedPercent": NSNumber(value: 40)],
                    "secondary": ["usedPercent": NSNumber(value: 5)],
                    // Numeric 1 is not a JSON boolean and must not become an observed flag.
                    "spendControlReached": NSNumber(value: 1),
                ],
            ],
        ])

        let values = Dictionary(uniqueKeysWithValues: samples.compactMap { sample in
            sample.value.map { (sample.name, $0) }
        })
        XCTAssertEqual(values["codex.account.rate_limits.bucket_count"], 2)
        XCTAssertEqual(values["codex.account.rate_limits.primary.used_percent.max"], 40)
        XCTAssertEqual(values["codex.account.rate_limits.secondary.used_percent.max"], 10)
        XCTAssertEqual(values["codex.account.rate_limits.individual.remaining_percent.min"], 80)
        XCTAssertEqual(values["codex.account.rate_limits.credits.has_credits.any"], 1)
        XCTAssertEqual(values["codex.account.rate_limits.credits.unlimited.any"], 0)
        XCTAssertEqual(values["codex.account.rate_limits.reached.any"], 1)
        XCTAssertNil(values["codex.account.rate_limits.spend_control_reached.any"])
        XCTAssertEqual(values["codex.account.rate_limits.reset_credits.available"], 3)
        XCTAssertEqual(
            samples.first {
                $0.name == "codex.account.rate_limits.primary.resets_at.earliest"
            }?.unit,
            .unixSeconds)
        XCTAssertTrue(samples.allSatisfy { $0.harnessLaneID == .codex })
        XCTAssertEqual(samples.first?.attributes[.status], .string("complete"))

        let encoded = try JSONEncoder().encode(samples)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("private-limit-id"))
        XCTAssertFalse(text.contains("123.45"))
        XCTAssertFalse(text.contains("balance"))
        XCTAssertFalse(text.contains("plus"))

        let clearedWarning = agentHarnessMetricSamples(from: [
            "type": "harness_account_usage",
            "provider": "codex",
            "kind": "rate_limits",
            "provenance": "provider_report",
            "complete": NSNumber(value: true),
            "bucketCount": NSNumber(value: 1),
            "buckets": [["rateLimitReached": NSNumber(value: false)]],
        ])
        XCTAssertEqual(
            clearedWarning.first { $0.name == "codex.account.rate_limits.reached.any" }?.value,
            0)
    }

    func testAccountTokenSummaryAndDailyBucketsAreBoundedAndValidated() throws {
        var daily: [[String: Any]] = (0..<380).map { index in
            [
                "startDate": String(format: "%04d-01-01", 2000 + index),
                "tokens": NSNumber(value: index),
                "threadId": "opaque-thread-\(index)",
            ]
        }
        daily[0]["tokens"] = NSNumber(value: true)
        daily[1]["startDate"] = "2026-02-31"

        let samples = agentHarnessMetricSamples(from: [
            "type": "harness_account_usage",
            "provider": "codex",
            "kind": "token_usage",
            "provenance": "provider_report",
            "source": "read",
            "aggregation": "snapshot",
            "summary": [
                "lifetimeTokens": NSNumber(value: 1_000_000),
                "peakDailyTokens": NSNumber(value: 100_000),
                "longestRunningTurnSec": NSNumber(value: 600),
                "currentStreakDays": NSNumber(value: 3),
                "longestStreakDays": NSNumber(value: 9),
                "estimatedUsageUsdMicros": NSNumber(value: 456),
            ],
            "dailyBucketCount": NSNumber(value: 380),
            "dailyUsage": daily,
            "threadUsage": ["threadId": "opaque-thread", "cost": "private"],
        ])

        let values = Dictionary(uniqueKeysWithValues: samples.compactMap { sample in
            sample.value.map { (sample.name, $0) }
        })
        XCTAssertEqual(values["codex.account.tokens.lifetime"], 1_000_000)
        XCTAssertEqual(values["codex.account.tokens.daily.peak"], 100_000)
        XCTAssertEqual(values["codex.account.turn.longest_running"], 600)
        XCTAssertEqual(values["codex.account.streak.current_days"], 3)
        XCTAssertEqual(values["codex.account.streak.longest_days"], 9)
        XCTAssertEqual(values["codex.account.tokens.daily.bucket_count"], 380)
        XCTAssertEqual(
            samples.filter { sample in
                sample.name.hasPrefix("codex.account.tokens.daily.2")
                    && sample.name.count == "codex.account.tokens.daily.2000-01-01".count
            }.count,
            364)
        XCTAssertFalse(samples.contains { $0.name.contains("2026-02-31") })

        let encoded = try JSONEncoder().encode(samples)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("opaque-thread"))
        XCTAssertFalse(text.contains("estimatedUsage"))
        XCTAssertFalse(text.contains("private"))
    }

    func testAccountBatchPreservesCompleteEmptyReplacementBoundaries() throws {
        let rateLimits = try XCTUnwrap(agentHarnessMetricBatch(from: [
            "type": "harness_account_usage",
            "provider": "codex",
            "kind": "rate_limits",
            "provenance": "provider_report",
            "source": "read",
            "aggregation": "snapshot",
            "complete": NSNumber(value: true),
            "bucketCount": NSNumber(value: 0),
            "buckets": [],
        ]))
        XCTAssertEqual(rateLimits.accountFamily, .rateLimits)
        XCTAssertTrue(rateLimits.replacesAccountFamily)
        XCTAssertEqual(rateLimits.samples.count, 1)
        XCTAssertEqual(rateLimits.samples.first?.value, 0)

        let clearedTokens = try XCTUnwrap(agentHarnessMetricBatch(from: [
            "type": "harness_account_usage",
            "provider": "codex",
            "kind": "token_usage",
            "provenance": "provider_report",
            "source": "read",
            "aggregation": "snapshot",
            "complete": NSNumber(value: true),
            "summary": [:],
            "dailyBucketCount": NSNumber(value: 0),
            "dailyUsage": [],
        ]))
        XCTAssertEqual(clearedTokens.accountFamily, .tokenUsage)
        XCTAssertTrue(clearedTokens.replacesAccountFamily)
        XCTAssertEqual(clearedTokens.samples.map(\.name), ["codex.account.tokens.daily.bucket_count"])

        let partial = try XCTUnwrap(agentHarnessMetricBatch(from: [
            "type": "harness_account_usage",
            "provider": "codex",
            "kind": "rate_limits",
            "provenance": "provider_report",
            "source": "notification",
            "aggregation": "snapshot",
            "complete": NSNumber(value: false),
            "buckets": [],
        ]))
        XCTAssertFalse(partial.replacesAccountFamily)
        XCTAssertTrue(partial.samples.isEmpty)
    }

    func testLegacyTokenSnapshotIsCompleteButMalformedMarkerCannotClearLedger() throws {
        let legacy = try XCTUnwrap(agentHarnessMetricBatch(from: [
            "type": "harness_account_usage",
            "provider": "codex",
            "kind": "token_usage",
            "provenance": "provider_report",
            "source": "read",
            "summary": ["lifetimeTokens": NSNumber(value: 1)],
        ]))
        XCTAssertTrue(legacy.replacesAccountFamily)

        let malformed = try XCTUnwrap(agentHarnessMetricBatch(from: [
            "type": "harness_account_usage",
            "provider": "codex",
            "kind": "token_usage",
            "provenance": "provider_report",
            "source": "read",
            "complete": NSNumber(value: 1),
            "summary": [:],
        ]))
        XCTAssertFalse(malformed.replacesAccountFamily)
    }
}
