import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  CodexLifecycleReducer,
  CodexLifecycleTrace,
  classifyCodexThreadRead,
  codexConversationHash,
  codexLifecycleStateForThreadStatus,
} from '../src/codex-lifecycle.mjs'

function activeOutcome(lifecycleState = 'providerActive') {
  return {
    kind: 'active', lifecycleState,
    turn: { id: 'turn-1', status: 'inProgress' },
    threadStatus: 'active', activeFlags: [],
  }
}

function startedReducer(options = {}) {
  const reducer = new CodexLifecycleReducer(options)
  assert.equal(reducer.transition('queued').accepted, true)
  assert.equal(reducer.transition('providerStarting', { processGeneration: 7 }).accepted, true)
  assert.equal(reducer.transition('providerStarting', { threadId: 'thread-1' }).accepted, true)
  assert.equal(reducer.transition('providerActive', { turnId: 'turn-1' }).accepted, true)
  return reducer
}

test('classifies an active Codex turn and its authoritative wait state', () => {
  const result = {
    thread: {
      status: { type: 'active', activeFlags: ['waitingOnApproval'] },
      turns: [{ id: 'turn-1', status: 'inProgress', items: [] }],
    },
  }
  assert.deepEqual(classifyCodexThreadRead(result, 'turn-1'), {
    kind: 'active',
    turn: result.thread.turns[0],
    threadStatus: 'active',
    activeFlags: ['waitingOnApproval'],
    lifecycleState: 'waitingForApproval',
  })
  assert.equal(
    codexLifecycleStateForThreadStatus(
      { type: 'active', activeFlags: ['waitingOnUserInput'] },
    ),
    'waitingForUserInput',
  )
})

test('classifies terminal, missing-active, orphaned, and system-error snapshots', () => {
  const completed = { id: 'turn-1', status: 'completed', items: [] }
  assert.equal(classifyCodexThreadRead({
    thread: { status: { type: 'idle' }, turns: [completed] },
  }, 'turn-1').kind, 'terminal')

  assert.deepEqual(classifyCodexThreadRead({
    thread: { status: { type: 'active', activeFlags: [] }, turns: [] },
  }, 'turn-1'), {
    kind: 'missingActive',
    threadStatus: 'active',
    activeFlags: [],
    lifecycleState: 'providerActive',
  })

  assert.equal(classifyCodexThreadRead({
    thread: { status: { type: 'idle' }, turns: [] },
  }, 'turn-1').kind, 'orphaned')
  assert.equal(classifyCodexThreadRead({
    thread: { status: { type: 'systemError' }, turns: [] },
  }, 'turn-1').kind, 'systemError')
  assert.equal(classifyCodexThreadRead({
    thread: {
      status: { type: 'idle' },
      turns: [{ id: 'turn-1', status: 'inProgress', items: [] }],
    },
  }, 'turn-1').kind, 'inconsistent')
  assert.equal(classifyCodexThreadRead({
    thread: {
      status: { type: 'systemError' },
      turns: [{ id: 'turn-1', status: 'inProgress', items: [] }],
    },
  }, 'turn-1').kind, 'systemError')
})

test('rejects thread reads that did not include turn history', () => {
  assert.deepEqual(classifyCodexThreadRead({
    thread: { status: { type: 'active', activeFlags: [] } },
  }, 'turn-1'), {
    kind: 'invalid',
    reason: 'turns_not_loaded',
    threadStatus: 'active',
    activeFlags: [],
  })
})

test('lifecycle reducer owns identity, legal phases, and exactly one terminal transition', () => {
  const reducer = startedReducer()
  assert.equal(reducer.transition('waitingForApproval').nextState, 'waitingForApproval')
  assert.equal(reducer.beginReconciliation().nextState, 'reconciling')
  assert.deepEqual(
    reducer.reconcile(activeOutcome('waitingForUserInput')),
    {
      action: 'remainActive', accepted: true, idempotent: false,
      previousState: 'reconciling', nextState: 'waitingForUserInput',
    },
  )
  assert.equal(reducer.finish('completed').nextState, 'completed')
  assert.equal(reducer.finish('completed').idempotent, true)
  assert.equal(reducer.finish('failed').nextState, 'completed')
  assert.equal(reducer.snapshot().terminalTransitions, 1)
})

test('lifecycle reducer rejects stale process and provider identities', () => {
  const reducer = startedReducer()
  assert.equal(
    reducer.transition('providerActive', { processGeneration: 8 }).reason,
    'stale_processGeneration',
  )
  assert.equal(
    reducer.transition('providerActive', { threadId: 'thread-old' }).reason,
    'stale_threadId',
  )
  assert.equal(
    reducer.transition('providerActive', { turnId: 'turn-old' }).reason,
    'stale_turnId',
  )
  assert.equal(reducer.snapshot().phase, 'providerActive')
})

test('lifecycle identity binding is atomic and real activity clears disagreement', () => {
  const reducer = new CodexLifecycleReducer({ mismatchLimit: 3 })
  assert.equal(reducer.transition('queued').accepted, true)
  const rejected = reducer.transition('providerStarting', {
    processGeneration: 7,
    threadId: 42,
  })
  assert.equal(rejected.accepted, false)
  assert.equal(rejected.reason, 'invalid_threadId')
  assert.equal(reducer.snapshot().processGeneration, null)

  assert.equal(reducer.transition('providerStarting', {
    processGeneration: 7, threadId: 'thread-1', turnId: 'turn-1',
  }).accepted, true)
  assert.equal(reducer.transition('providerActive').accepted, true)
  reducer.beginReconciliation()
  assert.equal(reducer.reconcile({
    kind: 'missingActive', lifecycleState: 'providerActive',
  }).action, 'retryOwnership')
  assert.equal(reducer.snapshot().ownershipMismatches, 1)
  reducer.noteActivity()
  assert.equal(reducer.snapshot().ownershipMismatches, 0)
})

