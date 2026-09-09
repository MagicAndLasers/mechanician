const COLLAB_ITEM_TYPES = new Set(['collabAgentToolCall', 'collabToolCall'])
const TERMINAL_STATUSES = new Set(['completed', 'failed', 'stopped'])
const OBSERVED_TOOL_ITEM_TYPES = new Set([
  'commandExecution',
  'fileChange',
  'mcpToolCall',
  'dynamicToolCall',
  'collabAgentToolCall',
  'collabToolCall',
  'webSearch',
  'imageView',
  'sleep',
  'imageGeneration',
])

function agentStatus(value) {
  switch (value) {
    case 'pendingInit': return 'pending'
    case 'running': return 'running'
    case 'completed': return 'completed'
    case 'interrupted':
    case 'shutdown': return 'stopped'
    case 'errored':
    case 'notFound': return 'failed'
    default: return null
  }
}

function receivers(item) {
  const ids = [
    ...(Array.isArray(item.receiverThreadIds) ? item.receiverThreadIds : []),
    item.receiverThreadId,
    item.newThreadId,
    ...Object.keys(item.agentsStates || {}),
  ].filter((id) => typeof id === 'string' && id)
  return [...new Set(ids)]
}

function stateFor(item, threadId) {
  const current = item.agentsStates?.[threadId]
  if (typeof current === 'string') return { status: current }
  if (current && typeof current === 'object') return current
  if (typeof item.agentStatus === 'string') return { status: item.agentStatus }
  if (item.agentStatus && typeof item.agentStatus === 'object') return item.agentStatus
  return null
}

function fallbackStatus(item, lifecycle) {
  if (item.status === 'failed') return 'failed'
  if (item.tool === 'closeAgent' && lifecycle === 'completed') return 'stopped'
  return 'running'
}

function diagnosticText(value) {
  const raw = typeof value === 'string'
    ? value
    : value && typeof value === 'object'
      ? value.message || value.detail || value.reason || value.code
      : ''
  return typeof raw === 'string' ? raw.replace(/\s+/g, ' ').trim().slice(0, 1000) : ''
}

function reportedModel(value) {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return trimmed || null
}

/// Provider-authored child model metadata on collaboration lifecycle shapes. Current
/// subAgentActivity and CollabAgentState schemas do not expose it, but accepting the field here is
/// forward-compatible. Deliberately do not fall back to the parent model or to a spawn request's
/// requested model: neither proves what the child actually ran.
export function codexReportedChildModel(item, state = null) {
  return reportedModel(state?.model) ?? reportedModel(
    item?.type === 'subAgentActivity' ? item.model : null)
}

/// Normalize the two authoritative child-thread model notifications. Thread settings supplies the
/// effective model; a reroute supersedes it with `toModel`.
export function codexChildModelUpdate(method, params) {
  const threadId = reportedModel(params?.threadId)
  if (!threadId) return null
  const model = method === 'thread/settings/updated'
    ? reportedModel(params?.threadSettings?.model)
    : method === 'model/rerouted'
      ? reportedModel(params?.toModel)
      : null
  if (!model) return null
  return {
    type: 'workflow_update',
    phase: 'progress',
    taskId: threadId,
    taskType: 'codex_subagent',
    subagentType: 'Codex',
    model,
  }
}

function failureExplanation(item, state, status) {
  if (status !== 'failed') return null
  return diagnosticText(state?.message)
    || diagnosticText(item.error)
    || diagnosticText(item.message)
    || diagnosticText(item.reason)
    || 'Codex could not start this agent. The selected model or account may not support delegation, or the provider may be at agent capacity.'
}

function subagentActivityStatus(kind) {
  switch (kind) {
    case 'completed': return 'completed'
    case 'failed':
    case 'errored': return 'failed'
    case 'interrupted':
    case 'shutdown':
    case 'stopped': return 'stopped'
    default: return 'running'
  }
}

