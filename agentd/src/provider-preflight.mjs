const DEFINITIVE_CREDENTIAL_REASONS = new Set([
  'no_credentials',
  'revoked',
  'reauth_required',
])

function bounded(value, fallback, limit = 512) {
  const text = String(value || '').trim()
  return (text || fallback).slice(0, limit)
}

function contextFields(context) {
  return {
    provider: bounded(context?.provider, 'unknown', 32),
    access: bounded(context?.access, 'unknown', 64),
    providerLabel: bounded(context?.providerLabel, 'The provider', 80),
    identityLabel: bounded(context?.identityLabel, 'Your account', 80),
  }
}

function providerError(reason, result) {
  const detail = { providerType: `credential_${reason}` }
  if (Number.isInteger(result?.httpStatus)) detail.status = result.httpStatus
  const subtype = bounded(result?.errorSubtype, '', 64).toLowerCase()
  if (/^[a-z0-9_=-]+$/.test(subtype)) detail.code = subtype
  return detail
}

/**
 * Normalize an adapter-specific credential probe into the same provider failure/account-state shape.
 * Vertex supplies Google ADC today; Bedrock can later supply an AWS verifier without changing the
 * turn loop, native UI, or transcript protocol.
 */
export function normalizeCredentialPreflight(result, context = {}) {
  const fields = contextFields(context)
  if (result?.ok === true) {
    return { ok: true, verification: 'verified' }
  }

  const reason = bounded(result?.reason, 'unknown', 64).toLowerCase()
  if (DEFINITIVE_CREDENTIAL_REASONS.has(reason)) {
    const workspaceReauth = reason === 'reauth_required'
      && /rapt/i.test(result?.errorSubtype || '')
    const message = reason === 'no_credentials'
      ? `${fields.identityLabel} credentials are missing. Reconnect ${fields.providerLabel} and try again.`
      : reason === 'reauth_required'
        ? workspaceReauth
          ? `Your organization requires you to sign in to ${fields.identityLabel} again. Reauthenticate with ${fields.identityLabel} to continue using ${fields.providerLabel}.`
          : `${fields.identityLabel} requires a fresh sign-in. Reconnect ${fields.providerLabel} and try again.`
        : fields.access === 'claude_vertex'
          ? `Your ${fields.identityLabel} sign-in expired or was revoked. Reauthenticate with ${fields.identityLabel} to continue using ${fields.providerLabel}.`
          : `${fields.identityLabel} sign-in expired or was revoked. Reconnect ${fields.providerLabel} and try again.`
    return {
      ok: false,
      verification: 'disconnected',
      failure: {
        errorKind: 'authentication',
        provider: fields.provider,
        access: fields.access,
        message,
        providerError: providerError(reason, result),
        reconnectRequired: true,
      },
    }
  }

  if (reason === 'network') {
    return {
      ok: false,
      verification: 'deferred',
      failure: {
        errorKind: 'network',
        provider: fields.provider,
        access: fields.access,
        message: `Couldn’t verify ${fields.providerLabel} credentials because the authentication service could not be reached.`,
        providerError: providerError(reason, result),
      },
    }
  }

  return {
    ok: false,
    verification: 'deferred',
    failure: {
      errorKind: 'unknown',
      provider: fields.provider,
      access: fields.access,
      message: `${fields.providerLabel} credentials could not be verified before the request started.`,
      providerError: providerError('unknown', result),
    },
  }
}

/**
 * Map the Claude engine's structured `auth status` classification onto the preflight contract.
 *
 * A probe that could not run at all (`status_unavailable`, a missing binary, a timeout) is
 * deliberately NOT definitive: a transient local fault is no evidence that the stored credential was
 * revoked, and treating it as such would sign the user out for the wrong reason.
 */
