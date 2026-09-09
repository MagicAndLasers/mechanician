function limitLabel(rateLimitType) {
  switch (rateLimitType) {
    case 'five_hour':
      return 'five-hour'
    case 'seven_day':
      return 'weekly'
    case 'seven_day_opus':
      return 'weekly Opus'
    case 'seven_day_sonnet':
      return 'weekly Sonnet'
    case 'seven_day_overage_included':
      return 'weekly'
    case 'overage':
      return 'additional usage'
    default:
      return ''
  }
}

function resetDescription(resetsAt) {
  const timestamp = Number(resetsAt)
  if (!Number.isFinite(timestamp) || timestamp <= 0) return null

  // The SDK currently reports Unix seconds. Accept milliseconds as well so the
  // message remains useful if that representation changes; the original numeric
  // value is still carried on the wire for locale-aware presentation by the app.
  const milliseconds = timestamp < 10_000_000_000 ? timestamp * 1000 : timestamp
  const date = new Date(milliseconds)
  return Number.isNaN(date.getTime()) ? null : date.toISOString()
}

/**
 * Retain the latest Claude subscription rate-limit snapshot on a turn context.
 * Returns true only when the SDK message was a usable rate-limit event.
 */
export function captureClaudeRateLimit(turn, message) {
  if (!turn || typeof turn !== 'object' || message?.type !== 'rate_limit_event') return false
  const info = message.rate_limit_info
  if (!info || typeof info !== 'object' || typeof info.status !== 'string') return false
  turn.rateLimitInfo = { ...info }
  return true
}

/**
 * Build the terminal NDJSON error for a rejected Claude subscription limit.
 * Allowed and warning snapshots deliberately return null so unrelated turn
 * completion/error behavior is preserved.
 */
export function claudeUsageLimitErrorEvent(id, rateLimitInfo) {
  if (rateLimitInfo?.status !== 'rejected') return null

  const label = limitLabel(rateLimitInfo.rateLimitType)
  const reset = resetDescription(rateLimitInfo.resetsAt)
  const parts = [`Claude${label ? ` ${label}` : ''} usage limit reached.`]
  if (reset) parts.push(`Resets at ${reset}.`)
  else parts.push('Try again after the limit resets.')

  // A rejected subscription allowance does not by itself mean the user has no
  // credits. Make that claim only when Anthropic explicitly reports it.
  if (rateLimitInfo.overageDisabledReason === 'out_of_credits') {
    parts.push('Usage credits are exhausted.')
  }

  const event = {
    type: 'error',
    id,
    errorKind: 'usage_limit',
    message: parts.join(' '),
  }
  if (rateLimitInfo.resetsAt != null) event.resetsAt = rateLimitInfo.resetsAt
  if (rateLimitInfo.rateLimitType) event.rateLimitType = rateLimitInfo.rateLimitType
  if (rateLimitInfo.overageDisabledReason) {
    event.overageDisabledReason = rateLimitInfo.overageDisabledReason
  }
  return event
}

/**
 * The non-terminal warning snapshot, as an event worth telling someone about.
 *
 * `allowed_warning` means nothing is blocked and everything still works — and Claude quietly stops
 * doing some things, which is why this exists. Follow-up prompt suggestions are the observed one:
 * the CLI skips generating them whenever the status is anything other than `allowed`, so at 75% of
 * a weekly window they disappear with no message and no setting. That was reported as a bug twice,
 * and two investigations blamed the SDK version before the account's own usage turned out to be it.
 *
 * A warning a person never sees is the same as no warning. This is also the only notice they get
 * BEFORE being cut off outright, which is worth more than the notice after.
 *
 * Returns null for `allowed` and for `rejected` — the latter has its own terminal error, and
 * saying it twice in two shapes would be worse than saying it once.
 */
export function claudeUsageWarningEvent(id, rateLimitInfo) {
  if (rateLimitInfo?.status !== 'allowed_warning') return null

  const event = { type: 'usage_status', id, status: 'allowed_warning' }
  if (rateLimitInfo.rateLimitType) {
    event.rateLimitType = rateLimitInfo.rateLimitType
    event.limitLabel = limitLabel(rateLimitInfo.rateLimitType)
  }
  if (Number.isFinite(Number(rateLimitInfo.utilization))) {
    event.utilization = Number(rateLimitInfo.utilization)
  }
  if (Number.isFinite(Number(rateLimitInfo.surpassedThreshold))) {
    event.surpassedThreshold = Number(rateLimitInfo.surpassedThreshold)
  }
  if (rateLimitInfo.resetsAt != null) event.resetsAt = rateLimitInfo.resetsAt
  if (typeof rateLimitInfo.isUsingOverage === 'boolean') {
    event.isUsingOverage = rateLimitInfo.isUsingOverage
  }
  return event
}
