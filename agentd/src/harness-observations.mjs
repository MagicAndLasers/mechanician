// Bounded, content-free observations from provider harnesses.
//
// These helpers deliberately accept the provider's rich objects and return only closed metadata,
// counters, timings and coarse outcomes. Prompt/response text, command lines, paths, tool input and
// output, error prose, account identifiers, balances and provider-authored display labels never
// cross this boundary.

export const HARNESS_METADATA_MAX_VALUES = 8
export const HARNESS_RETRY_HISTORY_MAX_ENTRIES = 16
export const HARNESS_RATE_LIMIT_MAX_BUCKETS = 16
export const HARNESS_ACCOUNT_DAILY_MAX_BUCKETS = 366
export const HARNESS_CLAUDE_USAGE_IDS_MAX_ENTRIES = 4_096

const TURN_ID_MAX_CHARACTERS = 160
const MODEL_ID_MAX_CHARACTERS = 256
const TOKEN_MAX_CHARACTERS = 96
const MAX_DURATION_MS = 30 * 24 * 60 * 60 * 1_000
const MAX_TOKEN_COUNT = 4_000_000_000
const MAX_COUNT = 1_000_000
const MAX_EPOCH_MILLISECONDS = 8_640_000_000_000_000

const LANES = new Set(['claude', 'codex'])
const PHASES = new Set([
  'provider_ready',
  'thread_ready',
  'request_accepted',
  'first_output',
  'terminal',
])
const THREAD_ACTIONS = new Set(['start', 'resume'])
const OUTPUT_KINDS = new Set(['text', 'thinking'])
const TERMINAL_OUTCOMES = new Set(['completed', 'failed', 'interrupted'])
const COMPACTION_TRIGGERS = new Set(['auto', 'manual', 'provider'])

// These values cross a persistence boundary and may be rendered. Provider enum strings are not a
// safe vocabulary: a future server could put an opaque id (or worse) in any nominally categorical
// field. Match known semantic families and collapse everything else to `other`.
const ERROR_KINDS = new Set([
  'authentication',
  'authorization',
  'rate_limit',
  'usage_limit',
  'timeout',
  'connection',
  'network',
  'unavailable',
  'overloaded',
  'server',
  'invalid_request',
  'context_limit',
  'compaction',
  'interrupted',
  'other',
])
const REROUTE_REASONS = new Set(['safety', 'capacity', 'performance', 'availability', 'other'])
const SAFETY_REASONS = new Set(['safety', 'capacity', 'performance', 'availability', 'other'])
const SAFETY_USE_CASES = new Set(['security', 'research', 'coding', 'other'])
const MODEL_VERIFICATIONS = new Set(['trusted_access', 'policy', 'capability', 'other'])

function finiteInteger(value, { minimum = 0, maximum = Number.MAX_SAFE_INTEGER } = {}) {
  const number = Number(value)
  if (!Number.isSafeInteger(number) || number < minimum) return null
  return Math.min(number, maximum)
}

function boundedDuration(value) {
  return finiteInteger(value, { maximum: MAX_DURATION_MS })
}

function boundedTokens(value) {
  return finiteInteger(value, { maximum: MAX_TOKEN_COUNT })
}

function boundedCount(value) {
  return finiteInteger(value, { maximum: MAX_COUNT })
}

function boundedEpochSeconds(value) {
  return finiteInteger(value, { maximum: 10_000_000_000 })
}

function boundedLabel(value, maximum = MODEL_ID_MAX_CHARACTERS) {
  if (typeof value !== 'string') return null
  const label = value.trim()
  if (!label || label.length > maximum || /[\u0000-\u001f\u007f]/.test(label)) return null
  return label
}

function boundedToken(value, maximum = TOKEN_MAX_CHARACTERS) {
  const token = boundedLabel(value, maximum)
  return token && /^[A-Za-z0-9][A-Za-z0-9._:/-]*$/.test(token) ? token : null
}

function boundedIdentifier(value) {
  return boundedToken(value, TURN_ID_MAX_CHARACTERS)
}

function normalizedCategorySource(value) {
  return typeof value === 'string'
    ? value.trim().replace(/([a-z0-9])([A-Z])/g, '$1 $2')
      .toLowerCase().replace(/[^a-z0-9]+/g, ' ')
    : ''
}

