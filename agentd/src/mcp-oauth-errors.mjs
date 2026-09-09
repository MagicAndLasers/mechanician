// Safe, stage-specific diagnostics for app-owned remote MCP OAuth.
//
// The MCP SDK deliberately owns OAuth semantics. This module observes each SDK fetch just enough to
// retain the request stage and HTTP status that its OAuthError drops. It never records a URL,
// header, request/response body, authorization code, verifier, state, or token.

import { OAuthError } from '@modelcontextprotocol/sdk/server/auth/errors.js'

const STAGES = new Set([
  'authorization_setup',
  'callback_listener',
  'protected_resource_discovery',
  'authorization_server_discovery',
  'client_registration',
  'authorization_redirect',
  'authorization_callback',
  'token_exchange',
  'credential_storage',
  'same_origin_browser',
])

const KINDS = new Set([
  'network',
  'timeout',
  'http',
  'oauth',
  'protocol',
  'invalid_response',
  'configuration',
  'cancelled',
  'unknown',
])

const ACTIONS = new Set([
  'retry',
  'manual_credentials',
  'check_network',
  'check_vpn',
  'edit_connection',
  'none',
])

const DISCOVERY_STAGES = new Set([
  'protected_resource_discovery',
  'authorization_server_discovery',
])

const NETWORK_CODES = new Set([
  'EAI_AGAIN',
  'ECONNREFUSED',
  'ECONNRESET',
  'EHOSTUNREACH',
  'ENETDOWN',
  'ENETUNREACH',
  'ENOTFOUND',
  'ETIMEDOUT',
  'UND_ERR_CONNECT_TIMEOUT',
  'UND_ERR_HEADERS_TIMEOUT',
  'UND_ERR_SOCKET',
])

const TIMEOUT_CODES = new Set([
  'ETIMEDOUT',
  'UND_ERR_CONNECT_TIMEOUT',
  'UND_ERR_HEADERS_TIMEOUT',
])

const MAX_TRACE_RECORDS = 16
const MAX_DESCRIPTION_BYTES = 512
const MAX_MESSAGE_BYTES = 1024
const MAX_WIRE_BYTES = 4096
const DEFAULT_FETCH_TIMEOUT_MS = 15_000

const STAGE_LABELS = Object.freeze({
  authorization_setup: 'OAuth setup',
  callback_listener: 'Authentication callback setup',
  protected_resource_discovery: 'OAuth protected-resource discovery',
  authorization_server_discovery: 'Authorization-server discovery',
  client_registration: 'Dynamic client registration',
  authorization_redirect: 'Authorization setup',
  authorization_callback: 'Authorization',
  token_exchange: 'Token exchange',
  credential_storage: 'OAuth credential storage',
  same_origin_browser: 'Browser sign-in',
})

function truncateUtf8(value, maxBytes) {
  const bytes = Buffer.from(value, 'utf8')
  if (bytes.byteLength <= maxBytes) return value
  return bytes.subarray(0, maxBytes).toString('utf8').replace(/\uFFFD$/u, '')
}

