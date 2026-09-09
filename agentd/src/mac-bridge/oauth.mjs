// OAuth 2.1 authorization server for the Mac Bridge MCP endpoint.
//
// Why a loopback server needs OAuth at all: the bridge runs Shortcuts and reads local data, so it
// is a code-execution surface for anything already running as this user. "It's only localhost" is
// not an access control — any process can reach 127.0.0.1. A bearer token bound to a registered
// client, plus a consent step the human actually sees, is what makes "which assistant is allowed to
// drive my Mac" answerable.
//
// In-memory by design: tokens die with the process. A restart forces every client to re-consent,
// which is the correct default for a tool that can run arbitrary automations, and it keeps this
// spike from inventing a credential store that would need its own threat model.

import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'

// Typed OAuth errors, so a client can tell a replayed code (invalid_grant, recoverable by starting
// a new authorization) from a server fault (server_error, not the client's problem). A generic
// Error would collapse both into server_error and strand a client that could have recovered.
import {
  InvalidGrantError,
  InvalidRequestError,
  InvalidTokenError,
} from '@modelcontextprotocol/sdk/server/auth/errors.js'

const AUTHORIZATION_CODE_TTL_MS = 60_000
// Short-lived on purpose, and overridable so refresh can be exercised in seconds rather than an
// hour. A client that never refreshes is indistinguishable from one that does until the first
// expiry, which is precisely the bug this makes testable.
const ACCESS_TOKEN_TTL_SECONDS = Number(process.env.MAC_BRIDGE_TOKEN_TTL_SECONDS || 60 * 60)

function token() {
  return randomBytes(32).toString('base64url')
}

function s256(verifier) {
  return createHash('sha256').update(verifier).digest('base64url')
}

/// Constant-time compare that cannot throw on a length mismatch.
function safeEqual(a, b) {
  const left = Buffer.from(String(a))
  const right = Buffer.from(String(b))
  if (left.length !== right.length) return false
  return timingSafeEqual(left, right)
}

export class MacBridgeOAuthProvider {
  /**
   * @param {object} options
   * @param {(request: {client: object, scopes: string[]}) => Promise<boolean>} options.requestConsent
   *   Asks the human. Returning false is a denial, not an error.
   * @param {() => number} [options.now]
   */
  constructor({ requestConsent, now = Date.now } = {}) {
    this.requestConsent = requestConsent
    this.now = now
    this.clients = new Map()
    this.codes = new Map()
    this.accessTokens = new Map()
    this.refreshTokens = new Map()

    const clients = this.clients
    this.clientsStore = {
      async getClient(clientId) { return clients.get(clientId) },
      async registerClient(client) {
        // Dynamic registration is open because every client still has to pass the consent gate
        // before it receives a token — registering is not authorization.
        clients.set(client.client_id, client)
        return client
      },
    }
  }

  /// Issued codes and tokens are process-lifetime only; this exists so tests need no clock control.
  purgeExpired() {
    const now = this.now()
    for (const [code, record] of this.codes) {
      if (record.expiresAt <= now) this.codes.delete(code)
    }
    for (const [value, record] of this.accessTokens) {
      if (record.expiresAt <= now) this.accessTokens.delete(value)
    }
  }

  async authorize(client, params, res) {
    const approved = await this.requestConsent({ client, scopes: params.scopes ?? [] })
    const redirect = new URL(params.redirectUri)
    if (!approved) {
      // A refusal is a normal OAuth outcome and must come back as a redirect, not a 500 — the
      // client needs to be able to tell "the human said no" from "the server broke".
      redirect.searchParams.set('error', 'access_denied')
      redirect.searchParams.set('error_description', 'The request was declined on this Mac.')
      if (params.state) redirect.searchParams.set('state', params.state)
      res.redirect(redirect.toString())
      return
    }
    const code = token()
    this.codes.set(code, {
      clientId: client.client_id,
      codeChallenge: params.codeChallenge,
      redirectUri: params.redirectUri,
      scopes: params.scopes ?? [],
      resource: params.resource?.toString(),
      expiresAt: this.now() + AUTHORIZATION_CODE_TTL_MS,
    })
    redirect.searchParams.set('code', code)
    if (params.state) redirect.searchParams.set('state', params.state)
    res.redirect(redirect.toString())
  }

