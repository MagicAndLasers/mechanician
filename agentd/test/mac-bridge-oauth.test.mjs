import assert from 'node:assert/strict'
import { createHash, randomBytes } from 'node:crypto'
import test from 'node:test'

import { InvalidTokenError } from '@modelcontextprotocol/sdk/server/auth/errors.js'

import { MacBridgeOAuthProvider } from '../src/mac-bridge/oauth.mjs'

const CLIENT = { client_id: 'client-a', client_name: 'Probe' }
const OTHER = { client_id: 'client-b', client_name: 'Someone else' }
const REDIRECT = 'http://127.0.0.1:9999/callback'

function pkce() {
  const verifier = randomBytes(32).toString('base64url')
  return { verifier, challenge: createHash('sha256').update(verifier).digest('base64url') }
}

/// Captures what the provider redirects to, standing in for an express Response.
function fakeResponse() {
  return { location: null, redirect(url) { this.location = new URL(url) } }
}

async function authorizedCode(provider, { client = CLIENT, challenge, state } = {}) {
  const res = fakeResponse()
  await provider.authorize(client, { codeChallenge: challenge, redirectUri: REDIRECT, state }, res)
  return res
}

function provider({ approve = true, now = Date.now } = {}) {
  return new MacBridgeOAuthProvider({ requestConsent: async () => approve, now })
}

test('an approved authorization returns a code and preserves state', async () => {
  const p = provider()
  const { challenge } = pkce()

  const res = await authorizedCode(p, { challenge, state: 'xyz' })

  assert.ok(res.location.searchParams.get('code'))
  assert.equal(res.location.searchParams.get('state'), 'xyz')
})

/// A refusal is a normal outcome. It has to come back as an OAuth redirect so the client can tell
/// "the human said no" from "the server broke" — and it must not mint a code.
test('a declined consent redirects with access_denied and issues nothing', async () => {
  const p = provider({ approve: false })
  const { challenge } = pkce()

  const res = await authorizedCode(p, { challenge, state: 'xyz' })

  assert.equal(res.location.searchParams.get('error'), 'access_denied')
  assert.equal(res.location.searchParams.get('code'), null)
  assert.equal(res.location.searchParams.get('state'), 'xyz')
  assert.equal(p.codes.size, 0)
})

/// The SDK's token handler verifies PKCE itself and then passes `codeVerifier: undefined`. Getting
/// this wrong rejects every legitimate exchange, which is exactly what happened the first time.
test('the exchange succeeds under the SDK contract, where the verifier is not forwarded', async () => {
  const p = provider()
  const { verifier, challenge } = pkce()
  const res = await authorizedCode(p, { challenge })
  const code = res.location.searchParams.get('code')

  assert.equal(await p.challengeForAuthorizationCode(CLIENT, code), challenge)
  const tokens = await p.exchangeAuthorizationCode(CLIENT, code, undefined, REDIRECT)

  assert.equal(tokens.token_type, 'Bearer')
  assert.ok(tokens.access_token && tokens.refresh_token)
  assert.equal(typeof tokens.expires_in, 'number')
  assert.ok(verifier)
})

test('a mismatched verifier is still rejected when one is supplied', async () => {
  const p = provider()
  const { challenge } = pkce()
  const res = await authorizedCode(p, { challenge })
  const code = res.location.searchParams.get('code')

  await assert.rejects(
    () => p.exchangeAuthorizationCode(CLIENT, code, 'not-the-verifier', REDIRECT),
    /PKCE/)
})

test('an authorization code is single use', async () => {
  const p = provider()
  const { challenge } = pkce()
  const res = await authorizedCode(p, { challenge })
  const code = res.location.searchParams.get('code')

  await p.exchangeAuthorizationCode(CLIENT, code, undefined, REDIRECT)

  await assert.rejects(
    () => p.exchangeAuthorizationCode(CLIENT, code, undefined, REDIRECT),
    (error) => error.errorCode === 'invalid_grant')
})

/// A loopback redirect is readable by other local processes, so a stolen code must be useless to
/// the thief without also being that client.
test('another client cannot exchange a code it did not request', async () => {
  const p = provider()
  const { challenge } = pkce()
  const res = await authorizedCode(p, { challenge })
  const code = res.location.searchParams.get('code')

  await assert.rejects(() => p.exchangeAuthorizationCode(OTHER, code, undefined, REDIRECT))
  await assert.rejects(() => p.challengeForAuthorizationCode(OTHER, code))
})

test('a redirect URI that changed between request and exchange is refused', async () => {
  const p = provider()
  const { challenge } = pkce()
  const res = await authorizedCode(p, { challenge })
  const code = res.location.searchParams.get('code')

  await assert.rejects(
    () => p.exchangeAuthorizationCode(CLIENT, code, undefined, 'http://127.0.0.1:9999/elsewhere'),
    /Redirect URI/)
})

test('codes expire', async () => {
  let clock = 1_000_000
  const p = provider({ now: () => clock })
  const { challenge } = pkce()
  const res = await authorizedCode(p, { challenge })
  const code = res.location.searchParams.get('code')

  clock += 61_000

  await assert.rejects(() => p.exchangeAuthorizationCode(CLIENT, code, undefined, REDIRECT))
})

test('access tokens verify, expire, and can be revoked', async () => {
  let clock = 1_000_000
  const p = provider({ now: () => clock })
  const { challenge } = pkce()
  const res = await authorizedCode(p, { challenge })
  const tokens = await p.exchangeAuthorizationCode(
    CLIENT, res.location.searchParams.get('code'), undefined, REDIRECT)

  const info = await p.verifyAccessToken(tokens.access_token)
  assert.equal(info.clientId, CLIENT.client_id)

  await p.revokeToken(CLIENT, { token: tokens.access_token })
  await assert.rejects(() => p.verifyAccessToken(tokens.access_token))

  const second = await p.exchangeRefreshToken(CLIENT, tokens.refresh_token)
  clock += 3_600_001
  await assert.rejects(() => p.verifyAccessToken(second.access_token), /Unknown or expired/)
})

test('a refresh token is single use', async () => {
  const p = provider()
  const { challenge } = pkce()
  const res = await authorizedCode(p, { challenge })
  const tokens = await p.exchangeAuthorizationCode(
    CLIENT, res.location.searchParams.get('code'), undefined, REDIRECT)

  await p.exchangeRefreshToken(CLIENT, tokens.refresh_token)

  await assert.rejects(() => p.exchangeRefreshToken(CLIENT, tokens.refresh_token))
})

/// Measured against the running server: throwing any other OAuth error here makes the bearer
/// middleware answer 400, which tells a client its REQUEST was malformed. It then never
/// re-authenticates and simply stays broken. Only InvalidTokenError produces the 401 +
/// WWW-Authenticate that means "log in again".
test('an unknown token fails as invalid_token, so the client is told to re-authenticate', async () => {
  const p = provider()

  await assert.rejects(
    () => p.verifyAccessToken('not-a-real-token'),
    (error) => error instanceof InvalidTokenError && error.errorCode === 'invalid_token')
})

test('an expired token is also invalid_token, not a generic failure', async () => {
  let clock = 1_000_000
  const p = provider({ now: () => clock })
  const { challenge } = pkce()
  const res = await authorizedCode(p, { challenge })
  const tokens = await p.exchangeAuthorizationCode(
    CLIENT, res.location.searchParams.get('code'), undefined, REDIRECT)

  clock += 3_600_001

  await assert.rejects(
    () => p.verifyAccessToken(tokens.access_token),
    (error) => error instanceof InvalidTokenError)
})