export function claudeSubscriptionCredentialProbe(status) {
  if (status?.authenticated === true) return { ok: true }
  switch (status?.reason) {
    case 'not_logged_in':
      return { ok: false, reason: 'revoked', errorSubtype: status.reason }
    case 'provider_conflict':
    case 'unsupported_auth_method':
      return { ok: false, reason: 'reauth_required', errorSubtype: status.reason }
    default:
      return { ok: false, reason: 'unknown', errorSubtype: status?.reason || 'status_unavailable' }
  }
}

/**
 * A single-flight, time-bounded gate around an expensive credential probe.
 *
 * The Claude subscription lane cannot afford to spawn the bundled engine before every prompt, but it
 * also cannot keep discovering an expired session mid-turn. Recent proof (a completed turn, or a
 * successful probe) suppresses the probe for `ttlMs`; anything that invalidates that proof reopens
 * it immediately. Concurrent turns share one in-flight probe rather than racing several.
 */
export function createCredentialTrustWindow({ ttlMs = 600_000, now = Date.now } = {}) {
  // Never a real timestamp: a zero sentinel would read as *verified* under any clock whose origin is
  // within ttlMs of zero, silently skipping the first probe.
  let verifiedAt = -Infinity
  let inFlight = null

  return {
    /** True when the next call actually spawns a probe rather than reusing recent proof. */
    get willProbe() { return now() - verifiedAt >= ttlMs },
    /** Positive evidence that bypasses the next probe (e.g. a turn the provider completed). */
    accept() { verifiedAt = now() },
    /** Drop the trust window so the next call re-probes (e.g. after an authentication failure). */
    suspect() { verifiedAt = -Infinity },
    verify(probe) {
      if (now() - verifiedAt < ttlMs) return Promise.resolve({ ok: true })
      if (inFlight) return inFlight
      inFlight = Promise.resolve()
        .then(probe)
        .then((result) => {
          if (result?.ok) verifiedAt = now()
          return result
        })
        .finally(() => { inFlight = null })
      return inFlight
    },
  }
}

export async function runCredentialPreflight(verify, context = {}) {
  try {
    return normalizeCredentialPreflight(await verify(), context)
  } catch {
    return normalizeCredentialPreflight({ ok: false, reason: 'unknown' }, context)
  }
}

export const PROVIDER_TIMEOUT_PHASES = new Set([
  'provider_start_timeout',
  'provider_first_output_timeout',
  'provider_compaction_timeout',
])

export function providerStartTimeoutFailure(
  context = {},
  timeoutMs = 60_000,
  phase = 'start',
  limit = 'idle',
) {
  const fields = contextFields(context)
  const seconds = Math.round(timeoutMs / 1000)
  const compaction = phase === 'compaction'
  return {
    errorKind: 'network',
    provider: fields.provider,
    access: fields.access,
    message: compaction
      ? `${fields.providerLabel} was still compacting this conversation’s context after ${seconds} seconds.`
      : limit === 'wall'
        ? `${fields.providerLabel} produced no response after ${seconds} seconds.`
      : `${fields.providerLabel} did not begin responding within ${seconds} seconds.`,
    providerError: {
      providerType: compaction ? 'provider_compaction_timeout'
        : limit === 'wall' ? 'provider_first_output_timeout' : 'provider_start_timeout',
    },
  }
}

const CLAUDE_ZERO_USAGE_FIELDS = [
  'input_tokens',
  'cache_creation_input_tokens',
  'cache_read_input_tokens',
  'output_tokens',
]

const CLAUDE_USAGE_METADATA_FIELDS = [
  'cache_creation',
  'inference_geo',
  'iterations',
  'output_tokens_details',
  'server_tool_use',
  'service_tier',
  'speed',
]

const CLAUDE_ZERO_MODEL_USAGE_FIELDS = [
  'inputTokens',
  'cacheCreationInputTokens',
  'cacheReadInputTokens',
  'outputTokens',
  'webSearchRequests',
  'costUSD',
]

function explicitFiniteZeroFields(value, fields) {
  return value && typeof value === 'object' && !Array.isArray(value)
    && fields.every((field) => Number.isFinite(value[field]) && value[field] === 0)
}

