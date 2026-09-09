#!/usr/bin/env node
// Deterministic format-review lifecycle fixture. `capture_quiescent` is a producer assertion emitted
// only after the root is terminal, the provider observation stream is exhausted, and every child
// observed before or after the root terminal is itself terminal.
import readline from 'node:readline'

const emit = (event) => process.stdout.write(`${JSON.stringify(event)}\n`)
const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))
const TERMINAL = new Set(['cancelled', 'completed', 'error', 'failed', 'interrupted', 'stopped'])

emit({
  type: 'ready', mode: 'fixture', provider: 'mechanician', auth: 'none', loggedIn: true,
  planType: 'test', cwd: process.cwd(),
})
emit({ type: 'allowlist', tools: [] })

let active = null

function begin(id) {
  let releaseSteering
  const steering = new Promise((resolve) => { releaseSteering = resolve })
  active = {
    id,
    root: null,
    providerExhausted: false,
    quiescent: false,
    children: new Map(),
    taskByTool: new Map(),
    parentToolByTool: new Map(),
    steeringSeen: new Set(),
    steering,
    releaseSteering,
  }
  emit({ type: 'turn_started', id })
  return active
}

function task(turn, toolUseId, description, parentToolUseId = null) {
  turn.parentToolByTool.set(toolUseId, parentToolUseId)
  emit({
    type: 'tool_use', id: turn.id, toolUseId,
    ...(parentToolUseId ? { parentToolUseId } : {}),
    name: 'Task', input: { subagent_type: 'Explore', description },
  })
}

function childParent(turn, toolUseId) {
  const parentTool = turn.parentToolByTool.get(toolUseId)
  return parentTool ? (turn.taskByTool.get(parentTool) ?? parentTool) : null
}

function workflow(turn, event) {
  const id = event.taskId ?? event.toolUseId
  if (event.toolUseId) {
    const priorID = turn.taskByTool.get(event.toolUseId)
    if (priorID && priorID !== id) {
      const provisional = turn.children.get(priorID)
      const authoritative = turn.children.get(id)
      if (provisional) {
        turn.children.set(id, authoritative ?? { ...provisional, id })
        turn.children.delete(priorID)
      }
      for (const existing of turn.children.values()) {
        if (existing.parentId === priorID) existing.parentId = id
      }
    }
    turn.taskByTool.set(event.toolUseId, id)
  }
  let child = turn.children.get(id)
  if (!child) {
    child = {
      id,
      parentId: event.toolUseId ? childParent(turn, event.toolUseId) : null,
      state: null,
    }
    turn.children.set(id, child)
  }
  // Deliberately key state only off an explicit status. Notifications can enrich metadata without
  // making a running child terminal or reviving a terminal one.
  if (event.status !== undefined) child.state = event.status
  emit({ type: 'workflow_update', id: turn.id, ...event })
  maybeQuiescent(turn)
}

function rootTerminal(turn, event) {
  turn.root = {
    type: event.type,
    id: event.id ?? turn.id,
    interrupted: event.type === 'done' && event.interrupted === true,
  }
  emit(event)
  maybeQuiescent(turn)
}

function exhaust(turn) {
  turn.providerExhausted = true
  maybeQuiescent(turn)
}

function childSummary(turn) {
  return [...turn.children.values()]
    .map(({ id, parentId, state }) => ({ id, parentId, state }))
    .sort((left, right) => left.id.localeCompare(right.id))
}

function maybeQuiescent(turn) {
  if (turn.quiescent || !turn.providerExhausted || !turn.root) return
  if ([...turn.children.values()].some((child) => !TERMINAL.has(child.state))) return
  turn.quiescent = true
  emit({
    type: 'capture_quiescent', id: turn.id, protocolVersion: 1,
    root: { ...turn.root },
    children: childSummary(turn),
  })
}

async function waitForSteering(turn) {
  // The targeted capture sends both requests as soon as it observes turn_started. The timeout keeps
  // this fixture usable by older one-way harnesses without manufacturing acknowledgements for input
  // they never sent.
  await Promise.race([turn.steering, wait(100)])
}

