const ERROR_KINDS = new Set([
  'authentication',
  'quota',
  'rate_limit',
  'model_access',
  'context_limit',
  'output_limit',
  'server',
  'network',
  'invalid_request',
  'unknown',
])

export const PROVIDER_ERROR_MAX_BYTES = 6144

const MAX_MESSAGE_BYTES = 2048
const MAX_IDENTIFIER_BYTES = 256
const MAX_ACCESS_BYTES = 64

function truncateUtf8(value, maxBytes) {
  const buffer = Buffer.from(value, 'utf8')
  if (buffer.byteLength <= maxBytes) return value
  return buffer.subarray(0, maxBytes).toString('utf8').replace(/\uFFFD$/u, '')
}

function scrubSecrets(value) {
  return value
    .replace(
      /(["']?(?:api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|session[-_ ]?token|id[-_ ]?token|client[-_ ]?secret|private[-_ ]?key|password|credential|token|secret)["']?\s*[:=]\s*)(?!\[redacted(?:-[a-z-]+)?\])(?:"[^"]*"|'[^']*'|[^\s,;}\]]+)/gi,
      '$1[redacted]',
    )
    .replace(/\b(?:bearer|basic)\s+[a-z0-9._~+/=-]{6,}/gi, '[redacted-authorization]')
    .replace(/\bsk-(?:proj-|ant-)?[a-z0-9_-]{8,}/gi, '[redacted-api-key]')
    .replace(/\beyJ[a-z0-9_-]{6,}\.[a-z0-9_-]{6,}\.[a-z0-9_-]{6,}\b/gi, '[redacted-token]')
}

function cleanString(value, maxBytes = MAX_IDENTIFIER_BYTES) {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  if (!trimmed) return null
  return truncateUtf8(scrubSecrets(trimmed), maxBytes)
}

function cleanMessage(value, fallback) {
  return cleanString(value, MAX_MESSAGE_BYTES) || fallback
}

function cleanCode(value) {
  if (typeof value === 'number' && Number.isInteger(value) && Number.isSafeInteger(value)) return value
  return cleanString(value)
}

function integerStatus(value) {
  if (typeof value !== 'number' && typeof value !== 'string') return null
  const status = Number(value)
  return Number.isInteger(status) && status >= 100 && status <= 599 ? status : null
}

function nonNegativeInteger(value) {
  if (typeof value !== 'number' && typeof value !== 'string') return null
  const number = Number(value)
  return Number.isSafeInteger(number) && number >= 0 ? number : null
}

function nonNegativeDouble(value) {
  if (typeof value !== 'number' && typeof value !== 'string') return null
  const number = Number(value)
  return Number.isFinite(number) && number >= 0 ? number : null
}

function durationSeconds(value) {
  const direct = nonNegativeDouble(value)
  if (direct != null) return direct
  if (typeof value !== 'string') return null
  const text = value.trim().toLowerCase()
  if (!text) return null
  let total = 0
  let end = 0
  let matched = false
  const expression = /(\d+(?:\.\d+)?)(ms|s|m|h)/g
  for (const part of text.matchAll(expression)) {
    if (part.index !== end) return null
    matched = true
    end = part.index + part[0].length
    const number = Number(part[1])
    total += part[2] === 'ms' ? number / 1000
      : part[2] === 'm' ? number * 60
        : part[2] === 'h' ? number * 3600 : number
  }
  return matched && end === text.length && Number.isFinite(total) ? total : null
}

function absoluteTime(value) {
  if (typeof value !== 'number' && typeof value !== 'string') return null
  if (typeof value === 'string' && !value.trim()) return null
  const numeric = Number(value)
  let date
  if (Number.isFinite(numeric) && numeric > 0) {
    date = new Date(numeric < 10_000_000_000 ? numeric * 1000 : numeric)
  } else if (typeof value === 'string') {
    date = new Date(value)
  }
  return date && !Number.isNaN(date.getTime()) ? date.toISOString() : null
}

function header(headers, name) {
  if (!headers) return null
  try {
    if (typeof headers.get === 'function') return cleanString(headers.get(name))
    const target = name.toLowerCase()
    for (const [key, value] of Object.entries(headers)) {
      if (key.toLowerCase() === target) return cleanString(typeof value === 'string' ? value : String(value))
    }
  } catch {}
  return null
}

function firstHeader(headers, names) {
  for (const name of names) {
    const value = header(headers, name)
    if (value != null) return value
  }
  return null
}