function coarseErrorKind(value, status = null) {
  if (ERROR_KINDS.has(value)) return value
  const source = normalizedCategorySource(value)
  if (/overload|capacity|too busy/.test(source)) return 'overloaded'
  if (/usage limit|quota|credit|billing|spend/.test(source)) return 'usage_limit'
  if (/rate limit|too many (?:request|attempt)|throttl/.test(source)) return 'rate_limit'
  if (/unauthenticated|unauthorized|authenticat|sign in|login|credential|api key/.test(source)) {
    return 'authentication'
  }
  if (/forbidden|authoriz|permission|access denied/.test(source)) return 'authorization'
  if (/context|token limit|maximum tokens|too many tokens/.test(source)) return 'context_limit'
  if (/compact|too few groups|blocking limit/.test(source)) return 'compaction'
  if (/timeout|timed out|deadline/.test(source)) return 'timeout'
  if (/disconnect|connection|socket|econn|stream (?:closed|failed)|transport/.test(source)) {
    return 'connection'
  }
  if (/network|dns|host unreachable/.test(source)) return 'network'
  if (/unavailable|not available/.test(source)) return 'unavailable'
  if (/interrupt|abort|cancel/.test(source)) return 'interrupted'
  if (/invalid|bad request|malformed/.test(source)) return 'invalid_request'
  if (/server|internal|service/.test(source)) return 'server'
  if (status === 401) return 'authentication'
  if (status === 403) return 'authorization'
  if (status === 408 || status === 504) return 'timeout'
  if (status === 429) return 'rate_limit'
  if (status === 503) return 'unavailable'
  if (status >= 500 && status <= 599) return 'server'
  if (status >= 400 && status <= 499) return 'invalid_request'
  return 'other'
}

function coarseRerouteReason(value) {
  if (REROUTE_REASONS.has(value)) return value
  const source = normalizedCategorySource(value)
  if (/safe|risk|cyber|policy|guard|abuse/.test(source)) return 'safety'
  if (/capacity|overload|quota|limit|busy/.test(source)) return 'capacity'
  if (/performance|latency|slow|speed|faster/.test(source)) return 'performance'
  if (/avail|fallback|outage|region/.test(source)) return 'availability'
  return 'other'
}

function coarseSafetyReason(value) {
  if (SAFETY_REASONS.has(value)) return value
  const source = normalizedCategorySource(value)
  if (/safe|risk|cyber|security|policy|guard|abuse|harm|trust/.test(source)) return 'safety'
  if (/capacity|overload|quota|limit|busy/.test(source)) return 'capacity'
  if (/performance|latency|slow|speed|faster/.test(source)) return 'performance'
  if (/avail|fallback|outage|region/.test(source)) return 'availability'
  return 'other'
}

function coarseSafetyUseCase(value) {
  if (SAFETY_USE_CASES.has(value)) return value
  const source = normalizedCategorySource(value)
  if (/cyber|security|vulnerab|malware|threat/.test(source)) return 'security'
  if (/research|analysis|investigat|study/.test(source)) return 'research'
  if (/code|coding|software|develop|program/.test(source)) return 'coding'
  return 'other'
}

function coarseModelVerification(value) {
  if (MODEL_VERIFICATIONS.has(value)) return value
  const source = normalizedCategorySource(value)
  if (/trusted|verified|access|account|identity|entitlement/.test(source)) return 'trusted_access'
  if (/policy|safe|guard|compliance/.test(source)) return 'policy'
  if (/capability|feature|model|support/.test(source)) return 'capability'
  return 'other'
}

function coarseCategoryArray(values, categorizer, maximum = HARNESS_METADATA_MAX_VALUES) {
  if (!Array.isArray(values)) return { values: [], count: null }
  const result = []
  const seen = new Set()
  for (const value of values) {
    if (typeof value !== 'string') continue
    const category = categorizer(value)
    if (!category || seen.has(category)) continue
    seen.add(category)
    if (result.length < maximum) result.push(category)
  }
  return { values: result, count: boundedCount(values.length) }
}

function assignInteger(target, key, value, normalize = boundedDuration) {
  const number = normalize(value)
  if (number !== null) target[key] = number
}

function turnObservation({ id, lane, event, provenance, scope, aggregation }) {
  const turnID = boundedIdentifier(id)
  if (!turnID || !LANES.has(lane) || !boundedToken(event)) return null
  return {
    type: 'harness_observation',
    id: turnID,
    lane,
    event,
    provenance,
    scope,
    aggregation,
  }
}

