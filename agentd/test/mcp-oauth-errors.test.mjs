import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  InvalidClientMetadataError,
  ServerError,
  TemporarilyUnavailableError,
} from '@modelcontextprotocol/sdk/server/auth/errors.js'

import {
  McpOAuthFailure,
  createMcpOAuthAttempt,
  isSameOriginBrowserFallbackEligible,
  mcpOAuthFailurePayload,
  normalizeMcpOAuthFailure,
} from '../src/mcp-oauth-errors.mjs'

// The same-origin browser fallback exists only for hosts a signed tenant profile declares; the app
// forwards that suffix to agentd. Declare one for the tests that exercise the fallback, and see
// `no declared host suffix disables the same-origin fallback entirely` for the public-app default.
process.env.MECHANICIAN_MCP_SAME_ORIGIN_HOST_SUFFIX = '.mcp.example.com'

const acme = {
  url: 'https://confluence.mcp.example.com/mcp',
}

test('missing dynamic registration has an exact actionable public failure', () => {
  const failure = normalizeMcpOAuthFailure(
    new Error('Incompatible auth server: does not support dynamic client registration'),
  )
  assert.deepEqual(mcpOAuthFailurePayload(failure), {
    message: 'Incompatible auth server: does not support dynamic client registration',
    errorStage: 'client_registration',
    errorKind: 'protocol',
    suggestedAction: 'manual_credentials',
    retryable: false,
    errorCode: 'dynamic_client_registration_unsupported',
  })
})

test('registration OAuth errors retain status and only a sanitized structured description', async () => {
  const attempt = createMcpOAuthAttempt(async () => new Response('{}', { status: 400 }))
  await attempt.fetch('https://login.example.test/register?server-secret=must-not-escape', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
  })
  const opaque = 'a'.repeat(64)
  const failure = normalizeMcpOAuthFailure(
    new InvalidClientMetadataError(
      `Redirect rejected. client_secret=top-secret Bearer bearer-secret-value `
      + `callback=https://localhost/cb?code=authorization-secret opaque=${opaque}`,
    ),
    { attempt },
  )
  const payload = mcpOAuthFailurePayload(failure)

  assert.equal(payload.errorStage, 'client_registration')
  assert.equal(payload.errorKind, 'oauth')
  assert.equal(payload.httpStatus, 400)
  assert.equal(payload.oauthError, 'invalid_client_metadata')
  assert.match(payload.oauthDescription, /\[redacted\]/)
  assert.match(payload.oauthDescription, /\[redacted-authorization\]/)
  assert.match(payload.oauthDescription, /\[redacted-url\]/)
  assert.match(payload.oauthDescription, /\[redacted-opaque-value\]/)
  const serialized = JSON.stringify(payload)
  assert.doesNotMatch(serialized, /top-secret|bearer-secret-value|authorization-secret/)
  assert.doesNotMatch(serialized, /login\.example|server-secret/)
  assert.doesNotMatch(serialized, new RegExp(opaque))
})

