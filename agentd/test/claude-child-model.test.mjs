import test from 'node:test'
import assert from 'node:assert/strict'

import {
  claudeAgentResultMetadata,
  claudeAgentResultMetadataForMessage,
  claudeChildModelUpdate,
  claudeTaskModel,
  createClaudeTaskLifecycleTracker,
  createClaudeTaskRouteRegistry,
} from '../src/claude-message-events.mjs'

test('Claude Agent structured results distinguish launch acknowledgements from completion', () => {
  assert.deepEqual(
    claudeAgentResultMetadata({
      status: 'async_launched',
      agentId: 'child-local',
      description: 'Inspect the app',
    }, 'Agent'),
    {
      subagentResultDisposition: 'launched',
      subagentTaskId: 'child-local',
    })
  assert.deepEqual(
    claudeAgentResultMetadata({
      status: 'remote_launched',
      taskId: 'child-remote',
      sessionUrl: 'https://example.invalid/session',
    }, 'agent'),
    {
      subagentResultDisposition: 'launched',
      subagentTaskId: 'child-remote',
    })
  assert.deepEqual(
    claudeAgentResultMetadata({
      status: 'completed',
      agentId: 'child-sync',
      content: [{ type: 'text', text: 'Done' }],
    }, 'Task'),
    { subagentResultDisposition: 'completed' })
})

test('Claude Agent result metadata fails closed on unrelated or malformed output', () => {
  for (const [output, toolName] of [
    [null, 'Agent'],
    [[], 'Agent'],
    ['async_launched', 'Agent'],
    [{}, 'Agent'],
    [{ status: 'running' }, 'Agent'],
    [{ status: 200 }, 'Agent'],
    [{ status: 'async_launched' }, 'Agent'],
    [{ status: 'remote_launched' }, 'Agent'],
    [{ status: 'completed' }, 'Agent'],
    [{ status: 'async_launched', agentId: 'child' }, 'Bash'],
  ]) {
    assert.equal(claudeAgentResultMetadata(output, toolName), null)
  }
})

test('Claude Agent message metadata accepts both SDK field spellings and rejects batches', () => {
  const block = {
    type: 'tool_result',
    tool_use_id: 'tool-agent',
    content: 'launched',
  }
  assert.deepEqual(
    claudeAgentResultMetadataForMessage({
      type: 'user',
      message: { content: [block] },
      tool_use_result: { status: 'async_launched', agentId: 'child-snake' },
    }, 'Agent'),
    {
      subagentResultDisposition: 'launched',
      subagentTaskId: 'child-snake',
    })
  assert.deepEqual(
    claudeAgentResultMetadataForMessage({
      type: 'user',
      message: { content: [block] },
      toolUseResult: { status: 'async_launched', agentId: 'child-camel' },
    }, 'Agent'),
    {
      subagentResultDisposition: 'launched',
      subagentTaskId: 'child-camel',
    })
  assert.equal(claudeAgentResultMetadataForMessage({
    type: 'user',
    message: {
      content: [
        block,
        { type: 'tool_result', tool_use_id: 'tool-other', content: 'done' },
      ],
    },
    tool_use_result: { status: 'async_launched', agentId: 'ambiguous' },
  }, 'Agent'), null)
})

test('Claude child assistant frames report the actual model on the correlated task row', () => {
  const update = claudeChildModelUpdate({
    type: 'assistant',
    parent_tool_use_id: 'tool-child',
    subagent_type: 'Explore',
    task_description: 'Inspect the adapter',
    message: {
      model: 'claude-sonnet-4-5-20250929',
      content: [{ type: 'text', text: 'Found it.' }],
    },
  }, new Map([['tool-child', 'task-child']]))

  assert.deepEqual(update, {
    type: 'workflow_update',
    phase: 'progress',
    taskId: 'task-child',
    toolUseId: 'tool-child',
    model: 'claude-sonnet-4-5-20250929',
    subagentType: 'Explore',
    description: 'Inspect the adapter',
  })
})

test('Claude child model attribution safely enriches a provisional tool-use row', () => {
  const update = claudeChildModelUpdate({
    type: 'assistant',
    parent_tool_use_id: 'tool-before-task-start',
    message: { model: 'claude-opus-4-1', content: [] },
  })

  assert.equal(update.taskId, 'tool-before-task-start')
  assert.equal(update.toolUseId, 'tool-before-task-start')
  assert.equal(update.model, 'claude-opus-4-1')
})

