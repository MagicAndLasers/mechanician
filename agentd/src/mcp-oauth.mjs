// App-owned OAuth for remote MCP servers.
//
// The Claude SDK's control methods keep OAuth state in a disposable CLI subprocess. Mechanician
// instead uses the official MCP SDK's current OAuth 2.1 implementation for RFC 9728 discovery,
// RFC 8414/OIDC metadata, RFC 7591 registration, PKCE, RFC 8707 resource indicators, token exchange,
// and refresh. Client registration and tokens are persisted only in the macOS Keychain.
//
// Acme's IAP front door intentionally blocks programmatic discovery. If (and only if) the
// standards flow fails before presenting an authorization URL, we use its same-origin browser
// contract: /auth/login redirects to an unguessable loopback callback with an access_token.

import { randomBytes } from 'node:crypto'
import { createServer } from 'node:http'
import {
  auth as sdkAuth,
  discoverOAuthServerInfo,
  refreshAuthorization,
  selectResourceURL,
} from '@modelcontextprotocol/sdk/client/auth.js'

import { createMcpOAuthKeychain, mcpOAuthBinding } from './mcp-oauth-keychain.mjs'
import {
  McpOAuthFailure,
  createMcpOAuthAttempt,
  isSameOriginBrowserFallbackEligible,
  normalizeMcpOAuthFailure,
} from './mcp-oauth-errors.mjs'

const DEFAULT_TIMEOUT_MS = 5 * 60 * 1000
const DEFAULT_REFRESH_MARGIN_MS = 5 * 60 * 1000
const MAX_TOKEN_BYTES = 1024 * 1024

function html(value) {
  return String(value).replace(/[&<>"']/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[character])
}

function resultPage(title, message) {
  return `<!doctype html><meta charset="utf-8"><meta name="referrer" content="no-referrer">\
<title>${html(title)}</title><body style="font:15px -apple-system;padding:3rem;text-align:center;\
color:#e5e9f0;background:#2e3440"><h2>${html(title)}</h2><p style="color:#81a1c1">\
${html(message)}</p></body>`
}

/**
 * A localhost receiver with a random path capability. OAuth state is additionally verified for
 * authorization-code flows. A request to the right port but wrong path/state cannot consume the
 * real callback. Tokens are returned as values, never as full URLs that could be logged later.
 */
export function startMcpOAuthRedirectCapture({
  mode = 'code',
  expectedState,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  nonce = randomBytes(24).toString('base64url'),
} = {}) {
  if (mode !== 'code' && mode !== 'token') throw new Error('invalid MCP OAuth callback mode')
  return new Promise((ready, readyFail) => {
    let settleResolve
    let settleReject
    const callback = new Promise((resolve, reject) => {
      settleResolve = resolve
      settleReject = reject
    })
    callback.catch(() => {})
    let done = false
    let timer
    const callbackPath = `/callback/${nonce}`
    const finish = (fn, value) => {
      if (done) return
      done = true
      clearTimeout(timer)
      try { server.close() } catch {}
      fn(value)
    }
    const respond = (response, status, title, detail) => {
      response.writeHead(status, {
        'Content-Type': 'text/html; charset=utf-8',
        'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'",
        'Referrer-Policy': 'no-referrer',
        'X-Content-Type-Options': 'nosniff',
        'Cache-Control': 'no-store',
      })
      response.end(resultPage(title, detail))
    }
    const server = createServer((request, response) => {
      if (request.method !== 'GET') {
        respond(response, 405, 'Authentication not accepted', 'The callback method was not valid.')
        return
      }
      const url = new URL(request.url || '/', 'http://127.0.0.1')
      if (url.pathname !== callbackPath) {
        respond(response, 404, 'Not found', 'This is not an active Mechanician callback.')
        return
      }
      if (mode === 'code' && (!expectedState || url.searchParams.get('state') !== expectedState)) {
        // Do not settle: the real browser redirect may still arrive after a stray local request.
        respond(response, 400, 'Authentication not accepted',
          'This callback did not match the active sign-in request.')
        return
      }
      const error = url.searchParams.get('error')
      if (error) {
        respond(response, 200, 'Authentication failed', 'The authorization server declined access.')
        finish(settleReject, new McpOAuthFailure({
          stage: mode === 'code' ? 'authorization_callback' : 'same_origin_browser',
          kind: 'oauth',
          oauthError: error,
          oauthDescription: url.searchParams.get('error_description'),
          message: 'Authorization was declined.',
          suggestedAction: 'retry',
          retryable: false,
        }))
        return
      }
      const value = mode === 'code'
        ? url.searchParams.get('code')
        : url.searchParams.get('access_token')
      if (!value || Buffer.byteLength(value, 'utf8') > MAX_TOKEN_BYTES) {
        respond(response, 400, 'Authentication not accepted',
          mode === 'code' ? 'No authorization code was received.' : 'No access token was received.')
        return
      }
      respond(response, 200, 'Connected', 'You can close this tab and return to Mechanician.')
      finish(settleResolve, mode === 'code' ? { code: value } : { accessToken: value })
    })
    server.once('error', (error) => {
      if (!done) {
        done = true
        clearTimeout(timer)
        settleReject(error)
        readyFail(error)
      }
    })
    timer = setTimeout(() => {
      finish(settleReject, new McpOAuthFailure({
        stage: mode === 'code' ? 'authorization_callback' : 'same_origin_browser',
        kind: 'timeout',
        code: 'MCP_OAUTH_CALLBACK_TIMEOUT',
        message: 'Authentication timed out.',
        suggestedAction: 'retry',
        retryable: true,
      }))
    }, timeoutMs)
    server.listen(0, '127.0.0.1', () => {
      const address = server.address()
      if (!address || typeof address !== 'object') {
        finish(settleReject, new Error('Could not start the authentication callback.'))
        readyFail(new Error('Could not start the authentication callback.'))
        return
      }
      ready({
        redirectUri: `http://127.0.0.1:${address.port}${callbackPath}`,
        waitForCallback: () => callback,
        cancel: () => finish(settleReject, new McpOAuthFailure({
          stage: mode === 'code' ? 'authorization_callback' : 'same_origin_browser',
          kind: 'cancelled',
          code: 'MCP_OAUTH_CANCELLED',
          message: 'Authorization was cancelled.',
          suggestedAction: 'none',
          retryable: false,
        })),
      })
    })
  })
}

function safeAuthorizationURL(value) {
  const url = value instanceof URL ? value : new URL(value)
  const loopback = url.hostname === '127.0.0.1' || url.hostname === 'localhost' || url.hostname === '::1'
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && loopback)) {
    throw new Error('The authorization server returned an unsafe URL.')
  }
  return url
}