export function harnessPhaseObservation({
  id,
  lane,
  phase,
  startedAt,
  now = Date.now(),
  warm,
  threadAction,
  outputKind,
  terminalOutcome,
} = {}) {
  if (!PHASES.has(phase)) return null
  const event = turnObservation({
    id,
    lane,
    event: 'phase',
    provenance: 'mechanician_clock',
    scope: 'turn',
    aggregation: 'point',
  })
  if (!event) return null
  event.phase = phase
  const start = finiteInteger(startedAt)
  const end = finiteInteger(now, { maximum: MAX_EPOCH_MILLISECONDS })
  if (end !== null) event.at = new Date(end).toISOString()
  if (start !== null && end !== null && end >= start) {
    event.elapsedMs = Math.min(end - start, MAX_DURATION_MS)
  }
  if (typeof warm === 'boolean') event.warm = warm
  if (THREAD_ACTIONS.has(threadAction)) event.threadAction = threadAction
  if (OUTPUT_KINDS.has(outputKind)) event.outputKind = outputKind
  if (TERMINAL_OUTCOMES.has(terminalOutcome)) event.terminalOutcome = terminalOutcome
  return event
}

export function harnessCompactionObservation({
  id,
  lane,
  startedAt,
  completedAt = Date.now(),
  durationMs,
  trigger,
  agentID = null,
  compactionSequence,
  errorKind,
} = {}) {
  let duration = boundedDuration(durationMs)
  let provenance = 'provider_report'
  if (duration === null) {
    const start = finiteInteger(startedAt)
    const end = finiteInteger(completedAt)
    if (start === null || end === null || end < start) return null
    duration = Math.min(end - start, MAX_DURATION_MS)
    provenance = 'mechanician_clock'
  }
  const event = turnObservation({
    id,
    lane,
    event: 'compaction',
    provenance,
    scope: 'event',
    aggregation: 'final',
  })
  if (!event) return null
  event.compactionDurationMs = duration
  if (COMPACTION_TRIGGERS.has(trigger)) event.compactionTrigger = trigger
  const boundedAgentID = boundedIdentifier(agentID)
  if (boundedAgentID) event.agentID = boundedAgentID
  const sequence = finiteInteger(compactionSequence, { minimum: 1, maximum: MAX_COUNT })
  if (sequence !== null) event.compactionSequence = sequence
  if (typeof errorKind === 'string') event.compactionErrorKind = coarseErrorKind(errorKind)
  return event
}

// The Claude Agent SDK can deliver the same assistant frame through more than one callback. Its
// stable message id makes usage idempotent; older/partial shapes with no id retain the historical
// emit-each-sample behavior. The rolling set is bounded so a pathological turn cannot grow memory.
export function claimClaudeAssistantUsageSample(seenMessageIDs, message) {
  if (!(seenMessageIDs instanceof Set)) return true
  const messageID = typeof message?.message?.id === 'string' ? message.message.id.trim() : ''
  if (!messageID || messageID.length > TURN_ID_MAX_CHARACTERS) return true
  if (seenMessageIDs.has(messageID)) return false
  if (seenMessageIDs.size >= HARNESS_CLAUDE_USAGE_IDS_MAX_ENTRIES) {
    const oldest = seenMessageIDs.values().next().value
    if (oldest !== undefined) seenMessageIDs.delete(oldest)
  }
  seenMessageIDs.add(messageID)
  return true
}

function codexErrorMetadata(error) {
  if (!error || typeof error !== 'object') return { errorKind: 'other' }
  const info = error.codexErrorInfo
  let rawErrorKind = typeof info === 'string' ? info : null
  let detail = null
  if (!rawErrorKind && info && typeof info === 'object' && !Array.isArray(info)) {
    if (typeof info.type === 'string') rawErrorKind = info.type
    const entry = Object.entries(info).find(([key]) => key !== 'type' && boundedToken(key))
    if (entry) {
      rawErrorKind ||= entry[0]
      detail = entry[1]
    }
  }
  rawErrorKind ||= typeof error.code === 'string' ? error.code : null
  rawErrorKind ||= typeof error.type === 'string' ? error.type : null
  const status = finiteInteger(
    detail?.httpStatusCode ?? error.httpStatusCode ?? error.status ?? error.statusCode,
    { minimum: 100, maximum: 999 },
  )
  return {
    errorKind: coarseErrorKind(rawErrorKind, status),
    ...(status !== null ? { httpStatusCode: status } : {}),
  }
}

