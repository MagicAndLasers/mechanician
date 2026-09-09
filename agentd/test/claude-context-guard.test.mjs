import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  ClaudeInputTooLargeError,
  buildBoundedClaudeReplay,
  claudeAssistantContextSample,
  claudeCachedContextDecision,
  claudeCompactionFailure,
  claudeContextDecision,
  claudePreflightMissReason,
  claudeServingModelMatchesContext,
  createClaudeContextUsageCache,
  estimateClaudeTokens,
  isStableClaudeContextModel,
  normalizeClaudeContextUsage,
  resolveClaudeContextModel,
} from '../src/claude-context-guard.mjs'
import { normalizeAnthropicError } from '../src/provider-errors.mjs'

test('Claude prompt projection uses the conservative UTF-8 byte estimate and completion reserve', () => {
  assert.equal(estimateClaudeTokens('abcdef'), 2)
  assert.equal(estimateClaudeTokens('😀'), 2, 'four UTF-8 bytes conservatively estimate two tokens')

  const decision = claudeContextDecision({
    totalTokens: 170_000,
    maxTokens: 200_000,
    rawMaxTokens: 200_000,
    autoCompactThreshold: 160_000,
    isAutoCompactEnabled: true,
    model: 'claude-sonnet-fixture',
  }, 'x'.repeat(9_000))

  assert.equal(decision.incomingTokens, 3_000)
  assert.equal(decision.completionReserve, 24_000)
  assert.equal(decision.projectedTokens, 197_000)
  assert.equal(decision.action, 'expect_compaction')
})

test('a resumed overfull context recovers fresh when auto-compaction cannot run', () => {
  const decision = claudeContextDecision({
    totalTokens: 178_000,
    maxTokens: 200_000,
    autoCompactThreshold: 160_000,
    isAutoCompactEnabled: false,
  }, 'small follow-up')

  assert.equal(decision.shouldCompact, true)
  assert.equal(decision.autoCompactionExpected, false)
  assert.equal(decision.action, 'recover_fresh')
})

test('malformed SDK context usage is ignored rather than inventing a denominator', () => {
  assert.equal(normalizeClaudeContextUsage(null), null)
  assert.equal(normalizeClaudeContextUsage({ totalTokens: 10 }), null)
  assert.equal(normalizeClaudeContextUsage({ totalTokens: -1, maxTokens: 200_000 }), null)
  assert.equal(
    normalizeClaudeContextUsage({
      totalTokens: 10,
      maxTokens: 200_000,
      autoCompactThreshold: 999_999,
      isAutoCompactEnabled: true,
    }).autoCompactThreshold,
    null,
  )
})

test('a completed root assistant request supplies the next-turn context lower bound', () => {
  assert.deepEqual(claudeAssistantContextSample({
    input_tokens: 100,
    cache_creation_input_tokens: 20,
    cache_read_input_tokens: 30,
    output_tokens: 10,
  }, 'claude-fixture'), {
    totalTokens: 160,
    model: 'claude-fixture',
  })
})

test('server-side usage uses only its final serving iteration, never cumulative billing totals', () => {
  const usage = {
    input_tokens: 190_000,
    cache_creation_input_tokens: 10_000,
    cache_read_input_tokens: 20_000,
    output_tokens: 4_000,
    iterations: [
      {
        type: 'message', model: 'claude-declined', input_tokens: 90_000,
        cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 100,
      },
      {
        type: 'fallback_message', model: 'claude-serving', input_tokens: 2_000,
        cache_creation_input_tokens: 300, cache_read_input_tokens: 40_000, output_tokens: 500,
      },
    ],
  }

  assert.deepEqual(claudeAssistantContextSample(usage, 'claude-top-level'), {
    totalTokens: 42_800,
    model: 'claude-serving',
  })
  assert.equal(claudeAssistantContextSample({
    ...usage,
    iterations: [...usage.iterations, {
      type: 'compaction', input_tokens: 10, cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0, output_tokens: 10,
    }],
  }, 'claude-top-level'), null, 'an ambiguous trailing iteration fails closed')
})

