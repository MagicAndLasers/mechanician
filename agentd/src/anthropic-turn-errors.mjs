import { claudeUsageLimitErrorEvent } from './claude-rate-limit.mjs'
import { isClaudeRefusalMessage } from './claude-message-events.mjs'
import { normalizeAnthropicError } from './provider-errors.mjs'

/** Reset provider failure state before a new Anthropic SDK stream attempt. */
export function resetAnthropicTurnErrors(turn) {
  if (!turn || typeof turn !== 'object') return
  turn.rateLimitInfo = null
  turn.anthropicFailure = null
}

/**
 * Retain a terminal assistant/result error reported by the Claude Agent SDK.
 * `system/api_retry` is intentionally ignored: the SDK is still retrying that
 * request, so it is status evidence rather than a terminal turn failure.
 */
export function captureAnthropicTurnError(turn, message, access) {
  if (!turn || typeof turn !== 'object' || !message || typeof message !== 'object') return null
  if (message.type === 'system' && message.subtype === 'api_retry') return null
  // A safety refusal is not a broken lane. Recording one as a provider failure would flag the
  // runtime/account unhealthy and send the user to reconnect an account that is working perfectly —
  // and on the fallback path the turn goes on to succeed, so there is no failure to report at all.
  // `SDKAssistantMessageError` has no refusal member, so the refusal arrives as its own terminal
  // and, on the frame, as stop_reason.
  if (isClaudeRefusalMessage(message)) return null
  if (message.type === 'assistant' && message.message?.stop_reason === 'refusal') return null

  let normalized = null
  if (message.type === 'assistant' && message.error) {
    normalized = normalizeAnthropicError(message, { access })
  } else if (message.type === 'result') {
    if (message.is_error === true) {
      normalized = normalizeAnthropicError(message, { access })
    }
  }

  if (normalized) turn.anthropicFailure = normalized
  return normalized
}

function thrownAnthropicError(error) {
  if (!error || typeof error !== 'object') return { error_details: String(error || 'Anthropic request failed.') }
  return {
    type: error.type,
    subtype: error.subtype,
    error: error.error,
    error_details: error.error_details ?? error.message,
    error_status: error.error_status ?? error.status ?? error.statusCode,
    api_error_status: error.api_error_status,
    request_id: error.request_id ?? error.requestId,
    terminal_reason: error.terminal_reason,
  }
}

/** Build the one terminal NDJSON event for an Anthropic turn. */
export function anthropicTerminalEvent(id, turn, { access, error = null, interrupted = false } = {}) {
  // A user interrupt remains a clean completion even if the SDK reported an
  // error candidate before its abort exception reached us.
  if (interrupted) return { type: 'done', id, interrupted: true }

  // The existing Claude subscription allocation card is more specific than
  // ordinary provider errors and retains precedence for rejected limits.
  const usageLimit = claudeUsageLimitErrorEvent(id, turn?.rateLimitInfo)
  if (usageLimit) return usageLimit

  const normalized = turn?.anthropicFailure || (error
    ? normalizeAnthropicError(thrownAnthropicError(error), { access })
    : null)
  if (normalized) return { type: 'error', id, ...normalized }
  return { type: 'done', id }
}
