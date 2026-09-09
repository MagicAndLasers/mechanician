// Run a pinned agentd fixture generator and capture one turn's NDJSON events.
// The capture stamps arrival order (seq) and an observation time; fixtures emit no provider
// timestamps, so times are marked capture-approximate downstream — never fabricated as provider
// event times (Stage A rule: unknown stays unknown).
import { spawn } from 'node:child_process'

const CHILD_TERMINAL_STATES = new Set([
  'cancelled', 'completed', 'error', 'failed', 'interrupted', 'stopped',
])
const ROOT_CONTENT_TYPES = new Set([
  'compact_boundary', 'context_usage', 'delta', 'interaction_closed', 'permission_request',
  'question_request', 'session', 'thinking', 'tool_result', 'tool_use', 'usage',
])

function exactStringRecord(value, label, keys) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) {
    throw new TypeError(`${label} must be a plain object`)
  }
  const ownKeys = Reflect.ownKeys(value)
  if (ownKeys.some((key) => typeof key !== 'string')) {
    throw new TypeError(`${label} must contain exactly: ${[...keys].sort().join(', ')}`)
  }
  const actual = ownKeys.sort()
  const expected = [...keys].sort()
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    throw new TypeError(`${label} must contain exactly: ${expected.join(', ')}`)
  }
  const result = {}
  for (const key of keys) {
    if (typeof value[key] !== 'string' || !value[key].trim()) {
      throw new TypeError(`${label}.${key} must be a non-empty string`)
    }
    result[key] = value[key]
  }
  return result
}

function explicitObservationTime(value, label) {
  if (value === null) return null
  if (typeof value !== 'string' || !Number.isFinite(Date.parse(value))) {
    throw new TypeError(`${label} must be an explicit timestamp string or null`)
  }
  return value
}

function steeringPlan(value) {
  if (!Array.isArray(value)) throw new TypeError('steeringRequests must be an array')
  const seen = new Set()
  return value.map((request, index) => {
    const normalized = exactStringRecord(
      request, `steeringRequests[${index}]`, ['steerId', 'prompt'])
    if (seen.has(normalized.steerId)) {
      throw new TypeError(`duplicate steering id: ${normalized.steerId}`)
    }
    seen.add(normalized.steerId)
    return normalized
  })
}

function exactRecordKeys(value, label, required, optional = []) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) {
    throw new TypeError(`${label} must be a plain object`)
  }
  const allowed = new Set([...required, ...optional])
  const keys = Reflect.ownKeys(value)
  if (keys.some((key) => typeof key !== 'string')
      || keys.some((key) => !allowed.has(key))
      || required.some((key) => !Object.prototype.hasOwnProperty.call(value, key))) {
    const optionalSuffix = optional.length ? `; optional: ${[...optional].sort().join(', ')}` : ''
    throw new TypeError(
      `${label} must contain required keys: ${[...required].sort().join(', ')}${optionalSuffix}`)
  }
  return value
}

function nonEmptyString(value, label) {
  if (typeof value !== 'string' || !value.trim()) {
    throw new TypeError(`${label} must be a non-empty string`)
  }
  return value
}

function plannedPermissionResponses(value) {
  if (!Array.isArray(value)) throw new TypeError('permissionResponses must be an array')
  const byResponseID = new Map()
  const responseIDByRequest = new Map()
  return value.map((candidate, index) => {
    const label = `permissionResponses[${index}]`
    const plan = exactRecordKeys(
      candidate, label,
      ['permissionId', 'responseId', 'allow', 'always'],
      ['message'],
    )
    const normalized = {
      permissionId: nonEmptyString(plan.permissionId, `${label}.permissionId`),
      responseId: nonEmptyString(plan.responseId, `${label}.responseId`),
      allow: plan.allow,
      always: plan.always,
      ...(plan.message === undefined
        ? {} : { message: nonEmptyString(plan.message, `${label}.message`) }),
    }
    if (typeof normalized.allow !== 'boolean' || typeof normalized.always !== 'boolean') {
      throw new TypeError(`${label}.allow and ${label}.always must be booleans`)
    }
    const fingerprint = JSON.stringify(normalized)
    const prior = byResponseID.get(normalized.responseId)
    if (prior && prior !== fingerprint) {
      throw new TypeError(`permission response id collision: ${normalized.responseId}`)
    }
    const priorResponseID = responseIDByRequest.get(normalized.permissionId)
    if (priorResponseID && priorResponseID !== normalized.responseId) {
      throw new TypeError(
        `permission ${normalized.permissionId} must reuse stable response id ${priorResponseID}`)
    }
    byResponseID.set(normalized.responseId, fingerprint)
    responseIDByRequest.set(normalized.permissionId, normalized.responseId)
    return normalized
  })
}