function parseBody(value) {
  if (typeof value !== 'string') return value
  const text = value.trim()
  if (!text) return null
  try { return JSON.parse(text) } catch { return text }
}

function rateLimitDimension(headers, aliases) {
  const suffix = (prefix) => aliases.map((alias) => `x-ratelimit-${prefix}-${alias}`)
  const limit = nonNegativeInteger(firstHeader(headers, suffix('limit')))
  const remaining = nonNegativeInteger(firstHeader(headers, suffix('remaining')))
  const resetAfterSeconds = durationSeconds(firstHeader(headers, suffix('reset')))
  if (limit == null && remaining == null && resetAfterSeconds == null) return null
  const result = {}
  if (limit != null) result.limit = limit
  if (remaining != null) result.remaining = remaining
  if (resetAfterSeconds != null) result.resetAfterSeconds = resetAfterSeconds
  return result
}

function openAIRateLimits(headers) {
  const requests = rateLimitDimension(headers, ['requests'])
  const tokens = rateLimitDimension(headers, ['tokens'])
  const project = rateLimitDimension(headers, ['project-tokens', 'project', 'projects', 'project-requests'])
  if (!requests && !tokens && !project) return null
  const result = {}
  if (requests) result.requests = requests
  if (tokens) result.tokens = tokens
  if (project) result.project = project
  return result
}

function codexKind(tag) {
  const normalized = String(tag || '').replace(/[^a-z0-9]/gi, '').toLowerCase()
  if (!normalized) return null
  if (normalized === 'contextwindowexceeded') return 'context_limit'
  if (normalized === 'sessionbudgetexceeded' || normalized === 'usagelimitexceeded') return 'quota'
  if (normalized === 'serveroverloaded' || normalized === 'internalservererror' || normalized === 'threadrollbackfailed') return 'server'
  if (normalized === 'unauthorized') return 'authentication'
  if (normalized === 'badrequest' || normalized === 'cyberpolicy' || normalized === 'activeturnnotsteerable') return 'invalid_request'
  if (normalized === 'httpconnectionfailed' || normalized === 'responsestreamconnectionfailed' ||
      normalized === 'responsestreamdisconnected' || normalized === 'responsetoomanyfailedattempts' ||
      /network|stream(?:error|failed|disconnected)|connection(?:failed|closed)/.test(normalized)) return 'network'
  return null
}

function classificationText({ code, providerType, message, terminalReason }) {
  return [code, providerType, message, terminalReason]
    .filter((value) => value != null)
    .join(' ')
    .toLowerCase()
}

// A provider that exhausts its own credential recovery reports it in prose, not in a code. The Claude
// Agent SDK's "Failed to authenticate: OAuth session expired and could not be refreshed" arrives
// tagged only as `api_error`, so the structured codes above miss it and the turn degrades to
// `unknown` — no Reconnect action, and the account row keeps claiming it is connected.
//
// The refresh clause deliberately requires a nearby credential noun: a conversation resume can also
// report an expired *session*, and that must stay out of the authentication bucket.
const CREDENTIAL_RECOVERY_FAILED =
  /failed to authenticate|oauth[_ -]?session[_ -]?expired|re-?authenticat(?:e|ion)[_ -]?(?:is[_ -]?)?required|(?:please[_ -]?)?(?:log|sign)[_ -]?in[_ -]?again|(?:oauth|token|credentials?|session|sign[_ -]?in)[^.]{0,40}(?:could not be refreshed|failed to refresh|refresh[_ -]?failed)/

