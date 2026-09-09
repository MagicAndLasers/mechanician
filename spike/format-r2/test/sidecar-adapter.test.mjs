import test from 'node:test'
import assert from 'node:assert/strict'
import { canonicalFromSidecar } from '../canonical-from-sidecar.mjs'
import { encodeACR, decodeACRRecord } from '../encode-acr.mjs'
import { compareCanonicalFidelity, compareSkeletons } from '../run.mjs'

// The real-corpus regression the harness caught (344 kind mismatches on the subagent-heavy
// record): a delegate's Task call exists BOTH as a message tool row and in the subagents map.
// The adapter must keep exactly one canonical copy or round trips misclassify the results.
test('a delegate represented in both messages and subagents yields one canonical copy', () => {
  const sidecar = {
    id: 'C0FFEE00-0000-4000-A000-000000000001',
    title: 'dup',
    messages: [
      { id: 'm1', kind: 'user', text: 'go' },
      { id: 'm2', kind: 'tool', toolName: 'Task', toolUseId: 'agent-1',
        text: 'Explore', toolResult: 'done' },
      { id: 'm3', kind: 'tool', toolName: 'Bash', toolUseId: 'plain-1',
        text: 'ls', toolResult: 'files', toolOwnerAgentID: 'root' },
      { id: 'm4', kind: 'assistant', text: 'finished' },
    ],
    subagents: {
      'agent-1': { key: 'agent-1', subagentType: 'Explore', task: 'look around',
        status: 'completed', startedAt: '2026-08-02T10:00:00Z', resultPreview: 'done' },
    },
  }
  const canonical = canonicalFromSidecar(sidecar)
  const byKind = {}
  for (const e of canonical.events) byKind[e.kind] = (byKind[e.kind] ?? 0) + 1
  assert.equal(byKind.agent_spawn, 1)
  assert.equal(byKind.agent_call_result, 1, 'the subagents map owns the delegate lifecycle')
  assert.equal(byKind.tool_call, 1, 'only the PLAIN tool row survives as a tool call')
  assert.equal(byKind.tool_result, 1)

  const { record } = encodeACR(canonical)
  const misses = compareSkeletons(canonical, decodeACRRecord(record))
  assert.deepEqual(misses, [], 'with one canonical copy, the round trip is clean')
})

test('transcript tool content inherits exact nested-agent ownership from activity', () => {
  const canonical = canonicalFromSidecar({
    subagents: {
      child: {
        key: 'child', taskId: 'child-task', subagentType: 'Explore', task: 'inspect',
        status: 'running',
      },
    },
    messages: [{
      id: 'read-row', kind: 'tool', toolName: 'Read', toolUseId: 'read-call',
      text: 'read source', toolResult: 'contents',
      captureOrdinal: 2, toolResultCaptureOrdinal: 3,
    }],
    agentActivity: [{
      id: 'child-read', agentID: 'subagent:child-task', kind: 'tool', detail: 'Read',
      toolTarget: 'source.swift', turnID: 'provider-turn', captureOrdinal: 2,
    }],
  })

  const call = canonical.events.find((event) => event.kind === 'tool_call')
  const result = canonical.events.find((event) => event.kind === 'tool_result')
  assert.notEqual(call.agentId, 'root')
  assert.equal(result.agentId, call.agentId)
  assert.equal(call.turnId, 'turn-1')
  assert.equal(call.toolTarget, 'source.swift')
  assert.equal(call.toolOwnershipProvenance, 'exact-transcript-activity-correlation')
  assert.equal(canonical.events.some((event) =>
    event.eventId === 'activity:child-read'), false, 'the activity enriches, never duplicates')
})

test('legacy multi-actor tool ownership is unknown rather than falsely root', () => {
  const canonical = canonicalFromSidecar({
    subagents: {
      child: { key: 'child', taskId: 'child-task', subagentType: 'Explore', task: 'inspect' },
    },
    messages: [{
      id: 'legacy-tool', kind: 'tool', toolName: 'Read', toolUseId: 'read-call',
      text: 'read source', toolResult: 'contents', captureOrdinal: 4,
      toolResultCaptureOrdinal: 5,
    }],
  })

  const call = canonical.events.find((event) => event.kind === 'tool_call')
  const result = canonical.events.find((event) => event.kind === 'tool_result')
  assert.equal(call.agentId, 'unknown-tool-actor')
  assert.equal(result.agentId, 'unknown-tool-actor')
  assert.equal(call.toolOwnershipProvenance, 'unavailable-legacy-multi-actor-record')
  assert.ok(canonical.agents.some((agent) => agent.id === 'unknown-tool-actor'))
})