function onlyKnownFields(value, fields) {
  return value && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).every((field) => fields.includes(field))
}

function onlyNullMetadata(value, fields) {
  return fields.every((field) => value[field] === undefined || value[field] === null)
}

function exactZeroUsage(value) {
  return explicitFiniteZeroFields(value, CLAUDE_ZERO_USAGE_FIELDS)
    && onlyKnownFields(value, [...CLAUDE_ZERO_USAGE_FIELDS, ...CLAUDE_USAGE_METADATA_FIELDS])
    && onlyNullMetadata(value, CLAUDE_USAGE_METADATA_FIELDS)
}

function textBlocks(message) {
  return Array.isArray(message?.message?.content)
    ? message.message.content.filter((block) => block && typeof block === 'object')
    : []
}

function exactSyntheticText(value) {
  return value === '' || value === 'No response requested.'
}

/**
 * The Claude engine sometimes closes a response cycle with a bookkeeping assistant whose model is
 * literally `<synthetic>`. The incident shape has zero output tokens and either no content or the
 * fixed `No response requested.` sentinel. It is not provider output and must neither disable the
 * no-response watchdog nor make a prompt unsafe to replay.
 *
 * Be exact and fail closed. A synthetic-looking frame with a tool, unknown block, nonzero usage, or
 * arbitrary text is real/unknown work until the pinned SDK proves otherwise.
 */
export function isClaudeSyntheticNoOutputAssistant(message) {
  if (message?.type !== 'assistant'
      // Root frames from the pinned SDK carry null; tolerate omission for older compatible
      // engines, but a non-empty parent is unambiguously child work and may never authorize replay.
      || (message.parent_tool_use_id !== null && message.parent_tool_use_id !== undefined)
      || message.error !== undefined
      || typeof message.uuid !== 'string' || !message.uuid
      || typeof message.session_id !== 'string' || !message.session_id
      || !onlyKnownFields(message, [
        'type', 'message', 'parent_tool_use_id', 'uuid', 'session_id', 'timestamp',
      ])
      || (message.timestamp !== undefined && typeof message.timestamp !== 'string')
      || typeof message?.message?.id !== 'string' || !message.message.id
      || message?.message?.model !== '<synthetic>'
      || message.message.role !== 'assistant'
      || (message.message.type !== undefined && message.message.type !== 'message')
      || !onlyKnownFields(message.message, [
        'id', 'container', 'content', 'context_management', 'diagnostics', 'model', 'role',
        'stop_details', 'stop_reason', 'stop_sequence', 'type', 'usage',
      ])
      || !onlyNullMetadata(message.message, [
        'container', 'context_management', 'diagnostics', 'stop_details',
      ])
      || message.message.stop_reason !== 'stop_sequence'
      || message.message.stop_sequence !== 'No response requested.'
      || !exactZeroUsage(message.message.usage)
      || !Array.isArray(message.message.content)) return false
  return message.message.content.every((block) => block && typeof block === 'object'
    && block.type === 'text' && exactSyntheticText(block.text)
    && onlyKnownFields(block, ['type', 'text', 'citations'])
    && (block.citations === undefined || block.citations === null))
}

