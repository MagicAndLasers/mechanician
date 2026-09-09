import test from 'node:test'
import assert from 'node:assert/strict'
import { toCanonical } from '../canonical.mjs'
import { decodeACRRecord, encodeACR } from '../encode-acr.mjs'
import { decodeVcon, encodeVcon } from '../encode-vcon.mjs'

const at = '2026-08-03T12:00:00.000Z'
const progress = [{
  type: 'workflow_phase', index: 0, title: 'Discover', state: 'running',
}, {
  type: 'workflow_agent', index: 1, phaseIndex: 0, label: 'Researcher',
  phaseTitle: 'Discover', state: 'running', agentId: 'provider-progress-agent',
  model: 'fixture-child-model', attempt: 2, lastToolName: 'Bash',
  lastToolSummary: 'Search the workflow implementation', promptPreview: 'Inspect capture',
  tokens: 120, toolCalls: 3, resultPreview: 'Located the reducer', error: null,
  durationMs: 90,
}]
const usage = {
  totalTokens: 500, inputTokens: 300, cachedInputTokens: 50, outputTokens: 150,
  reasoningOutputTokens: 25, toolUses: 4, durationMs: 125,
  toolUsesObserved: true,
}
const rawEvents = [
  { type: 'turn_started', id: 'provider-turn' },
  {
    type: 'workflow_update', id: 'provider-turn', phase: 'progress',
    taskId: 'provider-workflow-task', toolUseId: 'provider-workflow-tool',
    isWorkflowRun: true, workflowName: 'Elegant format review', taskType: 'local_workflow',
    subagentType: 'Workflow', description: 'Review the format', summary: 'Running',
    status: 'running', model: 'fixture-root-model', usage, workflowProgress: progress,
    outputFile: '/Users/example/private/workflow-output.txt',
  },
  // The SDK array is cumulative. An identical repeat must not mint duplicate lifecycle facts.
  {
    type: 'workflow_update', id: 'provider-turn', phase: 'progress',
    taskId: 'provider-workflow-task', toolUseId: 'provider-workflow-tool',
    isWorkflowRun: true, workflowName: 'Elegant format review', taskType: 'local_workflow',
    subagentType: 'Workflow', description: 'Review the format', summary: 'Running',
    status: 'running', model: 'fixture-root-model', usage, workflowProgress: progress,
    outputFile: '/Users/example/private/workflow-output.txt',
  },
  {
    type: 'workflow_update', id: 'provider-turn', phase: 'notification',
    taskId: 'provider-workflow-task', toolUseId: 'provider-workflow-tool',
    status: 'completed', workflowProgress: [
      { ...progress[0], state: 'completed' },
      { ...progress[1], state: 'completed', resultPreview: 'Review complete', durationMs: 150 },
    ],
  },
  // A later authoritative failure may refine an optimistic success terminal.
  {
    type: 'workflow_update', id: 'provider-turn', phase: 'notification',
    taskId: 'provider-workflow-task', toolUseId: 'provider-workflow-tool',
    status: 'failed', error: 'Nested verification failed', workflowProgress: [
      { ...progress[0], state: 'failed' },
      { ...progress[1], state: 'error', error: 'Verifier failed', durationMs: 160 },
    ],
  },
  // Late provider metadata may enrich a terminal entity but cannot resurrect it.
  {
    type: 'workflow_update', id: 'provider-turn', phase: 'progress',
    taskId: 'provider-workflow-task', workflowName: 'Elegant format verification',
    status: 'running', workflowProgress: [
      { ...progress[0], state: 'running', title: 'Discover and verify' },
      {
        ...progress[1], agentId: 'provider-progress-agent-rotated', state: 'running',
        label: 'Verifier', phaseTitle: 'Discover and verify',
        resultPreview: 'Late detail', durationMs: 175,
      },
    ],
  },
  {
    type: 'workflow_update', id: 'provider-turn', phase: 'started',
    taskId: 'provider-parent-agent', toolUseId: 'provider-parent-tool',
    taskType: 'codex_subagent', subagentType: 'Codex', description: 'Parent reviewer',
    agentPath: '/root/reviewer', status: 'running', toolEvent: 'Bash',
    toolTarget: 'rg workflowProgress', usage: { reasoningOutputTokens: 9, toolUses: 1 },
  },
  {
    type: 'workflow_update', id: 'provider-turn', phase: 'started',
    taskId: 'provider-child-agent', toolUseId: 'provider-child-tool',
    parentToolUseId: 'provider-parent-tool', taskType: 'codex_subagent',
    subagentType: 'Codex', description: 'Nested verifier',
    agentPath: '/root/reviewer/verifier', status: 'running',
  },
]