async function runSuccess(id) {
  const turn = begin(id)
  emit({ type: 'session', id, sessionId: 'PRIVATE-GATE-C-RESUME-HANDLE' })
  emit({
    type: 'usage', id, input: 1200, cachedInput: 400, output: 80, reasoningOutput: 20,
  })

  // A parent and its nested child are both discovered before the root terminal.
  task(turn, 'parent-tool', 'Coordinate lifecycle evidence')
  workflow(turn, {
    phase: 'started', taskId: 'parent-before-root', toolUseId: 'parent-tool',
    taskType: 'codex_subagent', subagentType: 'Explore',
    description: 'Coordinate lifecycle evidence', summary: 'Starting', status: 'running',
    model: 'gpt-fixture-parent', lastToolName: 'Read',
  })
  task(turn, 'nested-tool', 'Inspect nested lifecycle evidence', 'parent-tool')
  workflow(turn, {
    phase: 'started', taskId: 'nested-before-root', toolUseId: 'nested-tool',
    taskType: 'codex_subagent', subagentType: 'Explore',
    description: 'Inspect nested lifecycle evidence', summary: 'Starting', status: 'running',
    model: 'gpt-fixture-child', lastToolName: 'Search',
  })
  // Metadata-only: no status. Both fixture and capture state machines must keep this child running.
  workflow(turn, {
    phase: 'notification', taskId: 'nested-before-root', toolUseId: 'nested-tool',
    taskType: 'codex_subagent', subagentType: 'Explore',
    description: 'Inspect nested lifecycle evidence', summary: 'Metadata refreshed',
    model: 'gpt-fixture-child-v2', lastToolName: 'Read',
  })
  workflow(turn, {
    phase: 'notification', taskId: 'nested-before-root', toolUseId: 'nested-tool',
    taskType: 'codex_subagent', subagentType: 'Explore',
    description: 'Inspect nested lifecycle evidence', summary: 'Nested complete',
    status: 'completed', model: 'gpt-fixture-child-v2', lastToolName: 'Read',
    resultPreview: 'Nested lifecycle evidence verified.',
  })
  workflow(turn, {
    phase: 'notification', taskId: 'parent-before-root', toolUseId: 'parent-tool',
    taskType: 'codex_subagent', subagentType: 'Explore',
    description: 'Coordinate lifecycle evidence', summary: 'Parent complete',
    status: 'completed', model: 'gpt-fixture-parent', lastToolName: 'Read',
    resultPreview: 'Parent lifecycle evidence verified.',
  })

  // This child starts before the root terminal but finishes afterward.
  task(turn, 'after-tool', 'Finish after the root')
  workflow(turn, {
    phase: 'started', taskId: 'after-tool', toolUseId: 'after-tool',
    taskType: 'codex_subagent', subagentType: 'Explore',
    description: 'Finish after the root', summary: 'Running', status: 'running',
    model: 'gpt-fixture-after', lastToolName: 'Search',
  })
  // The producer learns the authoritative task id later. Capture must merge this alias instead of
  // leaving the provisional child falsely active at quiescence.
  workflow(turn, {
    phase: 'notification', taskId: 'child-after-root', toolUseId: 'after-tool',
    taskType: 'codex_subagent', subagentType: 'Explore',
    description: 'Finish after the root', summary: 'Authoritative identity learned',
    status: 'running', model: 'gpt-fixture-after', lastToolName: 'Search',
  })

  await waitForSteering(turn)
  emit({ type: 'delta', id, text: 'Root response completed while child lifecycle remained active.' })
  rootTerminal(turn, { type: 'done', id })

  workflow(turn, {
    phase: 'notification', taskId: 'child-after-root', toolUseId: 'after-tool',
    taskType: 'codex_subagent', subagentType: 'Explore',
    description: 'Finish after the root', summary: 'Complete', status: 'completed',
    model: 'gpt-fixture-after', lastToolName: 'Read',
    resultPreview: 'Post-root lifecycle evidence verified.',
    usage: {
      totalTokens: 900, inputTokens: 620, cachedInputTokens: 240, outputTokens: 280,
    },
  })

  // The provider reveals a previously unknown child only after root completion.
  workflow(turn, {
    phase: 'started', taskId: 'late-discovered-child', toolUseId: 'late-tool',
    taskType: 'codex_subagent', subagentType: 'Explore',
    description: 'Discovered after the root', summary: 'Late discovery', status: 'running',
    model: 'gpt-fixture-late', lastToolName: 'Search',
  })
  workflow(turn, {
    phase: 'notification', taskId: 'late-discovered-child', toolUseId: 'late-tool',
    taskType: 'codex_subagent', subagentType: 'Explore',
    description: 'Discovered after the root', summary: 'Late complete', status: 'completed',
    model: 'gpt-fixture-late', lastToolName: 'Read',
    resultPreview: 'Late lifecycle evidence verified.',
  })
  exhaust(turn)
}