function classify({ provider, status, code, providerType, message, terminalReason, codexErrorTag }) {
  // A response from an upstream 5xx endpoint is a provider/server failure even
  // when its prose contains words such as "timeout".
  if (status != null && status >= 500) return 'server'
  if (provider === 'codex' && Number(code) === -32603) return 'server'
  if (provider === 'codex' && providerType === 'app_server_timeout') return 'network'
  if (provider === 'codex' &&
      (providerType === 'app_server_exit' || providerType === 'app_server_unavailable')) return 'server'
  const taggedCodexKind = provider === 'codex' ? codexKind(codexErrorTag) : null
  if (taggedCodexKind && taggedCodexKind !== 'network') return taggedCodexKind

  const text = classificationText({ code, providerType, message, terminalReason })
  if (/insufficient[_ -]?quota|billing[_ -]?error|credits?[_ -]?required|out[_ -]?of[_ -]?credits|quota (?:is )?exceeded|billing hard limit|exceeded your current quota|error_max_budget/.test(text)) {
    return 'quota'
  }
  if (/authentication[_ -]?failed|authentication[_ -]?error|invalid[_ -]?api[_ -]?key|incorrect api key|unauthori[sz]ed|login[_ -]?required|not logged in|oauth[_ -]?org[_ -]?not[_ -]?allowed|invalid[_ -]?token|expired[_ -]?token|token[_ -]?revoked|refresh[_ -]?token[_ -]?invalidated/.test(text)
      || CREDENTIAL_RECOVERY_FAILED.test(text)) {
    return 'authentication'
  }
  if (/model[_ -]?not[_ -]?found|model[_ -]?access|unsupported[_ -]?model|unknown model|does not have access to model|model is not available/.test(text)) {
    return 'model_access'
  }
  if (/max(?:imum)?[_ -]?output[_ -]?tokens?|output[_ -]?(?:token[_ -]?)?limit/.test(text)) {
    return 'output_limit'
  }
  if (/context[_ -]?(?:length|window).*exceed|prompt[_ -]?too[_ -]?long|maximum context|too many tokens/.test(text)) {
    return 'context_limit'
  }
  if (/rate[_ -]?limit|too many requests|rapid[_ -]?refill[_ -]?breaker/.test(text) || status === 429) {
    return 'rate_limit'
  }
  if (status === 401) return 'authentication'
  // A bare 403 is authorization/policy, not proof that signing in again helps.
  if (status === 403) return 'unknown'
  if (status === 400 || status === 404 || status === 409 || status === 422) return 'invalid_request'
  if (taggedCodexKind === 'network') return 'network'
  if (/network|fetch failed|connection (?:reset|refused|closed)|econn(?:reset|refused)|enotfound|socket hang up|timed? ?out|timeout|dns/.test(text)) {
    return 'network'
  }
  if (/overloaded|server[_ -]?error|internal[_ -]?error|temporarily unavailable|service unavailable|bad gateway|gateway timeout/.test(text)) {
    return 'server'
  }
  if (/invalid[_ -]?(?:request|argument|params)|malformed|method not found|parse error|error_max_turns|structured_output_retries/.test(text)) {
    return 'invalid_request'
  }
  if (provider === 'codex' && [-32700, -32600, -32601, -32602].includes(Number(code))) {
    return 'invalid_request'
  }
  return 'unknown'
}

function fitWireSize(result) {
  if (Buffer.byteLength(JSON.stringify(result), 'utf8') <= PROVIDER_ERROR_MAX_BYTES) return result
  result.message = truncateUtf8(result.message, 512)
  if (Buffer.byteLength(JSON.stringify(result), 'utf8') <= PROVIDER_ERROR_MAX_BYTES) return result
  if (result.providerError) {
    delete result.providerError.rateLimits
    delete result.providerError.clientRequestId
    delete result.providerError.requestId
  }
  return result
}

function normalizedError(provider, context, errorKind, message, providerError = null) {
  const result = {
    errorKind: ERROR_KINDS.has(errorKind) ? errorKind : 'unknown',
    provider,
    message: cleanMessage(message, 'Provider request failed.'),
  }
  const access = cleanString(context?.access, MAX_ACCESS_BYTES)
  if (access) result.access = access
  if (providerError && Object.keys(providerError).length) result.providerError = providerError
  return fitWireSize(result)
}

function codexReconnectRequired({ code, providerType, message, codexErrorTag }) {
  const text = [code, providerType, message, codexErrorTag]
    .filter((value) => value != null)
    .join(' ')
    .replace(/[^a-z0-9]/gi, '')
    .toLowerCase()
  return /tokenrevoked|refreshtokeninvalidated|refreshtoken.*revoked|recoveryfailedpermanent/.test(text)
}

function addString(target, key, value) {
  const clean = cleanString(value)
  if (clean) target[key] = clean
}

function addCode(target, value) {
  const clean = cleanCode(value)
  if (clean != null) target.code = clean
}

function addStatus(target, value) {
  const clean = integerStatus(value)
  if (clean != null) target.status = clean
}

function addSeconds(target, key, value) {
  const clean = durationSeconds(value)
  if (clean != null) target[key] = clean
}

function addTime(target, key, value) {
  const clean = absoluteTime(value)
  if (clean) target[key] = clean
}

