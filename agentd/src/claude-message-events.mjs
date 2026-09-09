// Normalization of the Claude SDK's refusal/fallback and provider-frame identity messages into
// Mechanician's NDJSON events. Pure and message-at-a-time on purpose: the app's canonical-replacement
// reducer is the one piece of transcript handling that MUST be exercised against exact upstream
// shapes, and a refusal is not something a test suite may produce by asking a live model for harmful
// content. Everything here is therefore driven by fixtures.
//
// Two upstream mechanisms describe the same retraction, deliberately:
//
//   1. `SDKAssistantMessage.supersedes` — arrives WITH the replacement text, so the transcript can
//      swap the refused leg for its replacement the moment the replacement exists.
//   2. `model_refusal_fallback.retracted_message_uuids` — arrives at end of turn and is the complete
//      audit record for it.
//
// The SDK documents these as idempotent with each other. So the reducer must be able to apply both
// and land in the same place; this module's job is only to report them faithfully, never to decide
// which one wins.

/// A refusal category and explanation are provider prose on an open vocabulary — new categories ship
/// on the wire ahead of any schema. Carry them as opaque strings for display and never branch on
/// them: a policy decision made from an unstable string is a policy decision that silently changes
/// when the provider edits its copy.
const optionalString = (value) => (typeof value === 'string' && value !== '' ? value : null)
const modelString = (value) => {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return trimmed || null
}

const uuidList = (value) =>
  Array.isArray(value) ? value.filter((entry) => typeof entry === 'string' && entry !== '') : []

/// A future/current task lifecycle may carry the child model directly. Keep this normalization
/// separate from assistant-frame attribution: task events are optional metadata, while a child
/// assistant message's `message.model` is the authoritative model that actually answered.
export function claudeTaskModel(message) {
  return modelString(message?.model) ?? modelString(message?.patch?.model)
}

const claudeAgentToolNames = new Set(['agent', 'task'])
const claudeAgentTaskTypes = new Set(['remote_agent', 'local_agent', 'agent', 'subagent'])

const claudeTaskOwner = (owner) => {
  const turnId = modelString(owner?.turnId ?? owner?.ownerTurnId)
  if (!turnId) return null
  const conversationId = modelString(owner?.conversationId ?? owner?.ownerConversationId)
  return { turnId, ...(conversationId ? { conversationId } : {}) }
}

const claudeTaskRoute = (record) => record ? {
  ...(record.taskId ? { taskId: record.taskId } : {}),
  ...(record.toolUseId ? { toolUseId: record.toolUseId } : {}),
  ownerTurnId: record.owner.turnId,
  ...(record.owner.conversationId
    ? { ownerConversationId: record.owner.conversationId }
    : {}),
} : null