test('Claude child model attribution never guesses from a root or malformed frame', () => {
  for (const message of [
    { type: 'assistant', parent_tool_use_id: null, message: { model: 'claude-opus-4-1' } },
    { type: 'assistant', parent_tool_use_id: 'tool-child', message: { content: [] } },
    { type: 'assistant', parent_tool_use_id: 'tool-child', message: { model: '  ' } },
    { type: 'user', parent_tool_use_id: 'tool-child', message: { model: 'claude-opus-4-1' } },
  ]) {
    assert.equal(claudeChildModelUpdate(message), null)
  }
})

test('Claude task lifecycle forwards a directly reported model without inventing one', () => {
  assert.equal(
    claudeTaskModel({ subtype: 'task_started', model: 'claude-haiku-4-5' }),
    'claude-haiku-4-5')
  assert.equal(
    claudeTaskModel({ subtype: 'task_updated', patch: { model: 'claude-sonnet-4-5' } }),
    'claude-sonnet-4-5')
  assert.equal(claudeTaskModel({ subtype: 'task_progress' }), null)
  assert.equal(claudeTaskModel({ subtype: 'task_updated', patch: { model: '' } }), null)
})

test('Claude task lifecycle hides background Bash tasks that share the task protocol', () => {
  const tracker = createClaudeTaskLifecycleTracker()
  tracker.observeToolUse('tool-bash', 'Bash')

  assert.equal(tracker.correlate({
    type: 'system',
    subtype: 'task_started',
    task_id: 'bash-task',
    tool_use_id: 'tool-bash',
    task_type: 'local_bash',
    description: 'Wait 20 seconds',
  }), null)
  assert.equal(tracker.correlate({
    type: 'system',
    subtype: 'task_progress',
    task_id: 'bash-task',
    description: 'Wait 20 seconds',
  }), null)
  assert.equal(tracker.correlate({
    type: 'system',
    subtype: 'task_notification',
    task_id: 'bash-task',
    status: 'completed',
    summary: 'Wait 20 seconds',
  }), null)
  assert.equal(tracker.taskIdByToolUse.has('tool-bash'), false)
})

test('Claude task lifecycle retains Agent identity and backfills terminal correlation', () => {
  const tracker = createClaudeTaskLifecycleTracker()
  tracker.observeToolUse('tool-agent', 'Agent')
  assert.equal(tracker.toolNameForUse('tool-agent'), 'Agent')

  assert.deepEqual(tracker.correlate({
    type: 'system',
    subtype: 'task_started',
    task_id: 'agent-task',
    tool_use_id: 'tool-agent',
    description: 'Inspect the adapter',
  }), {
    taskId: 'agent-task',
    toolUseId: 'tool-agent',
  })
  assert.equal(tracker.taskIdByToolUse.get('tool-agent'), 'agent-task')
  assert.deepEqual(tracker.correlate({
    type: 'system',
    subtype: 'task_progress',
    task_id: 'agent-task',
    subagent_type: 'Explore',
    description: 'Inspecting',
  }), {
    taskId: 'agent-task',
    toolUseId: 'tool-agent',
  })
  assert.deepEqual(tracker.correlate({
    type: 'system',
    subtype: 'task_notification',
    task_id: 'agent-task',
    status: 'completed',
  }), {
    taskId: 'agent-task',
    toolUseId: 'tool-agent',
  })
  assert.equal(tracker.taskIdByToolUse.has('tool-agent'), false)
  assert.equal(tracker.toolNameForUse('tool-agent'), null)
})

test('Claude task lifecycle keeps provider workflows without an Agent tool origin', () => {
  const tracker = createClaudeTaskLifecycleTracker()

  assert.deepEqual(tracker.correlate({
    type: 'system',
    subtype: 'task_started',
    task_id: 'workflow-task',
    task_type: 'local_workflow',
    workflow_name: 'spec',
    description: 'Run specification workflow',
  }), {
    taskId: 'workflow-task',
  })
  assert.deepEqual(tracker.correlate({
    type: 'system',
    subtype: 'task_notification',
    task_id: 'workflow-task',
    status: 'completed',
  }), {
    taskId: 'workflow-task',
  })
})

test('Claude task lifecycle accepts legacy Task tool and rejects unknown task updates', () => {
  const tracker = createClaudeTaskLifecycleTracker()
  tracker.observeToolUse('tool-task', 'Task')

  assert.deepEqual(tracker.correlate({
    type: 'system',
    subtype: 'task_started',
    task_id: 'legacy-agent',
    tool_use_id: 'tool-task',
  }), {
    taskId: 'legacy-agent',
    toolUseId: 'tool-task',
  })
  assert.equal(tracker.correlate({
    type: 'system',
    subtype: 'task_updated',
    task_id: 'unknown-background-task',
    patch: { status: 'running' },
  }), null)
})

