import test from 'node:test'
import assert from 'node:assert/strict'

import { claudeUsageLimitErrorEvent } from '../src/claude-rate-limit.mjs'
import {
  PROVIDER_ERROR_MAX_BYTES,
  normalizeAnthropicError,
  normalizeCodexError,
  normalizeOpenAIError,
  normalizeProviderError,
} from '../src/provider-errors.mjs'

test('OpenAI request throttling preserves independent rate-limit dimensions', () => {
  const error = normalizeOpenAIError({
    status: 429,
    headers: {
      'X-Request-ID': 'req_rate_123',
      'X-Client-Request-ID': 'client_req_123',
      'Retry-After': '2.5',
      'X-RateLimit-Limit-Requests': '500',
      'X-RateLimit-Remaining-Requests': '12',
      'X-RateLimit-Reset-Requests': '750ms',
      'X-RateLimit-Limit-Tokens': '30000',
      'X-RateLimit-Remaining-Tokens': '24000',
      'X-RateLimit-Reset-Tokens': '1m2s',
      'X-RateLimit-Limit-Project-Tokens': '8',
      'X-RateLimit-Remaining-Project-Tokens': '3',
      'X-RateLimit-Reset-Project-Tokens': '1h',
    },
    body: {
      error: {
        message: 'Rate limit reached for requests.',
        type: 'requests',
        code: 'rate_limit_exceeded',
        param: 'model',
      },
    },
  }, { access: 'openai_api', authMode: 'ignored' })

  assert.deepEqual(error, {
    errorKind: 'rate_limit',
    provider: 'openai',
    message: 'Rate limit reached for requests.',
    access: 'openai_api',
    providerError: {
      code: 'rate_limit_exceeded',
      providerType: 'requests',
      param: 'model',
      status: 429,
      requestId: 'req_rate_123',
      clientRequestId: 'client_req_123',
      retryAfterSeconds: 2.5,
      rateLimits: {
        requests: { limit: 500, remaining: 12, resetAfterSeconds: 0.75 },
        tokens: { limit: 30000, remaining: 24000, resetAfterSeconds: 62 },
        project: { limit: 8, remaining: 3, resetAfterSeconds: 3600 },
      },
    },
  })
  assert.equal(Object.hasOwn(error, 'type'), false)
  assert.equal(Object.hasOwn(error, 'kind'), false)
  assert.equal(Object.hasOwn(error, 'authMode'), false)
})

test('wire spread cannot overwrite the terminal NDJSON event type', () => {
  const normalized = normalizeOpenAIError({
    status: 400,
    body: { error: { message: 'Bad request.', type: 'invalid_request_error' } },
  })
  const event = { type: 'error', id: 'turn-1', ...normalized }

  assert.equal(event.type, 'error')
  assert.equal(event.errorKind, 'invalid_request')
  assert.equal(event.providerError.providerType, 'invalid_request_error')
})

test('OpenAI insufficient_quota remains distinct from request-rate HTTP 429', () => {
  const error = normalizeOpenAIError({
    status: 429,
    body: {
      error: {
        message: 'You exceeded your current quota.',
        type: 'insufficient_quota',
        code: 'insufficient_quota',
      },
    },
  })

  assert.equal(error.errorKind, 'quota')
  assert.equal(error.providerError.status, 429)
  assert.equal(error.providerError.code, 'insufficient_quota')
})

test('OpenAI SSE context and output limits remain distinct and retain only whitelisted metadata', () => {
  const failed = normalizeOpenAIError({
    event: {
      type: 'response.failed',
      response: {
        error: {
          message: 'Input exceeds the model context window.',
          type: 'invalid_request_error',
          code: 'context_length_exceeded',
          param: 'input',
          details: { prompt: 'private user content' },
        },
      },
    },
  })
  const incomplete = normalizeOpenAIError({
    type: 'response.incomplete',
    response: { incomplete_details: { reason: 'max_output_tokens', private: 'omit me' } },
  })

  assert.equal(failed.errorKind, 'context_limit')
  assert.equal(failed.providerError.code, 'context_length_exceeded')
  assert.equal(failed.providerError.param, 'input')
  assert.equal(Object.hasOwn(failed, 'detail'), false)
  assert.equal(Object.hasOwn(failed.providerError, 'details'), false)
  assert.equal(incomplete.errorKind, 'output_limit')
  assert.equal(incomplete.message, 'The response reached its output token limit.')
  assert.doesNotMatch(JSON.stringify([failed, incomplete]), /private user content|omit me/)
})

