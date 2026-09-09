// FR-103 M2: Claude-on-Vertex route env + ADC credential handling.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, existsSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { createHash } from 'node:crypto'
import {
  resolveAnthropicAuthMode, vertexRouteEnvironment, scrubUnsupportedClaudeRoutes,
  directClaudeEnvironment, VERTEX_ROUTE_KEEP,
} from '../src/claude-secure-spawn.mjs'
import { createVertexAdc, resolveVertexAuthState } from '../src/vertex-adc.mjs'

function tempAdcPath() {
  return join(mkdtempSync(join(tmpdir(), 'vertex-adc-')), 'gcloud', 'application_default_credentials.json')
}

test('managed catalog fetches use the initialized profile-scoped Vertex ADC', () => {
  const agentdSource = readFileSync(new URL('../src/agentd.mjs', import.meta.url), 'utf8')
  assert.match(agentdSource, /await vertexAdc\.getIdentityToken\(\)/)
  assert.match(agentdSource, /vertexAdc\.refreshTokens\('turn-preflight'\)/)
  assert.match(
    agentdSource,
    /if \(!await preflightAnthropicTurn\(ctx\)\)[\s\S]{0,1500}await streamOnce\(/,
    'a failed credential preflight must terminalize before the SDK query starts',
  )
  // Stop is wired to `ctx.abortController`, which does not exist until the query is prepared, so an
  // interrupt landing during this preflight has to terminalize here too. On Vertex the preflight is
  // a live token refresh, which made that window wide enough to look like a dead Stop button on the
  // managed enterprise build (0.26.6). Behaviour is covered by claude-interrupt-preflight.test.mjs;
  // this keeps the ORDER visible in the one place the ordering is easy to undo by accident.
  assert.match(
    agentdSource,
    /if \(!await preflightAnthropicTurn\(ctx\)\)[\s\S]{0,1500}if \(ctx\.interrupted\)[\s\S]{0,600}await streamOnce\(/,
    'an interrupt during the credential preflight must terminalize before the SDK query starts',
  )
  assert.doesNotMatch(agentdSource, /\bVERTEX_ADC\b/)
})

// ── route env helpers ──

test('resolveAnthropicAuthMode maps MECHANICIAN_AUTH', () => {
  assert.equal(resolveAnthropicAuthMode({ MECHANICIAN_AUTH: 'subscription' }), 'subscription')
  assert.equal(resolveAnthropicAuthMode({ MECHANICIAN_AUTH: 'vertex' }), 'vertex')
  assert.equal(resolveAnthropicAuthMode({ MECHANICIAN_AUTH: 'apikey' }), 'apikey')
  assert.equal(resolveAnthropicAuthMode({}), 'apikey')          // absent ⇒ apikey (unchanged default)
})

test('vertexRouteEnvironment builds the three selectors, defaults region to global', () => {
  assert.deepEqual(vertexRouteEnvironment({ projectId: 'acme-claude-code', region: 'global' }), {
    CLAUDE_CODE_USE_VERTEX: '1',
    ANTHROPIC_VERTEX_PROJECT_ID: 'acme-claude-code',
    CLOUD_ML_REGION: 'global',
  })
  assert.equal(vertexRouteEnvironment({ projectId: 'p' }).CLOUD_ML_REGION, 'global')
  assert.equal(vertexRouteEnvironment({ projectId: ' p ', region: ' us-east5 ' }).ANTHROPIC_VERTEX_PROJECT_ID, 'p')
  assert.equal(vertexRouteEnvironment({ projectId: ' p ', region: ' us-east5 ' }).CLOUD_ML_REGION, 'us-east5')
  assert.equal(vertexRouteEnvironment({ projectId: '   ' }), null)
  assert.equal(vertexRouteEnvironment({}), null)                // no project ⇒ unconfigured
  assert.equal(vertexRouteEnvironment(), null)
})

test('scrub strips enterprise selectors by default but keeps sanctioned ones', () => {
  const base = {
    CLAUDE_CODE_USE_VERTEX: '1',
    ANTHROPIC_VERTEX_PROJECT_ID: 'p',
    CLOUD_ML_REGION: 'global',
    GOOGLE_APPLICATION_CREDENTIALS: '/private/adc.json',
    ANTHROPIC_VERTEX_BASE_URL: 'x',
    ANTHROPIC_BASE_URL: 'y',
    KEEPME: 'z',
  }
  assert.deepEqual(scrubUnsupportedClaudeRoutes({ ...base }), { KEEPME: 'z' })          // default: strip all
  assert.deepEqual(
    scrubUnsupportedClaudeRoutes({ ...base }, { keep: VERTEX_ROUTE_KEEP }),
    {
      CLAUDE_CODE_USE_VERTEX: '1',
      ANTHROPIC_VERTEX_PROJECT_ID: 'p',
      CLOUD_ML_REGION: 'global',
      GOOGLE_APPLICATION_CREDENTIALS: '/private/adc.json',
      KEEPME: 'z',
    })                                                                                   // Vertex keeps only its audited fields
})

test('directClaudeEnvironment strips secrets always, and Vertex env only when not kept', () => {
  const env = {
    ANTHROPIC_API_KEY: 'k', CLAUDE_CODE_USE_VERTEX: '1',
    ANTHROPIC_VERTEX_PROJECT_ID: 'p', CLOUD_ML_REGION: 'global',
    GOOGLE_APPLICATION_CREDENTIALS: '/private/adc.json',
  }
  const stripped = directClaudeEnvironment({ ...env })
  assert.equal(stripped.ANTHROPIC_API_KEY, undefined)
  assert.equal(stripped.CLAUDE_CODE_USE_VERTEX, undefined)
  assert.equal(stripped.ANTHROPIC_VERTEX_PROJECT_ID, undefined)
  assert.equal(stripped.GOOGLE_APPLICATION_CREDENTIALS, undefined)
  const kept = directClaudeEnvironment({ ...env }, { keep: VERTEX_ROUTE_KEEP })
  assert.equal(kept.ANTHROPIC_API_KEY, undefined)                                       // secret always gone
  assert.equal(kept.CLAUDE_CODE_USE_VERTEX, '1')                                        // route switch kept
  assert.equal(kept.ANTHROPIC_VERTEX_PROJECT_ID, 'p')                                   // project/region ride along
  assert.equal(kept.CLOUD_ML_REGION, 'global')
  assert.equal(kept.GOOGLE_APPLICATION_CREDENTIALS, '/private/adc.json')
})

// ── ADC credential file ──

test('write/read/hasCredentials/logout round-trip on an isolated path', () => {
  const adcPath = tempAdcPath()
  const adc = createVertexAdc({ adcPath })
  assert.equal(adc.hasCredentials(), false)
  adc.writeCredentials('refresh-abc')
  assert.ok(existsSync(adcPath))
  assert.equal(statSync(adcPath).mode & 0o777, 0o600)
  assert.equal(statSync(dirname(adcPath)).mode & 0o777, 0o700)
  const creds = adc.readCredentials()
  assert.equal(creds.refresh_token, 'refresh-abc')
  assert.equal(creds.type, 'authorized_user')
  assert.equal(creds.client_id, '32555940559.apps.googleusercontent.com')
  assert.equal(adc.hasCredentials(), true)
  adc.logout()
  assert.equal(existsSync(adcPath), false)
  assert.equal(adc.hasCredentials(), false)
})

test('credential rewrites preserve standard RAPT and quota metadata', () => {
  const adcPath = tempAdcPath()
  const adc = createVertexAdc({ adcPath })
  adc.writeCredentials({
    refresh_token: 'refresh-original',
    rapt_token: 'rapt-proof',
    quota_project_id: 'quota-project',
  })

  adc.writeCredentials('refresh-replacement')

  assert.deepEqual(
    {
      refresh_token: adc.readCredentials().refresh_token,
      rapt_token: adc.readCredentials().rapt_token,
      quota_project_id: adc.readCredentials().quota_project_id,
    },
    {
      refresh_token: 'refresh-replacement',
      rapt_token: 'rapt-proof',
      quota_project_id: 'quota-project',
    },
  )
})

test('logging out one profile route leaves another route credential untouched', () => {
  const firstPath = tempAdcPath()
  const secondPath = tempAdcPath()
  const first = createVertexAdc({ adcPath: firstPath })
  const second = createVertexAdc({ adcPath: secondPath })
  first.writeCredentials('first-route-refresh')
  second.writeCredentials('second-route-refresh')

  first.logout()

  assert.equal(first.hasCredentials(), false)
  assert.equal(second.hasCredentials(), true)
  assert.equal(second.readCredentials().refresh_token, 'second-route-refresh')
})

test('a credentials file without a refresh_token is not usable', () => {
  const adcPath = tempAdcPath()
  mkdirSync(dirname(adcPath), { recursive: true })
  writeFileSync(adcPath, JSON.stringify({ type: 'authorized_user' }))
  const adc = createVertexAdc({ adcPath })
  assert.equal(adc.hasCredentials(), false)
  assert.equal(adc.readCredentials(), null)
})

// ── refresh guard ──

function fakeFetch(responses) {
  // responses: { token: () => ({ok, status, json/text}), userinfo: () => ({...}) }
  let tokenCalls = 0
  const impl = async (url) => {
    if (String(url).includes('oauth2.googleapis.com/token')) { tokenCalls++; return responses.token() }
    if (String(url).includes('userinfo')) return responses.userinfo ? responses.userinfo() : { ok: true, json: async () => ({ email: 'u@acme.com' }) }
    throw new Error('unexpected url ' + url)
  }
  impl.tokenCalls = () => tokenCalls
  return impl
}

test('refreshTokens returns no_credentials when the ADC file is absent', async () => {
  const adc = createVertexAdc({ adcPath: tempAdcPath(), fetchImpl: async () => { throw new Error('should not fetch') } })
  const r = await adc.refreshTokens('test')
  assert.equal(r.ok, false)
  assert.equal(r.reason, 'no_credentials')
})

test('transient Vertex verification failures preserve a configured ADC account', () => {
  assert.deepEqual(
    resolveVertexAuthState({ authenticated: false, reason: 'network' }, true),
    { loggedIn: true, verification: 'deferred', reason: 'network' },
  )
  assert.deepEqual(
    resolveVertexAuthState({ authenticated: false, reason: 'unknown' }, true),
    { loggedIn: true, verification: 'deferred', reason: 'unknown' },
  )
})

test('definitive Vertex grant failures require reconnect', () => {
  for (const reason of ['no_credentials', 'revoked', 'reauth_required']) {
    assert.deepEqual(
      resolveVertexAuthState({ authenticated: false, reason }, true),
      { loggedIn: false, verification: 'disconnected', reason },
    )
  }
  assert.equal(
    resolveVertexAuthState({ authenticated: false, reason: 'network' }, false).loggedIn,
    false,
  )
  assert.deepEqual(
    resolveVertexAuthState({ authenticated: true }, false),
    { loggedIn: true, verification: 'verified', reason: null },
  )
})

test('a valid refresh caches — a second call within margin makes no network request', async () => {
  const adcPath = tempAdcPath()
  const clock = { t: 1_000_000 }
  const fetchImpl = fakeFetch({ token: () => ({ ok: true, json: async () => ({ access_token: 'AT', expires_in: 3600 }) }) })
  const adc = createVertexAdc({ adcPath, fetchImpl, now: () => clock.t })
  adc.writeCredentials('refresh-abc')
  const r1 = await adc.refreshTokens('a')
  assert.equal(r1.ok, true)
  assert.equal(r1.tokens.access_token, 'AT')
  const r2 = await adc.refreshTokens('b')        // still fresh (margin 5min, TTL 1h)
  assert.equal(r2.tokens.access_token, 'AT')
  assert.equal(fetchImpl.tokenCalls(), 1, 'cached token must not trigger a second refresh')
})

test('getIdentityToken reuses the guarded refresh result for managed Cloud Run catalogs', async () => {
  const adcPath = tempAdcPath()
  const fetchImpl = fakeFetch({ token: () => ({
    ok: true,
    json: async () => ({ access_token: 'AT', id_token: 'IDT', expires_in: 3600 }),
  }) })
  const adc = createVertexAdc({ adcPath, fetchImpl, now: () => 1_000_000 })
  adc.writeCredentials('refresh-abc')
  assert.equal(await adc.getIdentityToken(), 'IDT')
  assert.equal(await adc.getIdentityToken(), 'IDT')
  assert.equal(fetchImpl.tokenCalls(), 1)
})

test('a degenerate (<30s) TTL is treated as reauth_required and not cached', async () => {
  const adcPath = tempAdcPath()
  const fetchImpl = fakeFetch({ token: () => ({ ok: true, json: async () => ({ access_token: 'AT', expires_in: 1 }) }) })
  const adc = createVertexAdc({ adcPath, fetchImpl, now: () => 5_000 })
  adc.writeCredentials('refresh-abc')
  const r = await adc.refreshTokens('a')
  assert.equal(r.ok, false)
  assert.equal(r.reason, 'reauth_required')
})

test('checkAuth preserves only bounded invalid_rapt evidence for native reauthentication', async () => {
  const adcPath = tempAdcPath()
  const rapt = createVertexAdc({ adcPath, fetchImpl: fakeFetch({
    token: () => ({ ok: false, status: 400, json: async () => ({ error: 'invalid_grant', error_subtype: 'invalid_rapt' }) }) }) })
  rapt.writeCredentials('r')
  assert.deepEqual(await rapt.checkAuth(), {
    authenticated: false,
    reason: 'reauth_required',
    errorSubtype: 'invalid_rapt',
    httpStatus: 400,
  })

  const adcPath2 = tempAdcPath()
  const revoked = createVertexAdc({ adcPath: adcPath2, fetchImpl: fakeFetch({
    token: () => ({ ok: false, status: 400, json: async () => ({ error: 'invalid_grant' }) }) }) })
  revoked.writeCredentials('r')
  assert.deepEqual(await revoked.checkAuth(), {
    authenticated: false,
    reason: 'revoked',
    httpStatus: 400,
  })
})

test('checkAuth never forwards an unrecognized provider error subtype', async () => {
  const adcPath = tempAdcPath()
  const adc = createVertexAdc({ adcPath, fetchImpl: fakeFetch({
    token: () => ({
      ok: false,
      status: 400,
      json: async () => ({
        error: 'invalid_grant',
        error_subtype: 'provider_controlled_detail',
      }),
    }),
  }) })
  adc.writeCredentials('r')

  assert.deepEqual(await adc.checkAuth(), {
    authenticated: false,
    reason: 'revoked',
    httpStatus: 400,
  })
})

test('refresh sends a stored RAPT proof and persists rotated credentials', async () => {
  const adcPath = tempAdcPath()
  let tokenRequest
  const fetchImpl = async (url, options = {}) => {
    if (!String(url).includes('oauth2.googleapis.com/token')) {
      throw new Error(`unexpected url ${url}`)
    }
    tokenRequest = new URLSearchParams(options.body)
    return {
      ok: true,
      status: 200,
      json: async () => ({
        access_token: 'access-token',
        refresh_token: 'refresh-rotated',
        rapt_token: 'rapt-rotated',
        expires_in: 3600,
      }),
    }
  }
  const adc = createVertexAdc({ adcPath, fetchImpl, now: () => 1_000_000 })
  adc.writeCredentials({
    refresh_token: 'refresh-original',
    rapt_token: 'rapt-original',
    quota_project_id: 'quota-project',
  })

  const result = await adc.refreshTokens('rotation')

  assert.equal(result.ok, true)
  assert.equal(tokenRequest.get('rapt'), 'rapt-original')
  assert.equal(adc.readCredentials().refresh_token, 'refresh-rotated')
  assert.equal(adc.readCredentials().rapt_token, 'rapt-rotated')
  assert.equal(adc.readCredentials().quota_project_id, 'quota-project')
})

test('checkAuth reports authenticated + email on a valid grant', async () => {
  const adcPath = tempAdcPath()
  const fetchImpl = fakeFetch({
    token: () => ({ ok: true, json: async () => ({ access_token: 'AT', expires_in: 3600 }) }),
    userinfo: () => ({ ok: true, json: async () => ({ email: 'employee@acme.com' }) }),
  })
  const adc = createVertexAdc({ adcPath, fetchImpl, now: () => 1_000_000 })
  adc.writeCredentials('refresh-abc')
  const status = await adc.checkAuth()
  assert.equal(status.authenticated, true)
  assert.equal(status.email, 'employee@acme.com')
})

test('a malformed successful token response cannot reject the startup auth probe', async () => {
  const adcPath = tempAdcPath()
  const fetchImpl = fakeFetch({
    token: () => ({
      ok: true,
      status: 200,
      json: async () => { throw new SyntaxError('proxy returned HTML') },
    }),
  })
  const adc = createVertexAdc({ adcPath, fetchImpl, now: () => 1_000_000 })
  adc.writeCredentials('refresh-abc')

  assert.deepEqual(
    await adc.checkAuth(),
    { authenticated: false, reason: 'unknown' },
  )
  assert.equal(fetchImpl.tokenCalls(), 1)
})

test('a token response without an access token remains a deferred verification failure', async () => {
  const adcPath = tempAdcPath()
  const adc = createVertexAdc({
    adcPath,
    fetchImpl: fakeFetch({
      token: () => ({
        ok: true,
        status: 200,
        json: async () => ({ expires_in: 3600 }),
      }),
    }),
    now: () => 1_000_000,
  })
  adc.writeCredentials('refresh-abc')

  const status = await adc.checkAuth()
  assert.deepEqual(status, { authenticated: false, reason: 'unknown' })
  assert.equal(resolveVertexAuthState(status, true).loggedIn, true)
})

test('interactive OAuth restarts auth with PKCE and replaces stale RAPT credentials', async () => {
  const adcPath = tempAdcPath()
  let tokenRequest
  let tokenRequests = 0
  const fetchImpl = async (url, options = {}) => {
    if (String(url).includes('oauth2.googleapis.com/token')) {
      tokenRequests++
      tokenRequest = new URLSearchParams(options.body)
      return {
        ok: true,
        json: async () => ({
          access_token: 'access-from-code',
          refresh_token: 'refresh-from-code',
          expires_in: 3600,
        }),
      }
    }
    if (String(url).includes('userinfo')) {
      return { ok: true, json: async () => ({ email: 'employee@acme.com' }) }
    }
    throw new Error(`unexpected url ${url}`)
  }
  const adc = createVertexAdc({ adcPath, fetchImpl })
  adc.writeCredentials({
    refresh_token: 'stale-refresh',
    rapt_token: 'stale-rapt',
  })
  let resolveAuthUrl
  const authUrlPromise = new Promise((resolve) => { resolveAuthUrl = resolve })
  const flow = adc.runOAuthFlow({
    onAuthUrl: resolveAuthUrl,
    timeoutMs: 5_000,
  })

  const authUrl = new URL(await authUrlPromise)
  assert.equal(authUrl.hostname, 'accounts.google.com')
  assert.equal(authUrl.searchParams.get('code_challenge_method'), 'S256')
  assert.ok(authUrl.searchParams.get('code_challenge'))
  assert.equal(authUrl.searchParams.get('access_type'), 'offline')
  assert.equal(authUrl.searchParams.get('prompt'), 'consent')
  assert.ok(authUrl.searchParams.get('scope').split(' ')
    .includes('https://www.googleapis.com/auth/cloud-platform'))
  const redirect = new URL(authUrl.searchParams.get('redirect_uri'))
  assert.equal(redirect.hostname, '127.0.0.1')

  redirect.searchParams.set('code', 'attacker-code')
  redirect.searchParams.set('state', 'wrong-state')
  const rejected = await fetch(redirect)
  assert.equal(rejected.status, 400)

  redirect.searchParams.set('code', 'authorized-code')
  redirect.searchParams.set('state', authUrl.searchParams.get('state'))
  const accepted = await fetch(redirect)
  assert.equal(accepted.status, 200)

  const status = await flow
  assert.deepEqual(status, { authenticated: true, email: 'employee@acme.com' })
  assert.equal(adc.readCredentials().refresh_token, 'refresh-from-code')
  assert.equal(adc.readCredentials().rapt_token, undefined,
    'a fresh auth session must not preserve the rejected RAPT proof')
  assert.equal(tokenRequest.get('code'), 'authorized-code')
  const verifier = tokenRequest.get('code_verifier')
  assert.ok(verifier.length >= 43 && verifier.length <= 128)
  assert.equal(
    createHash('sha256').update(verifier).digest('base64url'),
    authUrl.searchParams.get('code_challenge'))
  const verified = await adc.checkAuth()
  assert.equal(verified.authenticated, true)
  assert.equal(tokenRequests, 1, 'account reload must reuse the fresh exchange token')
})