/// Provider-lifetime ownership for Claude Agent/Task/workflow work that can outlive one query.
///
/// The Agent SDK creates a new async iterator for every Mechanician turn, but a resumed iterator
/// may open with lifecycle or child frames for a background agent launched by an earlier one. The
/// per-query classifier below must therefore share this deliberately small registry. Only positive
/// Agent/Task/workflow evidence is admitted. In particular, observing a Bash tool never creates a
/// route, so a later bare task_notification cannot turn background shell work into a fake agent.
///
/// Live records are scoped by provider session and removed at terminal lifecycle. A separate
/// bounded tombstone keeps their immutable owner only for delayed observation routing. The live
/// bound does not evict active work: once full, new persistent correlations fail closed until a
/// terminal or session/provider boundary frees capacity.
export function createClaudeTaskRouteRegistry({
  maxEntries = 512,
  maxTerminalEntries = 1_024,
  maxRetiredSessions = 256,
  maxObservationEntries = 1_024,
} = {}) {
  const limit = Number.isSafeInteger(maxEntries) && maxEntries > 0 ? maxEntries : 512
  const terminalLimit = Number.isSafeInteger(maxTerminalEntries) && maxTerminalEntries > 0
    ? maxTerminalEntries : 1_024
  const retiredSessionLimit = Number.isSafeInteger(maxRetiredSessions) && maxRetiredSessions > 0
    ? maxRetiredSessions : 256
  const observationLimit = Number.isSafeInteger(maxObservationEntries)
    && maxObservationEntries > 0 ? maxObservationEntries : 1_024
  const records = new Set()
  const tasks = new Map()
  const tools = new Map()
  const terminals = new Set()
  const terminalTasks = new Map()
  const terminalTools = new Map()
  // Ordinary tools used by a positively owned child are not lifecycle evidence. Retain only the
  // immutable routing alias needed when their result arrives on a later SDK query without a
  // parent_tool_use_id. None of the lifecycle maps or admission helpers below consult this map.
  const observationTools = new Map()
  const retiredSessions = new Set()

  const key = (sessionId, identifier) => `${sessionId}\u0000${identifier}`
  const exact = (map, sessionId, identifier) => {
    const session = modelString(sessionId)
    const id = modelString(identifier)
    return session && id ? map.get(key(session, id)) ?? null : null
  }
  const matching = (field, identifier) => {
    const id = modelString(identifier)
    if (!id) return []
    return [...records].filter((record) => record[field] === id)
  }
  const unique = (field, identifier) => {
    const matches = matching(field, identifier)
    return matches.length === 1 ? matches[0] : null
  }
  const resolveRecord = ({ sessionId, taskId, toolUseId }) => {
    const session = modelString(sessionId)
    if (session) {
      return exact(tasks, session, taskId) ?? exact(tools, session, toolUseId)
    }
    // A few SDK control frames omit session_id. Use only an unambiguous exact identity; never
    // guess across two provider sessions that happen to reuse an opaque task/tool id.
    const task = modelString(taskId)
    const tool = modelString(toolUseId)
    const taskRecord = unique('taskId', task)
    const toolRecord = unique('toolUseId', tool)
    if (task && tool) {
      if (taskRecord && toolRecord) {
        return taskRecord === toolRecord
          || mergeableCorrelation(taskRecord, toolRecord, task, tool)
          ? taskRecord : null
      }
      if (taskRecord?.toolUseId === tool) return taskRecord
      if (toolRecord?.taskId === task) return toolRecord
      return null
    }
    return taskRecord ?? toolRecord
  }
  const removeRecord = (record) => {
    if (!record || !records.delete(record)) return false
    if (record.taskId && tasks.get(key(record.sessionId, record.taskId)) === record) {
      tasks.delete(key(record.sessionId, record.taskId))
    }
    if (record.toolUseId && tools.get(key(record.sessionId, record.toolUseId)) === record) {
      tools.delete(key(record.sessionId, record.toolUseId))
    }
    return true
  }
  const sameOwner = (left, right) => left?.owner?.turnId === right?.owner?.turnId
    && (left?.owner?.conversationId ?? null) === (right?.owner?.conversationId ?? null)
  const mergeableCorrelation = (taskRecord, toolRecord, taskId, toolUseId) =>
    !!taskRecord && !!toolRecord && taskRecord !== toolRecord
    && taskRecord.sessionId === toolRecord.sessionId
    && sameOwner(taskRecord, toolRecord)
    && (!taskRecord.toolUseId || taskRecord.toolUseId === toolUseId)
    && (!toolRecord.taskId || toolRecord.taskId === taskId)
  const removeTerminal = (terminal) => {
    if (!terminal || !terminals.delete(terminal)) return false
    if (terminal.taskId
        && terminalTasks.get(key(terminal.sessionId, terminal.taskId)) === terminal) {
      terminalTasks.delete(key(terminal.sessionId, terminal.taskId))
    }
    if (terminal.toolUseId
        && terminalTools.get(key(terminal.sessionId, terminal.toolUseId)) === terminal) {
      terminalTools.delete(key(terminal.sessionId, terminal.toolUseId))
    }
    return true
  }
  const rememberTerminal = ({ sessionId, taskId, toolUseId, toolName = null, owner = null }) => {
    const session = modelString(sessionId)
    const task = modelString(taskId)
    const tool = modelString(toolUseId)
    if (!session || (!task && !tool)) return false
    let retainedOwner = claudeTaskOwner(owner)
    let retainedToolName = modelString(toolName)
    let ownerConflict = false
    const priors = new Set([
      exact(terminalTasks, session, task),
      exact(terminalTools, session, tool),
    ].filter(Boolean))
    // Refresh an exact duplicate, but retain overlapping terminal identities. A provider conflict
    // can retire task A/tool X and task B/tool Y with one terminal A/Y; keeping all three pairs is
    // what prevents a later replay of B or X from being admitted under a new turn.
    for (const prior of priors) {
      if (prior.taskId !== task || prior.toolUseId !== tool) continue
      if (prior.owner) {
        if (!retainedOwner) retainedOwner = prior.owner
        else if (!sameOwner({ owner: retainedOwner }, prior)) ownerConflict = true
      }
      retainedToolName ??= prior.toolName
      removeTerminal(prior)
    }
    if (ownerConflict) retainedOwner = null
    while (terminals.size >= terminalLimit) {
      const oldest = terminals.values().next().value
      if (!oldest) break
      removeTerminal(oldest)
    }
    const terminal = {
      sessionId: session,
      taskId: task,
      toolUseId: tool,
      toolName: retainedToolName,
      owner: retainedOwner,
    }
    terminals.add(terminal)
    if (task) terminalTasks.set(key(session, task), terminal)
    if (tool) terminalTools.set(key(session, tool), terminal)
    return true
  }
  const terminalRecord = ({ sessionId, taskId, toolUseId }) => {
    const session = modelString(sessionId)
    if (session) {
      return exact(terminalTasks, session, taskId) ?? exact(terminalTools, session, toolUseId)
    }
    const task = modelString(taskId)
    const tool = modelString(toolUseId)
    let match = null
    for (const terminal of terminals) {
      if ((task && terminal.taskId === task) || (tool && terminal.toolUseId === tool)) {
        if (match && match !== terminal) return null
        match = terminal
      }
    }
    return match
  }
  const observationTerminalForToolUse = (toolUseId, sessionId = null) => {
    const tool = modelString(toolUseId)
    const session = modelString(sessionId)
    if (!tool) return null
    const matches = [...terminals].filter((terminal) =>
      terminal.toolUseId === tool && (!session || terminal.sessionId === session))
    if (!matches.length) return null
    // A sessionless child frame is safe only when this opaque id belongs to one provider session.
    // Within that session, overlapping terminal aliases may agree on the immutable owner while
    // disagreeing on a task id; retain the owner but omit an ambiguous canonical task id.
    if (!session && new Set(matches.map((terminal) => terminal.sessionId)).size !== 1) return null
    const first = matches[0]
    if (!first.owner || matches.some((terminal) =>
      !terminal.owner || !sameOwner(first, terminal))) return null
    const taskIds = new Set(matches.map((terminal) => terminal.taskId).filter(Boolean))
    return {
      sessionId: first.sessionId,
      taskId: taskIds.size === 1 ? [...taskIds][0] : null,
      toolUseId: tool,
      toolName: matches.every((terminal) => terminal.toolName === first.toolName)
        ? first.toolName : null,
      owner: first.owner,
    }
  }
  const createRecord = ({ sessionId, taskId = null, toolUseId = null, toolName = null, owner }) => {
    const session = modelString(sessionId)
    const normalizedOwner = claudeTaskOwner(owner)
    if (!session || !normalizedOwner || records.size >= limit) return null
    const record = {
      sessionId: session,
      taskId: modelString(taskId),
      toolUseId: modelString(toolUseId),
      toolName: modelString(toolName),
      owner: normalizedOwner,
    }
    if (!record.taskId && !record.toolUseId) return null
    records.add(record)
    if (record.taskId) tasks.set(key(session, record.taskId), record)
    if (record.toolUseId) tools.set(key(session, record.toolUseId), record)
    return record
  }
  const attachTask = (record, taskId) => {
    const task = modelString(taskId)
    if (!record || !task || record.taskId === task) return record
    if (record.taskId || exact(tasks, record.sessionId, task)) return record
    record.taskId = task
    tasks.set(key(record.sessionId, task), record)
    return record
  }
  const attachTool = (record, toolUseId, toolName = null) => {
    const tool = modelString(toolUseId)
    if (!record || !tool || record.toolUseId === tool) {
      if (record && !record.toolName) record.toolName = modelString(toolName)
      return record
    }
    if (record.toolUseId || exact(tools, record.sessionId, tool)) return record
    record.toolUseId = tool
    record.toolName = modelString(toolName)
    tools.set(key(record.sessionId, tool), record)
    return record
  }
  const observationAlias = (toolUseId, sessionId = null) => {
    const tool = modelString(toolUseId)
    const session = modelString(sessionId)
    if (!tool) return { found: false, route: null }
    if (session) {
      const observationKey = key(session, tool)
      return observationTools.has(observationKey)
        ? { found: true, route: observationTools.get(observationKey) }
        : { found: false, route: null }
    }
    const matches = [...observationTools.entries()]
      .filter(([observationKey]) => observationKey.endsWith(`\u0000${tool}`))
      .map(([, route]) => route)
    return matches.length === 1 && matches[0]
      ? { found: true, route: matches[0] }
      : { found: matches.length > 0, route: null }
  }
  const releaseObservationAlias = (toolUseId, sessionId = null) => {
    const tool = modelString(toolUseId)
    const session = modelString(sessionId)
    if (!tool) return false
    if (session) return observationTools.delete(key(session, tool))
    const matches = [...observationTools.keys()]
      .filter((observationKey) => observationKey.endsWith(`\u0000${tool}`))
    if (matches.length !== 1) return false
    return observationTools.delete(matches[0])
  }

  return {
    get size() { return records.size },
    get observationSize() { return observationTools.size },

    admitAgentTool({ sessionId, toolUseId, toolName, owner }) {
      const session = modelString(sessionId)
      const tool = modelString(toolUseId)
      const normalizedToolName = modelString(toolName)?.toLowerCase()
      if (!session || retiredSessions.has(session)
          || !tool || !claudeAgentToolNames.has(normalizedToolName)) return null
      if (terminalRecord({ sessionId: session, toolUseId: tool })) return null
      const existing = exact(tools, session, tool)
      return claudeTaskRoute(existing ?? createRecord({
        sessionId: session,
        toolUseId: tool,
        toolName,
        owner,
      }))
    },

    admitTask({ sessionId, taskId, toolUseId, toolName, owner }) {
      const session = modelString(sessionId)
      const task = modelString(taskId)
      const tool = modelString(toolUseId)
      if (!session || retiredSessions.has(session) || !task) return null
      if (terminalRecord({ sessionId: session, taskId: task, toolUseId: tool })) return null
      // Existing task identity is authoritative. If only the positively admitted Agent tool is
      // known, bind the task to that same immutable owner. A conflicting alias never reassigns
      // either record to the later turn.
      let record = exact(tasks, session, task)
      const toolRecord = exact(tools, session, tool)
      if ((record?.toolUseId && tool && record.toolUseId !== tool)
          || (toolRecord?.taskId && toolRecord.taskId !== task)) return null
      if (record && toolRecord && record !== toolRecord) {
        if (!mergeableCorrelation(record, toolRecord, task, tool)) return null
        const inheritedToolName = toolRecord.toolName
        removeRecord(toolRecord)
        attachTool(record, tool, toolName ?? inheritedToolName)
        return claudeTaskRoute(record)
      }
      if (record) {
        attachTool(record, tool, toolName)
        return claudeTaskRoute(record)
      }
      record = toolRecord
      if (record) {
        attachTask(record, task)
        return claudeTaskRoute(record)
      }
      return claudeTaskRoute(createRecord({
        sessionId: session,
        taskId: task,
        toolUseId: tool,
        toolName,
        owner,
      }))
    },

    resolve({ sessionId, taskId, toolUseId }) {
      return claudeTaskRoute(resolveRecord({ sessionId, taskId, toolUseId }))
    },

    correlationConflicts({ sessionId, taskId, toolUseId }) {
      const session = modelString(sessionId)
      const task = modelString(taskId)
      const tool = modelString(toolUseId)
      if (!task || !tool) return false
      if (!session
          && (matching('taskId', task).length > 1
            || matching('toolUseId', tool).length > 1)) return true
      const taskRecord = session
        ? exact(tasks, session, task) : unique('taskId', task)
      const toolRecord = session
        ? exact(tools, session, tool) : unique('toolUseId', tool)
      if ((taskRecord?.toolUseId && tool && taskRecord.toolUseId !== tool)
          || (toolRecord?.taskId && toolRecord.taskId !== task)) return true
      return !!taskRecord && !!toolRecord && taskRecord !== toolRecord
        && !mergeableCorrelation(taskRecord, toolRecord, task, tool)
    },

    wasTerminal({ sessionId, taskId, toolUseId }) {
      const session = modelString(sessionId)
      if (session && retiredSessions.has(session)) return true
      if (!session) {
        const task = modelString(taskId)
        const tool = modelString(toolUseId)
        return [...terminals].some((terminal) =>
          (task && terminal.taskId === task) || (tool && terminal.toolUseId === tool))
      }
      return !!terminalRecord({ sessionId, taskId, toolUseId })
    },

    routeForToolUse(toolUseId, sessionId = null) {
      return claudeTaskRoute(modelString(sessionId)
        ? exact(tools, sessionId, toolUseId)
        : unique('toolUseId', toolUseId))
    },

    // Terminal/retired Agent routes and ordinary child-tool aliases are observation-only evidence.
    // They may attribute delayed child tool/model/usage frames, but the lifecycle maps and
    // admission APIs above never consult ordinary aliases and cannot turn them into Agent cards.
    observationRouteForToolUse(toolUseId, sessionId = null) {
      const session = modelString(sessionId)
      if (session) {
        const lifecycleRoute = exact(tools, session, toolUseId)
          ?? observationTerminalForToolUse(toolUseId, session)
        if (lifecycleRoute) return claudeTaskRoute(lifecycleRoute)
        const alias = observationAlias(toolUseId, session)
        return alias.found ? alias.route : null
      }
      const liveMatches = matching('toolUseId', toolUseId)
      if (liveMatches.length > 1) return null
      if (liveMatches.length === 1) {
        // A sessionless frame cannot choose between one live use and a terminal use of the same
        // opaque id in another provider session or an ordinary observation alias.
        if ([...terminals].some((terminal) => terminal.toolUseId === modelString(toolUseId))
            || observationAlias(toolUseId).found) {
          return null
        }
        return claudeTaskRoute(liveMatches[0])
      }
      const terminalRoute = observationTerminalForToolUse(toolUseId)
      const alias = observationAlias(toolUseId)
      if (terminalRoute && alias.found) return null
      return claudeTaskRoute(terminalRoute) ?? (alias.found ? alias.route : null)
    },

    retainObservationAlias({ sessionId, toolUseId, route }) {
      const session = modelString(sessionId)
      const tool = modelString(toolUseId)
      const owner = claudeTaskOwner(route)
      if (!session || retiredSessions.has(session) || !tool || !owner) return false
      const observationKey = key(session, tool)
      const next = {
        taskId: modelString(route?.taskId),
        toolUseId: tool,
        ownerTurnId: owner.turnId,
        ...(owner.conversationId ? { ownerConversationId: owner.conversationId } : {}),
      }
      if (observationTools.has(observationKey)) {
        const prior = observationTools.get(observationKey)
        if (!prior || prior.ownerTurnId !== next.ownerTurnId
            || (prior.ownerConversationId ?? null) !== (next.ownerConversationId ?? null)) {
          observationTools.set(observationKey, null)
          return false
        }
        if (prior.taskId && next.taskId && prior.taskId !== next.taskId) {
          observationTools.set(observationKey, { ...prior, taskId: null })
        } else if (!prior.taskId && next.taskId) {
          observationTools.set(observationKey, { ...prior, taskId: next.taskId })
        }
        return true
      }
      while (observationTools.size >= observationLimit) {
        observationTools.delete(observationTools.keys().next().value)
      }
      observationTools.set(observationKey, next)
      return true
    },

    releaseObservationAlias(toolUseId, sessionId = null) {
      return releaseObservationAlias(toolUseId, sessionId)
    },

    taskIdForToolUse(toolUseId, sessionId = null) {
      const record = modelString(sessionId)
        ? exact(tools, sessionId, toolUseId)
        : unique('toolUseId', toolUseId)
      return record?.taskId ?? null
    },

    toolNameForUse(toolUseId, sessionId = null) {
      const record = modelString(sessionId)
        ? exact(tools, sessionId, toolUseId)
        : unique('toolUseId', toolUseId)
      return record?.toolName ?? null
    },

    releaseTask(taskId, sessionId = null) {
      return removeRecord(modelString(sessionId)
        ? exact(tasks, sessionId, taskId)
        : unique('taskId', taskId))
    },

    releaseTool(toolUseId, sessionId = null) {
      return removeRecord(modelString(sessionId)
        ? exact(tools, sessionId, toolUseId)
        : unique('toolUseId', toolUseId))
    },

    releaseCorrelation({ sessionId, taskId, toolUseId }) {
      const session = modelString(sessionId)
      const taskRecord = session
        ? exact(tasks, session, taskId)
        : unique('taskId', taskId)
      const toolRecord = session
        ? exact(tools, session, toolUseId)
        : unique('toolUseId', toolUseId)
      const targets = new Set([taskRecord, toolRecord].filter(Boolean))
      let removed = 0
      for (const record of targets) if (removeRecord(record)) removed += 1
      return removed
    },

    terminalizeCorrelation({ sessionId, taskId, toolUseId }) {
      const session = modelString(sessionId)
      const taskRecord = session
        ? exact(tasks, session, taskId)
        : unique('taskId', taskId)
      const toolRecord = session
        ? exact(tools, session, toolUseId)
        : unique('toolUseId', toolUseId)
      const concreteSession = session
        ?? taskRecord?.sessionId
        ?? toolRecord?.sessionId
      const targets = new Set([taskRecord, toolRecord].filter(Boolean))
      for (const record of targets) {
        rememberTerminal({
          sessionId: record.sessionId,
          taskId: record.taskId,
          toolUseId: record.toolUseId,
          toolName: record.toolName,
          owner: record.owner,
        })
      }
      rememberTerminal({
        sessionId: concreteSession,
        taskId: modelString(taskId) ?? taskRecord?.taskId ?? toolRecord?.taskId,
        toolUseId: modelString(toolUseId) ?? taskRecord?.toolUseId ?? toolRecord?.toolUseId,
      })
      let removed = 0
      for (const record of targets) if (removeRecord(record)) removed += 1
      return removed
    },

    drainSession(sessionId) {
      const session = modelString(sessionId)
      if (!session) return []
      const drained = []
      for (const record of [...records]) {
        if (record.sessionId !== session) continue
        rememberTerminal({
          sessionId: record.sessionId,
          taskId: record.taskId,
          toolUseId: record.toolUseId,
          toolName: record.toolName,
          owner: record.owner,
        })
        drained.push({ ...claudeTaskRoute(record), sessionId: record.sessionId })
        removeRecord(record)
      }
      for (const observationKey of [...observationTools.keys()]) {
        if (observationKey.startsWith(`${session}\u0000`)) {
          observationTools.delete(observationKey)
        }
      }
      retiredSessions.delete(session)
      while (retiredSessions.size >= retiredSessionLimit) {
        const oldest = retiredSessions.values().next().value
        if (!oldest) break
        retiredSessions.delete(oldest)
      }
      retiredSessions.add(session)
      return drained
    },

    drainAll() {
      const drained = [...records].map(claudeTaskRoute)
      records.clear()
      tasks.clear()
      tools.clear()
      terminals.clear()
      terminalTasks.clear()
      terminalTools.clear()
      observationTools.clear()
      retiredSessions.clear()
      return drained
    },

    releaseSession(sessionId) {
      return this.drainSession(sessionId).length
    },

    clear() {
      records.clear()
      tasks.clear()
      tools.clear()
      terminals.clear()
      terminalTasks.clear()
      terminalTools.clear()
      observationTools.clear()
      retiredSessions.clear()
    },
  }
}

