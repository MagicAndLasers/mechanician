import test from 'node:test'
import assert from 'node:assert/strict'

import {
  claudeSubscriptionCredentialProbe,
  createCredentialTrustWindow,
  createProviderResponseWatchdog,
  isClaudeSyntheticNoOutputAssistant,
  isClaudeSyntheticNoOutputResult,
  isProviderResponseActivity,
  normalizeCredentialPreflight,
  providerNoOutputFailure,
  providerStartTimeoutFailure,
  runCredentialPreflight,
  PROVIDER_TIMEOUT_PHASES,
} from '../src/provider-preflight.mjs'

const vertex = {
  provider: 'anthropic',
  access: 'claude_vertex',
  providerLabel: 'Google Vertex',
  identityLabel: 'Google',
}

const claude = {
  provider: 'anthropic',
  access: 'claude_subscription',
  providerLabel: 'Claude',
  identityLabel: 'Claude',
}

/** A deterministic clock so watchdog deadlines are asserted in simulated minutes, not real ones. */
function fakeClock() {
  let now = 0
  let nextId = 1
  const timers = new Map()
  return {
    schedule(callback, ms) {
      const id = nextId++
      timers.set(id, { at: now + ms, callback })
      return id
    },
    cancel(id) { timers.delete(id) },
    advance(ms) {
      const target = now + ms
      for (;;) {
        let due = null
        for (const [id, timer] of timers) {
          if (timer.at <= target && (due === null || timer.at < due.timer.at)) due = { id, timer }
        }
        if (due === null) break
        timers.delete(due.id)
        now = due.timer.at
        due.timer.callback()
      }
      now = target
    },
  }
}

function watchdogOnFakeClock(clock, overrides = {}) {
  const phases = []
  const watchdog = createProviderResponseWatchdog({
    timeoutMs: 180_000,
    compactionTimeoutMs: 900_000,
    onTimeout: (phase) => phases.push(phase),
    schedule: (callback, ms) => clock.schedule(callback, ms),
    cancel: (id) => clock.cancel(id),
    ...overrides,
  })
  return { watchdog, phases }
}

const COMPACTING = { type: 'system', subtype: 'status', status: 'compacting' }

test('credential preflight separates definitive sign-out from transient network failure', () => {
  const reauth = normalizeCredentialPreflight({
    ok: false, reason: 'reauth_required', httpStatus: 400, errorSubtype: 'invalid_rapt',
  }, vertex)
  const network = normalizeCredentialPreflight({ ok: false, reason: 'network' }, vertex)

  assert.equal(reauth.verification, 'disconnected')
  assert.equal(reauth.failure.errorKind, 'authentication')
  assert.equal(reauth.failure.reconnectRequired, true)
  assert.equal(reauth.failure.providerError.status, 400)
  assert.equal(reauth.failure.providerError.code, 'invalid_rapt')
  assert.match(reauth.failure.message, /organization requires you to sign in to Google again/)
  assert.match(reauth.failure.message, /Reauthenticate with Google/)

  assert.equal(network.verification, 'deferred')
  assert.equal(network.failure.errorKind, 'network')
  assert.equal(Object.hasOwn(network.failure, 'reconnectRequired'), false)
})

test('unknown and authorization-shaped preflight failures never fabricate reauthentication', () => {
  const forbidden = normalizeCredentialPreflight({
    ok: false, reason: 'unknown', httpStatus: 403,
  }, vertex)

  assert.equal(forbidden.failure.errorKind, 'unknown')
  assert.equal(forbidden.failure.providerError.status, 403)
  assert.equal(Object.hasOwn(forbidden.failure, 'reconnectRequired'), false)
})

test('credential verifier exceptions become bounded unknown failures', async () => {
  const result = await runCredentialPreflight(async () => {
    throw new Error('unexpected private verifier detail')
  }, vertex)

  assert.equal(result.ok, false)
  assert.equal(result.verification, 'deferred')
  assert.equal(result.failure.errorKind, 'unknown')
  assert.doesNotMatch(JSON.stringify(result), /private verifier detail/)
})

