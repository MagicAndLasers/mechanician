import assert from 'node:assert/strict'
import test from 'node:test'

import {
  HARNESS_ACCOUNT_DAILY_MAX_BUCKETS,
  HARNESS_CLAUDE_USAGE_IDS_MAX_ENTRIES,
  HARNESS_RATE_LIMIT_MAX_BUCKETS,
  HARNESS_RETRY_HISTORY_MAX_ENTRIES,
  claimClaudeAssistantUsageSample,
  claudeContextObservation,
  claudeResultObservation,
  codexAccountTokenUsageObservation,
  codexModelObservation,
  codexRateLimitsObservation,
  codexRetryObservation,
  codexRetryRecoveredObservation,
  codexToolObservation,
  harnessCompactionObservation,
  harnessPhaseObservation,
  updateCodexRateLimitState,
} from '../src/harness-observations.mjs'

test('phase observations keep exact harness clock boundaries and closed metadata', () => {
  assert.deepEqual(harnessPhaseObservation({
    id: 'turn-1',
    lane: 'codex',
    phase: 'thread_ready',
    startedAt: 1_000,
    now: 1_250,
    warm: true,
    threadAction: 'resume',
  }), {
    type: 'harness_observation',
    id: 'turn-1',
    lane: 'codex',
    event: 'phase',
    provenance: 'mechanician_clock',
    scope: 'turn',
    aggregation: 'point',
    phase: 'thread_ready',
    at: '1970-01-01T00:00:01.250Z',
    elapsedMs: 250,
    warm: true,
    threadAction: 'resume',
  })
  assert.equal(harnessPhaseObservation({
    id: 'turn-1', lane: 'codex', phase: 'provider invented this',
  }), null)
})

test('compaction observations use exact provider duration or paired harness-clock boundaries', () => {
  assert.deepEqual(harnessCompactionObservation({
    id: 'turn-1', lane: 'codex', durationMs: 812, trigger: 'provider',
    agentID: 'child-1', compactionSequence: 2,
  }), {
    type: 'harness_observation',
    id: 'turn-1',
    lane: 'codex',
    event: 'compaction',
    provenance: 'provider_report',
    scope: 'event',
    aggregation: 'final',
    compactionDurationMs: 812,
    compactionTrigger: 'provider',
    agentID: 'child-1',
    compactionSequence: 2,
  })
  assert.deepEqual(harnessCompactionObservation({
    id: 'turn-claude', lane: 'claude', startedAt: 1_000, completedAt: 1_250,
    trigger: 'auto', errorKind: 'compaction_failed',
  }), {
    type: 'harness_observation',
    id: 'turn-claude',
    lane: 'claude',
    event: 'compaction',
    provenance: 'mechanician_clock',
    scope: 'event',
    aggregation: 'final',
    compactionDurationMs: 250,
    compactionTrigger: 'auto',
    compactionErrorKind: 'compaction',
  })
  assert.equal(harnessCompactionObservation({
    id: 'turn-1', lane: 'codex', trigger: 'free form trigger',
  }), null)
  const privateFailure = harnessCompactionObservation({
    id: 'turn-1', lane: 'codex', durationMs: 1, errorKind: 'PRIVATE_SECRET_TOKEN',
  })
  assert.equal(privateFailure.compactionErrorKind, 'other')
  assert.doesNotMatch(JSON.stringify(privateFailure), /PRIVATE_SECRET_TOKEN/)
})

test('Claude assistant usage ids dedupe within a bounded turn set and id-less samples fall through', () => {
  const seen = new Set()
  const message = { message: { id: 'msg-1' } }
  assert.equal(claimClaudeAssistantUsageSample(seen, message), true)
  assert.equal(claimClaudeAssistantUsageSample(seen, message), false)
  assert.equal(claimClaudeAssistantUsageSample(seen, { message: {} }), true)

  for (let index = 0; index < HARNESS_CLAUDE_USAGE_IDS_MAX_ENTRIES + 10; index += 1) {
    claimClaudeAssistantUsageSample(seen, { message: { id: `msg-${index + 2}` } })
  }
  assert.equal(seen.size, HARNESS_CLAUDE_USAGE_IDS_MAX_ENTRIES)
})