/// Preserve the Agent tool's structured lifecycle result instead of asking the native app to parse
/// the model-directed tool-result prose. The SDK deliberately distinguishes a completed foreground
/// agent from a local/remote agent that has merely launched; only the former is a terminal result.
///
/// `SDKUserMessage.tool_use_result` is unknown-typed because every tool owns its output shape. Fail
/// closed on anything outside the AgentOutput status vocabulary so another tool's coincidental
/// `status` field can never become subagent lifecycle.
export function claudeAgentResultMetadata(toolUseResult, toolName) {
  const normalizedToolName = modelString(toolName)?.toLowerCase()
  if (!claudeAgentToolNames.has(normalizedToolName)) return null
  if (!toolUseResult || typeof toolUseResult !== 'object' || Array.isArray(toolUseResult)) {
    return null
  }
  const status = modelString(toolUseResult.status)
  if (status === 'async_launched') {
    const taskId = modelString(toolUseResult.agentId)
    return taskId
      ? { subagentResultDisposition: 'launched', subagentTaskId: taskId }
      : null
  }
  if (status === 'remote_launched') {
    const taskId = modelString(toolUseResult.taskId)
    return taskId
      ? { subagentResultDisposition: 'launched', subagentTaskId: taskId }
      : null
  }
  if (status === 'completed') {
    return modelString(toolUseResult.agentId)
      ? { subagentResultDisposition: 'completed' }
      : null
  }
  return null
}