test('a Claude subscription probe separates a dead sign-in from a probe that could not run', () => {
  assert.deepEqual(
    claudeSubscriptionCredentialProbe({ authenticated: true, reason: null }),
    { ok: true })

  const signedOut = claudeSubscriptionCredentialProbe({ authenticated: false, reason: 'not_logged_in' })
  assert.equal(signedOut.reason, 'revoked')
  assert.equal(normalizeCredentialPreflight(signedOut, claude).failure.reconnectRequired, true)

  // A managed third-party route is a real, definitive fault — Reconnect is the correct next step.
  for (const reason of ['provider_conflict', 'unsupported_auth_method']) {
    const conflict = claudeSubscriptionCredentialProbe({ authenticated: false, reason })
    assert.equal(conflict.reason, 'reauth_required', reason)
    assert.equal(normalizeCredentialPreflight(conflict, claude).verification, 'disconnected', reason)
  }

  // A missing binary or a timed-out probe must never sign the user out on its own.
  const unavailable = claudeSubscriptionCredentialProbe({
    authenticated: false, reason: 'status_unavailable',
  })
  assert.equal(unavailable.reason, 'unknown')
  const deferred = normalizeCredentialPreflight(unavailable, claude)
  assert.equal(deferred.verification, 'deferred')
  assert.equal(Object.hasOwn(deferred.failure, 'reconnectRequired'), false)
})

test('the credential trust window probes once, then trusts recent proof', async () => {
  let current = 100_000
  let probes = 0
  const window = createCredentialTrustWindow({ ttlMs: 10_000, now: () => current })
  const probe = () => { probes += 1; return Promise.resolve({ ok: true }) }

  assert.equal(window.willProbe, true)
  assert.deepEqual(await window.verify(probe), { ok: true })
  assert.equal(probes, 1)

  // Inside the window a turn must not spawn the engine again.
  current += 5_000
  assert.equal(window.willProbe, false)
  await window.verify(probe)
  assert.equal(probes, 1)

  // Past it, the credential is re-checked.
  current += 6_000
  assert.equal(window.willProbe, true)
  await window.verify(probe)
  assert.equal(probes, 2)
})

test('concurrent turns share one credential probe and a failure reopens the window', async () => {
  let current = 0
  let probes = 0
  let release
  const window = createCredentialTrustWindow({ ttlMs: 10_000, now: () => current })
  const slowProbe = () => {
    probes += 1
    return new Promise((resolve) => { release = resolve })
  }

  // Three turns starting at once must not race three sign-in probes against one credential store.
  const pending = [window.verify(slowProbe), window.verify(slowProbe), window.verify(slowProbe)]
  await Promise.resolve()
  assert.equal(probes, 1)
  release({ ok: true })
  assert.deepEqual(await Promise.all(pending), [{ ok: true }, { ok: true }, { ok: true }])

  // A failed probe must not be cached as proof.
  window.suspect()
  assert.equal(window.willProbe, true)
  await window.verify(() => { probes += 1; return Promise.resolve({ ok: false, reason: 'revoked' }) })
  assert.equal(probes, 2)
  assert.equal(window.willProbe, true, 'a rejected credential must never open the trust window')

  // A completed turn is accepted as proof without spawning anything.
  window.accept()
  assert.equal(window.willProbe, false)
})

test('a trust window probe that throws does not wedge every later turn', async () => {
  let current = 0
  const window = createCredentialTrustWindow({ ttlMs: 10_000, now: () => current })

  await assert.rejects(() => window.verify(() => { throw new Error('probe exploded') }))
  // The in-flight slot must be released, or the daemon would return the same rejected promise
  // to every subsequent turn for the life of the process.
  assert.deepEqual(await window.verify(() => Promise.resolve({ ok: true })), { ok: true })
  assert.equal(window.willProbe, false)
})

// Regression: 0.11.19 aborted any turn whose auto-compaction ran past the 60s first-response
// deadline. Because the abort also killed the compaction, the context never shrank and every
// retry re-entered the same doomed compaction — a conversation at ~99% of a 1M window could
// never send another message, and the failure read to the user as a subscription disconnect.
test('a long compaction is never mistaken for a provider that never answered', () => {
  const clock = fakeClock()
  const { watchdog, phases } = watchdogOnFakeClock(clock)

  watchdog.start()
  watchdog.observe(COMPACTING)
  assert.equal(watchdog.compacting, true)

  clock.advance(600_000) // ten minutes of silent, healthy compaction
  assert.deepEqual(phases, [], 'compaction must not be aborted at the first-response deadline')
  assert.equal(watchdog.waiting, true)

  // Compaction lands; the turn returns to an ordinary first-response budget.
  watchdog.observe({ type: 'system', subtype: 'compact_boundary', compact_metadata: {} })
  assert.equal(watchdog.compacting, false)
  clock.advance(120_000)
  assert.deepEqual(phases, [])

  assert.equal(watchdog.observe({
    type: 'stream_event', parent_tool_use_id: null,
    event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'answer' } },
  }), true)
  clock.advance(3_600_000)
  assert.deepEqual(phases, [], 'a responding turn is never re-armed')
})