test('persisted transcript ownership survives after bounded activity is trimmed', () => {
  const canonical = canonicalFromSidecar({
    subagents: {
      child: { key: 'child', taskId: 'child-task', subagentType: 'Explore', task: 'inspect' },
    },
    messages: [{
      id: 'owned-tool', kind: 'tool', toolName: 'Read', toolUseId: 'read-call',
      text: 'read source', toolResult: 'contents', captureOrdinal: 4,
      toolResultCaptureOrdinal: 5, toolOwnerAgentID: 'subagent:child-task',
      toolTurnID: 'private-turn',
    }],
  })

  const call = canonical.events.find((event) => event.kind === 'tool_call')
  const result = canonical.events.find((event) => event.kind === 'tool_result')
  assert.notEqual(call.agentId, 'root')
  assert.equal(result.agentId, call.agentId)
  assert.equal(call.turnId, 'turn-1')
  assert.equal(result.turnId, 'turn-1')
  assert.equal(call.toolOwnershipProvenance, 'persisted-transcript-tool-owner')
  const portable = JSON.stringify(canonical)
  assert.doesNotMatch(portable, /child-task|private-turn/)
})

test('unmatched compaction and queued-guidance activity preserve facts without private text', () => {
  const canonical = canonicalFromSidecar({
    agentActivity: [
      {
        id: 'failed-compaction', agentID: 'root', kind: 'compaction',
        compactionTrigger: 'auto', compactionPreTokens: 200000,
        compactionError: 'provider failed', turnID: 'provider-turn', captureOrdinal: 1,
      },
      {
        id: 'queued-guidance', agentID: 'root', kind: 'interjection',
        detail: 'PRIVATE_QUEUED_GUIDANCE', userEventKind: 'guidance',
        interjectionDisposition: 'queued', turnID: 'provider-turn', captureOrdinal: 2,
      },
    ],
  })

  const compaction = canonical.events.find((event) => event.kind === 'compaction')
  assert.equal(compaction.isError, true)
  assert.equal(compaction.outcome, 'failed')
  assert.equal(compaction.error, 'provider failed')
  assert.equal(compaction.compactionProvenance,
    'persisted-agent-activity-without-transcript-row')
  const delivery = canonical.events.find((event) => event.kind === 'user_delivery')
  assert.equal(delivery.disposition, 'queued')
  assert.equal(delivery.contentStatus, 'omitted-private-queued-content')
  assert.equal(JSON.stringify(delivery).includes('PRIVATE_QUEUED_GUIDANCE'), false)
})

// Compaction rows are the fact neither draft can express natively — the adapter must surface
// them as first-class canonical events so encoders are FORCED to ledger the gap.
test('compaction rows become first-class canonical events and survive the ACR round trip', () => {
  const sidecar = {
    id: 'C0FFEE00-0000-4000-A000-000000000002',
    title: 'compacted',
    messages: [
      { id: 'm1', kind: 'user', text: 'long work' },
      { id: 'm2', kind: 'compaction', compactionTrigger: 'auto',
        compactionPreTokens: 180000, compactionPostTokens: 40000 },
      { id: 'm3', kind: 'assistant', text: 'continuing with reduced history' },
    ],
  }
  const canonical = canonicalFromSidecar(sidecar)
  const compaction = canonical.events.find((e) => e.kind === 'compaction')
  assert.equal(compaction.trigger, 'auto')
  assert.equal(compaction.preTokens, 180000)

  const { record, ledger } = encodeACR(canonical)
  assert.ok(
    ledger.extensions.some((e) => e.includes('compaction')),
    'the compaction gap must be ledgered, never silently absorbed')
  const misses = compareSkeletons(canonical, decodeACRRecord(record))
  assert.deepEqual(misses, [])
})