/// Associate the message-scoped structured result only when the SDK supplied exactly one matching
/// tool-result block. This is the live SDK shape; refusing a future batched shape is safer than
/// smearing one agent lifecycle across several parallel tool calls.
export function claudeAgentResultMetadataForMessage(message, toolName) {
  if (message?.type !== 'user' || !Array.isArray(message.message?.content)) return null
  const blocks = message.message.content.filter((block) => block?.type === 'tool_result')
  if (blocks.length !== 1 || !modelString(blocks[0].tool_use_id)) return null
  return claudeAgentResultMetadata(
    message.tool_use_result ?? message.toolUseResult,
    toolName)
}

/// Track Claude's shared task_* lifecycle without mistaking every background task for an agent.
///
/// Claude uses the same task_started/progress/notification messages for background Bash commands,
/// Task/Agent subagents, and local workflows. The lifecycle messages after `task_started` omit the
/// task kind, so classification has to remember both the originating tool_use block and tasks that
/// were already accepted. Unknown tasks fail closed: showing no card for an unclassified provider
/// task is safer than inventing an agent that never existed.
export function createClaudeTaskLifecycleTracker({
  routeRegistry = createClaudeTaskRouteRegistry(),
  owner = null,
  maxObservationEntries = 512,
} = {}) {
  const toolNameByUse = new Map()
  const toolUseByTask = new Map()
  const taskIdByToolUse = new Map()
  const visibleTaskIds = new Set()
  const currentOwner = claudeTaskOwner(owner)
  const observationLimit = Number.isSafeInteger(maxObservationEntries)
    && maxObservationEntries > 0 ? maxObservationEntries : 512
  // Query-local retention closes the immediate terminal -> child-frame race even if the global
  // tombstone bound is under pressure. Keys include the provider session because Claude may reuse
  // an opaque tool id after a conversation reset. The provider registry independently retains the
  // same immutable owner across later queries.
  const observationRoutes = new Map()
  const observationKey = (sessionId, toolUseId) =>
    `${modelString(sessionId) ?? ''}\u0000${modelString(toolUseId) ?? ''}`
  const sameRouteOwner = (left, right) =>
    left?.ownerTurnId === right?.ownerTurnId
    && (left?.ownerConversationId ?? null) === (right?.ownerConversationId ?? null)
  const retainObservationRoute = (route, sessionId = null) => {
    const toolUseId = modelString(route?.toolUseId)
    const owner = claudeTaskOwner(route)
    if (!toolUseId || !owner) return false
    const normalizedSessionId = modelString(sessionId ?? route?.sessionId)
    const key = observationKey(normalizedSessionId, toolUseId)
    const next = {
      sessionId: normalizedSessionId,
      taskId: modelString(route?.taskId),
      toolUseId,
      ownerTurnId: owner.turnId,
      ...(owner.conversationId ? { ownerConversationId: owner.conversationId } : {}),
    }
    if (observationRoutes.has(key)) {
      const prior = observationRoutes.get(key)
      if (!prior || !sameRouteOwner(prior, next)) {
        observationRoutes.set(key, null)
        return false
      }
      if (prior.taskId && next.taskId && prior.taskId !== next.taskId) {
        observationRoutes.set(key, { ...prior, taskId: null })
      } else if (!prior.taskId && next.taskId) {
        observationRoutes.set(key, { ...prior, taskId: next.taskId })
      }
      return true
    }
    while (observationRoutes.size >= observationLimit) {
      observationRoutes.delete(observationRoutes.keys().next().value)
    }
    observationRoutes.set(key, next)
    return true
  }
  const localObservationForToolUse = (toolUseId, sessionId = null) => {
    const tool = modelString(toolUseId)
    const session = modelString(sessionId)
    if (!tool) return { found: false, route: null }
    if (session) {
      const key = observationKey(session, tool)
      return observationRoutes.has(key)
        ? { found: true, route: observationRoutes.get(key) }
        : { found: false, route: null }
    }
    const matches = [...observationRoutes.entries()]
      .filter(([key]) => key.endsWith(`\u0000${tool}`))
      .map(([, route]) => route)
    return matches.length === 1 && matches[0]
      ? { found: true, route: matches[0] }
      : { found: matches.length > 0, route: null }
  }
  const observationRouteForToolUse = (toolUseId, sessionId = null) => {
    if (!modelString(sessionId)) {
      // The provider registry sees every session. A query-local route cannot prove that the same
      // opaque id is absent from another live or terminal session, so never let it decide a
      // sessionless frame by itself.
      return routeRegistry.observationRouteForToolUse(toolUseId)
    }
    const live = routeRegistry.routeForToolUse(toolUseId, sessionId)
    if (live) return live
    const local = localObservationForToolUse(toolUseId, sessionId)
    if (local.found) {
      if (!local.route) return null
      const { sessionId: _sessionId, ...route } = local.route
      return route
    }
    return routeRegistry.observationRouteForToolUse(toolUseId, sessionId)
  }

  const rememberCorrelation = (taskId, toolUseId) => {
    if (!taskId || !toolUseId) return
    const previousToolUseId = toolUseByTask.get(taskId)
    if (previousToolUseId && previousToolUseId !== toolUseId
        && taskIdByToolUse.get(previousToolUseId) === taskId) {
      taskIdByToolUse.delete(previousToolUseId)
    }
    toolUseByTask.set(taskId, toolUseId)
    taskIdByToolUse.set(toolUseId, taskId)
  }

  const release = (taskId) => {
    if (!taskId) return
    const toolUseId = toolUseByTask.get(taskId)
    toolUseByTask.delete(taskId)
    visibleTaskIds.delete(taskId)
    if (toolUseId && taskIdByToolUse.get(toolUseId) === taskId) {
      taskIdByToolUse.delete(toolUseId)
      toolNameByUse.delete(toolUseId)
    }
  }

  const explicitlyVisible = (message, toolUseId, sessionId) => {
    if (modelString(message?.subagent_type)) return true
    const taskType = modelString(message?.task_type)?.toLowerCase()
    if (taskType === 'local_workflow' || claudeAgentTaskTypes.has(taskType)) return true
    if (modelString(message?.workflow_name) || Array.isArray(message?.workflow_progress)) return true
    const toolName = modelString(toolNameByUse.get(toolUseId)
      ?? routeRegistry.toolNameForUse(toolUseId, sessionId))?.toLowerCase()
    return claudeAgentToolNames.has(toolName)
  }

  const routedOwner = (route) => claudeTaskOwner(route)
  const correlationOwner = (route) => route?.ownerTurnId ? {
    ownerTurnId: route.ownerTurnId,
    ...(route.ownerConversationId
      ? { ownerConversationId: route.ownerConversationId }
      : {}),
  } : {}
  const terminalStatus = (status) => [
    'completed', 'failed', 'stopped', 'cancelled', 'canceled',
  ].includes(modelString(status)?.toLowerCase())
  const isTerminal = (message) =>
    (message?.subtype === 'task_notification' && terminalStatus(message?.status))
    || (message?.subtype === 'task_updated' && terminalStatus(message?.patch?.status))

  return {
    // Child assistant frames carry only their parent tool-use id. Expose this read-only-by-contract
    // join so model attribution enriches the same canonical task row as lifecycle updates.
    taskIdByToolUse,

    toolNameForUse(toolUseId, sessionId = null) {
      const id = modelString(toolUseId)
      return modelString(toolNameByUse.get(id)
        ?? routeRegistry.toolNameForUse(id, sessionId))
    },

    taskIdForToolUse(toolUseId, sessionId = null) {
      const id = modelString(toolUseId)
      return modelString(taskIdByToolUse.get(id)
        ?? routeRegistry.taskIdForToolUse(id, sessionId)
        ?? observationRouteForToolUse(id, sessionId)?.taskId)
    },

    ownerForToolUse(toolUseId, sessionId = null) {
      const id = modelString(toolUseId)
      return observationRouteForToolUse(id, sessionId)
    },

    retainObservationRoutes(routes) {
      if (!Array.isArray(routes)) return 0
      let retained = 0
      for (const route of routes) {
        if (retainObservationRoute(route, route?.sessionId)) retained += 1
      }
      return retained
    },

    observeToolUse(toolUseId, toolName, { sessionId = null, parentToolUseId = null } = {}) {
      const id = modelString(toolUseId)
      const name = modelString(toolName)
      if (!id || !name) return true
      const agentTool = claudeAgentToolNames.has(name.toLowerCase())
      if (agentTool && routeRegistry.wasTerminal({ sessionId, toolUseId: id })) return false
      if (!agentTool) {
        toolNameByUse.set(id, name)
        const inherited = observationRouteForToolUse(parentToolUseId, sessionId)
        if (inherited) {
          retainObservationRoute({ ...inherited, toolUseId: id }, sessionId)
          routeRegistry.retainObservationAlias({
            sessionId,
            toolUseId: id,
            route: inherited,
          })
        } else {
          // A root-owned ordinary tool can legitimately reuse an opaque id after an old child
          // observation. Its explicit parentless tool frame invalidates that stale attribution.
          routeRegistry.releaseObservationAlias(id, sessionId)
        }
        return true
      }
      // Positive Agent/Task evidence owns this identity from here on. Do not let a stale ordinary
      // alias reappear after the live lifecycle reaches terminal.
      routeRegistry.releaseObservationAlias(id, sessionId)
      const inherited = observationRouteForToolUse(parentToolUseId, sessionId)
      const toolOwner = routedOwner(inherited) ?? currentOwner
      const admitted = routeRegistry.admitAgentTool({
        sessionId,
        toolUseId: id,
        toolName: name,
        owner: toolOwner,
      })
      if (toolOwner && !admitted) return false
      toolNameByUse.set(id, name)
      if (admitted) retainObservationRoute(admitted, sessionId)
      return true
    },

    /// Bind the structured async Agent result to its provider task before a later query reports
    /// the terminal lifecycle. Foreground completion and tool errors release a provisional route.
    observeAgentResult(toolUseId, metadata, {
      sessionId = null,
      isError = false,
    } = {}) {
      const tool = modelString(toolUseId)
      if (!tool) return null
      if (metadata?.subagentResultDisposition === 'launched') {
        const taskId = modelString(metadata.subagentTaskId)
        if (!taskId) return null
        const prior = observationRouteForToolUse(tool, sessionId)
        const route = routeRegistry.admitTask({
          sessionId,
          taskId,
          toolUseId: tool,
          toolName: this.toolNameForUse(tool, sessionId),
          owner: routedOwner(prior) ?? currentOwner,
        })
        if (currentOwner && !route) return null
        rememberCorrelation(taskId, tool)
        visibleTaskIds.add(taskId)
        if (route) retainObservationRoute(route, sessionId)
        return route
      }
      if (isError || metadata?.subagentResultDisposition === 'completed') {
        retainObservationRoute({
          ...(observationRouteForToolUse(tool, sessionId) ?? {}),
          taskId: this.taskIdForToolUse(tool, sessionId),
          toolUseId: tool,
        }, sessionId)
        routeRegistry.terminalizeCorrelation({ sessionId, toolUseId: tool })
      }
      return null
    },

    /// Return canonical correlation only for an Agent/Task/workflow lifecycle event.
    /// A terminal event is classified before its correlation is released.
    correlate(message) {
      const taskId = modelString(message?.task_id)
      if (!taskId) return null
      const sessionId = modelString(message?.session_id)
      const taskType = modelString(message?.task_type)?.toLowerCase()
      // An explicit Bash classification always wins over coincidental opaque ids. Later bare
      // notifications are admitted only if this exact session already has positive agent evidence.
      if (taskType === 'local_bash') {
        routeRegistry.releaseCorrelation({
          sessionId,
          taskId,
          toolUseId: message?.tool_use_id,
        })
        release(taskId)
        return null
      }
      let toolUseId = modelString(message?.tool_use_id)
      if (!toolUseId) toolUseId = modelString(toolUseByTask.get(taskId))
      if (routeRegistry.wasTerminal({ sessionId, taskId, toolUseId })) return null
      if (routeRegistry.correlationConflicts({ sessionId, taskId, toolUseId })) {
        if (isTerminal(message)) {
          routeRegistry.terminalizeCorrelation({ sessionId, taskId, toolUseId })
        }
        return null
      }
      const existingRoute = routeRegistry.resolve({ sessionId, taskId, toolUseId })

      const visible = visibleTaskIds.has(taskId)
        || !!existingRoute
        || explicitlyVisible(message, toolUseId, sessionId)
      if (!visible) return null
      const localToolName = this.toolNameForUse(toolUseId, sessionId)
      // Ordinary child-tool aliases are for tool/model/usage attribution only. Lifecycle admission
      // may inherit an owner solely from a positively admitted live Agent/Task tool route.
      const toolRoute = routeRegistry.routeForToolUse(toolUseId, sessionId)
      const route = routeRegistry.admitTask({
        sessionId,
        taskId,
        toolUseId,
        toolName: localToolName,
        owner: routedOwner(toolRoute) ?? currentOwner,
      }) ?? existingRoute
      if (currentOwner && !route) return null
      if (toolUseId) rememberCorrelation(taskId, toolUseId)
      visibleTaskIds.add(taskId)
      const canonicalToolUseId = modelString(route?.toolUseId) ?? toolUseId
      const correlation = {
        taskId,
        ...(canonicalToolUseId ? { toolUseId: canonicalToolUseId } : {}),
        ...correlationOwner(route),
      }

      if (isTerminal(message)) {
        retainObservationRoute({ ...route, taskId, toolUseId: canonicalToolUseId }, sessionId)
        release(taskId)
        routeRegistry.terminalizeCorrelation({
          sessionId,
          taskId,
          toolUseId: canonicalToolUseId,
        })
      }
      return correlation
    },
  }
}