/// Translate a Codex collaboration item into Mechanician's provider-neutral
/// standalone-subagent events. Claude's task_* messages use the same wire shape.
export function codexWorkflowUpdates(item, lifecycle) {
  if (!item || !item.id) return []

  if (item.type === 'subAgentActivity' && item.agentThreadId) {
    // App Server also reports the owning agent at /root. It already has the
    // dedicated root lane; only descendants are delegated agents.
    if (item.agentPath === '/root') return []
    const status = subagentActivityStatus(item.kind)
    const rawName = String(item.agentPath || '').split('/').filter(Boolean).pop() || 'subagent'
    const error = failureExplanation(item, null, status)
    const model = codexReportedChildModel(item)
    return [{
      type: 'workflow_update',
      phase: item.kind === 'started'
        ? 'started'
        : (TERMINAL_STATUSES.has(status) ? 'notification' : 'progress'),
      taskId: item.agentThreadId,
      toolUseId: item.kind === 'started' ? item.id : undefined,
      taskType: 'codex_subagent',
      subagentType: 'Codex',
      description: rawName.replace(/[_-]+/g, ' '),
      status,
      lastToolName: item.kind,
      // Full /root/child/grandchild path — lets the app build the agent tree (FR-93).
      ...(item.agentPath ? { agentPath: String(item.agentPath) } : {}),
      ...(model ? { model } : {}),
      ...(error ? { error } : {}),
    }]
  }

  if (!COLLAB_ITEM_TYPES.has(item.type)) return []

  const targetIds = receivers(item)
  // Current Codex releases expose child identity through subAgentActivity. Their
  // empty wait items carry no agent state and must not create ghost cards.
  if (targetIds.length === 0) {
    if (item.tool !== 'spawnAgent') return []
    targetIds.push(item.id)
  }

  return targetIds.map((taskId) => {
    const state = stateFor(item, taskId)
    const status = agentStatus(state?.status) || fallbackStatus(item, lifecycle)
    const model = codexReportedChildModel(null, state)
    const event = {
      type: 'workflow_update',
      phase: lifecycle === 'started'
        ? 'started'
        : (TERMINAL_STATUSES.has(status) ? 'notification' : 'progress'),
      taskId,
      taskType: 'codex_subagent',
      subagentType: 'Codex',
      status,
      lastToolName: item.tool || undefined,
      ...(model ? { model } : {}),
    }

    // A spawn call owns exactly one child. Keeping its item id lets a provisional
    // start (before Codex supplies the child thread id) merge into the final row.
    if (item.tool === 'spawnAgent') event.toolUseId = item.id
    if (item.tool === 'spawnAgent' && item.prompt) event.description = item.prompt
    if (state?.message) event.summary = state.message
    else if (item.tool === 'sendInput' && item.prompt) event.summary = item.prompt
    const error = failureExplanation(item, state, status)
    if (error) event.error = error

    return event
  })
}

/// What a Codex child's observed tool acted on.
///
/// The label alone collapses a child's whole timeline to "Bash", because Codex runs everything as a
/// shell command. The command is on the item already; without carrying it, an agent card can only
/// ever say "Bash 24" no matter what the agent did.
export function codexToolTarget(item) {
  switch (item?.type) {
    case 'commandExecution':
      return typeof item.command === 'string' ? item.command : ''
    case 'fileChange': {
      const changes = Array.isArray(item.changes) ? item.changes : []
      const paths = changes.map((c) => c?.path).filter((p) => typeof p === 'string')
      return paths.length ? paths.join(', ') : ''
    }
    case 'mcpToolCall':
      return [item.server, item.tool].filter(Boolean).join('.')
    case 'webSearch':
      return typeof item.query === 'string' ? item.query : ''
    default:
      return ''
  }
}

/// Friendly label for a Codex child's observed tool — used to build the agent tool timeline (FR-90),
/// mirroring the names the main-turn codexToolUse maps to.
export function codexToolLabel(item) {
  switch (item?.type) {
    case 'commandExecution': return 'Bash'
    case 'fileChange': return 'Edit'
    case 'mcpToolCall': return item.tool ? `mcp:${item.tool}` : 'MCP tool'
    case 'webSearch': return 'WebSearch'
    default: return ''
  }
}

function itemText(item) {
  if (typeof item?.text === 'string') return item.text
  if (!Array.isArray(item?.content)) return ''
  return item.content
    .map((part) => typeof part?.text === 'string' ? part.text : '')
    .filter(Boolean)
    .join('\n')
}