const capture = {
  prompt: 'Test workflow canonical capture', promptObservedAt: at,
  producer: { name: 'test', version: '1', build: '1' },
  profile: { id: 'test', version: '1' },
  events: rawEvents.map((event, index) => ({ seq: index + 1, observedAt: at, event })),
}

function captureWith(...events) {
  return {
    prompt: 'Focused workflow capture', promptObservedAt: at,
    producer: { name: 'test', version: '1', build: '1' },
    profile: { id: 'test', version: '1' },
    events: [{ type: 'turn_started', id: 'provider-turn' }, ...events]
      .map((event, index) => ({ seq: index + 1, observedAt: at, event })),
  }
}

function withoutObservation(event) {
  const copy = structuredClone(event)
  delete copy.eventId
  delete copy.observedAt
  delete copy.timeProvenance
  return copy
}

test('workflow capture mints a distinct graph and retains every portable workflow field', () => {
  const canonical = toCanonical(capture)
  assert.equal(canonical.workflows.length, 1)
  assert.equal(canonical.workflowPhases.length, 1)
  assert.match(canonical.workflows[0].id, /^workflow-\d+$/)
  assert.match(canonical.workflowPhases[0].id, /^workflow-phase-\d+$/)
  assert.equal(canonical.workflows[0].name, undefined,
    'mutable workflow metadata belongs to lifecycle events, not identity nodes')
  assert.equal(canonical.workflows[0].providerConfirmed, undefined)
  assert.equal(canonical.workflowPhases[0].title, undefined,
    'mutable phase titles belong to lifecycle events, not identity nodes')

  const workflowAgent = canonical.agents.find((agent) => agent.workflowId)
  assert.match(workflowAgent.id, /^workflow-agent-\d+$/)
  assert.equal(workflowAgent.phaseId, canonical.workflowPhases[0].id)
  assert.equal(workflowAgent.label, undefined,
    'mutable workflow-agent labels belong to lifecycle events, not identity nodes')
  assert.equal(workflowAgent.task, undefined)

  const nested = canonical.agents.find((agent) => agent.task === 'Nested verifier')
  const parent = canonical.agents.find((agent) => agent.task === 'Parent reviewer')
  assert.equal(nested.parentId, parent.id)
  assert.deepEqual(nested.logicalAgentPath, ['reviewer', 'verifier'])
  assert.equal(nested.parentageProvenance, 'explicit-parent-tool-use-id')

  const workflowLifecycles = canonical.events.filter((event) =>
    event.kind === 'workflow_lifecycle')
  const phaseLifecycles = canonical.events.filter((event) =>
    event.kind === 'workflow_phase_lifecycle')
  const progressLifecycles = canonical.events.filter((event) =>
    event.kind === 'agent_lifecycle' && event.lifecycleScope === 'workflow-progress')
  assert.equal(workflowLifecycles[0].name, 'Elegant format review')
  assert.equal(workflowLifecycles[0].providerConfirmed, true)
  assert.equal(progressLifecycles[0].label, 'Researcher')
  assert.equal(workflowLifecycles.length, 4, 'identical cumulative update is deduped')
  assert.equal(phaseLifecycles.length, 4, 'identical cumulative phase is deduped')
  assert.equal(progressLifecycles.length, 4, 'identical cumulative agent is deduped')
  assert.equal(workflowLifecycles[2].stateProvenance,
    'provider-terminal-failure-refinement')
  assert.equal(progressLifecycles[2].stateProvenance,
    'provider-terminal-failure-refinement')
  assert.equal(workflowLifecycles.at(-1).state, 'failed')
  assert.equal(phaseLifecycles.at(-1).state, 'failed')
  assert.equal(progressLifecycles.at(-1).state, 'failed')
  assert.equal(progressLifecycles.at(-1).stateProvenance,
    'terminal-monotonic-no-resurrection')
  assert.equal(workflowLifecycles.at(-1).name, 'Elegant format verification')
  assert.equal(phaseLifecycles.at(-1).title, 'Discover and verify')
  assert.equal(progressLifecycles.at(-1).label, 'Verifier')
  assert.deepEqual(new Set(progressLifecycles.map((event) => event.agentId)),
    new Set([workflowAgent.id]), 'a provider alias rotation cannot split one workflow slot')
  assert.equal(progressLifecycles[0].attempt, 2)
  assert.equal(progressLifecycles[0].lastToolSummary, 'Search the workflow implementation')
  assert.equal(progressLifecycles[0].promptCompleteness, 'preview')
  assert.equal(progressLifecycles[0].tokens, 120)
  assert.equal(progressLifecycles[0].toolCalls, 3)
  assert.equal(progressLifecycles[0].resultCompleteness, 'preview')
  assert.equal(progressLifecycles[0].durationMs, 90)

  const workflowUsage = canonical.events.find((event) => event.kind === 'workflow_usage')
  assert.deepEqual({
    reasoning: workflowUsage.reasoningOutputTokens,
    tools: workflowUsage.toolUses,
    duration: workflowUsage.durationMs,
    observed: workflowUsage.toolUsesObserved,
  }, { reasoning: 25, tools: 4, duration: 125, observed: true })
  const tool = canonical.events.find((event) => event.kind === 'agent_tool_observation')
  assert.equal(tool.name, 'Bash')
  assert.equal(tool.toolTarget, 'rg workflowProgress')
  assert.equal(tool.completeness, 'summary-only')

  const portable = JSON.stringify(canonical)
  for (const rawHandle of [
    'provider-turn', 'provider-workflow-task', 'provider-workflow-tool',
    'provider-progress-agent', 'provider-progress-agent-rotated',
    'provider-parent-agent', 'provider-parent-tool',
    'provider-child-agent', 'provider-child-tool',
  ]) assert.equal(portable.includes(`\"${rawHandle}\"`), false, rawHandle)
  assert.doesNotMatch(portable, /workflow-output\.txt/)
  assert.doesNotMatch(portable, /\/root\/reviewer/)
})