function stringAnswerRecord(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) {
    throw new TypeError(`${label} must be a plain object`)
  }
  const answers = {}
  for (const key of Reflect.ownKeys(value)) {
    if (typeof key !== 'string' || !key.trim() || typeof value[key] !== 'string') {
      throw new TypeError(`${label} must contain only non-empty string keys with string values`)
    }
    answers[key] = value[key]
  }
  return answers
}

function plannedQuestionResponses(value) {
  if (!Array.isArray(value)) throw new TypeError('questionResponses must be an array')
  const byResponseID = new Map()
  const responseIDByRequest = new Map()
  return value.map((candidate, index) => {
    const label = `questionResponses[${index}]`
    const plan = exactRecordKeys(
      candidate, label, ['reqId', 'responseId', 'answers'], ['response'])
    const normalized = {
      reqId: nonEmptyString(plan.reqId, `${label}.reqId`),
      responseId: nonEmptyString(plan.responseId, `${label}.responseId`),
      answers: stringAnswerRecord(plan.answers, `${label}.answers`),
      ...(plan.response === undefined
        ? {} : { response: nonEmptyString(plan.response, `${label}.response`) }),
    }
    const fingerprint = JSON.stringify(normalized)
    const prior = byResponseID.get(normalized.responseId)
    if (prior && prior !== fingerprint) {
      throw new TypeError(`question response id collision: ${normalized.responseId}`)
    }
    const priorResponseID = responseIDByRequest.get(normalized.reqId)
    if (priorResponseID && priorResponseID !== normalized.responseId) {
      throw new TypeError(`question ${normalized.reqId} must reuse stable response id ${priorResponseID}`)
    }
    byResponseID.set(normalized.responseId, fingerprint)
    responseIDByRequest.set(normalized.reqId, normalized.responseId)
    return normalized
  })
}

const INTERRUPT_SELECTOR_FIELDS = new Set([
  'type', 'id', 'status', 'phase', 'taskId', 'permissionId', 'reqId',
])

function interruptSelector(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) {
    throw new TypeError(`${label} must be a plain object`)
  }
  const keys = Reflect.ownKeys(value)
  if (!keys.length || !keys.includes('type')
      || keys.some((key) => typeof key !== 'string' || !INTERRUPT_SELECTOR_FIELDS.has(key))) {
    throw new TypeError(
      `${label} must contain type and only supported scalar event selector fields`)
  }
  const result = {}
  for (const key of keys) {
    const field = value[key]
    if (typeof field === 'string') {
      result[key] = nonEmptyString(field, `${label}.${key}`)
    } else if (typeof field === 'boolean' || (typeof field === 'number' && Number.isFinite(field))) {
      result[key] = field
    } else {
      throw new TypeError(`${label}.${key} must be a string, boolean, or finite number`)
    }
  }
  if (result.type === 'capture_quiescent') {
    throw new TypeError(`${label}.type cannot be capture_quiescent`)
  }
  return result
}

function plannedInterruptRequests(value) {
  if (!Array.isArray(value)) throw new TypeError('interruptRequests must be an array')
  const ids = new Set()
  return value.map((candidate, index) => {
    const label = `interruptRequests[${index}]`
    const plan = exactRecordKeys(candidate, label, ['id', 'after'])
    const id = nonEmptyString(plan.id, `${label}.id`)
    if (ids.has(id)) throw new TypeError(`duplicate interrupt request id: ${id}`)
    ids.add(id)
    return { id, after: interruptSelector(plan.after, `${label}.after`) }
  })
}

