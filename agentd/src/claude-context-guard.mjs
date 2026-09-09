// Claude context-window guardrails.
//
// The Agent SDK owns the persisted transcript and provider-native compaction, so agentd should not
// try to reconstruct that token ledger from transcript text. The SDK's getContextUsage() control
// supplies the authoritative current fill (including system prompt, tools, MCP schemas, memory, and
// messages). Text estimation is used only for the one thing that control cannot include yet: the
// incoming prompt that has not been delivered.

export const CLAUDE_CONTEXT_POLICY = Object.freeze({
  bytesPerEstimatedToken: 3,
  minimumCompletionReserve: 24_000,
  proportionalCompletionReserve: 0.10,
  preSendProjectedRatio: 0.88,
  // A completed assistant request is a useful lower bound for the immediately following turn,
  // but it is not an authoritative snapshot of everything the CLI may add between requests.
  // Keep the no-control fast path deliberately far from compaction and refuse unusually large
  // incoming messages; either case falls back to getContextUsage().
  cachedUsageMaximumPromptTokens: 16_000,
  cachedUsageMinimumUncertaintyTokens: 48_000,
  cachedUsageProportionalUncertainty: 0.10,
  // A recovery replay is deliberately much smaller than a normal Claude window. The current user
  // message is never truncated and may use more than this when exact SDK usage proves it fits; this
  // cap applies only to durable transcript history added around it.
  maximumReplayHistoryTokens: 48_000,
  maximumReplayMessageTokens: 12_000,
  // Used when the SDK does not expose a working getContextUsage() control. The pinned SDK exposes
  // the method on Vertex too, but that route does not answer it, so method presence is insufficient.
  unknownFreshInputTokens: 96_000,
  replayOverheadTokens: 256,
})

const COMPACTION_ERROR_CHARACTERS = 256

function positiveInteger(value) {
  const number = Number(value)
  return Number.isSafeInteger(number) && number > 0 ? number : 0
}

function nonNegativeInteger(value) {
  const number = Number(value)
  return Number.isSafeInteger(number) && number >= 0 ? number : null
}

function boundedModel(value) {
  if (typeof value !== 'string') return ''
  const model = value.trim()
  return model.length <= 256 ? model : ''
}

