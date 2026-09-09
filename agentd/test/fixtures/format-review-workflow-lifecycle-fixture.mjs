#!/usr/bin/env node
// Deterministic format-review workflow fixture. It exercises the complete provider-neutral workflow
// surface, cumulative/reordered progress snapshots, a terminal update after the root terminal,
// and a stale cumulative live state that must not resurrect terminal work.
import readline from 'node:readline'

const emit = (event) => process.stdout.write(`${JSON.stringify(event)}\n`)

emit({
  type: 'ready', mode: 'fixture', provider: 'mechanician', auth: 'none', loggedIn: true,
  planType: 'test', cwd: process.cwd(),
})
emit({ type: 'allowlist', tools: [] })

let started = false

const phase = (title = 'Inspect') => ({ type: 'workflow_phase', index: 0, title })
const agent = (overrides = {}) => ({
  type: 'workflow_agent', index: 1, phaseIndex: 0, label: 'Inspector',
  phaseTitle: 'Inspect', state: 'start', agentId: 'PRIVATE-PROVIDER-AGENT',
  model: 'gpt-fixture-workflow', attempt: 1, lastToolName: 'Search',
  lastToolSummary: 'Finding workflow evidence.', promptPreview: 'Inspect lifecycle evidence.',
  tokens: 120, toolCalls: 1, resultPreview: '', error: '', durationMs: 125,
  ...overrides,
})

function workflowUpdate(id, fields) {
  emit({ type: 'workflow_update', id, ...fields })
}

