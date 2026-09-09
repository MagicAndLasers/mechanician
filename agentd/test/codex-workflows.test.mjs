import test from 'node:test'
import assert from 'node:assert/strict'
import {
  codexChildModelUpdate,
  codexCompactionEvents,
  codexObservedToolItemId,
  codexTerminalAgentPath,
  codexTerminalReport,
  codexThreadTokenSample,
  codexThreadTokenTotal,
  codexWebSearchQuery,
  codexWorkflowUpdates,
} from '../src/codex-workflows.mjs'

test('spawn starts one running Codex agent keyed to its child thread', () => {
  const [event] = codexWorkflowUpdates({
    type: 'collabAgentToolCall', id: 'call-1', tool: 'spawnAgent', status: 'inProgress',
    prompt: 'Inspect the parser', receiverThreadIds: ['thread-child'],
    agentsStates: { 'thread-child': { status: 'running', message: 'Reading files' } },
  }, 'started')

  assert.deepEqual(event, {
    type: 'workflow_update', phase: 'started', taskId: 'thread-child',
    taskType: 'codex_subagent', subagentType: 'Codex', status: 'running',
    lastToolName: 'spawnAgent', toolUseId: 'call-1',
    description: 'Inspect the parser', summary: 'Reading files',
  })
})

test('a completed spawn call keeps a still-running child active', () => {
  const [event] = codexWorkflowUpdates({
    type: 'collabAgentToolCall', id: 'call-1', tool: 'spawnAgent', status: 'completed',
    receiverThreadIds: ['thread-child'],
    agentsStates: { 'thread-child': { status: 'running' } },
  }, 'completed')

  assert.equal(event.phase, 'progress')
  assert.equal(event.status, 'running')
  assert.equal(event.toolUseId, 'call-1')
})

test('wait updates each child independently without a shared tool-use key', () => {
  const events = codexWorkflowUpdates({
    type: 'collabAgentToolCall', id: 'call-wait', tool: 'wait', status: 'completed',
    receiverThreadIds: ['thread-a', 'thread-b'],
    agentsStates: {
      'thread-a': { status: 'completed', message: 'Found the call site' },
      'thread-b': { status: 'errored', message: 'Tests failed' },
    },
  }, 'completed')

  assert.deepEqual(events.map((event) => [event.taskId, event.status, event.phase]), [
    ['thread-a', 'completed', 'notification'],
    ['thread-b', 'failed', 'notification'],
  ])
  assert.ok(events.every((event) => event.toolUseId === undefined))
})

test('supports the public app-server collabToolCall field names', () => {
  const [event] = codexWorkflowUpdates({
    type: 'collabToolCall', id: 'legacy-call', tool: 'spawnAgent', status: 'completed',
    newThreadId: 'legacy-child', agentStatus: 'interrupted', prompt: 'Review changes',
  }, 'completed')

  assert.equal(event.taskId, 'legacy-child')
  assert.equal(event.status, 'stopped')
  assert.equal(event.description, 'Review changes')
})

test('subAgentActivity supplies the authoritative child identity', () => {
  const [started] = codexWorkflowUpdates({
    type: 'subAgentActivity', id: 'activity-1', kind: 'started',
    agentThreadId: 'thread-child', agentPath: '/root/branch_check',
  }, 'completed')
  const [interrupted] = codexWorkflowUpdates({
    type: 'subAgentActivity', id: 'activity-2', kind: 'interrupted',
    agentThreadId: 'thread-child', agentPath: '/root/branch_check',
  }, 'completed')

  assert.deepEqual(started, {
    type: 'workflow_update', phase: 'started', taskId: 'thread-child',
    toolUseId: 'activity-1', taskType: 'codex_subagent', subagentType: 'Codex',
    description: 'branch check', status: 'running', lastToolName: 'started',
    agentPath: '/root/branch_check',
  })
  assert.equal(interrupted.phase, 'notification')
  assert.equal(interrupted.status, 'stopped')
})