test('completed permissions become inert historical pairs with record-local ids', () => {
  const canonical = canonicalFromSidecar({
    messages: [
      { kind: 'permission', permissionId: 'raw-pending-permission', permName: 'Bash',
        text: 'pending secret command', permDecided: false },
      { kind: 'permission', permissionId: 'raw-approved-permission', permName: 'Bash',
        text: 'approved command', permDecided: true, permAllowed: true, permAlways: true,
        observedAt: '2026-08-02T10:00:00Z' },
      { kind: 'permission', permissionId: 'raw-denied-permission', permName: 'Edit',
        text: 'denied edit', permDecided: true, permAllowed: false, permAlways: false,
        observedAt: '2026-08-02T10:01:00Z' },
    ],
  })

  const requests = canonical.events.filter((event) => event.kind === 'authorization_request')
  const responses = canonical.events.filter((event) => event.kind === 'authorization_response')
  assert.deepEqual(requests.map((event) => event.interactionId), [
    'authorization-1', 'authorization-2',
  ])
  assert.deepEqual(responses.map((event) => event.interactionId), [
    'authorization-1', 'authorization-2',
  ])
  assert.deepEqual(responses.map((event) => event.decision), ['allow', 'deny'])
  assert.deepEqual(responses.map((event) => event.requestedScope), ['persistent', 'once'])
  assert.ok([...requests, ...responses].every((event) => event.historicalOnly === true))
  assert.ok(requests.every((event) => event.input === null))
  assert.ok(requests.every(
    (event) => event.inputDisclosure === 'omitted-private-operative-input'))
  assert.ok(responses.every((event) => event.operativeGrantIncluded === false))
  assert.equal(responses[0].observedAt, null, 'the sidecar has no decision timestamp to invent')
  assert.equal(responses[0].timeProvenance, 'unknown')

  const portable = JSON.stringify(canonical)
  assert.doesNotMatch(portable, /raw-pending-permission|raw-approved-permission|raw-denied-permission/)
  assert.doesNotMatch(portable, /pending secret command|approved command|denied edit/)
  assert.doesNotMatch(portable, /authorization_ack/,
    'a decided sidecar card does not separately prove a provider acknowledgement fact')
})

test('completed questions retain available content but omit pending operative cards', () => {
  const questions = [{ question: 'Choose?', options: [{ label: 'A' }, { label: 'B' }] }]
  const canonical = canonicalFromSidecar({
    messages: [
      { kind: 'question', questionId: 'raw-pending-question', questions,
        questionDecided: false },
      { kind: 'question', questionId: 'raw-answered-question', questions,
        questionDecided: true, questionAnswers: { 'Choose?': 'B' },
        observedAt: '2026-08-02T11:00:00Z' },
      { kind: 'question', questionId: 'raw-answer-content-unavailable',
        questionDecided: true },
    ],
  })

  const requests = canonical.events.filter((event) => event.kind === 'question')
  const answers = canonical.events.filter((event) => event.kind === 'answer')
  assert.deepEqual(requests.map((event) => event.interactionId), ['question-1', 'question-2'])
  assert.deepEqual(answers.map((event) => event.interactionId), ['question-1', 'question-2'])
  assert.deepEqual(requests[0].questions, questions)
  assert.deepEqual(answers[0].answers, { 'Choose?': 'B' })
  assert.equal(requests[0].contentStatus, 'retained')
  assert.equal(answers[0].contentStatus, 'retained')
  assert.equal(requests[1].questions, null)
  assert.equal(answers[1].answers, null)
  assert.equal(requests[1].contentStatus, 'unavailable')
  assert.equal(answers[1].contentStatus, 'unavailable')
  assert.ok([...requests, ...answers].every((event) => event.historicalOnly === true))
  assert.equal(answers[0].observedAt, null, 'the sidecar has no answer timestamp to invent')

  const portable = JSON.stringify(canonical)
  assert.doesNotMatch(portable,
    /raw-pending-question|raw-answered-question|raw-answer-content-unavailable/)
  assert.doesNotMatch(portable, /answer_ack/)
})