/// Normalize one Claude child assistant frame into the same workflow_update shape as task_*.
///
/// `parent_tool_use_id` identifies the Agent/Task invocation that owns this subagent. When task
/// lifecycle has already supplied its task id, `taskIdByToolUse` joins the model onto that exact
/// row; otherwise using the tool-use id for both fields safely enriches the provisional row.
export function claudeChildModelUpdate(message, taskIdByToolUse = new Map()) {
  if (message?.type !== 'assistant') return null
  const toolUseId = modelString(message.parent_tool_use_id)
  const model = modelString(message.message?.model)
  if (!toolUseId || !model) return null
  const taskId = modelString(taskIdByToolUse?.get?.(toolUseId)) ?? toolUseId
  const subagentType = modelString(message.subagent_type)
  const description = modelString(message.task_description)
  return {
    type: 'workflow_update',
    phase: 'progress',
    taskId,
    toolUseId,
    model,
    ...(subagentType ? { subagentType } : {}),
    ...(description ? { description } : {}),
  }
}

/// Whether a fallback swap outlives the turn that caused it.
///
/// Upstream now emits only `retry`, and documents it as "retried once on a fallback model with the
/// swap made persistent for the session". `sticky` and `revert` remain in the enum for consumer
/// compatibility and are no longer emitted. Treat anything that is not an explicit `revert` as
/// persistent: an unknown future direction that we wrongly treat as one-shot would silently show the
/// user the wrong model for the rest of the session.
export function fallbackIsPersistent(direction) {
  return direction !== 'revert'
}