test('Codex child model attribution uses only child-authored lifecycle metadata', () => {
  const [activity] = codexWorkflowUpdates({
    type: 'subAgentActivity', id: 'activity-1', kind: 'started',
    agentThreadId: 'thread-child', agentPath: '/root/reviewer',
    // Forward-compatible: absent from 0.144.6, but safe to retain if App Server adds it.
    model: 'gpt-5.4-codex',
  }, 'started')
  assert.equal(activity.model, 'gpt-5.4-codex')

  const [state] = codexWorkflowUpdates({
    type: 'collabAgentToolCall', id: 'wait-1', tool: 'wait', status: 'completed',
    receiverThreadIds: ['thread-child'],
    agentsStates: {
      // Forward-compatible: current CollabAgentState has status/message only.
      'thread-child': { status: 'running', model: 'gpt-5.5-codex' },
    },
  }, 'completed')
  assert.equal(state.model, 'gpt-5.5-codex')

  const [requestedOnly] = codexWorkflowUpdates({
    type: 'collabAgentToolCall', id: 'spawn-1', tool: 'spawnAgent', status: 'inProgress',
    receiverThreadIds: ['thread-child'],
    agentsStates: { 'thread-child': { status: 'running' } },
    model: 'requested-model',
  }, 'started')
  assert.equal(
    requestedOnly.model,
    undefined,
    'a requested spawn model is not proof of the child effective model')
})

test('Codex child model notifications publish effective settings and reroutes', () => {
  assert.deepEqual(codexChildModelUpdate('thread/settings/updated', {
    threadId: 'thread-child',
    threadSettings: { model: 'gpt-5.3-codex' },
  }), {
    type: 'workflow_update',
    phase: 'progress',
    taskId: 'thread-child',
    taskType: 'codex_subagent',
    subagentType: 'Codex',
    model: 'gpt-5.3-codex',
  })

  assert.equal(
    codexChildModelUpdate('model/rerouted', {
      threadId: 'thread-child',
      turnId: 'turn-child',
      fromModel: 'gpt-5.3-codex',
      toModel: 'gpt-5.4-codex',
      reason: 'highRiskCyberActivity',
    })?.model,
    'gpt-5.4-codex')
  assert.equal(codexChildModelUpdate('thread/status/changed', {
    threadId: 'thread-child',
    model: 'not-an-effective-model-field',
  }), null)
  assert.equal(codexChildModelUpdate('model/rerouted', {
    threadId: 'thread-child',
    toModel: '  ',
  }), null)
})

test('root subAgentActivity is not emitted as a delegated agent', () => {
  for (const kind of ['started', 'interacted', 'interrupted']) {
    assert.deepEqual(codexWorkflowUpdates({
      type: 'subAgentActivity', id: `root-${kind}`, kind,
      agentThreadId: 'thread-root', agentPath: '/root',
    }, kind === 'started' ? 'started' : 'completed'), [])
  }

  const [child] = codexWorkflowUpdates({
    type: 'subAgentActivity', id: 'activity-child', kind: 'started',
    agentThreadId: 'thread-child', agentPath: '/root/child',
  }, 'started')
  assert.equal(child.taskId, 'thread-child')
  assert.equal(child.agentPath, '/root/child')
  assert.equal(child.description, 'child')
})

test('ignores empty Codex wait items instead of creating ghost agents', () => {
  assert.deepEqual(codexWorkflowUpdates({
    type: 'collabAgentToolCall', id: 'wait-1', tool: 'wait', status: 'completed',
    receiverThreadIds: [], agentsStates: {},
  }, 'completed'), [])
})

test('uses a spawn call id provisionally until a child thread id arrives', () => {
  const [started] = codexWorkflowUpdates({
    type: 'collabAgentToolCall', id: 'call-1', tool: 'spawnAgent', status: 'inProgress',
    receiverThreadIds: [], agentsStates: {}, prompt: 'Trace window state',
  }, 'started')
  const [completed] = codexWorkflowUpdates({
    type: 'collabAgentToolCall', id: 'call-1', tool: 'spawnAgent', status: 'completed',
    receiverThreadIds: ['thread-child'], agentsStates: { 'thread-child': { status: 'running' } },
  }, 'completed')

  assert.equal(started.taskId, 'call-1')
  assert.equal(started.toolUseId, 'call-1')
  assert.equal(completed.taskId, 'thread-child')
  assert.equal(completed.toolUseId, 'call-1')
})