test('durable interaction selections, acknowledgements, closure, and free text stay distinct', () => {
  const canonical = canonicalFromSidecar({
    messages: [
      {
        kind: 'permission', permissionId: 'raw-selected-permission', permName: 'Bash',
        permDecided: false, permAllowed: true, permAlways: false,
        interactionResponseStatus: 'selected',
        interactionResponseObservedAt: '2026-08-03T12:00:01.000Z',
      },
      {
        kind: 'permission', permissionId: 'raw-accepted-permission', permName: 'Edit',
        permDecided: true, permAllowed: false, permAlways: true,
        interactionResponseStatus: 'accepted',
        interactionResponseObservedAt: '2026-08-03T12:01:01.000Z',
        interactionAcknowledgedAt: '2026-08-03T12:01:02.000Z',
      },
      {
        kind: 'permission', permissionId: 'raw-closed-permission', permName: 'Read',
        permDecided: false,
        interactionClosure: {
          outcome: 'cancelled', reason: 'turn_interrupted',
          observedAt: '2026-08-03T12:02:01.000Z',
        },
      },
      {
        kind: 'question', questionId: 'raw-answered-question', questionDecided: true,
        questions: [{ question: 'Destination?', options: [{ label: 'Other' }] }],
        questionAnswers: { 'Destination?': 'Other' },
        questionFreeTextResponse: 'A folder with spaces',
        interactionResponseStatus: 'accepted',
        interactionResponseObservedAt: '2026-08-03T12:03:01.000Z',
        interactionAcknowledgedAt: '2026-08-03T12:03:02.000Z',
      },
      {
        kind: 'question', questionId: 'raw-closed-question', questionDecided: false,
        questions: [{ question: 'Pending?', options: [] }],
        interactionClosure: {
          outcome: 'cancelled', reason: 'turn_interrupted',
          observedAt: '2026-08-03T12:04:01.000Z',
        },
      },
    ],
  })

  const authorizationResponses = canonical.events.filter(
    (event) => event.kind === 'authorization_response')
  assert.deepEqual(authorizationResponses.map((event) => [
    event.interactionId, event.responseStatus, event.observedAt,
  ]), [
    ['authorization-1', 'selected', '2026-08-03T12:00:01.000Z'],
    ['authorization-2', 'accepted', '2026-08-03T12:01:01.000Z'],
  ])
  assert.deepEqual(canonical.events.filter((event) => event.kind === 'authorization_ack')
    .map((event) => [event.interactionId, event.responseStatus, event.observedAt]), [[
    'authorization-2', 'accepted', '2026-08-03T12:01:02.000Z',
  ]])

  const answer = canonical.events.find(
    (event) => event.kind === 'answer' && event.response === 'A folder with spaces')
  assert.equal(answer.responseStatus, 'accepted')
  assert.equal(answer.observedAt, '2026-08-03T12:03:01.000Z')
  assert.equal(canonical.events.find((event) => event.kind === 'answer_ack').observedAt,
    '2026-08-03T12:03:02.000Z')

  const closures = canonical.events.filter((event) => event.kind === 'interaction_closed')
  assert.deepEqual(closures.map((event) => [
    event.interactionId, event.interactionType, event.outcome, event.reason, event.observedAt,
  ]), [
    ['authorization-3', 'authorization', 'cancelled', 'turn_interrupted',
      '2026-08-03T12:02:01.000Z'],
    ['question-2', 'question', 'cancelled', 'turn_interrupted',
      '2026-08-03T12:04:01.000Z'],
  ])
  assert.equal(canonical.events.some((event) =>
    ['authorization_response', 'answer'].includes(event.kind)
      && ['authorization-3', 'question-2'].includes(event.interactionId)), false,
  'closure settles the request without fabricating a deny or answer')

  const portable = JSON.stringify(canonical)
  assert.doesNotMatch(portable, /raw-(?:selected|accepted|closed|answered)-/)
  // Chronology is an adapter-level conversion diagnostic until the external projection prototypes
  // gain an explicit document-level completeness vocabulary. Keep this interaction assertion scoped
  // to the canonical lifecycle facts it is intended to verify.
  const { chronology: _chronology, ...portableLifecycle } = canonical
  const { record } = encodeACR(portableLifecycle)
  const decoded = decodeACRRecord(record)
  assert.deepEqual(compareSkeletons(portableLifecycle, decoded), [],
    'the prototype external roots retain closure as an explicitly extension-carried event')
  assert.deepEqual(compareCanonicalFidelity(portableLifecycle, decoded).unclassifiedDifferences, [],
    'every exact sidecar lifecycle difference is retained or named by the prototype ledger')
})

