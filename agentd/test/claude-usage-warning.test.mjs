import test from 'node:test'
import assert from 'node:assert/strict'

import { claudeUsageWarningEvent, claudeUsageLimitErrorEvent } from '../src/claude-rate-limit.mjs'

const warning = {
  status: 'allowed_warning',
  rateLimitType: 'seven_day',
  utilization: 0.87,
  surpassedThreshold: 0.75,
  resetsAt: 1787281200,
  isUsingOverage: false,
}

test('a warning snapshot becomes an event worth telling someone about', () => {
  const event = claudeUsageWarningEvent('turn-1', warning)
  assert.equal(event.type, 'usage_status')
  assert.equal(event.id, 'turn-1')
  assert.equal(event.status, 'allowed_warning')
  assert.equal(event.rateLimitType, 'seven_day')
  assert.equal(event.limitLabel, 'weekly')
  assert.equal(event.utilization, 0.87)
  assert.equal(event.surpassedThreshold, 0.75)
  assert.equal(event.resetsAt, 1787281200)
  assert.equal(event.isUsingOverage, false)
})

test('nothing is said when everything is allowed', () => {
  assert.equal(claudeUsageWarningEvent('t', { status: 'allowed', utilization: 0.1 }), null)
  assert.equal(claudeUsageWarningEvent('t', undefined), null)
  assert.equal(claudeUsageWarningEvent('t', {}), null)
})

// Said once, in one shape. A rejected limit already has a terminal error with its own card, and
// two notices for one fact is worse than one.
test('a rejected limit is left to its own terminal error', () => {
  const rejected = { ...warning, status: 'rejected' }
  assert.equal(claudeUsageWarningEvent('t', rejected), null)
  assert.ok(claudeUsageLimitErrorEvent('t', rejected))
  assert.equal(claudeUsageLimitErrorEvent('t', warning), null)
})

test('a snapshot with no numbers still says which limit and when', () => {
  const event = claudeUsageWarningEvent('t', { status: 'allowed_warning', rateLimitType: 'five_hour' })
  assert.equal(event.limitLabel, 'five-hour')
  assert.ok(!('utilization' in event), 'never invents a number Claude did not give')
  assert.ok(!('resetsAt' in event))
})
