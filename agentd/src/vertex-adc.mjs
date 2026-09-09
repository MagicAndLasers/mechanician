// Google Application Default Credentials (ADC) for the Claude-on-Vertex route (FR-103 M2).
//
// Provides an in-app loopback OAuth flow that obtains a user's Google credentials with no `gcloud`
// requirement, plus a refresh-storm guard so a RAPT-expired grant cannot drive a tight network
// loop. Two route-specific constraints shape the implementation:
//   1. The ADC file is written to a Mechanician-controlled, per-route path (not the shared
//      ~/.config/gcloud location), so a tenant build never clobbers the user's real gcloud ADC. The
//      daemon points GOOGLE_APPLICATION_CREDENTIALS at this file for the Claude engine child.
//   2. The browser is opened by the app: agentd emits the auth URL and Swift opens it, matching
//      Mechanician's existing loopback-OAuth boundary.
//
// Exposed as a factory so tests can inject a clock + fetch and a temp ADC path.

import { createServer } from 'node:http'
import {
  chmodSync, writeFileSync, mkdirSync, readFileSync, existsSync, unlinkSync, renameSync, statSync,
} from 'node:fs'
import { dirname } from 'node:path'
import { createHash, randomBytes } from 'node:crypto'

// Google's well-known OAuth2 client credentials — the SAME public values the gcloud CLI uses. These
// are NOT secrets (installed-app client). See developers.google.com/identity/protocols/oauth2/native-app.
export const GOOGLE_CLIENT_ID = '32555940559.apps.googleusercontent.com'
export const GOOGLE_CLIENT_SECRET = 'ZmssLNjJy2998hD4CTg2ejr2'
const SCOPES = [
  'https://www.googleapis.com/auth/cloud-platform',
  'https://www.googleapis.com/auth/userinfo.email',
]
const TOKEN_URL = 'https://oauth2.googleapis.com/token'
const AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth'
const USERINFO_URL = 'https://www.googleapis.com/oauth2/v1/userinfo'

// Guard thresholds (see refreshTokens). Normal access tokens live ~3600s; a degenerate <30s token
// means the grant needs reauth and must NOT be cached (callers would re-refresh instantly).
const MIN_VALID_TTL_MS = 30_000
const REFRESH_MARGIN_MS = 300_000     // reuse a cached token until <5min remains
const MAX_BACKOFF_MS = 60_000

const DEFINITIVE_DISCONNECT_REASONS = new Set([
  'no_credentials',
  'revoked',
  'reauth_required',
])

/// Turn a best-effort Google token probe into product account state. A timeout, DNS failure, or
/// temporary Google outage is not evidence that a refresh token was revoked. Keep an on-disk ADC
/// credential usable in that case and let the actual Claude/Vertex operation provide stronger
/// evidence. Only missing credentials and definitive grant failures require reconnect.
export function resolveVertexAuthState(status, hasCredentials = false) {
  if (status?.authenticated === true) {
    return { loggedIn: true, verification: 'verified', reason: null }
  }
  const reason = typeof status?.reason === 'string' ? status.reason : 'unknown'
  if (DEFINITIVE_DISCONNECT_REASONS.has(reason) || !hasCredentials) {
    return { loggedIn: false, verification: 'disconnected', reason }
  }
  return { loggedIn: true, verification: 'deferred', reason }
}