test('close and missing-agent states become terminal', () => {
  const [closed] = codexWorkflowUpdates({
    type: 'collabAgentToolCall', id: 'close-1', tool: 'closeAgent', status: 'completed',
    receiverThreadIds: ['thread-a'], agentsStates: {},
  }, 'completed')
  const [missing] = codexWorkflowUpdates({
    type: 'collabAgentToolCall', id: 'wait-1', tool: 'wait', status: 'completed',
    receiverThreadIds: ['thread-b'], agentsStates: { 'thread-b': { status: 'notFound' } },
  }, 'completed')

  assert.equal(closed.status, 'stopped')
  assert.equal(missing.status, 'failed')
})

test('failed spawn without a child preserves a useful provider explanation', () => {
  const [failed] = codexWorkflowUpdates({
    type: 'collabAgentToolCall', id: 'spawn-capacity', tool: 'spawnAgent', status: 'failed',
    prompt: 'Review the persistence layer',
    error: { code: 'agent_capacity', message: 'Parallel agent capacity is currently full.' },
    receiverThreadIds: [], agentsStates: {},
  }, 'completed')

  assert.equal(failed.taskId, 'spawn-capacity')
  assert.equal(failed.status, 'failed')
  assert.equal(failed.phase, 'notification')
  assert.equal(failed.description, 'Review the persistence layer')
  assert.equal(failed.error, 'Parallel agent capacity is currently full.')
})

test('terminal subAgentActivity kinds never remain running', () => {
  const [completed] = codexWorkflowUpdates({
    type: 'subAgentActivity', id: 'activity-complete', kind: 'completed',
    agentThreadId: 'thread-complete', agentPath: '/root/reviewer',
  }, 'completed')
  const [failed] = codexWorkflowUpdates({
    type: 'subAgentActivity', id: 'activity-failed', kind: 'errored',
    agentThreadId: 'thread-failed', agentPath: '/root/tester',
    error: { message: 'Agent capacity was exhausted.' },
  }, 'completed')

  assert.equal(completed.status, 'completed')
  assert.equal(completed.phase, 'notification')
  assert.equal(failed.status, 'failed')
  assert.equal(failed.phase, 'notification')
  assert.equal(failed.error, 'Agent capacity was exhausted.')
})

test('a child FINAL_ANSWER agent message supplies the missing terminal boundary', () => {
  const final = {
    type: 'agentMessage', author: '/root/reviewer', recipient: '/root',
    content: [{ type: 'inputText', text: 'Message Type: FINAL_ANSWER\nTask name: reviewer\nPayload:\nDone.' }],
  }
  const progress = {
    type: 'agent_message', author: '/root/reviewer', recipient: '/root',
    content: [{ type: 'input_text', text: 'Message Type: MESSAGE\nPayload:\nStill working.' }],
  }

  assert.equal(codexTerminalAgentPath(final), '/root/reviewer')
  assert.equal(codexTerminalAgentPath(progress), null)
  assert.equal(codexTerminalAgentPath({ ...final, author: '/root' }), null)
})

test('a completed web search can backfill a query omitted from its start item', () => {
  assert.equal(codexWebSearchQuery({ type: 'webSearch', id: 'search-1' }), '')
  assert.equal(codexWebSearchQuery({
    type: 'webSearch', id: 'search-1',
    query: 'macOS toolbar toggle button',
  }), 'macOS toolbar toggle button')
  assert.equal(codexWebSearchQuery({
    type: 'webSearch', id: 'search-2',
    queries: ['Anthropic OAuth callback', 'OpenAI local success page'],
  }), 'Anthropic OAuth callback · OpenAI local success page')
})