test('quiet active reconciliation never restarts and preserves provider wait states', () => {
  const reducer = startedReducer()
  for (let index = 0; index < 100; index += 1) {
    assert.equal(reducer.beginReconciliation().action, 'probe')
    const lifecycleState = index % 2 ? 'waitingForApproval' : 'providerActive'
    const decision = reducer.reconcile(activeOutcome(lifecycleState))
    assert.equal(decision.action, 'remainActive')
    assert.equal(decision.nextState, lifecycleState)
  }
  assert.equal(reducer.snapshot().terminalTransitions, 0)
  assert.equal(reducer.snapshot().reconciliationFailures, 0)
})

test('reconciliation policy retries bounded disagreement then preserves an orphan', () => {
  const reducer = startedReducer({ mismatchLimit: 3 })
  const outcome = {
    kind: 'missingActive', lifecycleState: 'providerActive',
    threadStatus: 'active', activeFlags: [],
  }
  for (let index = 1; index <= 2; index += 1) {
    reducer.beginReconciliation()
    const decision = reducer.reconcile(outcome)
    assert.equal(decision.action, 'retryOwnership')
    assert.equal(reducer.snapshot().ownershipMismatches, index)
  }
  reducer.beginReconciliation()
  const terminal = reducer.reconcile(outcome)
  assert.equal(terminal.action, 'recoverableOrphan')
  assert.equal(terminal.nextState, 'recoverableOrphan')
  assert.equal(reducer.snapshot().terminalTransitions, 1)
})

test('reconciliation policy restarts only after bounded invalid or failed probes', () => {
  const invalid = startedReducer({ failureLimit: 2 })
  invalid.beginReconciliation()
  assert.equal(invalid.reconcile({ kind: 'invalid' }).action, 'retryInvalid')
  invalid.beginReconciliation()
  assert.equal(invalid.reconcile({ kind: 'invalid' }).action, 'restartInvalid')
  assert.equal(invalid.snapshot().phase, 'failed')

  const unavailable = startedReducer({ failureLimit: 2 })
  unavailable.beginReconciliation()
  assert.equal(unavailable.reconcileFailure().action, 'retryFailure')
  unavailable.beginReconciliation()
  assert.equal(unavailable.reconcileFailure().action, 'restartUnresponsive')
  assert.equal(unavailable.snapshot().phase, 'failed')
})

test('lifecycle trace is bounded and retains only allowlisted metadata', () => {
  const lines = []
  let monotonic = 10
  const trace = new CodexLifecycleTrace({
    runtimeId: 'runtime-1',
    codexVersion: '0.144.6',
    schemaHash: 'schema-hash',
    maxEntries: 2,
    log: (line) => lines.push(JSON.parse(line)),
    now: () => new Date('2026-07-18T12:00:00.000Z'),
    monotonicNow: () => monotonic++,
  })
  const sensitive = {
    prompt: 'do not retain me',
    output: 'secret output',
    environment: { OPENAI_API_KEY: 'secret' },
  }
  trace.record({
    clientTurnId: 'client-1',
    conversationId: 'conversation-1',
    processGeneration: 3,
    model: 'gpt-test',
    effort: 'ultra',
    threadId: 'thread-1',
    turnId: 'turn-1',
    event: 'reconcile_started',
    previousState: 'providerActive',
    nextState: 'reconciling',
    reason: 'silence',
    ...sensitive,
  })
  trace.record({ clientTurnId: 'client-1', event: 'second' })
  trace.record({
    clientTurnId: 'client-1',
    model: 'm'.repeat(512),
    threadId: 't'.repeat(512),
    event: 'third',
  })

  const entries = trace.entries()
  assert.equal(entries.length, 2)
  assert.deepEqual(entries.map((entry) => entry.event), ['second', 'third'])
  assert.equal(lines.length, 3)
  assert.equal(lines[0].conversationHash, codexConversationHash('conversation-1'))
  assert.equal(lines[0].codexVersion, '0.144.6')
  assert.equal(lines[0].schemaHash, 'schema-hash')
  assert.equal(lines[0].effort, 'ultra')
  assert.equal(entries[1].model.length, 128)
  assert.equal(entries[1].threadId.length, 128)
  assert.equal(Object.hasOwn(lines[0], 'prompt'), false)
  assert.equal(Object.hasOwn(lines[0], 'output'), false)
  assert.equal(Object.hasOwn(lines[0], 'environment'), false)
  assert.doesNotMatch(JSON.stringify(lines), /do not retain me|secret output|OPENAI_API_KEY/)

  const exported = trace.exportSnapshot()
  assert.equal(exported.format, 'ai.mechanician.codex-lifecycle.v1')
  assert.equal(exported.entryCount, 2)
  assert.equal(exported.maximumEntryCount, 2)
  assert.equal(exported.runtime.codexVersion, '0.144.6')
  assert.equal(exported.redaction.prompts, 'excluded')
  assert.doesNotMatch(
    JSON.stringify(exported),
    /do not retain me|secret output|OPENAI_API_KEY/,
  )
})