test('cached context skips control only with a large uncertainty margin', () => {
  const safe = claudeCachedContextDecision({
    totalTokens: 60_000,
    maxTokens: 200_000,
    model: 'claude-fixture',
    autoCompactThreshold: 160_000,
    isAutoCompactEnabled: true,
  }, 'small follow-up')
  assert.equal(safe.eligible, true)
  assert.equal(safe.usage.totalTokens, 60_000, 'uncertainty never mutates the measured sample')
  assert.equal(safe.uncertaintyTokens, 48_000)
  assert.equal(safe.guardedTokens, 108_000)

  const near = claudeCachedContextDecision({
    totalTokens: 110_000,
    maxTokens: 200_000,
    model: 'claude-fixture',
    autoCompactThreshold: 160_000,
    isAutoCompactEnabled: true,
  }, 'small follow-up')
  assert.equal(near.eligible, false)
  assert.equal(near.reason, 'near_limit')

  const largePrompt = claudeCachedContextDecision({
    totalTokens: 10_000,
    maxTokens: 200_000,
    model: 'claude-fixture',
  }, 'x'.repeat(48_003))
  assert.equal(largePrompt.eligible, false)
  assert.equal(largePrompt.reason, 'large_prompt')
})

test('the context cache is exact-identity, expiring, bounded, and single-use', () => {
  let clock = 1_000
  const cache = createClaudeContextUsageCache({
    maximumEntries: 2,
    maxAgeMs: 5_000,
    now: () => clock,
  })
  const usage = { totalTokens: 1_000, maxTokens: 200_000, model: 'claude-fixture' }

  assert.equal(cache.store('session-a', 'config-a', usage), true)
  assert.deepEqual(cache.claim('session-a', 'config-b'), {
    reason: 'identity_mismatch', usage: null,
  })
  assert.deepEqual(cache.claim('session-a', 'config-a'), {
    reason: 'absent', usage: null,
  }, 'identity mismatch consumes the sample')

  cache.store('session-a', 'config-a', usage)
  assert.deepEqual(cache.take('session-a', 'config-a'), {
    totalTokens: 1_000,
    maxTokens: 200_000,
    rawMaxTokens: 200_000,
    model: 'claude-fixture',
    autoCompactThreshold: null,
    isAutoCompactEnabled: false,
  })
  assert.equal(cache.take('session-a', 'config-a'), null)

  cache.store('expired', 'config-a', usage)
  clock += 5_001
  assert.equal(cache.claim('expired', 'config-a').reason, 'expired')

  cache.store('clock-rollback', 'config-a', usage)
  clock -= 1
  assert.equal(cache.claim('clock-rollback', 'config-a').reason, 'clock_rollback')
  clock += 1

  cache.store('oldest', 'config-a', usage)
  cache.store('middle', 'config-a', usage)
  cache.store('newest', 'config-a', usage)
  assert.equal(cache.size, 2)
  assert.equal(cache.take('oldest', 'config-a'), null)
  assert.ok(cache.take('middle', 'config-a'))
  assert.ok(cache.take('newest', 'config-a'))
})

test('only explicit versioned Claude IDs may reuse a cached context window', () => {
  assert.equal(isStableClaudeContextModel('claude-opus-4-8'), true)
  assert.equal(isStableClaudeContextModel('claude-opus-4-8[1m]'), true)
  assert.equal(isStableClaudeContextModel('anthropic.claude-3-5-sonnet-20241022-v2:0'), true)
  assert.equal(isStableClaudeContextModel('us.anthropic.claude-3-7-sonnet-20250219-v1:0'), true)
  assert.equal(isStableClaudeContextModel('opus'), false)
  assert.equal(isStableClaudeContextModel('default'), false)
  assert.equal(isStableClaudeContextModel('claude-sonnet-latest'), false)
  assert.equal(isStableClaudeContextModel('custom-model-5'), false)
})