test('Codex retry observations retain typed history without provider error prose', () => {
  const retry = codexRetryObservation({
    id: 'turn-1',
    retryAttempt: 1,
    willContinue: true,
    error: {
      message: 'secret prompt and /private/path',
      additionalDetails: 'raw response body',
      codexErrorInfo: { responseStreamDisconnected: { httpStatusCode: 503 } },
    },
  })
  assert.deepEqual(retry, {
    type: 'harness_observation',
    id: 'turn-1',
    lane: 'codex',
    event: 'retry',
    provenance: 'provider_report',
    scope: 'request',
    aggregation: 'delta',
    retryDisposition: 'scheduled',
    retryAttempt: 1,
    willContinue: true,
    errorKind: 'connection',
    httpStatusCode: 503,
  })
  assert.doesNotMatch(JSON.stringify(retry), /secret|private|raw response/i)

  const history = Array.from({ length: 40 }, (_, index) => ({
    retryAttempt: index + 1,
    willContinue: true,
    errorKind: index === 0 ? 'serverOverloaded' : 'other',
  }))
  const recovered = codexRetryRecoveredObservation({
    id: 'turn-1', retryAttempts: 40, retryHistoryCount: 40, retryHistory: history,
  })
  assert.equal(recovered.retryHistory.length, HARNESS_RETRY_HISTORY_MAX_ENTRIES)
  assert.equal(recovered.retryHistoryCount, 40)
  assert.equal(recovered.retryDisposition, 'recovered')
  assert.equal(recovered.retryHistory[0].errorKind, 'overloaded')

  const terminal = codexRetryObservation({
    id: 'turn-1', retryAttempt: 2, willContinue: false,
    hadPriorRetry: true,
    error: { codexErrorInfo: 'PRIVATE_SECRET_TOKEN' },
  })
  assert.equal(terminal.event, 'retry_exhausted')
  assert.equal(terminal.retryDisposition, 'exhausted')
  assert.equal(terminal.errorKind, 'other')
  assert.doesNotMatch(JSON.stringify(terminal), /PRIVATE_SECRET_TOKEN/)

  const noRetry = codexRetryObservation({
    id: 'turn-2', retryAttempt: 1, willContinue: false,
    error: { codexErrorInfo: { httpConnectionFailed: { httpStatusCode: 503 } } },
  })
  assert.deepEqual(noRetry, {
    type: 'harness_observation',
    id: 'turn-2',
    lane: 'codex',
    event: 'internal_error',
    provenance: 'provider_report',
    scope: 'request',
    aggregation: 'delta',
    errorKind: 'connection',
    httpStatusCode: 503,
  })
})

test('Codex completed tool observations expose exact duration and coarse outcome only', () => {
  assert.deepEqual(codexToolObservation({
    id: 'turn-1',
    durationMs: 999,
    item: {
      id: 'call-1',
      type: 'commandExecution',
      command: 'cat ~/.ssh/id_ed25519',
      cwd: '/private/project',
      aggregatedOutput: 'secret output',
      status: 'completed',
      exitCode: 0,
      durationMs: 812,
    },
  }), {
    type: 'harness_observation',
    id: 'turn-1',
    lane: 'codex',
    event: 'tool',
    provenance: 'provider_report',
    scope: 'event',
    aggregation: 'final',
    toolUseID: 'call-1',
    toolKind: 'command',
    toolOutcome: 'success',
    toolDurationMs: 812,
  })
  assert.equal(codexToolObservation({
    id: 'turn-1',
    item: { id: 'call-2', type: 'mcpToolCall', status: 'failed', durationMs: 10 },
  }).toolOutcome, 'error')
  assert.equal(codexToolObservation({
    id: 'turn-1',
    item: { id: 'call-3', type: 'commandExecution', status: 'declined' },
  }).toolOutcome, 'declined')
  assert.deepEqual(codexToolObservation({
    id: 'turn-1',
    durationMs: 25,
    item: { id: 'call-4', type: 'webSearch', query: 'discarded' },
  }), {
    type: 'harness_observation',
    id: 'turn-1',
    lane: 'codex',
    event: 'tool',
    provenance: 'provider_report',
    scope: 'event',
    aggregation: 'final',
    toolUseID: 'call-4',
    toolKind: 'web',
    toolOutcome: 'success',
    toolDurationMs: 25,
  })
})