test('a compaction that reports its own result releases the longer deadline', () => {
  const clock = fakeClock()
  const { watchdog, phases } = watchdogOnFakeClock(clock)

  watchdog.start()
  watchdog.observe(COMPACTING)
  watchdog.observe({ type: 'system', subtype: 'status', status: null, compact_result: 'success' })
  assert.equal(watchdog.compacting, false)

  clock.advance(180_001)
  assert.deepEqual(phases, ['start'], 'post-compaction silence falls back to the short budget')
})

test('a wedged compaction still fails in bounded time, and says so', () => {
  const clock = fakeClock()
  const { watchdog, phases } = watchdogOnFakeClock(clock)

  watchdog.start()
  watchdog.observe(COMPACTING)
  clock.advance(900_001)

  assert.deepEqual(phases, ['compaction'])
  assert.equal(watchdog.waiting, false)
})

test('any sign of life restarts the clock instead of counting down against a live session', () => {
  const clock = fakeClock()
  const { watchdog, phases } = watchdogOnFakeClock(clock, { wallTimeoutMs: 3_600_000 })

  watchdog.start()
  for (let minute = 0; minute < 10; minute++) {
    clock.advance(120_000)
    watchdog.observe({ type: 'system', subtype: 'hook_progress' })
  }
  assert.deepEqual(phases, [], 'twenty minutes of progress messages is not a dead provider')

  clock.advance(180_001) // now it actually goes silent
  assert.deepEqual(phases, ['start'])
})

test('provider response watchdog re-arms on initialization and stops on provider activity', () => {
  let scheduled
  let cancelled = false
  let timedOut = false
  const watchdog = createProviderResponseWatchdog({
    timeoutMs: 60_000,
    onTimeout: () => { timedOut = true },
    schedule: (callback) => {
      scheduled = () => { if (!cancelled) callback() }
      return 7
    },
    cancel: (timer) => { assert.equal(timer, 7); cancelled = true },
  })

  watchdog.start()
  assert.equal(watchdog.waiting, true)
  assert.equal(watchdog.observe({ type: 'system', subtype: 'init' }), false)
  assert.equal(watchdog.waiting, true)
  assert.equal(watchdog.observe({
    type: 'stream_event', parent_tool_use_id: null,
    event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'answer' } },
  }), true)
  assert.equal(watchdog.waiting, false)
  assert.equal(cancelled, true)
  scheduled()
  assert.equal(timedOut, false)
})

test('zero-token synthetic Claude control frames are not provider output', () => {
  const assistant = {
    type: 'assistant',
    uuid: 'synthetic-assistant-1',
    session_id: 'synthetic-session',
    parent_tool_use_id: null,
    message: {
      id: 'synthetic-message-1',
      model: '<synthetic>',
      role: 'assistant',
      content: [{ type: 'text', text: 'No response requested.' }],
      stop_reason: 'stop_sequence',
      stop_sequence: 'No response requested.',
      usage: {
        input_tokens: 0, cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0, output_tokens: 0,
      },
    },
  }
  const result = {
    type: 'result', subtype: 'success', is_error: false,
    uuid: 'synthetic-result-1', session_id: 'synthetic-session',
    result: 'No response requested.',
    num_turns: 0, stop_reason: 'stop_sequence', total_cost_usd: 0,
    duration_ms: 43, duration_api_ms: 0, permission_denials: [],
    usage: {
      input_tokens: 0, cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0, output_tokens: 0,
    },
    modelUsage: { '<synthetic>': {
      inputTokens: 0, cacheCreationInputTokens: 0,
      cacheReadInputTokens: 0, outputTokens: 0,
      webSearchRequests: 0, costUSD: 0,
      contextWindow: 200_000, maxOutputTokens: 32_000,
    } },
  }

  assert.equal(isClaudeSyntheticNoOutputAssistant(assistant), true)
  assert.equal(isClaudeSyntheticNoOutputResult(result), true)
  assert.equal(isProviderResponseActivity(assistant), false)
  assert.equal(isProviderResponseActivity(result), false)

  for (const malformed of [
    { ...assistant, message: { ...assistant.message, usage: { output_tokens: 0 } } },
    { ...assistant, message: { ...assistant.message, content: ['No response requested.'] } },
    { ...assistant, message: {
      ...assistant.message, content: [{ type: 'text', text: '(no content)' }],
    } },
    { ...assistant, message: { ...assistant.message, stop_reason: null } },
    { ...assistant, parent_tool_use_id: 'child-tool' },
    { ...assistant, resumed_from_incomplete_thinking: true },
    { ...assistant, message: { ...assistant.message, container: { id: 'work' } } },
  ]) {
    assert.equal(isClaudeSyntheticNoOutputAssistant(malformed), false)
  }
  for (const malformed of [
    { ...result, num_turns: 1 },
    { ...result, total_cost_usd: 0.01 },
    { ...result, duration_ms: -1 },
    { ...result, duration_api_ms: 1 },
    { ...result, permission_denials: [{}] },
    { ...result, modelUsage: {} },
    { ...result, modelUsage: {
      '<synthetic>': { ...result.modelUsage['<synthetic>'], webSearchRequests: 1 },
    } },
    { ...result, modelUsage: {
      '<synthetic>': { ...result.modelUsage['<synthetic>'], costUSD: 0.01 },
    } },
    { ...result, deferred_tool_use: { name: 'Read' } },
    { ...result, usage: { ...result.usage, cache_read_input_tokens: undefined } },
  ]) {
    assert.equal(isClaudeSyntheticNoOutputResult(malformed), false)
  }

  assert.equal(isClaudeSyntheticNoOutputAssistant({
    ...assistant,
    message: { ...assistant.message, content: [{ type: 'tool_use', name: 'Read' }] },
  }), false, 'a synthetic-labelled unknown/tool frame must fail closed')
  assert.equal(isProviderResponseActivity({
    ...assistant,
    message: { ...assistant.message, model: 'future-model', content: [] },
  }), false, 'an unknown frame with no emitted content is not usable output')
})