function scrubDiagnosticText(value, maxBytes = MAX_DESCRIPTION_BYTES) {
  if (typeof value !== 'string') return null
  let text = value
    .replace(/https?:\/\/[^\s<>"']+/gi, '[redacted-url]')
    .replace(
      /(["']?(?:api[-_ ]?key|authorization[-_ ]?code|code[-_ ]?verifier|access[-_ ]?token|refresh[-_ ]?token|session[-_ ]?token|id[-_ ]?token|client[-_ ]?secret|private[-_ ]?key|password|credential|token|secret|state)["']?\s*[:=]\s*)(?!\[redacted(?:-[a-z-]+)?\])(?:"[^"]*"|'[^']*'|[^\s,;}\]]+)/gi,
      '$1[redacted]',
    )
    .replace(/\b(?:bearer|basic)\s+[a-z0-9._~+/=-]{6,}/gi, '[redacted-authorization]')
    .replace(/\bsk-(?:proj-|ant-)?[a-z0-9_-]{8,}/gi, '[redacted-api-key]')
    .replace(/\beyJ[a-z0-9_-]{6,}\.[a-z0-9_-]{6,}\.[a-z0-9_-]{6,}\b/gi, '[redacted-token]')
    .replace(/\b[a-f0-9]{40,}\b/gi, '[redacted-opaque-value]')
    .replace(/\b[a-z0-9_-]{48,}\b/gi, '[redacted-opaque-value]')
    .replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  if (!text) return null
  text = truncateUtf8(text, maxBytes)
  return text || null
}

function safeOAuthCode(value) {
  if (typeof value !== 'string') return null
  const code = value.trim()
  return /^[A-Za-z][A-Za-z0-9._~-]{0,63}$/.test(code) ? code : null
}

function safeInternalCode(value) {
  if (typeof value !== 'string') return null
  const code = value.trim()
  return /^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/.test(code) ? code : null
}

function safeStatus(value) {
  const status = Number(value)
  return Number.isInteger(status) && status >= 100 && status <= 599 ? status : null
}

function safeStage(value) {
  return STAGES.has(value) ? value : 'authorization_setup'
}

function safeKind(value) {
  return KINDS.has(value) ? value : 'unknown'
}

function safeAction(value) {
  return ACTIONS.has(value) ? value : null
}

function safeTrace(records) {
  if (!Array.isArray(records)) return []
  return records.slice(-MAX_TRACE_RECORDS).flatMap((record) => {
    if (!record || !STAGES.has(record.stage)) return []
    const next = { stage: record.stage }
    const status = safeStatus(record.status)
    if (status != null) next.status = status
    if (typeof record.ok === 'boolean') next.ok = record.ok
    if (record.outcome === 'network' || record.outcome === 'timeout') {
      next.outcome = record.outcome
    }
    const code = safeInternalCode(record.code)
    if (code) next.code = code
    return [next]
  })
}

function errorChain(error) {
  const result = []
  const seen = new Set()
  let current = error
  while (current && (typeof current === 'object' || typeof current === 'function')
      && !seen.has(current) && result.length < 8) {
    seen.add(current)
    result.push(current)
    current = current.cause
  }
  return result
}

function errorText(chain) {
  return chain
    .map((error) => typeof error?.message === 'string' ? error.message : '')
    .filter(Boolean)
    .join(' ')
    .toLowerCase()
}

function errorCode(chain) {
  for (const error of chain) {
    const code = safeInternalCode(typeof error?.code === 'string' ? error.code.toUpperCase() : '')
    if (code) return code
  }
  return null
}

function inferFetchStage(input, init, fallbackStage) {
  let pathname = ''
  try {
    const raw = input instanceof URL ? input.href
      : typeof input === 'string' ? input
        : typeof input?.url === 'string' ? input.url : ''
    pathname = new URL(raw).pathname.toLowerCase()
  } catch {}
  if (pathname.includes('/.well-known/oauth-protected-resource')) {
    return 'protected_resource_discovery'
  }
  if (pathname.includes('/.well-known/oauth-authorization-server')
      || pathname.includes('/.well-known/openid-configuration')) {
    return 'authorization_server_discovery'
  }

  const method = String(init?.method || input?.method || 'GET').toUpperCase()
  if (method === 'POST') {
    let contentType = ''
    try {
      const headers = new Headers(input?.headers)
      new Headers(init?.headers).forEach((value, name) => headers.set(name, value))
      contentType = headers.get('content-type')?.toLowerCase() || ''
    } catch {}
    if (contentType.includes('application/json')) return 'client_registration'
    if (contentType.includes('application/x-www-form-urlencoded')) return 'token_exchange'
  }
  return safeStage(fallbackStage)
}

function traceFor(error, attempt) {
  if (attempt && typeof attempt.records === 'function') return safeTrace(attempt.records())
  return safeTrace(error?.trace)
}

function lastTraceRecord(trace) {
  return trace.length ? trace[trace.length - 1] : null
}

function selectedStage(explicitStage, attempt, trace) {
  if (STAGES.has(explicitStage)) return explicitStage
  const current = attempt?.currentStage?.()
  if (STAGES.has(current) && current !== 'authorization_setup') return current
  return lastTraceRecord(trace)?.stage || safeStage(current)
}

function selectedStatus(trace, stage) {
  for (let index = trace.length - 1; index >= 0; index--) {
    const record = trace[index]
    if (record.stage === stage && record.status != null) return record.status
  }
  return null
}

function defaultRetryable(kind, status, oauthError) {
  if (kind === 'network' || kind === 'timeout') return true
  if (kind === 'http') return status === 408 || status === 425 || status === 429
    || (status != null && status >= 500)
  if (kind === 'oauth') {
    return oauthError === 'server_error' || oauthError === 'temporarily_unavailable'
  }
  return false
}

function defaultAction(kind, code) {
  if (kind === 'cancelled') return 'none'
  if (code === 'dynamic_client_registration_unsupported') return 'manual_credentials'
  if (kind === 'network') return 'check_network'
  if (kind === 'configuration') return 'edit_connection'
  return 'retry'
}

export class McpOAuthFailure extends Error {
  constructor({
    stage = 'authorization_setup',
    kind = 'unknown',
    code,
    status,
    oauthError,
    oauthDescription,
    message = 'MCP authorization failed.',
    suggestedAction,
    retryable,
    authorizationWasPresented = false,
    fallbackFromStage,
    trace = [],
    cause,
  } = {}) {
    const safeMessage = scrubDiagnosticText(message, MAX_MESSAGE_BYTES)
      || 'MCP authorization failed.'
    super(safeMessage, cause === undefined ? undefined : { cause })
    this.name = 'McpOAuthFailure'
    this.stage = safeStage(stage)
    this.kind = safeKind(kind)
    this.code = safeInternalCode(code)
    this.status = safeStatus(status)
    this.oauthError = safeOAuthCode(oauthError)
    this.oauthDescription = scrubDiagnosticText(oauthDescription)
    this.suggestedAction = safeAction(suggestedAction)
      || defaultAction(this.kind, this.code)
    this.retryable = typeof retryable === 'boolean'
      ? retryable : defaultRetryable(this.kind, this.status, this.oauthError)
    this.authorizationWasPresented = authorizationWasPresented === true
    this.fallbackFromStage = STAGES.has(fallbackFromStage) ? fallbackFromStage : null
    Object.defineProperty(this, 'trace', {
      value: safeTrace(trace),
      configurable: false,
      enumerable: false,
      writable: false,
    })
  }
}

function copyFailure(failure, {
  attempt,
  stage,
  authorizationWasPresented,
  fallbackFromStage,
} = {}) {
  const trace = attempt ? traceFor(null, attempt) : failure.trace
  return new McpOAuthFailure({
    stage: STAGES.has(stage) ? stage : failure.stage,
    kind: failure.kind,
    code: failure.code,
    status: failure.status,
    oauthError: failure.oauthError,
    oauthDescription: failure.oauthDescription,
    message: failure.message,
    suggestedAction: failure.suggestedAction,
    retryable: failure.retryable,
    authorizationWasPresented: authorizationWasPresented === true
      || failure.authorizationWasPresented,
    fallbackFromStage: fallbackFromStage || failure.fallbackFromStage,
    trace,
    cause: failure.cause,
  })
}

/**
 * Per-attempt SDK fetch observer. Only stage/status/outcome enter the trace.
 */
export function createMcpOAuthAttempt(
  fetchImpl = globalThis.fetch,
  { timeoutMs = DEFAULT_FETCH_TIMEOUT_MS } = {},
) {
  if (typeof fetchImpl !== 'function') throw new TypeError('MCP OAuth fetch is not configured')
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    throw new TypeError('MCP OAuth fetch timeout is invalid')
  }
  let stage = 'authorization_setup'
  const records = []
  const remember = (record) => {
    records.push(record)
    if (records.length > MAX_TRACE_RECORDS) records.shift()
  }
  const attempt = {
    setStage(value) {
      stage = safeStage(value)
    },
    currentStage() {
      return stage
    },
    records() {
      return safeTrace(records)
    },
    async fetch(input, init) {
      stage = inferFetchStage(input, init, stage)
      const timeoutSignal = AbortSignal.timeout(timeoutMs)
      const callerSignal = init?.signal || input?.signal
      const signal = callerSignal
        ? AbortSignal.any([callerSignal, timeoutSignal])
        : timeoutSignal
      try {
        const response = await fetchImpl(input, { ...(init || {}), signal })
        remember({ stage, status: response?.status, ok: response?.ok })
        return response
      } catch (error) {
        const chain = errorChain(error)
        const code = timeoutSignal.aborted
          ? 'MCP_OAUTH_FETCH_TIMEOUT' : errorCode(chain)
        const timeout = timeoutSignal.aborted
          || TIMEOUT_CODES.has(code)
          || chain.some((value) => /^(?:TimeoutError)$/i.test(value?.name || ''))
        remember({
          stage,
          outcome: timeout ? 'timeout' : 'network',
          ...(code ? { code } : {}),
        })
        // Preserve the SDK's exception identity. Its discovery helper deliberately treats a
        // TypeError as a signal to retry without request headers and to continue through its
        // standards-defined metadata fallbacks. Classification happens once at our manager
        // boundary, using this attempt trace, after the SDK has finished its own orchestration.
        throw error
      }
    },
  }
  return Object.freeze(attempt)
}

/**
 * Convert SDK, undici, Keychain, callback, and app errors into one secret-free failure.
 */
export function normalizeMcpOAuthFailure(error, {
  attempt,
  stage,
  authorizationWasPresented = false,
  fallbackFromStage,
} = {}) {
  if (error instanceof McpOAuthFailure) {
    return copyFailure(error, {
      attempt, stage, authorizationWasPresented, fallbackFromStage,
    })
  }

  const trace = traceFor(error, attempt)
  let resolvedStage = selectedStage(stage, attempt, trace)
  const chain = errorChain(error)
  const text = errorText(chain)
  const directMessage = typeof error?.message === 'string'
    ? error.message.trim().toLowerCase() : ''
  const last = lastTraceRecord(trace)
  const code = errorCode(chain) || safeInternalCode(last?.code)
  const statusForStage = () => selectedStatus(trace, resolvedStage)
  const base = {
    stage: resolvedStage,
    authorizationWasPresented,
    fallbackFromStage,
    trace,
    cause: error,
  }

  if (code === 'MCP_OAUTH_SUPERSEDED') {
    return new McpOAuthFailure({
      ...base,
      kind: 'cancelled',
      code,
      message: 'This MCP authorization operation was superseded.',
      suggestedAction: 'none',
      retryable: false,
    })
  }

  // Preserve the SDK's structured OAuth signal before inspecting any description prose. An OAuth
  // server is allowed to say "request timed out" or "operation cancelled" in error_description;
  // neither makes it a local timeout/cancel event.
  const oauth = chain.find((candidate) => candidate instanceof OAuthError)
  if (oauth) {
    const invalidRawResponse = /\binvalid oauth error response\b|\braw body\b/i.test(oauth.message || '')
    if (invalidRawResponse) {
      return new McpOAuthFailure({
        ...base,
        kind: 'invalid_response',
        status: statusForStage(),
        message: 'The authorization server returned an invalid OAuth error response.',
      })
    }
    const oauthError = safeOAuthCode(oauth.errorCode)
    return new McpOAuthFailure({
      ...base,
      kind: 'oauth',
      status: statusForStage(),
      oauthError,
      oauthDescription: oauth.message,
      message: oauthError === 'access_denied'
        ? 'Authorization was declined.' : 'The authorization server rejected the request.',
    })
  }

  if (code === 'MCP_OAUTH_CANCELLED'
      || directMessage === 'cancelled'
      || directMessage === 'canceled'
      || directMessage === 'authorization was cancelled.'
      || directMessage === 'authorization was canceled.') {
    return new McpOAuthFailure({
      ...base,
      kind: 'cancelled',
      code: code || 'MCP_OAUTH_CANCELLED',
      message: 'Authorization was cancelled.',
      suggestedAction: 'none',
      retryable: false,
    })
  }

  const timedOut = TIMEOUT_CODES.has(code)
    || code === 'MCP_OAUTH_FETCH_TIMEOUT'
    || last?.outcome === 'timeout'
    || chain.some((value) => /^(?:TimeoutError)$/i.test(value?.name || ''))
    || directMessage === 'authentication timed out.'
    || directMessage === 'authorization timed out'
    || directMessage === (
      'timed out waiting for the sign-in to finish. '
      + 'if you completed it on claude.ai, click check status.'
    )
  if (timedOut) {
    return new McpOAuthFailure({
      ...base,
      kind: 'timeout',
      code,
      message: 'Authentication timed out.',
      suggestedAction: 'retry',
      retryable: true,
    })
  }
  if ((code && NETWORK_CODES.has(code))
      || last?.outcome === 'network') {
    return new McpOAuthFailure({
      ...base,
      kind: 'network',
      code,
      message: 'The authorization server could not be reached.',
      suggestedAction: 'check_network',
      retryable: true,
    })
  }

  const providerDenial = /^authorization denied:\s*([A-Za-z][A-Za-z0-9._~-]{0,63})$/i
    .exec(directMessage)
  if (providerDenial) {
    return new McpOAuthFailure({
      ...base,
      stage: 'authorization_callback',
      kind: 'oauth',
      code: safeOAuthCode(providerDenial[1]),
      message: 'Authorization was declined.',
      oauthError: safeOAuthCode(providerDenial[1]),
      suggestedAction: 'none',
      retryable: false,
    })
  }

  if (/\bdoes not support dynamic client registration\b/.test(text)) {
    return new McpOAuthFailure({
      ...base,
      stage: 'client_registration',
      kind: 'protocol',
      code: 'dynamic_client_registration_unsupported',
      message: 'Incompatible auth server: does not support dynamic client registration',
      suggestedAction: 'manual_credentials',
      retryable: false,
    })
  }
  if (/\bdoes not support response type code\b/.test(text)) {
    return new McpOAuthFailure({
      ...base,
      stage: 'authorization_redirect',
      kind: 'protocol',
      code: 'authorization_code_unsupported',
      message: 'Incompatible auth server: does not support authorization-code responses.',
      retryable: false,
    })
  }
  if (/\bdoes not support code challenge method s256\b/.test(text)) {
    return new McpOAuthFailure({
      ...base,
      stage: 'authorization_redirect',
      kind: 'protocol',
      code: 'pkce_s256_unsupported',
      message: 'Incompatible auth server: does not support PKCE S256.',
      retryable: false,
    })
  }
  if (/\bresource server does not implement oauth 2\.0 protected resource metadata\b/.test(text)) {
    return new McpOAuthFailure({
      ...base,
      stage: 'protected_resource_discovery',
      kind: 'protocol',
      code: 'protected_resource_metadata_missing',
      message: 'OAuth protected-resource metadata was not found (RFC 9728).',
    })
  }

  const protectedHTTP = text.match(
    /\bhttp\s+([1-5]\d\d)\s+trying to load well-known oauth protected resource metadata\b/,
  )
  if (protectedHTTP) {
    return new McpOAuthFailure({
      ...base,
      stage: 'protected_resource_discovery',
      kind: 'http',
      status: Number(protectedHTTP[1]),
      message: 'OAuth protected-resource discovery failed.',
    })
  }
  const metadataHTTP = text.match(
    /\bhttp\s+([1-5]\d\d)\s+trying to load (?:oauth|openid provider) metadata\b/,
  )
  if (metadataHTTP) {
    return new McpOAuthFailure({
      ...base,
      stage: 'authorization_server_discovery',
      kind: 'http',
      status: Number(metadataHTTP[1]),
      message: 'Authorization-server discovery failed.',
    })
  }

  if (/\bunsafe url\b/.test(text)) {
    return new McpOAuthFailure({
      ...base,
      stage: 'authorization_redirect',
      kind: 'configuration',
      code: 'unsafe_authorization_url',
      message: 'The authorization server returned an unsafe URL.',
      suggestedAction: 'edit_connection',
      retryable: false,
    })
  }
  if (/\bno authorization code\b/.test(text)) {
    return new McpOAuthFailure({
      ...base,
      stage: 'authorization_callback',
      kind: 'protocol',
      code: 'authorization_code_missing',
      message: 'No authorization code was received.',
    })
  }
  if (/\bno access token\b/.test(text)) {
    return new McpOAuthFailure({
      ...base,
      kind: 'protocol',
      code: 'access_token_missing',
      message: 'No access token was received.',
    })
  }
  if (/\b(?:did not return|returned no) (?:a )?bearer token\b/.test(text)) {
    return new McpOAuthFailure({
      ...base,
      stage: 'token_exchange',
      kind: 'invalid_response',
      code: 'bearer_token_missing',
      message: 'The authorization server did not return a bearer token.',
    })
  }
  if (/\bcode verifier is no longer available\b/.test(text)) {
    return new McpOAuthFailure({
      ...base,
      stage: 'token_exchange',
      kind: 'configuration',
      code: 'code_verifier_missing',
      message: 'The OAuth code verifier is no longer available.',
      retryable: false,
    })
  }
  if (/\bkeychain\b/.test(text)) {
    return new McpOAuthFailure({
      ...base,
      stage: 'credential_storage',
      kind: 'configuration',
      code: 'keychain_unavailable',
      message: 'MCP OAuth credentials could not be stored in the macOS Keychain.',
      suggestedAction: 'retry',
    })
  }
  if (/\bdeclined\b|\baccess denied\b/.test(text)) {
    return new McpOAuthFailure({
      ...base,
      stage: 'authorization_callback',
      kind: 'oauth',
      oauthError: 'access_denied',
      message: 'Authorization was declined.',
      retryable: false,
    })
  }

  if (last?.status != null && last.ok === false) {
    resolvedStage = last.stage
    return new McpOAuthFailure({
      ...base,
      stage: resolvedStage,
      kind: 'http',
      status: last.status,
      message: `${STAGE_LABELS[resolvedStage]} failed.`,
    })
  }
  if (chain.some((value) => value?.name === 'SyntaxError' || value?.name === 'ZodError')
      || (last?.status != null && last.ok === true)) {
    return new McpOAuthFailure({
      ...base,
      kind: 'invalid_response',
      status: statusForStage(),
      message: `${STAGE_LABELS[resolvedStage]} returned an invalid response.`,
    })
  }

  return new McpOAuthFailure({
    ...base,
    kind: 'unknown',
    message: `MCP authorization failed during ${STAGE_LABELS[resolvedStage].toLowerCase()}.`,
  })
}

function stageLabel(stage) {
  return STAGE_LABELS[stage] || STAGE_LABELS.authorization_setup
}

function qualifier(failure) {
  const values = []
  if (failure.status != null) values.push(`HTTP ${failure.status}`)
  if (failure.oauthError) values.push(failure.oauthError)
  return values.length ? ` (${values.join(', ')})` : ''
}

function publicMessage(failure, networkScope) {
  if (failure.code === 'dynamic_client_registration_unsupported') {
    return 'Incompatible auth server: does not support dynamic client registration'
  }
  if (failure.kind === 'cancelled') return failure.message
  if (failure.kind === 'network') {
    const scopeHint = networkScope === 'vpnOnly'
      ? 'Connect to the required VPN and try again.'
      : 'Check your network connection and try again.'
    return `Could not reach the authorization server during ${stageLabel(failure.stage).toLowerCase()}. ${scopeHint}`
  }
  if (failure.kind === 'timeout') {
    return failure.stage === 'authorization_callback' || failure.stage === 'same_origin_browser'
      ? 'Authentication timed out.'
      : `${stageLabel(failure.stage)} timed out.`
  }
  if (failure.kind === 'oauth') {
    const base = failure.oauthError === 'access_denied'
      ? 'Authorization was declined' : `${stageLabel(failure.stage)} failed`
    return truncateUtf8(
      `${base}${qualifier(failure)}${failure.oauthDescription ? `: ${failure.oauthDescription}` : ''}.`,
      MAX_MESSAGE_BYTES,
    )
  }
  if (failure.kind === 'http') {
    return `${stageLabel(failure.stage)} failed${qualifier(failure)}.`
  }
  if (failure.kind === 'invalid_response') {
    return `${stageLabel(failure.stage)} returned an invalid response${qualifier(failure)}.`
  }
  if (failure.kind === 'protocol' || failure.kind === 'configuration') {
    return truncateUtf8(failure.message, MAX_MESSAGE_BYTES)
  }
  return `${stageLabel(failure.stage)} failed.`
}

/**
 * Backward-compatible flat NDJSON fields. `message` remains authoritative for older apps.
 */
export function mcpOAuthFailurePayload(error, { networkScope } = {}) {
  const failure = normalizeMcpOAuthFailure(error)
  const suggestedAction = failure.kind === 'network'
    ? networkScope === 'vpnOnly' ? 'check_vpn' : 'check_network'
    : failure.suggestedAction
  const payload = {
    message: publicMessage(failure, networkScope),
    errorStage: failure.stage,
    errorKind: failure.kind,
    suggestedAction,
    retryable: failure.retryable,
  }
  if (failure.code) payload.errorCode = failure.code
  if (failure.status != null) payload.httpStatus = failure.status
  if (failure.oauthError) payload.oauthError = failure.oauthError
  if (failure.oauthDescription) payload.oauthDescription = failure.oauthDescription
  if (failure.fallbackFromStage) payload.fallbackFromStage = failure.fallbackFromStage

  if (Buffer.byteLength(JSON.stringify(payload), 'utf8') > MAX_WIRE_BYTES) {
    delete payload.oauthDescription
    payload.message = truncateUtf8(payload.message, 512)
  }
  return payload
}

/**
 * Which hosts may use the same-origin browser flow is one organization's fact, not the app's. It
 * arrives from that organization's signed tenant profile, which the app forwards here; the public
 * app declares none, and with none declared no host qualifies and the fallback is unavailable.
 *
 * The value is a host SUFFIX, and a candidate must be exactly one additional label beneath it —
 * so `a.mcp.example.com` qualifies while `a.b.mcp.example.com` and `mcp.example.com.evil.test` do
 * not. That is the same shape the previous compiled-in pattern enforced.
 */
function sameOriginBrowserHostSuffix() {
  const raw = (process.env.MECHANICIAN_MCP_SAME_ORIGIN_HOST_SUFFIX || '').trim().toLowerCase()
  if (!raw) return ''
  return raw.startsWith('.') ? raw : `.${raw}`
}

function isSameOriginBrowserEndpoint(server) {
  const suffix = sameOriginBrowserHostSuffix()
  if (!suffix) return false
  try {
    const url = new URL(server?.url)
    const host = url.hostname.toLowerCase()
    if (!host.endsWith(suffix)) return false
    const label = host.slice(0, host.length - suffix.length)
    return url.protocol === 'https:'
      && !url.username && !url.password
      && !url.port
      && !url.search && !url.hash
      && url.pathname === '/mcp'
      && /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label)
  } catch {
    return false
  }
}