test('Codex model observations bound safety arrays and omit free-form values', () => {
  assert.deepEqual(codexModelObservation({
    id: 'turn-1',
    method: 'model/rerouted',
    params: {
      fromModel: 'gpt-original',
      toModel: 'gpt-safe',
      reason: 'highRiskCyberActivity',
      explanation: 'provider-authored prose must not cross',
    },
  }), {
    type: 'harness_observation',
    id: 'turn-1',
    lane: 'codex',
    event: 'model_rerouted',
    provenance: 'provider_report',
    scope: 'turn',
    aggregation: 'point',
    originalModelID: 'gpt-original',
    model: 'gpt-safe',
    rerouteReason: 'safety',
  })
  const privateReroute = codexModelObservation({
    id: 'turn-1', method: 'model/rerouted',
    params: { fromModel: 'gpt-original', toModel: 'gpt-safe', reason: 'PRIVATE_SECRET_TOKEN' },
  })
  assert.equal(privateReroute.rerouteReason, 'other')
  assert.doesNotMatch(JSON.stringify(privateReroute), /PRIVATE_SECRET_TOKEN/)

  const safety = codexModelObservation({
    id: 'turn-1',
    method: 'model/safetyBuffering/updated',
    params: {
      model: 'gpt-safe',
      fasterModel: 'gpt-fast',
      showBufferingUi: true,
      reasons: ['cyber', 'not a safe token with spaces', ...Array(12).fill('duplicate')],
      useCases: ['analysis', 'PRIVATE_SECRET_TOKEN'],
    },
  })
  assert.equal(safety.safetyOutcome, 'buffered')
  assert.deepEqual(safety.safetyReasons, ['safety', 'other'])
  assert.equal(safety.safetyReasonCount, 14)
  assert.deepEqual(safety.safetyUseCases, ['research', 'other'])
  assert.doesNotMatch(JSON.stringify(safety), /PRIVATE_SECRET_TOKEN/)

  const verification = codexModelObservation({
    id: 'turn-1',
    method: 'model/verification',
    params: { verifications: ['trustedAccount', 'PRIVATE_SECRET_TOKEN'] },
  })
  assert.deepEqual(verification.modelVerifications, ['trusted_access', 'other'])
  assert.doesNotMatch(JSON.stringify(verification), /PRIVATE_SECRET_TOKEN/)
})

test('Claude result observations preserve timing boundaries and cache components', () => {
  assert.deepEqual(claudeResultObservation({
    id: 'turn-claude',
    providerQuerySequence: 2,
    message: {
      type: 'result',
      duration_ms: 10_000,
      duration_api_ms: 8_000,
      ttft_ms: 700,
      ttft_stream_ms: 850,
      time_to_request_ms: 200,
      time_to_request_from_spawn_ms: 500,
      warm_spare_claimed: true,
      result: 'content is ignored',
      usage: {
        input_tokens: 100,
        cache_creation_input_tokens: 20,
        cache_read_input_tokens: 300,
        output_tokens: 40,
      },
    },
  }), {
    type: 'harness_observation',
    id: 'turn-claude',
    lane: 'claude',
    event: 'result',
    provenance: 'provider_report',
    scope: 'request',
    aggregation: 'final',
    providerQuerySequence: 2,
    durationMs: 10_000,
    apiDurationMs: 8_000,
    timeToFirstTokenMs: 700,
    streamTimeToFirstOutputMs: 850,
    timeToRequestMs: 200,
    timeToRequestFromSpawnMs: 500,
    warm: true,
    uncachedInputTokens: 100,
    cacheWriteInputTokens: 20,
    cacheReadInputTokens: 300,
    outputTokens: 40,
    inputTokens: 420,
  })
})