test('api retries and synthetic terminals re-arm liveness but never disable it', () => {
  const clock = fakeClock()
  const { watchdog, phases } = watchdogOnFakeClock(clock)
  const retry = {
    type: 'system', subtype: 'api_retry', attempt: 4, max_retries: 10,
    retry_delay_ms: 0, error_status: 429, error: 'overloaded',
  }
  const synthetic = {
    type: 'assistant',
    uuid: 'synthetic-assistant-2',
    session_id: 'synthetic-session',
    parent_tool_use_id: null,
    message: {
      id: 'synthetic-message-2', model: '<synthetic>', role: 'assistant',
      stop_reason: 'stop_sequence', stop_sequence: 'No response requested.',
      content: [{ type: 'text', text: 'No response requested.' }],
      usage: {
        input_tokens: 0, cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0, output_tokens: 0,
      },
    },
  }

  watchdog.start()
  clock.advance(179_000)
  assert.equal(watchdog.observe(retry), false)
  assert.equal(watchdog.waiting, true)
  clock.advance(179_000)
  assert.deepEqual(phases, [])
  assert.equal(watchdog.observe(synthetic), false)
  clock.advance(180_001)
  assert.deepEqual(phases, ['start'], 'retry/control traffic cannot make later silence unbounded')
})

test('only concrete stream output ends the first-response watchdog', () => {
  assert.equal(isProviderResponseActivity({
    type: 'stream_event', event: { type: 'message_start' },
  }), false)
  assert.equal(isProviderResponseActivity({
    type: 'stream_event', event: {
      type: 'content_block_delta', delta: { type: 'text_delta', text: 'answer' },
    },
  }), true)
  assert.equal(isProviderResponseActivity({
    type: 'assistant', message: { model: 'claude-fixture', content: [] },
  }), false, 'a completed frame with no emitted text or tool call is not usable app output')
  assert.equal(isProviderResponseActivity({
    type: 'stream_event', parent_tool_use_id: null, event: {
      type: 'content_block_start', content_block: { type: 'thinking', thinking: 'began' },
    },
  }), false, 'thinking is progress, not an answer')
  assert.equal(isProviderResponseActivity({
    type: 'assistant', parent_tool_use_id: null, message: {
      content: [{ type: 'tool_use', id: 'tool-1', name: 'Read', input: {} }],
    },
  }), true, 'a concrete root tool call ends the no-answer watchdog')
})

test('retry chatter cannot extend the absolute first-real-output ceiling', () => {
  const clock = fakeClock()
  const phases = []
  const watchdog = createProviderResponseWatchdog({
    timeoutMs: 180_000,
    wallTimeoutMs: 900_000,
    onTimeout: (phase, limit) => phases.push({ phase, limit }),
    schedule: (callback, ms) => clock.schedule(callback, ms),
    cancel: (id) => clock.cancel(id),
  })
  watchdog.start()
  for (let elapsed = 0; elapsed < 900_000; elapsed += 120_000) {
    clock.advance(Math.min(120_000, 899_999 - elapsed))
    watchdog.observe({ type: 'system', subtype: 'api_retry' })
  }
  clock.advance(1)
  assert.deepEqual(phases, [{ phase: 'start', limit: 'wall' }])
  assert.equal(watchdog.waiting, false)
})