function run(id) {
  started = true
  emit({ type: 'turn_started', id })

  emit({
    type: 'tool_use', id, toolUseId: 'parent-tool', name: 'Task',
    input: { subagent_type: 'Explore', description: 'Own the nested workflow.' },
  })
  workflowUpdate(id, {
    phase: 'started', taskId: 'parent-task', toolUseId: 'parent-tool',
    taskType: 'codex_subagent', subagentType: 'Explore',
    description: 'Own the nested workflow.', summary: 'Parent running.', status: 'running',
    model: 'gpt-fixture-parent', lastToolName: 'Read',
  })

  emit({
    type: 'tool_use', id, toolUseId: 'workflow-tool', parentToolUseId: 'parent-tool',
    name: 'Task', input: { subagent_type: 'workflow', description: 'Run workflow evidence.' },
  })
  workflowUpdate(id, {
    phase: 'started', taskId: 'workflow-task', toolUseId: 'workflow-tool',
    parentToolUseId: 'parent-tool', isWorkflowRun: true, workflowName: 'Evidence workflow',
    taskType: 'local_workflow', subagentType: 'workflow', agentPath: '/root/workflow',
    description: 'Run workflow evidence.', summary: 'Workflow starting.', status: 'running',
    model: 'gpt-fixture-workflow', toolEvent: 'Search', toolTarget: 'workflow evidence',
    toolEventID: 'PRIVATE-PROVIDER-TOOL-ITEM', providerQuerySequence: 1,
    lastToolName: 'Search', resultPreview: '',
    usage: {
      totalTokens: 120, inputTokens: 80, cachedInputTokens: 20, outputTokens: 40,
      reasoningOutputTokens: 10, toolUses: 1, durationMs: 125, toolUsesObserved: true,
    },
    workflowProgress: [phase(), agent()],
  })

  // The provider repeats the complete cumulative set in a different order.
  workflowUpdate(id, {
    phase: 'progress', taskId: 'workflow-task', toolUseId: 'workflow-tool',
    parentToolUseId: 'parent-tool', isWorkflowRun: true, workflowName: 'Evidence workflow',
    taskType: 'local_workflow', subagentType: 'workflow', agentPath: '/root/workflow',
    description: 'Run workflow evidence.', summary: 'Workflow progressing.', status: 'running',
    model: 'gpt-fixture-workflow', toolEvent: 'Read', toolTarget: 'relative/result.txt',
    lastToolName: 'Read', resultPreview: 'Partial evidence.',
    usage: {
      totalTokens: 240, inputTokens: 150, cachedInputTokens: 40, outputTokens: 90,
      reasoningOutputTokens: 25, toolUses: 2, durationMs: 250, toolUsesObserved: true,
    },
    workflowProgress: [
      agent({ state: 'progress', lastToolName: 'Read', lastToolSummary: 'Reading evidence.',
        tokens: 240, toolCalls: 2, resultPreview: 'Partial evidence.', durationMs: 250 }),
      phase(),
    ],
  })

  workflowUpdate(id, {
    phase: 'notification', taskId: 'parent-task', toolUseId: 'parent-tool',
    taskType: 'codex_subagent', subagentType: 'Explore',
    description: 'Own the nested workflow.', summary: 'Parent complete.', status: 'completed',
    model: 'gpt-fixture-parent', lastToolName: 'Read', resultPreview: 'Ownership complete.',
  })

  emit({ type: 'delta', id, text: 'The root finishes before the workflow terminal update.' })
  emit({ type: 'done', id })

  workflowUpdate(id, {
    phase: 'notification', taskId: 'workflow-task', toolUseId: 'workflow-tool',
    parentToolUseId: 'parent-tool', isWorkflowRun: true, workflowName: 'Evidence workflow',
    taskType: 'local_workflow', subagentType: 'workflow', agentPath: '/root/workflow',
    description: 'Run workflow evidence.', summary: 'Workflow failed.', status: 'failed',
    model: 'gpt-fixture-workflow', toolEvent: 'Bash', toolTarget: 'fixture command',
    lastToolName: 'Bash', resultPreview: 'Terminal evidence retained.',
    usage: {
      totalTokens: 360, inputTokens: 220, cachedInputTokens: 60, outputTokens: 140,
      reasoningOutputTokens: 45, toolUses: 3, durationMs: 500, toolUsesObserved: true,
    },
    outputFile: '/Users/private/Workflow/output.json', error: 'Synthetic workflow failure.',
    workflowProgress: [
      phase('Inspect complete'),
      agent({ state: 'error', lastToolName: 'Bash', lastToolSummary: 'Command failed.',
        tokens: 360, toolCalls: 3, resultPreview: 'Terminal evidence retained.',
        error: 'Synthetic agent failure.', durationMs: 500 }),
    ],
  })

  // A late repeated snapshot carries a stale active child state. The aggregate terminal state is
  // unchanged; reducers may enrich metrics, but must never resurrect either lifecycle.
  workflowUpdate(id, {
    phase: 'updated', taskId: 'workflow-task', toolUseId: 'workflow-tool',
    parentToolUseId: 'parent-tool', isWorkflowRun: true, workflowName: 'Evidence workflow',
    taskType: 'local_workflow', subagentType: 'workflow', agentPath: '/root/workflow',
    description: 'Run workflow evidence.', summary: 'Late cumulative snapshot.', status: 'failed',
    model: 'gpt-fixture-workflow', toolEvent: 'Bash', toolTarget: 'fixture command',
    lastToolName: 'Bash', resultPreview: 'Late metrics retained.',
    usage: {
      totalTokens: 380, inputTokens: 230, cachedInputTokens: 60, outputTokens: 150,
      reasoningOutputTokens: 50, toolUses: 3, durationMs: 525, toolUsesObserved: true,
    },
    outputFile: '/Users/private/Workflow/output.json', error: 'Synthetic workflow failure.',
    workflowProgress: [
      agent({ state: 'progress', lastToolName: 'Bash', lastToolSummary: 'Stale progress.',
        tokens: 380, toolCalls: 3, resultPreview: 'Late metrics retained.',
        error: 'Synthetic agent failure.', durationMs: 525 }),
      phase('Inspect complete'),
    ],
  })

  emit({
    type: 'capture_quiescent', id, protocolVersion: 1,
    root: { type: 'done', id, interrupted: false },
    children: [
      { id: 'parent-task', parentId: null, state: 'completed' },
      { id: 'workflow-task', parentId: 'parent-task', state: 'failed' },
    ],
  })
}

const rl = readline.createInterface({ input: process.stdin })
rl.on('line', (line) => {
  let request
  try { request = JSON.parse(line) } catch { return }
  if (request.type === 'send' && !started) run(request.id)
})