// Catalog aliases (`opus`, `sonnet`, `default`, `*-latest`) can resolve to a different model and
// context window without the persisted picker value changing. They must re-check authoritative
// usage. Restrict the optimization to explicit Claude model IDs carrying a version component.
export function isStableClaudeContextModel(value) {
  const model = boundedModel(value)
  if (!model || /(?:^|[-_.:/])(default|latest)(?:$|[-_.:@/\[])/i.test(model)) return false
  const leaf = model.split('/').at(-1)
  if (/^(opus|sonnet|haiku)$/i.test(leaf)) return false
  return /^(?:claude[-_.]|(?:[a-z0-9-]+\.)*anthropic[.-]claude[-_.])/i.test(leaf)
    && /\d/.test(leaf)
}

// The catalog value sent to the CLI is often a friendly alias (`opus[1m]`, `default`) even though
// the same initialization response names the exact wire model it resolves to. A cached sample may
// reuse that alias only after the CURRENT query's initialization resolves it to the same explicit
// model. This keeps the optimization harness-owned: a changed provider catalog becomes a miss,
// never a stale assumption baked into Mechanician.
export function resolveClaudeContextModel(requestedModel, catalog) {
  const requested = boundedModel(requestedModel)
  if (!requested || !Array.isArray(catalog)) return ''
  const matches = catalog
    .filter((item) => boundedModel(item?.value) === requested)
  // A version-looking picker value can still be a catalog alias: the live SDK currently publishes
  // `claude-fable-5[1m] -> claude-fable-5`. Syntax is therefore never identity evidence. Exactly
  // one current row must name the picker value: absent, identical, conflicting, and malformed
  // duplicates are all ambiguous and spend the live usage control instead.
  if (matches.length !== 1) return ''
  const resolved = boundedModel(matches[0]?.resolvedModel)
  return isStableClaudeContextModel(resolved) ? resolved : ''
}

// Context variants such as `[1m]` are reported on getContextUsage()/catalog identities but not on
// the serving assistant message. The exact window is checked separately, so strip only that known
// suffix when joining the two SDK surfaces; arbitrary bracketed provider syntax still fails closed.
export function claudeServingModelMatchesContext(contextModel, servingModel) {
  const context = boundedModel(contextModel).replace(/\[1m\]$/i, '')
  const serving = boundedModel(servingModel).replace(/\[1m\]$/i, '')
  return !!context && context === serving
}

export function estimateClaudeTokens(value, policy = CLAUDE_CONTEXT_POLICY) {
  if (typeof value !== 'string' || !value) return 0
  return Math.ceil(Buffer.byteLength(value, 'utf8') / policy.bytesPerEstimatedToken)
}

export function normalizeClaudeContextUsage(value) {
  if (!value || typeof value !== 'object') return null
  const totalTokens = nonNegativeInteger(value.totalTokens)
  const maxTokens = positiveInteger(value.maxTokens)
  if (totalTokens === null || !maxTokens || totalTokens >= Number.MAX_SAFE_INTEGER) return null
  const rawThreshold = positiveInteger(value.autoCompactThreshold)
  return {
    totalTokens,
    maxTokens,
    rawMaxTokens: positiveInteger(value.rawMaxTokens) || maxTokens,
    model: boundedModel(value.model),
    autoCompactThreshold: rawThreshold && rawThreshold <= maxTokens ? rawThreshold : null,
    isAutoCompactEnabled: value.isAutoCompactEnabled === true,
  }
}

/**
 * Recover the provider request's true trailing context from one root assistant frame.
 *
 * Top-level usage is cumulative when Anthropic performs server-side iterations. In that shape the
 * final serving iteration, not the aggregate, is the request that becomes the session's current
 * context. Compaction/advisor iterations are not interchangeable with a serving message, so an
 * ambiguous trailing iteration fails closed instead of manufacturing a cache sample.
 */
export function claudeAssistantContextSample(usage, fallbackModel = '') {
  if (!usage || typeof usage !== 'object') return null
  let selected = usage
  if (Array.isArray(usage.iterations) && usage.iterations.length) {
    selected = usage.iterations.at(-1)
    if (!['message', 'fallback_message'].includes(selected?.type)) return null
  }

  const inputTokens = nonNegativeInteger(selected.input_tokens)
  const cacheCreationTokens = nonNegativeInteger(selected.cache_creation_input_tokens ?? 0)
  const cacheReadTokens = nonNegativeInteger(selected.cache_read_input_tokens ?? 0)
  const outputTokens = nonNegativeInteger(selected.output_tokens)
  if ([inputTokens, cacheCreationTokens, cacheReadTokens, outputTokens].includes(null)) return null
  const totalTokens = inputTokens + cacheCreationTokens + cacheReadTokens + outputTokens
  if (!Number.isSafeInteger(totalTokens) || totalTokens <= 0) return null
  const model = boundedModel(selected.model) || boundedModel(fallbackModel)
  if (!model) return null
  return { totalTokens, model }
}

/**
 * Decide whether a one-turn-old provider sample is far enough from the context boundary to avoid
 * an extra SDK control request. The returned `usage` remains the measured sample; uncertainty is
 * added only to the safety projection so it cannot accumulate across healthy turns.
 */
export function claudeCachedContextDecision(
  rawUsage,
  prompt,
  { policy = CLAUDE_CONTEXT_POLICY } = {},
) {
  const usage = normalizeClaudeContextUsage(rawUsage)
  if (!usage) return { eligible: false, reason: 'invalid_usage', usage: null }
  const incomingTokens = estimateClaudeTokens(prompt, policy)
  if (incomingTokens > policy.cachedUsageMaximumPromptTokens) {
    return { eligible: false, reason: 'large_prompt', usage, incomingTokens }
  }
  const uncertaintyTokens = Math.max(
    policy.cachedUsageMinimumUncertaintyTokens,
    Math.ceil(usage.maxTokens * policy.cachedUsageProportionalUncertainty),
  )
  if (!Number.isSafeInteger(usage.totalTokens + uncertaintyTokens)) {
    return { eligible: false, reason: 'invalid_projection', usage, incomingTokens }
  }
  const guardedUsage = { ...usage, totalTokens: usage.totalTokens + uncertaintyTokens }
  const decision = claudeContextDecision(guardedUsage, prompt, { policy })
  const eligible = decision.action === 'proceed'
    && decision.shouldCompact === false
    && decision.autoCompactionExpected === false
  return {
    eligible,
    reason: eligible ? 'safe' : 'near_limit',
    usage,
    incomingTokens,
    uncertaintyTokens,
    guardedTokens: guardedUsage.totalTokens,
    decision,
  }
}

/// Why a turn had to block on `getContextUsage()` instead of answering from the cached sample.
///
/// FR-216: this round trip is the largest latency item on the Claude lane, and the obvious lever is
/// widening `cachedUsageMaximumPromptTokens`. That number cannot be chosen from the policy constants
/// alone — it depends on which miss actually dominates real use, and a wrong guess either keeps the
/// round trip or trades it for a stale projection near the compaction threshold. So the reason is
/// named here, as a closed vocabulary, and reported once per turn.
///
/// Returns null when no round trip was needed at all.
export function claudePreflightMissReason({
  supportsContextUsage,
  authMode = '',
  resumeId = null,
  cached = null,
} = {}) {
  if (!supportsContextUsage) return authMode === 'vertex' ? 'vertex_bypass' : 'no_control'
  if (cached?.eligible) return null
  // A miss with a decision behind it reports that decision; `large_prompt` and `near_limit` are the
  // two the threshold work would act on, and they are deliberately distinguishable.
  if (cached) return cached.reason
  // No decision to report: either there was no prior sample to consult, or this is a fresh session,
  // which never consults one. Separated because only the first is a cache that could be improved.
  return resumeId ? 'no_cached_usage' : 'fresh_session'
}

/**
 * A bounded, in-memory, single-consumer cache. Taking an entry always removes it, including on an
 * identity mismatch or expiry, so concurrent/superseded turns cannot repeatedly spend one sample.
 */
export function createClaudeContextUsageCache({
  maximumEntries = 64,
  maxAgeMs = 5 * 60_000,
  now = () => Date.now(),
} = {}) {
  const entries = new Map()
  const boundedMaximumEntries = Math.max(1, Math.floor(Number(maximumEntries) || 1))
  const boundedMaxAgeMs = Math.max(0, Math.floor(Number(maxAgeMs) || 0))
  const keyFor = (sessionId) => typeof sessionId === 'string' ? sessionId.trim() : ''
  const identityFor = (contextKey) => typeof contextKey === 'string' ? contextKey.trim() : ''
  const claim = (sessionId, contextKey) => {
    const key = keyFor(sessionId)
    const identity = identityFor(contextKey)
    if (!key || !identity) return { reason: 'invalid_identity', usage: null }
    const entry = entries.get(key)
    if (!entry) return { reason: 'absent', usage: null }
    entries.delete(key)
    if (entry.contextKey !== identity) return { reason: 'identity_mismatch', usage: null }
    const ageMs = now() - entry.observedAt
    if (ageMs < 0) return { reason: 'clock_rollback', usage: null }
    if (ageMs > boundedMaxAgeMs) return { reason: 'expired', usage: null }
    return { reason: 'hit', usage: { ...entry.usage } }
  }

  return {
    claim,
    take(sessionId, contextKey) {
      return claim(sessionId, contextKey).usage
    },
    store(sessionId, contextKey, rawUsage) {
      const key = keyFor(sessionId)
      const identity = identityFor(contextKey)
      const usage = normalizeClaudeContextUsage(rawUsage)
      if (!key || !identity || !usage) return false
      entries.delete(key)
      entries.set(key, { contextKey: identity, usage, observedAt: now() })
      while (entries.size > boundedMaximumEntries) entries.delete(entries.keys().next().value)
      return true
    },
    delete(sessionId) {
      const key = keyFor(sessionId)
      return key ? entries.delete(key) : false
    },
    clear() {
      entries.clear()
    },
    get size() {
      return entries.size
    },
  }
}

export function claudeCompletionReserve(maxTokens, policy = CLAUDE_CONTEXT_POLICY) {
  return Math.max(
    policy.minimumCompletionReserve,
    Math.ceil(positiveInteger(maxTokens) * policy.proportionalCompletionReserve),
  )
}

/**
 * Decide whether a resumed provider session can safely accept the next prompt.
 *
 * `expect_compaction` is still safe: agentd watches the SDK's compaction terminal and aborts on
 * failure before the CLI can fall through to an oversized provider request. `recover_fresh` means
 * auto-compaction is not enabled (or its reported threshold says it will not run) even though the
 * input itself would cross the model limit.
 *
 * This answers for a RESUMED session only, which is the whole of its job: a fresh session never
 * reaches here, because `freshClaudePromptPlan` returns before the guard is consulted. It used to
 * take a `resumed` flag and carry a fourth `reject_prompt` outcome for the false case; every caller
 * passed true, so that outcome was unreachable and the documented state machine described a branch
 * that could not run.
 */
export function claudeContextDecision(
  rawUsage,
  prompt,
  { policy = CLAUDE_CONTEXT_POLICY } = {},
) {
  const usage = normalizeClaudeContextUsage(rawUsage)
  const incomingTokens = estimateClaudeTokens(prompt, policy)
  if (!usage) {
    return {
      action: 'unknown',
      incomingTokens,
      currentTokens: null,
      maxTokens: null,
      projectedTokens: null,
      completionReserve: null,
      shouldCompact: false,
      autoCompactionExpected: false,
    }
  }

  const completionReserve = claudeCompletionReserve(usage.maxTokens, policy)
  const inputTokens = usage.totalTokens + incomingTokens
  const projectedTokens = inputTokens + completionReserve
  const shouldCompact =
    projectedTokens >= Math.floor(usage.maxTokens * policy.preSendProjectedRatio)
  const autoCompactionExpected = usage.isAutoCompactEnabled && (
    usage.autoCompactThreshold !== null
      ? inputTokens >= usage.autoCompactThreshold
      : shouldCompact
  )

  let action = 'proceed'
  if (projectedTokens >= usage.maxTokens) {
    action = autoCompactionExpected ? 'expect_compaction' : 'recover_fresh'
  } else if (autoCompactionExpected) {
    action = 'expect_compaction'
  }

  return {
    action,
    incomingTokens,
    currentTokens: usage.totalTokens,
    maxTokens: usage.maxTokens,
    projectedTokens,
    completionReserve,
    shouldCompact,
    autoCompactionExpected,
  }
}

function safePrefix(text, maximumBytes) {
  if (maximumBytes <= 0) return ''
  const bytes = Buffer.from(text, 'utf8')
  if (bytes.length <= maximumBytes) return text
  let end = Math.min(maximumBytes, bytes.length)
  // `end` is exclusive. If it points into a UTF-8 continuation sequence, back up to that
  // sequence's leading byte so decoding cannot manufacture U+FFFD.
  while (end > 0 && (bytes[end] & 0xC0) === 0x80) end -= 1
  return bytes.subarray(0, end).toString('utf8')
}

function safeSuffix(text, maximumBytes) {
  if (maximumBytes <= 0) return ''
  const bytes = Buffer.from(text, 'utf8')
  if (bytes.length <= maximumBytes) return text
  let start = Math.max(0, bytes.length - maximumBytes)
  while (start < bytes.length && (bytes[start] & 0xC0) === 0x80) start += 1
  return bytes.subarray(start).toString('utf8')
}

function replayEntry(value) {
  if (!value || typeof value !== 'object' || typeof value.text !== 'string') return null
  return {
    role: value.role === 'assistant' ? 'Assistant' : 'User',
    text: value.text,
  }
}

function replayGroups(entries) {
  const groups = []
  for (let index = 0; index < entries.length; index += 1) {
    const entry = entries[index]
    if (entry.role === 'User') {
      groups.push({ entries: [entry] })
    } else if (groups.length) {
      groups.at(-1).entries.push(entry)
    }
    // An assistant entry without any preceding user entry is an orphan from an already-truncated
    // transcript. Count it as omitted rather than presenting it as a freestanding model claim.
  }
  return groups
}

function renderedReplayGroup(group) {
  return group.entries.map((entry) => `${entry.role}: ${entry.text}`).join('\n\n')
}

function boundedReplayGroup(group, tokenBudget, policy) {
  const rendered = renderedReplayGroup(group)
  const maximumBytes = Math.max(0, tokenBudget * policy.bytesPerEstimatedToken)
  if (Buffer.byteLength(rendered, 'utf8') <= maximumBytes) {
    return { text: rendered, truncatedMessages: 0 }
  }

  const marker = '\n\n[… middle of this older turn omitted …]\n\n'
  const first = group.entries[0]
  const last = group.entries.at(-1)
  const firstLabel = `${first.role}: `
  const lastLabel = group.entries.length > 1 ? `${last.role}: ` : ''
  const fixedBytes = Buffer.byteLength(firstLabel + marker + lastLabel, 'utf8')
  const contentBytes = maximumBytes - fixedBytes
  if (contentBytes <= 0) return { text: '', truncatedMessages: 0 }
  const headBytes = Math.ceil(contentBytes * 0.6)
  const tailBytes = contentBytes - headBytes
  return {
    text:
      firstLabel + safePrefix(first.text, headBytes)
      + marker
      + lastLabel + safeSuffix(last.text, tailBytes),
    truncatedMessages: group.entries.length,
  }
}

/**
 * Build a deterministic fresh-session replay.
 *
 * Newest complete turns win. A user message and the assistant messages that follow it are selected
 * atomically, so a tight boundary cannot retain an orphan assistant answer while dropping its
 * question. At most one boundary turn is excerpted (head + tail), then all older messages are
 * omitted. The current prompt is appended verbatim and is never truncated; an oversized current
 * prompt returns `ok: false` so the caller can show Edit Prompt instead.
 */
export function buildBoundedClaudeReplay(
  history,
  prompt,
  {
    maximumInputTokens = CLAUDE_CONTEXT_POLICY.unknownFreshInputTokens,
    maximumHistoryTokens = CLAUDE_CONTEXT_POLICY.maximumReplayHistoryTokens,
    maximumMessageTokens = CLAUDE_CONTEXT_POLICY.maximumReplayMessageTokens,
    policy = CLAUDE_CONTEXT_POLICY,
  } = {},
) {
  const currentPrompt = typeof prompt === 'string' ? prompt : String(prompt ?? '')
  const entries = (Array.isArray(history) ? history : []).map(replayEntry).filter(Boolean)
  if (!entries.length) {
    const estimatedTokens = estimateClaudeTokens(currentPrompt, policy)
    return estimatedTokens <= maximumInputTokens
      ? {
          ok: true,
          text: currentPrompt,
          estimatedTokens,
          omittedMessages: 0,
          truncatedMessages: 0,
        }
      : {
          ok: false,
          estimatedTokens,
          maximumInputTokens,
          currentPromptTokens: estimatedTokens,
          omittedMessages: 0,
          truncatedMessages: 0,
        }
  }

  const prefix = 'Here is our earlier conversation, for context:\n\n'
  const suffix = `\n\n---\n\nContinue naturally. The user now says:\n\n${currentPrompt}`
  const fixedTokens =
    estimateClaudeTokens(prefix + suffix, policy) + policy.replayOverheadTokens
  if (fixedTokens > maximumInputTokens) {
    // The wrapper is optional; the user's current message is not. When the remaining provider
    // space is narrow, drop all replay history before deciding that the message itself is too big.
    const omissionOnly =
      `[Mechanician omitted all ${entries.length} earlier message`
      + `${entries.length === 1 ? '' : 's'} to fit this recovery request safely.]\n\n`
      + currentPrompt
    if (estimateClaudeTokens(omissionOnly, policy) <= maximumInputTokens) {
      return {
        ok: true,
        text: omissionOnly,
        estimatedTokens: estimateClaudeTokens(omissionOnly, policy),
        omittedMessages: entries.length,
        truncatedMessages: 0,
      }
    }
    const currentPromptTokens = estimateClaudeTokens(currentPrompt, policy)
    if (currentPromptTokens <= maximumInputTokens) {
      return {
        ok: true,
        text: currentPrompt,
        estimatedTokens: currentPromptTokens,
        omittedMessages: entries.length,
        truncatedMessages: 0,
      }
    }
    return {
      ok: false,
      estimatedTokens: fixedTokens,
      maximumInputTokens,
      currentPromptTokens,
      omittedMessages: entries.length,
      truncatedMessages: 0,
    }
  }

  let remaining = Math.min(
    maximumHistoryTokens,
    Math.max(0, maximumInputTokens - fixedTokens),
  )
  const groups = replayGroups(entries)
  const selected = []
  for (let index = groups.length - 1; index >= 0 && remaining > 0; index -= 1) {
    const group = groups[index]
    // Keep one conservative token for the inter-turn delimiter measured immediately below.
    const entryBudget = Math.min(maximumMessageTokens, remaining) - 1
    if (entryBudget <= 0) break
    const excerpt = boundedReplayGroup(group, entryBudget, policy)
    if (!excerpt.text) break
    const renderedTokens = estimateClaudeTokens(excerpt.text + '\n\n', policy)
    if (renderedTokens > remaining) break
    selected.unshift({
      text: excerpt.text,
      count: group.entries.length,
      truncatedMessages: excerpt.truncatedMessages,
    })
    remaining -= renderedTokens
    if (excerpt.truncatedMessages > 0) break
  }

  const selectedMessageCount = () =>
    selected.reduce((total, group) => total + group.count, 0)
  const currentOmittedMessages = () => entries.length - selectedMessageCount()
  const currentTruncatedMessages = () =>
    selected.reduce((total, group) => total + group.truncatedMessages, 0)
  const omittedMessages = currentOmittedMessages()
  const omission = omittedMessages > 0
    ? `[Mechanician omitted ${omittedMessages} older message${omittedMessages === 1 ? '' : 's'} `
      + 'to keep this recovery request within the model context window.]\n\n'
    : ''
  let text = prefix + omission + selected.map((group) => group.text).join('\n\n') + suffix

  // The omission note and Unicode-boundary rounding are intentionally covered twice: if the final
  // conservative estimate crossed the cap, remove the oldest selected turn until it fits.
  while (selected.length && estimateClaudeTokens(text, policy) > maximumInputTokens) {
    selected.shift()
    const omitted = currentOmittedMessages()
    text = prefix
      + `[Mechanician omitted ${omitted} older message${omitted === 1 ? '' : 's'} `
      + 'to keep this recovery request within the model context window.]\n\n'
      + selected.map((group) => group.text).join('\n\n') + suffix
  }
  const estimatedTokens = estimateClaudeTokens(text, policy)
  if (estimatedTokens > maximumInputTokens) {
    return {
      ok: false,
      estimatedTokens,
      maximumInputTokens,
      currentPromptTokens: estimateClaudeTokens(currentPrompt, policy),
      omittedMessages: entries.length,
      truncatedMessages: currentTruncatedMessages(),
    }
  }
  return {
    ok: true,
    text,
    estimatedTokens,
    omittedMessages: currentOmittedMessages(),
    truncatedMessages: currentTruncatedMessages(),
  }
}

export function claudeCompactionFailure(message) {
  if (message?.type !== 'system' || message.subtype !== 'status') return null
  const rawError = typeof message.compact_error === 'string'
    ? message.compact_error.trim().slice(0, COMPACTION_ERROR_CHARACTERS)
    : ''
  if (message.compact_result !== 'failed' && !rawError) return null
  return {
    code: /^[a-z][a-z0-9_]{0,63}$/i.test(rawError) ? rawError : 'compaction_failed',
    message: rawError || 'Claude context compaction failed.',
  }
}

export class ClaudeCompactionRecoveryRequired extends Error {
  constructor(failure, { safeToReplay = true, reason = 'provider_compaction_failed' } = {}) {
    super('Claude could not compact this conversation before sending the next provider request.')
    this.name = 'ClaudeCompactionRecoveryRequired'
    this.failure = failure || { code: 'compaction_failed', message: 'Compaction failed.' }
    this.safeToReplay = safeToReplay === true
    this.reason = reason
  }
}

export class ClaudeInputTooLargeError extends Error {
  constructor({ estimatedTokens = null, maximumInputTokens = null } = {}) {
    super(
      'This message is too large to send safely. Shorten it or remove an attachment, then try again.',
    )
    this.name = 'ClaudeInputTooLargeError'
    // These fields intentionally match anthropicTerminalEvent's thrown-error adapter. They produce
    // a stable provider-neutral context-limit card and let the app offer Edit Prompt.
    this.error = 'prompt_preflight_limit'
    this.subtype = 'input_too_large'
    this.terminal_reason = 'prompt_too_long'
    this.error_details = this.message
    this.estimatedTokens = estimatedTokens
    this.maximumInputTokens = maximumInputTokens
  }
}

export class ClaudeCompactionUnavailableError extends Error {
  constructor() {
    super(
      'Claude could not safely reduce this conversation. Start a fresh conversation with a '
      + 'summary, or remove large context before retrying.',
    )
    this.name = 'ClaudeCompactionUnavailableError'
    this.error = 'compaction_failed'
    this.subtype = 'context_compaction_failed'
    this.terminal_reason = 'prompt_too_long'
    this.error_details = this.message
  }
}