test('OpenAI 5xx timeout is server, bare 403 is conservative, and network has no response', () => {
  assert.equal(normalizeOpenAIError({
    status: 504,
    body: 'Gateway Timeout',
  }).errorKind, 'server')
  assert.equal(normalizeOpenAIError({
    status: 403,
    body: 'Request forbidden by policy.',
  }).errorKind, 'unknown')
  assert.equal(normalizeOpenAIError({
    error: new TypeError('fetch failed: ECONNRESET'),
    headers: { 'x-client-request-id': 'client_no_response' },
  }).errorKind, 'network')
  assert.equal(normalizeOpenAIError({
    error: new TypeError('fetch failed: ECONNRESET'),
    headers: { 'x-client-request-id': 'client_no_response' },
  }).providerError.clientRequestId, 'client_no_response')
})

test('Retry-After HTTP dates become canonical absolute timestamps', () => {
  const error = normalizeOpenAIError({
    status: 429,
    headers: { 'retry-after': 'Fri, 17 Jul 2026 03:40:00 GMT' },
    body: { error: { message: 'Too many requests.', code: 'rate_limit_exceeded' } },
  })

  assert.equal(error.providerError.resetsAt, '2026-07-17T03:40:00.000Z')
  assert.equal(Object.hasOwn(error.providerError, 'retryAfterSeconds'), false)
})

test('all provider-controlled strings are bounded and scrubbed of credential material', () => {
  const huge = '💥'.repeat(10000)
  const error = normalizeCodexError({
    code: 'sk-proj-abcdefghijklmnop',
    message: `Bearer abcdefghijklmnop api_key=sk-abcdefghijklmnop ${huge}`,
    data: {
      requestId: 'token=super-secret-token',
      client_secret: 'must-not-survive',
      raw: 'Authorization: Bearer another-secret',
      userPrompt: 'private user content',
      codexErrorInfo: { type: 'networkError' },
    },
  }, { access: 'codex_subscription', authMode: 'must-not-emit', authLane: 'must-not-emit' })
  const serialized = JSON.stringify(error)

  assert.equal(error.errorKind, 'network')
  assert.ok(Buffer.byteLength(serialized, 'utf8') <= PROVIDER_ERROR_MAX_BYTES)
  assert.doesNotMatch(serialized, /abcdefghijklmnop|super-secret-token|must-not-survive|another-secret|private user content/)
  assert.doesNotMatch(serialized, /authMode|authLane|client_secret|userPrompt|\"data\"/)
  assert.match(serialized, /redacted/)
  assert.doesNotMatch(serialized, /\]\]/)
  assert.doesNotThrow(() => JSON.parse(serialized))
})

test('Codex JSON-RPC errors preserve only canonical whitelisted fields', () => {
  const error = normalizeCodexError({
    error: {
      code: -32001,
      message: 'Login required before starting a turn.',
      data: {
        status: 401,
        type: 'authentication_error',
        requestId: 'codex_req_1',
        refresh_token: 'must-not-leak',
        privateTranscript: 'must-not-persist',
      },
    },
  }, { access: 'codex_subscription' })

  assert.deepEqual(error, {
    errorKind: 'authentication',
    provider: 'codex',
    message: 'Login required before starting a turn.',
    access: 'codex_subscription',
    providerError: {
      code: -32001,
      providerType: 'authentication_error',
      status: 401,
      requestId: 'codex_req_1',
    },
  })
  assert.doesNotMatch(JSON.stringify(error), /must-not-leak|must-not-persist/)
})