test('subagent terminal records preserve completed, failed, stopped, and unknown outcomes', () => {
  const subagents = {}
  for (const status of ['completed', 'failed', 'stopped', 'future-terminal', 'running']) {
    subagents[status] = {
      key: status, status, subagentType: 'Explore', task: status,
      resultPreview: `${status} preview`, endedAt: '2026-08-02T12:00:00Z',
    }
  }
  const canonical = canonicalFromSidecar({ subagents })
  const terminals = canonical.events.filter((event) => event.kind === 'agent_call_result')

  assert.equal(terminals.length, 4, 'a running subagent has no fabricated terminal event')
  assert.deepEqual(Object.fromEntries(terminals.map((event) => [event.status, event.outcome])), {
    completed: 'succeeded', failed: 'failed', stopped: 'stopped',
    'future-terminal': 'unknown',
  })
  assert.ok(terminals.every(
    (event) => event.stateProvenance === 'degraded-legacy-subagent-summary'))
  assert.equal(canonical.chronology.legacySummaryEventCount, 9,
    'five summary-derived starts plus four summary-derived terminals are explicitly degraded')
  assert.equal(terminals.find((event) => event.status === 'stopped').isError, false)
  assert.equal(canonical.events.some((event) => event.kind === 'agent_completed'), false,
    'stopped must never collapse into a success-shaped completed event')
})

test('tool results own their outcome and local reconciliation preserves a result-less stop', () => {
  const canonical = canonicalFromSidecar({
    messages: [
      { kind: 'tool', id: 'failed-row', toolUseId: 'failed-call', toolName: 'Bash',
        toolResult: 'exit 1', toolIsError: true, toolState: 'succeeded' },
      { kind: 'tool', id: 'success-row', toolUseId: 'success-call', toolName: 'Read',
        toolResult: 'contents', toolIsError: false, toolState: 'failed' },
      { kind: 'tool', id: 'stopped-row', toolUseId: 'stopped-call', toolName: 'Bash',
        toolState: 'stopped' },
      { kind: 'tool', id: 'running-row', toolUseId: 'running-call', toolName: 'Bash',
        toolState: 'running' },
    ],
  })

  const results = canonical.events.filter((event) => event.kind === 'tool_result')
  assert.deepEqual(results.map((event) => [event.toolUseId, event.outcome]), [
    ['failed-call', 'failed'], ['success-call', 'succeeded'],
  ])
  assert.ok(results.every((event) => event.stateProvenance === 'persisted-tool-result'))

  const terminals = canonical.events.filter((event) => event.kind === 'tool_terminal')
  assert.deepEqual(terminals, [{
    kind: 'tool_terminal', eventId: 'entry:stopped-row:terminal',
    agentId: 'root', toolUseId: 'stopped-call',
    outcome: 'stopped', stateProvenance: 'legacy-local-reconciliation',
    providerObserved: false, observedAt: null, timeProvenance: 'persisted-observation',
  }])
  assert.equal(terminals.some((event) => event.toolUseId === 'running-call'), false)
  assert.doesNotMatch(JSON.stringify(terminals), /cancelled|cancellation|provider-cancel/)
})

test('fallback transcript events retain their source row kind', () => {
  const canonical = canonicalFromSidecar({
    messages: [
      { kind: 'system', text: 'system fact' },
      { kind: 'review', text: 'review fact' },
      { kind: 'future-kind', text: 'future fact' },
      { text: 'untyped fact' },
    ],
  })
  assert.deepEqual(
    canonical.events.map((event) => [event.kind, event.sourceKind]),
    [
      ['system', 'system'], ['system', 'review'],
      ['system', 'future-kind'], ['system', 'unknown'],
    ])
})

test('complete capture ordinals order facts across maps, transcript rows, and row refinements', () => {
  const canonical = canonicalFromSidecar({
    // Map traversal happens before messages, deliberately opposite the retained capture order.
    subagents: {
      child: {
        key: 'child', subagentType: 'Explore', task: 'inspect', status: 'completed',
        startedAt: '2026-08-03T12:00:03.000Z', endedAt: '2026-08-03T12:00:08.000Z',
        startedCaptureOrdinal: 3, endedCaptureOrdinal: 8,
      },
    },
    agentActivity: [
      {
        id: 'child-start', agentID: 'subagent:child', kind: 'state', phase: 'model',
        at: '2026-08-03T12:00:03.000Z', captureOrdinal: 3,
      },
      {
        id: 'child-end', agentID: 'subagent:child', kind: 'state', phase: 'completed',
        at: '2026-08-03T12:00:08.000Z', captureOrdinal: 8,
      },
    ],
    messages: [
      { kind: 'user', id: 'user-entry', text: 'start', captureOrdinal: 1 },
      {
        kind: 'permission', id: 'permission-entry', permName: 'Bash',
        permDecided: true, permAllowed: true,
        interactionResponseStatus: 'accepted',
        captureOrdinal: 2, interactionResponseCaptureOrdinal: 6,
        interactionAcknowledgedCaptureOrdinal: 10,
        interactionAcknowledgedAt: '2026-08-03T12:00:10.000Z',
      },
      {
        kind: 'tool', id: 'plain-tool', toolUseId: 'plain-tool', toolName: 'Read',
        toolResult: 'contents', captureOrdinal: 4, toolResultCaptureOrdinal: 7,
      },
      { kind: 'assistant', id: 'assistant-entry', text: 'done', captureOrdinal: 9 },
    ],
  })

  assert.deepEqual(canonical.chronology, {
    status: 'complete', basis: 'record-local-capture-partial-order',
    tieSemantics: 'same-ordinal-events-are-an-unordered-capture-batch',
    serializationOrder: 'capture-ordinal-then-stable-event-id',
    maximumCaptureOrdinal: 10, captureBatchCount: 9, eventCount: 9,
  })
  assert.deepEqual(canonical.events.map((event) => [event.captureOrdinal, event.kind]), [
    [1, 'user_message'],
    [2, 'authorization_request'],
    [3, 'agent_spawn'],
    [4, 'tool_call'],
    [6, 'authorization_response'],
    [7, 'tool_result'],
    [8, 'agent_call_result'],
    [9, 'assistant_message'],
    [10, 'authorization_ack'],
  ])
})