function fallbackLoginURL(serverUrl, redirectUri) {
  const base = new URL(serverUrl)
  if (base.protocol !== 'https:') throw new Error('Browser fallback requires an HTTPS MCP server.')
  base.search = ''
  base.hash = ''
  base.pathname = base.pathname.replace(/\/mcp\/?$/i, '').replace(/\/$/, '') + '/auth/login'
  base.searchParams.set('redirect_uri', redirectUri)
  return base
}

function validBearerTokens(tokens) {
  return tokens && typeof tokens.access_token === 'string' && tokens.access_token.length > 0
    && Buffer.byteLength(tokens.access_token, 'utf8') <= MAX_TOKEN_BYTES
    && (!tokens.token_type || String(tokens.token_type).toLowerCase() === 'bearer')
}

function tokenExpiry(record) {
  const seconds = Number(record?.tokens?.expires_in)
  const obtainedAt = Number(record?.tokensObtainedAt)
  if (!Number.isFinite(seconds) || seconds <= 0 || !Number.isFinite(obtainedAt)) return null
  return obtainedAt + seconds * 1000
}

function supersededError() {
  return new McpOAuthFailure({
    stage: 'authorization_setup',
    kind: 'cancelled',
    code: 'MCP_OAUTH_SUPERSEDED',
    message: 'This MCP authorization operation was superseded.',
    suggestedAction: 'none',
    retryable: false,
  })
}