  async challengeForAuthorizationCode(client, authorizationCode) {
    const record = this.codes.get(authorizationCode)
    if (!record || record.clientId !== client.client_id) {
      throw new InvalidGrantError('Unknown authorization code.')
    }
    return record.codeChallenge
  }

  async exchangeAuthorizationCode(client, authorizationCode, codeVerifier, redirectUri) {
    this.purgeExpired()
    const record = this.codes.get(authorizationCode)
    if (!record || record.clientId !== client.client_id) {
      throw new InvalidGrantError('Unknown authorization code.')
    }
    // Single use: replaying a code must not mint a second token even within its TTL.
    this.codes.delete(authorizationCode)
    if (record.expiresAt <= this.now()) throw new InvalidGrantError('Authorization code expired.')
    if (redirectUri !== undefined && redirectUri !== record.redirectUri) {
      throw new InvalidRequestError('Redirect URI does not match the authorization request.')
    }
    // PKCE is mandatory — a loopback redirect is readable by any local process, so the code alone
    // cannot be treated as a secret — but this method is NOT where it is normally checked. The SDK's
    // token handler calls `challengeForAuthorizationCode` and compares the challenge itself, then
    // passes `codeVerifier: undefined` here precisely because it already did. Re-deriving it here
    // would reject every legitimate exchange. A verifier only arrives when a provider opts into
    // `skipLocalPkceValidation`, so check it when present and trust the handler otherwise.
    if (codeVerifier !== undefined && !safeEqual(s256(codeVerifier), record.codeChallenge)) {
      throw new InvalidGrantError('PKCE verification failed.')
    }
    if (!record.codeChallenge) throw new InvalidGrantError('Authorization code has no PKCE challenge.')
    return this.#issue(client, record.scopes, record.resource)
  }

  async exchangeRefreshToken(client, refreshToken, scopes) {
    const record = this.refreshTokens.get(refreshToken)
    if (!record || record.clientId !== client.client_id) {
      throw new InvalidGrantError('Unknown refresh token.')
    }
    this.refreshTokens.delete(refreshToken)
    return this.#issue(client, scopes?.length ? scopes : record.scopes, record.resource)
  }

  async verifyAccessToken(value) {
    this.purgeExpired()
    const record = this.accessTokens.get(value)
    // InvalidTokenError specifically: the bearer middleware maps it to 401 with a WWW-Authenticate
    // header, which is what tells a client to re-authenticate. Any other OAuth error becomes a 400,
    // and a client reading that has been told its REQUEST was malformed — so it never re-logs-in
    // and simply stays broken. Measured: this exact mistake returned 400 for an unknown token.
    if (!record) throw new InvalidTokenError('Unknown or expired access token.')
    return {
      token: value,
      clientId: record.clientId,
      scopes: record.scopes,
      expiresAt: Math.floor(record.expiresAt / 1000),
    }
  }

  /// Revoke everything a client holds. The app's "Revoke" must make the next call FAIL, not just
  /// remove a row from a list — otherwise the button is theatre.
  revokeClient(clientId) {
    for (const store of [this.accessTokens, this.refreshTokens]) {
      for (const [value, record] of store) {
        if (record.clientId === clientId) store.delete(value)
      }
    }
    this.clients.delete(clientId)
  }

  async revokeToken(client, request) {
    const value = request?.token
    if (!value) return
    for (const store of [this.accessTokens, this.refreshTokens]) {
      const record = store.get(value)
      if (record && record.clientId === client.client_id) store.delete(value)
    }
  }

  #issue(client, scopes, resource) {
    const accessToken = token()
    const refreshToken = token()
    const expiresAt = this.now() + ACCESS_TOKEN_TTL_SECONDS * 1000
    this.accessTokens.set(accessToken, { clientId: client.client_id, scopes, resource, expiresAt })
    this.refreshTokens.set(refreshToken, { clientId: client.client_id, scopes, resource })
    return {
      access_token: accessToken,
      token_type: 'Bearer',
      expires_in: ACCESS_TOKEN_TTL_SECONDS,
      refresh_token: refreshToken,
      scope: scopes.join(' '),
    }
  }
}