test('Claude nested Agent start may precede its tool frame without admitting its Bash child', () => {
  const tracker = createClaudeTaskLifecycleTracker()

  // Observed in the live SDK: task_started can beat the corresponding nested Agent assistant
  // frame. subagent_type is sufficient provider evidence and retains the correlation meanwhile.
  assert.deepEqual(tracker.correlate({
    type: 'system',
    subtype: 'task_started',
    task_id: 'nested-agent',
    tool_use_id: 'tool-nested-agent',
    subagent_type: 'general-purpose',
    description: 'Nested subagent UI test',
  }), {
    taskId: 'nested-agent',
    toolUseId: 'tool-nested-agent',
  })
  tracker.observeToolUse('tool-nested-agent', 'Agent')

  // The nested agent's background Bash uses the same lifecycle protocol, but is not another agent.
  tracker.observeToolUse('tool-nested-bash', 'Bash')
  assert.equal(tracker.correlate({
    type: 'system',
    subtype: 'task_started',
    task_id: 'background-bash',
    tool_use_id: 'tool-nested-bash',
    description: 'Wait 20 seconds',
  }), null)

  assert.deepEqual(tracker.correlate({
    type: 'system',
    subtype: 'task_notification',
    task_id: 'nested-agent',
    status: 'completed',
  }), {
    taskId: 'nested-agent',
    toolUseId: 'tool-nested-agent',
  })
})

test('Claude task ownership survives the per-query tracker and terminalizes the original turn', () => {
  const routeRegistry = createClaudeTaskRouteRegistry()
  const firstTurn = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-one', conversationId: 'conversation-one' },
  })
  firstTurn.observeToolUse('tool-agent', 'Agent', { sessionId: 'session-one' })
  assert.deepEqual(firstTurn.correlate({
    type: 'system',
    subtype: 'task_started',
    session_id: 'session-one',
    task_id: 'agent-task',
    tool_use_id: 'tool-agent',
    subagent_type: 'Explore',
  }), {
    taskId: 'agent-task',
    toolUseId: 'tool-agent',
    ownerTurnId: 'turn-one',
    ownerConversationId: 'conversation-one',
  })

  const secondTurn = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-two', conversationId: 'conversation-one' },
  })
  assert.deepEqual(secondTurn.correlate({
    type: 'system',
    subtype: 'task_notification',
    session_id: 'session-one',
    task_id: 'agent-task',
    status: 'completed',
  }), {
    taskId: 'agent-task',
    toolUseId: 'tool-agent',
    ownerTurnId: 'turn-one',
    ownerConversationId: 'conversation-one',
  })
  assert.equal(routeRegistry.size, 0)
  assert.equal(secondTurn.correlate({
    type: 'system',
    subtype: 'task_notification',
    session_id: 'session-one',
    task_id: 'agent-task',
    status: 'completed',
  }), null, 'terminal cleanup makes a replay fail closed')
  assert.equal(secondTurn.correlate({
    type: 'system',
    subtype: 'task_progress',
    session_id: 'session-one',
    task_id: 'agent-task',
    tool_use_id: 'tool-agent',
    subagent_type: 'Explore',
  }), null, 'positive lifecycle fields cannot reopen a terminal provider identity')
  assert.equal(secondTurn.observeToolUse('tool-agent', 'Agent', {
    sessionId: 'session-one',
  }), false, 'a replayed Agent tool frame is suppressed by the terminal tombstone')
  assert.equal(secondTurn.observeAgentResult('tool-agent', {
    subagentResultDisposition: 'launched',
    subagentTaskId: 'agent-task',
  }, { sessionId: 'session-one' }), null)
  assert.equal(routeRegistry.size, 0)
})