export function codexRetryObservation({
  id,
  error,
  retryAttempt,
  willContinue,
  hadPriorRetry = false,
} = {}) {
  const attempt = finiteInteger(retryAttempt, { minimum: 1, maximum: MAX_COUNT })
  if (attempt === null || typeof willContinue !== 'boolean') return null
  const eventKind = willContinue
    ? 'retry'
    : hadPriorRetry
      ? 'retry_exhausted'
      : 'internal_error'
  const event = turnObservation({
    id,
    lane: 'codex',
    event: eventKind,
    provenance: 'provider_report',
    scope: 'request',
    aggregation: 'delta',
  })
  if (!event) return null
  if (eventKind === 'internal_error') {
    return { ...event, ...codexErrorMetadata(error) }
  }
  return {
    ...event,
    retryDisposition: willContinue ? 'scheduled' : 'exhausted',
    retryAttempt: attempt,
    willContinue,
    ...codexErrorMetadata(error),
  }
}

export function codexRetryRecoveredObservation({
  id,
  retryAttempts,
  retryHistory,
  retryHistoryCount,
} = {}) {
  const event = turnObservation({
    id,
    lane: 'codex',
    event: 'retry_recovered',
    provenance: 'provider_report',
    scope: 'turn',
    aggregation: 'final',
  })
  if (!event) return null
  const attempts = finiteInteger(retryAttempts, { minimum: 1, maximum: MAX_COUNT })
  if (attempts === null) return null
  const history = []
  for (const candidate of Array.isArray(retryHistory) ? retryHistory : []) {
    if (history.length >= HARNESS_RETRY_HISTORY_MAX_ENTRIES) break
    const attempt = finiteInteger(candidate?.retryAttempt, { minimum: 1, maximum: MAX_COUNT })
    if (attempt === null) continue
    const status = finiteInteger(candidate?.httpStatusCode, { minimum: 100, maximum: 999 })
    const errorKind = coarseErrorKind(candidate?.errorKind, status)
    const item = {
      retryAttempt: attempt,
      willContinue: candidate?.willContinue === true,
      errorKind,
    }
    if (status !== null) item.httpStatusCode = status
    history.push(item)
  }
  return {
    ...event,
    retryDisposition: 'recovered',
    retryAttempts: attempts,
    retryHistoryCount: boundedCount(retryHistoryCount) ?? history.length,
    ...(history.length ? { retryHistory: history } : {}),
  }
}

function codexToolKind(type) {
  switch (type) {
    case 'commandExecution': return 'command'
    case 'mcpToolCall': return 'mcp'
    case 'dynamicToolCall': return 'dynamic'
    case 'fileChange': return 'file_change'
    case 'webSearch': return 'web'
    default: return null
  }
}

function codexToolOutcome(item) {
  if (item?.status === 'declined') return 'declined'
  if (item?.status === 'failed' || item?.success === false) return 'error'
  if (item?.type === 'commandExecution'
      && Number.isInteger(item.exitCode) && item.exitCode !== 0) return 'error'
  if (item?.status === 'completed' || item?.success === true) return 'success'
  if (item?.type === 'webSearch') return 'success'
  return null
}

export function codexToolObservation({ id, item, agentID = null, durationMs } = {}) {
  const toolKind = codexToolKind(item?.type)
  const toolUseID = boundedIdentifier(item?.id)
  if (!toolKind || !toolUseID) return null
  const event = turnObservation({
    id,
    lane: 'codex',
    event: 'tool',
    provenance: 'provider_report',
    scope: 'event',
    aggregation: 'final',
  })
  if (!event) return null
  event.toolUseID = toolUseID
  event.toolKind = toolKind
  const outcome = codexToolOutcome(item)
  if (outcome) event.toolOutcome = outcome
  assignInteger(event, 'toolDurationMs', item.durationMs ?? durationMs)
  const boundedAgentID = boundedIdentifier(agentID)
  if (boundedAgentID) event.agentID = boundedAgentID
  return event
}

