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
const accountInstanceId = 'a1faed81-8eba-4242-97fa-b3a5d9212585'
const routeIdentity = 'anthropic:apikey:builtin'

async function waitFor(predicate, description, fixture, timeout = 5_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.fail(`timed out waiting for ${description}\nagentd stderr:\n${fixture.stderr}`)
}

function writeSDKLoader(directory, captureFile, status, { allowClear = false } = {}) {
  const sdkSource = `
    import fs from 'node:fs'
    const capture = ${JSON.stringify(captureFile)}
    const record = (value) => fs.appendFileSync(capture, JSON.stringify(value) + '\\n')

    export function createSdkMcpServer(config) { return config }
    export function tool(name, description, schema, handler) {
      return { name, description, schema, handler }
    }

    export function query({ prompt, options }) {
      record({ kind: 'query', mounted: Object.keys(options?.mcpServers || {}) })
      const stream = (async function* () {
        const input = prompt?.[Symbol.asyncIterator]?.()
        if (input) await input.next()
      })()
      stream.supportedCommands = async () => []
      stream.mcpServerStatus = async () => {
        record({ kind: 'status' })
        return [${JSON.stringify(status)}]
      }
      stream.mcpAuthenticate = async () => {
        record({ kind: 'authenticate' })
        throw new Error('reconciliation must not start authorization')
      }
      stream.mcpSubmitOAuthCallbackUrl = async () => {
        record({ kind: 'submit-callback' })
        throw new Error('the failed authorization start must not submit a callback')
      }
      stream.mcpClearAuth = async () => {
        record({ kind: 'clear' })
        if (${JSON.stringify(allowClear)}) return
        throw new Error('reconciliation must not clear authorization')
      }
      return stream
    }

    export async function startup() {
      return { query() { throw new Error('unexpected warm query') }, close() {} }
    }
  `
  const sdkURL = `data:text/javascript;base64,${Buffer.from(sdkSource).toString('base64')}`
  fs.writeFileSync(path.join(directory, 'hooks.mjs'), `
    const sdkURL = ${JSON.stringify(sdkURL)}
    export async function resolve(specifier, context, nextResolve) {
      if (specifier === '@anthropic-ai/claude-agent-sdk') {
        return { url: sdkURL, shortCircuit: true }
      }
      return nextResolve(specifier, context)
    }
  `)
  const loader = path.join(directory, 'loader.mjs')
  fs.writeFileSync(loader, `
    import { register } from 'node:module'
    register(new URL('./hooks.mjs', import.meta.url))
  `)
  return loader
}