test('Claude terminal observation ownership routes trailing child frames without reopening lifecycle', () => {
  const routeRegistry = createClaudeTaskRouteRegistry()
  const ownerTurn = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-owner', conversationId: 'conversation-one' },
  })
  ownerTurn.observeToolUse('tool-parent-agent', 'Agent', { sessionId: 'session-one' })
  ownerTurn.correlate({
    type: 'system', subtype: 'task_started', session_id: 'session-one',
    task_id: 'task-parent-agent', tool_use_id: 'tool-parent-agent', subagent_type: 'Explore',
  })

  const terminalTurn = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-observer', conversationId: 'conversation-one' },
  })
  assert.equal(terminalTurn.correlate({
    type: 'system', subtype: 'task_notification', session_id: 'session-one',
    task_id: 'task-parent-agent', tool_use_id: 'tool-parent-agent', status: 'completed',
  })?.ownerTurnId, 'turn-owner')
  assert.equal(routeRegistry.size, 0)
  assert.deepEqual(terminalTurn.ownerForToolUse('tool-parent-agent', 'session-one'), {
    taskId: 'task-parent-agent',
    toolUseId: 'tool-parent-agent',
    ownerTurnId: 'turn-owner',
    ownerConversationId: 'conversation-one',
  })
  assert.equal(terminalTurn.taskIdForToolUse('tool-parent-agent', 'session-one'),
    'task-parent-agent')
  assert.equal(routeRegistry.resolve({
    sessionId: 'session-one', taskId: 'task-parent-agent', toolUseId: 'tool-parent-agent',
  }), null, 'read-only terminal observation does not recreate a live lifecycle route')
  assert.equal(terminalTurn.observeToolUse('tool-parent-agent', 'Agent', {
    sessionId: 'session-one',
  }), false, 'the terminal parent identity cannot be re-admitted')

  assert.equal(terminalTurn.observeToolUse('tool-nested-agent', 'Agent', {
    sessionId: 'session-one', parentToolUseId: 'tool-parent-agent',
  }), true, 'a new nested Agent inherits the retained parent owner')
  assert.deepEqual(terminalTurn.correlate({
    type: 'system', subtype: 'task_started', session_id: 'session-one',
    task_id: 'task-nested-agent', tool_use_id: 'tool-nested-agent',
    subagent_type: 'general-purpose',
  }), {
    taskId: 'task-nested-agent',
    toolUseId: 'tool-nested-agent',
    ownerTurnId: 'turn-owner',
    ownerConversationId: 'conversation-one',
  })
})

test('Claude terminal and retired observation owners survive into a later query', () => {
  for (const boundary of ['terminal', 'retired']) {
    const routeRegistry = createClaudeTaskRouteRegistry()
    const ownerTurn = createClaudeTaskLifecycleTracker({
      routeRegistry,
      owner: { turnId: 'turn-owner' },
    })
    ownerTurn.observeToolUse('tool-agent', 'Agent', { sessionId: 'session-one' })
    ownerTurn.correlate({
      type: 'system', subtype: 'task_started', session_id: 'session-one',
      task_id: 'task-agent', tool_use_id: 'tool-agent', subagent_type: 'Explore',
    })
    if (boundary === 'terminal') {
      ownerTurn.correlate({
        type: 'system', subtype: 'task_notification', session_id: 'session-one',
        task_id: 'task-agent', tool_use_id: 'tool-agent', status: 'completed',
      })
    } else {
      const drained = routeRegistry.drainSession('session-one')
      assert.equal(drained.length, 1)
    }

    const laterQuery = createClaudeTaskLifecycleTracker({
      routeRegistry,
      owner: { turnId: 'turn-later' },
    })
    assert.equal(laterQuery.ownerForToolUse('tool-agent', 'session-one')?.ownerTurnId,
      'turn-owner', `${boundary} observation retains the launching turn`)
    assert.equal(laterQuery.taskIdForToolUse('tool-agent', 'session-one'), 'task-agent')
    assert.equal(routeRegistry.size, 0)
    assert.equal(laterQuery.correlate({
      type: 'system', subtype: 'task_progress', session_id: 'session-one',
      task_id: 'task-agent', tool_use_id: 'tool-agent', subagent_type: 'Explore',
    }), null, `${boundary} lifecycle remains terminal despite read-only observation evidence`)
  }
})

test('Claude ordinary child-tool attribution survives a split SDK query without lifecycle authority', () => {
  const routeRegistry = createClaudeTaskRouteRegistry({ maxObservationEntries: 1 })
  const ownerQuery = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-owner', conversationId: 'conversation-one' },
  })
  ownerQuery.observeToolUse('tool-parent-agent', 'Agent', { sessionId: 'session-one' })
  ownerQuery.correlate({
    type: 'system', subtype: 'task_started', session_id: 'session-one',
    task_id: 'task-parent-agent', tool_use_id: 'tool-parent-agent', subagent_type: 'Explore',
  })
  ownerQuery.observeToolUse('tool-child-read', 'Read', {
    sessionId: 'session-one', parentToolUseId: 'tool-parent-agent',
  })

  const resultQuery = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-successor', conversationId: 'conversation-one' },
  })
  assert.deepEqual(resultQuery.ownerForToolUse('tool-child-read', 'session-one'), {
    taskId: 'task-parent-agent',
    toolUseId: 'tool-child-read',
    ownerTurnId: 'turn-owner',
    ownerConversationId: 'conversation-one',
  }, 'a parentless result in the next query retains the child tool\'s immutable owner')
  assert.equal(resultQuery.correlate({
    type: 'system', subtype: 'task_started', session_id: 'session-one',
    task_id: 'ordinary-tool-task', tool_use_id: 'tool-child-read',
  }), null, 'an ordinary observation alias cannot admit Agent lifecycle')
  assert.equal(routeRegistry.size, 1)

  ownerQuery.observeToolUse('tool-child-glob', 'Glob', {
    sessionId: 'session-one', parentToolUseId: 'tool-parent-agent',
  })
  assert.equal(routeRegistry.observationSize, 1)
  assert.equal(resultQuery.ownerForToolUse('tool-child-read', 'session-one'), null,
    'the provider-session observation ledger remains bounded')
  assert.equal(resultQuery.ownerForToolUse('tool-child-glob', 'session-one')?.ownerTurnId,
    'turn-owner')
  routeRegistry.drainSession('session-one')
  assert.equal(routeRegistry.observationSize, 0)
  assert.equal(resultQuery.ownerForToolUse('tool-child-glob', 'session-one'), null,
    'session retirement clears ordinary observation aliases')
})

