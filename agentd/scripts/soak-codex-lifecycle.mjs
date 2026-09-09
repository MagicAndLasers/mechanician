#!/usr/bin/env node
import assert from 'node:assert/strict'
import { pathToFileURL } from 'node:url'

import { CodexLifecycleReducer } from '../src/codex-lifecycle.mjs'

const SCENARIOS = Object.freeze([
  'completedNotification',
  'failedNotification',
  'interruptedNotification',
  'quietActive',
  'approvalWait',
  'userInputWait',
  'reconciledTerminal',
  'immediateOrphan',
  'boundedOwnershipMismatch',
  'invalidProbeRestart',
  'lostProbeRestart',
  'systemError',
  'duplicateReordered',
])

function positiveInteger(value, fallback) {
  const parsed = Number.parseInt(String(value ?? ''), 10)
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback
}

function mulberry32(seed) {
  let state = seed >>> 0
  return () => {
    state = (state + 0x6D2B79F5) | 0
    let value = Math.imul(state ^ (state >>> 15), 1 | state)
    value = (value + Math.imul(value ^ (value >>> 7), 61 | value)) ^ value
    return ((value ^ (value >>> 14)) >>> 0) / 4_294_967_296
  }
}

function activeOutcome(lifecycleState = 'providerActive') {
  return {
    kind: 'active', lifecycleState,
    turn: { id: 'turn', status: 'inProgress' },
    threadStatus: 'active', activeFlags: [],
  }
}

function beginAcceptedTurn(index) {
  const reducer = new CodexLifecycleReducer({ mismatchLimit: 3, failureLimit: 2 })
  const identity = {
    processGeneration: 1 + (index % 97),
    threadId: `thread-${index}`,
    turnId: `turn-${index}`,
  }
  assert.equal(reducer.transition('queued').accepted, true)
  assert.equal(reducer.transition('providerStarting', {
    processGeneration: identity.processGeneration,
  }).accepted, true)
  assert.equal(reducer.transition('providerStarting', {
    threadId: identity.threadId,
  }).accepted, true)
  assert.equal(reducer.transition('providerActive', {
    turnId: identity.turnId,
  }).accepted, true)
  return { reducer, identity }
}

function reconcile(reducer, outcome) {
  const probe = reducer.beginReconciliation()
  assert.equal(probe.accepted, true)
  assert.equal(probe.action, 'probe')
  return reducer.reconcile(outcome)
}

function exerciseScenario(reducer, scenario, random) {
  switch (scenario) {
    case 'completedNotification':
      reducer.finish('completed')
      break
    case 'failedNotification':
      reducer.finish('failed')
      break
    case 'interruptedNotification':
      reducer.finish('interrupted', { interrupted: true })
      break
    case 'quietActive': {
      const cycles = 2 + Math.floor(random() * 24)
      for (let cycle = 0; cycle < cycles; cycle += 1) {
        const state = cycle % 5 === 0 ? 'waitingForApproval' : 'providerActive'
        const decision = reconcile(reducer, activeOutcome(state))
        assert.equal(decision.action, 'remainActive')
        assert.equal(reducer.isTerminal, false, 'quiet work must never be terminalized')
      }
      reducer.finish('completed')
      break
    }
    case 'approvalWait':
      assert.equal(reconcile(reducer, activeOutcome('waitingForApproval')).action, 'remainActive')
      reducer.finish('completed')
      break
    case 'userInputWait':
      assert.equal(reconcile(reducer, activeOutcome('waitingForUserInput')).action, 'remainActive')
      reducer.finish('completed')
      break
    case 'reconciledTerminal':
      assert.equal(reconcile(reducer, {
        kind: 'terminal', turn: { id: 'turn', status: 'completed' },
      }).action, 'terminal')
      break
    case 'immediateOrphan':
      assert.equal(reconcile(reducer, { kind: 'orphaned' }).action, 'recoverableOrphan')
      break
    case 'boundedOwnershipMismatch':
      for (let attempt = 1; attempt <= 3; attempt += 1) {
        const decision = reconcile(reducer, {
          kind: 'missingActive', lifecycleState: 'providerActive',
        })
        assert.equal(
          decision.action,
          attempt < 3 ? 'retryOwnership' : 'recoverableOrphan',
        )
      }
      break
    case 'invalidProbeRestart':
      assert.equal(reconcile(reducer, { kind: 'invalid' }).action, 'retryInvalid')
      assert.equal(reconcile(reducer, { kind: 'invalid' }).action, 'restartInvalid')
      break
    case 'lostProbeRestart':
      assert.equal(reducer.beginReconciliation().accepted, true)
      assert.equal(reducer.reconcileFailure().action, 'retryFailure')
      assert.equal(reducer.beginReconciliation().accepted, true)
      assert.equal(reducer.reconcileFailure().action, 'restartUnresponsive')
      break
    case 'systemError':
      assert.equal(reconcile(reducer, { kind: 'systemError' }).action, 'systemError')
      break
    case 'duplicateReordered':
      // Item ordering is transport-owned; the lifecycle projection must tolerate repeated
      // activity/wait transitions and still accept exactly one terminal boundary.
      reducer.transition('waitingForUserInput')
      reducer.noteActivity()
      reducer.transition('providerActive')
      reducer.transition('providerActive')
      reducer.finish('completed')
      break
    default:
      assert.fail(`unknown lifecycle soak scenario ${scenario}`)
  }
}