test('thinking chatter rearms idle but cannot extend the absolute no-answer ceiling', () => {
  const clock = fakeClock()
  const phases = []
  const watchdog = createProviderResponseWatchdog({
    timeoutMs: 180_000,
    wallTimeoutMs: 900_000,
    onTimeout: (phase, limit) => phases.push({ phase, limit }),
    schedule: (callback, ms) => clock.schedule(callback, ms),
    cancel: (id) => clock.cancel(id),
  })
  watchdog.start()
  for (let elapsed = 0; elapsed < 899_999; elapsed += 120_000) {
    clock.advance(Math.min(120_000, 899_999 - elapsed))
    watchdog.observe({
      type: 'stream_event', parent_tool_use_id: null,
      event: {
        type: 'content_block_delta',
        delta: { type: 'thinking_delta', thinking: 'still thinking' },
      },
    })
  }
  assert.deepEqual(phases, [])
  clock.advance(1)
  assert.deepEqual(phases, [{ phase: 'start', limit: 'wall' }])
})

test('no-output terminal diagnostics distinguish exhausted recovery from replay refusal', () => {
  const exhausted = providerNoOutputFailure(vertex, {
    resumed: true, noProviderWork: true, freshReplayAttempted: true,
  })
  assert.equal(exhausted.errorKind, 'network')
  assert.deepEqual(exhausted.providerError, {
    providerType: 'provider_no_output',
    code: 'no_output_after_fresh_replay',
    diagnosticCode: 'claude_no_output_after_fresh_replay',
    resumed: true,
    noProviderWork: true,
    freshReplayAttempted: true,
  })

  const refused = providerNoOutputFailure(vertex, {
    resumed: true, noProviderWork: false, replayRefusal: 'guidance_acknowledged',
  })
  assert.equal(refused.providerError.code, 'no_output_replay_refused')
  assert.equal(refused.providerError.replayRefusal, 'guidance_acknowledged')
  assert.match(refused.message, /accepting additional guidance/)
})

test('provider timeout failure is provider-neutral and retryable network state', () => {
  const failure = providerStartTimeoutFailure(vertex, 45_000)
  assert.deepEqual(failure, {
    errorKind: 'network',
    provider: 'anthropic',
    access: 'claude_vertex',
    message: 'Google Vertex did not begin responding within 45 seconds.',
    providerError: { providerType: 'provider_start_timeout' },
  })
})

test('a compaction stall is reported as compaction, not as a provider that went quiet', () => {
  const failure = providerStartTimeoutFailure(claude, 900_000, 'compaction')

  assert.equal(failure.errorKind, 'network')
  assert.equal(failure.providerError.providerType, 'provider_compaction_timeout')
  assert.match(failure.message, /compacting/)
  assert.doesNotMatch(failure.message, /did not begin responding/)
  assert.equal(Object.hasOwn(failure, 'reconnectRequired'), false)

  // Both phases must be recognized as watchdog timeouts, or a later SDK message overwrites the
  // real cause and the user is told something else entirely.
  assert.equal(PROVIDER_TIMEOUT_PHASES.has('provider_start_timeout'), true)
  assert.equal(PROVIDER_TIMEOUT_PHASES.has('provider_first_output_timeout'), true)
  assert.equal(PROVIDER_TIMEOUT_PHASES.has(failure.providerError.providerType), true)
})

test('the absolute no-output ceiling reports its real 900-second budget', () => {
  const failure = providerStartTimeoutFailure(vertex, 900_000, 'start', 'wall')
  assert.equal(failure.providerError.providerType, 'provider_first_output_timeout')
  assert.match(failure.message, /900 seconds/)
  assert.match(failure.message, /produced no response/)
  assert.doesNotMatch(failure.message, /180 seconds/)
})

test('provider response watchdog invokes its terminal callback when no response arrives', () => {
  let scheduled
  let timedOut = false
  const watchdog = createProviderResponseWatchdog({
    onTimeout: () => { timedOut = true },
    schedule: (callback) => { scheduled = callback; return 1 },
    cancel: () => {},
  })

  watchdog.start()
  scheduled()
  assert.equal(timedOut, true)
  assert.equal(watchdog.waiting, false)
})