test('provider workflow aliases cannot merge distinct phase slots', () => {
  const ambiguous = captureWith({
    type: 'workflow_update', id: 'provider-turn', taskId: 'workflow-task',
    isWorkflowRun: true, workflowProgress: [{
      type: 'workflow_agent', index: 0, phaseIndex: 0, agentId: 'reused-provider-alias',
    }, {
      type: 'workflow_agent', index: 1, phaseIndex: 0, agentId: 'reused-provider-alias',
    }],
  })
  assert.throws(() => toCanonical(ambiguous),
    /one provider workflow agent alias names two workflow slots/)
})

test('workflow recognition matches production markers and ignores an empty progress array', () => {
  const standalone = toCanonical(captureWith({
    type: 'workflow_update', id: 'provider-turn', taskId: 'child-task',
    taskType: 'codex_subagent', status: 'running', workflowProgress: [],
  }))
  assert.equal(standalone.workflows, undefined)
  assert.equal(standalone.agents.filter((agent) => agent.id !== 'root').length, 1)

  for (const marker of [
    { taskType: 'local_workflow' },
    { workflowName: 'Named workflow' },
    { workflowProgress: [{ type: 'workflow_phase', index: 0, title: 'Inspect' }] },
  ]) {
    const canonical = toCanonical(captureWith({
      type: 'workflow_update', id: 'provider-turn', taskId: 'workflow-task', ...marker,
    }))
    assert.equal(canonical.workflows.length, 1, JSON.stringify(marker))
    assert.equal(canonical.agents.filter((agent) => agent.id !== 'root').length, 0,
      JSON.stringify(marker))
  }
})

test('logical agent paths and tool targets fail closed on machine-local locators', () => {
  const hostileTargets = [
    'cat "/Users/david/private.txt"',
    'open file:///Users/david/private.txt',
    'ls /Volumes/Private/data',
    'echo $HOME/.ssh/id_ed25519',
    'type "C:\\Users\\david\\private.txt"',
    'dir "\\\\server\\share\\private.txt"',
  ]
  for (const toolTarget of hostileTargets) {
    const canonical = toCanonical(captureWith({
      type: 'workflow_update', id: 'provider-turn', taskId: 'child-task',
      taskType: 'codex_subagent', status: 'running', agentPath: '/Users/david/private-agent',
      toolEvent: 'Bash', toolTarget,
    }))
    const child = canonical.agents.find((agent) => agent.id !== 'root')
    assert.equal(child.logicalAgentPath, undefined, toolTarget)
    const observation = canonical.events.find((event) => event.kind === 'agent_tool_observation')
    assert.equal(observation.toolTarget, null, toolTarget)
    assert.equal(observation.toolTargetDisclosure, 'omitted-private-local', toolTarget)
    assert.doesNotMatch(JSON.stringify(canonical), /david|private\.txt|private-agent/, toolTarget)
  }
})