test('legacy and partially ordinal sidecars preserve traversal order with a degraded diagnostic', () => {
  const legacy = canonicalFromSidecar({
    subagents: {
      child: { key: 'child', status: 'running', startedCaptureOrdinal: 0 },
    },
    messages: [
      { kind: 'user', text: 'legacy row' },
      { kind: 'assistant', text: 'partially upgraded row', captureOrdinal: 2 },
    ],
  })

  assert.deepEqual(legacy.events.map((event) => event.kind), [
    'agent_spawn', 'user_message', 'assistant_message',
  ], 'partial ordinals must not be used to manufacture a cross-source total order')
  assert.deepEqual(legacy.chronology, {
    status: 'degraded', basis: 'adapter-traversal-only',
    diagnostic: 'cross-source-order-unavailable',
    eventCount: 3,
    capturedOrdinalEventCount: 1,
    missingCaptureOrdinalEventCount: 1,
    invalidCaptureOrdinalEventCount: 1,
    stableEventIdEventCount: 1,
    missingStableEventIdEventCount: 2,
    duplicateStableEventIdEventCount: 0,
    legacySummaryEventCount: 1,
  })
  assert.equal(legacy.events[0].captureOrdinal, undefined)
  assert.equal(legacy.events[1].captureOrdinal, undefined)
  assert.equal(legacy.events[2].captureOrdinal, 2)
})

test('same-callback facts share an unordered ordinal and serialize by stable event id', () => {
  const canonical = canonicalFromSidecar({
    messages: [
      {
        kind: 'tool', id: 'z-tool', toolUseId: 'z-call', toolName: 'Bash',
        toolState: 'stopped', captureOrdinal: 1, toolTerminalCaptureOrdinal: 5,
      },
      {
        kind: 'tool', id: 'a-tool', toolUseId: 'a-call', toolName: 'Bash',
        toolState: 'stopped', captureOrdinal: 2, toolTerminalCaptureOrdinal: 5,
      },
    ],
  })

  assert.deepEqual(canonical.chronology, {
    status: 'complete', basis: 'record-local-capture-partial-order',
    tieSemantics: 'same-ordinal-events-are-an-unordered-capture-batch',
    serializationOrder: 'capture-ordinal-then-stable-event-id',
    maximumCaptureOrdinal: 5, captureBatchCount: 3, eventCount: 4,
  })
  assert.deepEqual(canonical.events.map((event) => [
    event.captureOrdinal, event.eventId, event.kind,
  ]), [
    [1, 'entry:z-tool', 'tool_call'],
    [2, 'entry:a-tool', 'tool_call'],
    [5, 'entry:a-tool:terminal', 'tool_terminal'],
    [5, 'entry:z-tool:terminal', 'tool_terminal'],
  ])
  assert.equal(canonical.chronology.tieSemantics,
    'same-ordinal-events-are-an-unordered-capture-batch',
  'lexical serialization inside the batch must not claim causal order')
})

