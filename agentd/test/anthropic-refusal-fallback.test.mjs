// Claude Opus 5 adoption, plan Phase 1A (O5-006): the refusal/fallback wire contract.
//
// Every fixture here is hand-built to the shapes in the pinned SDK's `sdk.d.ts`
// (`SDKModelRefusalFallbackMessage`, `SDKModelRefusalNoFallbackMessage`, `SDKAssistantMessage`,
// `SDKPartialAssistantMessage`). That is deliberate and permanent: the only way to make a live model
// refuse is to ask it for something harmful, which is not a thing CI may do. Fixtures are the
// contract, so when the SDK is bumped, diff `sdk.d.ts` against these shapes rather than trusting a
// green run.
import { test } from 'node:test'
import assert from 'node:assert/strict'

import {
  claudeFrameIdentity,
  claudeRefusalEvents,
  createFrameCorrelator,
  fallbackIsPersistent,
  isClaudeRefusalMessage,
  replayClaudeStream,
} from '../src/claude-message-events.mjs'
import { captureAnthropicTurnError } from '../src/anthropic-turn-errors.mjs'

/// A complete, current-CLI fallback notice.
const fallbackMessage = (overrides = {}) => ({
  type: 'system',
  subtype: 'model_refusal_fallback',
  trigger: 'refusal',
  direction: 'retry',
  original_model: 'claude-opus-5',
  fallback_model: 'claude-opus-4-8',
  request_id: 'req_01ABC',
  api_refusal_category: 'cyber',
  api_refusal_explanation: 'This request asked for exploit code.',
  retracted_message_uuids: ['frame-1', 'tool-result-1'],
  refused_user_message_uuid: 'user-1',
  content: 'The response was replaced after a safety refusal.',
  uuid: 'notice-1',
  session_id: 'sess-1',
  ...overrides,
})

test('a fallback notice carries every field the transcript must attribute', () => {
  const [event] = claudeRefusalEvents(fallbackMessage())

  assert.equal(event.type, 'model_refusal')
  assert.equal(event.outcome, 'fallback')
  assert.equal(event.originalModel, 'claude-opus-5')
  assert.equal(event.fallbackModel, 'claude-opus-4-8')
  assert.equal(event.requestId, 'req_01ABC')
  assert.equal(event.category, 'cyber')
  assert.deepEqual(event.retractedMessageUUIDs, ['frame-1', 'tool-result-1'])
  assert.equal(event.refusedUserMessageUUID, 'user-1')
  assert.equal(event.frameUUID, 'notice-1')
})

test('the explanation is carried verbatim, never interpreted', () => {
  // Provider prose on an unstable string. It is displayed and nothing else — a policy branch taken
  // on this text would change behavior the next time someone edits the copy.
  const prose = 'Refused: <category=cyber> "generate an exploit" — see policy §4.'
  const [event] = claudeRefusalEvents(
    fallbackMessage({ api_refusal_explanation: prose }))

  assert.equal(event.explanation, prose)
})

test('a refusal with no fallback retracts nothing', () => {
  // No retry ran, so there is no replacement text to put in the transcript's place. Retracting the
  // refused leg here would delete what the user saw and leave a hole.
  const [event] = claudeRefusalEvents({
    type: 'system',
    subtype: 'model_refusal_no_fallback',
    original_model: 'claude-opus-5',
    request_id: null,
    api_refusal_category: 'cyber',
    api_refusal_explanation: null,
    refused_user_message_uuid: 'user-1',
    content: 'This request was declined.',
    uuid: 'notice-2',
    session_id: 'sess-1',
  })

  assert.equal(event.outcome, 'no_fallback')
  assert.deepEqual(event.retractedMessageUUIDs, [])
  assert.equal(event.requestId, null)
  assert.equal(event.explanation, null)
  assert.equal(event.fallbackModel, undefined, 'there is no fallback model to name')
})