test('Claude observation ownership stays session-scoped and bounded', () => {
  const routeRegistry = createClaudeTaskRouteRegistry({ maxTerminalEntries: 1 })
  const tracker = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-one' },
    maxObservationEntries: 1,
  })
  for (const suffix of ['one', 'two']) {
    tracker.observeToolUse(`tool-${suffix}`, 'Agent', { sessionId: 'session-one' })
    tracker.correlate({
      type: 'system', subtype: 'task_started', session_id: 'session-one',
      task_id: `task-${suffix}`, tool_use_id: `tool-${suffix}`, subagent_type: 'Explore',
    })
    tracker.correlate({
      type: 'system', subtype: 'task_notification', session_id: 'session-one',
      task_id: `task-${suffix}`, tool_use_id: `tool-${suffix}`, status: 'completed',
    })
  }
  assert.equal(tracker.ownerForToolUse('tool-one', 'session-one'), null,
    'both query-local and provider tombstone ledgers enforce their configured bound')
  assert.equal(tracker.ownerForToolUse('tool-two', 'session-one')?.ownerTurnId, 'turn-one')

  routeRegistry.admitAgentTool({
    sessionId: 'session-two', toolUseId: 'tool-two', toolName: 'Agent',
    owner: { turnId: 'turn-two' },
  })
  assert.equal(tracker.ownerForToolUse('tool-two'), null,
    'a sessionless lookup cannot choose between a terminal and live reuse in two sessions')
  assert.equal(tracker.ownerForToolUse('tool-two', 'session-one')?.ownerTurnId, 'turn-one')
  assert.equal(tracker.ownerForToolUse('tool-two', 'session-two')?.ownerTurnId, 'turn-two')
})

test('Claude async Agent result binds a later terminal directly to the original tool owner', () => {
  const routeRegistry = createClaudeTaskRouteRegistry()
  const firstTurn = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-one' },
  })
  firstTurn.observeToolUse('tool-agent', 'Agent', { sessionId: 'session-one' })
  assert.deepEqual(firstTurn.observeAgentResult('tool-agent', {
    subagentResultDisposition: 'launched',
    subagentTaskId: 'agent-task',
  }, { sessionId: 'session-one' }), {
    taskId: 'agent-task',
    toolUseId: 'tool-agent',
    ownerTurnId: 'turn-one',
  })

  const secondTurn = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-two' },
  })
  assert.deepEqual(secondTurn.correlate({
    type: 'system',
    subtype: 'task_notification',
    session_id: 'session-one',
    task_id: 'agent-task',
    tool_use_id: 'tool-agent',
    status: 'failed',
  }), {
    taskId: 'agent-task',
    toolUseId: 'tool-agent',
    ownerTurnId: 'turn-one',
  })
})