test('complete chronology requires stable unique local event ids', () => {
  const missing = canonicalFromSidecar({
    messages: [{ kind: 'user', text: 'no durable row id', captureOrdinal: 1 }],
  })
  assert.equal(missing.chronology.status, 'degraded')
  assert.equal(missing.chronology.missingStableEventIdEventCount, 1)

  const duplicate = canonicalFromSidecar({
    messages: [
      { kind: 'assistant', id: 'same-id', text: 'first', captureOrdinal: 1 },
      { kind: 'user', id: 'same-id', text: 'second', captureOrdinal: 2 },
    ],
  })
  assert.equal(duplicate.chronology.status, 'degraded')
  assert.equal(duplicate.chronology.duplicateStableEventIdEventCount, 1)
  assert.deepEqual(duplicate.events.map((event) => event.kind), [
    'assistant_message', 'user_message',
  ], 'a degraded conversion preserves traversal order rather than inventing a tie-break')
})

test('activity chronology orders equal-wall-time agent facts around transcript-owned facts', () => {
  const at = '2026-08-03T14:00:00.000Z'
  const sidecar = {
    subagents: {
      child: {
        key: 'child', taskId: 'durable-child', subagentType: 'Explore', task: 'inspect',
        status: 'completed', resultPreview: 'finished', startedAt: at, endedAt: at,
        // Summary ordinals are explicit correlation pointers; the matched activity rows own order.
        startedCaptureOrdinal: 3, endedCaptureOrdinal: 10,
      },
    },
    messages: [
      {
        kind: 'tool', id: 'root-tool', toolUseId: 'root-call', toolName: 'Read',
        toolResult: 'contents', observedAt: at,
        captureOrdinal: 4, toolResultCaptureOrdinal: 7,
      },
      {
        kind: 'compaction', id: 'compaction-row', compactionTrigger: 'auto', observedAt: at,
        captureOrdinal: 8,
      },
      { kind: 'user', id: 'guidance-row', text: 'continue', observedAt: at, captureOrdinal: 9 },
    ],
    agentActivity: [
      {
        id: 'root-state', agentID: 'root', kind: 'state', phase: 'model', detail: 'working',
        turnID: 'turn-local', at, captureOrdinal: 1,
      },
      {
        id: 'root-identity', agentID: 'root', kind: 'identity',
        providerAccess: 'codex_subscription', modelID: 'gpt-test',
        turnID: 'turn-local', at, captureOrdinal: 2,
      },
      {
        id: 'child-start', agentID: 'subagent:durable-child', agentLabel: 'Explore',
        kind: 'state', phase: 'waiting', turnID: 'turn-local', at, captureOrdinal: 3,
      },
      {
        id: 'ui-tool-projection', agentID: 'root', kind: 'tool', detail: 'Read',
        turnID: 'turn-local', at, captureOrdinal: 4,
      },
      {
        id: 'child-usage', agentID: 'subagent:durable-child', kind: 'tokens',
        inputTokens: 12, outputTokens: 3, turnID: 'turn-local', at, captureOrdinal: 5,
      },
      {
        id: 'root-context', agentID: 'root', kind: 'context',
        contextTokens: 100, contextWindow: 200, turnID: 'turn-local', at, captureOrdinal: 6,
      },
      {
        id: 'ui-compaction-projection', agentID: 'root', kind: 'compaction',
        turnID: 'turn-local', at, captureOrdinal: 8,
      },
      {
        id: 'ui-interjection-projection', agentID: 'root', kind: 'interjection',
        turnID: 'turn-local', at, captureOrdinal: 9,
      },
      {
        id: 'child-done', agentID: 'subagent:durable-child', agentLabel: 'Explore',
        kind: 'state', phase: 'completed', turnID: 'turn-local', at, captureOrdinal: 10,
      },
    ],
  }

  const canonical = canonicalFromSidecar(sidecar)
  assert.deepEqual(canonical.events.map((event) => [event.captureOrdinal, event.kind]), [
    [1, 'agent_lifecycle'],
    [2, 'agent_identity'],
    [3, 'agent_spawn'],
    [4, 'tool_call'],
    [5, 'usage'],
    [6, 'context_usage'],
    [7, 'tool_result'],
    [8, 'compaction'],
    [9, 'user_message'],
    [10, 'agent_call_result'],
  ])
  assert.equal(canonical.chronology.status, 'complete')
  assert.equal(canonical.chronology.maximumCaptureOrdinal, 10)
  assert.ok(canonical.events.every((event) => event.observedAt === at),
    'equal timestamps do not participate in chronology')

  const spawn = canonical.events.find((event) => event.kind === 'agent_spawn')
  const completion = canonical.events.find((event) => event.kind === 'agent_call_result')
  assert.deepEqual([
    spawn.eventId, spawn.spawnedAgentId, spawn.spawnProvenance,
  ], [
    'activity:child-start', 'agent-1', 'persisted-agent-activity-state',
  ])
  assert.deepEqual([
    completion.eventId, completion.completedAgentId, completion.status,
    completion.stateProvenance, completion.result,
  ], [
    'activity:child-done', 'agent-1', 'completed',
    'persisted-agent-activity-state', 'finished',
  ])
  assert.equal(canonical.events.some((event) =>
    event.eventId?.startsWith('activity:ui-')), false,
  'tool/compaction/interjection activity projections never duplicate transcript-owned facts')
  assert.deepEqual(canonicalFromSidecar(JSON.parse(JSON.stringify(sidecar))), canonical,
    'a save/relaunch-shaped JSON round trip retains the exact partial order')
})