/**
 * The same-origin browser contract is a deployment-specific compatibility path, not a generic OAuth
 * fallback. A standards failure after discovery, a network failure, or any post-redirect failure
 * must remain visible instead of being replaced by a second authentication mechanism.
 */
export function isSameOriginBrowserFallbackEligible(server, error) {
  const failure = normalizeMcpOAuthFailure(error)
  if (!isSameOriginBrowserEndpoint(server)
      || failure.authorizationWasPresented
      || failure.kind === 'network'
      || failure.kind === 'timeout'
      || failure.kind === 'oauth'
      || failure.kind === 'cancelled') {
    return false
  }
  if (DISCOVERY_STAGES.has(failure.stage)) {
    return failure.kind === 'http'
      || failure.kind === 'protocol'
      || failure.kind === 'invalid_response'
  }

  // The SDK may treat absent metadata as legacy OAuth and fail later at `/register`. Retain that
  // compatibility only when authorization-server discovery itself had no successful response.
  if (failure.stage !== 'client_registration'
      || !['http', 'protocol', 'invalid_response'].includes(failure.kind)) {
    return false
  }
  const discovery = failure.trace.filter(
    (record) => record.stage === 'authorization_server_discovery',
  )
  return discovery.length > 0
    && !discovery.some((record) => record.ok === true)
    && discovery.some((record) => record.ok === false)
}
