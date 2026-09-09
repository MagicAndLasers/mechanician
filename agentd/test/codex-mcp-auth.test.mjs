import assert from 'node:assert/strict'
import test from 'node:test'

import {
  beginCodexOAuthLogin,
  CODEX_CREDENTIALS_STORE_ARGS,
  cancelCodexOAuthLogin,
  clearCodexOAuth,
  createCodexOAuthWaiters,
  resolveCodexOAuthCompletion,
} from '../src/codex-mcp-auth.mjs'

function collector() {
  const events = []
  return { events, emit: (event) => events.push(event) }
}

const appReturning = (result) => ({ request: async () => result })
const appThrowing = (message) => ({ request: async () => { throw new Error(message) } })

test('a login emits the authorization URL and waits for completion', async () => {
  const { events, emit } = collector()
  const waiters = createCodexOAuthWaiters()

  await beginCodexOAuthLogin({
    id: 'req-1', name: 'bridge', app: appReturning({ authorizationUrl: 'https://x.test/auth' }),
    waiters, emit,
  })

  assert.deepEqual(events, [{ type: 'mcp_authorize_url', id: 'req-1', name: 'bridge', url: 'https://x.test/auth' }])
  assert.equal(waiters.get('bridge').id, 'req-1', 'still waiting for the terminal event')
})

/// The URL event is NOT terminal. The app shows the row as waiting until this arrives, so a lost
/// completion would leave a spinner forever.
test('completion returns success for the generation barrier without publishing it early', async () => {
  const { events, emit } = collector()
  const waiters = createCodexOAuthWaiters()
  await beginCodexOAuthLogin({
    id: 'req-1', name: 'bridge', app: appReturning({ authorizationUrl: 'https://x.test' }), waiters, emit,
  })

  const completion = resolveCodexOAuthCompletion({
    notification: { name: 'bridge', success: true }, waiters,
  })

  assert.equal(completion.handled, true)
  assert.equal(completion.success, true)
  assert.equal(completion.waiter.id, 'req-1')
  assert.deepEqual(completion.event, {
    type: 'mcp_authorize_ok', id: 'req-1', name: 'bridge',
  })
  assert.equal(
    events.some((event) => event.type === 'mcp_authorize_ok'),
    false,
    'the daemon must emit this event only after MCP generation convergence')
  assert.equal(waiters.size, 0)
})

test('a failed completion carries the reason Codex gave without needing convergence', async () => {
  const { events, emit } = collector()
  const waiters = createCodexOAuthWaiters()
  await beginCodexOAuthLogin({
    id: 'req-1', name: 'bridge', app: appReturning({ authorizationUrl: 'https://x.test' }), waiters, emit,
  })

  const completion = resolveCodexOAuthCompletion({
    notification: { name: 'bridge', success: false, error: 'the user declined' }, waiters,
  })

  assert.equal(completion.handled, true)
  assert.equal(completion.success, false)
  assert.deepEqual(completion.event,
    { type: 'mcp_authorize_error', id: 'req-1', name: 'bridge', message: 'the user declined' })
  assert.equal(events.some((event) => event.type === 'mcp_authorize_error'), false)
})

/// Codex reports completion by server NAME and emits for its own flows too, so an event nobody is
/// waiting on must not be answered with someone else's request id.
test('a completion nobody is waiting for is ignored', () => {
  const { events, emit } = collector()

  const completion = resolveCodexOAuthCompletion({
    notification: { name: 'stranger', success: true }, waiters: createCodexOAuthWaiters(), emit,
  })

  assert.equal(completion.handled, false)
  assert.deepEqual(events, [])
})

test('a second sign-in supersedes the first rather than stacking', async () => {
  const { emit } = collector()
  const waiters = createCodexOAuthWaiters()
  const app = appReturning({ authorizationUrl: 'https://x.test' })

  await beginCodexOAuthLogin({ id: 'first', name: 'bridge', app, waiters, emit })
  await beginCodexOAuthLogin({ id: 'second', name: 'bridge', app, waiters, emit })

  assert.equal(waiters.size, 1)
  assert.equal(waiters.get('bridge').id, 'second')
})

test('a lane that is not running says so instead of hanging', async () => {
  const { events, emit } = collector()
  const waiters = createCodexOAuthWaiters()

  await beginCodexOAuthLogin({ id: 'req-1', name: 'bridge', app: null, waiters, emit })

  assert.equal(events[0].type, 'mcp_authorize_error')
  assert.match(events[0].message, /not running/)
  assert.equal(waiters.size, 0, 'nothing is left waiting')
})

test('a login that fails or returns no URL leaves nothing waiting', async () => {
  for (const app of [appThrowing('boom'), appReturning({})]) {
    const { events, emit } = collector()
    const waiters = createCodexOAuthWaiters()

    await beginCodexOAuthLogin({ id: 'req-1', name: 'bridge', app, waiters, emit })

    assert.equal(events.at(-1).type, 'mcp_authorize_error')
    assert.equal(waiters.size, 0, 'a stuck waiter would strand the row as "waiting" forever')
  }
})

