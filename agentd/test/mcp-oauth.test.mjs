import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'
import { test } from 'node:test'
import { query } from '@anthropic-ai/claude-agent-sdk'
import { AccessDeniedError } from '@modelcontextprotocol/sdk/server/auth/errors.js'

import {
  createMcpOAuthManager,
  startMcpOAuthRedirectCapture,
} from '../src/mcp-oauth.mjs'
import {
  McpOAuthFailure,
  mcpOAuthFailurePayload,
} from '../src/mcp-oauth-errors.mjs'
import { resolveMcpOAuthHeaders } from '../src/mcp-auth-header-helper.mjs'
import { configuredMcpStatusPayload } from '../src/mcp-status.mjs'

// The same-origin fallback is only offered to hosts a signed tenant profile declares.
process.env.MECHANICIAN_MCP_SAME_ORIGIN_HOST_SUFFIX = '.mcp.example.com'

const server = {
  id: '7F661A72-4885-42AD-BCE1-242B6741D88A',
  name: 'Confluence', transport: 'http', url: 'https://confluence.mcp.example.com/mcp',
}

function memoryKeychain() {
  const records = new Map()
  return {
    records,
    read(binding) { return structuredClone(records.get(binding.account)) || null },
    write(binding, state) {
      const record = structuredClone({
        ...state, schemaVersion: 1, serverId: binding.serverId, serverUrl: binding.serverUrl,
        bindingDigest: binding.bindingDigest, routeDigest: binding.routeDigest,
      })
      records.set(binding.account, record)
      return structuredClone(record)
    },
    remove(binding) { records.delete(binding.account) },
  }
}

function captureSequence(values) {
  const captures = []
  return {
    captures,
    async factory(options) {
      const value = values.shift()
      const capture = {
        options,
        redirectUri: `http://127.0.0.1:43123/callback/${captures.length}`,
        cancelled: false,
        waitForCallback: async () => value,
        cancel() { this.cancelled = true },
      }
      captures.push(capture)
      return capture
    },
  }
}