test('an older CLI omitting the newer fields still normalizes', () => {
  // `retracted_message_uuids`, `api_refusal_category` and `refused_user_message_uuid` are all
  // documented as absent from older CLIs. Absent must mean "nothing to do", not a crash mid-turn.
  const [event] = claudeRefusalEvents({
    type: 'system',
    subtype: 'model_refusal_fallback',
    trigger: 'refusal',
    direction: 'retry',
    original_model: 'claude-opus-5',
    fallback_model: 'claude-opus-4-8',
    request_id: 'req_01ABC',
    content: 'Replaced.',
    uuid: 'notice-3',
    session_id: 'sess-1',
  })

  assert.deepEqual(event.retractedMessageUUIDs, [])
  assert.equal(event.category, null)
  assert.equal(event.refusedUserMessageUUID, null)
})

test('a malformed retraction list is filtered, not trusted', () => {
  const [event] = claudeRefusalEvents(
    fallbackMessage({ retracted_message_uuids: ['frame-1', '', null, 7, 'frame-2'] }))

  assert.deepEqual(event.retractedMessageUUIDs, ['frame-1', 'frame-2'])
})

test('a fallback swap is persistent unless it explicitly reverts', () => {
  // Upstream emits only `retry` now, documented as persistent for the session. An unknown future
  // direction treated as one-shot would leave the user looking at the wrong model all session, so
  // only an explicit `revert` is non-persistent.
  assert.equal(fallbackIsPersistent('retry'), true)
  assert.equal(fallbackIsPersistent('sticky'), true)
  assert.equal(fallbackIsPersistent('revert'), false)
  assert.equal(fallbackIsPersistent('some-future-direction'), true)

  assert.equal(claudeRefusalEvents(fallbackMessage())[0].persistent, true)
  assert.equal(
    claudeRefusalEvents(fallbackMessage({ direction: 'revert' }))[0].persistent, false)
})

test('an assistant frame reports its identity and what it replaces', () => {
  const identity = claudeFrameIdentity({
    type: 'assistant',
    message: { content: [] },
    parent_tool_use_id: null,
    uuid: 'frame-2',
    session_id: 'sess-1',
    supersedes: ['frame-1', 'tool-result-1'],
  })

  assert.deepEqual(identity, { frameUUID: 'frame-2', supersedes: ['frame-1', 'tool-result-1'] })
})

test('an ordinary assistant frame reports identity and no supersession', () => {
  // The common case by far. `supersedes` must be absent rather than empty so the app can treat its
  // presence alone as "this frame replaces something".
  const identity = claudeFrameIdentity({
    type: 'assistant', message: { content: [] }, parent_tool_use_id: null,
    uuid: 'frame-1', session_id: 'sess-1',
  })

  assert.deepEqual(identity, { frameUUID: 'frame-1' })
})

test('a partial carries the uuid its deltas belong to', () => {
  const identity = claudeFrameIdentity({
    type: 'stream_event',
    event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'hi' } },
    parent_tool_use_id: null,
    uuid: 'frame-1',
    session_id: 'sess-1',
  })

  assert.deepEqual(identity, { frameUUID: 'frame-1' })
})

test('messages with no frame identity yield null rather than a partial object', () => {
  assert.equal(claudeFrameIdentity({ type: 'result', uuid: 'r-1' }), null)
  assert.equal(claudeFrameIdentity({ type: 'assistant', message: {} }), null)
  assert.equal(claudeFrameIdentity(null), null)
})

test('non-refusal messages produce no refusal events', () => {
  for (const message of [
    { type: 'assistant', message: { content: [] }, uuid: 'a' },
    { type: 'result', subtype: 'success' },
    { type: 'system', subtype: 'init' },
    { type: 'system', subtype: 'compact_boundary' },
    null,
  ]) {
    assert.deepEqual(claudeRefusalEvents(message), [])
    assert.equal(isClaudeRefusalMessage(message), false)
  }
})

test('both refusal terminals are recognized as refusals', () => {
  assert.equal(isClaudeRefusalMessage(fallbackMessage()), true)
  assert.equal(
    isClaudeRefusalMessage({ type: 'system', subtype: 'model_refusal_no_fallback' }), true)
})

// MARK: - Pairing a completed frame with the streaming id whose deltas built it