function openAIEnvelope(input) {
  const event = input?.event || input
  if (event?.type === 'error') return event.error || event
  if (event?.type === 'response.failed') return event.response?.error || event.error || event.response || event
  if (event?.type === 'response.incomplete') {
    return event.response?.error || event.response?.incomplete_details || event.incomplete_details || event
  }
  const body = parseBody(input?.body ?? input)
  if (body && typeof body === 'object' && body.error) return body.error
  return body
}

/** Normalize a direct OpenAI Responses HTTP failure or streaming error event. */
export function normalizeOpenAIError(input, context = {}) {
  const source = input && typeof input === 'object' ? input : { body: input }
  const event = source.event || source
  const envelope = openAIEnvelope(source)
  const error = envelope && typeof envelope === 'object' ? envelope : {}
  const status = integerStatus(source.status ?? error.status ?? event.response?.status)
  const code = cleanCode(error.code ?? event.code)
  const providerType = cleanString(error.type ?? event.error?.type)
  const param = cleanString(error.param)
  const rawMessage = error.message ?? (typeof envelope === 'string' ? envelope : null) ??
    event.response?.incomplete_details?.reason
  const message = typeof rawMessage === 'string' &&
      /^max(?:imum)?[_ -]?output[_ -]?tokens?$/i.test(rawMessage.trim())
    ? 'The response reached its output token limit.'
    : cleanMessage(rawMessage, `OpenAI request failed${status ? ` (HTTP ${status})` : ''}.`)
  const providerError = {}
  addCode(providerError, code)
  addString(providerError, 'providerType', providerType)
  addString(providerError, 'param', param)
  addStatus(providerError, status)
  addString(providerError, 'requestId', source.requestId ?? source.request_id ?? error.request_id ??
    header(source.headers, 'x-request-id') ?? header(source.headers, 'request-id'))
  addString(providerError, 'clientRequestId', source.clientRequestId ?? source.client_request_id ??
    header(source.headers, 'x-client-request-id'))

  const retryAfter = source.retryAfter ?? source.retry_after ?? error.retry_after ??
    header(source.headers, 'retry-after')
  const retrySeconds = durationSeconds(retryAfter)
  if (retrySeconds != null) providerError.retryAfterSeconds = retrySeconds
  else addTime(providerError, 'resetsAt', retryAfter)
  const retryMilliseconds = nonNegativeDouble(header(source.headers, 'retry-after-ms'))
  if (providerError.retryAfterSeconds == null && retryMilliseconds != null) {
    providerError.retryAfterSeconds = retryMilliseconds / 1000
  }
  if (!providerError.resetsAt) {
    addTime(providerError, 'resetsAt', source.resetsAt ?? source.resets_at ?? error.resets_at)
  }
  const rateLimits = openAIRateLimits(source.headers)
  if (rateLimits) providerError.rateLimits = rateLimits

  const errorKind = classify({ provider: 'openai', status, code, providerType, message })
  return normalizedError('openai', context, errorKind, message, providerError)
}

function codexInfo(error, data, nested) {
  const info = error.codexErrorInfo ?? data?.codexErrorInfo ?? nested?.codexErrorInfo
  if (typeof info === 'string') return { tag: info, value: {}, payload: {} }
  if (!info || typeof info !== 'object') return { tag: null, value: {}, payload: {} }
  let tag = info.type ?? info.kind
  if (!tag) {
    tag = Object.keys(info).find((key) => codexKind(key)) || null
  }
  const payload = tag && info[tag] && typeof info[tag] === 'object' ? info[tag] : info
  return { tag, value: info, payload }
}

const CODEX_SUBSCRIPTION_BACKEND_404_DIAGNOSTIC_CODE = 'codex_subscription_backend_404'
const CODEX_SUBSCRIPTION_BACKEND_404_MESSAGE =
  'The Codex subscription connection received HTTP 404 for an internal service request. Your prompt was not rejected. Retry in a moment; if it persists, check OpenAI status or Codex Help.'