function jsonResponse(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

test('standards OAuth persists tokens and mounts a trusted header helper without exposing Bearer', async () => {
  const keychain = memoryKeychain()
  const sequence = captureSequence([{ code: 'authorization-code' }])
  let calls = 0
  const manager = createMcpOAuthManager({
    routeScope: 'anthropic:vertex:route-v1:abc', keychain,
    headerHelperCommand: "'/Applications/Mechanician.app/Contents/Resources/node' '/Applications/Mechanician.app/Contents/Resources/agentd/src/mcp-auth-header-helper.mjs'",
    captureFactory: sequence.factory,
    authImpl: async (provider, options) => {
      calls++
      if (!options.authorizationCode) {
        provider.saveDiscoveryState({
          authorizationServerUrl: 'https://login.example.com',
          authorizationServerMetadata: { token_endpoint: 'https://login.example.com/token' },
          resourceMetadata: { resource: server.url },
        })
        provider.saveClientInformation({ client_id: 'registered-client', client_secret: 'client-secret' })
        provider.saveCodeVerifier('verifier')
        await provider.redirectToAuthorization(new URL('https://login.example.com/authorize?request=1'))
        return 'REDIRECT'
      }
      assert.equal(options.authorizationCode, 'authorization-code')
      assert.equal(provider.codeVerifier(), 'verifier')
      provider.saveTokens({
        access_token: 'access-secret', refresh_token: 'refresh-secret',
        token_type: 'Bearer', expires_in: 3600,
      })
      return 'AUTHORIZED'
    },
  })
  const urls = []
  const result = await manager.authorize(server, { onAuthorizationUrl: (url) => urls.push(url) })
  assert.equal(result.method, 'oauth-2.1')
  assert.equal(calls, 2)
  assert.deepEqual(urls, ['https://login.example.com/authorize?request=1'])

  const loaded = {
    servers: { Confluence: { type: 'http', url: server.url, headers: {}, alwaysLoad: true } },
    oauthBindings: { Confluence: server },
  }
  await manager.applyAuthorization(loaded)
  assert.deepEqual(loaded.servers.Confluence.headers, {})
  assert.match(loaded.servers.Confluence.headersHelper, /mcp-auth-header-helper\.mjs/)
  assert.doesNotMatch(JSON.stringify(loaded.servers), /access-secret|refresh-secret/)
})

test('an explicit Authenticate always starts a new flow instead of reusing a rejected token', async () => {
  const keychain = memoryKeychain()
  const sequence = captureSequence([{ code: 'new-code' }])
  let authCalls = 0
  const manager = createMcpOAuthManager({
    routeScope: 'anthropic:vertex:route-v1:abc', keychain,
    captureFactory: sequence.factory,
    authImpl: async (provider, options) => {
      authCalls++
      if (!options.authorizationCode) {
        provider.saveCodeVerifier('new-verifier')
        await provider.redirectToAuthorization(new URL('https://login.example.com/authorize'))
        return 'REDIRECT'
      }
      provider.saveTokens({ access_token: 'replacement', token_type: 'Bearer' })
      return 'AUTHORIZED'
    },
  })
  keychain.write(manager.bindingFor(server), {
    tokens: { access_token: 'server-rejected', token_type: 'Bearer' },
  })
  const result = await manager.authorize(server, { onAuthorizationUrl: () => {} })
  assert.equal(result.method, 'oauth-2.1')
  assert.equal(authCalls, 2)
  assert.equal(await manager.accessToken(server), 'replacement')
})

test('discovery failure uses the declared same-origin browser flow and stores its token', async () => {
  const keychain = memoryKeychain()
  const sequence = captureSequence([undefined, { accessToken: 'iap-secret' }])
  const manager = createMcpOAuthManager({
    routeScope: 'anthropic:vertex:route-v1:abc', keychain,
    captureFactory: sequence.factory,
    authImpl: async () => {
      throw new McpOAuthFailure({
        stage: 'authorization_server_discovery',
        kind: 'http',
        status: 403,
        message: 'Authorization-server discovery failed.',
      })
    },
  })
  const urls = []
  const result = await manager.authorize(server, {
    onAuthorizationUrl: (url) => urls.push(url),
  })
  assert.equal(result.method, 'same-origin-browser')
  assert.equal(sequence.captures[0].cancelled, true)
  const login = new URL(urls[0])
  assert.equal(login.origin, 'https://confluence.mcp.example.com')
  assert.equal(login.pathname, '/auth/login')
  assert.equal(login.searchParams.get('redirect_uri'), sequence.captures[1].redirectUri)
  assert.equal(await manager.accessToken(server), 'iap-secret')
})

test('an OAuth denial after presenting authorization never falls through to another flow', async () => {
  const keychain = memoryKeychain()
  const sequence = captureSequence([undefined, { accessToken: 'must-not-be-used' }])
  const manager = createMcpOAuthManager({
    routeScope: 'anthropic:vertex:route-v1:abc', keychain,
    captureFactory: sequence.factory,
    authImpl: async (provider) => {
      await provider.redirectToAuthorization(new URL('https://login.example.com/authorize'))
      throw Object.freeze(new AccessDeniedError('The user denied access.'))
    },
  })
  await assert.rejects(
    manager.authorize(server, { onAuthorizationUrl: () => {} }),
    (error) => error instanceof McpOAuthFailure
      && error.kind === 'oauth'
      && error.oauthError === 'access_denied'
      && error.authorizationWasPresented === true,
  )
  assert.equal(sequence.captures.length, 1)
  assert.equal(await manager.accessToken(server), null)
})

test('pinned SDK reports missing DCR exactly and a generic server never gets Acme fallback', async () => {
  const generic = {
    ...server,
    id: '6D7A70F3-B60D-4CE3-AB72-F72EF2E43028',
    name: 'Generic',
    url: 'https://mcp.example.com/mcp',
  }
  const sequence = captureSequence([undefined, { accessToken: 'must-not-be-used' }])
  const requests = []
  const manager = createMcpOAuthManager({
    routeScope: 'anthropic:vertex:route-v1:abc',
    keychain: memoryKeychain(),
    captureFactory: sequence.factory,
    fetchImpl: async (input, init = {}) => {
      const url = new URL(input)
      requests.push({ pathname: url.pathname, method: init.method || 'GET' })
      if (url.pathname.includes('/.well-known/oauth-protected-resource')) {
        return jsonResponse({
          resource: generic.url,
          authorization_servers: ['https://login.example.test'],
        })
      }
      if (url.pathname.includes('/.well-known/oauth-authorization-server')) {
        return jsonResponse({
          issuer: 'https://login.example.test',
          authorization_endpoint: 'https://login.example.test/authorize',
          token_endpoint: 'https://login.example.test/token',
          response_types_supported: ['code'],
          code_challenge_methods_supported: ['S256'],
        })
      }
      throw new Error('unexpected OAuth request')
    },
  })

  await assert.rejects(
    manager.authorize(generic, { onAuthorizationUrl: () => {} }),
    (error) => error instanceof McpOAuthFailure
      && error.stage === 'client_registration'
      && error.kind === 'protocol'
      && error.code === 'dynamic_client_registration_unsupported'
      && mcpOAuthFailurePayload(error).message
        === 'Incompatible auth server: does not support dynamic client registration',
  )
  assert.ok(requests.some((request) =>
    request.pathname.includes('/.well-known/oauth-protected-resource')))
  assert.ok(requests.some((request) =>
    request.pathname.includes('/.well-known/oauth-authorization-server')))
  assert.equal(requests.some((request) => request.method === 'POST'), false)
  assert.equal(sequence.captures.length, 1)
  assert.equal(sequence.captures[0].cancelled, true)
})

test('pinned SDK token errors retain HTTP status and sanitized OAuth fields', async () => {
  const generic = {
    ...server,
    id: '2502228E-D43F-4D0D-913F-97668C538C98',
    name: 'TokenFailure',
    url: 'https://mcp.example.com/mcp',
  }
  const sequence = captureSequence([{ code: 'expired-code' }])
  let tokenRequests = 0
  const manager = createMcpOAuthManager({
    routeScope: 'anthropic:vertex:route-v1:abc',
    keychain: memoryKeychain(),
    captureFactory: sequence.factory,
    fetchImpl: async (input, init = {}) => {
      const url = new URL(input)
      const contentType = new Headers(init.headers).get('content-type') || ''
      if (url.pathname.includes('/.well-known/oauth-protected-resource')) {
        return jsonResponse({
          resource: generic.url,
          authorization_servers: ['https://login.example.test'],
        })
      }
      if (url.pathname.includes('/.well-known/oauth-authorization-server')) {
        return jsonResponse({
          issuer: 'https://login.example.test',
          authorization_endpoint: 'https://login.example.test/authorize',
          token_endpoint: 'https://login.example.test/token',
          registration_endpoint: 'https://login.example.test/register',
          response_types_supported: ['code'],
          code_challenge_methods_supported: ['S256'],
          token_endpoint_auth_methods_supported: ['none'],
        })
      }
      if (url.pathname === '/register' && contentType.includes('application/json')) {
        const metadata = JSON.parse(init.body)
        return jsonResponse({
          ...metadata,
          client_id: 'mechanician-test-client',
          token_endpoint_auth_method: 'none',
        }, 201)
      }
      if (url.pathname === '/token'
          && contentType.includes('application/x-www-form-urlencoded')) {
        tokenRequests++
        return jsonResponse({
          error: 'invalid_grant',
          error_description: 'Authorization code expired. access_token=must-not-escape',
        }, 400)
      }
      throw new Error('unexpected OAuth request')
    },
  })
  const authorizationURLs = []
  const error = await manager.authorize(generic, {
    onAuthorizationUrl: (url) => authorizationURLs.push(url),
  }).catch((failure) => failure)
  const payload = mcpOAuthFailurePayload(error)

  assert.ok(error instanceof McpOAuthFailure)
  assert.equal(error.authorizationWasPresented, true, JSON.stringify({
    stage: error.stage,
    kind: error.kind,
    code: error.code,
    payload,
    tokenRequests,
  }))
  assert.equal(payload.errorStage, 'token_exchange')
  assert.equal(payload.errorKind, 'oauth')
  assert.equal(payload.httpStatus, 400)
  assert.equal(payload.oauthError, 'invalid_grant')
  assert.match(payload.oauthDescription, /\[redacted\]/)
  assert.doesNotMatch(JSON.stringify(payload), /must-not-escape/)
  assert.equal(authorizationURLs.length, 1)
  assert.ok(tokenRequests >= 1)
  assert.equal(sequence.captures.length, 1)
})

test('expired tokens refresh once and concurrent mounts share the in-flight refresh', async () => {
  const keychain = memoryKeychain()
  let now = 2_000_000
  let refreshCalls = 0
  const manager = createMcpOAuthManager({
    routeScope: 'anthropic:vertex:route-v1:abc', keychain, now: () => now,
    discoverImpl: async () => { throw new Error('persisted discovery should be reused') },
    selectResourceImpl: async () => new URL(server.url),
    refreshImpl: async () => {
      refreshCalls++
      await new Promise((resolve) => setTimeout(resolve, 5))
      return { access_token: 'fresh', refresh_token: 'refresh', token_type: 'Bearer', expires_in: 3600 }
    },
  })
  const binding = manager.bindingFor(server)
  keychain.write(binding, {
    tokens: { access_token: 'expired', refresh_token: 'refresh', token_type: 'Bearer', expires_in: 60 },
    tokensObtainedAt: now - 120_000,
    clientInformation: { client_id: 'client', client_secret: 'secret' },
    discoveryState: {
      authorizationServerUrl: 'https://login.example.com',
      authorizationServerMetadata: { token_endpoint: 'https://login.example.com/token' },
      resourceMetadata: { resource: server.url },
    },
  })
  const [first, second] = await Promise.all([manager.accessToken(server), manager.accessToken(server)])
  assert.deepEqual([first, second], ['fresh', 'fresh'])
  assert.equal(refreshCalls, 1)
})

test('Clear Auth wins over an in-flight refresh and a late response cannot restore the token', async () => {
  const keychain = memoryKeychain()
  let releaseRefresh
  const refreshResult = new Promise((resolve) => { releaseRefresh = resolve })
  const manager = createMcpOAuthManager({
    routeScope: 'anthropic:vertex:route-v1:abc', keychain, now: () => 2_000_000,
    selectResourceImpl: async () => new URL(server.url),
    refreshImpl: async () => refreshResult,
  })
  keychain.write(manager.bindingFor(server), {
    tokens: { access_token: 'expired', refresh_token: 'refresh', token_type: 'Bearer', expires_in: 60 },
    tokensObtainedAt: 1_000_000,
    clientInformation: { client_id: 'client' },
    discoveryState: {
      authorizationServerUrl: 'https://login.example.com',
      authorizationServerMetadata: { token_endpoint: 'https://login.example.com/token' },
      resourceMetadata: { resource: server.url },
    },
  })
  const pending = manager.accessToken(server)
  manager.clear(server)
  releaseRefresh({ access_token: 'late-token', token_type: 'Bearer', expires_in: 3600 })
  assert.equal(await pending, null)
  assert.equal(await manager.accessToken(server), null)
})

test('manual header credentials take precedence and Clear Auth removes the unused OAuth token', async () => {
  const keychain = memoryKeychain()
  const manager = createMcpOAuthManager({
    routeScope: 'anthropic:vertex:route-v1:abc', keychain,
  })
  const binding = manager.bindingFor(server)
  keychain.write(binding, { tokens: { access_token: 'oauth', token_type: 'Bearer' } })
  const loaded = {
    servers: { Confluence: { type: 'http', url: server.url,
      headers: { authorization: 'Bearer manual' } } },
    oauthBindings: { Confluence: server },
  }
  await manager.applyAuthorization(loaded)
  assert.equal(loaded.servers.Confluence.headers.authorization, 'Bearer manual')
  assert.equal(loaded.authorizationStates.Confluence, 'authenticated')
  manager.clear(server)
  assert.equal(await manager.accessToken(server), null)
})

test('a Jira-style PAT header suppresses OAuth without reading the OAuth Keychain', async () => {
  let oauthReads = 0
  const manager = createMcpOAuthManager({
    routeScope: 'anthropic:vertex:route-v1:abc',
    keychain: {
      read() { oauthReads++; throw new Error('OAuth Keychain should not be read') },
      write() { throw new Error('not reached') },
      remove() {},
    },
  })
  const loaded = {
    servers: { Jira: { type: 'http', url: 'https://jira.example.com/mcp',
      headers: { 'X-API-Key': 'jira-pat' } } },
    oauthBindings: { Jira: {
      ...server, id: 'F23ED452-EA37-442F-99B5-1B72AA61357B',
      name: 'Jira', url: 'https://jira.example.com/mcp',
    } },
  }

  await manager.applyAuthorization(loaded)

  assert.equal(oauthReads, 0)
  assert.equal(loaded.authorizationStates.Jira, 'authenticated')
  assert.equal(loaded.servers.Jira.headers['X-API-Key'], 'jira-pat')
  assert.equal(loaded.servers.Jira.headersHelper, undefined)
  assert.equal(configuredMcpStatusPayload(loaded)[0].status, 'authenticated',
    'the Connections panel must not offer browser sign-in for a saved PAT')
})

test('empty manual headers do not falsely satisfy authentication', async () => {
  const manager = createMcpOAuthManager({
    routeScope: 'anthropic:vertex:route-v1:abc',
    keychain: memoryKeychain(),
  })
  const loaded = {
    servers: { Confluence: { type: 'http', url: server.url,
      headers: { Authorization: '   ' } } },
    oauthBindings: { Confluence: server },
  }

  await manager.applyAuthorization(loaded)

  assert.equal(loaded.authorizationStates.Confluence, 'needs-auth')
})

test('Keychain read failure remains unavailable instead of being mislabeled needs-auth', async () => {
  const manager = createMcpOAuthManager({
    routeScope: 'anthropic:vertex:route-v1:abc',
    keychain: {
      read() { throw new Error('macOS Keychain unavailable') },
      write() { throw new Error('not reached') },
      remove() {},
    },
    headerHelperCommand: "'/fixed/node' '/fixed/mcp-auth-header-helper.mjs'",
  })
  const loaded = {
    servers: { Confluence: { type: 'http', url: server.url, headers: {} } },
    oauthBindings: { Confluence: server },
    errors: [],
  }
  await manager.applyAuthorization(loaded)
  assert.equal(loaded.authorizationStates.Confluence, 'unavailable')
  assert.equal(loaded.servers.Confluence.headersHelper, undefined)
  assert.equal(loaded.errors.length, 1)
})

test('loopback capture ignores wrong state and accepts only the unguessable callback path', async (t) => {
  const capture = await startMcpOAuthRedirectCapture({
    mode: 'code', expectedState: 'expected', timeoutMs: 2_000, nonce: 'fixed-test-nonce',
  })
  t.after(() => capture.cancel())
  const redirect = new URL(capture.redirectUri)
  const wrongPath = new URL('/callback/other?code=stolen&state=expected', redirect)
  assert.equal((await fetch(wrongPath)).status, 404)
  const wrongState = new URL(redirect)
  wrongState.search = '?code=stolen&state=wrong'
  assert.equal((await fetch(wrongState)).status, 400)
  const correct = new URL(redirect)
  correct.search = '?code=real-code&state=expected'
  assert.equal((await fetch(correct)).status, 200)
  assert.deepEqual(await capture.waitForCallback(), { code: 'real-code' })
})

test('loopback OAuth denials preserve only safe structured callback diagnostics', async (t) => {
  const capture = await startMcpOAuthRedirectCapture({
    mode: 'code', expectedState: 'expected', timeoutMs: 2_000, nonce: 'denial-test-nonce',
  })
  t.after(() => capture.cancel())
  const redirect = new URL(capture.redirectUri)
  redirect.searchParams.set('state', 'expected')
  redirect.searchParams.set('error', 'access_denied')
  redirect.searchParams.set(
    'error_description',
    'User denied access. access_token=callback-secret '
      + 'details=https://login.example/cb?code=authorization-secret',
  )
  assert.equal((await fetch(redirect)).status, 200)
  const error = await capture.waitForCallback().catch((failure) => failure)
  const payload = mcpOAuthFailurePayload(error)

  assert.ok(error instanceof McpOAuthFailure)
  assert.equal(payload.errorStage, 'authorization_callback')
  assert.equal(payload.errorKind, 'oauth')
  assert.equal(payload.oauthError, 'access_denied')
  assert.match(payload.oauthDescription, /\[redacted\]/)
  assert.match(payload.oauthDescription, /\[redacted-url\]/)
  assert.doesNotMatch(JSON.stringify(payload), /callback-secret|authorization-secret/)
})

test('header helper binds Claude server name and URL to the configured UUID and performs a read-only token lookup', async () => {
  const payload = JSON.stringify({ mcpServers: [{ ...server, enabled: true }] })
  let observed
  const headers = await resolveMcpOAuthHeaders({
    environment: {
      MECHANICIAN_MCP_OAUTH_ROUTE_SCOPE: 'anthropic:vertex:route-v1:abc',
      MECHANICIAN_SUPPORT_DIR: '/test/support',
      CLAUDE_CODE_MCP_SERVER_NAME: 'Confluence',
      CLAUDE_CODE_MCP_SERVER_URL: server.url,
    },
    readFile(file) {
      assert.equal(file, '/test/support/extensions.json')
      return payload
    },
    manager: {
      async accessToken(resolved, options) {
        observed = { resolved, options }
        return 'helper-secret'
      },
    },
  })
  assert.deepEqual(headers, { Authorization: 'Bearer helper-secret' })
  assert.deepEqual(observed, { resolved: server, options: { allowRefresh: false } })
})

test('header helper fails closed when Claude supplies a different endpoint', async () => {
  await assert.rejects(resolveMcpOAuthHeaders({
    environment: {
      MECHANICIAN_MCP_OAUTH_ROUTE_SCOPE: 'anthropic:vertex:route-v1:abc',
      MECHANICIAN_SUPPORT_DIR: '/test/support',
      CLAUDE_CODE_MCP_SERVER_NAME: 'Confluence',
      CLAUDE_CODE_MCP_SERVER_URL: 'https://attacker.example/mcp',
    },
    readFile: () => JSON.stringify({ mcpServers: [{ ...server, enabled: true }] }),
    manager: { accessToken: async () => 'must-not-be-read' },
  }), /endpoint mismatch/)
})

test('bundled Claude Agent SDK forwards headersHelper in MCP config without a bearer value', async () => {
  let spawned
  class FakeClaudeProcess extends EventEmitter {
    constructor() {
      super()
      this.stdin = new PassThrough()
      this.stdout = new PassThrough()
      this.killed = false
      this.exitCode = null
    }
    kill() {
      this.killed = true
      this.exitCode = 0
      this.stdout.end()
      this.emit('exit', 0, null)
      return true
    }
  }
  const helper = "'/fixed/node' '/fixed/mcp-auth-header-helper.mjs'"
  const active = query({
    prompt: 'serialization test',
    options: {
      mcpServers: { Confluence: { type: 'http', url: server.url, headersHelper: helper } },
      spawnClaudeCodeProcess(options) {
        spawned = options
        return new FakeClaudeProcess()
      },
    },
  })
  try {
    const index = spawned.args.indexOf('--mcp-config')
    assert.notEqual(index, -1)
    const config = JSON.parse(spawned.args[index + 1])
    assert.equal(config.mcpServers.Confluence.headersHelper, helper)
    assert.doesNotMatch(spawned.args.join(' '), /Bearer|access-secret|refresh-secret/)
  } finally {
    await active.return()
  }
})