/** The companion successful result emitted for a zero-token synthetic response cycle. */
export function isClaudeSyntheticNoOutputResult(message) {
  if (message?.type !== 'result'
      || typeof message.uuid !== 'string' || !message.uuid
      || typeof message.session_id !== 'string' || !message.session_id
      || !onlyKnownFields(message, [
        'type', 'subtype', 'duration_ms', 'duration_api_ms', 'is_error', 'num_turns',
        'result', 'stop_reason', 'total_cost_usd', 'usage', 'modelUsage',
        'permission_denials', 'uuid', 'session_id',
      ])
      || message.subtype !== 'success'
      || message.is_error !== false
      || message.num_turns !== 0
      || message.stop_reason !== 'stop_sequence'
      || !Number.isFinite(message.total_cost_usd) || message.total_cost_usd !== 0
      // The SDK's sentinel can spend milliseconds in local bookkeeping even though it performs no
      // provider request. `duration_api_ms`, cost, turns and usage are the work-bearing fields.
      || !Number.isFinite(message.duration_ms) || message.duration_ms < 0
      || !Number.isFinite(message.duration_api_ms) || message.duration_api_ms !== 0
      || !Array.isArray(message.permission_denials) || message.permission_denials.length !== 0
      || !exactZeroUsage(message.usage)
      || !exactSyntheticText(message.result)) return false
  const models = message.modelUsage && typeof message.modelUsage === 'object'
    ? Object.keys(message.modelUsage) : []
  return models.length > 0
    && models.every((model) => {
      if (model !== '<synthetic>') return false
      const usage = message.modelUsage[model]
      if (!explicitFiniteZeroFields(usage, CLAUDE_ZERO_MODEL_USAGE_FIELDS)
          || !onlyKnownFields(usage, [
            ...CLAUDE_ZERO_MODEL_USAGE_FIELDS,
            'contextWindow',
            'maxOutputTokens',
          ])) return false
      return ['contextWindow', 'maxOutputTokens'].every((field) => usage[field] === undefined
        || (Number.isFinite(usage[field]) && usage[field] >= 0))
    })
}

function hasStreamAnswer(message) {
  if (message?.type !== 'stream_event' || message.parent_tool_use_id || !message.event) return false
  const event = message.event
  if (event.type === 'content_block_delta') {
    if (event.delta?.type === 'text_delta') return Boolean(event.delta.text)
    // Thinking is progress, but it is not an answer. It restarts the idle timer below while the
    // non-resettable no-answer ceiling remains armed.
    if (event.delta?.type === 'thinking_delta') return false
    // A non-empty tool-input delta proves that a concrete tool call is underway.
    if (event.delta?.type === 'input_json_delta') return Boolean(event.delta.partial_json)
    return false
  }
  if (event.type === 'content_block_start') {
    const block = event.content_block
    if (block?.type === 'tool_use') return Boolean(block.id || block.name)
    return false
  }
  return false
}

/** User-visible answer text or a concrete tool call/result has reached this turn. */
export function isProviderResponseActivity(message) {
  if (!message || typeof message !== 'object') return false
  if (message.type === 'stream_event') return hasStreamAnswer(message)
  if (message.type === 'assistant') {
    // Complete tool calls are emitted from assistant frames. Completed prose without a matching
    // streaming delta is deliberately not counted: Mechanician did not publish it to the user.
    return !message.parent_tool_use_id && Array.isArray(message.message?.content)
      && message.message.content.some((block) => block?.type === 'tool_use'
        && (block.id || block.name))
  }
  if (message.type === 'user') {
    return !message.parent_tool_use_id
      && textBlocks(message).some((block) => block.type === 'tool_result')
  }
  // A result, including the synthetic success result, is a terminal control record rather than
  // output. `streamOnce` separately decides whether its zero-output terminal is recoverable.
  return false
}

/**
 * Stable provider-neutral failure for a Claude turn that produced no usable response. Structural
 * fields let the app offer a fresh-session action without matching provider prose.
 */
export function providerNoOutputFailure(context = {}, {
  resumed = false,
  noProviderWork = false,
  freshReplayAttempted = false,
  replayRefusal = null,
} = {}) {
  const fields = contextFields(context)
  const exhausted = resumed && noProviderWork && freshReplayAttempted
  const code = exhausted ? 'no_output_after_fresh_replay'
    : replayRefusal ? 'no_output_replay_refused' : 'no_output'
  const providerError = {
    providerType: 'provider_no_output',
    code,
    diagnosticCode: exhausted
      ? 'claude_no_output_after_fresh_replay'
      : replayRefusal ? 'claude_no_output_replay_refused' : 'claude_no_output',
    resumed: Boolean(resumed),
    noProviderWork: Boolean(noProviderWork),
    freshReplayAttempted: Boolean(freshReplayAttempted),
  }
  if (['guidance_acknowledged', 'provider_work_observed', 'fresh_session'].includes(replayRefusal)) {
    providerError.replayRefusal = replayRefusal
  }
  return {
    errorKind: 'network',
    provider: fields.provider,
    access: fields.access,
    message: exhausted
      ? `${fields.providerLabel} ended twice without producing a response.`
      : replayRefusal === 'guidance_acknowledged'
        ? `${fields.providerLabel} ended without a response after accepting additional guidance.`
        : replayRefusal === 'provider_work_observed'
          ? `${fields.providerLabel} ended without a response after beginning provider or tool work.`
          : `${fields.providerLabel} ended without producing a response.`,
    providerError,
  }
}