// This is intentionally narrower than generic HTTP 404 handling. The bundled App Server has
// occasionally received a 404 from its own ChatGPT subscription endpoints without attaching a
// structured status to the JSON-RPC error. That is neither a malformed person request nor proof
// that reconnecting will help. Match only the bounded, provider-owned endpoint forms and replace
// the opaque URL/edge diagnostic before it crosses into the persisted transcript.
function codexSubscriptionBackend404(message) {
  if (typeof message !== 'string') return false
  const has404 = /\b(?:unexpected status|http error:)\s*404\b/i.test(message)
  const hasEndpoint = /(?:https|wss):\/\/chatgpt\.com\/backend-api\/codex\/(?:models|responses)(?=$|[/?#,:])/i.test(message)
  return has404 && hasEndpoint
}

/** Normalize a Codex App Server JSON-RPC or turn error. `willRetry` is intentionally omitted. */
export function normalizeCodexError(input, context = {}) {
  const source = input && typeof input === 'object' ? input : { message: input }
  const error = source.error && typeof source.error === 'object' ? source.error : source
  const data = error.data && typeof error.data === 'object' ? error.data : null
  const nested = data?.error && typeof data.error === 'object' ? data.error : null
  const info = codexInfo(error, data, nested)
  const status = integerStatus(error.status ?? data?.status ?? data?.httpStatus ?? nested?.status ??
    info.payload.httpStatusCode ?? info.payload.status ?? info.value.httpStatusCode ?? info.value.status)
  const code = cleanCode(error.code ?? nested?.code ?? info.payload.code ?? info.value.code)
  const providerType = cleanString(error.providerType ?? error.type ?? data?.type ?? data?.errorType ?? nested?.type)
  const param = cleanString(error.param ?? data?.param ?? nested?.param)
  const message = cleanMessage(error.message ?? nested?.message ?? info.payload.message ?? info.value.message, 'Codex request failed.')
  const subscriptionBackend404 = codexSubscriptionBackend404(message)
  const codexErrorTag = cleanString(info.tag)
  const providerError = {}
  addCode(providerError, code)
  addString(providerError, 'providerType', providerType)
  addString(providerError, 'param', param)
  addStatus(providerError, subscriptionBackend404 ? 404 : status)
  if (subscriptionBackend404) {
    providerError.diagnosticCode = CODEX_SUBSCRIPTION_BACKEND_404_DIAGNOSTIC_CODE
  }
  addString(providerError, 'requestId', error.requestId ?? error.request_id ?? data?.requestId ??
    data?.request_id ?? nested?.request_id ?? info.payload.requestId ?? info.payload.request_id ??
    info.value.requestId ?? info.value.request_id)
  addString(providerError, 'codexErrorTag', codexErrorTag)
  addSeconds(providerError, 'retryAfterSeconds', error.retryAfter ?? error.retry_after ??
    data?.retryAfter ?? data?.retry_after ?? info.payload.retryAfter ?? info.payload.retry_after ??
    info.value.retryAfter ?? info.value.retry_after)
  addTime(providerError, 'resetsAt', error.resetsAt ?? error.resets_at ??
    data?.resetsAt ?? data?.resets_at ?? info.payload.resetsAt ?? info.payload.resets_at ??
    info.value.resetsAt ?? info.value.resets_at)
  const reconnectRequired = codexReconnectRequired({ code, providerType, message, codexErrorTag })
  const errorKind = reconnectRequired ? 'authentication' : subscriptionBackend404 ? 'server' : classify({
    provider: 'codex', status, code, providerType, message, codexErrorTag,
  })
  const result = normalizedError(
    'codex',
    context,
    errorKind,
    subscriptionBackend404 ? CODEX_SUBSCRIPTION_BACKEND_404_MESSAGE : message,
    providerError,
  )
  if (reconnectRequired) result.reconnectRequired = true
  return fitWireSize(result)
}

function anthropicCode(input) {
  if (typeof input?.error === 'string') return input.error
  if (typeof input?.error?.type === 'string') return input.error.type
  if (typeof input?.subtype === 'string' && input.subtype !== 'success') return input.subtype
  if (typeof input?.terminal_reason === 'string') return input.terminal_reason
  return null
}

function anthropicMessage(input, code) {
  const explicit = cleanString(input?.error_details, MAX_MESSAGE_BYTES) ||
    cleanString(input?.error?.message, MAX_MESSAGE_BYTES) ||
    (Array.isArray(input?.errors)
      ? input.errors.map((value) => cleanString(value, MAX_MESSAGE_BYTES)).find(Boolean)
      : null) || cleanString(input?.result, MAX_MESSAGE_BYTES)
  if (explicit) return explicit
  switch (code) {
    case 'authentication_failed': return 'Anthropic authentication failed.'
    case 'oauth_org_not_allowed': return 'This Anthropic organization cannot use the selected sign-in.'
    case 'billing_error': return 'Anthropic billing or quota limit reached.'
    case 'rate_limit': return 'Anthropic rate limit reached.'
    case 'overloaded': return 'Anthropic service is overloaded.'
    case 'invalid_request': return 'Anthropic rejected the request.'
    case 'model_not_found': return 'The selected Anthropic model is unavailable.'
    case 'server_error': return 'Anthropic server error.'
    case 'max_output_tokens': return 'Anthropic response reached its output limit.'
    case 'prompt_too_long': return 'The conversation exceeds the selected model context window.'
    default: return 'Anthropic request failed.'
  }
}

// Claude-on-Vertex can report a Google OAuth failure only as prose nested inside the SDK's generic
// `api_error` / `error_during_execution` result. In particular, Workspace session controls produce
// an `invalid_grant` JSON body with `invalid_rapt` embedded in error_description/error_subtype.
// Recover that stable OAuth signal here so the terminal card starts an interactive Google sign-in
// instead of presenting the opaque SDK wrapper as an unknown, retryable provider failure.
function vertexCredentialFailure(context, { code, providerType, message, terminalReason }) {
  if (context?.access !== 'claude_vertex') return null
  const text = classificationText({ code, providerType, message, terminalReason })
  const raptRequired = /\binvalid[_ -]?rapt\b|\brapt[_ -]?required\b|reauth related error/.test(text)
  if (raptRequired) {
    return {
      code: 'invalid_rapt',
      providerType: 'credential_reauth_required',
      message: 'Your organization requires you to sign in to Google again. Reauthenticate with Google to continue using Google Vertex.',
    }
  }
  if (/\binvalid[_ -]?grant\b/.test(text)) {
    return {
      code: 'invalid_grant',
      providerType: 'credential_revoked',
      message: 'Your Google sign-in expired or was revoked. Reauthenticate with Google to continue using Google Vertex.',
    }
  }
  return null
}

/**
 * Normalize Claude Agent SDK assistant, api_retry, or result errors. Subscription
 * `rate_limit_event` stays exclusively on the existing Claude usage-limit path.
 */
export function normalizeAnthropicError(input, context = {}) {
  const source = input && typeof input === 'object' ? input : { error_details: input }
  if (source.type === 'rate_limit_event') return null
  if (source.type === 'result' && source.subtype === 'success' && source.is_error !== true) return null
  const code = cleanCode(anthropicCode(source))
  const status = integerStatus(source.error_status ?? source.api_error_status ?? source.status)
  const providerType = cleanString(source.subtype)
  const terminalReason = cleanString(source.terminal_reason)
  const upstreamMessage = anthropicMessage(source, code)
  const vertexCredential = vertexCredentialFailure(context, {
    code, providerType, message: upstreamMessage, terminalReason,
  })
  const message = vertexCredential?.message ?? upstreamMessage
  const providerError = {}
  addCode(providerError, vertexCredential?.code ?? code)
  addString(providerError, 'providerType', vertexCredential?.providerType ?? providerType)
  addString(providerError, 'terminalReason', terminalReason)
  addStatus(providerError, status)
  addString(providerError, 'requestId', source.request_id ?? source.requestId)
  if (source.retry_delay_ms != null) {
    const milliseconds = nonNegativeDouble(source.retry_delay_ms)
    if (milliseconds != null) providerError.retryAfterSeconds = milliseconds / 1000
  } else {
    addSeconds(providerError, 'retryAfterSeconds', source.retryAfter ?? source.retry_after)
  }
  addTime(providerError, 'resetsAt', source.resetsAt ?? source.resets_at)
  let errorKind = vertexCredential ? 'authentication' : classify({
    provider: 'anthropic', status, code, providerType, message, terminalReason,
  })
  if (source.subtype === 'api_retry' && source.error_status == null) errorKind = 'network'
  const result = normalizedError('anthropic', context, errorKind, message, providerError)
  if ((context.access === 'claude_subscription' || context.access === 'claude_vertex')
      && errorKind === 'authentication') {
    result.reconnectRequired = true
  }
  return result
}

/** Dispatch helper for integration sites that already carry the provider route. */
export function normalizeProviderError(provider, input, context = {}) {
  switch (provider) {
    case 'openai': return normalizeOpenAIError(input, context)
    case 'codex': return normalizeCodexError(input, context)
    case 'anthropic': return normalizeAnthropicError(input, context)
    default: {
      const safeProvider = cleanString(provider, 32) || 'unknown'
      const message = cleanMessage(input?.message ?? input, 'Provider request failed.')
      return normalizedError(safeProvider, context, 'unknown', message)
    }
  }
}