test('revoked Codex refresh credentials require interactive reconnect', () => {
  const revoked = normalizeCodexError({
    message: 'Your access token could not be refreshed because your refresh token was revoked. Please log out and sign in again.',
  }, { access: 'codex_subscription' })
  const invalidated = normalizeCodexError({
    code: 'refresh_token_invalidated',
    message: 'Sign in again.',
  }, { access: 'codex_subscription' })
  const ordinary = normalizeCodexError({
    status: 401,
    message: 'Login required before starting a turn.',
  }, { access: 'codex_subscription' })

  assert.equal(revoked.errorKind, 'authentication')
  assert.equal(revoked.reconnectRequired, true)
  assert.equal(invalidated.errorKind, 'authentication')
  assert.equal(invalidated.reconnectRequired, true)
  assert.equal(Object.hasOwn(ordinary, 'reconnectRequired'), false)
})

test('Codex standard JSON-RPC failures distinguish caller and server faults', () => {
  assert.equal(normalizeCodexError({
    code: -32602,
    message: 'Invalid params.',
    data: { field: 'model' },
  }).errorKind, 'invalid_request')
  assert.equal(normalizeCodexError({
    code: -32603,
    message: 'Internal error.',
  }).errorKind, 'server')
})

test('Codex App Server lifecycle failures retain their safe type and classify usefully', () => {
  const timeout = normalizeCodexError({
    message: 'Codex App Server timed out waiting for turn/start.',
    providerType: 'app_server_timeout',
    code: 'app_server_timeout',
    method: 'turn/start',
  })
  const exit = normalizeCodexError({
    message: 'Codex App Server exited (17).',
    providerType: 'app_server_exit',
    code: 'app_server_exit',
    exitCode: 17,
  })

  assert.equal(timeout.errorKind, 'network')
  assert.equal(timeout.providerError.providerType, 'app_server_timeout')
  assert.equal(exit.errorKind, 'server')
  assert.equal(exit.providerError.providerType, 'app_server_exit')
  assert.equal(Object.hasOwn(exit.providerError, 'exitCode'), false)
})

test('Codex semantic error tags cover App Server variants without retaining willRetry', () => {
  const cases = [
    ['contextWindowExceeded', 'context_limit'],
    ['sessionBudgetExceeded', 'quota'],
    ['usageLimitExceeded', 'quota'],
    ['serverOverloaded', 'server'],
    ['unauthorized', 'authentication'],
    ['badRequest', 'invalid_request'],
    ['networkError', 'network'],
    ['streamDisconnected', 'network'],
  ]
  for (const [tag, expected] of cases) {
    const error = normalizeCodexError({
      message: 'Codex turn failed.',
      codexErrorInfo: { type: tag, willRetry: true, resetsAt: 1_784_259_600 },
      willRetry: true,
    })
    assert.equal(error.errorKind, expected, tag)
    assert.equal(error.providerError.codexErrorTag, tag)
    assert.equal(Object.hasOwn(error.providerError, 'willRetry'), false)
    assert.equal(error.providerError.resetsAt, '2026-07-17T03:40:00.000Z')
  }
})

test('Codex model-capacity failures preserve the exact provider message without invented metadata', () => {
  const message = 'Selected model is at capacity. Please try a different model.'
  for (const tag of ['serverOverloaded', 'server_overloaded']) {
    const error = normalizeCodexError({
      message,
      codexErrorInfo: tag,
      willRetry: false,
    }, { access: 'codex_subscription' })

    assert.equal(error.errorKind, 'server', tag)
    assert.equal(error.provider, 'codex', tag)
    assert.equal(error.access, 'codex_subscription', tag)
    assert.equal(error.message, message, tag)
    assert.equal(error.providerError.codexErrorTag, tag)
    assert.equal(Object.hasOwn(error, 'willRetry'), false, tag)
    assert.equal(Object.hasOwn(error.providerError, 'willRetry'), false, tag)
    assert.equal(Object.hasOwn(error.providerError, 'requestId'), false, tag)
  }
})

test('Codex semantic tags can be object variant keys', () => {
  const error = normalizeCodexError({
    message: 'Stream stopped.',
    data: { codexErrorInfo: { responseStreamFailed: { reason: 'private' } } },
  })

  assert.equal(error.errorKind, 'network')
  assert.equal(error.providerError.codexErrorTag, 'responseStreamFailed')
  assert.doesNotMatch(JSON.stringify(error), /private/)
})

