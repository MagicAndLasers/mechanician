import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import path from 'node:path'
import readline from 'node:readline'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const server = path.join(here, '..', 'src', 'mac-bridge', 'server.mjs')

/// Drives the real bridge process over the same stdio protocol the app uses. Consent is the one
/// thing that must never be decidable by the bridge itself, so it is worth testing against the
/// actual process rather than a stand-in.
function startBridge(port) {
  const child = spawn(process.execPath, [server], {
    env: { ...process.env, MAC_BRIDGE_PORT: String(port), MAC_BRIDGE_AUTO_APPROVE: '' },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  child.stderr.resume()
  const messages = []
  const waiters = []
  readline.createInterface({ input: child.stdout }).on('line', (line) => {
    let message
    try { message = JSON.parse(line) } catch { return }
    messages.push(message)
    for (const [index, waiter] of waiters.entries()) {
      if (waiter.match(message)) {
        waiters.splice(index, 1)
        waiter.resolve(message)
        break
      }
    }
  })
  return {
    child,
    send: (message) => child.stdin.write(`${JSON.stringify(message)}\n`),
    messages,
    waitFor(match, timeoutMs = 15_000) {
      const existing = messages.find(match)
      if (existing) return Promise.resolve(existing)
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('timed out waiting for a message')), timeoutMs)
        waiters.push({ match, resolve: (m) => { clearTimeout(timer); resolve(m) } })
      })
    },
    stop: () => child.kill('SIGTERM'),
  }
}

/// Registers a client and starts an authorization, returning once the bridge has asked for consent.
async function askForConsent(bridge, port) {
  const registration = await (await fetch(`http://127.0.0.1:${port}/register`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      client_name: 'Probe Assistant',
      redirect_uris: ['http://127.0.0.1:9999/callback'],
      grant_types: ['authorization_code'], response_types: ['code'],
      token_endpoint_auth_method: 'none',
    }),
  })).json()
  const authorize = fetch(
    `http://127.0.0.1:${port}/authorize?response_type=code`
    + `&client_id=${encodeURIComponent(registration.client_id)}`
    + `&redirect_uri=${encodeURIComponent('http://127.0.0.1:9999/callback')}`
    + '&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256',
    { redirect: 'manual' })
  const request = await bridge.waitFor((m) => m.type === 'consent_request')
  return { registration, authorize, request }
}

test('the bridge asks the app for consent and cannot answer itself', async (t) => {
  const port = 7841
  const bridge = startBridge(port)
  t.after(() => bridge.stop())
  await bridge.waitFor((m) => m.type === 'bridge_ready')

  const { request, authorize } = await askForConsent(bridge, port)

  assert.equal(request.client.name, 'Probe Assistant')
  assert.ok(request.id)
  // Nothing was granted while the question is outstanding.
  assert.equal(bridge.messages.some((m) => m.type === 'clients' && m.clients.length), false)

  bridge.send({ type: 'consent_decision', id: request.id, approved: true })
  const response = await authorize
  const location = new URL(response.headers.get('location'))

  assert.ok(location.searchParams.get('code'), 'approval issues a code')
  const clients = await bridge.waitFor((m) => m.type === 'clients' && m.clients.length === 1)
  assert.equal(clients.clients[0].name, 'Probe Assistant')
})

/// A refusal has to be an OAuth outcome the client understands, not a hang or a 500.
test('declining redirects with access_denied and grants nothing', async (t) => {
  const port = 7842
  const bridge = startBridge(port)
  t.after(() => bridge.stop())
  await bridge.waitFor((m) => m.type === 'bridge_ready')

  const { request, authorize } = await askForConsent(bridge, port)
  bridge.send({ type: 'consent_decision', id: request.id, approved: false })
  const response = await authorize
  const location = new URL(response.headers.get('location'))

  assert.equal(location.searchParams.get('error'), 'access_denied')
  assert.equal(location.searchParams.get('code'), null)
  assert.equal(bridge.messages.some((m) => m.type === 'clients' && m.clients.length), false)
})

/// Revoking must make the next call FAIL, not merely remove a row — otherwise the button is theatre.
test('revoking a client invalidates the token it already holds', async (t) => {
  const port = 7843
  const bridge = startBridge(port)
  t.after(() => bridge.stop())
  await bridge.waitFor((m) => m.type === 'bridge_ready')

  const { registration, request, authorize } = await askForConsent(bridge, port)
  bridge.send({ type: 'consent_decision', id: request.id, approved: true })
  const code = new URL((await authorize).headers.get('location')).searchParams.get('code')

  const tokens = await (await fetch(`http://127.0.0.1:${port}/token`, {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code', code,
      code_verifier: 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
      client_id: registration.client_id, redirect_uri: 'http://127.0.0.1:9999/callback',
    }),
  })).json()

  const call = async () => (await fetch(`http://127.0.0.1:${port}/mcp`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      accept: 'application/json, text/event-stream',
      authorization: `Bearer ${tokens.access_token}`,
    },
    body: JSON.stringify({
      jsonrpc: '2.0', id: 1, method: 'initialize',
      params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'p', version: '1' } },
    }),
  })).status

  assert.equal(await call(), 200, 'the token works before revoking')

  bridge.send({ type: 'revoke', clientId: registration.client_id })
  await bridge.waitFor((m) => m.type === 'clients' && m.clients.length === 0)

  assert.equal(await call(), 401, 'and is refused immediately afterwards')
})