test('reads the provider-authored cumulative token total for a child thread', () => {
  assert.equal(codexThreadTokenTotal({
    total: {
      totalTokens: 12_345, inputTokens: 10_000, cachedInputTokens: 2_000,
      outputTokens: 2_345, reasoningOutputTokens: 500,
    },
    last: { totalTokens: 345 },
    modelContextWindow: 128_000,
  }), 12_345)
  assert.equal(codexThreadTokenTotal({ total: { totalTokens: 0 } }), null)
  assert.equal(codexThreadTokenTotal({ total: { totalTokens: Number.MAX_SAFE_INTEGER + 1 } }), null)
  assert.equal(codexThreadTokenTotal({ last: { totalTokens: 345 } }), null)
  assert.equal(codexThreadTokenTotal(null), null)
})

test('reads one point-in-time Codex token sample without inventing zero metrics', () => {
  assert.deepEqual(codexThreadTokenSample({
    total: { totalTokens: 9_999 },
    last: {
      totalTokens: 450,
      inputTokens: 300,
      cachedInputTokens: 100,
      outputTokens: 50,
      reasoningOutputTokens: 25,
    },
  }), {
    inputTokens: 300,
    cachedInputTokens: 100,
    outputTokens: 50,
    reasoningOutputTokens: 25,
  })
  assert.deepEqual(codexThreadTokenSample({
    last: { inputTokens: 0, outputTokens: 8 },
  }), {
    inputTokens: undefined,
    cachedInputTokens: undefined,
    outputTokens: 8,
    reasoningOutputTokens: undefined,
  })
  assert.equal(codexThreadTokenSample({ total: { totalTokens: 10 } }), null)
  assert.equal(codexThreadTokenSample(null), null)
})

test('identifies concrete child-thread tool items without counting messages or lifecycle items', () => {
  for (const type of [
    'commandExecution', 'fileChange', 'mcpToolCall', 'dynamicToolCall',
    'collabAgentToolCall', 'webSearch', 'imageView', 'sleep', 'imageGeneration',
  ]) {
    assert.equal(codexObservedToolItemId({ type, id: `id-${type}` }), `id-${type}`)
  }
  assert.equal(codexObservedToolItemId({ type: 'agentMessage', id: 'message-1' }), null)
  assert.equal(codexObservedToolItemId({ type: 'subAgentActivity', id: 'activity-1' }), null)
  assert.equal(codexObservedToolItemId({ type: 'commandExecution' }), null)
})

test('ignores non-collaboration items', () => {
  assert.deepEqual(codexWorkflowUpdates({ type: 'commandExecution', id: 'cmd-1' }, 'started'), [])
})

test('publishes Codex context compaction through the provider-neutral boundary', () => {
  const item = { type: 'contextCompaction', id: 'compact-1' }
  assert.deepEqual(codexCompactionEvents(item, 'started'), [
    { type: 'status', status: 'compacting' },
  ])
  assert.deepEqual(codexCompactionEvents(item, 'completed'), [
    { type: 'status', status: '' },
    { type: 'compact_boundary', trigger: 'provider', preTokens: null, postTokens: null },
  ])
  assert.deepEqual(codexCompactionEvents({ type: 'agentMessage', id: 'm1' }, 'completed'), [])
})

test('codexTerminalReport returns a child FINAL_ANSWER report with the envelope stripped', () => {
  const item = {
    type: 'agentMessage', author: '/root/child',
    text: 'Message Type: FINAL_ANSWER\nHere is the report.\n- one\n- two',
  }
  assert.equal(codexTerminalReport(item), 'Here is the report.\n- one\n- two')
})

test('codexTerminalReport ignores non-terminal and root messages', () => {
  assert.equal(
    codexTerminalReport({ type: 'agentMessage', author: '/root/child', text: 'just chatting' }), '')
  assert.equal(
    codexTerminalReport({ type: 'agentMessage', author: '/root', text: 'Message Type: FINAL_ANSWER\nx' }), '')
})