export function codexModelObservation({ id, method, params, agentID = null } = {}) {
  let eventKind = null
  if (method === 'model/rerouted') eventKind = 'model_rerouted'
  else if (method === 'model/safetyBuffering/updated') eventKind = 'model_safety'
  else if (method === 'model/verification') eventKind = 'model_verification'
  if (!eventKind) return null
  const event = turnObservation({
    id,
    lane: 'codex',
    event: eventKind,
    provenance: 'provider_report',
    scope: 'turn',
    aggregation: 'point',
  })
  if (!event) return null
  const boundedAgentID = boundedIdentifier(agentID)
  if (boundedAgentID) event.agentID = boundedAgentID

  if (eventKind === 'model_rerouted') {
    const originalModelID = boundedToken(params?.fromModel, MODEL_ID_MAX_CHARACTERS)
    const model = boundedToken(params?.toModel, MODEL_ID_MAX_CHARACTERS)
    const rerouteReason = typeof params?.reason === 'string'
      ? coarseRerouteReason(params.reason) : null
    if (originalModelID) event.originalModelID = originalModelID
    if (model) event.model = model
    if (rerouteReason) event.rerouteReason = rerouteReason
    return event
  }

  if (eventKind === 'model_safety') {
    const model = boundedToken(params?.model, MODEL_ID_MAX_CHARACTERS)
    const fasterModel = boundedToken(params?.fasterModel, MODEL_ID_MAX_CHARACTERS)
    const reasons = coarseCategoryArray(params?.reasons, coarseSafetyReason)
    const useCases = coarseCategoryArray(params?.useCases, coarseSafetyUseCase)
    if (model) event.model = model
    if (fasterModel) event.fasterModel = fasterModel
    if (typeof params?.showBufferingUi === 'boolean') {
      event.showBuffering = params.showBufferingUi
      event.safetyOutcome = params.showBufferingUi ? 'buffered' : 'allowed'
    }
    if (reasons.values.length) event.safetyReasons = reasons.values
    if (reasons.count !== null) event.safetyReasonCount = reasons.count
    if (useCases.values.length) event.safetyUseCases = useCases.values
    if (useCases.count !== null) event.safetyUseCaseCount = useCases.count
    return event
  }

  const verifications = coarseCategoryArray(params?.verifications, coarseModelVerification)
  if (verifications.values.length) event.modelVerifications = verifications.values
  if (verifications.count !== null) event.verificationCount = verifications.count
  return event
}

function summedClaudeModelUsage(modelUsage) {
  if (!modelUsage || typeof modelUsage !== 'object' || Array.isArray(modelUsage)) return null
  const rows = Object.values(modelUsage)
  if (!rows.length) return null
  const total = {
    input_tokens: 0,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: 0,
    output_tokens: 0,
  }
  let observedPositive = false
  for (const row of rows) {
    if (!row || typeof row !== 'object' || Array.isArray(row)) continue
    for (const [source, target] of [
      ['inputTokens', 'input_tokens'],
      ['cacheCreationInputTokens', 'cache_creation_input_tokens'],
      ['cacheReadInputTokens', 'cache_read_input_tokens'],
      ['outputTokens', 'output_tokens'],
    ]) {
      const tokens = boundedTokens(row[source])
      if (tokens === null) continue
      if (tokens > 0) observedPositive = true
      total[target] = Math.min(total[target] + tokens, MAX_TOKEN_COUNT)
    }
  }
  return observedPositive ? total : null
}

export function claudeResultObservation({ id, message, providerQuerySequence } = {}) {
  if (!message || message.type !== 'result') return null
  const agentTreeUsage = summedClaudeModelUsage(message.modelUsage)
  const event = turnObservation({
    id,
    lane: 'claude',
    event: 'result',
    provenance: 'provider_report',
    scope: agentTreeUsage ? 'agent_tree' : 'request',
    aggregation: 'final',
  })
  if (!event) return null
  const querySequence = finiteInteger(providerQuerySequence, { minimum: 1, maximum: MAX_COUNT })
  if (querySequence !== null) event.providerQuerySequence = querySequence
  assignInteger(event, 'durationMs', message.duration_ms)
  assignInteger(event, 'apiDurationMs', message.duration_api_ms)
  assignInteger(event, 'timeToFirstTokenMs', message.ttft_ms)
  assignInteger(event, 'streamTimeToFirstOutputMs', message.ttft_stream_ms)
  assignInteger(event, 'timeToRequestMs', message.time_to_request_ms)
  assignInteger(event, 'timeToRequestFromSpawnMs', message.time_to_request_from_spawn_ms)
  if (typeof message.warm_spare_claimed === 'boolean') event.warm = message.warm_spare_claimed

  const usage = agentTreeUsage || message.usage
  if (usage && typeof usage === 'object') {
    const uncached = boundedTokens(usage.input_tokens)
    const cacheWrite = boundedTokens(usage.cache_creation_input_tokens)
    const cacheRead = boundedTokens(usage.cache_read_input_tokens)
    const output = boundedTokens(usage.output_tokens)
    if ([uncached, cacheWrite, cacheRead, output].some((value) => value !== null && value > 0)) {
      if (uncached !== null) event.uncachedInputTokens = uncached
      if (cacheWrite !== null) event.cacheWriteInputTokens = cacheWrite
      if (cacheRead !== null) event.cacheReadInputTokens = cacheRead
      if (output !== null) event.outputTokens = output
      if ([uncached, cacheWrite, cacheRead].every((value) => value !== null)) {
        event.inputTokens = Math.min(uncached + cacheWrite + cacheRead, MAX_TOKEN_COUNT)
      }
    }
  }
  return event
}

