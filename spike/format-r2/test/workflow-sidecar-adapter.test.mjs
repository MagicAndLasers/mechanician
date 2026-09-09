import test from 'node:test'
import assert from 'node:assert/strict'
import { canonicalFromSidecar } from '../canonical-from-sidecar.mjs'

test('workflow summaries form graph nodes while exact activity owns history', () => {
  const exactIdentity = 'workflow:RAW-RUN-KEY:RAW-EXACT-AGENT-KEY'
  const canonical = canonicalFromSidecar({
    workflowRuns: {
      'RAW-RUN-STORAGE-KEY': {
        runKey: 'RAW-RUN-KEY',
        sessionId: 'RAW-PROVIDER-SESSION',
        toolUseId: 'RAW-WORKFLOW-TOOL',
        runTaskId: 'RAW-WORKFLOW-TASK',
        outputFile: '/private/machine/workflow-output.json',
        workflowName: 'Repository review',
        description: 'Review the repository in two phases',
        summary: 'Review complete',
        status: 'completed',
        phases: {
          'RAW-PHASE-ONE': { index: 1, title: 'Inspect' },
          'RAW-PHASE-TWO': { index: 2, title: 'Verify' },
        },
        agents: {
          'RAW-EXACT-AGENT-KEY': {
            index: 1, label: 'Inspector', phaseIndex: 1, phaseTitle: 'Inspect',
            state: 'done', agentId: 'RAW-PROVIDER-AGENT', model: 'fixture-model', attempt: 2,
            promptPreview: 'Inspect the implementation', lastToolName: 'Read',
            lastToolSummary: 'Read the primary source', tokens: 120, toolCalls: 3,
            resultPreview: 'Inspection complete', durationMs: 900,
            startedAt: '2026-08-03T10:00:00Z', endedAt: '2026-08-03T10:00:09Z',
          },
          'RAW-SUMMARY-ONLY-AGENT-KEY': {
            index: 1, label: 'Verifier', phaseIndex: 2, phaseTitle: 'Verify',
            state: 'failed', agentId: 'RAW-SECOND-PROVIDER-AGENT', model: 'fixture-model',
            promptPreview: 'Verify the result', lastToolName: 'Bash',
            lastToolSummary: 'The check failed', tokens: 40, toolCalls: 1,
            error: 'A test failed', durationMs: 500,
            startedAt: '2026-08-03T10:00:10Z', endedAt: '2026-08-03T10:00:15Z',
          },
        },
      },
    },
    // This root transcript row is the duplicate launch/control surface for the workflow. The
    // workflow graph owns it, so its operative tool id must not become portable a second time.
    messages: [{
      id: 'launch-row', kind: 'tool', toolName: 'Task', toolUseId: 'RAW-WORKFLOW-TOOL',
      text: 'launch workflow', toolResult: 'started', captureOrdinal: 1,
    }],
    agentActivity: [
      {
        id: 'exact-start', captureOrdinal: 2, agentID: exactIdentity, kind: 'state',
        phase: 'model', detail: 'Inspecting', turnID: 'RAW-PROVIDER-TURN',
        at: '2026-08-03T10:00:01Z',
      },
      {
        id: 'exact-tool', captureOrdinal: 3, agentID: exactIdentity, kind: 'tool',
        detail: 'Read', toolTarget: 'WorkflowStore.swift', turnID: 'RAW-PROVIDER-TURN',
        at: '2026-08-03T10:00:02Z',
      },
      {
        id: 'exact-usage', captureOrdinal: 4, agentID: exactIdentity, kind: 'tokens',
        totalTokens: 100, turnID: 'RAW-PROVIDER-TURN', at: '2026-08-03T10:00:03Z',
      },
      {
        id: 'exact-end', captureOrdinal: 5, agentID: exactIdentity, kind: 'state',
        phase: 'completed', detail: 'Inspected', turnID: 'RAW-PROVIDER-TURN',
        at: '2026-08-03T10:00:09Z',
      },
    ],
  })

  const [workflow] = canonical.workflows
  const phases = canonical.workflowPhases
  const workflowAgents = canonical.agents.filter((agent) => agent.type === 'workflow-agent')
  assert.equal(workflow.ownerAgentId, 'root')
  assert.equal(workflow.name, 'Repository review')
  assert.deepEqual(phases.map((phase) => [phase.sourceOrdinal, phase.workflowId]), [
    [1, workflow.id], [2, workflow.id],
  ])
  assert.equal(workflowAgents.length, 2)
  assert.ok(workflowAgents.every((agent) => agent.parentId === 'root'))
  assert.ok(workflowAgents.every((agent) => agent.workflowId === workflow.id))
  assert.ok(workflowAgents.every((agent) => phases.some((phase) => phase.id === agent.phaseId)))
  assert.equal(canonical.agents.some(
    (agent) => agent.type === 'workflow' || agent.type === 'workflow-phase'), false)

  const exactAgent = workflowAgents.find((agent) => agent.label === 'Inspector')
  const exactLifecycle = canonical.events.filter(
    (event) => event.kind === 'agent_lifecycle' && event.agentId === exactAgent.id)
  assert.deepEqual(exactLifecycle.map((event) => [event.phase, event.state]), [
    ['model', 'model'], ['tool', null], ['completed', 'completed'],
  ])
  assert.equal(exactLifecycle.at(-1).resultPreview, 'Inspection complete')
  assert.equal(exactLifecycle.at(-1).stateProvenance, 'persisted-agent-activity-state')
  assert.equal(exactLifecycle.some((event) =>
    event.stateProvenance === 'degraded-workflow-summary-without-event-ledger-match'), false)
  const exactUsage = canonical.events.find(
    (event) => event.kind === 'usage' && event.agentId === exactAgent.id)
  assert.equal(exactUsage.totalTokens, 100, 'the activity delta remains the history fact')
  assert.equal(exactUsage.cumulativeTotalTokens, 120, 'the mutable total is labeled enrichment')
  assert.equal(exactUsage.usageSummaryProvenance,
    'persisted-mutable-workflow-summary-enrichment')

  const summaryOnlyAgent = workflowAgents.find((agent) => agent.label === 'Verifier')
  const degraded = canonical.events.filter((event) =>
    event.agentId === summaryOnlyAgent.id
      && event.stateProvenance === 'degraded-workflow-summary-without-event-ledger-match')
  assert.equal(degraded.length, 1, 'one latest-state snapshot replaces duplicate spawn/result truth')
  assert.equal(degraded[0].state, 'failed')
  assert.equal(degraded[0].outcome, 'failed')
  assert.equal(canonical.chronology.status, 'degraded')
  assert.equal(canonical.chronology.degradedWorkflowSummaryEventCount, 1)

  const portable = JSON.stringify(canonical)
  for (const raw of [
    'RAW-RUN-STORAGE-KEY', 'RAW-RUN-KEY', 'RAW-PROVIDER-SESSION',
    'RAW-WORKFLOW-TOOL', 'RAW-WORKFLOW-TASK', 'RAW-PHASE-ONE', 'RAW-PHASE-TWO',
    'RAW-EXACT-AGENT-KEY', 'RAW-SUMMARY-ONLY-AGENT-KEY',
    'RAW-PROVIDER-AGENT', 'RAW-SECOND-PROVIDER-AGENT', 'RAW-PROVIDER-TURN',
    '/private/machine/workflow-output.json',
  ]) {
    assert.equal(portable.includes(raw), false, `${raw} must remain a local correlation handle`)
  }
  assert.deepEqual(canonical.sessionIds, [])
  assert.equal(canonical.events.some((event) => event.kind === 'tool_call'), false,
    'the workflow launch row is not duplicated as a root tool history fact')
})