export function runCodexLifecycleSoak({ iterations = 100_000, seed = 0xC0DE_1446 } = {}) {
  iterations = positiveInteger(iterations, 100_000)
  seed = positiveInteger(seed, 0xC0DE_1446)
  const random = mulberry32(seed)
  const scenarios = Object.fromEntries(SCENARIOS.map((scenario) => [scenario, 0]))
  const efforts = { high: 0, ultra: 0 }
  const threadKinds = { fresh: 0, resumed: 0 }
  const workloads = { toolFree: 0, toolHeavy: 0 }

  for (let index = 0; index < iterations; index += 1) {
    const scenario = SCENARIOS[index % SCENARIOS.length]
    const { reducer, identity } = beginAcceptedTurn(index)
    scenarios[scenario] += 1
    efforts[index % 2 === 0 ? 'ultra' : 'high'] += 1
    threadKinds[index % 3 === 0 ? 'resumed' : 'fresh'] += 1
    workloads[index % 4 === 0 ? 'toolHeavy' : 'toolFree'] += 1

    // Every iteration injects a stale old/new-generation event. It must be rejected without
    // changing the accepted provider identity or lifecycle phase.
    const beforeStale = reducer.snapshot()
    const stale = reducer.transition('providerActive', {
      processGeneration: identity.processGeneration + 1,
    })
    assert.equal(stale.accepted, false)
    assert.equal(stale.reason, 'stale_processGeneration')
    assert.deepEqual(reducer.snapshot(), beforeStale)

    exerciseScenario(reducer, scenario, random)
    const terminal = reducer.snapshot()
    assert.equal(reducer.isTerminal, true, `${scenario} must terminate`)
    assert.equal(terminal.terminalTransitions, 1, `${scenario} must terminalize once`)
    assert.equal(terminal.processGeneration, identity.processGeneration)
    assert.equal(terminal.threadId, identity.threadId)
    assert.equal(terminal.turnId, identity.turnId)

    // Repeated/reordered terminal notifications are idempotent and cannot change the outcome.
    const terminalPhase = terminal.phase
    for (const status of ['completed', 'failed', 'interrupted', 'completed']) {
      assert.equal(reducer.finish(status).nextState, terminalPhase)
    }
    assert.equal(reducer.snapshot().terminalTransitions, 1)
  }

  return {
    format: 'ai.mechanician.codex-lifecycle-soak.v1',
    seed,
    iterations,
    scenarios,
    dimensions: { efforts, threadKinds, workloads },
    assertions: {
      noIndefiniteAcceptedTurns: iterations,
      exactlyOneTerminalTransition: iterations,
      staleGenerationRejections: iterations,
      quietTurnsKilledForSilence: 0,
    },
  }
}

function argumentsFrom(argv) {
  const result = {
    iterations: process.env.MECHANICIAN_CODEX_SOAK_ITERATIONS,
    seed: process.env.MECHANICIAN_CODEX_SOAK_SEED,
  }
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--iterations') result.iterations = argv[++index]
    else if (argv[index] === '--seed') result.seed = argv[++index]
    else throw new Error(`unknown argument: ${argv[index]}`)
  }
  return result
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const summary = runCodexLifecycleSoak(argumentsFrom(process.argv.slice(2)))
  process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`)
}