test('Claude provider-lifetime ownership keeps unknown and colliding Bash tasks fail-closed', () => {
  const routeRegistry = createClaudeTaskRouteRegistry()
  const firstTurn = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-one' },
  })
  firstTurn.observeToolUse('tool-bash', 'Bash', { sessionId: 'session-one' })
  assert.equal(firstTurn.correlate({
    type: 'system',
    subtype: 'task_started',
    session_id: 'session-one',
    task_id: 'bash-task',
    tool_use_id: 'tool-bash',
    task_type: 'local_bash',
  }), null)

  const secondTurn = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-two' },
  })
  assert.equal(secondTurn.correlate({
    type: 'system',
    subtype: 'task_notification',
    session_id: 'session-one',
    task_id: 'bash-task',
    tool_use_id: 'tool-bash',
    status: 'completed',
  }), null)

  firstTurn.observeToolUse('reused-tool', 'Agent', { sessionId: 'session-one' })
  firstTurn.correlate({
    type: 'system',
    subtype: 'task_started',
    session_id: 'session-one',
    task_id: 'reused-task',
    tool_use_id: 'reused-tool',
    subagent_type: 'Explore',
  })
  assert.equal(secondTurn.correlate({
    type: 'system',
    subtype: 'task_started',
    session_id: 'session-one',
    task_id: 'reused-task',
    tool_use_id: 'reused-tool',
    task_type: 'local_bash',
  }), null)
  assert.equal(routeRegistry.size, 0,
    'positive local_bash evidence retires a colliding stale Agent route')
  assert.equal(secondTurn.correlate({
    type: 'system',
    subtype: 'task_notification',
    session_id: 'session-one',
    task_id: 'reused-task',
    status: 'completed',
  }), null)
})

test('Claude task routes are session-scoped and retain the first positive owner', () => {
  const routeRegistry = createClaudeTaskRouteRegistry()
  const firstTurn = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-one' },
  })
  const secondTurn = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-two' },
  })
  firstTurn.observeToolUse('shared-tool', 'Agent', { sessionId: 'session-one' })
  firstTurn.correlate({
    type: 'system', subtype: 'task_started', session_id: 'session-one',
    task_id: 'shared-task', tool_use_id: 'shared-tool', subagent_type: 'Explore',
  })
  secondTurn.observeToolUse('shared-tool', 'Agent', { sessionId: 'session-two' })
  secondTurn.correlate({
    type: 'system', subtype: 'task_started', session_id: 'session-two',
    task_id: 'shared-task', tool_use_id: 'shared-tool', subagent_type: 'Explore',
  })

  assert.deepEqual(secondTurn.correlate({
    type: 'system', subtype: 'task_progress', session_id: 'session-one',
    task_id: 'shared-task', subagent_type: 'Explore',
  }), {
    taskId: 'shared-task',
    toolUseId: 'shared-tool',
    ownerTurnId: 'turn-one',
  }, 'a later positive frame cannot overwrite the original session owner')
  assert.deepEqual(secondTurn.correlate({
    type: 'system', subtype: 'task_notification', session_id: 'session-two',
    task_id: 'shared-task', status: 'completed',
  }), {
    taskId: 'shared-task',
    toolUseId: 'shared-tool',
    ownerTurnId: 'turn-two',
  })
})

test('Claude task-route capacity fails closed and a terminal frees the slot', () => {
  const routeRegistry = createClaudeTaskRouteRegistry({ maxEntries: 1 })
  assert.deepEqual(routeRegistry.admitAgentTool({
    sessionId: 'session-one',
    toolUseId: 'tool-one',
    toolName: 'Agent',
    owner: { turnId: 'turn-one' },
  }), {
    toolUseId: 'tool-one',
    ownerTurnId: 'turn-one',
  })
  assert.equal(routeRegistry.admitAgentTool({
    sessionId: 'session-one',
    toolUseId: 'tool-two',
    toolName: 'Agent',
    owner: { turnId: 'turn-two' },
  }), null)
  assert.equal(routeRegistry.size, 1)
  assert.equal(routeRegistry.releaseTool('tool-one', 'session-one'), true)
  assert.deepEqual(routeRegistry.admitAgentTool({
    sessionId: 'session-one',
    toolUseId: 'tool-two',
    toolName: 'Agent',
    owner: { turnId: 'turn-two' },
  }), {
    toolUseId: 'tool-two',
    ownerTurnId: 'turn-two',
  })
})

test('Claude tracker suppresses an Agent card when provider-lifetime capacity is full', () => {
  const routeRegistry = createClaudeTaskRouteRegistry({ maxEntries: 1 })
  const firstTurn = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-one' },
  })
  assert.equal(firstTurn.observeToolUse('tool-one', 'Agent', {
    sessionId: 'session-one',
  }), true)

  const secondTurn = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-two' },
  })
  assert.equal(secondTurn.observeToolUse('tool-two', 'Agent', {
    sessionId: 'session-one',
  }), false, 'the unowned Agent tool frame must not reach Swift')
  assert.equal(secondTurn.toolNameForUse('tool-two', 'session-one'), null)
  assert.equal(secondTurn.observeAgentResult('tool-two', {
    subagentResultDisposition: 'launched',
    subagentTaskId: 'task-two',
  }, { sessionId: 'session-one' }), null)
  assert.equal(secondTurn.taskIdByToolUse.has('tool-two'), false)
  assert.equal(secondTurn.correlate({
    type: 'system', subtype: 'task_started', session_id: 'session-one',
    task_id: 'task-two', tool_use_id: 'tool-two', subagent_type: 'Explore',
  }), null, 'positive lifecycle prose cannot create an ownerless card after admission fails')
  assert.equal(routeRegistry.size, 1)
})

