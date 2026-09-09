#!/usr/bin/env node
// Deterministic format-review interaction/failure fixture. It exercises the provider-neutral wire in
// both directions: permission and question requests, exact response replay, acknowledgements,
// tool/child failures, a stopped child, and a real user interrupt. Private-looking locators are
// deliberately present on the wire so the portable canonical adapter can prove their omission.
import readline from 'node:readline'

const emit = (event) => process.stdout.write(`${JSON.stringify(event)}\n`)
const requestQueue = []
const waiters = []

function receive(request) {
  const index = waiters.findIndex((waiter) => waiter.predicate(request))
  if (index >= 0) {
    const [waiter] = waiters.splice(index, 1)
    clearTimeout(waiter.timer)
    waiter.resolve(request)
  } else {
    requestQueue.push(request)
  }
}

function waitForRequest(predicate, label) {
  const index = requestQueue.findIndex(predicate)
  if (index >= 0) return Promise.resolve(requestQueue.splice(index, 1)[0])
  return new Promise((resolve, reject) => {
    const waiter = { predicate, resolve, timer: null }
    waiter.timer = setTimeout(() => {
      const pendingIndex = waiters.indexOf(waiter)
      if (pendingIndex >= 0) waiters.splice(pendingIndex, 1)
      reject(new Error(`timed out waiting for ${label}`))
    }, 2000)
    waiters.push(waiter)
  })
}

emit({
  type: 'ready', mode: 'fixture', provider: 'mechanician', auth: 'none', loggedIn: true,
  planType: 'test', cwd: process.cwd(),
})
emit({ type: 'allowlist', tools: [] })

const permissionAck = (turnID, response, accepted, message = null) => emit({
  type: 'permission_response_ack', id: turnID, permissionId: response.responseId,
  accepted, allow: response.allow, always: response.always,
  ...(message ? { message } : {}),
})

async function mainLifecycle(turnID) {
  emit({ type: 'turn_started', id: turnID })
  emit({
    type: 'permission_request', id: turnID,
    permissionId: 'permission-write-escape', name: 'Bash',
    input: { command: 'printf "outside workspace\\n" > /Users/private/Outside/result.txt' },
    writeEscape: {
      target: '/Users/private/Outside/result.txt',
      workspace: '/Users/private/Workspace',
    },
  })
  const firstPermission = await waitForRequest(
    (request) => request.type === 'permission_response'
      && request.permissionId === 'permission-write-escape',
    'first write-escape permission response')
  permissionAck(turnID, firstPermission, true)
  const replayedPermission = await waitForRequest(
    (request) => request.type === 'permission_response'
      && request.permissionId === 'permission-write-escape',
    'replayed write-escape permission response')
  // Production replays the cached original acknowledgement for the same stable response id.
  permissionAck(turnID, replayedPermission, true)

  emit({
    type: 'permission_request', id: turnID,
    permissionId: 'permission-capability', name: 'mcp__capabilities__RunCapability',
    input: {
      name: 'Fixture Capability',
      command: 'cat /Users/private/OrdinaryPermission/secret.txt',
    },
    capability: {
      name: 'Fixture Capability', title: 'Fixture capability',
      description: 'Runs a deterministic fixture action.', safety: 'sensitive',
    },
  })
  const capabilityPermission = await waitForRequest(
    (request) => request.type === 'permission_response'
      && request.permissionId === 'permission-capability',
    'capability permission response')
  permissionAck(turnID, capabilityPermission, true)

  emit({
    type: 'question_request', id: turnID, reqId: 'question-output-style',
    questions: [{
      question: 'Which output style should the fixture retain?', header: 'Output',
      options: [
        { label: 'Concise', description: 'Keep the retained answer short.' },
        { label: 'Detailed', description: 'Keep additional retained context.', preview: 'Detail' },
      ], multiSelect: false,
    }],
  })
  const answer = await waitForRequest(
    (request) => request.type === 'question_response'
      && request.reqId === 'question-output-style',
    'question response')
  emit({
    type: 'question_response_ack', id: turnID, reqId: answer.reqId,
    responseId: answer.responseId, accepted: true,
  })

  emit({
    type: 'tool_use', id: turnID, toolUseId: 'ordinary-failed-tool',
    name: 'Bash', input: { command: 'exit 7' },
  })
  emit({
    type: 'tool_result', id: turnID, toolUseId: 'ordinary-failed-tool',
    status: 'error', isError: true, result: 'Process exited with status 7.',
  })

  emit({
    type: 'tool_use', id: turnID, toolUseId: 'failed-child-tool',
    name: 'Task', input: { subagent_type: 'Explore', description: 'Fail deterministically' },
  })
  emit({
    type: 'workflow_update', id: turnID, phase: 'started', taskId: 'child-failed',
    toolUseId: 'failed-child-tool', taskType: 'codex_subagent', subagentType: 'Explore',
    description: 'Fail deterministically', summary: 'Started', status: 'running',
    model: 'gpt-fixture-failed',
  })
  emit({
    type: 'workflow_update', id: turnID, phase: 'notification', taskId: 'child-failed',
    toolUseId: 'failed-child-tool', taskType: 'codex_subagent', subagentType: 'Explore',
    description: 'Fail deterministically', summary: 'Failed as requested', status: 'failed',
    model: 'gpt-fixture-failed', error: 'Synthetic child failure.',
  })

  emit({
    type: 'tool_use', id: turnID, toolUseId: 'stopped-child-tool',
    name: 'Task', input: { subagent_type: 'Explore', description: 'Stop deterministically' },
  })
  emit({
    type: 'workflow_update', id: turnID, phase: 'started', taskId: 'child-stopped',
    toolUseId: 'stopped-child-tool', taskType: 'codex_subagent', subagentType: 'Explore',
    description: 'Stop deterministically', summary: 'Started', status: 'running',
    model: 'gpt-fixture-stopped',
  })
  emit({
    type: 'workflow_update', id: turnID, phase: 'notification', taskId: 'child-stopped',
    toolUseId: 'stopped-child-tool', taskType: 'codex_subagent', subagentType: 'Explore',
    description: 'Stop deterministically', summary: 'Stopped as requested', status: 'stopped',
    model: 'gpt-fixture-stopped',
  })

  await waitForRequest(
    (request) => request.type === 'interrupt' && request.turnId === turnID,
    'root interrupt request')
  emit({ type: 'done', id: turnID, interrupted: true })
  emit({
    type: 'capture_quiescent', id: turnID, protocolVersion: 1,
    root: { type: 'done', id: turnID, interrupted: true },
    children: [
      { id: 'child-failed', parentId: null, state: 'failed' },
      { id: 'child-stopped', parentId: null, state: 'stopped' },
    ],
  })
}