const partial = (uuid) => ({
  type: 'stream_event',
  event: { type: 'content_block_delta', delta: { type: 'text_delta', text: '…' } },
  parent_tool_use_id: null,
  uuid,
  session_id: 'sess-1',
})

const completed = (uuid, content = [{ type: 'text', text: '…' }]) => ({
  type: 'assistant', message: { content }, parent_tool_use_id: null,
  uuid, session_id: 'sess-1',
})

test('a completed frame reports the streaming id it replaces', () => {
  const correlator = createFrameCorrelator()
  correlator.observe(partial('partial-1'))

  assert.equal(correlator.observe(completed('frame-1')), 'partial-1')
})

test('each frame pairs with its own partials, not the previous frame\'s', () => {
  const correlator = createFrameCorrelator()
  correlator.observe(partial('partial-1'))
  assert.equal(correlator.observe(completed('frame-1')), 'partial-1')
  correlator.observe(partial('partial-2'))

  assert.equal(correlator.observe(completed('frame-2')), 'partial-2')
})

test('a completed frame pairs with the first text event that opened its transcript row', () => {
  const correlator = createFrameCorrelator()
  correlator.observe(partial('partial-first'))
  correlator.observe(partial('partial-middle'))
  correlator.observe(partial('partial-last'))

  assert.equal(correlator.observe(completed('frame-1')), 'partial-first')
})

test('thinking and lifecycle stream events cannot steal a text row pairing', () => {
  const correlator = createFrameCorrelator()
  correlator.observe(partial('partial-first'))
  correlator.observe({
    type: 'stream_event',
    event: { type: 'content_block_stop', index: 0 },
    uuid: 'lifecycle-event',
  })
  correlator.observe({
    type: 'stream_event',
    event: {
      type: 'content_block_delta',
      delta: { type: 'thinking_delta', thinking: 'reasoning' },
    },
    uuid: 'thinking-event',
  })
  correlator.observe(completed(
    'thinking-frame',
    [{ type: 'thinking', thinking: 'reasoning', signature: 'signed' }]))

  assert.equal(correlator.observe(completed('text-frame')), 'partial-first')
})

test('a frame that streamed nothing reports no provisional id', () => {
  // The case that makes guessing wrong: a tool-only frame completing right after a text frame. It
  // must NOT claim the previous frame's row, or a later retraction deletes the wrong text.
  const correlator = createFrameCorrelator()
  correlator.observe(partial('partial-1'))
  correlator.observe(completed('frame-1'))

  assert.equal(correlator.observe(completed('frame-2', [])), null)
})

test('other message types do not disturb the pairing', () => {
  const correlator = createFrameCorrelator()
  correlator.observe(partial('partial-1'))
  correlator.observe({ type: 'system', subtype: 'status' })
  correlator.observe({ type: 'user', message: { content: [] } })

  assert.equal(correlator.observe(completed('frame-1')), 'partial-1')
})

// MARK: - Whole-turn replay through the real emission path
//
// `replayClaudeStream` drives `claudeStreamFrameEvents`, which is the same function `streamOnce`
// calls. That matters more here than anywhere else in the codebase: a refusal cannot be provoked
// from a live model, so if the tested path were a reimplementation of the emission path, the tests
// would prove nothing about what the app actually receives.

test('a refused turn replays as retraction, replacement and notice in wire order', () => {
  const events = replayClaudeStream([
    partial('partial-1'),
    completed('frame-1'),
    // The retry's replacement text supersedes the refused frame.
    { ...completed('frame-2'), supersedes: ['frame-1'] },
    fallbackMessage({ retracted_message_uuids: ['frame-1'] }),
  ])

  assert.deepEqual(events.map((e) => e.type), [
    'delta', 'assistant_frame', 'assistant_frame', 'model_refusal',
  ])
  assert.equal(events[1].frameUUID, 'frame-1')
  assert.equal(events[1].provisionalFrameUUID, 'partial-1')
  assert.deepEqual(events[2].supersedes, ['frame-1'])
  assert.deepEqual(events[3].retractedMessageUUIDs, ['frame-1'])
})