test('Claude task-start before its Agent frame shares one route and leaves no alias behind', () => {
  const routeRegistry = createClaudeTaskRouteRegistry()
  const tracker = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-one' },
  })
  assert.deepEqual(tracker.correlate({
    type: 'system', subtype: 'task_started', session_id: 'session-one',
    task_id: 'task-before-tool', tool_use_id: 'tool-after-start',
    subagent_type: 'Explore',
  }), {
    taskId: 'task-before-tool',
    toolUseId: 'tool-after-start',
    ownerTurnId: 'turn-one',
  })
  tracker.observeToolUse('tool-after-start', 'Agent', { sessionId: 'session-one' })
  assert.equal(routeRegistry.size, 1)
  assert.deepEqual(tracker.correlate({
    type: 'system', subtype: 'task_notification', session_id: 'session-one',
    task_id: 'task-before-tool', status: 'completed',
  }), {
    taskId: 'task-before-tool',
    toolUseId: 'tool-after-start',
    ownerTurnId: 'turn-one',
  })
  assert.equal(routeRegistry.size, 0)
})

test('Claude conflicting task and tool owners fail closed and terminal cleanup removes both', () => {
  const routeRegistry = createClaudeTaskRouteRegistry()
  routeRegistry.admitTask({
    sessionId: 'session-one',
    taskId: 'conflicting-task',
    owner: { turnId: 'turn-task' },
  })
  routeRegistry.admitAgentTool({
    sessionId: 'session-one',
    toolUseId: 'conflicting-tool',
    toolName: 'Agent',
    owner: { turnId: 'turn-tool' },
  })
  const tracker = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-later' },
  })
  assert.equal(tracker.correlate({
    type: 'system', subtype: 'task_progress', session_id: 'session-one',
    task_id: 'conflicting-task', tool_use_id: 'conflicting-tool',
    subagent_type: 'Explore',
  }), null)
  assert.equal(routeRegistry.size, 2)
  assert.equal(tracker.correlate({
    type: 'system', subtype: 'task_notification', session_id: 'session-one',
    task_id: 'conflicting-task', tool_use_id: 'conflicting-tool',
    subagent_type: 'Explore', status: 'failed',
  }), null)
  assert.equal(routeRegistry.size, 0)
})

test('Claude conflicting terminal tombstones every removed task/tool identity', () => {
  const routeRegistry = createClaudeTaskRouteRegistry()
  const firstOwner = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-one' },
  })
  firstOwner.observeToolUse('tool-x', 'Agent', { sessionId: 'session-one' })
  firstOwner.correlate({
    type: 'system', subtype: 'task_started', session_id: 'session-one',
    task_id: 'task-a', tool_use_id: 'tool-x', subagent_type: 'Explore',
  })
  const secondOwner = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-two' },
  })
  secondOwner.observeToolUse('tool-y', 'Agent', { sessionId: 'session-one' })
  secondOwner.correlate({
    type: 'system', subtype: 'task_started', session_id: 'session-one',
    task_id: 'task-b', tool_use_id: 'tool-y', subagent_type: 'Explore',
  })

  const laterTurn = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-later' },
  })
  assert.equal(laterTurn.correlate({
    type: 'system', subtype: 'task_notification', session_id: 'session-one',
    task_id: 'task-a', tool_use_id: 'tool-y',
    subagent_type: 'Explore', status: 'failed',
  }), null)
  assert.equal(routeRegistry.size, 0)
  assert.equal(laterTurn.correlate({
    type: 'system', subtype: 'task_progress', session_id: 'session-one',
    task_id: 'task-b', subagent_type: 'Explore',
  }), null, 'the removed task B identity cannot be re-admitted under the later turn')
  assert.equal(laterTurn.observeToolUse('tool-x', 'Agent', {
    sessionId: 'session-one',
  }), false, 'the removed tool X identity remains terminal too')
})