function providerFor({
  binding, keychain, redirectUri, expectedState, onRedirect, now,
  canPersist = () => true, onStage = () => {},
}) {
  let record
  try {
    record = keychain.read(binding) || {}
  } catch (error) {
    throw normalizeMcpOAuthFailure(error, { stage: 'credential_storage' })
  }
  let codeVerifier
  const ensureCurrent = () => {
    if (!canPersist()) throw supersededError()
  }
  const persist = (patch) => {
    ensureCurrent()
    try {
      record = keychain.write(binding, { ...record, ...patch })
    } catch (error) {
      throw normalizeMcpOAuthFailure(error, { stage: 'credential_storage' })
    }
  }
  const remove = () => {
    ensureCurrent()
    try {
      keychain.remove(binding)
      record = {}
    } catch (error) {
      throw normalizeMcpOAuthFailure(error, { stage: 'credential_storage' })
    }
  }
  return {
    get redirectUrl() { return redirectUri },
    get clientMetadata() {
      return {
        client_name: 'Mechanician',
        redirect_uris: [redirectUri],
        grant_types: ['authorization_code', 'refresh_token'],
        response_types: ['code'],
        token_endpoint_auth_method: 'none',
      }
    },
    state: () => expectedState,
    clientInformation: () => record.clientInformation,
    saveClientInformation(value) { persist({ clientInformation: value }) },
    tokens: () => record.tokens,
    saveTokens(value) { persist({ tokens: value, tokensObtainedAt: now() }) },
    redirectToAuthorization(value) {
      onStage('authorization_redirect')
      onRedirect(safeAuthorizationURL(value))
    },
    saveCodeVerifier(value) { codeVerifier = value },
    codeVerifier() {
      if (!codeVerifier) throw new Error('The OAuth code verifier is no longer available.')
      return codeVerifier
    },
    saveDiscoveryState(value) { persist({ discoveryState: value }) },
    discoveryState: () => record.discoveryState,
    invalidateCredentials(scope) {
      ensureCurrent()
      if (scope === 'all') { remove(); return }
      if (scope === 'tokens') persist({ tokens: undefined, tokensObtainedAt: undefined })
      if (scope === 'client') persist({ clientInformation: undefined })
      if (scope === 'discovery') persist({ discoveryState: undefined })
      if (scope === 'verifier') codeVerifier = undefined
    },
    currentRecord: () => record,
    ensureCurrent,
  }
}