function deepFreeze(value, seen = new Set()) {
  if (value === null || typeof value !== 'object' || seen.has(value)) return value
  seen.add(value)
  for (const child of Object.values(value)) deepFreeze(child, seen)
  return Object.freeze(value)
}

function lifecycleMonitor() {
  let rootTerminal = null
  const children = new Map()
  const taskToolParents = new Map()
  const taskByTool = new Map()
  const toolByTask = new Map()
  const permissions = new Map()
  const questions = new Map()
  const permissionAttempts = new Map()
  const questionAttempts = new Map()

  const responseFingerprint = (request) => JSON.stringify(request)
  const rememberAttempt = (attempts, interaction, request, requestField, label) => {
    const responseID = request.responseId
    const requestID = request[requestField]
    const known = interaction.get(requestID)
    if (!known) throw new Error(`${label} response names unknown request ${requestID}`)
    const fingerprint = responseFingerprint(request)
    const prior = attempts.get(responseID)
    if (prior) {
      if (prior.requestID !== requestID || prior.fingerprint !== fingerprint) {
        throw new Error(`${label} response id collision: ${responseID}`)
      }
      prior.outstandingAcks += 1
      return
    }
    attempts.set(responseID, {
      requestID,
      request: structuredClone(request),
      fingerprint,
      outstandingAcks: 1,
      accepted: null,
    })
  }

  const observeOutbound = (request) => {
    switch (request.type) {
      case 'permission_response':
        rememberAttempt(
          permissionAttempts, permissions, request, 'permissionId', 'permission')
        break
      case 'question_response':
        rememberAttempt(questionAttempts, questions, request, 'reqId', 'question')
        break
      case 'interrupt':
        if (rootTerminal) throw new Error('interrupt request was sent after the root terminal')
        break
      default:
        break
    }
  }

  const observePermissionAck = (event) => {
    if (typeof event.permissionId !== 'string' || !event.permissionId) {
      throw new Error('permission acknowledgement did not identify its response')
    }
    if (typeof event.accepted !== 'boolean') {
      throw new Error(`permission acknowledgement ${event.permissionId} omitted accepted`)
    }
    const attempt = permissionAttempts.get(event.permissionId)
    if (!attempt || attempt.outstandingAcks < 1) {
      throw new Error(`permission acknowledgement ${event.permissionId} has no outbound response`)
    }
    attempt.outstandingAcks -= 1
    if (!event.accepted) return
    if (event.allow !== attempt.request.allow || event.always !== attempt.request.always) {
      throw new Error(`permission acknowledgement ${event.permissionId} changed the decision`)
    }
    const interaction = permissions.get(attempt.requestID)
    if (!interaction) throw new Error(`permission ${attempt.requestID} disappeared before acknowledgement`)
    if (interaction.acceptedResponseID
        && interaction.acceptedResponseID !== event.permissionId) {
      throw new Error(`permission ${attempt.requestID} accepted two different responses`)
    }
    interaction.acceptedResponseID = event.permissionId
    interaction.pending = false
    attempt.accepted = true
  }

  const observeQuestionAck = (event) => {
    if (typeof event.responseId !== 'string' || !event.responseId) {
      throw new Error('question acknowledgement did not identify its response')
    }
    if (typeof event.accepted !== 'boolean') {
      throw new Error(`question acknowledgement ${event.responseId} omitted accepted`)
    }
    const attempt = questionAttempts.get(event.responseId)
    if (!attempt || attempt.outstandingAcks < 1) {
      throw new Error(`question acknowledgement ${event.responseId} has no outbound response`)
    }
    if (typeof event.reqId !== 'string' || event.reqId !== attempt.requestID) {
      throw new Error(`question acknowledgement ${event.responseId} changed its request`)
    }
    attempt.outstandingAcks -= 1
    if (!event.accepted) return
    const interaction = questions.get(attempt.requestID)
    if (!interaction) throw new Error(`question ${attempt.requestID} disappeared before acknowledgement`)
    if (interaction.acceptedResponseID
        && interaction.acceptedResponseID !== event.responseId) {
      throw new Error(`question ${attempt.requestID} accepted two different responses`)
    }
    interaction.acceptedResponseID = event.responseId
    interaction.pending = false
    attempt.accepted = true
  }

  const observeInteractionClosure = (event) => {
    if (!['permission', 'question'].includes(event.interactionKind)) {
      throw new Error('interaction closure has an unknown interaction kind')
    }
    if (typeof event.requestId !== 'string' || !event.requestId) {
      throw new Error('interaction closure did not identify its request')
    }
    if (typeof event.outcome !== 'string' || !event.outcome
        || typeof event.reason !== 'string' || !event.reason) {
      throw new Error(`interaction closure ${event.requestId} omitted its outcome or reason`)
    }
    const interaction = event.interactionKind === 'permission'
      ? permissions.get(event.requestId)
      : questions.get(event.requestId)
    const attempts = event.interactionKind === 'permission'
      ? permissionAttempts
      : questionAttempts
    if (!interaction) {
      throw new Error(
        `${event.interactionKind} closure names unknown request ${event.requestId}`)
    }
    if (!interaction.pending) {
      throw new Error(
        `${event.interactionKind} ${event.requestId} was already settled before closure`)
    }
    const responseAttempt = [...attempts.values()]
      .find((attempt) => attempt.requestID === event.requestId)
    if (responseAttempt) {
      throw new Error(
        `${event.interactionKind} ${event.requestId} closed after a response was delivered`)
    }
    interaction.pending = false
    interaction.closure = {
      outcome: event.outcome,
      reason: event.reason,
    }
  }

  const mergeChildAlias = (provisionalID, authoritativeID) => {
    if (provisionalID === authoritativeID) return
    const provisional = children.get(provisionalID)
    const authoritative = children.get(authoritativeID)
    if (provisional) {
      const merged = authoritative ?? {
        id: authoritativeID,
        parentId: provisional.parentId,
        state: null,
        stateHistory: [],
      }
      if (!merged.parentId) merged.parentId = provisional.parentId
      const history = []
      for (const state of [...provisional.stateHistory, ...merged.stateHistory]) {
        if (history.at(-1) !== state) history.push(state)
      }
      const firstTerminal = history.findIndex((state) => CHILD_TERMINAL_STATES.has(state))
      if (firstTerminal >= 0 && history.slice(firstTerminal + 1)
        .some((state) => state !== history[firstTerminal])) {
        throw new Error(
          `aliased child ${provisionalID}/${authoritativeID} changed state after terminal ${history[firstTerminal]}`)
      }
      merged.stateHistory = history
      merged.state = history.at(-1) ?? null
      children.set(authoritativeID, merged)
      children.delete(provisionalID)
    }
    for (const child of children.values()) {
      if (child.parentId === provisionalID) child.parentId = authoritativeID
    }
    for (const [tool, task] of taskByTool) {
      if (task === provisionalID) taskByTool.set(tool, authoritativeID)
    }
    toolByTask.delete(provisionalID)
  }

  const resolveParent = (toolUseId) => {
    const parentToolUseId = taskToolParents.get(toolUseId)
    if (!parentToolUseId) return null
    return taskByTool.get(parentToolUseId) ?? parentToolUseId
  }
  const childSnapshot = () => [...children.values()]
    .map((child) => ({
      id: child.id,
      parentId: child.parentId,
      state: child.state,
      stateHistory: [...child.stateHistory],
    }))
    .sort((left, right) => left.id.localeCompare(right.id))

  const observe = (event) => {
    if (rootTerminal && ROOT_CONTENT_TYPES.has(event.type)) {
      throw new Error(`root content ${event.type} arrived after terminal ${rootTerminal.type}`)
    }
    if (event.type === 'tool_use' && event.name === 'Task' && event.toolUseId) {
      taskToolParents.set(event.toolUseId, event.parentToolUseId ?? null)
      return null
    }
    if (event.type === 'permission_request') {
      if (typeof event.permissionId !== 'string' || !event.permissionId) {
        throw new Error('permission request did not identify itself')
      }
      if (permissions.has(event.permissionId)) {
        throw new Error(`duplicate permission request ${event.permissionId}`)
      }
      permissions.set(event.permissionId, {
        pending: true,
        acceptedResponseID: null,
      })
      return null
    }
    if (event.type === 'permission_response_ack') {
      observePermissionAck(event)
      return null
    }
    if (event.type === 'question_request') {
      if (typeof event.reqId !== 'string' || !event.reqId) {
        throw new Error('question request did not identify itself')
      }
      if (questions.has(event.reqId)) {
        throw new Error(`duplicate question request ${event.reqId}`)
      }
      questions.set(event.reqId, {
        pending: true,
        acceptedResponseID: null,
      })
      return null
    }
    if (event.type === 'question_response_ack') {
      observeQuestionAck(event)
      return null
    }
    if (event.type === 'interaction_closed') {
      observeInteractionClosure(event)
      return null
    }
    if (event.type === 'workflow_update') {
      let id = event.taskId ?? event.toolUseId
      if (!id) throw new Error('workflow update did not identify its child')
      if (event.toolUseId) {
        const priorTask = taskByTool.get(event.toolUseId)
        const priorTool = event.taskId ? toolByTask.get(event.taskId) : null
        if (priorTool && priorTool !== event.toolUseId) {
          throw new Error(`child ${event.taskId} was correlated with two tool ids`)
        }
        if (priorTask && priorTask !== id) mergeChildAlias(priorTask, id)
        taskByTool.set(event.toolUseId, id)
        toolByTask.set(id, event.toolUseId)
      }
      let child = children.get(id)
      if (!child) {
        child = {
          id,
          parentId: event.toolUseId ? resolveParent(event.toolUseId) : null,
          state: null,
          stateHistory: [],
        }
        children.set(id, child)
      } else if (!child.parentId && event.toolUseId) {
        child.parentId = resolveParent(event.toolUseId)
      }
      // Status is the lifecycle state. A notification that only refreshes summary/model/tool
      // metadata must not silently revive, finish, or otherwise mutate the child state.
      if (event.status !== undefined && event.status !== null) {
        if (typeof event.status !== 'string' || !event.status) {
          throw new Error(`child ${id} emitted an invalid lifecycle state`)
        }
        if (child.state && CHILD_TERMINAL_STATES.has(child.state)
            && event.status !== child.state) {
          throw new Error(`child ${id} changed state after terminal ${child.state}`)
        }
        if (event.status !== child.state) {
          child.state = event.status
          child.stateHistory.push(event.status)
        }
      }
      return null
    }
    if (event.type === 'done' || event.type === 'error') {
      if (rootTerminal) throw new Error('root emitted more than one terminal event')
      rootTerminal = {
        type: event.type,
        id: event.id ?? null,
        interrupted: event.type === 'done' && event.interrupted === true,
      }
      return null
    }
    if (event.type !== 'capture_quiescent') return null
    if (event.protocolVersion !== 1) {
      throw new Error(`unsupported capture quiescence version ${event.protocolVersion ?? '<missing>'}`)
    }
    if (!rootTerminal) throw new Error('capture declared quiescence before the root was terminal')
    const active = childSnapshot().filter((child) => !CHILD_TERMINAL_STATES.has(child.state))
    if (active.length) {
      throw new Error(`capture declared quiescence with active children: ${active.map((c) => c.id).join(', ')}`)
    }
    const pendingPermissions = [...permissions.entries()]
      .filter(([, interaction]) => interaction.pending).map(([id]) => id)
    const pendingQuestions = [...questions.entries()]
      .filter(([, interaction]) => interaction.pending).map(([id]) => id)
    const unacknowledged = [
      ...[...permissionAttempts.entries()].filter(([, attempt]) => attempt.outstandingAcks > 0)
        .map(([id]) => `permission response ${id}`),
      ...[...questionAttempts.entries()].filter(([, attempt]) => attempt.outstandingAcks > 0)
        .map(([id]) => `question response ${id}`),
    ]
    const pendingInteractions = [
      ...pendingPermissions.map((id) => `permission ${id}`),
      ...pendingQuestions.map((id) => `question ${id}`),
      ...unacknowledged,
    ]
    if (pendingInteractions.length) {
      throw new Error(
        `capture declared quiescence with pending interactions: ${pendingInteractions.join(', ')}`)
    }
    if (!event.root || event.root.type !== rootTerminal.type
        || (event.root.id ?? null) !== rootTerminal.id
        || Boolean(event.root.interrupted) !== rootTerminal.interrupted) {
      throw new Error('capture quiescence root summary disagrees with observed terminal event')
    }
    const declared = Array.isArray(event.children) ? event.children.map((child) => ({
      id: child?.id ?? null,
      parentId: child?.parentId ?? null,
      state: child?.state ?? null,
    })).sort((left, right) => String(left.id).localeCompare(String(right.id))) : null
    const observed = childSnapshot().map(({ id, parentId, state }) => ({ id, parentId, state }))
    if (!declared || JSON.stringify(declared) !== JSON.stringify(observed)) {
      throw new Error('capture quiescence child summary disagrees with observed lifecycle')
    }
    return { protocolVersion: 1, root: { ...rootTerminal }, children: childSnapshot() }
  }

  return { observe, observeOutbound }
}