test('malformed workflow progress remains inert and mints no phase or agent identity', () => {
  const canonical = toCanonical(captureWith({
    type: 'workflow_update', id: 'provider-turn', taskId: 'workflow-task',
    isWorkflowRun: true, workflowProgress: [{
      type: 'workflow_phase', index: '0', title: 'String ordinal',
    }, {
      type: 'workflow_phase', index: { secret: 'must-not-travel' }, title: 'Object ordinal',
    }, {
      type: 'workflow_agent', index: -1, phaseIndex: 0, agentId: 'private-agent-alias',
    }, {
      type: 'workflow_agent', index: 1, agentId: 'missing-phase-alias',
    }],
  }))
  assert.equal(canonical.workflowPhases, undefined)
  assert.equal(canonical.agents.filter((agent) => agent.id !== 'root').length, 0)
  const diagnostics = canonical.events.filter((event) =>
    event.kind === 'workflow_progress_observation')
  assert.equal(diagnostics.length, 4)
  assert.ok(diagnostics.every((event) => event.recognition === 'malformed-inert'))
  assert.deepEqual(diagnostics.map((event) => event.sourceOrdinal), [null, null, null, 1])
  assert.ok(diagnostics.every((event) => event.phaseId == null))
  assert.doesNotMatch(JSON.stringify(canonical),
    /must-not-travel|private-agent-alias|missing-phase-alias/)
})

test('identical point tool observations remain distinct historical facts', () => {
  const toolUpdate = {
    type: 'workflow_update', id: 'provider-turn', taskId: 'child-task',
    taskType: 'codex_subagent', status: 'running',
    toolEvent: 'Bash', toolTarget: 'npm test',
  }
  const local = captureWith(toolUpdate)
  local.events.push({ seq: local.events.length + 1, observedAt: at,
    event: structuredClone(toolUpdate) })
  const tools = toCanonical(local).events.filter(
    (event) => event.kind === 'agent_tool_observation')
  assert.deepEqual(tools.map((event) => [event.name, event.toolTarget]), [
    ['Bash', 'npm test'], ['Bash', 'npm test'],
  ])
})

test('cumulative usage is monotonic, per-call usage is latest, and confirmation is sticky', () => {
  const local = captureWith({
    type: 'workflow_update', id: 'provider-turn', taskId: 'workflow-task',
    isWorkflowRun: true, workflowName: 'Stable name', taskType: 'local_workflow',
    description: 'Stable description', summary: 'Stable summary', status: 'running',
    model: 'stable-model', usage: {
      totalTokens: 500, toolUses: 4, durationMs: 125, toolUsesObserved: true,
      inputTokens: 300, cachedInputTokens: 50, outputTokens: 150,
      reasoningOutputTokens: 25,
    },
  })
  for (const event of [{
    type: 'workflow_update', id: 'provider-turn', taskId: 'workflow-task',
    isWorkflowRun: false, workflowName: '', description: null, summary: '', model: '',
    usage: {
      totalTokens: 450, toolUses: 3, durationMs: 80, toolUsesObserved: false,
      inputTokens: 250, cachedInputTokens: 40, outputTokens: 140,
      reasoningOutputTokens: 20,
    },
  }, {
    type: 'workflow_update', id: 'provider-turn', taskId: 'workflow-task', usage: {
      totalTokens: 550, toolUses: 6, durationMs: 140, toolUsesObserved: false,
      inputTokens: 275, cachedInputTokens: 45, outputTokens: 155,
      reasoningOutputTokens: 22,
    },
  }]) local.events.push({ seq: local.events.length + 1, observedAt: at, event })
  const canonical = toCanonical(local)
  const latest = canonical.events.filter((event) => event.kind === 'workflow_usage').at(-1)
  assert.deepEqual({
    totalTokens: latest.totalTokens, toolUses: latest.toolUses,
    durationMs: latest.durationMs, toolUsesObserved: latest.toolUsesObserved,
    inputTokens: latest.inputTokens, cachedInputTokens: latest.cachedInputTokens,
    outputTokens: latest.outputTokens, reasoningOutputTokens: latest.reasoningOutputTokens,
  }, {
    totalTokens: 550, toolUses: 6, durationMs: 140, toolUsesObserved: true,
    inputTokens: 275, cachedInputTokens: 45, outputTokens: 155,
    reasoningOutputTokens: 22,
  })
  const lifecycle = canonical.events.filter(
    (event) => event.kind === 'workflow_lifecycle').at(-1)
  assert.deepEqual([
    lifecycle.providerConfirmed, lifecycle.name, lifecycle.description,
    lifecycle.summary, lifecycle.observedModel,
  ], [true, 'Stable name', 'Stable description', 'Stable summary', 'stable-model'])
})

