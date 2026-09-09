#!/usr/bin/env node
import readline from 'node:readline'

const emit = (event) => process.stdout.write(`${JSON.stringify(event)}\n`)
const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))

const model = {
  id: 'gpt-5.6-parallel-fixture', label: 'GPT-5.6 Parallel Fixture', isDefault: true,
  efforts: ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'],
  capabilities: ['effort', 'ultra'],
}

emit({
  type: 'ready', mode: 'sdk', provider: 'codex', auth: 'subscription', loggedIn: true,
  planType: 'pro', cwd: process.env.MECHANICIAN_CWD || process.cwd(),
})
emit({ type: 'allowlist', tools: [] })
emit({ type: 'model_catalog', scope: '', models: [model] })

async function runTurn(id) {
  emit({ type: 'turn_started', id })
  emit({ type: 'session', id, sessionId: 'codex-tools:parallel-fixture-thread' })

  for (const [spawn, task] of [
    ['spawn-persistence', 'Inspect persistence ownership'],
    ['spawn-rendering', 'Inspect Agents panel rendering'],
  ]) {
    emit({
      type: 'workflow_update', id, phase: 'started', taskId: spawn, toolUseId: spawn,
      taskType: 'codex_subagent', subagentType: 'Codex', description: task,
      status: 'running', lastToolName: 'spawnAgent',
    })
  }

  // Reproduce App Server's out-of-order provisional/authoritative identity handoff for both
  // children. The app must collapse these four transient identities into exactly two rows.
  for (const [activity, child, summary] of [
    ['activity-persistence', 'child-persistence', 'Reviewing the conversation store'],
    ['activity-rendering', 'child-rendering', 'Reviewing the Agents surface'],
  ]) {
    emit({
      type: 'workflow_update', id, phase: 'started', taskId: child, toolUseId: activity,
      taskType: 'codex_subagent', subagentType: 'Codex', description: 'reviewer',
      summary, status: 'running', lastToolName: 'started',
    })
  }
  await wait(250)
  for (const [spawn, child] of [
    ['spawn-persistence', 'child-persistence'],
    ['spawn-rendering', 'child-rendering'],
  ]) {
    emit({
      type: 'workflow_update', id, phase: 'progress', taskId: child, toolUseId: spawn,
      taskType: 'codex_subagent', subagentType: 'Codex', status: 'running',
      lastToolName: 'wait',
    })
  }

  emit({ type: 'delta', id, text: 'Two provider-owned child agents are running in parallel. ' })
  await wait(30000)
  emit({
    type: 'workflow_update', id, phase: 'notification', taskId: 'child-persistence',
    taskType: 'codex_subagent', subagentType: 'Codex', status: 'completed',
    summary: 'Persistence ownership verified.',
  })
  emit({
    type: 'workflow_update', id, phase: 'notification', taskId: 'child-rendering',
    taskType: 'codex_subagent', subagentType: 'Codex', status: 'failed',
    error: 'Parallel agent capacity is currently full. Try again after another child completes.',
  })
  emit({ type: 'delta', id, text: 'The provider returned one completion and one capacity failure.' })
  emit({ type: 'done', id })
}

const rl = readline.createInterface({ input: process.stdin })
rl.on('line', (line) => {
  let request
  try { request = JSON.parse(line) } catch { return }
  switch (request.type) {
    case 'ping': emit({ type: 'pong', id: request.id }); break
    case 'load':
      emit({
        type: 'loaded', id: request.id, sessionId: request.sessionId || null,
        cwd: request.cwd || process.env.MECHANICIAN_CWD || process.cwd(),
      })
      break
    case 'model_catalog':
      emit({ type: 'model_catalog', id: request.id, scope: request.scope || '', models: [model] })
      break
    case 'send': void runTurn(request.id); break
    case 'interrupt': emit({ type: 'done', id: request.turnId || request.id, interrupted: true }); break
    case 'reset': emit({ type: 'reset_ok', id: request.id }); break
    default: break
  }
})