test('a provider exit that settles an in-flight login owns its only terminal event', async () => {
  const { events, emit } = collector()
  const waiters = createCodexOAuthWaiters()
  let rejectStart
  const pendingStart = new Promise((_resolve, reject) => { rejectStart = reject })
  const operation = beginCodexOAuthLogin({
    id: 'req-1', name: 'bridge', app: { request: () => pendingStart }, waiters, emit,
  })

  const waiter = waiters.get('bridge')
  assert.equal(waiter.id, 'req-1')
  waiters.delete('bridge')
  emit({
    type: 'mcp_authorize_error', id: waiter.id, name: 'bridge',
    message: 'Codex stopped during authorization. Try authorizing this server again.',
  })
  rejectStart(new Error('transport stopped'))
  await operation

  assert.deepEqual(events, [{
    type: 'mcp_authorize_error', id: 'req-1', name: 'bridge',
    message: 'Codex stopped during authorization. Try authorizing this server again.',
  }])
})

test('cancelling stops the wait and acknowledges', () => {
  const { events, emit } = collector()
  const waiters = createCodexOAuthWaiters()
  waiters.set('bridge', { id: 'req-1' })

  cancelCodexOAuthLogin({ id: 'req-2', name: 'bridge', waiters, emit })

  assert.deepEqual(events, [{ type: 'mcp_authorize_cancel_ok', id: 'req-2', name: 'bridge' }])
  assert.equal(waiters.size, 0)
})

test('clearing runs codex mcp logout against our own Codex home', async () => {
  const { events, emit } = collector()
  const calls = []

  await clearCodexOAuth({
    id: 'req-1', name: 'bridge', executable: '/bin/codex', codexHome: '/tmp/home', emit,
    exec: async (file, args, options) => { calls.push({ file, args, options }); return { stdout: '' } },
  })

  assert.deepEqual(events, [{ type: 'mcp_clear_auth_ok', id: 'req-1', name: 'bridge' }])
  assert.deepEqual(calls[0].args, [...CODEX_CREDENTIALS_STORE_ARGS, 'mcp', 'logout', 'bridge'])
  assert.equal(calls[0].options.env.CODEX_HOME, '/tmp/home')
})

test('clear-auth returns its terminal for convergence instead of publishing it early', async () => {
  const calls = []
  const result = await clearCodexOAuth({
    id: 'req-1', name: 'bridge', executable: '/bin/codex', codexHome: '/tmp/home',
    exec: async (...args) => { calls.push(args); return { stdout: '' } },
  })

  assert.equal(result.ok, true)
  assert.deepEqual(result.event, {
    type: 'mcp_clear_auth_ok', id: 'req-1', name: 'bridge',
  })
  assert.equal(calls.length, 1)
  // No emitter was supplied: agentd owns publishing the returned event only after its generation
  // barrier resolves. A helper-owned emission here would be unobservable and therefore untestable.
})

/// Already signed out is the outcome the user asked for, so it must not read as a failure.
test('clearing a server that was never signed in still succeeds', async () => {
  const { events, emit } = collector()

  await clearCodexOAuth({
    id: 'req-1', name: 'bridge', executable: '/bin/codex', codexHome: '/tmp/home', emit,
    exec: async () => { const e = new Error('failed'); e.stderr = 'server is not logged in'; throw e },
  })

  assert.equal(events[0].type, 'mcp_clear_auth_ok')
})

test('a real logout failure is reported, not swallowed', async () => {
  const { events, emit } = collector()

  await clearCodexOAuth({
    id: 'req-1', name: 'bridge', executable: '/bin/codex', codexHome: '/tmp/home', emit,
    exec: async () => { const e = new Error('permission denied'); e.stderr = 'keyring locked'; throw e },
  })

  assert.equal(events[0].type, 'mcp_authorize_error')
})

test('a missing Codex binary does not silently claim the credential was removed', async () => {
  const { events, emit } = collector()

  await clearCodexOAuth({ id: 'req-1', name: 'bridge', executable: null, codexHome: '/tmp', emit })

  assert.equal(events[0].type, 'mcp_authorize_error')
  assert.match(events[0].message, /could not be located/)
})

/// `auto` is free to fall back to a plaintext file inside CODEX_HOME — a credential at rest, which
/// is strictly worse than the exposure this whole approach exists to avoid. And logout must look in
/// the SAME store the app-server writes to, or it reports success without removing anything.
test('the credential store is pinned to the keychain, never left to the default', () => {
  assert.deepEqual(CODEX_CREDENTIALS_STORE_ARGS, ['-c', 'mcp_oauth_credentials_store="keyring"'])
})
