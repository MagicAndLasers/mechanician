// Root C candidate: the canonical multi-agent event/artifact graph.
//
// The bet this model tests: agents, parentage, and agent-to-agent communication are FIRST-CLASS
// (nodes and typed events), and human dialog / traces / telemetry are projections. Everything
// the wire says lands here without loss; everything the wire only implies (a recipient inside a
// tool input) lands with explicit provenance instead of being silently promoted to fact. This
// remains a selected subset: canonical-field-contract.mjs fail-closes every source fact the
// adapter does not yet map, so a missing mapping can never masquerade as root-C fidelity.
export const CANONICAL_FORMAT = 'mechanician-canonical-graph/0-spike'

function terminalOutcome(state) {
  switch (state) {
    case 'completed':
    case 'success':
    case 'succeeded':
    case 'done': return 'succeeded'
    case 'error':
    case 'failed': return 'failed'
    case 'cancelled':
    case 'interrupted':
    case 'killed':
    case 'stopped': return 'stopped'
    default: return null
  }
}

const TERMINAL_WORK_STATES = new Set([
  'completed', 'success', 'succeeded', 'done', 'error', 'failed',
  'cancelled', 'interrupted', 'killed', 'stopped',
])

function normalizedWorkState(state) {
  if (state == null) return null
  return state === 'error' ? 'failed' : state
}

function isAggregateWorkflowEvent(event) {
  return event.isWorkflowRun === true
    || event.taskType === 'local_workflow'
    || (typeof event.workflowName === 'string' && event.workflowName.trim().length > 0)
    || (Array.isArray(event.workflowProgress) && event.workflowProgress.length > 0)
}

function providerAgentPath(value) {
  if (typeof value !== 'string' || value.length > 2048 || !value.startsWith('/root/')) return null
  const components = value.split('/')
  if (components[0] !== '' || components[1] !== 'root' || components.length < 3) return null
  const segments = components.slice(2)
  if (segments.some((part) => part.length === 0 || part.length > 256
      || part !== part.trim() || part === '.' || part === '..'
      || /[\\\u0000-\u001f\u007f]/.test(part)
      || /%(?:2e|2f|5c)/i.test(part))) return null
  return segments
}