test('the current SDK catalog can safely resolve an alias without erasing its context variant', () => {
  const catalog = [
    { value: 'opus[1m]', resolvedModel: 'claude-opus-5[1m]' },
    { value: 'default', resolvedModel: 'claude-opus-5[1m]' },
  ]
  assert.equal(
    resolveClaudeContextModel('opus[1m]', catalog),
    'claude-opus-5[1m]',
  )
  assert.equal(
    resolveClaudeContextModel('claude-fable-5[1m]', [
      { value: 'claude-fable-5[1m]', resolvedModel: 'claude-fable-5' },
    ]),
    'claude-fable-5',
  )
  assert.equal(
    resolveClaudeContextModel('claude-opus-5[1m]', []),
    '',
    'a stable-looking value cannot self-authorize when the initialized catalog omits it',
  )
  assert.equal(resolveClaudeContextModel('claude-opus-5[1m]', [
    { value: 'sonnet', resolvedModel: 'claude-sonnet-5' },
  ]), '', 'an unrelated initialized catalog is not evidence for the selected value')
  assert.equal(resolveClaudeContextModel('unknown', catalog), '')
  assert.equal(resolveClaudeContextModel('default', [
    { value: 'default', resolvedModel: 'claude-opus-5[1m]' },
    { value: 'default', resolvedModel: 'claude-sonnet-5[1m]' },
  ]), '', 'conflicting duplicate rows are not authority')
  assert.equal(resolveClaudeContextModel('default', [
    { value: 'default', resolvedModel: 'claude-opus-5[1m]' },
    { value: 'default' },
  ]), '', 'a malformed duplicate cannot be discarded')
  assert.equal(resolveClaudeContextModel('default', [
    { value: 'default', resolvedModel: 'claude-opus-5[1m]' },
    { value: 'default', resolvedModel: 'claude-opus-5[1m]' },
  ]), '', 'identical duplicate rows are not unique authority')
  assert.equal(resolveClaudeContextModel('claude-opus-5', [
    { value: 'claude-opus-5', resolvedModel: `${'x'.repeat(257)}` },
  ]), '', 'overlong exact identities are rejected rather than truncated')
})

test('serving model identity strips only the SDK context-window suffix', () => {
  assert.equal(
    claudeServingModelMatchesContext('claude-opus-5[1m]', 'claude-opus-5'),
    true,
  )
  assert.equal(
    claudeServingModelMatchesContext('claude-opus-5[other]', 'claude-opus-5'),
    false,
  )
  assert.equal(
    claudeServingModelMatchesContext('claude-opus-5[1m]', 'claude-sonnet-5'),
    false,
  )
})

test('the SDK compact failure terminal is recognized without matching provider prose', () => {
  assert.deepEqual(claudeCompactionFailure({
    type: 'system',
    subtype: 'status',
    status: null,
    compact_result: 'failed',
    compact_error: 'too_few_groups',
  }), {
    code: 'too_few_groups',
    message: 'too_few_groups',
  })
  assert.equal(claudeCompactionFailure({
    type: 'system', subtype: 'status', compact_result: 'success',
  }), null)
  assert.equal(claudeCompactionFailure({
    type: 'system', subtype: 'compact_boundary',
  }), null)
})

test('bounded replay is deterministic, explicit, and keeps the newest messages', () => {
  const history = Array.from({ length: 8 }, (_, index) => ({
    role: index % 2 ? 'assistant' : 'user',
    text: `message-${index} ` + String(index).repeat(600),
  }))
  const options = {
    maximumInputTokens: 900,
    maximumHistoryTokens: 500,
    maximumMessageTokens: 180,
  }
  const first = buildBoundedClaudeReplay(history, 'current prompt exactly', options)
  const second = buildBoundedClaudeReplay(history, 'current prompt exactly', options)

  assert.equal(first.ok, true)
  assert.deepEqual(first, second)
  assert.match(first.text, /Mechanician omitted \d+ older messages?/)
  assert.match(first.text, /Assistant: .*777/)
  assert.doesNotMatch(first.text, /message-0/)
  assert.ok(first.text.endsWith('current prompt exactly'))
  assert.ok(first.estimatedTokens <= options.maximumInputTokens)
})

