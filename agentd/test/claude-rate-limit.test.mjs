import test from 'node:test'
import assert from 'node:assert/strict'

import {
  captureClaudeRateLimit,
  claudeUsageLimitErrorEvent,
} from '../src/claude-rate-limit.mjs'

test('captures a defensive copy of the latest SDK rate-limit snapshot', () => {
  const turn = {}
  const info = {
    status: 'rejected',
    resetsAt: 1_784_259_600,
    rateLimitType: 'seven_day_opus',
    overageDisabledReason: 'member_level_disabled',
  }

  assert.equal(captureClaudeRateLimit(turn, {
    type: 'rate_limit_event',
    rate_limit_info: info,
  }), true)
  assert.deepEqual(turn.rateLimitInfo, info)
  assert.notEqual(turn.rateLimitInfo, info)

  info.status = 'allowed'
  assert.equal(turn.rateLimitInfo.status, 'rejected')
})

test('ignores unrelated and malformed SDK messages', () => {
  const turn = { rateLimitInfo: { status: 'allowed' } }

  assert.equal(captureClaudeRateLimit(turn, { type: 'assistant' }), false)
  assert.equal(captureClaudeRateLimit(turn, {
    type: 'rate_limit_event',
    rate_limit_info: {},
  }), false)
  assert.deepEqual(turn.rateLimitInfo, { status: 'allowed' })
})

test('builds a structured weekly limit error without claiming credits are empty', () => {
  const event = claudeUsageLimitErrorEvent('turn-1', {
    status: 'rejected',
    resetsAt: 1_784_259_600,
    rateLimitType: 'seven_day_opus',
    overageDisabledReason: 'member_level_disabled',
  })

  assert.deepEqual(event, {
    type: 'error',
    id: 'turn-1',
    errorKind: 'usage_limit',
    message: 'Claude weekly Opus usage limit reached. Resets at 2026-07-17T03:40:00.000Z.',
    resetsAt: 1_784_259_600,
    rateLimitType: 'seven_day_opus',
    overageDisabledReason: 'member_level_disabled',
  })
  assert.doesNotMatch(event.message, /credit/i)
})

test('mentions exhausted credits only for Anthropic out_of_credits', () => {
  const event = claudeUsageLimitErrorEvent('turn-2', {
    status: 'rejected',
    rateLimitType: 'overage',
    overageDisabledReason: 'out_of_credits',
  })

  assert.match(event.message, /Usage credits are exhausted\./)
  assert.equal(event.overageDisabledReason, 'out_of_credits')
})

test('preserves normal completion and error handling for non-rejected snapshots', () => {
  assert.equal(claudeUsageLimitErrorEvent('turn-3', null), null)
  assert.equal(claudeUsageLimitErrorEvent('turn-3', { status: 'allowed' }), null)
  assert.equal(claudeUsageLimitErrorEvent('turn-3', { status: 'allowed_warning' }), null)
})