function portableToolTarget(value) {
  if (typeof value !== 'string' || value.length === 0) {
    return { toolTarget: null, toolTargetDisclosure: 'not-reported' }
  }
  // A provider tool target is useful historical context, but an absolute current-machine path is
  // not portable identity. Preserve safe commands/relative labels and make local-path omission an
  // explicit canonical fact rather than leaking it through an extension encoder.
  const carriesLocalLocator = /(?:^|[\s"'=(:,])\/(?!\/)[^\s"']+/.test(value)
    || /(?:^|[\s"'=(:,])(?:~\/|\\\\[^\\\s]+\\|[A-Za-z]:[\\/])/.test(value)
    || /(?:^|[^A-Za-z0-9_])\$(?:\{(?:HOME|PWD)\}|(?:HOME|PWD)\b)/.test(value)
    || /(?:^|[\s"'=(:,])file:\/\//i.test(value)
    || /(?:^|[\s"'=(:,])\/?(?:Users|Volumes|private|tmp|var|etc|opt|Applications|System|Library|home)\//.test(value)
  if (carriesLocalLocator) {
    return { toolTarget: null, toolTargetDisclosure: 'omitted-private-local' }
  }
  return { toolTarget: value, toolTargetDisclosure: 'historical-inert' }
}

function sameSnapshot(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function validSourceOrdinal(value) {
  return Number.isSafeInteger(value) && value >= 0
}

// Workflows have identity and lifecycle independent of the agents that execute their phases.
// Provider task/tool handles are scoped aliases only: this prepass joins those aliases, mints
// record-local workflow/phase/agent ids in observation order, and exposes no raw handle.
function canonicalWorkflowModel(capture) {
  const parent = new Map()
  const firstSeen = new Map()
  const aggregateKeys = new Set()
  let observationCounter = 0
  const rawTurnID = (event) => event.turnId ?? event.id ?? '__capture_turn__'
  const scoped = (event, namespace, id) =>
    `${rawTurnID(event)}\u0000${namespace}\u0000${String(id)}`
  const taskKey = (event, id) => scoped(event, 'workflow-task', id)
  const toolKey = (event, id) => scoped(event, 'workflow-tool', id)
  const add = (key) => {
    if (!key || parent.has(key)) return
    parent.set(key, key)
    firstSeen.set(key, observationCounter += 1)
  }
  const find = (key) => {
    const next = parent.get(key)
    if (!next || next === key) return key
    const root = find(next)
    parent.set(key, root)
    return root
  }
  const union = (left, right) => {
    add(left)
    add(right)
    const a = find(left)
    const b = find(right)
    if (a !== b) parent.set(b, a)
  }

  for (const { event } of capture.events) {
    if (event.type !== 'workflow_update') continue
    const task = event.taskId ? taskKey(event, event.taskId) : null
    const tool = event.toolUseId ? toolKey(event, event.toolUseId) : null
    if (task) add(task)
    if (tool) add(tool)
    if (task && tool) union(task, tool)
    if (isAggregateWorkflowEvent(event)) {
      if (task) aggregateKeys.add(task)
      if (tool) aggregateKeys.add(tool)
    }
  }

  const aggregateRoots = new Set([...aggregateKeys].map(find))
  const workflowIDByRoot = new Map()
  let workflowCounter = 0
  for (const key of [...parent.keys()].sort(
    (left, right) => firstSeen.get(left) - firstSeen.get(right))) {
    const root = find(key)
    if (aggregateRoots.has(root) && !workflowIDByRoot.has(root)) {
      workflowIDByRoot.set(root, `workflow-${workflowCounter += 1}`)
    }
  }
  const idForKey = (key) => {
    if (!key || !parent.has(key)) return null
    return workflowIDByRoot.get(find(key)) ?? null
  }
  const workflowID = (event) => idForKey(
    event.taskId ? taskKey(event, event.taskId)
      : event.toolUseId ? toolKey(event, event.toolUseId) : null)

  const workflows = []
  const workflowByID = new Map()
  const workflowPhases = []
  const phaseByKey = new Map()
  const progressAgentByKey = new Map()
  const progressAgents = []
  let phaseCounter = 0
  let progressAgentCounter = 0
  const phaseID = (workflowId, sourceIndex) => {
    if (workflowId == null || !validSourceOrdinal(sourceIndex)) return null
    const key = `${workflowId}\u0000${String(sourceIndex)}`
    if (!phaseByKey.has(key)) {
      const phase = {
        id: `workflow-phase-${phaseCounter += 1}`,
        workflowId, sourceOrdinal: sourceIndex,
        identityProvenance: 'minted-from-workflow-phase-ordinal',
      }
      phaseByKey.set(key, phase)
      workflowPhases.push(phase)
    }
    return phaseByKey.get(key).id
  }
  const progressAgentKey = (workflowId, progress) => {
    if (workflowId == null || !validSourceOrdinal(progress.phaseIndex)
        || !validSourceOrdinal(progress.index)) return null
    return `${workflowId}\u0000slot:${progress.phaseIndex}:${progress.index}`
  }
  const progressAgentID = (workflowId, progress) =>
    progressAgentByKey.get(progressAgentKey(workflowId, progress))?.id ?? null
  const progressSlotByProviderAlias = new Map()
  const observeProgressAlias = (workflowId, progress, slotKey) => {
    if (progress.agentId == null) return
    if (typeof progress.agentId !== 'string' || progress.agentId.length === 0) {
      throw new Error('workflow progress agent alias must be a nonempty string')
    }
    const aliasKey = `${workflowId}\u0000provider-agent:${progress.agentId}`
    const priorSlot = progressSlotByProviderAlias.get(aliasKey)
    if (priorSlot && priorSlot !== slotKey) {
      throw new Error('one provider workflow agent alias names two workflow slots')
    }
    progressSlotByProviderAlias.set(aliasKey, slotKey)
  }

  for (const { event } of capture.events) {
    if (event.type !== 'workflow_update') continue
    const id = workflowID(event)
    if (!id) continue
    let workflow = workflowByID.get(id)
    if (!workflow) {
      workflow = {
        id, ownerAgentId: 'root',
        identityProvenance: 'minted-from-provider-workflow-alias',
      }
      workflowByID.set(id, workflow)
      workflows.push(workflow)
    }
    for (const progress of event.workflowProgress ?? []) {
      if (!progress || typeof progress !== 'object') continue
      if (progress.type === 'workflow_phase') {
        phaseID(id, progress.index)
      } else if (progress.type === 'workflow_agent') {
        const key = progressAgentKey(id, progress)
        if (!key) continue
        observeProgressAlias(id, progress, key)
        if (!progressAgentByKey.has(key)) {
          const phase = phaseID(id, progress.phaseIndex)
          const agent = {
            id: `workflow-agent-${progressAgentCounter += 1}`,
            parentId: workflow.ownerAgentId,
            type: 'workflow-agent', workflowId: id, phaseId: phase,
            sourceOrdinal: progress.index ?? null,
            identityProvenance: 'minted-from-workflow-agent-slot',
            parentageProvenance: 'workflow-owner',
          }
          progressAgentByKey.set(key, agent)
          progressAgents.push(agent)
        }
      }
    }
  }

  return {
    workflows,
    workflowPhases,
    progressAgents,
    workflowID,
    workflowIDFromTool: (event, rawID) => idForKey(rawID ? toolKey(event, rawID) : null),
    workflowIDFromTask: (event, rawID) => idForKey(rawID ? taskKey(event, rawID) : null),
    phaseID,
    progressAgentID,
  }
}

// Provider turn, task, thread, steering, and tool-use identifiers may be live control handles.
// They never become portable identities. This prepass scopes raw aliases to one provider turn,
// enforces one-to-one task/tool correlations, and mints record-local ids in observation order.
function canonicalIdentityModel(capture, workflowModel) {
  const turnIDs = new Map()
  let turnCounter = 0
  const rawTurnID = (event) => event.turnId ?? event.id ?? '__capture_turn__'
  const portableTurnID = (event) => {
    const raw = String(rawTurnID(event))
    if (!turnIDs.has(raw)) turnIDs.set(raw, `turn-${turnCounter += 1}`)
    return turnIDs.get(raw)
  }
  for (const { event } of capture.events) {
    if (event.type === 'turn_started') portableTurnID(event)
  }
  if (turnIDs.size === 0) turnIDs.set('__capture_turn__', `turn-${turnCounter += 1}`)

  const parent = new Map()
  const firstSeen = new Map()
  let observationCounter = 0
  const scoped = (event, namespace, id) =>
    `${rawTurnID(event)}\u0000${namespace}\u0000${String(id)}`
  const taskKey = (event, id) => scoped(event, 'task', id)
  const toolKey = (event, id) => scoped(event, 'tool', id)
  const add = (key) => {
    if (key && !parent.has(key)) {
      parent.set(key, key)
      firstSeen.set(key, observationCounter += 1)
    }
  }
  const find = (key) => {
    const next = parent.get(key)
    if (!next || next === key) return key
    const root = find(next)
    parent.set(key, root)
    return root
  }
  const union = (left, right) => {
    add(left)
    add(right)
    const a = find(left)
    const b = find(right)
    if (a !== b) parent.set(b, a)
  }

  const taskByTool = new Map()
  const toolByTask = new Map()
  const parentToolByTool = new Map()
  for (const { event } of capture.events) {
    if (event.type === 'workflow_update' && !workflowModel.workflowID(event)) {
      if (event.taskId) add(taskKey(event, event.taskId))
      if (event.toolUseId) add(toolKey(event, event.toolUseId))
      if (event.taskId && event.toolUseId) {
        const providerToolKey = toolKey(event, event.toolUseId)
        const providerTaskKey = taskKey(event, event.taskId)
        const priorTask = taskByTool.get(providerToolKey)
        const priorTool = toolByTask.get(providerTaskKey)
        const provisionalSelfTaskKey = taskKey(event, event.toolUseId)
        if (priorTask && priorTask !== providerTaskKey && priorTask !== provisionalSelfTaskKey) {
          throw new Error('one provider tool id named two authoritative child tasks')
        }
        if (priorTool && priorTool !== providerToolKey) {
          throw new Error('one authoritative child task named two provider tool ids')
        }
        taskByTool.set(providerToolKey, providerTaskKey)
        if (priorTask === provisionalSelfTaskKey && priorTask !== providerTaskKey) {
          toolByTask.delete(priorTask)
        }
        toolByTask.set(providerTaskKey, providerToolKey)
        union(providerTaskKey, providerToolKey)
      }
    } else if (event.type === 'tool_use' && event.name === 'Task' && event.toolUseId
        && !workflowModel.workflowIDFromTool(event, event.toolUseId)) {
      add(toolKey(event, event.toolUseId))
    }
    if (event.type === 'tool_use' && event.toolUseId) {
      const key = toolKey(event, event.toolUseId)
      const parentTool = event.parentToolUseId ?? null
      if (parentToolByTool.has(key) && parentToolByTool.get(key) !== parentTool) {
        throw new Error('one provider tool call named two different owners')
      }
      parentToolByTool.set(key, parentTool)
    }
  }

  const portableAgentByComponent = new Map()
  let agentCounter = 0
  for (const key of [...parent.keys()].sort(
    (left, right) => firstSeen.get(left) - firstSeen.get(right))) {
    const root = find(key)
    if (!portableAgentByComponent.has(root)) {
      portableAgentByComponent.set(root, `agent-${agentCounter += 1}`)
    }
  }
  const agentIDForKey = (key) => {
    if (!key || !parent.has(key)) return null
    return portableAgentByComponent.get(find(key))
  }
  const agentIDFromTask = (event, rawID) => {
    if (!rawID) return null
    return agentIDForKey(taskKey(event, rawID))
  }
  const agentIDFromTool = (event, rawID) => {
    if (!rawID) return null
    return agentIDForKey(toolKey(event, rawID))
  }
  const agentIDFromReference = (event, rawID) => {
    const byTask = agentIDFromTask(event, rawID)
    const byTool = agentIDFromTool(event, rawID)
    if (byTask && byTool && byTask !== byTool) {
      throw new Error('provider agent reference is ambiguous between task and tool namespaces')
    }
    return byTask ?? byTool
  }

  const callIDs = new Map()
  let callCounter = 0
  const callID = (event, rawID) => {
    if (!rawID) return null
    const key = scoped(event, 'call', rawID)
    if (!callIDs.has(key)) callIDs.set(key, `call-${callCounter += 1}`)
    return callIDs.get(key)
  }
  const steeringIDs = new Map()
  let steeringCounter = 0
  const steeringID = (event, rawID) => {
    if (!rawID) return null
    const key = scoped(event, 'steering', rawID)
    if (!steeringIDs.has(key)) steeringIDs.set(key, `steering-${steeringCounter += 1}`)
    return steeringIDs.get(key)
  }

  // Approval/question request ids and client response ids occupy distinct namespaces. They alias
  // only through an outbound response the capture actually observed; equal raw strings never join
  // by coincidence. This mirrors the child task/tool collision defense above.
  const interactionParent = new Map()
  const interactionOrder = new Map()
  const interactionFamily = new Map()
  let interactionObservation = 0
  const interactionKey = (event, family, role, rawID) =>
    scoped(event, `interaction:${family}:${role}`, rawID)
  const addInteraction = (key, family) => {
    if (!key || interactionParent.has(key)) return
    interactionParent.set(key, key)
    interactionOrder.set(key, interactionObservation += 1)
    interactionFamily.set(key, family)
  }
  const findInteraction = (key) => {
    const next = interactionParent.get(key)
    if (!next || next === key) return key
    const root = findInteraction(next)
    interactionParent.set(key, root)
    return root
  }
  const responseByRequest = new Map()
  const requestByResponse = new Map()
  const bindInteraction = (event, family, requestRawID, responseRawID) => {
    const requestKey = interactionKey(event, family, 'request', requestRawID)
    const responseKey = interactionKey(event, family, 'response', responseRawID)
    if (!interactionParent.has(requestKey)) {
      throw new Error(`${family} response names an unobserved request`)
    }
    const priorResponse = responseByRequest.get(requestKey)
    const priorRequest = requestByResponse.get(responseKey)
    if (priorResponse && priorResponse !== responseKey) {
      throw new Error(`one ${family} request named two response ids`)
    }
    if (priorRequest && priorRequest !== requestKey) {
      throw new Error(`one ${family} response id named two requests`)
    }
    addInteraction(responseKey, family)
    const requestRoot = findInteraction(requestKey)
    const responseRoot = findInteraction(responseKey)
    if (requestRoot !== responseRoot) interactionParent.set(responseRoot, requestRoot)
    responseByRequest.set(requestKey, responseKey)
    requestByResponse.set(responseKey, requestKey)
  }
  const outboundBySequence = new Map()
  for (const outbound of capture.outboundRequests ?? []) {
    const sequence = outbound.afterEventSequence
    if (!outboundBySequence.has(sequence)) outboundBySequence.set(sequence, [])
    outboundBySequence.get(sequence).push(outbound)
  }
  for (const { seq, event } of capture.events) {
    if (event.type === 'permission_request' && event.permissionId) {
      addInteraction(interactionKey(event, 'authorization', 'request', event.permissionId),
        'authorization')
    } else if (event.type === 'question_request' && event.reqId) {
      addInteraction(interactionKey(event, 'question', 'request', event.reqId), 'question')
    }
    for (const outbound of outboundBySequence.get(seq) ?? []) {
      const request = outbound.request
      if (request.type === 'permission_response') {
        bindInteraction(request, 'authorization', request.permissionId, request.responseId)
      } else if (request.type === 'question_response') {
        bindInteraction(request, 'question', request.reqId, request.responseId)
      }
    }
    if (event.type === 'permission_response_ack') {
      const responseKey = interactionKey(event, 'authorization', 'response', event.permissionId)
      if (!interactionParent.has(responseKey)) {
        throw new Error('authorization acknowledgement names an unobserved response')
      }
    } else if (event.type === 'question_response_ack') {
      const responseKey = interactionKey(event, 'question', 'response', event.responseId)
      if (!interactionParent.has(responseKey)) {
        throw new Error('question acknowledgement names an unobserved response')
      }
      const requestKey = interactionKey(event, 'question', 'request', event.reqId)
      if (!interactionParent.has(requestKey)
          || findInteraction(requestKey) !== findInteraction(responseKey)) {
        throw new Error('question acknowledgement request/response correlation disagrees')
      }
    } else if (event.type === 'interaction_closed') {
      const family = event.interactionKind === 'permission'
        ? 'authorization'
        : event.interactionKind === 'question' ? 'question' : null
      if (!family) throw new Error('interaction closure has an unknown interaction kind')
      const requestKey = interactionKey(event, family, 'request', event.requestId)
      if (!interactionParent.has(requestKey)) {
        throw new Error(`${family} closure names an unobserved request`)
      }
    }
  }
  const portableInteractionByRoot = new Map()
  const interactionCounters = new Map()
  for (const key of [...interactionParent.keys()].sort(
    (left, right) => interactionOrder.get(left) - interactionOrder.get(right))) {
    const root = findInteraction(key)
    if (portableInteractionByRoot.has(root)) continue
    const family = interactionFamily.get(root) ?? interactionFamily.get(key)
    const next = (interactionCounters.get(family) ?? 0) + 1
    interactionCounters.set(family, next)
    portableInteractionByRoot.set(root, `${family}-${next}`)
  }
  const interactionID = (event, family, role, rawID) => {
    const key = interactionKey(event, family, role, rawID)
    if (!interactionParent.has(key)) {
      throw new Error(`${family} ${role} id was not registered`)
    }
    return portableInteractionByRoot.get(findInteraction(key))
  }

  const pathByAgentID = new Map()
  const agentIDByPath = new Map()
  for (const { event } of capture.events) {
    if (event.type !== 'workflow_update' || workflowModel.workflowID(event)) continue
    const path = providerAgentPath(event.agentPath)
    if (!path) continue
    const id = event.taskId
      ? agentIDFromTask(event, event.taskId)
      : agentIDFromTool(event, event.toolUseId)
    const key = path.join('/')
    const priorID = agentIDByPath.get(key)
    const priorPath = pathByAgentID.get(id)
    if (priorID && priorID !== id) {
      throw new Error(`provider logical agent path ${key} names two agents`)
    }
    if (priorPath && priorPath.join('/') !== key) {
      throw new Error(`one agent names two provider logical paths`)
    }
    agentIDByPath.set(key, id)
    pathByAgentID.set(id, path)
  }

  const definitions = new Map()
  const declare = ({
    id, parentId, type, task, callId, parentageProvenance, priority, logicalAgentPath,
  }) => {
    if (!id) return
    const existing = definitions.get(id)
    if (existing && existing.priority === priority && existing.parentId !== parentId) {
      throw new Error(
        `conflicting equally authoritative parents for ${id}: ${existing.parentId} and ${parentId}`)
    }
    if (!existing || priority > existing.priority) {
      definitions.set(id, {
        id,
        parentId,
        type: type || existing?.type || 'agent',
        task: task || existing?.task || '',
        callId: callId || existing?.callId || null,
        parentageProvenance,
        logicalAgentPath: logicalAgentPath || existing?.logicalAgentPath || null,
        priority,
      })
      return
    }
    if ((!existing.type || existing.type === 'agent') && type) existing.type = type
    if (!existing.task && task) existing.task = task
    if (!existing.callId && callId) existing.callId = callId
    if (!existing.logicalAgentPath && logicalAgentPath) {
      existing.logicalAgentPath = logicalAgentPath
    }
  }

  for (const { event } of capture.events) {
    if (event.type === 'workflow_update' && !workflowModel.workflowID(event)) {
      const id = event.taskId
        ? agentIDFromTask(event, event.taskId)
        : agentIDFromTool(event, event.toolUseId)
      const path = pathByAgentID.get(id) ?? null
      const pathParent = path?.length > 1
        ? agentIDByPath.get(path.slice(0, -1).join('/')) ?? null
        : 'root'
      const explicitParent = event.parentToolUseId
        ? agentIDFromTool(event, event.parentToolUseId)
        : null
      if (event.parentToolUseId && !explicitParent) {
        throw new Error('workflow child names an undeclared explicit parent agent')
      }
      if (explicitParent && pathParent && explicitParent !== pathParent) {
        throw new Error('explicit workflow parent disagrees with provider logical agent path')
      }
      const parentId = explicitParent ?? pathParent ?? 'root'
      declare({
        id,
        parentId,
        type: event.subagentType ?? event.taskType ?? 'agent',
        task: event.description ?? '',
        callId: callID(event, event.toolUseId),
        parentageProvenance: explicitParent
          ? 'explicit-parent-tool-use-id'
          : pathParent && path?.length > 1
            ? 'provider-logical-agent-path'
            : path?.length > 1
              ? 'provider-logical-agent-path-unresolved'
              : 'root-owned-workflow-event',
        priority: explicitParent ? 3 : pathParent && path?.length > 1 ? 2 : 0,
        logicalAgentPath: path,
      })
    } else if (event.type === 'tool_use' && event.name === 'Task'
        && !workflowModel.workflowIDFromTool(event, event.toolUseId)) {
      const parentID = event.parentToolUseId
        ? agentIDFromTool(event, event.parentToolUseId)
        : 'root'
      if (event.parentToolUseId && !parentID) {
        throw new Error('Task names an undeclared parent agent')
      }
      declare({
        id: agentIDFromTool(event, event.toolUseId),
        parentId: parentID,
        type: event.input?.subagent_type ?? 'agent',
        task: event.input?.description ?? '',
        callId: callID(event, event.toolUseId),
        parentageProvenance: event.parentToolUseId
          ? 'explicit-parent-tool-use-id'
          : 'root-owned-task-call',
        priority: 1,
      })
    }
  }
  for (const definition of definitions.values()) {
    if (definition.parentId !== 'root' && !definitions.has(definition.parentId)) {
      throw new Error(`agent ${definition.id} has undeclared parent ${definition.parentId}`)
    }
  }

  return {
    firstTurnId: turnIDs.values().next().value,
    turnID: portableTurnID,
    agentIDFromTask,
    agentIDFromTool,
    agentIDFromReference,
    callID,
    callOwnerID(event, rawID) {
      const explicitParent = event.parentToolUseId
      const observedParent = parentToolByTool.get(toolKey(event, rawID))
      if (explicitParent && observedParent && explicitParent !== observedParent) {
        throw new Error('tool result owner disagrees with the observed call owner')
      }
      const parentTool = explicitParent ?? observedParent
      return parentTool ? agentIDFromTool(event, parentTool) : 'root'
    },
    steeringID,
    authorizationIDForRequest: (event, rawID) =>
      interactionID(event, 'authorization', 'request', rawID),
    authorizationIDForResponse: (event, rawID) =>
      interactionID(event, 'authorization', 'response', rawID),
    questionIDForRequest: (event, rawID) =>
      interactionID(event, 'question', 'request', rawID),
    questionIDForResponse: (event, rawID) =>
      interactionID(event, 'question', 'response', rawID),
    interactionIDForClosure: (event) => {
      const family = event.interactionKind === 'permission' ? 'authorization' : 'question'
      return interactionID(event, family, 'request', event.requestId)
    },
    definitions,
  }
}

export function toCanonical(capture) {
  const workflowModel = canonicalWorkflowModel(capture)
  const identities = canonicalIdentityModel(capture, workflowModel)
  const agents = [{ id: 'root', parentId: null, type: 'root', task: null }]
  const agentById = new Map(agents.map((agent) => [agent.id, agent]))
  const spawnedAgents = new Set()
  const events = []
  const sessionIds = []
  let portableSessionCounter = 0
  let currentTurnId = identities.firstTurnId
  let assistantBuffer = null
  const outboundBySequence = new Map()
  const emittedControlResponses = new Set()
  const outboundDeliveryCounts = new Map()
  for (const outbound of capture.outboundRequests ?? []) {
    const sequence = outbound.afterEventSequence
    if (!outboundBySequence.has(sequence)) outboundBySequence.set(sequence, [])
    outboundBySequence.get(sequence).push(outbound)
    const request = outbound.request
    const responseID = request.type === 'permission_response'
      ? request.responseId
      : request.type === 'question_response' ? request.responseId : null
    if (responseID) {
      const key = `${request.type}\u0000${request.turnId ?? request.id}\u0000${responseID}`
      outboundDeliveryCounts.set(key, (outboundDeliveryCounts.get(key) ?? 0) + 1)
    }
  }
  for (const definition of identities.definitions.values()) {
    const agent = {
      id: definition.id,
      parentId: definition.parentId,
      type: definition.type,
      task: definition.task,
      parentageProvenance: definition.parentageProvenance,
      ...(definition.logicalAgentPath ? { logicalAgentPath: definition.logicalAgentPath } : {}),
    }
    agents.push(agent)
    agentById.set(agent.id, agent)
  }
  for (const definition of workflowModel.progressAgents) {
    const agent = structuredClone(definition)
    agents.push(agent)
    agentById.set(agent.id, agent)
  }
  const appendSpawn = (agent, observedAt, provenance) => {
    if (!agent || spawnedAgents.has(agent.id)) return
    if (agent.parentId && agent.parentId !== 'root') {
      const parentAgent = agentById.get(agent.parentId)
      if (!parentAgent) throw new Error(`agent ${agent.id} has dangling parent ${agent.parentId}`)
      appendSpawn(parentAgent, observedAt, parentAgent.parentageProvenance)
    }
    spawnedAgents.add(agent.id)
    const portableCallId = identities.definitions.get(agent.id)?.callId
    events.push({
      kind: 'agent_spawn', agentId: agent.parentId ?? 'root', spawnedAgentId: agent.id,
      ...(agent.workflowId != null && portableCallId == null
        ? {}
        : { toolUseId: portableCallId ?? null }),
      agentType: agent.type,
      ...(agent.task !== undefined ? { task: agent.task } : {}),
      ...(agent.workflowId != null ? { workflowId: agent.workflowId } : {}),
      ...(agent.phaseId != null ? { phaseId: agent.phaseId } : {}),
      ...(agent.sourceOrdinal != null ? { sourceOrdinal: agent.sourceOrdinal } : {}),
      spawnProvenance: provenance, observedAt, timeProvenance: 'capture-approximate',
    })
  }
  const flushAssistant = () => {
    if (assistantBuffer) {
      events.push(assistantBuffer)
      assistantBuffer = null
    }
  }

  const workflowLifecycleByID = new Map()
  const workflowUsageByID = new Map()
  const phaseLifecycleByID = new Map()
  const agentLifecycleByID = new Map()
  const unknownProgressObservations = new Set()
  const known = (target, key, value) => {
    if (value !== undefined) target[key] = value ?? null
  }
  const enrich = (target, key, value) => {
    if (value === undefined || value === null) return
    if (typeof value === 'string' && value.length === 0) return
    target[key] = value
  }
  const maximize = (target, key, value) => {
    if (typeof value !== 'number' || !Number.isFinite(value)) return
    const previous = target[key]
    target[key] = typeof previous === 'number' && Number.isFinite(previous)
      ? Math.max(previous, value)
      : value
  }
  const applyMonotonicState = (next, previous, reportedValue) => {
    if (reportedValue === undefined) return
    const reportedState = normalizedWorkState(reportedValue)
    const priorState = previous?.state ?? null
    next.reportedState = reportedState
    const terminalFailureRefinement = priorState
      && terminalOutcome(priorState) === 'succeeded'
      && (reportedState === 'failed' || reportedState === 'killed')
    if (priorState && TERMINAL_WORK_STATES.has(priorState)
        && reportedState !== priorState && !terminalFailureRefinement) {
      next.state = priorState
      next.outcome = terminalOutcome(priorState)
      next.stateProvenance = TERMINAL_WORK_STATES.has(reportedState)
        ? 'first-terminal-observation-wins'
        : 'terminal-monotonic-no-resurrection'
      return
    }
    next.state = reportedState
    next.outcome = terminalOutcome(reportedState)
    next.stateProvenance = terminalFailureRefinement
      ? 'provider-terminal-failure-refinement'
      : 'provider-reported'
  }
  const appendChanged = (stateMap, key, event) => {
    const comparison = { ...event }
    delete comparison.observedAt
    delete comparison.timeProvenance
    if (sameSnapshot(stateMap.get(key), comparison)) return false
    stateMap.set(key, structuredClone(comparison))
    events.push(event)
    return true
  }
  const appendToolObservation = ({
    agentId, workflowId = null, phaseId = null, toolEvent, toolTarget,
    turnId, observedAt, source = 'workflow-update',
  }) => {
    if (toolEvent == null && toolTarget == null) return
    const target = portableToolTarget(toolTarget)
    const observation = {
      kind: 'agent_tool_observation', agentId, workflowId, phaseId,
      name: toolEvent ?? null, ...target,
      completeness: 'summary-only', source, turnId,
      observedAt, timeProvenance: 'capture-approximate',
    }
    // `toolEvent` is a point observation, not a cumulative latest-state field. Two identical Bash
    // calls are two historical facts. Only callers translating an explicitly cumulative transport
    // collection may dedupe that collection before invoking this helper.
    events.push(observation)
  }
  const appendInertProgressObservation = ({
    workflowId, ownerAgentId, progress, turnId, observedAt, recognition, reason = null,
  }) => {
    const safe = {
      entryType: typeof progress.type === 'string' ? progress.type : null,
      sourceOrdinal: validSourceOrdinal(progress.index) ? progress.index : null,
      title: typeof progress.title === 'string' ? progress.title : null,
      phaseSourceOrdinal: validSourceOrdinal(progress.phaseIndex) ? progress.phaseIndex : null,
      label: typeof progress.label === 'string' ? progress.label : null,
      phaseTitle: typeof progress.phaseTitle === 'string' ? progress.phaseTitle : null,
      reportedState: typeof progress.state === 'string'
        ? normalizedWorkState(progress.state)
        : null,
      observedModel: typeof progress.model === 'string' ? progress.model : null,
      attempt: Number.isSafeInteger(progress.attempt) ? progress.attempt : null,
      lastToolName: typeof progress.lastToolName === 'string' ? progress.lastToolName : null,
      lastToolSummary: typeof progress.lastToolSummary === 'string'
        ? progress.lastToolSummary : null,
      promptPreview: typeof progress.promptPreview === 'string' ? progress.promptPreview : null,
      promptCompleteness: 'preview',
      tokens: Number.isSafeInteger(progress.tokens) ? progress.tokens : null,
      toolCalls: Number.isSafeInteger(progress.toolCalls) ? progress.toolCalls : null,
      resultPreview: typeof progress.resultPreview === 'string' ? progress.resultPreview : null,
      resultCompleteness: 'preview',
      error: typeof progress.error === 'string' ? progress.error : null,
      durationMs: Number.isSafeInteger(progress.durationMs) ? progress.durationMs : null,
    }
    const key = JSON.stringify({ workflowId, recognition, reason, ...safe })
    if (unknownProgressObservations.has(key)) return
    unknownProgressObservations.add(key)
    events.push({
      kind: 'workflow_progress_observation', workflowId,
      agentId: ownerAgentId, recognition, malformedReason: reason, ...safe,
      turnId, observedAt, timeProvenance: 'capture-approximate',
    })
  }
  const mergedUsage = (previous, usage) => {
    const next = {}
    for (const key of [
      'totalTokens', 'inputTokens', 'cachedInputTokens', 'outputTokens',
      'reasoningOutputTokens', 'toolUses', 'durationMs', 'toolUsesObserved',
    ]) {
      if (previous?.[key] !== undefined) next[key] = previous[key]
    }
    for (const [key, value] of Object.entries({
      inputTokens: usage?.inputTokens,
      cachedInputTokens: usage?.cachedInputTokens,
      outputTokens: usage?.outputTokens,
      reasoningOutputTokens: usage?.reasoningOutputTokens,
    })) known(next, key, value)
    for (const key of ['totalTokens', 'toolUses', 'durationMs']) {
      maximize(next, key, usage?.[key])
    }
    if (previous?.toolUsesObserved === true || usage?.toolUsesObserved === true) {
      next.toolUsesObserved = true
    } else if (usage?.toolUsesObserved !== undefined && usage?.toolUsesObserved !== null) {
      next.toolUsesObserved = usage.toolUsesObserved === true
    }
    return next
  }
  const applyErrorFailure = (next, previous, error) => {
    if (typeof error !== 'string' || error.length === 0) return
    const outcome = terminalOutcome(next.state)
    if (outcome === 'failed' || outcome === 'stopped') return
    next.state = 'failed'
    next.outcome = 'failed'
    next.stateProvenance = previous?.state && terminalOutcome(previous.state) === 'succeeded'
      ? 'error-terminal-failure-refinement'
      : 'error-implied-failure'
  }
  const appendWorkflowUpdate = (source, observedAt) => {
    const workflowId = workflowModel.workflowID(source)
    if (!workflowId) return false
    const workflow = workflowModel.workflows.find((item) => item.id === workflowId)
    if (!workflow) throw new Error('workflow update resolved to an undeclared workflow')

    if (source.parentToolUseId) {
      const owner = identities.agentIDFromTool(source, source.parentToolUseId)
      if (!owner) throw new Error('workflow names an undeclared explicit owner agent')
      if (workflow.ownerAgentId !== 'root' && workflow.ownerAgentId !== owner) {
        throw new Error('workflow names two different explicit owner agents')
      }
      workflow.ownerAgentId = owner
      workflow.parentageProvenance = 'explicit-parent-tool-use-id'
      for (const agent of agents.filter((item) => item.workflowId === workflowId)) {
        agent.parentId = owner
      }
    }

    const previous = workflowLifecycleByID.get(workflowId)
    const next = { ...(previous ?? {
      workflowId, agentId: workflow.ownerAgentId, phase: null, state: null, outcome: null,
      reportedState: null, stateProvenance: null, providerConfirmed: false,
      name: null, taskType: null, subagentType: null, description: null,
      summary: null, observedModel: null, logicalAgentPath: null,
      parentageProvenance: null, error: null,
    }) }
    next.agentId = workflow.ownerAgentId
    enrich(next, 'phase', source.phase)
    if (source.isWorkflowRun === true) next.providerConfirmed = true
    else if (source.isWorkflowRun === false && next.providerConfirmed !== true) {
      next.providerConfirmed = false
    }
    enrich(next, 'name', source.workflowName)
    enrich(next, 'taskType', source.taskType)
    enrich(next, 'subagentType', source.subagentType)
    enrich(next, 'description', source.description)
    enrich(next, 'summary', source.summary)
    enrich(next, 'observedModel', source.model)
    const logicalPath = providerAgentPath(source.agentPath)
    if (logicalPath) next.logicalAgentPath = logicalPath
    if (workflow.parentageProvenance) {
      next.parentageProvenance = workflow.parentageProvenance
    }
    enrich(next, 'error', source.error)
    applyMonotonicState(next, previous, source.status)
    applyErrorFailure(next, previous, next.error)
    appendChanged(workflowLifecycleByID, workflowId, {
      kind: 'workflow_lifecycle', ...next, turnId: identities.turnID(source),
      observedAt, timeProvenance: 'capture-approximate',
    })

    if (source.usage && typeof source.usage === 'object') {
      const priorUsage = workflowUsageByID.get(workflowId)
      const usage = mergedUsage(priorUsage, source.usage)
      appendChanged(workflowUsageByID, workflowId, {
        kind: 'workflow_usage', workflowId, agentId: workflow.ownerAgentId,
        ...usage, measurementKind: 'cumulative', turnId: identities.turnID(source),
        observedAt, timeProvenance: 'capture-approximate',
      })
    }
    appendToolObservation({
      agentId: workflow.ownerAgentId, workflowId,
      toolEvent: source.toolEvent, toolTarget: source.toolTarget,
      turnId: identities.turnID(source), observedAt,
    })

    for (const progress of source.workflowProgress ?? []) {
      if (!progress || typeof progress !== 'object') continue
      if (progress.type === 'workflow_phase') {
        if (!validSourceOrdinal(progress.index)) {
          appendInertProgressObservation({
            workflowId, ownerAgentId: workflow.ownerAgentId, progress,
            turnId: identities.turnID(source), observedAt,
            recognition: 'malformed-inert', reason: 'workflow-phase-index-not-nonnegative-integer',
          })
          continue
        }
        const phaseId = workflowModel.phaseID(workflowId, progress.index)
        const priorPhase = phaseLifecycleByID.get(phaseId)
        const phase = { ...(priorPhase ?? {
          workflowId, phaseId, agentId: workflow.ownerAgentId,
          sourceOrdinal: progress.index ?? null, title: null, state: null,
          reportedState: null, outcome: null, stateProvenance: null,
        }) }
        enrich(phase, 'sourceOrdinal', progress.index)
        enrich(phase, 'title', progress.title)
        applyMonotonicState(phase, priorPhase, progress.state)
        appendChanged(phaseLifecycleByID, phaseId, {
          kind: 'workflow_phase_lifecycle', ...phase,
          turnId: identities.turnID(source), observedAt,
          timeProvenance: 'capture-approximate',
        })
      } else if (progress.type === 'workflow_agent') {
        if (!validSourceOrdinal(progress.index) || !validSourceOrdinal(progress.phaseIndex)) {
          appendInertProgressObservation({
            workflowId, ownerAgentId: workflow.ownerAgentId, progress,
            turnId: identities.turnID(source), observedAt,
            recognition: 'malformed-inert',
            reason: 'workflow-agent-slot-not-nonnegative-integers',
          })
          continue
        }
        const agentId = workflowModel.progressAgentID(workflowId, progress)
        const agent = agentById.get(agentId)
        if (!agent) throw new Error('workflow progress names an undeclared workflow agent')
        appendSpawn(agent, observedAt, 'observed-workflow-progress-agent')
        const priorAgent = agentLifecycleByID.get(agentId)
        const lifecycle = { ...(priorAgent ?? {
          workflowId, phaseId: workflowModel.phaseID(workflowId, progress.phaseIndex),
          sourceOrdinal: progress.index ?? null, label: null, phaseTitle: null,
          phase: 'workflow-progress', state: null, reportedState: null, outcome: null,
          stateProvenance: null, observedModel: null, attempt: null,
          lastToolName: null, lastToolSummary: null, promptPreview: null,
          promptCompleteness: 'preview', tokens: null, toolCalls: null,
          resultPreview: null, resultCompleteness: 'preview', error: null,
          durationMs: null,
        }) }
        enrich(lifecycle, 'sourceOrdinal', progress.index)
        enrich(lifecycle, 'phaseId', workflowModel.phaseID(workflowId, progress.phaseIndex))
        enrich(lifecycle, 'label', progress.label)
        enrich(lifecycle, 'phaseTitle', progress.phaseTitle)
        enrich(lifecycle, 'observedModel', progress.model)
        enrich(lifecycle, 'attempt', progress.attempt)
        enrich(lifecycle, 'lastToolName', progress.lastToolName)
        enrich(lifecycle, 'lastToolSummary', progress.lastToolSummary)
        enrich(lifecycle, 'promptPreview', progress.promptPreview)
        maximize(lifecycle, 'tokens', progress.tokens)
        maximize(lifecycle, 'toolCalls', progress.toolCalls)
        enrich(lifecycle, 'resultPreview', progress.resultPreview)
        enrich(lifecycle, 'error', progress.error)
        maximize(lifecycle, 'durationMs', progress.durationMs)
        applyMonotonicState(lifecycle, priorAgent, progress.state)
        applyErrorFailure(lifecycle, priorAgent, lifecycle.error)
        appendChanged(agentLifecycleByID, agentId, {
          kind: 'agent_lifecycle', agentId, ...lifecycle,
          turnId: identities.turnID(source), taskId: agentId, toolUseId: null,
          lifecycleScope: 'workflow-progress', taskType: agent.type,
          subagentType: agent.type, description: null, summary: null,
          usage: {
            totalTokens: lifecycle.tokens,
            toolUses: lifecycle.toolCalls,
            measurementKind: 'cumulative',
          },
          observedAt, timeProvenance: 'capture-approximate',
        })
      } else {
        appendInertProgressObservation({
          workflowId, ownerAgentId: workflow.ownerAgentId, progress,
          turnId: identities.turnID(source), observedAt,
          recognition: 'unrecognized-inert', reason: 'unrecognized-workflow-progress-type',
        })
      }
    }
    return true
  }

  // The user's accepted prompt is part of the record even though the wire carries it in the
  // REQUEST direction (the capture preserves it separately).
  events.push({
    kind: 'user_message', agentId: 'user', text: capture.prompt,
    turnId: currentTurnId, observedAt: capture.promptObservedAt ?? null,
    timeProvenance: capture.promptObservedAt ? 'capture-approximate' : 'unknown',
  })

  for (const { seq, observedAt, event } of capture.events) {
    switch (event.type) {
      case 'turn_started':
        flushAssistant()
        currentTurnId = identities.turnID(event)
        events.push({
          kind: 'turn_started', agentId: 'root', turnId: currentTurnId,
          observedAt, timeProvenance: 'capture-approximate',
        })
        break
      case 'session':
        // The wire value is a provider resume handle and stays private. The spike mints a
        // record-local portable identity from boundary order; the format review still owes final lineage
        // semantics, and the provenance makes this normalization explicit rather than magical.
        portableSessionCounter += 1
        sessionIds.push(`provider-session-${portableSessionCounter}`)
        events.push({
          kind: 'session', sessionId: `provider-session-${portableSessionCounter}`,
          turnId: identities.turnID(event),
          sessionIdentityProvenance: 'minted-from-boundary-order', observedAt,
          timeProvenance: 'capture-approximate',
        })
        break
      case 'delta': {
        if (!assistantBuffer) {
          assistantBuffer = {
            kind: 'assistant_message', agentId: 'root', text: '',
            turnId: identities.turnID(event),
            observedAt, timeProvenance: 'capture-approximate',
          }
        }
        assistantBuffer.text += event.text ?? ''
        break
      }
      case 'tool_use': {
        flushAssistant()
        const owner = event.parentToolUseId
          ? identities.agentIDFromTool(event, event.parentToolUseId)
          : 'root'
        if (!owner) throw new Error('tool event names an undeclared parent agent')
        const invokedWorkflowID = event.name === 'Task'
          ? workflowModel.workflowIDFromTool(event, event.toolUseId)
          : null
        if (invokedWorkflowID) {
          events.push({
            kind: 'workflow_invocation', agentId: owner, workflowId: invokedWorkflowID,
            toolUseId: identities.callID(event, event.toolUseId),
            turnId: identities.turnID(event), task: event.input?.description ?? '',
            workflowType: event.input?.subagent_type ?? null,
            observedAt, timeProvenance: 'capture-approximate',
          })
        } else if (event.name === 'Task') {
          const agent = agentById.get(identities.agentIDFromTool(event, event.toolUseId))
          if (!agent) throw new Error('Task call does not resolve to a declared child agent')
          appendSpawn(agent, observedAt, 'explicit-task-tool-call')
        } else if (event.name === 'SendMessage' && event.input?.recipient) {
          // The wire's documented gap: the recipient exists only inside the sender's tool
          // input. Canonical records the edge — with provenance saying it was inferred, so a
          // projection can either carry it (extension) or drop it (loss), never invent it.
          const recipient = identities.agentIDFromReference(event, event.input.recipient)
          if (!recipient) throw new Error('SendMessage names an undeclared recipient agent')
          events.push({
            kind: 'agent_message', agentId: owner,
            recipientAgentId: recipient,
            summary: event.input.summary ?? '',
            toolUseId: identities.callID(event, event.toolUseId),
            turnId: identities.turnID(event),
            recipientProvenance: 'inferred-from-tool-input',
            observedAt, timeProvenance: 'capture-approximate',
          })
        } else {
          events.push({
            kind: 'tool_call', agentId: owner,
            toolUseId: identities.callID(event, event.toolUseId),
            turnId: identities.turnID(event), name: event.name, input: event.input ?? null,
            observedAt, timeProvenance: 'capture-approximate',
          })
        }
        break
      }
      case 'tool_result': {
        flushAssistant()
        const completedAgentID = identities.agentIDFromTool(event, event.toolUseId)
        const isSpawnClose = Boolean(completedAgentID && agentById.has(completedAgentID))
        const owner = identities.callOwnerID(event, event.toolUseId)
        if (!owner) throw new Error('tool result names an undeclared parent agent')
        const observedOutcome = terminalOutcome(event.status)
        const isError = event.isError === true || observedOutcome === 'failed'
        const disposition = event.subagentResultDisposition ?? null
        const outcome = disposition === 'launched'
          ? 'launched'
          : isError ? 'failed' : observedOutcome ?? 'unknown'
        events.push({
          kind: isSpawnClose ? 'agent_call_result' : 'tool_result',
          agentId: owner,
          toolUseId: identities.callID(event, event.toolUseId),
          ...(isSpawnClose ? { completedAgentId: completedAgentID } : {}),
          turnId: identities.turnID(event),
          result: event.result ?? '',
          status: event.status ?? null,
          isError,
          outcome,
          ...(isSpawnClose ? {
            disposition,
            providerTaskIdPresent: Boolean(event.subagentTaskId),
          } : {}),
          observedAt, timeProvenance: 'capture-approximate',
        })
        break
      }
      case 'usage':
        flushAssistant()
        events.push({
          kind: 'usage', agentId: 'root', turnId: identities.turnID(event),
          inputTokens: event.input ?? null,
          cachedInputTokens: event.cachedInput ?? null,
          outputTokens: event.output ?? null,
          reasoningOutputTokens: event.reasoningOutput ?? null,
          observedAt, timeProvenance: 'capture-approximate',
        })
        break
      case 'workflow_update': {
        flushAssistant()
        if (appendWorkflowUpdate(event, observedAt)) break
        const agentID = event.taskId
          ? identities.agentIDFromTask(event, event.taskId)
          : identities.agentIDFromTool(event, event.toolUseId)
        const agent = agentById.get(agentID)
        if (!agent) throw new Error('workflow update does not resolve to a declared child agent')
        appendSpawn(agent, observedAt, 'observed-workflow-lifecycle')
        events.push({
          kind: 'agent_lifecycle', agentId: agent.id,
          turnId: identities.turnID(event),
          phase: event.phase ?? null,
          state: event.status ?? null,
          outcome: terminalOutcome(event.status),
          taskId: agent.id,
          toolUseId: identities.callID(event, event.toolUseId),
          taskType: event.taskType ?? null,
          subagentType: event.subagentType ?? null,
          description: event.description ?? null,
          summary: event.summary ?? null,
          ...(event.workflowName !== undefined ? { workflowName: event.workflowName } : {}),
          ...(event.isWorkflowRun !== undefined
            ? { providerConfirmedWorkflow: event.isWorkflowRun === true }
            : {}),
          ...(providerAgentPath(event.agentPath)
            ? { logicalAgentPath: providerAgentPath(event.agentPath) }
            : {}),
          ...(event.agentPath !== undefined
            ? { parentageProvenance: agent.parentageProvenance ?? null }
            : {}),
          lastToolName: event.lastToolName ?? null,
          resultPreview: event.resultPreview ?? null,
          observedModel: event.model ?? null,
          usage: event.usage ? {
            totalTokens: event.usage.totalTokens ?? null,
            inputTokens: event.usage.inputTokens ?? null,
            cachedInputTokens: event.usage.cachedInputTokens ?? null,
            outputTokens: event.usage.outputTokens ?? null,
            ...(event.usage.reasoningOutputTokens !== undefined
              ? { reasoningOutputTokens: event.usage.reasoningOutputTokens }
              : {}),
            ...(event.usage.toolUses !== undefined
              ? { toolUses: event.usage.toolUses }
              : {}),
            ...(event.usage.durationMs !== undefined
              ? { durationMs: event.usage.durationMs }
              : {}),
            ...(event.usage.toolUsesObserved !== undefined
              ? { toolUsesObserved: event.usage.toolUsesObserved }
              : {}),
          } : null,
          error: event.error ?? null,
          observedAt, timeProvenance: 'capture-approximate',
        })
        appendToolObservation({
          agentId: agent.id, toolEvent: event.toolEvent, toolTarget: event.toolTarget,
          turnId: identities.turnID(event), observedAt,
        })
        break
      }
      case 'permission_request':
        flushAssistant()
        events.push({
          kind: 'authorization_request', agentId: 'root', recipientAgentId: 'user',
          turnId: identities.turnID(event),
          interactionId: identities.authorizationIDForRequest(event, event.permissionId),
          toolName: event.name ?? 'tool',
          // Approval payloads are operative provider input and routinely contain absolute paths,
          // commands, patches, or other machine-local detail. The corresponding tool event owns
          // portable intent/content when captured; the authorization event records only the
          // decision boundary and an explicit omission until disclosure profiles can redact it.
          input: null,
          inputDisclosure: 'omitted-private-operative-input',
          boundaryRequest: event.writeEscape ? {
            kind: 'workspace-escape', locatorDisclosure: 'omitted-private-local',
          } : null,
          capability: event.capability ? {
            name: event.capability.name ?? null,
            title: event.capability.title ?? null,
            description: event.capability.description ?? null,
            safety: event.capability.safety ?? null,
          } : null,
          observedAt, timeProvenance: 'capture-approximate',
        })
        break
      case 'permission_response_ack': { // permissionId is the client response id on this leg.
        flushAssistant()
        const interactionId = identities.authorizationIDForResponse(event, event.permissionId)
        events.push({
          kind: 'authorization_ack', agentId: 'root', recipientAgentId: 'user',
          turnId: identities.turnID(event), interactionId,
          accepted: event.accepted === true,
          message: event.message ?? null,
          observedAt, timeProvenance: 'capture-approximate',
        })
        break
      }
      case 'question_request':
        flushAssistant()
        events.push({
          kind: 'question', agentId: 'root', recipientAgentId: 'user',
          turnId: identities.turnID(event),
          interactionId: identities.questionIDForRequest(event, event.reqId),
          questions: structuredClone(event.questions ?? []),
          observedAt, timeProvenance: 'capture-approximate',
        })
        break
      case 'question_response_ack': {
        flushAssistant()
        const interactionId = identities.questionIDForResponse(event, event.responseId)
        events.push({
          kind: 'answer_ack', agentId: 'root', recipientAgentId: 'user',
          turnId: identities.turnID(event), interactionId,
          accepted: event.accepted === true,
          message: event.message ?? null,
          observedAt, timeProvenance: 'capture-approximate',
        })
        break
      }
      case 'interaction_closed':
        flushAssistant()
        events.push({
          kind: 'interaction_closed', agentId: 'root', recipientAgentId: 'user',
          turnId: identities.turnID(event),
          interactionId: identities.interactionIDForClosure(event),
          interactionType: event.interactionKind === 'permission'
            ? 'authorization'
            : 'question',
          outcome: event.outcome,
          reason: event.reason,
          observedAt, timeProvenance: 'capture-approximate',
        })
        break
      case 'error':
        flushAssistant()
        events.push({
          kind: 'provider_error', agentId: 'root', turnId: identities.turnID(event),
          errorKind: event.errorKind ?? 'unknown',
          rateLimitType: event.rateLimitType ?? null,
          resetsAt: event.resetsAt ?? null,
          message: event.message ?? '',
          observedAt, timeProvenance: 'capture-approximate',
        })
        events.push({
          kind: 'turn_failed', agentId: 'root', turnId: identities.turnID(event),
          errorKind: event.errorKind ?? 'unknown', observedAt,
          timeProvenance: 'capture-approximate',
        })
        break
      case 'steer_ack':
      case 'steer_rejected':
        flushAssistant()
        events.push({
          kind: 'steering', agentId: 'root', requesterAgentId: 'user',
          turnId: identities.turnID(event),
          steeringId: identities.steeringID(event, event.steerId),
          state: event.type === 'steer_ack' ? 'accepted' : 'rejected',
          observedAt, timeProvenance: 'capture-approximate',
        })
        break
      case 'compact_boundary':
        // The provider-neutral wire publishes the moment reduced history becomes authoritative.
        // Preserve it as a first-class event: this is not transport status and later turns were
        // generated against a materially different context after this boundary.
        flushAssistant()
        events.push({
          kind: 'compaction', agentId: 'root',
          trigger: event.trigger ?? 'unknown',
          preTokens: event.preTokens ?? null,
          postTokens: event.postTokens ?? null,
          turnId: identities.turnID(event),
          observedAt, timeProvenance: 'capture-approximate',
        })
        break
      case 'context_usage':
        // Context samples are historical inputs to compaction/replay analysis, not UI-only
        // telemetry. Their ordering around a compaction boundary explains what later turns saw.
        flushAssistant()
        events.push({
          kind: 'context_usage', agentId: 'root',
          contextTokens: event.contextTokens ?? null,
          contextWindow: event.contextWindow ?? null,
          model: event.model ?? null,
          turnId: identities.turnID(event),
          observedAt, timeProvenance: 'capture-approximate',
        })
        break
      case 'done':
        flushAssistant()
        events.push({
          kind: event.interrupted === true ? 'turn_stopped' : 'turn_completed',
          agentId: 'root', turnId: identities.turnID(event),
          observedAt,
          timeProvenance: 'capture-approximate',
        })
        break
      default:
        break // ready / allowlist / model_catalog / turn_started / transient status are transport
    }
    for (const outbound of outboundBySequence.get(seq) ?? []) {
      const request = outbound.request
      flushAssistant()
      if (request.type === 'steer') {
        events.push({
          kind: 'steering_request', agentId: 'user', responderAgentId: 'root',
          turnId: identities.turnID(request),
          steeringId: identities.steeringID(request, request.steerId),
          text: request.prompt,
          observedAt: outbound.observedAt ?? null,
          timeProvenance: outbound.observedAt ? 'capture-approximate' : 'unknown',
        })
      } else if (request.type === 'permission_response') {
        const interactionId = identities.authorizationIDForResponse(request, request.responseId)
        const key = `${request.type}\u0000${request.turnId ?? request.id}\u0000${request.responseId}`
        if (emittedControlResponses.has(key)) continue
        emittedControlResponses.add(key)
        events.push({
          kind: 'authorization_response', agentId: 'user', recipientAgentId: 'root',
          turnId: identities.turnID(request), interactionId,
          decision: request.allow === true ? 'allow' : 'deny',
          requestedScope: request.always === true ? 'persistent' : 'once',
          message: request.message ?? null,
          operativeGrantIncluded: false,
          deliveryAttempts: outboundDeliveryCounts.get(key) ?? 1,
          observedAt: outbound.observedAt ?? null,
          timeProvenance: outbound.observedAt ? 'capture-approximate' : 'unknown',
        })
      } else if (request.type === 'question_response') {
        const interactionId = identities.questionIDForResponse(request, request.responseId)
        const key = `${request.type}\u0000${request.turnId ?? request.id}\u0000${request.responseId}`
        if (emittedControlResponses.has(key)) continue
        emittedControlResponses.add(key)
        events.push({
          kind: 'answer', agentId: 'user', recipientAgentId: 'root',
          turnId: identities.turnID(request), interactionId,
          answers: structuredClone(request.answers ?? {}),
          response: request.response ?? null,
          deliveryAttempts: outboundDeliveryCounts.get(key) ?? 1,
          observedAt: outbound.observedAt ?? null,
          timeProvenance: outbound.observedAt ? 'capture-approximate' : 'unknown',
        })
      } else if (request.type === 'interrupt') {
        events.push({
          kind: 'interruption_requested', agentId: 'user', recipientAgentId: 'root',
          turnId: identities.turnID(request),
          observedAt: outbound.observedAt ?? null,
          timeProvenance: outbound.observedAt ? 'capture-approximate' : 'unknown',
        })
      }
    }
  }
  return {
    format: CANONICAL_FORMAT,
    producer: structuredClone(capture.producer),
    profile: structuredClone(capture.profile),
    sessionIds,
    agents,
    ...(workflowModel.workflows.length > 0
      ? { workflows: structuredClone(workflowModel.workflows) }
      : {}),
    ...(workflowModel.workflowPhases.length > 0
      ? { workflowPhases: structuredClone(workflowModel.workflowPhases) }
      : {}),
    events: events.map((event, index) => ({ eventId: `event-${index + 1}`, ...event })),
  }
}

/// Structural equality for round-trip checks: agents with parentage, and the ordered
/// (kind, agentId, distinguishing-field) event skeleton. Timestamps are excluded (declared
/// capture-approximate) — comparing them would test the clock, not the mapping.
export function skeleton(canonical) {
  return {
    agents: canonical.agents.map((a) => `${a.id}<-${a.parentId}:${a.type}`).sort(),
    events: canonical.events.map((e) => {
      const tail = e.spawnedAgentId ?? e.interactionId ?? e.recipientAgentId
        ?? e.toolUseId ?? e.sessionId
        ?? e.trigger
        ?? (e.kind === 'context_usage' ? `${e.contextTokens ?? ''}/${e.contextWindow ?? ''}` : null)
        ?? (e.text ? String(e.text.length) : '')
      return `${e.kind}@${e.agentId ?? ''}:${tail ?? ''}`
    }),
  }
}