test('Claude result prefers whole agent-tree model usage without exposing model-map keys', () => {
  const observation = claudeResultObservation({
    id: 'turn-claude',
    message: {
      type: 'result',
      usage: {
        input_tokens: 1,
        cache_creation_input_tokens: 2,
        cache_read_input_tokens: 3,
        output_tokens: 4,
      },
      modelUsage: {
        'private-route-key': {
          inputTokens: 100,
          cacheCreationInputTokens: 20,
          cacheReadInputTokens: 300,
          outputTokens: 40,
          costUSD: 12.34,
        },
        'private-child-model': {
          inputTokens: 50,
          cacheCreationInputTokens: 10,
          cacheReadInputTokens: 200,
          outputTokens: 30,
        },
      },
    },
  })
  assert.equal(observation.scope, 'agent_tree')
  assert.equal(observation.uncachedInputTokens, 150)
  assert.equal(observation.cacheWriteInputTokens, 30)
  assert.equal(observation.cacheReadInputTokens, 500)
  assert.equal(observation.outputTokens, 70)
  assert.equal(observation.inputTokens, 680)
  assert.doesNotMatch(JSON.stringify(observation), /private|route|model|12\.34/)
})

test('Claude result ignores zeroed crash model usage and never promotes an all-zero final', () => {
  const fallback = claudeResultObservation({
    id: 'turn-claude',
    message: {
      type: 'result',
      duration_ms: 12,
      modelUsage: {
        '<synthetic>': {
          inputTokens: 0,
          cacheCreationInputTokens: 0,
          cacheReadInputTokens: 0,
          outputTokens: 0,
        },
      },
      usage: {
        input_tokens: 5,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        output_tokens: 1,
      },
    },
  })
  assert.equal(fallback.scope, 'request')
  assert.equal(fallback.inputTokens, 5)
  assert.equal(fallback.cacheWriteInputTokens, 0)
  assert.equal(fallback.outputTokens, 1)

  const zero = claudeResultObservation({
    id: 'turn-claude',
    message: {
      type: 'result',
      duration_ms: 12,
      modelUsage: { '<synthetic>': {
        inputTokens: 0, cacheCreationInputTokens: 0, cacheReadInputTokens: 0, outputTokens: 0,
      } },
      usage: {
        input_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        output_tokens: 0,
      },
    },
  })
  assert.deepEqual(zero, {
    type: 'harness_observation',
    id: 'turn-claude',
    lane: 'claude',
    event: 'result',
    provenance: 'provider_report',
    scope: 'request',
    aggregation: 'final',
    durationMs: 12,
  })
})

test('Claude context composition never exposes provider labels or file/tool names', () => {
  const observation = claudeContextObservation({
    id: 'turn-claude',
    raw: {
      totalTokens: 80_000,
      maxTokens: 180_000,
      rawMaxTokens: 200_000,
      model: 'claude-fixture',
      categories: [
        { name: 'System prompt /private/secret.md', tokens: 5_000 },
        { name: 'MCP tools (deferred)', tokens: 3_000, isDeferred: true },
        { name: 'Messages', tokens: 70_000 },
      ],
      memoryFiles: [{ path: '/Users/person/private.md', tokens: 1_000 }],
      mcpTools: [{ name: 'mcp__secret__tool', serverName: 'secret', tokens: 3_000 }],
    },
  })
  assert.deepEqual(observation.contextComposition, {
    system_prompt: 5_000,
    deferred_tools: 3_000,
    messages: 70_000,
    compaction_buffer: 20_000,
    free: 100_000,
  })
  assert.equal(observation.contextTokens, 80_000)
  assert.equal(observation.contextUsableWindow, 180_000)
  assert.equal(observation.contextRawWindowTokens, 200_000)
  assert.doesNotMatch(JSON.stringify(observation), /private|secret|claude-fixture/)
})