/// Multi-agent v2 delivers a child's final response as an agent_message rather than
/// another subAgentActivity item. Return the known agent path only for the explicit
/// terminal envelope; ordinary MESSAGE traffic must leave the child running.
export function codexTerminalAgentPath(item) {
  if (!item || (item.type !== 'agentMessage' && item.type !== 'agent_message')) return null
  const author = typeof item.author === 'string' ? item.author : ''
  if (!author || author === '/root') return null
  return /(?:^|\n)Message Type:\s*FINAL_ANSWER(?:\s|$)/.test(itemText(item)) ? author : null
}

/// A Codex subagent's final report text, taken from its FINAL_ANSWER agent_message with the
/// envelope header stripped. Empty unless this item is that terminal report — used to fill the
/// agent detail pane's Result (FR-90), since Codex delivers the report as a message, not a
/// tool_result.
export function codexTerminalReport(item) {
  if (!codexTerminalAgentPath(item)) return ''
  return itemText(item)
    .replace(/(?:^|\n)Message Type:\s*FINAL_ANSWER[^\n]*/i, '')
    .trim()
}

/// App Server can publish a webSearch start before its query is populated. Accept
/// the documented/current shapes so the completed item can backfill the action row.
export function codexWebSearchQuery(item) {
  if (!item || item.type !== 'webSearch') return ''
  const direct = [item.query, item.searchQuery, item.action?.query]
    .find((value) => typeof value === 'string' && value.trim())
  if (direct) return direct.trim()
  if (Array.isArray(item.queries)) {
    return item.queries
      .map((value) => typeof value === 'string' ? value.trim() : '')
      .filter(Boolean)
      .join(' · ')
  }
  return ''
}

/// App Server reports cumulative token usage for each thread. Child agents own their
/// own threads, so the cumulative total is the provider-authored per-child token count.
/// Reject zero/malformed values rather than turning absent metrics into a measured zero.
export function codexThreadTokenTotal(tokenUsage) {
  const value = Number(tokenUsage?.total?.totalTokens)
  return Number.isSafeInteger(value) && value > 0 ? value : null
}

/// The `last` bucket is one point-in-time model call, unlike `total`, which is cumulative for the
/// thread. Keep every reported component optional so a future/older App Server cannot turn an
/// absent metric into a measured zero.
export function codexThreadTokenSample(tokenUsage) {
  const last = tokenUsage?.last
  if (!last || typeof last !== 'object') return null
  const positive = (value) => {
    const number = Number(value)
    return Number.isSafeInteger(number) && number > 0 ? number : undefined
  }
  const sample = {
    inputTokens: positive(last.inputTokens),
    cachedInputTokens: positive(last.cachedInputTokens),
    outputTokens: positive(last.outputTokens),
    reasoningOutputTokens: positive(last.reasoningOutputTokens),
  }
  return Object.values(sample).some((value) => value != null) ? sample : null
}

/// App Server does not publish a per-child tool-call aggregate. Count only concrete,
/// uniquely identified tool/action items observed on the child thread. Callers retain
/// a Set of these ids so started/completed notifications cannot double-count a call.
export function codexObservedToolItemId(item) {
  if (!item || !OBSERVED_TOOL_ITEM_TYPES.has(item.type)) return null
  return typeof item.id === 'string' && item.id ? item.id : null
}

/// Codex publishes compaction as a first-class thread item. Translate it to the same
/// provider-neutral status/boundary events Claude uses so the app can persist one honest card.
export function codexCompactionEvents(item, lifecycle) {
  if (!item || item.type !== 'contextCompaction') return []
  if (lifecycle === 'started') {
    return [{ type: 'status', status: 'compacting' }]
  }
  return [
    { type: 'status', status: '' },
    // App Server's contextCompaction item carries identity but no token counts. Preserve unknown as
    // null; zero would be a fabricated measurement and renders as a nonsensical 0 → 0 boundary.
    { type: 'compact_boundary', trigger: 'provider', preTokens: null, postTokens: null },
  ]
}