/// Tracks which streaming event started the text row for each completed assistant frame.
///
/// `SDKPartialAssistantMessage.uuid` identifies the partial EVENT: successive deltas in one text
/// block can therefore have different UUIDs, and the completed `SDKAssistantMessage` has another
/// UUID again. The app stamps a newly opened transcript row with the FIRST text delta's UUID. Only
/// the stream loop sees that exact pairing, so retain that first UUID until the corresponding
/// completed TEXT block arrives. Thinking, lifecycle and tool-only messages must neither claim nor
/// clear it; doing so can re-attribute (and later retract) the wrong transcript row.
export function createFrameCorrelator() {
  let firstTextPartial = null
  return {
    /// Feed every message; returns the provisional id to report with a completed assistant frame.
    observe(message) {
      if (message?.type === 'stream_event') {
        if (message.event?.type !== 'content_block_delta'
            || message.event.delta?.type !== 'text_delta') return null
        const uuid = optionalString(message.uuid)
        if (uuid && !firstTextPartial) firstTextPartial = uuid
        return null
      }
      if (message?.type !== 'assistant') return null
      const hasText = Array.isArray(message.message?.content)
        && message.message.content.some((block) => block?.type === 'text')
      if (!hasText) return null
      const carried = firstTextPartial
      firstTextPartial = null
      return carried
    },
  }
}