test('invalid OAuth error bodies are never copied from the SDK ServerError', async () => {
  const attempt = createMcpOAuthAttempt(async () => new Response('<html>private body</html>', {
    status: 502,
  }))
  await attempt.fetch('https://login.example.test/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  })
  const failure = normalizeMcpOAuthFailure(
    new ServerError(
      'HTTP 502: Invalid OAuth error response: parse failed. '
      + 'Raw body: <html>private body with access_token=do-not-leak</html>',
    ),
    { attempt },
  )
  const payload = mcpOAuthFailurePayload(failure)

  assert.equal(payload.errorStage, 'token_exchange')
  assert.equal(payload.errorKind, 'invalid_response')
  assert.equal(payload.httpStatus, 502)
  assert.equal(payload.oauthError, undefined)
  assert.equal(payload.oauthDescription, undefined)
  assert.doesNotMatch(JSON.stringify(payload), /private body|do-not-leak|raw body/i)
})

test('structured OAuth errors outrank timeout prose in their description', async () => {
  const attempt = createMcpOAuthAttempt(async () => new Response('{}', { status: 503 }))
  await attempt.fetch('https://login.example.test/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  })
  const failure = normalizeMcpOAuthFailure(
    new TemporarilyUnavailableError('The upstream request timed out; retry later.'),
    { attempt },
  )

  assert.equal(failure.kind, 'oauth')
  assert.equal(failure.oauthError, 'temporarily_unavailable')
  assert.equal(failure.status, 503)
  assert.equal(failure.retryable, true)
})

test('upstream cancellation prose is not mistaken for a local user cancellation', () => {
  const failure = normalizeMcpOAuthFailure(
    new Error('The server cancelled its backend request while processing registration.'),
    { stage: 'client_registration' },
  )
  assert.equal(failure.kind, 'unknown')

  const local = normalizeMcpOAuthFailure(new Error('cancelled'), {
    stage: 'authorization_callback',
  })
  assert.equal(local.kind, 'cancelled')
  assert.equal(local.code, 'MCP_OAUTH_CANCELLED')
  assert.equal(mcpOAuthFailurePayload(local).suggestedAction, 'none')
})

test('provider-owned OAuth messages map only through exact safe forms', () => {
  const denied = normalizeMcpOAuthFailure(
    new Error('authorization denied: access_denied'),
  )
  assert.equal(denied.stage, 'authorization_callback')
  assert.equal(denied.kind, 'oauth')
  assert.equal(denied.oauthError, 'access_denied')
  assert.equal(denied.message, 'Authorization was declined.')

  for (const message of [
    'authorization timed out',
    'Timed out waiting for the sign-in to finish. '
      + 'If you completed it on claude.ai, click Check Status.',
  ]) {
    const timedOut = normalizeMcpOAuthFailure(new Error(message))
    assert.equal(timedOut.kind, 'timeout')
    assert.equal(timedOut.message, 'Authentication timed out.')
  }
})

test('DNS failures get a VPN hint only for an explicitly VPN-scoped server', async () => {
  const cause = new Error('getaddrinfo failed for private-name.example')
  cause.code = 'ENOTFOUND'
  const attempt = createMcpOAuthAttempt(async () => {
    throw new TypeError('fetch failed', { cause })
  })
  let rawFailure
  try {
    await attempt.fetch('https://secret-host.example/.well-known/oauth-authorization-server')
  } catch (error) {
    rawFailure = error
  }
  assert.equal(rawFailure instanceof McpOAuthFailure, false)
  assert.equal(rawFailure?.name, 'TypeError',
    'the observer must preserve the exception identity used by SDK discovery fallbacks')
  const failure = normalizeMcpOAuthFailure(rawFailure, { attempt })

  assert.ok(failure instanceof McpOAuthFailure)
  assert.equal(failure.kind, 'network')
  assert.equal(failure.stage, 'authorization_server_discovery')
  assert.equal(failure.code, 'ENOTFOUND')
  const publicPayload = mcpOAuthFailurePayload(failure, { networkScope: 'public' })
  const vpnPayload = mcpOAuthFailurePayload(failure, { networkScope: 'vpnOnly' })
  assert.match(publicPayload.message, /Check your network connection/)
  assert.doesNotMatch(publicPayload.message, /VPN/)
  assert.match(vpnPayload.message, /Connect to the required VPN/)
  assert.equal(vpnPayload.suggestedAction, 'check_vpn')
  assert.doesNotMatch(JSON.stringify(vpnPayload), /secret-host|private-name/)
})

test('SDK fetches have a bounded timeout that remains separate from browser callback timing', async () => {
  let receivedSignal
  const attempt = createMcpOAuthAttempt(
    async (_url, { signal }) => {
      receivedSignal = signal
      return await new Promise((resolve, reject) => {
        signal.addEventListener('abort', () => reject(signal.reason), { once: true })
      })
    },
    { timeoutMs: 20 },
  )
  const rawFailure = await attempt.fetch(
    'https://login.example.test/.well-known/oauth-authorization-server',
  ).catch((error) => error)
  const failure = normalizeMcpOAuthFailure(rawFailure, { attempt })

  assert.ok(receivedSignal instanceof AbortSignal)
  assert.equal(receivedSignal.aborted, true)
  assert.ok(failure instanceof McpOAuthFailure)
  assert.equal(failure.kind, 'timeout')
  assert.equal(failure.code, 'MCP_OAUTH_FETCH_TIMEOUT')
  assert.equal(failure.stage, 'authorization_server_discovery')
})

test('the fetch timeout composes with a caller abort signal', async () => {
  const caller = new AbortController()
  let receivedSignal
  const attempt = createMcpOAuthAttempt(
    async (_url, { signal }) => {
      receivedSignal = signal
      return await new Promise((resolve, reject) => {
        signal.addEventListener('abort', () => reject(signal.reason), { once: true })
      })
    },
    { timeoutMs: 5_000 },
  )
  const pending = attempt.fetch('https://login.example.test/register', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    signal: caller.signal,
  })
  caller.abort(new Error('caller stopped the request'))
  const rawFailure = await pending.catch((error) => error)
  const failure = normalizeMcpOAuthFailure(rawFailure, { attempt })

  assert.notEqual(receivedSignal, caller.signal)
  assert.equal(receivedSignal.aborted, true)
  assert.ok(failure instanceof McpOAuthFailure)
  assert.equal(failure.kind, 'network')
  assert.equal(failure.stage, 'client_registration')
})

test('discovery HTTP diagnostics include status without retaining endpoint URLs', async () => {
  const attempt = createMcpOAuthAttempt(
    async () => new Response('upstream unavailable', { status: 503 }),
  )
  await attempt.fetch(
    'https://tenant-secret.example/.well-known/oauth-authorization-server/private-path',
  )
  const failure = normalizeMcpOAuthFailure(
    new Error(
      'HTTP 503 trying to load OAuth metadata from '
      + 'https://tenant-secret.example/.well-known/oauth-authorization-server/private-path',
    ),
    { attempt },
  )
  const payload = mcpOAuthFailurePayload(failure)

  assert.equal(payload.errorStage, 'authorization_server_discovery')
  assert.equal(payload.errorKind, 'http')
  assert.equal(payload.httpStatus, 503)
  assert.doesNotMatch(JSON.stringify(payload), /tenant-secret|private-path/)
  assert.deepEqual(failure.trace, [{
    stage: 'authorization_server_discovery',
    status: 503,
    ok: false,
  }])
})

test('no declared host suffix disables the same-origin fallback entirely', () => {
  const discovery = new McpOAuthFailure({
    stage: 'authorization_server_discovery',
    kind: 'http',
    status: 403,
  })
  const declared = process.env.MECHANICIAN_MCP_SAME_ORIGIN_HOST_SUFFIX
  delete process.env.MECHANICIAN_MCP_SAME_ORIGIN_HOST_SUFFIX
  try {
    // This is the public app: no profile declares a host, so the compatibility path does not
    // exist for anyone — including the host that qualifies when a profile does declare it.
    assert.equal(isSameOriginBrowserFallbackEligible(acme, discovery), false)
  } finally {
    process.env.MECHANICIAN_MCP_SAME_ORIGIN_HOST_SUFFIX = declared
  }
})

test('same-origin fallback is restricted to declared hosts and discovery failures', () => {
  const discovery = new McpOAuthFailure({
    stage: 'authorization_server_discovery',
    kind: 'http',
    status: 403,
  })
  assert.equal(isSameOriginBrowserFallbackEligible(acme, discovery), true)
  assert.equal(isSameOriginBrowserFallbackEligible({
    url: 'https://confluence.mcp.example.com.evil.example/mcp',
  }, discovery), false)
  assert.equal(isSameOriginBrowserFallbackEligible({
    url: 'https://confluence.mcp.example.com/mcp?target=other',
  }, discovery), false)
  assert.equal(isSameOriginBrowserFallbackEligible({
    url: 'https://mcp.example.com/mcp',
  }, discovery), false)

  const network = new McpOAuthFailure({
    stage: 'authorization_server_discovery',
    kind: 'network',
  })
  assert.equal(isSameOriginBrowserFallbackEligible(acme, network), false)

  const postRedirect = new McpOAuthFailure({
    stage: 'authorization_server_discovery',
    kind: 'http',
    authorizationWasPresented: true,
  })
  assert.equal(isSameOriginBrowserFallbackEligible(acme, postRedirect), false)

  const realRegistrationIncompatibility = new McpOAuthFailure({
    stage: 'client_registration',
    kind: 'protocol',
    code: 'dynamic_client_registration_unsupported',
    trace: [{ stage: 'authorization_server_discovery', status: 200, ok: true }],
  })
  assert.equal(
    isSameOriginBrowserFallbackEligible(acme, realRegistrationIncompatibility),
    false,
  )
})

test('legacy registration fallback requires failed authorization-server discovery', () => {
  const blockedDiscovery = new McpOAuthFailure({
    stage: 'client_registration',
    kind: 'invalid_response',
    status: 403,
    trace: [
      { stage: 'protected_resource_discovery', status: 404, ok: false },
      { stage: 'authorization_server_discovery', status: 403, ok: false },
      { stage: 'client_registration', status: 403, ok: false },
    ],
  })
  assert.equal(isSameOriginBrowserFallbackEligible(acme, blockedDiscovery), true)

  const discovered = new McpOAuthFailure({
    stage: 'client_registration',
    kind: 'invalid_response',
    status: 400,
    trace: [
      { stage: 'authorization_server_discovery', status: 200, ok: true },
      { stage: 'client_registration', status: 400, ok: false },
    ],
  })
  assert.equal(isSameOriginBrowserFallbackEligible(acme, discovered), false)
})

test('unknown errors never surface raw bodies, URLs, or credentials', () => {
  const raw = new Error(
    '<html>failure for https://secret.example/cb?code=abc '
    + 'Authorization: Bearer do-not-leak access_token=also-secret</html>',
  )
  const payload = mcpOAuthFailurePayload(raw)
  assert.equal(payload.errorKind, 'unknown')
  assert.doesNotMatch(JSON.stringify(payload), /secret\.example|do-not-leak|also-secret|<html>/)
})