test('activity aliases remint locally while exact parent and call correlations survive', () => {
  const rawAliases = [
    'provider-parent-call', 'provider-parent-task',
    'provider-child-call', 'provider-child-task',
    'provider-orphan-call', 'provider-missing-parent', 'provider-turn-secret',
  ]
  const sidecar = {
    subagents: {
      'provider-parent-call': {
        key: 'provider-parent-call', taskId: 'provider-parent-task',
        subagentType: 'Explore', task: 'parent work', status: 'running',
        startedCaptureOrdinal: 1,
      },
      'provider-child-call': {
        key: 'provider-child-call', taskId: 'provider-child-task',
        parentToolUseId: 'provider-parent-call', subagentType: 'Explore',
        task: 'child work', status: 'completed', resultPreview: 'done',
        startedCaptureOrdinal: 2, endedCaptureOrdinal: 4,
      },
      'provider-orphan-call': {
        key: 'provider-orphan-call', parentToolUseId: 'provider-missing-parent',
        subagentType: 'Explore', task: 'orphan work', status: 'running',
        startedCaptureOrdinal: 5,
      },
    },
    agentActivity: [
      {
        id: 'activity-1', agentID: 'subagent:provider-parent-task', kind: 'state',
        phase: 'model', turnID: 'provider-turn-secret', captureOrdinal: 1,
      },
      {
        id: 'activity-2', agentID: 'subagent:provider-child-task', kind: 'state',
        phase: 'waiting', turnID: 'provider-turn-secret', captureOrdinal: 2,
      },
      {
        id: 'activity-4', agentID: 'subagent:provider-child-task', kind: 'state',
        phase: 'completed', turnID: 'provider-turn-secret', captureOrdinal: 4,
      },
      {
        id: 'activity-5', agentID: 'subagent:provider-orphan-call', kind: 'state',
        phase: 'model', turnID: 'provider-turn-secret', captureOrdinal: 5,
      },
    ],
  }

  const canonical = canonicalFromSidecar(sidecar)
  const portable = JSON.stringify(canonical)
  for (const rawAlias of rawAliases) assert.doesNotMatch(portable, new RegExp(rawAlias))

  const parent = canonical.agents.find((agent) => agent.id === 'agent-1')
  const child = canonical.agents.find((agent) => agent.id === 'agent-2')
  const orphan = canonical.agents.find((agent) => agent.id === 'agent-3')
  assert.equal(parent.parentId, 'root')
  assert.equal(child.parentId, parent.id)
  assert.equal(orphan.parentId, null)
  assert.equal(orphan.parentageProvenance, 'unavailable-unresolved-parent-alias')

  const childSpawn = canonical.events.find((event) =>
    event.kind === 'agent_spawn' && event.spawnedAgentId === child.id)
  const childResult = canonical.events.find((event) =>
    event.kind === 'agent_call_result' && event.completedAgentId === child.id)
  assert.deepEqual([
    childSpawn.agentId, childSpawn.toolUseId,
    childResult.agentId, childResult.toolUseId, childResult.turnId,
  ], [parent.id, 'delegate-call-2', parent.id, 'delegate-call-2', 'turn-1'])
})

test('ambiguous explicit activity aliases fail instead of correlating by time or label', () => {
  assert.throws(() => canonicalFromSidecar({
    subagents: {
      first: { key: 'first', taskId: 'shared', subagentType: 'Explore', task: 'one' },
      second: { key: 'second', taskId: 'shared', subagentType: 'Explore', task: 'two' },
    },
  }), /ambiguous persisted subagent activity identity: subagent:shared/)
})
