#!/usr/bin/env node
import readline from 'node:readline'

const emit = (event) => process.stdout.write(`${JSON.stringify(event)}\n`)
const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))

const model = {
  id: 'claude-opus-5-usage-fixture',
  label: 'Claude Opus 5 Usage-Limit Fixture',
  isDefault: true,
  efforts: ['low', 'medium', 'high', 'max'],
  capabilities: ['effort'],
}

emit({
  type: 'ready',
  mode: 'sdk',
  provider: 'claude',
  auth: 'subscription',
  loggedIn: true,
  planType: 'max',
  cwd: process.env.MECHANICIAN_CWD || process.cwd(),
})
emit({ type: 'allowlist', tools: [] })
emit({ type: 'model_catalog', scope: '', models: [model] })

function emitRunningChild(id, {
  taskId,
  model: childModel,
  description,
}) {
  emit({
    type: 'workflow_update',
    id,
    phase: 'started',
    taskId,
    toolUseId: taskId,
    taskType: 'claude_subagent',
    subagentType: 'Explore',
    description,
    status: 'running',
    model: childModel,
    lastToolName: 'Read',
  })
}

async function runSuccessfulParentWithDelegate(id, completesInBackground) {
  emit({ type: 'turn_started', id })
  emit({ type: 'session', id, sessionId: 'claude-tools:delegate-only-fixture-thread' })
  emitRunningChild(id, {
    taskId: 'delegate-only-child',
    model: 'claude-haiku-4-5',
    description: completesInBackground
      ? 'Finishing after the parent response'
      : 'Waiting after the parent response',
  })
  emit({ type: 'delta', id, text: 'The parent is done; its child remains active. ' })
  await wait(400)
  emit({ type: 'done', id })
  if (completesInBackground) {
    await wait(2500)
    emit({
      type: 'workflow_update',
      id,
      phase: 'notification',
      taskId: 'delegate-only-child',
      toolUseId: 'delegate-only-child',
      taskType: 'claude_subagent',
      subagentType: 'Explore',
      description: 'Finished after the parent response',
      status: 'completed',
      model: 'claude-haiku-4-5',
      lastToolName: 'Read',
      resultPreview: 'Background delegate completed normally.',
    })
  }
}

async function runUsageLimitTurn(id) {
  emit({ type: 'turn_started', id })
  emit({ type: 'session', id, sessionId: 'claude-tools:usage-limit-fixture-thread' })

  for (const child of [
    {
      taskId: 'usage-child-haiku',
      model: 'claude-haiku-4-5',
      description: 'Inspecting the lifecycle path',
    },
    {
      taskId: 'usage-child-sonnet',
      model: 'claude-sonnet-4-6',
      description: 'Inspecting the provider picker',
    },
  ]) {
    emitRunningChild(id, child)
  }

  emit({
    type: 'delta',
    id,
    text: 'Two provider-owned Claude child agents are running. ',
  })
  await wait(2500)
  emit({
    type: 'error',
    id,
    errorKind: 'usage_limit',
    rateLimitType: 'five_hour',
    resetsAt: Math.floor(Date.now() / 1000) + 3600,
    message: 'Claude usage limit reached; resets later.',
  })
}

function runTurn(id, prompt) {
  if (prompt.includes('background-completes')) {
    return runSuccessfulParentWithDelegate(id, true)
  }
  if (prompt.includes('delegate-only')) {
    return runSuccessfulParentWithDelegate(id, false)
  }
  return runUsageLimitTurn(id)
}

const rl = readline.createInterface({ input: process.stdin })
rl.on('line', (line) => {
  let request
  try { request = JSON.parse(line) } catch { return }
  switch (request.type) {
    case 'ping':
      emit({ type: 'pong', id: request.id })
      break
    case 'load':
      emit({
        type: 'loaded',
        id: request.id,
        sessionId: request.sessionId || null,
        cwd: request.cwd || process.env.MECHANICIAN_CWD || process.cwd(),
      })
      break
    case 'model_catalog':
      emit({ type: 'model_catalog', id: request.id, scope: request.scope || '', models: [model] })
      break
    case 'send':
      void runTurn(request.id, request.prompt || '')
      break
    case 'interrupt':
      emit({ type: 'done', id: request.turnId || request.id, interrupted: true })
      break
    case 'reset':
      emit({ type: 'reset_ok', id: request.id })
      break
    default:
      break
  }
})