/// The provider's own identity for one assistant frame, plus anything it replaces. Returns null for
/// messages that carry no frame identity, so callers can spread the result unconditionally.
export function claudeFrameIdentity(message) {
  if (!message || typeof message !== 'object') return null
  const uuid = optionalString(message.uuid)
  if (!uuid) return null
  if (message.type === 'assistant') {
    const supersedes = uuidList(message.supersedes)
    return { frameUUID: uuid, ...(supersedes.length ? { supersedes } : {}) }
  }
  // A partial carries its own SDK-event UUID. The app uses it only as provisional attribution while
  // streaming; `createFrameCorrelator` pairs the first text event with the completed provider frame,
  // whose UUID is authoritative for refusal/retraction.
  if (message.type === 'stream_event') return { frameUUID: uuid }
  return null
}

/// Normalize every Claude tool block with the assistant frame that owns it. A later safety
/// fallback retracts provider frame UUIDs, so omitting this exact correlation would leave a tool
/// that may already have executed visible as ordinary current work rather than superseded audit
/// evidence. Only the frame identity travels here; `supersedes` remains an assistant-frame fact.
export function claudeToolUseEvents(message) {
  if (message?.type !== 'assistant' || !Array.isArray(message.message?.content)) return []
  const frameUUID = claudeFrameIdentity(message)?.frameUUID
  const parentToolUseId = optionalString(message.parent_tool_use_id)
  return message.message.content
    .filter((block) => block?.type === 'tool_use')
    .map((block) => ({
      type: 'tool_use',
      toolUseId: block.id,
      name: block.name,
      input: block.input,
      ...(frameUUID ? { frameUUID } : {}),
      ...(parentToolUseId ? { parentToolUseId } : {}),
    }))
}