test('Codex App Server object variants retain HTTP status without arbitrary payload', () => {
  const server = normalizeCodexError({
    message: 'Connection failed.',
    codexErrorInfo: { httpConnectionFailed: { httpStatusCode: 503, private: 'omit' } },
  })
  const stream = normalizeCodexError({
    message: 'Stream disconnected.',
    codexErrorInfo: { responseStreamDisconnected: { httpStatusCode: null } },
  })
  const steer = normalizeCodexError({
    message: 'The current turn cannot be steered.',
    codexErrorInfo: { activeTurnNotSteerable: { turnKind: 'review' } },
  })
  const limited = normalizeCodexError({
    message: 'Response retry limit reached.',
    codexErrorInfo: { responseTooManyFailedAttempts: { httpStatusCode: 429 } },
  })
  const unauthorizedConnection = normalizeCodexError({
    message: 'Connection failed.',
    codexErrorInfo: { httpConnectionFailed: { httpStatusCode: 401 } },
  })

  assert.equal(server.errorKind, 'server')
  assert.equal(server.providerError.status, 503)
  assert.equal(stream.errorKind, 'network')
  assert.equal(steer.errorKind, 'invalid_request')
  assert.equal(limited.errorKind, 'rate_limit')
  assert.equal(unauthorizedConnection.errorKind, 'authentication')
  assert.doesNotMatch(JSON.stringify([server, stream, steer, limited, unauthorizedConnection]), /private|turnKind/)
})

test('Codex subscription endpoint 404 becomes a safe server failure', () => {
  const expectedMessage =
    'The Codex subscription connection received HTTP 404 for an internal service request. Your prompt was not rejected. Retry in a moment; if it persists, check OpenAI status or Codex Help.'
  const cases = [
    'unexpected status 404 Not Found: Unknown error, url: https://chatgpt.com/backend-api/codex/models?client_version=0.148.0, cf-ray: private-edge-id',
    'failed to connect to websocket: HTTP error: 404 Not Found, url: wss://chatgpt.com/backend-api/codex/responses, cf-ray: private-edge-id',
  ]

  for (const message of cases) {
    const error = normalizeCodexError({ message }, { access: 'codex_subscription' })
    assert.equal(error.errorKind, 'server')
    assert.equal(error.message, expectedMessage)
    assert.equal(error.providerError.status, 404)
    assert.equal(error.providerError.diagnosticCode, 'codex_subscription_backend_404')
    assert.doesNotMatch(JSON.stringify(error), /chatgpt\.com|cf-ray|private-edge-id/)
  }

  const unrelated = normalizeCodexError({
    message: 'unexpected status 404 Not Found, url: https://example.com/backend-api/codex/responses',
  }, { access: 'codex_subscription' })
  assert.equal(unrelated.errorKind, 'unknown')
  assert.equal(Object.hasOwn(unrelated, 'providerError'), false)
})