test('one huge history entry is excerpted head-and-tail while the current prompt stays exact', () => {
  const huge = `BEGIN-${'a'.repeat(20_000)}-END`
  const current = `current-${'z'.repeat(2_000)}-exact-end`
  const replay = buildBoundedClaudeReplay(
    [{ role: 'user', text: huge }],
    current,
    {
      maximumInputTokens: 2_000,
      maximumHistoryTokens: 900,
      maximumMessageTokens: 900,
    },
  )

  assert.equal(replay.ok, true)
  assert.equal(replay.truncatedMessages, 1)
  assert.match(replay.text, /BEGIN-/)
  assert.match(replay.text, /-END/)
  assert.match(replay.text, /middle of this older turn omitted/)
  assert.ok(replay.text.endsWith(current), 'the current prompt must be byte-for-byte at the end')
})

test('the replay boundary keeps a user/assistant turn together instead of orphaning an answer', () => {
  const replay = buildBoundedClaudeReplay(
    [
      { role: 'user', text: `PAIR-QUESTION-${'q'.repeat(2_000)}` },
      { role: 'assistant', text: `MIDDLE-ANSWER-${'m'.repeat(500)}-MIDDLE-END` },
      { role: 'assistant', text: `FINAL-ANSWER-${'a'.repeat(500)}-ANSWER-END` },
    ],
    'current prompt',
    {
      maximumInputTokens: 1_000,
      maximumHistoryTokens: 120,
      maximumMessageTokens: 120,
    },
  )

  assert.equal(replay.ok, true)
  assert.equal(replay.truncatedMessages, 3)
  assert.match(replay.text, /User: PAIR-QUESTION-/)
  assert.match(replay.text, /Assistant: .*ANSWER-END/)
  assert.match(replay.text, /middle of this older turn omitted/)
  assert.ok(replay.text.endsWith('current prompt'))
})

test('a current prompt over the preflight budget is rejected, never silently truncated', () => {
  const current = `exact-start-${'q'.repeat(12_000)}-exact-end`
  const replay = buildBoundedClaudeReplay(
    [{ role: 'assistant', text: 'older context' }],
    current,
    { maximumInputTokens: 1_000 },
  )

  assert.equal(replay.ok, false)
  assert.equal('text' in replay, false)
  assert.ok(replay.currentPromptTokens > replay.maximumInputTokens)
})

test('recovery drops all old history before blaming a current prompt that still fits', () => {
  const current = 'keep this prompt exact'
  const replay = buildBoundedClaudeReplay(
    [{ role: 'assistant', text: 'old context' }],
    current,
    { maximumInputTokens: 30 },
  )

  assert.equal(replay.ok, true)
  assert.equal(replay.omittedMessages, 1)
  assert.ok(replay.text.endsWith(current))
  assert.doesNotMatch(replay.text, /old context/)
})

test('input preflight failures expose the stable Edit Prompt discriminator', () => {
  const failure = new ClaudeInputTooLargeError({
    estimatedTokens: 210_000,
    maximumInputTokens: 150_000,
  })
  const normalized = normalizeAnthropicError({
    type: failure.type,
    subtype: failure.subtype,
    error: failure.error,
    error_details: failure.error_details,
    terminal_reason: failure.terminal_reason,
  }, { access: 'claude_vertex' })

  assert.equal(normalized.errorKind, 'context_limit')
  assert.equal(normalized.providerError.providerType, 'input_too_large')
  assert.equal(normalized.providerError.code, 'prompt_preflight_limit')
  assert.equal(normalized.providerError.terminalReason, 'prompt_too_long')
  assert.equal(normalized.reconnectRequired, undefined)
})

