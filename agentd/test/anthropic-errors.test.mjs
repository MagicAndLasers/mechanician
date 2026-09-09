import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  anthropicTerminalEvent,
  captureAnthropicTurnError,
  resetAnthropicTurnErrors,
} from '../src/anthropic-turn-errors.mjs'

test('assistant error becomes a structured Anthropic terminal failure', () => {
  const turn = {}
  captureAnthropicTurnError(turn, {
    type: 'assistant',
    error: 'billing_error',
    request_id: 'anthropic_req_1',
  }, 'anthropic_api')

  assert.deepEqual(anthropicTerminalEvent('turn-1', turn, { access: 'anthropic_api' }), {
    type: 'error',
    id: 'turn-1',
    errorKind: 'quota',
    provider: 'anthropic',
    message: 'Anthropic billing or quota limit reached.',
    access: 'anthropic_api',
    providerError: {
      code: 'billing_error',
      requestId: 'anthropic_req_1',
    },
  })
})

test('a terminal Vertex invalid_rapt result becomes a reauthentication event', () => {
  const turn = {}
  captureAnthropicTurnError(turn, {
    type: 'result',
    subtype: 'error_during_execution',
    is_error: true,
    error: 'api_error',
    terminal_reason: 'api_error',
    errors: [
      'Google Vertex request failed: {"error":"invalid_grant",'
        + '"error_description":"reauth related error (invalid_rapt)",'
        + '"error_subtype":"invalid_rapt"}',
    ],
  }, 'claude_vertex')

  const terminal = anthropicTerminalEvent('turn-rapt', turn, { access: 'claude_vertex' })
  assert.equal(terminal.type, 'error')
  assert.equal(terminal.errorKind, 'authentication')
  assert.equal(terminal.reconnectRequired, true)
  assert.equal(terminal.providerError.code, 'invalid_rapt')
  assert.match(terminal.message, /Reauthenticate with Google/)
})

test('api_retry remains nonterminal and does not seed a later failure', () => {
  const turn = {}
  assert.equal(captureAnthropicTurnError(turn, {
    type: 'system',
    subtype: 'api_retry',
    attempt: 1,
    max_retries: 3,
    retry_delay_ms: 250,
    error_status: 503,
    error: 'overloaded',
  }, 'anthropic_api'), null)
  assert.equal(turn.anthropicFailure, undefined)
  assert.deepEqual(anthropicTerminalEvent('turn-2', turn, { access: 'anthropic_api' }), {
    type: 'done', id: 'turn-2',
  })
})

test('result is_error is terminal even when the subtype is success', () => {
  const turn = {}
  captureAnthropicTurnError(turn, {
    type: 'result',
    subtype: 'success',
    is_error: true,
    api_error_status: 503,
    result: 'Anthropic was overloaded while finalizing the response.',
  }, 'claude_subscription')

  const terminal = anthropicTerminalEvent('turn-3', turn, { access: 'claude_subscription' })
  assert.equal(terminal.type, 'error')
  assert.equal(terminal.errorKind, 'server')
  assert.equal(terminal.access, 'claude_subscription')
  assert.equal(terminal.providerError.status, 503)
})

test('non-error result does not fabricate a provider failure', () => {
  const turn = {}
  assert.equal(captureAnthropicTurnError(turn, {
    type: 'result', subtype: 'success', is_error: false, result: 'Recovered.',
  }, 'anthropic_api'), null)

  assert.deepEqual(anthropicTerminalEvent('turn-4', turn, { access: 'anthropic_api' }), {
    type: 'done', id: 'turn-4',
  })
})

test('reset clears stale provider and subscription-limit candidates before replay', () => {
  const turn = {
    rateLimitInfo: { status: 'rejected', rateLimitType: 'seven_day' },
  }
  captureAnthropicTurnError(turn, {
    type: 'assistant', error: 'authentication_failed',
  }, 'claude_subscription')

  resetAnthropicTurnErrors(turn)

  assert.equal(turn.rateLimitInfo, null)
  assert.equal(turn.anthropicFailure, null)
  assert.deepEqual(anthropicTerminalEvent('turn-5', turn, { access: 'claude_subscription' }), {
    type: 'done', id: 'turn-5',
  })
})

test('Claude usage-limit rejection wins over an ordinary provider candidate', () => {
  const turn = {
    rateLimitInfo: {
      status: 'rejected',
      resetsAt: 1_784_259_600,
      rateLimitType: 'seven_day_opus',
      overageDisabledReason: 'out_of_credits',
    },
  }
  captureAnthropicTurnError(turn, {
    type: 'assistant', error: 'rate_limit', request_id: 'anthropic_req_limit',
  }, 'claude_subscription')

  const terminal = anthropicTerminalEvent('turn-6', turn, { access: 'claude_subscription' })
  assert.equal(terminal.errorKind, 'usage_limit')
  assert.equal(terminal.provider, undefined)
  assert.match(terminal.message, /weekly Opus usage limit/)
})

test('interrupt stays a clean terminal even when an error candidate exists', () => {
  const turn = {}
  captureAnthropicTurnError(turn, {
    type: 'assistant', error: 'server_error',
  }, 'anthropic_api')

  assert.deepEqual(anthropicTerminalEvent('turn-7', turn, {
    access: 'anthropic_api',
    error: new Error('aborted'),
    interrupted: true,
  }), {
    type: 'done', id: 'turn-7', interrupted: true,
  })
})

test('unstructured thrown errors still use the provider-neutral wire shape', () => {
  const terminal = anthropicTerminalEvent('turn-8', {}, {
    access: 'anthropic_api',
    error: new Error('socket connection reset with token=super-secret-value'),
  })

  assert.equal(terminal.type, 'error')
  assert.equal(terminal.errorKind, 'network')
  assert.equal(terminal.provider, 'anthropic')
  assert.equal(terminal.access, 'anthropic_api')
  assert.doesNotMatch(terminal.message, /super-secret-value/)
})