/// Normalize the two refusal terminal shapes. Returns an array so a caller can splat it into its
/// emit loop without a null check; a non-refusal message yields no events.
///
/// Note what is deliberately NOT here: nothing in this module decides that the account, runtime or
/// model is unhealthy. A refusal is the provider working correctly and declining one request, and
/// treating it as a provider failure would flip the lane to broken and send the user to re-auth a
/// perfectly good account.
export function claudeRefusalEvents(message) {
  if (!message || message.type !== 'system') return []
  const uuid = optionalString(message.uuid)

  if (message.subtype === 'model_refusal_fallback') {
    const direction = optionalString(message.direction) ?? 'retry'
    return [{
      type: 'model_refusal',
      outcome: 'fallback',
      direction,
      persistent: fallbackIsPersistent(direction),
      originalModel: optionalString(message.original_model),
      fallbackModel: optionalString(message.fallback_model),
      requestId: optionalString(message.request_id),
      category: optionalString(message.api_refusal_category),
      // Display only. Never parsed into policy — see `optionalString`.
      explanation: optionalString(message.api_refusal_explanation),
      retractedMessageUUIDs: uuidList(message.retracted_message_uuids),
      refusedUserMessageUUID: optionalString(message.refused_user_message_uuid),
      text: optionalString(message.content),
      ...(uuid ? { frameUUID: uuid } : {}),
    }]
  }

  if (message.subtype === 'model_refusal_no_fallback') {
    return [{
      type: 'model_refusal',
      outcome: 'no_fallback',
      originalModel: optionalString(message.original_model),
      requestId: optionalString(message.request_id),
      category: optionalString(message.api_refusal_category),
      explanation: optionalString(message.api_refusal_explanation),
      // No retry ran, so nothing was retracted: the refused leg is all there is, and the app must
      // keep whatever partial text it already showed rather than silently dropping it with no
      // replacement to put in its place.
      retractedMessageUUIDs: [],
      refusedUserMessageUUID: optionalString(message.refused_user_message_uuid),
      text: optionalString(message.content),
      ...(uuid ? { frameUUID: uuid } : {}),
    }]
  }

  return []
}

/// The frame/refusal events one SDK message produces, in wire order, WITHOUT the turn id — the
/// caller adds that.
///
/// `streamOnce` calls exactly this, so the fixture harness below exercises the real emission path
/// rather than a parallel reimplementation of it that could drift. `correlator` must be the one
/// created for this turn: it carries the partial→completed frame pairing across messages.
export function claudeStreamFrameEvents(message, correlator) {
  const events = []
  for (const refusal of claudeRefusalEvents(message)) events.push(refusal)

  const provisionalFrameUUID = correlator.observe(message)
  const frame = claudeFrameIdentity(message)
  if (message?.type === 'assistant' && frame) {
    events.push({
      type: 'assistant_frame',
      ...frame,
      ...(provisionalFrameUUID ? { provisionalFrameUUID } : {}),
    })
  }
  return events
}

/// Replay a whole message sequence and collect every event it produces, exactly as the daemon's
/// stream loop would. This is the fake stream: a refusal cannot be provoked from a live model, so
/// the only way to test a full refusal turn end to end is to hand the loop the messages the SDK
/// would have delivered.
export function replayClaudeStream(messages) {
  const correlator = createFrameCorrelator()
  const events = []
  for (const message of messages) {
    events.push(...claudeStreamFrameEvents(message, correlator))
    // Delta enrichment happens where the delta is emitted, so mirror that here to keep the harness
    // an honest picture of what the app receives.
    if (message?.type === 'stream_event'
        && message.event?.type === 'content_block_delta'
        && message.event.delta?.type === 'text_delta') {
      const frame = claudeFrameIdentity(message)
      events.push({ type: 'delta', text: message.event.delta.text, ...(frame ?? {}) })
    }
    events.push(...claudeToolUseEvents(message))
  }
  return events
}

/// True when a message is one of the refusal terminals. Lets the turn-error capture path skip a
/// refusal without duplicating subtype strings across modules.
export function isClaudeRefusalMessage(message) {
  return message?.type === 'system'
    && (message.subtype === 'model_refusal_fallback'
      || message.subtype === 'model_refusal_no_fallback')
}