async function startFixture(t, status, options = {}) {
  const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-mcp-reconcile-'))
  const capture = path.join(support, 'sdk-events.ndjson')
  const loader = writeSDKLoader(support, capture, status, options)
  fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({ mcpServers: [] }))
  const child = spawn(process.execPath, ['--import', loader, agentd], {
    env: {
      ...process.env,
      MECHANICIAN_PROVIDER: 'anthropic',
      MECHANICIAN_AUTH: 'apikey',
      MECHANICIAN_CONFIG_DIR: support,
      MECHANICIAN_SUPPORT_DIR: support,
      MECHANICIAN_CWD: support,
      MECHANICIAN_ACCOUNT_INSTANCE_ID: accountInstanceId,
      ANTHROPIC_API_KEY: 'fixture-api-key',
      ANTHROPIC_AUTH_TOKEN: '',
      CLAUDE_CODE_OAUTH_TOKEN: '',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const events = []
  let stdout = ''
  let stderr = ''
  child.stdout.setEncoding('utf8')
  child.stderr.setEncoding('utf8')
  child.stdout.on('data', (chunk) => {
    stdout += chunk
    const lines = stdout.split('\n')
    stdout = lines.pop() ?? ''
    for (const line of lines) if (line) events.push(JSON.parse(line))
  })
  child.stderr.on('data', (chunk) => { stderr += chunk })
  const fixture = {
    child,
    events,
    capture,
    get stderr() { return stderr },
  }
  t.after(async () => {
    if (child.exitCode === null) child.kill('SIGKILL')
    if (child.exitCode === null) {
      try { await once(child, 'exit') } catch {}
    }
    fs.rmSync(support, { recursive: true, force: true })
  })
  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready event', fixture)
  return fixture
}

function exactReconcile(id, overrides = {}) {
  return {
    type: 'mcp_reconcile', id, name: 'VICE', attemptId: `${id}-attempt`,
    source: 'providerConnector', operation: 'authorize', accountInstanceId, routeIdentity,
    ...overrides,
  }
}

function send(fixture, request) {
  fixture.child.stdin.write(`${JSON.stringify(request)}\n`)
}

function captured(fixture) {
  if (!fs.existsSync(fixture.capture)) return []
  return fs.readFileSync(fixture.capture, 'utf8').trim().split('\n')
    .filter(Boolean).map(JSON.parse)
}

test('connector reconciliation reports exact ready evidence without starting authorization', async (t) => {
  const fixture = await startFixture(t, {
    name: 'VICE', status: 'connected', tools: [{ name: 'search' }],
  })
  const request = exactReconcile('reconcile-ready')
  send(fixture, request)

  const terminal = await waitFor(
    () => fixture.events.find((event) =>
      event.type === 'mcp_reconcile_ok' && event.id === request.id),
    'ready reconciliation terminal', fixture,
  )
  const phase = fixture.events.find((event) =>
    event.type === 'mcp_credentials_changed' && event.changeId === request.attemptId)

  assert.deepEqual(phase, {
    type: 'mcp_credentials_changed', name: 'VICE', changeId: request.attemptId,
    source: 'providerConnector', accountInstanceId, routeIdentity,
    operation: 'authorize',
    activation: 'ready', status: 'connected', tools: 1,
  })
  assert.deepEqual(terminal, {
    type: 'mcp_reconcile_ok', id: request.id, name: 'VICE',
    attemptId: request.attemptId, changeId: request.attemptId,
    source: 'providerConnector', accountInstanceId, routeIdentity,
    operation: 'authorize', activation: 'ready', status: 'connected', tools: 1,
  })
  assert.deepEqual(captured(fixture).map((event) => event.kind), ['query', 'status'])
  assert.equal(fixture.events.some((event) => event.type === 'mcp_authorize_url'), false)
})

test('clear reconciliation idempotently finishes the exact saved clear operation', async (t) => {
  const fixture = await startFixture(t, {
    name: 'VICE', status: 'connected', tools: [{ name: 'search' }],
  }, { allowClear: true })
  const request = exactReconcile('reconcile-cleared', { operation: 'clear' })
  send(fixture, request)

  const terminal = await waitFor(
    () => fixture.events.find((event) =>
      event.type === 'mcp_reconcile_ok' && event.id === request.id),
    'cleared reconciliation terminal', fixture,
  )
  assert.deepEqual(fixture.events.find((event) =>
    event.type === 'mcp_credentials_changed' && event.changeId === request.attemptId
      && event.activation === 'cleared'), {
    type: 'mcp_credentials_changed', name: 'VICE', changeId: request.attemptId,
    source: 'providerConnector', accountInstanceId, routeIdentity,
    operation: 'clear',
    activation: 'cleared', status: 'needs-auth',
  })
  assert.equal(terminal.attemptId, request.attemptId)
  assert.deepEqual(captured(fixture).map((event) => event.kind), ['query', 'clear'])
})

for (const mismatch of [{
  label: 'authorize still needs auth',
  operation: 'authorize',
  status: { name: 'VICE', status: 'needs-auth' },
}]) {
  test(`${mismatch.label} remains an unresolved reconciliation failure`, async (t) => {
    const fixture = await startFixture(t, mismatch.status)
    const request = exactReconcile(`reconcile-${mismatch.operation}-mismatch`, {
      operation: mismatch.operation,
    })
    send(fixture, request)

    const terminal = await waitFor(
      () => fixture.events.find((event) =>
        event.type === 'mcp_reconcile_error' && event.id === request.id),
      `${mismatch.label} terminal`, fixture,
    )
    assert.equal(terminal.attemptId, request.attemptId)
    assert.deepEqual(fixture.events.find((event) =>
      event.type === 'mcp_credentials_changed' && event.changeId === request.attemptId), {
      type: 'mcp_credentials_changed', name: 'VICE', changeId: request.attemptId,
      source: 'providerConnector', accountInstanceId, routeIdentity,
      operation: mismatch.operation,
      activation: 'failed',
    })
    assert.deepEqual(captured(fixture).map((event) => event.kind), ['query', 'status'])
  })
}

test('explicit retry may resume authorization under the same exact attempt', async (t) => {
  const fixture = await startFixture(t, { name: 'VICE', status: 'needs-auth' })
  const request = exactReconcile('reconcile-resume-authorize', {
    operation: 'authorize', resumeIfNeeded: true,
  })
  send(fixture, request)

  const terminal = await waitFor(
    () => fixture.events.find((event) =>
      event.type === 'mcp_reconcile_error' && event.id === request.id),
    'resumed authorization terminal', fixture,
  )
  assert.equal(terminal.attemptId, request.attemptId)
  assert.equal(terminal.operation, 'authorize')
  assert.deepEqual(captured(fixture).map((event) => event.kind), [
    'query', 'status', 'query', 'authenticate',
  ])
  assert.equal(fixture.events.some((event) => event.type === 'mcp_authorize_url'), false)
})

test('uncertain connector reconciliation retains the exact attempt through failed evidence', async (t) => {
  const fixture = await startFixture(t, {
    name: 'VICE', status: 'connected', tools: [],
  })
  const request = exactReconcile('reconcile-uncertain')
  send(fixture, request)

  const terminal = await waitFor(
    () => fixture.events.find((event) =>
      event.type === 'mcp_reconcile_error' && event.id === request.id),
    'uncertain reconciliation terminal', fixture,
  )
  assert.deepEqual(fixture.events.find((event) =>
    event.type === 'mcp_credentials_changed' && event.changeId === request.attemptId), {
    type: 'mcp_credentials_changed', name: 'VICE', changeId: request.attemptId,
    source: 'providerConnector', accountInstanceId, routeIdentity,
    operation: 'authorize',
    activation: 'failed',
  })
  assert.equal(terminal.attemptId, request.attemptId)
  assert.equal(terminal.source, 'providerConnector')
  assert.equal(terminal.accountInstanceId, accountInstanceId)
  assert.equal(terminal.routeIdentity, routeIdentity)
  assert.match(terminal.message, /could not determine/i)
  assert.deepEqual(captured(fixture).map((event) => event.kind), ['query', 'status'])
})

for (const identityCase of [
  {
    label: 'account',
    override: { accountInstanceId: 'e65b4b19-4cf3-4f45-b65d-4536bf6bf023' },
  },
  {
    label: 'route',
    override: { routeIdentity: 'anthropic:subscription:builtin' },
  },
]) {
  test(`connector reconciliation for the wrong ${identityCase.label} fails before provider access`, async (t) => {
    const fixture = await startFixture(t, {
      name: 'VICE', status: 'connected', tools: [{ name: 'search' }],
    })
    const request = exactReconcile(`reconcile-wrong-${identityCase.label}`, identityCase.override)
    send(fixture, request)

    const terminal = await waitFor(
      () => fixture.events.find((event) =>
        event.type === 'mcp_reconcile_error' && event.id === request.id),
      `wrong ${identityCase.label} reconciliation`, fixture,
    )
    assert.match(terminal.message, /different provider account or route/i)
    assert.equal(fixture.events.some((event) =>
      event.type === 'mcp_credentials_changed' && event.id === request.id), false)
    assert.deepEqual(captured(fixture), [])
  })
}