test('Anthropic assistant errors retain enum and request id in wire-safe fields', () => {
  const error = normalizeAnthropicError({
    type: 'assistant',
    error: 'billing_error',
    request_id: 'anthropic_req_1',
  }, { access: 'anthropic_api' })

  assert.deepEqual(error, {
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

test('Claude and Vertex authentication failures require reconnect while an API-key failure does not', () => {
  const subscription = normalizeAnthropicError({
    error: 'authentication_failed',
    error_details: 'Failed to authenticate. API Error: 401 Invalid authentication credentials',
    error_status: 401,
  }, { access: 'claude_subscription' })
  const vertex = normalizeAnthropicError({
    error: 'authentication_failed',
    error_details: 'Application Default Credentials are invalid',
    error_status: 401,
  }, { access: 'claude_vertex' })
  const apiKey = normalizeAnthropicError({
    error: 'authentication_failed',
    error_details: 'Invalid API key',
    error_status: 401,
  }, { access: 'anthropic_api' })

  assert.equal(subscription.errorKind, 'authentication')
  assert.equal(subscription.reconnectRequired, true)
  assert.equal(vertex.errorKind, 'authentication')
  assert.equal(vertex.reconnectRequired, true)
  assert.equal(Object.hasOwn(apiKey, 'reconnectRequired'), false)
})

test('Vertex invalid_rapt nested in an SDK api_error requires interactive Google reauthentication', () => {
  const payload = 'Google Vertex request failed: '
    + '{"error":"invalid_grant","error_description":"reauth related error (invalid_rapt)",'
    + '"error_subtype":"invalid_rapt"}'
  for (const input of [
    {
      type: 'assistant',
      error: 'api_error',
      error_details: payload,
    },
    {
      type: 'result',
      subtype: 'error_during_execution',
      is_error: true,
      errors: [payload],
      terminal_reason: 'model_error',
    },
  ]) {
    const failure = normalizeAnthropicError(input, { access: 'claude_vertex' })
    assert.equal(failure.errorKind, 'authentication')
    assert.equal(failure.reconnectRequired, true)
    assert.equal(failure.providerError.code, 'invalid_rapt')
    assert.equal(failure.providerError.providerType, 'credential_reauth_required')
    assert.match(failure.message, /Reauthenticate with Google/)
    assert.doesNotMatch(failure.message, /invalid_grant|invalid_rapt/)
  }
})

test('a generic Vertex invalid_grant also directs the user to Google reauthentication', () => {
  const failure = normalizeAnthropicError({
    type: 'result',
    subtype: 'api_error',
    is_error: true,
    result: 'Google Vertex request failed: {"error":"invalid_grant"}',
  }, { access: 'claude_vertex' })

  assert.equal(failure.errorKind, 'authentication')
  assert.equal(failure.reconnectRequired, true)
  assert.equal(failure.providerError.code, 'invalid_grant')
  assert.equal(failure.providerError.providerType, 'credential_revoked')
  assert.match(failure.message, /expired or was revoked/)
})

test('an exhausted OAuth refresh is authentication even when the provider tags it api_error', () => {
  // The Claude Agent SDK reports a dead refresh token in prose under a generic api_error code. It
  // must still mark the account disconnected and offer Reconnect instead of a bare Retry.
  const expired = normalizeAnthropicError({
    type: 'result',
    subtype: 'api_error',
    error: 'api_error',
    error_details: 'Failed to authenticate: OAuth session expired and could not be refreshed',
  }, { access: 'claude_subscription' })

  assert.equal(expired.errorKind, 'authentication')
  assert.equal(expired.reconnectRequired, true)

  for (const message of [
    'Your credentials could not be refreshed. Please sign in again.',
    'Re-authentication required for this account.',
    'OAuth session expired',
  ]) {
    assert.equal(
      normalizeAnthropicError({ error: 'api_error', error_details: message },
        { access: 'claude_subscription' }).errorKind,
      'authentication',
      message)
  }
})

test('an expired conversation session is not mistaken for an expired sign-in', () => {
  // "session expired" without a credential noun is a resume fault; misclassifying it would strand
  // the user on a Reconnect button that cannot fix anything.
  const resume = normalizeAnthropicError({
    error: 'api_error',
    error_details: 'The conversation session expired; start a new session to continue.',
  }, { access: 'claude_subscription' })

  assert.notEqual(resume.errorKind, 'authentication')
  assert.equal(Object.hasOwn(resume, 'reconnectRequired'), false)
})

test('Anthropic model_not_found is model access but terminal model_error is not', () => {
  assert.equal(normalizeAnthropicError({
    type: 'assistant', error: 'model_not_found',
  }).errorKind, 'model_access')
  assert.equal(normalizeAnthropicError({
    type: 'result',
    subtype: 'error_during_execution',
    terminal_reason: 'model_error',
    errors: ['Model execution ended.'],
  }).errorKind, 'unknown')
})

test('Anthropic api_retry without an HTTP response is network with seconds', () => {
  const error = normalizeAnthropicError({
    type: 'system',
    subtype: 'api_retry',
    retry_delay_ms: 1250,
    error_status: null,
    error: 'unknown',
  })

  assert.equal(error.errorKind, 'network')
  assert.equal(error.providerError.retryAfterSeconds, 1.25)
  assert.equal(error.providerError.code, 'unknown')
})

test('Anthropic result errors retain terminal metadata without arbitrary diagnostics', () => {
  const error = normalizeAnthropicError({
    type: 'result',
    subtype: 'error_during_execution',
    is_error: true,
    terminal_reason: 'prompt_too_long',
    errors: ['Prompt is too long for this model.'],
    permission_denials: [{ private: 'omit' }],
  })

  assert.equal(error.errorKind, 'context_limit')
  assert.equal(error.message, 'Prompt is too long for this model.')
  assert.equal(error.providerError.code, 'error_during_execution')
  assert.equal(error.providerError.terminalReason, 'prompt_too_long')
  assert.doesNotMatch(JSON.stringify(error), /permission_denials|omit/)
})

test('Anthropic output limits remain distinct from input context overflow', () => {
  const assistant = normalizeAnthropicError({
    type: 'assistant',
    error: 'max_output_tokens',
    request_id: 'anthropic_output_1',
  })
  const result = normalizeAnthropicError({
    type: 'result',
    subtype: 'error_during_execution',
    is_error: true,
    terminal_reason: 'max_output_tokens',
    errors: ['Response reached the output token limit.'],
  })
  const context = normalizeAnthropicError({
    type: 'result',
    subtype: 'error_during_execution',
    is_error: true,
    terminal_reason: 'prompt_too_long',
    errors: ['Prompt exceeds the context window.'],
  })

  assert.equal(assistant.errorKind, 'output_limit')
  assert.equal(assistant.providerError.code, 'max_output_tokens')
  assert.equal(result.errorKind, 'output_limit')
  assert.equal(result.providerError.terminalReason, 'max_output_tokens')
  assert.equal(context.errorKind, 'context_limit')
})

test('Anthropic success subtype with is_error true uses the result diagnostic', () => {
  const error = normalizeAnthropicError({
    type: 'result',
    subtype: 'success',
    is_error: true,
    result: 'Server overloaded while finalizing the response.',
  })

  assert.equal(error.errorKind, 'server')
  assert.equal(error.message, 'Server overloaded while finalizing the response.')
  assert.equal(error.providerError.providerType, 'success')
  assert.equal(normalizeAnthropicError({
    type: 'result', subtype: 'success', is_error: false, result: 'Normal answer.',
  }), null)
})

test('current Claude subscription usage-limit event remains untouched', () => {
  const info = {
    status: 'rejected',
    resetsAt: 1_784_259_600,
    rateLimitType: 'seven_day_opus',
    overageDisabledReason: 'out_of_credits',
  }
  assert.equal(normalizeAnthropicError({
    type: 'rate_limit_event', rate_limit_info: info,
  }), null)
  assert.deepEqual(claudeUsageLimitErrorEvent('turn-limit', info), {
    type: 'error',
    id: 'turn-limit',
    errorKind: 'usage_limit',
    message: 'Claude weekly Opus usage limit reached. Resets at 2026-07-17T03:40:00.000Z. Usage credits are exhausted.',
    resetsAt: 1_784_259_600,
    rateLimitType: 'seven_day_opus',
    overageDisabledReason: 'out_of_credits',
  })
})

test('malformed scalar types are omitted instead of weakening the wire schema', () => {
  const error = normalizeOpenAIError({
    status: true,
    body: { error: { message: 'Malformed.', code: false, type: true, param: {} } },
    resetsAt: true,
  }, { access: 'openai_api', authLane: 'ignored' })

  assert.deepEqual(error, {
    errorKind: 'invalid_request',
    provider: 'openai',
    message: 'Malformed.',
    access: 'openai_api',
  })
})

test('generic dispatcher is bounded and emits the canonical contract', () => {
  const error = normalizeProviderError('local', {
    message: `Provider failure token=top-secret ${'x'.repeat(20000)}`,
    private: 'must not persist',
  }, { access: 'local_lane' })
  const serialized = JSON.stringify(error)

  assert.equal(error.errorKind, 'unknown')
  assert.equal(error.provider, 'local')
  assert.equal(error.access, 'local_lane')
  assert.equal(Object.hasOwn(error, 'detail'), false)
  assert.doesNotMatch(serialized, /top-secret|must not persist/)
  assert.ok(Buffer.byteLength(serialized, 'utf8') <= PROVIDER_ERROR_MAX_BYTES)
})