test('Codex rate-limit state merges sparse updates and strips ids, labels, balances and spend strings', () => {
  let state = updateCodexRateLimitState(null, {
    rateLimits: {
      limitId: 'codex-private-bucket',
      limitName: 'Workspace Secret Name',
      planType: 'plus',
      primary: { usedPercent: 25, windowDurationMins: 300, resetsAt: 1_800_000_000 },
      secondary: { usedPercent: 10, windowDurationMins: 10_080, resetsAt: 1_800_500_000 },
      credits: { hasCredits: true, unlimited: false, balance: '123.45 private credits' },
      individualLimit: {
        remainingPercent: 80, resetsAt: 1_800_500_000, used: '$20', limit: '$100',
      },
    },
    rateLimitResetCredits: {
      availableCount: 2,
      credits: [{ id: 'opaque', title: 'private', description: 'private' }],
    },
  }, { replace: true })
  state = updateCodexRateLimitState(state, {
    rateLimits: {
      limitId: 'codex-private-bucket',
      primary: { usedPercent: 40 },
      rateLimitReachedType: 'PRIVATE_SECRET_TOKEN',
    },
  })
  const observation = codexRateLimitsObservation(state, { source: 'notification' })
  assert.deepEqual(observation.buckets, [{
    primary: { usedPercent: 40, windowDurationMins: 300, resetsAt: 1_800_000_000 },
    secondary: { usedPercent: 10, windowDurationMins: 10_080, resetsAt: 1_800_500_000 },
    credits: { hasCredits: true, unlimited: false },
    individualLimit: { remainingPercent: 80, resetsAt: 1_800_500_000 },
    rateLimitReached: true,
  }])
  assert.equal(observation.resetCreditsAvailable, 2)
  assert.equal(observation.complete, true)
  assert.equal(observation.buckets[0].planType, undefined)
  assert.doesNotMatch(
    JSON.stringify(observation),
    /codex-private-bucket|Workspace Secret|123\.45|\$20|\$100|opaque|private/i,
  )

  const many = Object.fromEntries(Array.from(
    { length: 30 },
    (_, index) => [`bucket-${index}`, { primary: { usedPercent: index } }],
  ))
  state = updateCodexRateLimitState(null, {
    rateLimits: { primary: { usedPercent: 0 } },
    rateLimitsByLimitId: many,
  }, { replace: true })
  const bounded = codexRateLimitsObservation(state)
  assert.equal(bounded.bucketCount, 30)
  assert.equal(bounded.buckets.length, HARNESS_RATE_LIMIT_MAX_BUCKETS)

})

test('complete empty Codex rate-limit reads publish a clearing snapshot', () => {
  const state = updateCodexRateLimitState(
    null,
    { rateLimitsByLimitId: {} },
    { replace: true },
  )
  const cleared = codexRateLimitsObservation(state)
  assert.equal(cleared.complete, true)
  assert.equal(cleared.bucketCount, 0)
  assert.deepEqual(cleared.buckets, [])
})

test('Codex account token usage is provider-level, bounded and omits thread cost data', () => {
  const dailyUsageBuckets = Array.from({
    length: HARNESS_ACCOUNT_DAILY_MAX_BUCKETS + 10,
  }, (_, index) => ({ startDate: `2026-01-${String((index % 28) + 1).padStart(2, '0')}`, tokens: index }))
  const observation = codexAccountTokenUsageObservation({
    summary: {
      lifetimeTokens: 1_000_000,
      peakDailyTokens: 100_000,
      longestRunningTurnSec: 600,
      currentStreakDays: 3,
      longestStreakDays: 9,
    },
    dailyUsageBuckets,
    threadUsage: {
      threadId: 'opaque-thread',
      estimatedUsageCreditsMicros: 123,
      estimatedUsageUsdMicros: 456,
      groups: [{ model: 'secret-route' }],
    },
  })
  assert.equal(observation.type, 'harness_account_usage')
  assert.equal(observation.complete, true)
  assert.equal(observation.dailyBucketCount, HARNESS_ACCOUNT_DAILY_MAX_BUCKETS + 10)
  assert.equal(observation.dailyUsage.length, HARNESS_ACCOUNT_DAILY_MAX_BUCKETS)
  assert.doesNotMatch(JSON.stringify(observation), /opaque-thread|estimated|secret-route/)

  const cleared = codexAccountTokenUsageObservation({})
  assert.equal(cleared.complete, true)
  assert.equal(cleared.dailyBucketCount, 0)
  assert.deepEqual(cleared.summary, {})
  assert.deepEqual(cleared.dailyUsage, [])
})