function runError(id) {
  const turn = begin(id)
  emit({ type: 'session', id, sessionId: 'PRIVATE-GATE-C-ERROR-HANDLE' })
  rootTerminal(turn, {
    type: 'error', id, errorKind: 'usage_limit', rateLimitType: 'five_hour',
    resetsAt: 1_786_000_000, message: 'Synthetic provider limit reached.',
  })
  exhaust(turn)
}

function runInterrupted(id) {
  const turn = begin(id)
  rootTerminal(turn, { type: 'done', id, interrupted: true })
  exhaust(turn)
}

function runLateRootContent(id) {
  const turn = begin(id)
  emit({ type: 'delta', id, text: 'Valid retained root content.' })
  rootTerminal(turn, { type: 'done', id })
  emit({ type: 'delta', id, text: 'This content is invalid after the root terminal.' })
  exhaust(turn)
}

function runPrematureQuiescence(id) {
  const turn = begin(id)
  task(turn, 'active-tool', 'Still active')
  workflow(turn, {
    phase: 'started', taskId: 'active-child', toolUseId: 'active-tool',
    taskType: 'codex_subagent', subagentType: 'Explore',
    description: 'Still active', status: 'running',
  })
  rootTerminal(turn, { type: 'done', id })
  emit({
    type: 'capture_quiescent', id, protocolVersion: 1,
    root: { ...turn.root }, children: childSummary(turn),
  })
}

function receiveSteering(request) {
  const turn = active
  if (!turn || request.turnId !== turn.id || turn.root) {
    emit({
      type: 'steer_rejected', id: request.turnId, turnId: request.turnId,
      steerId: request.steerId,
    })
    return
  }
  if (request.steerId === 'steer-accepted'
      && request.prompt === 'Please include the accepted steering fact.') {
    emit({ type: 'steer_ack', id: turn.id, turnId: turn.id, steerId: request.steerId })
  } else {
    emit({ type: 'steer_rejected', id: turn.id, turnId: turn.id, steerId: request.steerId })
  }
  turn.steeringSeen.add(request.steerId)
  if (turn.steeringSeen.has('steer-accepted') && turn.steeringSeen.has('steer-rejected')) {
    turn.releaseSteering()
  }
}

const rl = readline.createInterface({ input: process.stdin })
rl.on('line', (line) => {
  let request
  try { request = JSON.parse(line) } catch { return }
  if (request.type === 'steer') {
    receiveSteering(request)
    return
  }
  if (request.type !== 'send') return
  if (request.prompt === 'malformed') process.stdout.write('{not-json}\n')
  else if (request.prompt === 'error') runError(request.id)
  else if (request.prompt === 'interrupted') runInterrupted(request.id)
  else if (request.prompt === 'late-root-content') runLateRootContent(request.id)
  else if (request.prompt === 'premature-quiescence') runPrematureQuiescence(request.id)
  else void runSuccess(request.id)
})