test('Claude one-sided task/tool alias mismatches fail closed', () => {
  for (const mismatch of ['task', 'tool']) {
    const routeRegistry = createClaudeTaskRouteRegistry()
    const owner = createClaudeTaskLifecycleTracker({
      routeRegistry,
      owner: { turnId: 'turn-owner' },
    })
    owner.observeToolUse('bound-tool', 'Agent', { sessionId: 'session-one' })
    owner.correlate({
      type: 'system', subtype: 'task_started', session_id: 'session-one',
      task_id: 'bound-task', tool_use_id: 'bound-tool', subagent_type: 'Explore',
    })
    const later = createClaudeTaskLifecycleTracker({
      routeRegistry,
      owner: { turnId: 'turn-later' },
    })
    const taskId = mismatch === 'task' ? 'different-task' : 'bound-task'
    const toolUseId = mismatch === 'tool' ? 'different-tool' : 'bound-tool'
    assert.equal(later.correlate({
      type: 'system', subtype: 'task_progress', session_id: 'session-one',
      task_id: taskId, tool_use_id: toolUseId, subagent_type: 'Explore',
    }), null, `${mismatch} identity mismatch cannot inherit the bound route owner`)
    assert.equal(routeRegistry.size, 1)
    assert.equal(later.correlate({
      type: 'system', subtype: 'task_notification', session_id: 'session-one',
      task_id: taskId, tool_use_id: toolUseId,
      subagent_type: 'Explore', status: 'failed',
    }), null)
    assert.equal(routeRegistry.size, 0)
  }
})

test('Claude terminal tombstones retain overlapping prior task and tool identities', () => {
  const routeRegistry = createClaudeTaskRouteRegistry()
  routeRegistry.terminalizeCorrelation({
    sessionId: 'session-one', taskId: 'task-one', toolUseId: 'tool-one',
  })
  routeRegistry.terminalizeCorrelation({
    sessionId: 'session-one', taskId: 'task-two', toolUseId: 'tool-two',
  })
  routeRegistry.terminalizeCorrelation({
    sessionId: 'session-one', taskId: 'task-one', toolUseId: 'tool-two',
  })
  assert.equal(routeRegistry.wasTerminal({
    taskId: 'task-one', toolUseId: 'tool-two',
  }), true, 'sessionless replay is suppressed by every overlapping terminal identity')
  assert.equal(routeRegistry.wasTerminal({ taskId: 'task-two' }), true)
  assert.equal(routeRegistry.wasTerminal({ toolUseId: 'tool-one' }), true)
})

test('Claude sessionless terminal derives its tombstone from the unique live route', () => {
  const routeRegistry = createClaudeTaskRouteRegistry()
  const firstTurn = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-one' },
  })
  firstTurn.observeToolUse('tool-agent', 'Agent', { sessionId: 'session-one' })
  firstTurn.correlate({
    type: 'system', subtype: 'task_started', session_id: 'session-one',
    task_id: 'agent-task', tool_use_id: 'tool-agent', subagent_type: 'Explore',
  })
  const laterTurn = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-two' },
  })
  assert.equal(laterTurn.correlate({
    type: 'system', subtype: 'task_notification', task_id: 'agent-task',
    status: 'completed',
  })?.ownerTurnId, 'turn-one')
  assert.equal(routeRegistry.size, 0)
  assert.equal(laterTurn.correlate({
    type: 'system', subtype: 'task_notification', task_id: 'agent-task',
    tool_use_id: 'tool-agent', subagent_type: 'Explore', status: 'completed',
  }), null)
})

test('Claude notification without a terminal status keeps ownership for the real terminal', () => {
  const routeRegistry = createClaudeTaskRouteRegistry()
  const firstTurn = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-one' },
  })
  firstTurn.observeToolUse('tool-agent', 'Agent', { sessionId: 'session-one' })
  firstTurn.correlate({
    type: 'system', subtype: 'task_started', session_id: 'session-one',
    task_id: 'agent-task', tool_use_id: 'tool-agent', subagent_type: 'Explore',
  })
  const laterTurn = createClaudeTaskLifecycleTracker({
    routeRegistry,
    owner: { turnId: 'turn-two' },
  })
  assert.equal(laterTurn.correlate({
    type: 'system', subtype: 'task_notification', session_id: 'session-one',
    task_id: 'agent-task',
  })?.ownerTurnId, 'turn-one')
  assert.equal(routeRegistry.size, 1)
  assert.equal(laterTurn.correlate({
    type: 'system', subtype: 'task_notification', session_id: 'session-one',
    task_id: 'agent-task', status: 'running',
  })?.ownerTurnId, 'turn-one')
  assert.equal(routeRegistry.size, 1)
  assert.equal(laterTurn.correlate({
    type: 'system', subtype: 'task_notification', session_id: 'session-one',
    task_id: 'agent-task', status: 'stopped',
  })?.ownerTurnId, 'turn-one')
  assert.equal(routeRegistry.size, 0)
})