const CONTEXT_COMPOSITION_KEYS = Object.freeze([
  'system_prompt',
  'system_tools',
  'mcp_tools',
  'deferred_tools',
  'memory',
  'agents',
  'skills',
  'commands',
  'messages',
  'compaction_buffer',
  'free',
  'other',
])

function claudeContextCategory(category) {
  const name = typeof category?.name === 'string' ? category.name.toLowerCase() : ''
  if (category?.isDeferred === true || /deferred/.test(name)) return 'deferred_tools'
  if (/system\s*prompt|prompt\s*section/.test(name)) return 'system_prompt'
  if (/system\s*tools?|built.?in\s*tools?/.test(name)) return 'system_tools'
  if (/mcp\s*tools?|connectors?/.test(name)) return 'mcp_tools'
  if (/memor(?:y|ies)|memory\s*files?/.test(name)) return 'memory'
  if (/agents?/.test(name)) return 'agents'
  if (/skills?/.test(name)) return 'skills'
  if (/slash|commands?/.test(name)) return 'commands'
  if (/messages?|conversation|history|attachments?/.test(name)) return 'messages'
  if (/compact|buffer|reserve/.test(name)) return 'compaction_buffer'
  if (/free|remaining|available/.test(name)) return 'free'
  return 'other'
}

function addCompositionToken(composition, key, value) {
  if (!CONTEXT_COMPOSITION_KEYS.includes(key)) return false
  const tokens = boundedTokens(value)
  if (tokens === null) return false
  composition[key] = Math.min((composition[key] || 0) + tokens, MAX_TOKEN_COUNT)
  return true
}

function explicitClaudeContextComposition(raw) {
  const composition = {}
  const sumRows = (rows, key, predicate = () => true) => {
    for (const row of Array.isArray(rows) ? rows : []) {
      if (predicate(row)) addCompositionToken(composition, key, row?.tokens)
    }
  }
  sumRows(raw.systemPromptSections, 'system_prompt')
  sumRows(raw.systemTools, 'system_tools')
  sumRows(raw.mcpTools, 'mcp_tools', (row) => row?.isLoaded !== false)
  sumRows(raw.mcpTools, 'deferred_tools', (row) => row?.isLoaded === false)
  sumRows(raw.deferredBuiltinTools, 'deferred_tools', (row) => row?.isLoaded === false)
  sumRows(raw.memoryFiles, 'memory')
  sumRows(raw.agents, 'agents')
  addCompositionToken(composition, 'skills', raw.skills?.tokens)
  addCompositionToken(composition, 'commands', raw.slashCommands?.tokens)
  const breakdown = raw.messageBreakdown
  if (breakdown && typeof breakdown === 'object') {
    for (const key of [
      'toolCallTokens',
      'toolResultTokens',
      'attachmentTokens',
      'assistantMessageTokens',
      'userMessageTokens',
      'redirectedContextTokens',
      'unattributedTokens',
    ]) addCompositionToken(composition, 'messages', breakdown[key])
  }
  return composition
}

export function claudeContextObservation({ id, raw } = {}) {
  const contextTokens = boundedTokens(raw?.totalTokens)
  const usableWindow = boundedTokens(raw?.maxTokens)
  const rawWindow = boundedTokens(raw?.rawMaxTokens)
  if (contextTokens === null || usableWindow === null || usableWindow === 0) return null
  const event = turnObservation({
    id,
    lane: 'claude',
    event: 'context',
    provenance: 'provider_report',
    scope: 'thread',
    aggregation: 'snapshot',
  })
  if (!event) return null
  event.contextTokens = contextTokens
  event.contextUsableWindow = usableWindow
  event.contextRawWindowTokens = rawWindow || usableWindow

  const composition = {}
  for (const category of Array.isArray(raw.categories) ? raw.categories : []) {
    addCompositionToken(composition, claudeContextCategory(category), category?.tokens)
  }
  if (!Object.keys(composition).length) Object.assign(composition, explicitClaudeContextComposition(raw))
  if (!Object.hasOwn(composition, 'compaction_buffer') && rawWindow !== null && rawWindow > usableWindow) {
    addCompositionToken(composition, 'compaction_buffer', rawWindow - usableWindow)
  }
  if (!Object.hasOwn(composition, 'free') && usableWindow > contextTokens) {
    addCompositionToken(composition, 'free', usableWindow - contextTokens)
  }
  if (Object.keys(composition).length) event.contextComposition = composition
  return event
}