export function createVertexAdc({
  adcPath,
  fetchImpl = globalThis.fetch,
  now = () => Date.now(),
  clientId = GOOGLE_CLIENT_ID,
  clientSecret = GOOGLE_CLIENT_SECRET,
  log = () => {},
} = {}) {
  if (!adcPath) throw new Error('createVertexAdc requires an adcPath')

  // ── Refresh guard state (per instance) ──
  let cachedSuccess = null        // { ok:true, tokens, expiresAt }
  let cachedEmail = null          // { token, email }
  let inFlightRefresh = null
  let lastFailure = null          // { ok:false, reason, ... }
  let failureBackoffUntil = 0
  let consecutiveFailures = 0
  let lastAdcMtimeMs = 0

  function resetGuard() {
    cachedSuccess = null
    cachedEmail = null
    inFlightRefresh = null
    lastFailure = null
    failureBackoffUntil = 0
    consecutiveFailures = 0
  }

  /// Sync, no-network: is there a usable ADC credential on disk? Used for the daemon's initial
  /// loggedIn signal at boot (mirrors hasClaudeLogin's synchronous status check).
  function hasCredentials() {
    return readCredentials() !== null
  }

  function readCredentials() {
    try {
      const creds = JSON.parse(readFileSync(adcPath, 'utf-8'))
      return creds && creds.refresh_token ? creds : null
    } catch {
      return null
    }
  }

  function writeCredentials(update, { preserveExisting = true } = {}) {
    const incoming = typeof update === 'string'
      ? { refresh_token: update }
      : update && typeof update === 'object' ? update : {}
    const existing = preserveExisting ? readCredentials() : null
    const refreshToken = nonEmptyString(incoming.refresh_token)
      || nonEmptyString(existing?.refresh_token)
    if (!refreshToken) {
      throw new Error('Google did not return a refresh token')
    }
    const adcDirectory = dirname(adcPath)
    mkdirSync(adcDirectory, { recursive: true, mode: 0o700 })
    try { chmodSync(adcDirectory, 0o700) } catch { /* best effort on an existing directory */ }
    const creds = {
      account: nonEmptyString(incoming.account) || nonEmptyString(existing?.account) || '',
      client_id: nonEmptyString(incoming.client_id)
        || nonEmptyString(existing?.client_id) || clientId,
      client_secret: nonEmptyString(incoming.client_secret)
        || nonEmptyString(existing?.client_secret) || clientSecret,
      refresh_token: refreshToken,
      type: 'authorized_user',
      universe_domain: nonEmptyString(incoming.universe_domain)
        || nonEmptyString(existing?.universe_domain) || 'googleapis.com',
    }
    // RAPT is Google's proof that a Workspace user recently reauthenticated. It is part of the
    // authorized-user ADC schema and must survive both an atomic rewrite and a rotated refresh
    // token. quota_project_id is likewise standard ADC metadata that should not disappear merely
    // because Mechanician refreshed the credential.
    const raptToken = nonEmptyString(incoming.rapt_token)
      || nonEmptyString(existing?.rapt_token)
    const quotaProjectId = nonEmptyString(incoming.quota_project_id)
      || nonEmptyString(existing?.quota_project_id)
    if (raptToken) creds.rapt_token = raptToken
    if (quotaProjectId) creds.quota_project_id = quotaProjectId
    // Never leave a partially written refresh token behind if the process exits mid-write. A fresh
    // owner-only file in the same directory can be renamed atomically over an existing ADC file (or
    // symlink) without following the destination.
    const temporaryPath = `${adcPath}.${process.pid}.${randomBytes(8).toString('hex')}.tmp`
    try {
      writeFileSync(temporaryPath, JSON.stringify(creds, null, 2), {
        mode: 0o600,
        flag: 'wx',
      })
      renameSync(temporaryPath, adcPath)
      try { chmodSync(adcPath, 0o600) } catch { /* already created owner-only */ }
    } finally {
      try { if (existsSync(temporaryPath)) unlinkSync(temporaryPath) } catch { /* ignore */ }
    }
  }

  function logout() {
    resetGuard()
    try { if (existsSync(adcPath)) unlinkSync(adcPath) } catch { /* ignore */ }
  }

  /// The single choke point for every refresh_token grant. Serves a still-valid cached token with no
  /// network call, coalesces concurrent refreshes, treats an absurdly small TTL as reauth-required
  /// (not cache-and-loop), and backs off exponentially on repeated failure.
  async function refreshTokens(callsite) {
    // A fresh interactive login (or an external gcloud login) changes the file mtime — drop cache.
    try {
      const m = statSync(adcPath).mtimeMs
      if (m !== lastAdcMtimeMs) { resetGuard(); lastAdcMtimeMs = m }
    } catch { /* missing file — network refresh returns no_credentials */ }

    const t = now()
    if (cachedSuccess && cachedSuccess.expiresAt - t > REFRESH_MARGIN_MS) return cachedSuccess
    if (lastFailure && t < failureBackoffUntil) return lastFailure
    if (inFlightRefresh) return inFlightRefresh

    inFlightRefresh = (async () => {
      try {
        let result
        try {
          result = await refreshTokensNetwork(callsite)
        } catch (err) {
          // Credential verification is a best-effort network probe. A malformed proxy response or
          // an unexpected fetch implementation must not escape into agentd's process-wide
          // unhandled-rejection drain and take every in-flight Vertex turn down with it.
          const detail = String(err?.message || err || 'unexpected refresh failure').slice(0, 256)
          result = { ok: false, reason: 'unknown', error: detail }
          log(`[vertex-adc] refresh (${callsite}) failed unexpectedly: ${detail}`)
        }
        if (result.ok) {
          const ttlMs = (result.tokens.expires_in || 0) * 1000
          if (ttlMs < MIN_VALID_TTL_MS) {
            consecutiveFailures++
            failureBackoffUntil = now() + Math.min(MAX_BACKOFF_MS, 1000 * 2 ** consecutiveFailures)
            cachedSuccess = null
            lastFailure = { ok: false, reason: 'reauth_required', error: 'degenerate_ttl',
              errorSubtype: `expires_in=${result.tokens.expires_in}` }
            log(`[vertex-adc] refresh (${callsite}) degenerate TTL — reauth_required`)
            return lastFailure
          }
          cachedSuccess = result
          lastFailure = null
          consecutiveFailures = 0
          failureBackoffUntil = 0
          return result
        }
        consecutiveFailures++
        failureBackoffUntil = now() + Math.min(MAX_BACKOFF_MS, 1000 * 2 ** consecutiveFailures)
        lastFailure = result
        cachedSuccess = null
        return result
      } finally {
        inFlightRefresh = null
      }
    })()
    return inFlightRefresh
  }

  // Raw network refresh (no caching). Google returns invalid_grant for BOTH a revoked token and a
  // RAPT requirement — only the latter carries error_subtype:"invalid_rapt", so we classify it to let
  // the UI warn before a turn dies.
  async function refreshTokensNetwork(callsite) {
    const creds = readCredentials()
    if (!creds) return { ok: false, reason: 'no_credentials' }

    const params = new URLSearchParams({
      client_id: creds.client_id || clientId,
      client_secret: creds.client_secret || clientSecret,
      refresh_token: creds.refresh_token,
      grant_type: 'refresh_token',
    })
    // Google Workspace session controls return invalid_rapt/rapt_required unless the proof from a
    // prior interactive reauthentication is supplied on subsequent refreshes.
    if (nonEmptyString(creds.rapt_token)) params.set('rapt', creds.rapt_token)

    let resp
    try {
      resp = await fetchImpl(TOKEN_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: params.toString(),
        signal: AbortSignal.timeout(10_000),
      })
    } catch (err) {
      return { ok: false, reason: 'network', error: err?.message || String(err) }
    }

    if (!resp.ok) {
      let error, errorSubtype
      try {
        const body = await resp.json()
        error = body.error
        errorSubtype = body.error_subtype
        if (!errorSubtype && /rapt/i.test(body.error_description || '')) errorSubtype = 'invalid_rapt'
      } catch { /* body not JSON */ }
      let reason = 'unknown'
      if (/rapt/i.test(errorSubtype || '')) reason = 'reauth_required'
      else if (error === 'invalid_grant') reason = 'revoked'
      log(`[vertex-adc] refresh (${callsite}) failed reason=${reason} http=${resp.status}`
        + ` subtype=${errorSubtype || '-'}`)
      return { ok: false, reason, error, errorSubtype, httpStatus: resp.status }
    }

    let tokens
    try {
      tokens = await resp.json()
    } catch {
      log(`[vertex-adc] refresh (${callsite}) returned an invalid success response`)
      return { ok: false, reason: 'unknown', error: 'invalid_token_response',
        httpStatus: resp.status }
    }
    if (!tokens || typeof tokens.access_token !== 'string' || !tokens.access_token) {
      log(`[vertex-adc] refresh (${callsite}) success response omitted access_token`)
      return { ok: false, reason: 'unknown', error: 'missing_access_token',
        httpStatus: resp.status }
    }
    // OAuth servers may rotate refresh credentials. Keep the returned value instead of reporting a
    // successful turn while leaving the old, soon-to-fail credential on disk. Preserve an existing
    // RAPT proof unless Google explicitly returns a newer one.
    const rotatedRefreshToken = nonEmptyString(tokens.refresh_token)
    const refreshedRaptToken = nonEmptyString(tokens.rapt_token)
    if ((rotatedRefreshToken && rotatedRefreshToken !== creds.refresh_token)
        || (refreshedRaptToken && refreshedRaptToken !== creds.rapt_token)) {
      writeCredentials({
        refresh_token: rotatedRefreshToken || creds.refresh_token,
        ...(refreshedRaptToken ? { rapt_token: refreshedRaptToken } : {}),
      })
      try { lastAdcMtimeMs = statSync(adcPath).mtimeMs } catch { lastAdcMtimeMs = 0 }
      log(`[vertex-adc] refresh (${callsite}) persisted rotated credential metadata`)
    }
    const expiresAt = now() + (tokens.expires_in || 3600) * 1000
    return { ok: true, tokens, expiresAt }
  }

  /// Refresh + verify: are the current ADC credentials usable? Returns { authenticated, email?, reason? }.
  async function checkAuth() {
    try {
      const result = await refreshTokens('checkAuth')
      if (!result.ok) {
        // Keep only the bounded classification needed by the native account surface. Google body
        // prose and token material must never cross the daemon protocol, while invalid_rapt and
        // the status code are the evidence that distinguishes reauthentication from first-time
        // setup.
        const subtype = typeof result.errorSubtype === 'string'
          && ['invalid_rapt', 'rapt_required'].includes(result.errorSubtype.toLowerCase())
          ? result.errorSubtype.toLowerCase() : null
        return {
          authenticated: false,
          reason: result.reason,
          ...(subtype ? { errorSubtype: subtype } : {}),
          ...(Number.isInteger(result.httpStatus)
            && result.httpStatus >= 400 && result.httpStatus <= 599
            ? { httpStatus: result.httpStatus } : {}),
        }
      }
      let email
      if (cachedEmail && cachedEmail.token === result.tokens.access_token) {
        email = cachedEmail.email
      } else {
        email = await getUserEmail(result.tokens.access_token)
        cachedEmail = { token: result.tokens.access_token, email }
      }
      return { authenticated: true, email, expiresAt: result.expiresAt }
    } catch (err) {
      // Keep this public probe total: callers use it during optional daemon startup discovery and
      // account refresh. The real Claude/Vertex operation remains the authoritative verifier.
      log(`[vertex-adc] checkAuth failed unexpectedly: ${String(err?.message || err).slice(0, 256)}`)
      return { authenticated: false, reason: 'unknown' }
    }
  }

  async function getAccessToken() {
    const result = await refreshTokens('getAccessToken')
    return result.ok ? result.tokens.access_token : null
  }

  async function getIdentityToken() {
    const result = await refreshTokens('getIdentityToken')
    return result.ok ? result.tokens.id_token || null : null
  }

  async function getUserEmail(accessToken) {
    try {
      const resp = await fetchImpl(USERINFO_URL, { headers: { Authorization: `Bearer ${accessToken}` } })
      if (resp.ok) return (await resp.json()).email
    } catch { /* non-critical */ }
    return undefined
  }

  async function exchangeCode(code, redirectUri, codeVerifier) {
    const params = new URLSearchParams({
      code, client_id: clientId, client_secret: clientSecret,
      redirect_uri: redirectUri, grant_type: 'authorization_code', code_verifier: codeVerifier,
    })
    const resp = await fetchImpl(TOKEN_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: params.toString(),
    })
    if (!resp.ok) throw new Error(`Token exchange failed: ${await resp.text()}`)
    return resp.json()
  }

  function startRedirectServer(expectedState) {
    return new Promise((resolve, reject) => {
      let resolveCode, rejectCode
      const codePromise = new Promise((res, rej) => { resolveCode = res; rejectCode = rej })
      const server = createServer((req, res) => {
        const url = new URL(req.url || '/', 'http://127.0.0.1')
        const code = url.searchParams.get('code')
        const error = url.searchParams.get('error')
        const state = url.searchParams.get('state')
        const respond = (status, title, detail) => {
          res.writeHead(status, {
            'Content-Type': 'text/html; charset=utf-8',
            'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'",
            'X-Content-Type-Options': 'nosniff',
          })
          res.end(resultPage(title, detail))
        }
        // A random process can guess the loopback port. Do not consume or reject the real flow for
        // an unrelated request; only a callback carrying the nonce sent to Google may settle it.
        if (state !== expectedState) {
          respond(400, 'Authentication not accepted', 'This callback did not match the active sign-in request.')
          return
        }
        if (error) {
          respond(200, 'Authentication failed', error)
          rejectCode(new Error(`Authentication failed: ${error}`)); return
        }
        if (code) {
          respond(200, 'Authenticated', 'You can close this tab and return to Mechanician.')
          resolveCode(code); return
        }
        respond(400, 'Authentication not accepted', 'Google did not provide an authorization code.')
      })
      server.once('error', (error) => {
        rejectCode(error)
        reject(error)
      })
      server.listen(0, '127.0.0.1', () => {
        const addr = server.address()
        if (addr && typeof addr === 'object') resolve({ port: addr.port, server, codePromise })
        else reject(new Error('Failed to start ADC redirect server'))
      })
    })
  }

  /// The full loopback OAuth flow: start a localhost server, hand the consent URL to `onAuthUrl` (the
  /// app opens the browser), capture the redirect, exchange the code, and write ADC. Returns
  /// { authenticated, email }.
  async function runOAuthFlow({ onAuthUrl, timeoutMs = 300_000 } = {}) {
    const state = randomBytes(16).toString('hex')
    const codeVerifier = randomBytes(64).toString('base64url')
    const codeChallenge = createHash('sha256').update(codeVerifier).digest('base64url')
    const { port, server, codePromise } = await startRedirectServer(state)
    const redirectUri = `http://127.0.0.1:${port}`
    const authUrl = new URL(AUTH_URL)
    authUrl.searchParams.set('client_id', clientId)
    authUrl.searchParams.set('redirect_uri', redirectUri)
    authUrl.searchParams.set('response_type', 'code')
    authUrl.searchParams.set('scope', SCOPES.join(' '))
    authUrl.searchParams.set('access_type', 'offline')
    authUrl.searchParams.set('prompt', 'consent')
    authUrl.searchParams.set('state', state)
    authUrl.searchParams.set('code_challenge', codeChallenge)
    authUrl.searchParams.set('code_challenge_method', 'S256')

    let timeout
    try {
      if (typeof onAuthUrl === 'function') onAuthUrl(authUrl.toString())
      const code = await Promise.race([
        codePromise,
        new Promise((_, reject) => {
          timeout = setTimeout(() => reject(new Error('Authentication timed out')), timeoutMs)
        }),
      ])
      const tokens = await exchangeCode(code, redirectUri, codeVerifier)
      if (!tokens.refresh_token) throw new Error('Google did not return a refresh token')
      // A new authorization grant replaces any stale proof from the old Google session. Persist a
      // RAPT token if the endpoint supplies one; otherwise the next policy-driven reauthentication
      // is intentionally interactive.
      writeCredentials(tokens, { preserveExisting: false })
      // Fresh credentials clear any pre-reauth backoff. Seed the cache with the exchange response so
      // agentd's immediate account_reload validates without needlessly refreshing a brand-new token.
      resetGuard()
      const expiresAt = now() + (tokens.expires_in || 3600) * 1000
      cachedSuccess = { ok: true, tokens, expiresAt }
      try { lastAdcMtimeMs = statSync(adcPath).mtimeMs } catch { lastAdcMtimeMs = 0 }
      const email = await getUserEmail(tokens.access_token)
      cachedEmail = { token: tokens.access_token, email }
      return { authenticated: true, email }
    } finally {
      if (timeout) clearTimeout(timeout)
      server.close()
    }
  }

  return {
    adcPath,
    hasCredentials, readCredentials, writeCredentials, logout,
    refreshTokens, checkAuth, getAccessToken, getIdentityToken, runOAuthFlow, resetGuard,
  }
}

function resultPage(title, detail) {
  const safeTitle = escapeHTML(title)
  const safeDetail = escapeHTML(detail)
  return `<!DOCTYPE html><html><head><meta charset="utf-8"><title>Mechanician</title></head>
<body style="font-family:-apple-system,sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#1a1a2e;color:#e8e8e8;">
<div style="text-align:center;"><h1>${safeTitle}</h1><p>${safeDetail}</p></div></body></html>`
}

function escapeHTML(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}

function nonEmptyString(value) {
  return typeof value === 'string' && value.trim() ? value : null
}
