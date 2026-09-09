const BROWSE_ERROR_TYPES = new Set([
  'network',
  'timeout',
  'authentication',
  'http',
  'configuration',
  'invalid_response',
  'unavailable',
  'unknown',
])

const NETWORK_CODES = new Set([
  'EAI_AGAIN',
  'ECONNREFUSED',
  'ECONNRESET',
  'EHOSTUNREACH',
  'ENETUNREACH',
  'ENOTFOUND',
  'ETIMEDOUT',
  'UND_ERR_CONNECT_TIMEOUT',
  'UND_ERR_SOCKET',
])

export const BROWSE_RESPONSE_MAX_BYTES = 8 * 1024 * 1024
const RESPONSE_TOO_LARGE_CODE = 'BROWSE_RESPONSE_TOO_LARGE'

function boundedString(value, fallback = 'Catalog request failed.') {
  const text = String(value || '').trim()
  return (text || fallback).slice(0, 512)
}

function nestedCode(error) {
  return boundedString(error?.code || error?.cause?.code || '', '').toUpperCase() || null
}

/**
 * Classify failures from Node's fetch/undici without coupling UI policy to English prose. Native
 * error codes and names win; message matching is a conservative fallback for wrapped proxy errors.
 */
export function classifyBrowseException(error) {
  const name = boundedString(error?.name || '', '').toLowerCase()
  const code = nestedCode(error)
  const message = boundedString(error?.message || error)
  const combined = `${message} ${boundedString(error?.cause?.message || '', '')}`.toLowerCase()

  if (code === RESPONSE_TOO_LARGE_CODE) {
    return {
      kind: 'invalid_response',
      message: 'The catalog response is too large for Mechanician to load safely.',
      code,
    }
  }
  if (name === 'timeouterror' || name === 'aborterror'
      || code === 'UND_ERR_CONNECT_TIMEOUT' || code === 'ETIMEDOUT'
      || /\btimed? ?out\b|\btimeout\b/.test(combined)) {
    return { kind: 'timeout', message, ...(code ? { code } : {}) }
  }
  if ((code && NETWORK_CODES.has(code))
      || /\bfetch failed\b|\bdns\b|\bgetaddrinfo\b|\bnetwork\b|\bsocket hang up\b|\bconnection (?:reset|refused|closed)\b/.test(combined)) {
    return { kind: 'network', message, ...(code ? { code } : {}) }
  }
  return { kind: 'unknown', message, ...(code ? { code } : {}) }
}

export function browseHTTPFailure(status, { usesGoogleIdentity = false } = {}) {
  const code = Number.isInteger(Number(status)) ? Number(status) : null
  if (code === 401) {
    return { kind: 'authentication', message: 'Catalog authentication is required (HTTP 401).', status: code }
  }
  if (code === 403) {
    if (usesGoogleIdentity) {
      return {
        kind: 'authentication',
        message: 'Google denied access to this managed catalog. Reconnect Google and try again.',
        status: code,
      }
    }
    return { kind: 'http', message: 'Catalog access was denied (HTTP 403).', status: code }
  }
  return {
    kind: 'http',
    message: code == null ? 'Catalog request failed.' : `Catalog request failed (HTTP ${code}).`,
    ...(code == null ? {} : { status: code }),
  }
}

function responseTooLargeError() {
  return Object.assign(
    new Error('The catalog response exceeded Mechanician’s safe size limit.'),
    { code: RESPONSE_TOO_LARGE_CODE },
  )
}

/**
 * Read a fetch response without allowing a registry, proxy, or login page to allocate an unbounded
 * body in agentd. Content-Length is only an early rejection: streamed bytes remain authoritative.
 */
export async function readBoundedBrowseBody(
  response,
  { maximumBytes = BROWSE_RESPONSE_MAX_BYTES } = {},
) {
  const limit = Number.isSafeInteger(maximumBytes) && maximumBytes > 0
    ? maximumBytes
    : BROWSE_RESPONSE_MAX_BYTES
  const declaredLength = Number(response?.headers?.get?.('content-length'))
  if (Number.isFinite(declaredLength) && declaredLength > limit) {
    throw responseTooLargeError()
  }

  const body = response?.body
  if (!body) return ''
  if (typeof body.getReader !== 'function') {
    const bytes = new Uint8Array(await response.arrayBuffer())
    if (bytes.byteLength > limit) throw responseTooLargeError()
    return new TextDecoder().decode(bytes)
  }

  const reader = body.getReader()
  const chunks = []
  let total = 0
  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    const chunk = value instanceof Uint8Array ? value : new Uint8Array(value)
    total += chunk.byteLength
    if (total > limit) {
      try { await reader.cancel() } catch {}
      throw responseTooLargeError()
    }
    chunks.push(chunk)
  }

  const bytes = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }
  return new TextDecoder().decode(bytes)
}

/**
 * A successful HTTP status does not prove a catalog was returned: enterprise gateways commonly
 * redirect an expired session to a 200 HTML login page. Validate JSON here so raw markup never
 * reaches a format adapter (or leaks back through its parser error).
 */
export function browseResponseFailure(
  body,
  {
    contentType = '',
    redirected = false,
    usesGoogleIdentity = false,
  } = {},
) {
  const text = String(body ?? '')
  const jsonText = text.charCodeAt(0) === 0xFEFF ? text.slice(1) : text
  try {
    JSON.parse(jsonText)
    return null
  } catch {}

  const sample = jsonText.trimStart().slice(0, 4096).toLowerCase()
  const type = String(contentType || '').toLowerCase()
  const looksLikeHTML = type.includes('text/html')
    || /^<!doctype\s+html\b|^<(?:html|head|body|title|script)\b/.test(sample)
  const looksLikeLogin = /\b(?:sign|log)[ -]?in\b|accounts\.google|reauth|authentication required/.test(sample)

  if (usesGoogleIdentity && (looksLikeHTML || looksLikeLogin || redirected)) {
    return {
      kind: 'authentication',
      message:
        'The managed catalog returned a sign-in page instead of JSON. Reconnect Google and try again.',
      code: 'CATALOG_AUTH_HTML_RESPONSE',
    }
  }
  if (!sample) {
    return {
      kind: 'invalid_response',
      message: 'The catalog returned an empty response instead of JSON.',
      code: 'CATALOG_EMPTY_RESPONSE',
    }
  }
  if (looksLikeHTML) {
    return {
      kind: 'invalid_response',
      message: 'The catalog returned HTML instead of JSON.',
      code: 'CATALOG_HTML_RESPONSE',
    }
  }
  return {
    kind: 'invalid_response',
    message: 'The catalog returned malformed JSON.',
    code: 'CATALOG_INVALID_JSON',
  }
}

/** Backward-compatible flat NDJSON error fields: older apps still read `error`; newer ones use type. */
export function browseErrorEvent(id, failure = {}) {
  const kind = BROWSE_ERROR_TYPES.has(failure.kind) ? failure.kind : 'unknown'
  const event = {
    type: 'browse_result',
    id,
    error: boundedString(failure.message),
    errorType: kind,
  }
  if (Number.isInteger(failure.status)) event.errorStatus = failure.status
  const code = boundedString(failure.code || '', '')
  if (code) event.errorCode = code
  return event
}