test('error-only workflow and child updates derive failure without rewriting reported state', () => {
  const child = {
    type: 'workflow_agent', index: 1, phaseIndex: 0, agentId: 'error-child',
    label: 'Verifier', state: 'running', model: 'child-model',
    promptPreview: 'Verify the output',
  }
  const local = captureWith({
    type: 'workflow_update', id: 'provider-turn', taskId: 'workflow-task',
    isWorkflowRun: true, workflowName: 'Failure check', status: 'running',
    description: 'Check the result', workflowProgress: [child],
  })
  local.events.push({ seq: local.events.length + 1, observedAt: at, event: {
    type: 'workflow_update', id: 'provider-turn', taskId: 'workflow-task',
    workflowName: '', description: null, error: 'Workflow verification failed',
    workflowProgress: [{
      ...child, state: undefined, label: '', model: null, promptPreview: '',
      error: 'Child verification failed',
    }],
  } })
  const canonical = toCanonical(local)
  const workflow = canonical.events.filter(
    (event) => event.kind === 'workflow_lifecycle').at(-1)
  const agent = canonical.events.filter((event) =>
    event.kind === 'agent_lifecycle' && event.lifecycleScope === 'workflow-progress').at(-1)
  for (const lifecycle of [workflow, agent]) {
    assert.equal(lifecycle.state, 'failed')
    assert.equal(lifecycle.outcome, 'failed')
    assert.equal(lifecycle.reportedState, 'running')
    assert.equal(lifecycle.stateProvenance, 'error-implied-failure')
  }
  assert.deepEqual([workflow.name, workflow.description], ['Failure check', 'Check the result'])
  assert.deepEqual([agent.label, agent.observedModel, agent.promptPreview],
    ['Verifier', 'child-model', 'Verify the output'])
})

test('VAC and vCon projections round-trip the workflow extensions', () => {
  const canonical = toCanonical(capture)
  for (const [name, decoded, ledger] of [
    ['VAC', decodeACRRecord(encodeACR(canonical).record), encodeACR(canonical).ledger],
    ['vCon', decodeVcon(encodeVcon(canonical)), encodeVcon(canonical).ledger],
  ]) {
    assert.deepEqual(decoded.workflows, canonical.workflows, `${name}: workflow nodes`)
    assert.deepEqual(decoded.workflowPhases, canonical.workflowPhases, `${name}: phase nodes`)
    const kinds = new Set([
      'workflow_lifecycle', 'workflow_usage', 'workflow_phase_lifecycle',
      'workflow_progress_observation', 'agent_tool_observation',
    ])
    assert.deepEqual(
      decoded.events.filter((event) => kinds.has(event.kind)).map(withoutObservation),
      canonical.events.filter((event) => kinds.has(event.kind)).map(withoutObservation),
      `${name}: workflow extension events`)
    assert.ok(ledger.extensions.some((entry) => entry.includes('workflow')),
      `${name}: extension dependence remains explicit`)
  }
})

test('VAC lifecycle uses one writable representation and rejects legacy conflicts', () => {
  const encoded = encodeACR(toCanonical(capture)).record
  const lifecycle = encoded.session.entries.find(
    (entry) => entry['event-type'] === 'agent-lifecycle')
  assert.deepEqual(Object.keys(lifecycle.data), ['x-canonical-event'])

  const tampered = structuredClone(encoded)
  const conflicting = tampered.session.entries.find(
    (entry) => entry['event-type'] === 'agent-lifecycle')
  conflicting.data.state = conflicting.data['x-canonical-event'].state === 'running'
    ? 'failed'
    : 'running'
  assert.throws(() => decodeACRRecord(tampered),
    /ordinary field state conflicts with x-canonical-event/)

  const legacy = structuredClone(encoded)
  const legacyEntry = legacy.session.entries.find(
    (entry) => entry['event-type'] === 'agent-lifecycle')
  const source = legacyEntry.data['x-canonical-event']
  legacyEntry.data = {
    'turn-id': source.turnId, 'agent-id': source.agentId, phase: source.phase,
    state: source.state, outcome: source.outcome, 'task-id': source.taskId,
    'tool-use-id': source.toolUseId, 'task-type': source.taskType,
    'subagent-type': source.subagentType, description: source.description,
    summary: source.summary, 'last-tool-name': source.lastToolName,
    'result-preview': source.resultPreview, 'observed-model': source.observedModel,
    usage: source.usage, error: source.error,
  }
  const decoded = decodeACRRecord(legacy).events.find(
    (event) => event.kind === 'agent_lifecycle')
  assert.equal(decoded.state, source.state)
  assert.equal(decoded.agentId, source.agentId)
})