export function captureTurn(
  fixturePath,
  {
    prompt = 'go',
    promptObservedAt = null,
    timeoutMs = 40000,
    observedAtForSequence = null,
    completeWhen = null,
    requireQuiescence = false,
    steeringRequests = [],
    permissionResponses = [],
    questionResponses = [],
    interruptRequests = [],
    producer = {
      name: 'Mechanician R2 capture harness',
      version: '0.23.0',
      build: '207',
    },
    profile = {
      id: 'ai.mechanician.conversation-record.native-graph',
      version: '0-spike',
    },
  } = {},
) {
  if (typeof fixturePath !== 'string' || !fixturePath) {
    throw new TypeError('fixturePath must be a non-empty string')
  }
  if (typeof prompt !== 'string') throw new TypeError('prompt must be a string')
  const envelopeProducer = exactStringRecord(producer, 'producer', ['name', 'version', 'build'])
  const envelopeProfile = exactStringRecord(profile, 'profile', ['id', 'version'])
  const envelopePromptObservedAt = explicitObservationTime(promptObservedAt, 'promptObservedAt')
  const plannedSteers = steeringPlan(steeringRequests)
  const plannedPermissions = plannedPermissionResponses(permissionResponses)
  const plannedQuestions = plannedQuestionResponses(questionResponses)
  const plannedInterrupts = plannedInterruptRequests(interruptRequests)

  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [fixturePath], { stdio: ['pipe', 'pipe', 'inherit'] })
    const events = []
    const outboundRequests = []
    const lifecycle = lifecycleMonitor()
    let buffered = ''
    let seq = 0
    let settled = false
    let steeringSent = false
    let quiescence = null
    let currentTurnID = null
    const remainingPermissions = new Set(plannedPermissions.map((_, index) => index))
    const remainingQuestions = new Set(plannedQuestions.map((_, index) => index))
    const remainingInterrupts = new Set(plannedInterrupts.map((_, index) => index))
    const stopChild = () => {
      child.stdin.end()
      child.kill()
    }
    const fail = (error) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      stopChild()
      reject(error)
    }
    const finish = () => {
      if (settled) return
      if (requireQuiescence && !quiescence) {
        fail(new Error('capture reached a completion condition before explicit quiescence'))
        return
      }
      const unmatched = [
        ...[...remainingPermissions].map((index) => (
          `permission ${plannedPermissions[index].permissionId}/${plannedPermissions[index].responseId}`)),
        ...[...remainingQuestions].map((index) => (
          `question ${plannedQuestions[index].reqId}/${plannedQuestions[index].responseId}`)),
        ...[...remainingInterrupts].map((index) => (
          `interrupt ${plannedInterrupts[index].id}`)),
      ]
      if (unmatched.length) {
        fail(new Error(`capture has unmatched interaction plans: ${unmatched.join(', ')}`))
        return
      }
      settled = true
      clearTimeout(timer)
      stopChild()
      const snapshot = structuredClone({
        prompt,
        promptObservedAt: envelopePromptObservedAt,
        producer: envelopeProducer,
        profile: envelopeProfile,
        events,
        outboundRequests,
        quiescence,
      })
      resolve(deepFreeze(snapshot))
    }
    const timer = setTimeout(() => {
      fail(new Error(`fixture never completed within ${timeoutMs}ms`))
    }, timeoutMs)
    const recordAndSend = (request, observedAt) => {
      lifecycle.observeOutbound(request)
      outboundRequests.push({
        afterEventSequence: seq,
        observedAt,
        request: structuredClone(request),
      })
      child.stdin.write(`${JSON.stringify(request)}\n`)
    }
    const sendSteering = (turnID, observedAt) => {
      if (steeringSent || !plannedSteers.length) return
      steeringSent = true
      for (const plan of plannedSteers) {
        const request = {
          type: 'steer', id: turnID, turnId: turnID,
          steerId: plan.steerId, prompt: plan.prompt,
        }
        recordAndSend(request, observedAt)
      }
    }
    const sendInteractionResponses = (event, observedAt) => {
      if (event.type === 'permission_request') {
        for (const index of [...remainingPermissions]) {
          const plan = plannedPermissions[index]
          if (plan.permissionId !== event.permissionId) continue
          remainingPermissions.delete(index)
          recordAndSend({ type: 'permission_response', id: event.id, ...plan }, observedAt)
        }
      }
      if (event.type === 'question_request') {
        for (const index of [...remainingQuestions]) {
          const plan = plannedQuestions[index]
          if (plan.reqId !== event.reqId) continue
          remainingQuestions.delete(index)
          recordAndSend({ type: 'question_response', id: event.id, ...plan }, observedAt)
        }
      }
      for (const index of [...remainingInterrupts]) {
        const plan = plannedInterrupts[index]
        const matches = Object.entries(plan.after)
          .every(([key, value]) => event[key] === value)
        if (!matches) continue
        if (!currentTurnID) {
          throw new Error(`interrupt ${plan.id} matched before turn_started`)
        }
        remainingInterrupts.delete(index)
        recordAndSend({ type: 'interrupt', id: plan.id, turnId: currentTurnID }, observedAt)
      }
    }
    child.stdout.on('data', (chunk) => {
      if (settled) return
      buffered += chunk
      let index
      while ((index = buffered.indexOf('\n')) >= 0) {
        const line = buffered.slice(0, index)
        buffered = buffered.slice(index + 1)
        if (!line.trim()) continue
        let event
        try {
          event = JSON.parse(line)
        } catch {
          fail(new Error('fixture emitted malformed NDJSON'))
          return
        }
        if (!event || typeof event !== 'object' || Array.isArray(event)) {
          fail(new Error('fixture emitted a non-object event'))
          return
        }
        seq += 1
        let observedAt
        try {
          observedAt = explicitObservationTime(
            observedAtForSequence
              ? observedAtForSequence(seq, event)
              : new Date().toISOString(),
            `observedAt for sequence ${seq}`)
          const lifecycleResult = lifecycle.observe(event)
          if (event.type === 'capture_quiescent') {
            quiescence = {
              ...lifecycleResult,
              sequence: seq,
              observedAt,
            }
          } else {
            events.push({ seq, observedAt, event })
          }
        } catch (error) {
          fail(error)
          return
        }
        try {
          if (event.type === 'turn_started') {
            currentTurnID = event.id
            sendSteering(event.id, observedAt)
          }
          sendInteractionResponses(event, observedAt)
        } catch (error) {
          fail(error)
          return
        }
        if (event.type === 'capture_quiescent') {
          finish()
          return
        }
        let complete
        try {
          complete = completeWhen
            ? completeWhen(event, events)
            : event.type === 'done' || event.type === 'error'
        } catch (error) {
          fail(error)
          return
        }
        if (complete && !requireQuiescence) {
          finish()
          return
        }
      }
    })
    child.stdin.on('error', (error) => {
      if (!settled) fail(error)
    })
    child.on('error', fail)
    child.on('close', (code) => {
      if (settled) return
      fail(new Error(`fixture exited with ${code ?? 'unknown'} before the capture completion condition`))
    })
    child.stdin.write(`${JSON.stringify({ type: 'send', id: 'turn-1', prompt })}\n`)
  })
}