async function pendingPermission(turnID) {
  emit({ type: 'turn_started', id: turnID })
  emit({
    type: 'permission_request', id: turnID, permissionId: 'permission-left-pending',
    name: 'Bash', input: { command: 'true' },
  })
  await waitForRequest(
    (request) => request.type === 'interrupt' && request.turnId === turnID,
    'pending-permission interrupt request')
  emit({
    type: 'interaction_closed', id: turnID, interactionKind: 'permission',
    requestId: 'permission-left-pending', outcome: 'cancelled', reason: 'turn_interrupted',
  })
  emit({ type: 'done', id: turnID, interrupted: true })
  emit({
    type: 'capture_quiescent', id: turnID, protocolVersion: 1,
    root: { type: 'done', id: turnID, interrupted: true }, children: [],
  })
}

async function pendingQuestion(turnID) {
  emit({ type: 'turn_started', id: turnID })
  emit({
    type: 'question_request', id: turnID, reqId: 'question-left-pending',
    questions: [{ question: 'Pending?', header: 'Pending', options: [], multiSelect: false }],
  })
  await waitForRequest(
    (request) => request.type === 'interrupt' && request.turnId === turnID,
    'pending-question interrupt request')
  emit({
    type: 'interaction_closed', id: turnID, interactionKind: 'question',
    requestId: 'question-left-pending', outcome: 'cancelled', reason: 'turn_interrupted',
  })
  emit({ type: 'done', id: turnID, interrupted: true })
  emit({
    type: 'capture_quiescent', id: turnID, protocolVersion: 1,
    root: { type: 'done', id: turnID, interrupted: true }, children: [],
  })
}

async function unacknowledgedPermission(turnID) {
  emit({ type: 'turn_started', id: turnID })
  emit({
    type: 'permission_request', id: turnID, permissionId: 'permission-unacknowledged',
    name: 'Bash', input: { command: 'true' },
  })
  await waitForRequest(
    (request) => request.type === 'permission_response'
      && request.permissionId === 'permission-unacknowledged',
    'unacknowledged permission response')
  emit({ type: 'done', id: turnID })
  emit({
    type: 'capture_quiescent', id: turnID, protocolVersion: 1,
    root: { type: 'done', id: turnID, interrupted: false }, children: [],
  })
}

let started = false
const rl = readline.createInterface({ input: process.stdin })
rl.on('line', (line) => {
  let request
  try { request = JSON.parse(line) } catch { return }
  if (request.type !== 'send') {
    receive(request)
    return
  }
  if (started) return
  started = true
  const operation = request.prompt === 'pending-permission'
    ? pendingPermission(request.id)
    : request.prompt === 'pending-question'
      ? pendingQuestion(request.id)
      : request.prompt === 'unacked-permission'
        ? unacknowledgedPermission(request.id)
        : mainLifecycle(request.id)
  operation.catch((error) => {
    emit({ type: 'error', id: request.id, errorKind: 'fixture', message: error.message })
    process.exitCode = 1
  })
})