/**
 * Context compaction is a silent operation whose duration scales with the context being
 * summarized — near a 1M window it routinely runs for minutes without emitting a single token.
 * It gets its own, far larger deadline so a healthy compaction is never mistaken for a dead
 * provider. Aborting mid-compaction is especially destructive: the turn dies *and* the context
 * is never reduced, so every retry re-enters the same doomed compaction.
 */
export function isCompactionStart(message) {
  return message?.type === 'system'
    && message.subtype === 'status'
    && message.status === 'compacting'
}

export function isCompactionEnd(message) {
  if (!message || typeof message !== 'object' || message.type !== 'system') return false
  if (message.subtype === 'compact_boundary') return true
  return message.subtype === 'status'
    && (typeof message.compact_result === 'string' || message.status !== 'compacting')
}

/**
 * A one-shot watchdog that starts only when the prompt is delivered, after MCP readiness.
 *
 * It exists to catch a provider that accepted the prompt and then never answered at all. Setup,
 * retry, and other control traffic restart the clock; only real assistant/tool output ends it. The
 * idle deadline is time-since-last-sign-of-life. The wall deadline is time-since-prompt until
 * user-visible answer text or a concrete tool call/result, and cannot be extended by retries,
 * thinking, or telemetry.
 */
export function createProviderResponseWatchdog({
  timeoutMs = 60_000,
  compactionTimeoutMs = 900_000,
  wallTimeoutMs = 900_000,
  onTimeout,
  schedule = setTimeout,
  cancel = clearTimeout,
} = {}) {
  let timer = null
  let wallTimer = null
  let waiting = false
  let compacting = false

  function stop() {
    if (timer !== null) cancel(timer)
    if (wallTimer !== null) cancel(wallTimer)
    timer = null
    wallTimer = null
    waiting = false
    compacting = false
  }

  function armIdle() {
    if (timer !== null) cancel(timer)
    timer = schedule(() => {
      timer = null
      if (wallTimer !== null) cancel(wallTimer)
      wallTimer = null
      waiting = false
      const phase = compacting ? 'compaction' : 'start'
      compacting = false
      if (typeof onTimeout === 'function') onTimeout(phase)
    }, compacting ? compactionTimeoutMs : timeoutMs)
  }

  return {
    start() {
      stop()
      waiting = true
      armIdle()
      wallTimer = schedule(() => {
        wallTimer = null
        if (!waiting) return
        if (timer !== null) cancel(timer)
        timer = null
        waiting = false
        const phase = compacting ? 'compaction' : 'start'
        compacting = false
        if (typeof onTimeout === 'function') onTimeout(phase, 'wall')
      }, wallTimeoutMs)
    },
    observe(message) {
      if (!waiting) return false
      if (isProviderResponseActivity(message)) {
        stop()
        return true
      }
      if (message?.type === 'result') {
        if (isClaudeSyntheticNoOutputResult(message)) {
          armIdle()
          return false
        }
        stop()
        return false
      }
      if (isCompactionStart(message)) compacting = true
      else if (compacting && isCompactionEnd(message)) compacting = false
      armIdle()
      return false
    },
    cancel: stop,
    get waiting() { return waiting },
    get compacting() { return compacting },
  }
}
