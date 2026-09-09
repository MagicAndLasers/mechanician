#!/usr/bin/env node
// Stage A corpus seed: multi-level delegation and direct child-to-child activity.
//
// The four earlier seeds prove only root-child parallelism. This one closes the topology gap the
// Stage A kickoff review named first (root -> child -> grandchild -> great-grandchild, plus a
// child messaging a sibling), because the format review's semantic-root comparison stands on whether a
// candidate format can round-trip exactly this shape without flattening it.
//
// DOCUMENTED WIRE GAP (this is corpus evidence, not an oversight): the daemon protocol expresses
// delegation nesting via `parentToolUseId` on Task tool_use events, but direct agent-to-agent
// communication has NO first-class event. A child messaging a sibling can only appear as an
// ordinary tool call owned by the SENDER (emitted below as a `SendMessage` tool_use under
// child-a naming child-b in its input). Any candidate format mapping built from today's wire
// therefore classifies the recipient linkage as `not captured` unless the format adds it — which
// is precisely what the upstream feedback asks the ACR/Agent Session authors to make expressible.
import readline from 'node:readline'

const emit = (event) => process.stdout.write(`${JSON.stringify(event)}\n`)
const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))

const model = {
  id: 'claude-nested-delegation-fixture', label: 'Claude Nested Delegation Fixture',
  isDefault: true, efforts: [], capabilities: [],
}

emit({
  type: 'ready', mode: 'sdk', provider: 'claude', auth: 'subscription', loggedIn: true,
  cwd: process.env.MECHANICIAN_CWD || process.cwd(),
})
emit({ type: 'allowlist', tools: [] })
emit({ type: 'model_catalog', scope: '', models: [model] })

const task = (id, toolUseId, subagentType, description, parentToolUseId) => {
  const event = {
    type: 'tool_use', id, name: 'Task', toolUseId,
    input: { subagent_type: subagentType, description },
  }
  if (parentToolUseId) event.parentToolUseId = parentToolUseId
  return event
}

const result = (id, toolUseId, text, parentToolUseId) => {
  const event = { type: 'tool_result', id, toolUseId, result: text }
  if (parentToolUseId) event.parentToolUseId = parentToolUseId
  return event
}

async function runTurn(id) {
  emit({ type: 'turn_started', id })
  emit({ type: 'session', id, sessionId: 'claude:nested-delegation-thread' })
  emit({ type: 'delta', id, text: 'Fanning out a nested review. ' })

  // Level 1: the root spawns two children in parallel.
  emit(task(id, 'child-a', 'Explore', 'Survey the persistence layer'))
  emit(task(id, 'child-b', 'Plan', 'Draft the migration order'))
  await wait(120)

  // Level 2 and 3: child-a delegates downward twice — the chain a candidate format must keep
  // as a graph edge per level, not flatten into siblings of the root.
  emit(task(id, 'grandchild-a1', 'Explore', 'Enumerate sidecar writers', 'child-a'))
  await wait(80)
  emit(task(id, 'greatgrandchild-a1x', 'Explore', 'Hash the largest sidecars', 'grandchild-a1'))
  await wait(120)

  // Direct child-to-child activity: child-a tells child-b what it found. On today's wire this is
  // an ordinary tool call owned by the sender; the recipient exists only inside `input`.
  emit({
    type: 'tool_use', id, name: 'SendMessage', toolUseId: 'msg-a-to-b',
    parentToolUseId: 'child-a',
    input: { recipient: 'child-b', summary: 'Persistence survey ready for your plan' },
  })
  emit(result(id, 'msg-a-to-b', 'Delivered to child-b.', 'child-a'))
  await wait(80)

  // Deepest first, then unwind the chain; child-b closes after receiving the message.
  emit(result(id, 'greatgrandchild-a1x', 'Hashed 77 sidecars; largest 89.4 MB.', 'grandchild-a1'))
  emit(result(id, 'grandchild-a1', 'Writers enumerated: app store, ambient daemon.', 'child-a'))
  emit(result(id, 'child-a', 'Persistence survey complete.'))
  emit(result(id, 'child-b', 'Migration order drafted using the survey.'))
  emit({ type: 'delta', id, text: 'All four delegates and the cross-message completed.' })
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