/// A compaction failure whose text is not a bare identifier is reported as the generic
/// `compaction_failed`. 0.26.2 treated anything that was not `too_few_groups` as safe to continue
/// through, so "unknown failure" reached the provider and came back `prompt_too_long` on the second
/// turn of a fresh conversation. Unknown must mean stop, not continue.
test('an unrecognized compaction failure is reported generically, so it must not read as benign', () => {
  const generic = claudeCompactionFailure({
    type: 'system',
    subtype: 'status',
    status: null,
    compact_result: 'failed',
    compact_error: 'Compaction failed: the model returned an unexpected response (429).',
  })
  assert.equal(generic.code, 'compaction_failed',
    'prose collapses to the generic code, which is exactly why it cannot be an implicit allow')
  assert.match(generic.message, /unexpected response/)

  // A failure with no error text at all still reports the generic code rather than nothing.
  assert.equal(claudeCompactionFailure({
    type: 'system', subtype: 'status', compact_result: 'failed',
  }).code, 'compaction_failed')
})

// FR-216. The lever on the largest latency item is widening `cachedUsageMaximumPromptTokens`, and
// that number cannot be chosen from the policy constants: it depends on which miss dominates real
// use. These pin the vocabulary that measurement is counted by, so a later reading of the logs is
// comparing stable categories rather than whatever the code happened to say that week.
test('Claude preflight miss reasons distinguish every cause of a blocking round trip', () => {
  // The fast path worked; there is nothing to report.
  assert.equal(
    claudePreflightMissReason({
      supportsContextUsage: true, resumeId: 'session', cached: { eligible: true, reason: 'safe' },
    }),
    null,
  )

  // The two the threshold work would actually act on, kept distinguishable on purpose: one says the
  // prompt was too big for the cached projection, the other says the session was too full for it.
  assert.equal(
    claudePreflightMissReason({
      supportsContextUsage: true, resumeId: 'session',
      cached: { eligible: false, reason: 'large_prompt' },
    }),
    'large_prompt',
  )
  assert.equal(
    claudePreflightMissReason({
      supportsContextUsage: true, resumeId: 'session',
      cached: { eligible: false, reason: 'near_limit' },
    }),
    'near_limit',
  )

  // No decision to report. Separated because only the first is a cache that could be improved: a
  // fresh session has no prior sample by definition, so counting them together would overstate how
  // much a better cache could win.
  assert.equal(
    claudePreflightMissReason({ supportsContextUsage: true, resumeId: 'session', cached: null }),
    'no_cached_usage',
  )
  assert.equal(
    claudePreflightMissReason({ supportsContextUsage: true, resumeId: null, cached: null }),
    'fresh_session',
  )

  // No round trip happens at all on these, so they must not be counted as cache misses: Vertex is
  // bypassed deliberately (the route does not answer the control), and an older SDK has no method.
  assert.equal(
    claudePreflightMissReason({ supportsContextUsage: false, authMode: 'vertex' }),
    'vertex_bypass',
  )
  assert.equal(
    claudePreflightMissReason({ supportsContextUsage: false, authMode: 'apikey' }),
    'no_control',
  )

  // Called with nothing, it must not claim a cache miss.
  assert.equal(claudePreflightMissReason(), 'no_control')
})

test('Claude preflight miss reason reports the cached decision ahead of the session shape', () => {
  // A resumed session with a rejected sample reports WHY it was rejected, not `no_cached_usage`.
  // Collapsing those would hide exactly the signal the threshold decision needs.
  for (const reason of ['invalid_usage', 'invalid_projection', 'large_prompt', 'near_limit']) {
    assert.equal(
      claudePreflightMissReason({
        supportsContextUsage: true, resumeId: 'session', cached: { eligible: false, reason },
      }),
      reason,
    )
  }
})