export function createMcpOAuthManager({
  routeScope,
  keychain = createMcpOAuthKeychain(),
  headerHelperCommand,
  fetchImpl = globalThis.fetch,
  now = () => Date.now(),
  authImpl = sdkAuth,
  discoverImpl = discoverOAuthServerInfo,
  refreshImpl = refreshAuthorization,
  selectResourceImpl = selectResourceURL,
  captureFactory = startMcpOAuthRedirectCapture,
  refreshMarginMs = DEFAULT_REFRESH_MARGIN_MS,
  oauthFetchTimeoutMs = 15_000,
} = {}) {
  if (typeof routeScope !== 'string' || !routeScope) throw new Error('MCP OAuth requires a route scope')
  const refreshes = new Map()
  const failures = new Map()
  // Authorize, refresh, and Clear Auth may overlap. A generation makes every eventual Keychain
  // write conditional on still being the newest operation, so a late token response can never
  // resurrect credentials after Clear Auth or overwrite a newer interactive sign-in.
  const generations = new Map()

  const bindingFor = (server) => mcpOAuthBinding(server, routeScope)
  const generationFor = (binding) => generations.get(binding.account) || 0
  const advanceGeneration = (binding) => {
    const next = generationFor(binding) + 1
    generations.set(binding.account, next)
    return next
  }
  const generationIsCurrent = (binding, generation) => generationFor(binding) === generation
  const requireGeneration = (binding, generation) => {
    if (!generationIsCurrent(binding, generation)) throw supersededError()
  }

  async function refresh(binding, record) {
    const generation = generationFor(binding)
    const existing = refreshes.get(binding.account)
    if (existing?.generation === generation) return existing.promise
    const failure = failures.get(binding.account)
    if (failure && failure.retryAt > now()) return null
    const entry = { generation, promise: null }
    const request = (async () => {
      const attempt = createMcpOAuthAttempt(fetchImpl, { timeoutMs: oauthFetchTimeoutMs })
      try {
        if (!record?.tokens?.refresh_token || !record?.clientInformation) return null
        let discovery = record.discoveryState
        if (!discovery) {
          attempt.setStage('authorization_server_discovery')
          discovery = await discoverImpl(binding.serverUrl, { fetchFn: attempt.fetch })
          requireGeneration(binding, generation)
          record = keychain.write(binding, { ...record, discoveryState: discovery })
        }
        const provider = providerFor({
          binding, keychain, redirectUri: 'http://127.0.0.1/', expectedState: '',
          onRedirect: () => {}, now,
          canPersist: () => generationIsCurrent(binding, generation),
        })
        const resource = await selectResourceImpl(
          binding.serverUrl, provider, discovery.resourceMetadata)
        attempt.setStage('token_exchange')
        const tokens = await refreshImpl(discovery.authorizationServerUrl, {
          metadata: discovery.authorizationServerMetadata,
          clientInformation: record.clientInformation,
          refreshToken: record.tokens.refresh_token,
          resource,
          fetchFn: attempt.fetch,
        })
        if (!validBearerTokens(tokens)) throw new Error('OAuth refresh returned no bearer token')
        requireGeneration(binding, generation)
        keychain.write(binding, { ...record, tokens, tokensObtainedAt: now() })
        failures.delete(binding.account)
        return tokens.access_token
      } catch (error) {
        if (error?.code === 'MCP_OAUTH_SUPERSEDED') return null
        const attempts = Math.min((failures.get(binding.account)?.attempts || 0) + 1, 6)
        failures.set(binding.account, {
          attempts, retryAt: now() + Math.min(60_000, 1000 * 2 ** attempts),
        })
        return null
      } finally {
        if (refreshes.get(binding.account) === entry) refreshes.delete(binding.account)
      }
    })()
    entry.promise = request
    refreshes.set(binding.account, entry)
    return request
  }

  async function accessToken(server, { allowRefresh = true } = {}) {
    const binding = bindingFor(server)
    const generation = generationFor(binding)
    const record = keychain.read(binding)
    if (!record || !validBearerTokens(record.tokens)) return null
    const expiry = tokenExpiry(record)
    // The Claude headersHelper is deliberately read-only. agentd refreshes before mounting the
    // server; the short-lived helper then performs one Keychain read and cannot race Clear Auth by
    // completing a late network refresh in another process.
    if (!allowRefresh) return expiry === null || expiry > now() ? record.tokens.access_token : null
    if (expiry === null || expiry - now() > refreshMarginMs) return record.tokens.access_token
    const refreshed = await refresh(binding, record)
    if (refreshed) return refreshed
    if (!generationIsCurrent(binding, generation)) return null
    // A network-only refresh failure must not discard a token that is still actually valid.
    return expiry > now() ? record.tokens.access_token : null
  }

  async function applyAuthorization(loaded) {
    loaded.authorizationStates = loaded.authorizationStates || {}
    for (const [name, server] of Object.entries(loaded?.oauthBindings || {})) {
      const sdkServer = loaded.servers?.[name]
      if (!sdkServer || (sdkServer.type !== 'http' && sdkServer.type !== 'sse')) continue
      // The connection editor treats remote headers as the manual-credential alternative to
      // browser OAuth and persists every value in Keychain. Do not infer OAuth from one exact,
      // case-sensitive spelling of "Authorization": HTTP field names are case-insensitive, and
      // PAT-based servers also commonly use fields such as X-API-Key. A non-empty manual header
      // remains authoritative until the user edits or removes it.
      const hasManualCredentials = Object.values(sdkServer.headers || {}).some(
        (value) => typeof value === 'string' && value.trim().length > 0,
      )
      if (hasManualCredentials) {
        loaded.authorizationStates[name] = 'authenticated'
        continue
      }
      let token
      let credentialReadFailed = false
      try { token = await accessToken(server) } catch {
        token = null
        credentialReadFailed = true
        loaded.authorizationStates[name] = 'unavailable'
        loaded.errors = loaded.errors || []
        loaded.errors.push({
          name: String(name).replace(/[\r\n\t]/g, ' ').slice(0, 160),
          message: 'MCP OAuth credentials could not be loaded from the macOS Keychain.',
        })
      }
      if (token) {
        loaded.authorizationStates[name] = 'authenticated'
        if (!headerHelperCommand) {
          throw new Error('MCP OAuth header helper is not configured')
        }
        // Claude Code runs this trusted helper when the connection is opened. The bearer value
        // travels from Keychain to the helper's stdout pipe and never appears in --mcp-config,
        // process arguments, the Claude process environment, or an agent-visible child environment.
        sdkServer.headersHelper = headerHelperCommand
      } else if (!credentialReadFailed) {
        loaded.authorizationStates[name] = 'needs-auth'
      }
    }
    return loaded
  }

  async function standardAuthorization(
    server, binding, generation, { onAuthorizationUrl, onCapture },
  ) {
    const attempt = createMcpOAuthAttempt(fetchImpl, { timeoutMs: oauthFetchTimeoutMs })
    const expectedState = randomBytes(24).toString('base64url')
    let capture
    let redirected = false
    try {
      attempt.setStage('callback_listener')
      capture = await captureFactory({ mode: 'code', expectedState })
      onCapture?.(capture)
      const provider = providerFor({
        binding, keychain, redirectUri: capture.redirectUri, expectedState,
        onRedirect(url) {
          redirected = true
          onAuthorizationUrl(url.toString())
        },
        onStage: (stage) => attempt.setStage(stage),
        now,
        canPersist: () => generationIsCurrent(binding, generation),
      })
      // A new interactive attempt gets a new DCR registration tied to this loopback redirect. Keep
      // discovery metadata, but do not reuse an expired token or a registration with an old port.
      provider.invalidateCredentials('client')
      provider.invalidateCredentials('tokens')
      attempt.setStage('authorization_setup')
      const result = await authImpl(provider, {
        serverUrl: binding.serverUrl,
        fetchFn: attempt.fetch,
      })
      if (result !== 'REDIRECT') {
        capture.cancel()
        return { completed: true, redirected }
      }
      attempt.setStage('authorization_callback')
      const callback = await capture.waitForCallback()
      attempt.setStage('token_exchange')
      const completed = await authImpl(provider, {
        serverUrl: binding.serverUrl,
        authorizationCode: callback.code,
        fetchFn: attempt.fetch,
      })
      if (completed !== 'AUTHORIZED' || !validBearerTokens(provider.currentRecord().tokens)) {
        throw new Error('The authorization server did not return a bearer token.')
      }
      provider.ensureCurrent()
      failures.delete(binding.account)
      return { completed: true, redirected }
    } catch (error) {
      try { capture?.cancel?.() } catch {}
      // Always normalize into our own extensible error: SDK errors may be frozen. The presentation
      // marker must survive so a denial/exchange failure never falls through to another mechanism.
      throw normalizeMcpOAuthFailure(error, {
        attempt,
        authorizationWasPresented: redirected,
      })
    }
  }

  async function browserFallback(
    server, binding, generation, { onAuthorizationUrl, onCapture }, fallbackFromStage,
  ) {
    let capture
    let presented = false
    try {
      capture = await captureFactory({ mode: 'token' })
      onCapture?.(capture)
      onAuthorizationUrl(fallbackLoginURL(binding.serverUrl, capture.redirectUri).toString())
      presented = true
      const callback = await capture.waitForCallback()
      const tokens = { access_token: callback.accessToken, token_type: 'Bearer' }
      requireGeneration(binding, generation)
      try {
        keychain.write(binding, {
          flow: 'same-origin-browser', tokens, tokensObtainedAt: now(),
          clientInformation: undefined, discoveryState: undefined,
        })
      } catch (error) {
        throw normalizeMcpOAuthFailure(error, { stage: 'credential_storage' })
      }
      failures.delete(binding.account)
    } catch (error) {
      try { capture?.cancel?.() } catch {}
      throw normalizeMcpOAuthFailure(error, {
        stage: error?.stage === 'credential_storage'
          ? 'credential_storage' : 'same_origin_browser',
        authorizationWasPresented: presented,
        fallbackFromStage,
      })
    }
  }

  async function authorize(server, options = {}) {
    let binding
    try {
      binding = bindingFor(server)
    } catch (error) {
      throw normalizeMcpOAuthFailure(error, { stage: 'authorization_setup' })
    }
    const generation = advanceGeneration(binding)
    if (options.clearFirst) {
      try {
        keychain.remove(binding)
      } catch (error) {
        throw normalizeMcpOAuthFailure(error, { stage: 'credential_storage' })
      }
    }
    try {
      await standardAuthorization(server, binding, generation, options)
      return { method: 'oauth-2.1' }
    } catch (error) {
      const failure = normalizeMcpOAuthFailure(error)
      // The audited same-origin flow is allowed only for hosts the tenant profile declares, and
      // only when standards discovery was blocked before presenting a page. It is never a generic
      // OAuth recovery path, and the public app declares no such hosts at all.
      if (!isSameOriginBrowserFallbackEligible(server, failure)) throw failure
      await browserFallback(server, binding, generation, options, failure.stage)
      return { method: 'same-origin-browser' }
    }
  }

  function clear(server) {
    const binding = bindingFor(server)
    advanceGeneration(binding)
    keychain.remove(binding)
    failures.delete(binding.account)
  }

  return Object.freeze({ authorize, clear, accessToken, applyAuthorization, bindingFor })
}