function normalizedRateLimitWindow(value) {
  if (!value || typeof value !== 'object') return null
  const usedPercent = finiteInteger(value.usedPercent, { maximum: 100 })
  if (usedPercent === null) return null
  const window = { usedPercent }
  assignInteger(window, 'windowDurationMins', value.windowDurationMins, boundedCount)
  assignInteger(window, 'resetsAt', value.resetsAt, boundedEpochSeconds)
  return window
}

function normalizedRateLimitBucket(value) {
  if (!value || typeof value !== 'object') return null
  const bucket = {}
  if (typeof value.rateLimitReachedType === 'string') {
    bucket.rateLimitReached = value.rateLimitReachedType.trim().length > 0
  }
  if (typeof value.spendControlReached === 'boolean') {
    bucket.spendControlReached = value.spendControlReached
  }
  const primary = normalizedRateLimitWindow(value.primary)
  const secondary = normalizedRateLimitWindow(value.secondary)
  if (primary) bucket.primary = primary
  if (secondary) bucket.secondary = secondary
  if (value.credits && typeof value.credits === 'object') {
    const credits = {}
    if (typeof value.credits.hasCredits === 'boolean') credits.hasCredits = value.credits.hasCredits
    if (typeof value.credits.unlimited === 'boolean') credits.unlimited = value.credits.unlimited
    if (Object.keys(credits).length) bucket.credits = credits
  }
  if (value.individualLimit && typeof value.individualLimit === 'object') {
    const individualLimit = {}
    assignInteger(
      individualLimit,
      'remainingPercent',
      value.individualLimit.remainingPercent,
      (candidate) => finiteInteger(candidate, { maximum: 100 }),
    )
    assignInteger(individualLimit, 'resetsAt', value.individualLimit.resetsAt, boundedEpochSeconds)
    if (Object.keys(individualLimit).length) bucket.individualLimit = individualLimit
  }
  return Object.keys(bucket).length ? bucket : null
}

function mergeAvailable(previous, incoming) {
  const result = { ...(previous || {}) }
  for (const [key, value] of Object.entries(incoming || {})) {
    if (value === null || value === undefined) continue
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      result[key] = mergeAvailable(result[key], value)
    } else {
      result[key] = value
    }
  }
  return result
}

function normalizedBucketEntries(payload) {
  const entries = []
  const byID = payload?.rateLimitsByLimitId
  if (byID && typeof byID === 'object' && !Array.isArray(byID)) {
    for (const [rawKey, rawBucket] of Object.entries(byID)) {
      if (entries.length >= HARNESS_RATE_LIMIT_MAX_BUCKETS) break
      const key = boundedIdentifier(rawBucket?.limitId) || boundedIdentifier(rawKey)
      const bucket = normalizedRateLimitBucket(rawBucket)
      if (key && bucket) entries.push({ key, bucket })
    }
  }
  const fallback = payload?.rateLimits
  const fallbackKey = boundedIdentifier(fallback?.limitId) || '__default__'
  const fallbackBucket = normalizedRateLimitBucket(fallback)
  if (fallbackBucket
      && !(entries.length && fallbackKey === '__default__')
      && !entries.some((entry) => entry.key === fallbackKey)
      && entries.length < HARNESS_RATE_LIMIT_MAX_BUCKETS) {
    entries.push({ key: fallbackKey, bucket: fallbackBucket })
  }
  return entries
}

/**
 * Merge a full account/rateLimits/read response or sparse account/rateLimits/updated payload into
 * bounded state. `key` is retained only locally to match sparse buckets and is stripped by the
 * wire observation below.
 */
