import assert from 'node:assert/strict'
import { once } from 'node:events'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const here = path.dirname(fileURLToPath(import.meta.url))
const agentd = path.resolve(here, '../src/agentd.mjs')
const ambientd = path.resolve(here, '../src/ambientd.mjs')

function startAgentd(t, {
  provider, auth, disabled = false, anthropicKey = '', environment = {},
}) {
  const config = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-account-controls-'))
  const emptySecurity = path.join(config, 'security')
  fs.writeFileSync(emptySecurity, '#!/bin/sh\nexit 44\n')
  fs.chmodSync(emptySecurity, 0o755)
  const child = spawn(process.execPath, [agentd], {
    env: {
      ...process.env,
      MECHANICIAN_PROVIDER: provider,
      MECHANICIAN_AUTH: auth,
      MECHANICIAN_CONFIG_DIR: config,
      MECHANICIAN_ACCOUNT_DISABLED: disabled ? '1' : '0',
      OPENAI_API_KEY: '',
      ANTHROPIC_API_KEY: anthropicKey,
      CLAUDE_CODE_OAUTH_TOKEN: '',
      MECHANICIAN_TEST_SECURITY_BIN: emptySecurity,
      // Prevent a test from observing real developer credentials or provider executables.
      PATH: config,
      ...environment,
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const events = []
  let buffered = ''
  child.stdout.setEncoding('utf8')
  child.stdout.on('data', (chunk) => {
    buffered += chunk
    const lines = buffered.split('\n')
    buffered = lines.pop() ?? ''
    for (const line of lines) if (line) events.push(JSON.parse(line))
  })
  t.after(() => {
    child.kill()
    fs.rmSync(config, { recursive: true, force: true })
  })
  return { child, events, config }
}

function fakeClaudeAuth(t, { initiallyLoggedIn = false, loginExitCode = 0, holdLogin = false } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-fake-claude-auth-'))
  const executable = path.join(root, 'claude')
  const pidFile = path.join(root, 'login.pid')
  const stoppedFile = path.join(root, 'login.stopped')
  const authenticatedFile = path.join(root, 'authenticated')
  const environmentFile = path.join(root, 'login.environment')
  fs.writeFileSync(executable, `#!/bin/sh
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  if [ -f "$MECHANICIAN_TEST_AUTHENTICATED" ]; then
    echo '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}'
  else
    echo '{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}'
  fi
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "login" ]; then
  printf '%s\n%s\n%s\n' "$CLAUDE_CONFIG_DIR" "$CLAUDE_SECURESTORAGE_CONFIG_DIR" "$BROWSER" > "$MECHANICIAN_TEST_LOGIN_ENVIRONMENT"
  echo $$ > "$MECHANICIAN_TEST_LOGIN_PID"
  ${holdLogin ? "" : `: > "$MECHANICIAN_TEST_AUTHENTICATED"\n  exit ${loginExitCode}`}
  trap 'echo stopped > "$MECHANICIAN_TEST_LOGIN_STOPPED"; exit 0' HUP INT TERM
  while true; do sleep 1; done
fi
if [ "$1" = "auth" ] && [ "$2" = "logout" ]; then
  /bin/rm -f "$MECHANICIAN_TEST_AUTHENTICATED"
  exit 0
fi
exit 1
`)
  fs.chmodSync(executable, 0o755)
  if (initiallyLoggedIn) fs.writeFileSync(authenticatedFile, '')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  return { executable, pidFile, stoppedFile, authenticatedFile, environmentFile }
}

for (const anthropicKey of ['', ' \t\n ']) {
  test(`Anthropic API does not start the SDK for a ${anthropicKey ? 'whitespace' : 'missing'} key`, async (t) => {
    const { events } = startAgentd(t, {
      provider: 'anthropic', auth: 'apikey', anthropicKey,
    })
    const ready = await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')
    assert.equal(ready.mode, 'unavailable')
  })

  test(`ambientd resolves no Anthropic credential for a ${anthropicKey ? 'whitespace' : 'missing'} key`, async (t) => {
    // It used to exit(1) here. Now that a task names its own provider, exiting would take every
    // OTHER lane's tasks down with it, so the daemon stays up and only Anthropic-lane runs fail.
    // The property under test is unchanged and is the one that matters: with no usable key, no
    // credential is resolved and none of the forbidden variables is accepted as a fallback.
    const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-ambient-credential-'))
    // The daemon no longer exits on a missing key, so it is still writing into this directory when
    // the test ends. Kill it FIRST (after-hooks run last-registered-first), and tolerate the race.
    t.after(() => fs.rmSync(support, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 }))
    const child = spawn(process.execPath, [ambientd], {
      env: {
        ...process.env,
        HOME: support, // keeps the test isolated from the developer's login Keychain
        MECHANICIAN_SUPPORT_DIR: support,
        ANTHROPIC_API_KEY: anthropicKey,
        ANTHROPIC_AUTH_TOKEN: 'must-not-be-an-auth-fallback',
        CLAUDE_CODE_OAUTH_TOKEN: 'must-not-be-an-auth-fallback',
        OPENAI_API_KEY: 'must-not-be-an-auth-fallback',
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    t.after(() => { try { child.kill('SIGKILL') } catch {} })
    let stderr = ''
    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (chunk) => { stderr += chunk })
    await waitFor(() => stderr.includes('no ANTHROPIC_API_KEY'), 'the missing-credential notice')
    assert.match(stderr, /Anthropic-lane tasks will fail/)
    assert.equal(child.exitCode, null, 'other lanes must keep running')
  })
}

async function waitFor(predicate, description, timeout = 5000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.fail(`timed out waiting for ${description}`)
}

for (const route of [
  { provider: 'anthropic', auth: 'apikey', label: 'Anthropic API' },
  { provider: 'openai', auth: 'apikey', label: 'OpenAI API' },
]) {
  test(`${route.label} rejects subscription login/logout controls`, async (t) => {
    const { child, events } = startAgentd(t, route)
    await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')

    child.stdin.write(`${JSON.stringify({ type: 'login_start', id: 'login-1' })}\n`)
    child.stdin.write(`${JSON.stringify({ type: 'logout', id: 'logout-1' })}\n`)
    await waitFor(
      () => events.filter((event) => event.type === 'login_error').length === 2,
      'both control errors')

    assert.deepEqual(
      events.filter((event) => event.type === 'login_error').map((event) => event.id).sort(),
      ['login-1', 'logout-1'])
    assert.ok(events.filter((event) => event.type === 'login_error')
      .every((event) => /Account Settings/.test(event.message)))
    assert.equal(events.some((event) => event.type === 'login_started'), false)
    assert.equal(events.some((event) => event.type === 'logout_ok'), false)
  })
}

test('Vertex account reload and logout stay scoped to the route ADC file', async (t) => {
  const { child, events, config } = startAgentd(t, {
    provider: 'anthropic',
    auth: 'vertex',
    environment: {
      MECHANICIAN_VERTEX_PROJECT: 'acme-claude-code',
      MECHANICIAN_VERTEX_REGION: 'us-east5',
    },
  })
  const adcPath = path.join(config, 'gcloud', 'application_default_credentials.json')
  const ready = await waitFor(() => events.find((event) => event.type === 'ready'), 'Vertex ready')
  assert.equal(ready.auth, 'vertex')
  assert.equal(ready.loggedIn, false)
  assert.equal(fs.existsSync(adcPath), false)

  child.stdin.write(`${JSON.stringify({ type: 'account_reload', id: 'vertex-reload' })}\n`)
  const reload = await waitFor(
    () => events.find((event) => event.type === 'account_reload_ok' && event.id === 'vertex-reload'),
    'Vertex account reload')
  assert.equal(reload.loggedIn, false)

  child.stdin.write(`${JSON.stringify({ type: 'logout', id: 'vertex-logout' })}\n`)
  const logout = await waitFor(
    () => events.find((event) => event.type === 'logout_ok' && event.id === 'vertex-logout'),
    'Vertex logout')
  assert.equal(logout.loggedIn, false)
  assert.equal(fs.existsSync(adcPath), false)
})

test('an unconfigured Vertex build refuses OAuth before opening a browser', async (t) => {
  const { child, events } = startAgentd(t, {
    provider: 'anthropic',
    auth: 'vertex',
  })
  const ready = await waitFor(() => events.find((event) => event.type === 'ready'), 'Vertex ready')
  assert.equal(ready.loggedIn, false)
  assert.equal(ready.mode, 'unavailable')

  child.stdin.write(`${JSON.stringify({ type: 'login_start', id: 'vertex-login' })}\n`)
  const error = await waitFor(
    () => events.find((event) => event.type === 'login_error' && event.id === 'vertex-login'),
    'unconfigured Vertex login error')
  assert.match(error.message, /not configured for Google Vertex/)
  assert.equal(events.some((event) => event.type === 'login_started'), false)
  assert.equal(events.some((event) => event.type === 'login_url'), false)
})

test('Claude login is single-flight and its PTY stops when the daemon disconnects', async (t) => {
  const fixture = fakeClaudeAuth(t, { holdLogin: true })
  const { child, events } = startAgentd(t, {
    provider: 'anthropic',
    auth: 'subscription',
    environment: {
      MECHANICIAN_CLAUDE_AUTH_BIN: fixture.executable,
      MECHANICIAN_TEST_LOGIN_PID: fixture.pidFile,
      MECHANICIAN_TEST_LOGIN_STOPPED: fixture.stoppedFile,
      MECHANICIAN_TEST_AUTHENTICATED: fixture.authenticatedFile,
      MECHANICIAN_TEST_LOGIN_ENVIRONMENT: fixture.environmentFile,
    },
  })
  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')

  child.stdin.write(`${JSON.stringify({ type: 'login_start', id: 'login-owner' })}\n`)
  await waitFor(
    () => events.find((event) => event.type === 'login_started' && event.id === 'login-owner'),
    'owned login start')
  const loginPID = Number(await waitFor(
    () => fs.existsSync(fixture.pidFile) && fs.readFileSync(fixture.pidFile, 'utf8').trim(),
    'login child pid'))

  child.stdin.write(`${JSON.stringify({ type: 'login_start', id: 'login-overlap' })}\n`)
  const overlap = await waitFor(
    () => events.find((event) => event.type === 'login_error' && event.id === 'login-overlap'),
    'overlapping login rejection')
  assert.match(overlap.message, /already in progress/)

  child.stdin.end()
  await waitFor(() => child.exitCode !== null, 'daemon exit')
  await waitFor(() => fs.existsSync(fixture.stoppedFile), 'login child cleanup')
  assert.throws(() => process.kill(loginPID, 0), { code: 'ESRCH' })
})

test('Claude login delegates browser callback and refreshable storage to the bundled engine', async (t) => {
  const fixture = fakeClaudeAuth(t)
  const { child, events, config } = startAgentd(t, {
    provider: 'anthropic',
    auth: 'subscription',
    environment: {
      MECHANICIAN_CLAUDE_AUTH_BIN: fixture.executable,
      MECHANICIAN_TEST_LOGIN_PID: fixture.pidFile,
      MECHANICIAN_TEST_LOGIN_STOPPED: fixture.stoppedFile,
      MECHANICIAN_TEST_AUTHENTICATED: fixture.authenticatedFile,
      MECHANICIAN_TEST_LOGIN_ENVIRONMENT: fixture.environmentFile,
    },
  })
  const ready = await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')
  assert.equal(ready.loggedIn, false)

  child.stdin.write(`${JSON.stringify({ type: 'login_start', id: 'login-owner' })}\n`)
  await waitFor(
    () => events.find((event) => event.type === 'login_started' && event.id === 'login-owner'),
    'Claude login start')
  const ok = await waitFor(
    () => events.find((event) => event.type === 'login_ok' && event.id === 'login-owner'),
    'Claude login completion')
  assert.equal(ok.loggedIn, true)
  assert.equal(events.some((event) => event.type === 'login_url'), false,
    'Claude owns the browser and callback; agentd must not scrape or forward an OAuth URL')
  const [configDir, secureStorageDir, browser] = fs.readFileSync(fixture.environmentFile, 'utf8').split('\n')
  assert.equal(configDir, config)
  assert.equal(secureStorageDir, config)
  assert.equal(browser, '/usr/bin/open')
})

test('Claude logout uses the same app-scoped secure storage and reports signed out', async (t) => {
  const fixture = fakeClaudeAuth(t, { initiallyLoggedIn: true })
  const { child, events } = startAgentd(t, {
    provider: 'anthropic',
    auth: 'subscription',
    environment: {
      MECHANICIAN_CLAUDE_AUTH_BIN: fixture.executable,
      MECHANICIAN_TEST_AUTHENTICATED: fixture.authenticatedFile,
      MECHANICIAN_TEST_LOGIN_ENVIRONMENT: fixture.environmentFile,
    },
  })
  const ready = await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')
  assert.equal(ready.loggedIn, true)

  child.stdin.write(`${JSON.stringify({ type: 'logout', id: 'logout-owner' })}\n`)
  const ok = await waitFor(
    () => events.find((event) => event.type === 'logout_ok' && event.id === 'logout-owner'),
    'Claude logout completion')
  assert.equal(ok.loggedIn, false)
  assert.equal(fs.existsSync(fixture.authenticatedFile), false)
})

test('Claude startup uses structured status from its app-scoped refreshable login', async (t) => {
  const fixture = fakeClaudeAuth(t, { initiallyLoggedIn: true })
  const { events, config } = startAgentd(t, {
    provider: 'anthropic',
    auth: 'subscription',
    environment: {
      MECHANICIAN_CLAUDE_AUTH_BIN: fixture.executable,
      MECHANICIAN_TEST_AUTHENTICATED: fixture.authenticatedFile,
      MECHANICIAN_TEST_LOGIN_ENVIRONMENT: fixture.environmentFile,
    },
  })

  const ready = await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')
  assert.equal(ready.loggedIn, true)
  assert.equal(config.length > 0, true)
})

for (const route of [
  { provider: 'anthropic', auth: 'subscription', label: 'Claude' },
  { provider: 'codex', auth: 'subscription', label: 'Codex' },
]) {
  test(`${route.label} local disconnect suppresses startup and login`, async (t) => {
    const { child, events } = startAgentd(t, { ...route, disabled: true })
    const ready = await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')
    assert.equal(ready.loggedIn, false)
    assert.equal(ready.mode, 'unavailable')

    child.stdin.write(`${JSON.stringify({ type: 'login_start', id: 'disabled-login' })}\n`)
    const error = await waitFor(
      () => events.find((event) => event.type === 'login_error' && event.id === 'disabled-login'),
      'disabled login error')
    assert.match(error.message, /disconnected from Mechanician/)
    assert.equal(events.some((event) => event.type === 'login_started'), false)
  })
}