test('a delta carries the frame its text belongs to', () => {
  const [delta] = replayClaudeStream([partial('partial-1')])

  assert.equal(delta.type, 'delta')
  assert.equal(delta.frameUUID, 'partial-1')
})

test('a Claude tool call carries the exact assistant frame a refusal can retract', () => {
  const events = replayClaudeStream([completed('frame-tool', [{
    type: 'tool_use', id: 'tool-1', name: 'Bash', input: { command: 'swift test' },
  }])])

  assert.deepEqual(events.map((event) => event.type), ['assistant_frame', 'tool_use'])
  assert.deepEqual(events[1], {
    type: 'tool_use', toolUseId: 'tool-1', name: 'Bash',
    input: { command: 'swift test' }, frameUUID: 'frame-tool',
  })
})

test('the fallback model refusing in turn produces a second, no-fallback notice', () => {
  // Plan case 10. The retry is allowed to refuse too, and when it does there is no third model —
  // so the turn ends with text the user can see and a notice explaining why nothing replaced it.
  const events = replayClaudeStream([
    completed('frame-1'),
    fallbackMessage({ retracted_message_uuids: ['frame-1'], uuid: 'notice-1' }),
    completed('frame-2'),
    {
      type: 'system',
      subtype: 'model_refusal_no_fallback',
      original_model: 'claude-opus-4-8',
      request_id: 'req_02',
      api_refusal_category: 'cyber',
      content: 'Declined again.',
      uuid: 'notice-2',
      session_id: 'sess-1',
    },
  ])

  const refusals = events.filter((e) => e.type === 'model_refusal')
  assert.equal(refusals.length, 2)
  assert.equal(refusals[0].outcome, 'fallback')
  assert.equal(refusals[1].outcome, 'no_fallback')
  // The second refusal retracts nothing: there is no replacement to put in its place.
  assert.deepEqual(refusals[1].retractedMessageUUIDs, [])
  assert.equal(refusals[1].originalModel, 'claude-opus-4-8',
    'the second notice names the model that actually refused, not the original selection')
})

test('an ordinary turn emits no refusal events at all', () => {
  const events = replayClaudeStream([
    partial('partial-1'), completed('frame-1'), { type: 'result', subtype: 'success' },
  ])

  assert.equal(events.filter((e) => e.type === 'model_refusal').length, 0)
  assert.deepEqual(events.map((e) => e.type), ['delta', 'assistant_frame'])
})

// MARK: - A refusal must never be reported as a broken lane

test('neither refusal terminal is captured as a provider failure', () => {
  // The account is fine. Recording a refusal as a turn failure would surface a provider error card
  // and push the user to reconnect a working account — and on the fallback path the turn then goes
  // on to succeed, so there is no failure to report at all.
  for (const message of [
    fallbackMessage(),
    { type: 'system', subtype: 'model_refusal_no_fallback', original_model: 'claude-opus-5',
      request_id: null, content: 'Declined.', uuid: 'notice-2', session_id: 'sess-1' },
  ]) {
    const turn = {}
    assert.equal(captureAnthropicTurnError(turn, message, 'anthropic'), null)
    assert.equal(turn.anthropicFailure, undefined)
  }
})

test('an assistant frame stopping for refusal is not a provider failure', () => {
  const turn = {}
  const captured = captureAnthropicTurnError(turn, {
    type: 'assistant',
    message: { content: [], stop_reason: 'refusal' },
    error: 'unknown',
    uuid: 'frame-1',
    session_id: 'sess-1',
  }, 'anthropic')

  assert.equal(captured, null)
  assert.equal(turn.anthropicFailure, undefined)
})

test('a real provider error is still captured', () => {
  // The guard above must be narrow. An operational failure on an assistant frame is exactly what
  // this capture exists for, and must survive the refusal carve-out.
  const turn = {}
  const captured = captureAnthropicTurnError(turn, {
    type: 'assistant',
    message: { content: [], stop_reason: 'end_turn' },
    error: 'authentication_failed',
    uuid: 'frame-1',
    session_id: 'sess-1',
  }, 'anthropic')

  assert.notEqual(captured, null)
  assert.notEqual(turn.anthropicFailure, undefined)
})