export function updateCodexRateLimitState(previous, payload, { replace = false } = {}) {
  const entries = normalizedBucketEntries(payload)
  const priorEntries = replace ? [] : Array.isArray(previous?.entries) ? previous.entries : []
  const byKey = new Map(priorEntries.slice(0, HARNESS_RATE_LIMIT_MAX_BUCKETS).map(
    (entry) => [entry.key, { key: entry.key, bucket: mergeAvailable({}, entry.bucket) }],
  ))
  for (const entry of entries) {
    const singlePrior = entry.key === '__default__' && byKey.size === 1
      ? byKey.values().next().value
      : null
    const existing = byKey.get(entry.key) || singlePrior
    if (existing) existing.bucket = mergeAvailable(existing.bucket, entry.bucket)
    else if (byKey.size < HARNESS_RATE_LIMIT_MAX_BUCKETS) byKey.set(entry.key, entry)
  }
  let resetCreditsAvailable = replace ? null : boundedCount(previous?.resetCreditsAvailable)
  const suppliedResetCount = boundedCount(payload?.rateLimitResetCredits?.availableCount)
  if (suppliedResetCount !== null) resetCreditsAvailable = suppliedResetCount
  const rawMapCount = payload?.rateLimitsByLimitId
    && typeof payload.rateLimitsByLimitId === 'object'
    && !Array.isArray(payload.rateLimitsByLimitId)
    ? Object.keys(payload.rateLimitsByLimitId).length
    : 0
  const suppliedBucketCount = rawMapCount || (payload?.rateLimits ? 1 : 0)
  const bucketCount = replace
    ? suppliedBucketCount
    : Math.max(boundedCount(previous?.bucketCount) || 0, suppliedBucketCount, byKey.size)
  return {
    complete: replace || previous?.complete === true,
    bucketCount: boundedCount(bucketCount) ?? byKey.size,
    entries: [...byKey.values()],
    ...(resetCreditsAvailable !== null ? { resetCreditsAvailable } : {}),
  }
}

export function codexRateLimitsObservation(state, { source = 'read' } = {}) {
  if (!state || !Array.isArray(state.entries)) return null
  const buckets = state.entries
    .slice(0, HARNESS_RATE_LIMIT_MAX_BUCKETS)
    .map((entry) => mergeAvailable({}, entry?.bucket))
    .filter((bucket) => Object.keys(bucket).length)
  // A successful full read with no buckets is still meaningful: it clears the prior account
  // snapshot. Partial notifications without any usable fields remain noise.
  if (!buckets.length && state.resetCreditsAvailable == null && state.complete !== true) return null
  return {
    type: 'harness_account_usage',
    provider: 'codex',
    kind: 'rate_limits',
    provenance: 'provider_report',
    source: source === 'notification' ? 'notification' : 'read',
    aggregation: 'snapshot',
    complete: state.complete === true,
    bucketCount: boundedCount(state.bucketCount) ?? buckets.length,
    buckets,
    ...(state.resetCreditsAvailable != null
      ? { resetCreditsAvailable: boundedCount(state.resetCreditsAvailable) }
      : {}),
  }
}

export function codexAccountTokenUsageObservation(payload) {
  if (!payload || typeof payload !== 'object') return null
  const summary = {}
  for (const [source, target] of [
    ['lifetimeTokens', 'lifetimeTokens'],
    ['peakDailyTokens', 'peakDailyTokens'],
    ['longestRunningTurnSec', 'longestRunningTurnSec'],
    ['currentStreakDays', 'currentStreakDays'],
    ['longestStreakDays', 'longestStreakDays'],
  ]) assignInteger(summary, target, payload.summary?.[source], boundedTokens)

  const rawBuckets = Array.isArray(payload.dailyUsageBuckets) ? payload.dailyUsageBuckets : []
  const dailyUsage = []
  for (const bucket of rawBuckets) {
    if (dailyUsage.length >= HARNESS_ACCOUNT_DAILY_MAX_BUCKETS) break
    const startDate = boundedLabel(bucket?.startDate, 10)
    const tokens = boundedTokens(bucket?.tokens)
    if (!startDate || !/^\d{4}-\d{2}-\d{2}$/.test(startDate) || tokens === null) continue
    dailyUsage.push({ startDate, tokens })
  }
  return {
    type: 'harness_account_usage',
    provider: 'codex',
    kind: 'token_usage',
    provenance: 'provider_report',
    source: 'read',
    aggregation: 'snapshot',
    complete: true,
    summary,
    dailyBucketCount: boundedCount(rawBuckets.length) ?? dailyUsage.length,
    dailyUsage,
  }
}
