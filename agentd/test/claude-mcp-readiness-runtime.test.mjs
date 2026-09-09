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
const configuredServerId = '7f661a72-4885-42ad-bce1-242b6741d88a'

function extensionsWithReadiness(claim, servers = []) {
  return {
    mcpServers: servers,
    pendingMCPReadiness: {
      byAccess: {
        anthropic_api: [{
          name: claim.name, changeId: claim.changeId, source: claim.source,
          ...(claim.serverId ? { serverID: claim.serverId } : {}),
          accountInstanceID: claim.accountInstanceId,
          routeIdentity: claim.routeIdentity,
        }],
      },
    },
  }
}

function configuredExtensionsWithReadiness(changeId) {
  return extensionsWithReadiness({
    name: 'VICE', changeId, source: 'configured', serverId: configuredServerId,
    accountInstanceId, routeIdentity,
  }, [{
    id: configuredServerId,
    name: 'VICE', enabled: true, transport: 'stdio', command: '/bin/echo',
  }])
}

async function waitFor(predicate, description, fixture, timeout = 5_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.fail(`timed out waiting for ${description}\nagentd stderr:\n${fixture.stderr}`)
}

function writeSDKLoader(directory, captureFile, statusTools = [{ name: 'search' }], {
  turnReleaseFile = null,
  oauthReleaseFile = null,
  statusToolsFile = null,
  statusReleaseFile = null,
} = {}) {
  const sdkSource = `
    import fs from 'node:fs'
    const capture = ${JSON.stringify(captureFile)}
    const turnReleaseFile = ${JSON.stringify(turnReleaseFile)}
    const statusToolsFile = ${JSON.stringify(statusToolsFile)}
    const statusReleaseFile = ${JSON.stringify(statusReleaseFile)}
    let queryCount = 0
    const record = (value) => fs.appendFileSync(capture, JSON.stringify(value) + '\\n')

    export function createSdkMcpServer(config) { return config }
    export function tool(name, description, schema, handler) {
      return { name, description, schema, handler }
    }

    export function query({ prompt, options }) {
      const ordinal = ++queryCount
      record({
        kind: 'query', ordinal, mounted: Object.keys(options?.mcpServers || {}),
        resume: options?.resume ?? null,
      })
      const stream = (async function* () {
        const input = prompt?.[Symbol.asyncIterator]?.()
        const first = input ? await input.next() : { done: true }
        if (first.done) return
        record({ kind: 'prompt', value: first.value })
        yield {
          type: 'system', subtype: 'init', session_id: 'fixture-session',
          tools: ['Read'], mcp_servers: [{ name: 'VICE', status: 'connected' }],
        }
        if (ordinal === 1 && turnReleaseFile) {
          while (!fs.existsSync(turnReleaseFile)) {
            await new Promise((resolve) => setTimeout(resolve, 10))
          }
        }
        yield {
          type: 'stream_event', session_id: 'fixture-session', uuid: 'fixture-frame',
          event: {
            type: 'content_block_delta', index: 0,
            delta: { type: 'text_delta', text: 'connector ready' },
          },
        }
        yield {
          type: 'result', subtype: 'success', session_id: 'fixture-session',
          is_error: false, result: 'connector ready', duration_ms: 4, duration_api_ms: 2,
          num_turns: 1, stop_reason: null, total_cost_usd: 0,
          usage: {
            input_tokens: 1, output_tokens: 1,
            cache_creation_input_tokens: 0, cache_read_input_tokens: 0,
          },
          modelUsage: {}, permission_denials: [], uuid: 'fixture-result',
        }
      })()
      stream.supportedCommands = async () => []
      stream.mcpServerStatus = async () => {
        while (statusReleaseFile && !fs.existsSync(statusReleaseFile)) {
          await new Promise((resolve) => setTimeout(resolve, 10))
        }
        let tools = ${JSON.stringify(statusTools)}
        if (statusToolsFile) {
          try { tools = JSON.parse(fs.readFileSync(statusToolsFile, 'utf8')) }
          catch {}
        }
        return [{ name: 'VICE', status: 'connected', tools }]
      }
      return stream
    }

    export async function startup() {
      record({ kind: 'prewarm' })
      return { query() { throw new Error('promoted turn reused a warm query') }, close() {} }
    }
  `
  const sdkURL = `data:text/javascript;base64,${Buffer.from(sdkSource).toString('base64')}`
  const oauthSource = oauthReleaseFile ? `
    import fs from 'node:fs'
    const releaseFile = ${JSON.stringify(oauthReleaseFile)}
    let authenticated = false
    const waitForRelease = async () => {
      while (!fs.existsSync(releaseFile)) {
        await new Promise((resolve) => setTimeout(resolve, 10))
      }
    }
    export function createMcpOAuthManager() {
      return {
        async applyAuthorization(loaded) {
          loaded.authorizationStates = loaded.authorizationStates || {}
          for (const name of Object.keys(loaded.oauthBindings || {})) {
            loaded.authorizationStates[name] = authenticated ? 'authenticated' : 'needs-auth'
            if (authenticated && loaded.servers?.[name]) {
              loaded.servers[name].headersHelper = 'fixture-oauth-header-helper'
            }
          }
          return loaded
        },
        async authorize(server, { onAuthorizationUrl }) {
          onAuthorizationUrl('https://example.test/claude-mcp-login')
          await waitForRelease()
          authenticated = true
          return { method: 'fixture-oauth' }
        },
        async clear() { authenticated = false },
      }
    }
  ` : null
  const oauthURL = oauthSource
    ? `data:text/javascript;base64,${Buffer.from(oauthSource).toString('base64')}` : null
  fs.writeFileSync(path.join(directory, 'hooks.mjs'), `
    const sdkURL = ${JSON.stringify(sdkURL)}
    const oauthURL = ${JSON.stringify(oauthURL)}
    export async function resolve(specifier, context, nextResolve) {
      if (specifier === '@anthropic-ai/claude-agent-sdk') {
        return { url: sdkURL, shortCircuit: true }
      }
      if (oauthURL && (specifier === './mcp-oauth.mjs'
          || specifier.endsWith('/mcp-oauth.mjs'))) {
        return { url: oauthURL, shortCircuit: true }
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

async function startFixture(t, {
  extensions = { mcpServers: [] }, statusTools = [{ name: 'search' }],
  turnReleaseFile = null, oauthReleaseFile = null, statusToolsFile = null,
  statusReleaseFile = null,
  environment = {},
} = {}) {
  const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-claude-mcp-proof-'))
  const capture = path.join(support, 'sdk-events.ndjson')
  const loader = writeSDKLoader(support, capture, statusTools, {
    turnReleaseFile, oauthReleaseFile, statusToolsFile, statusReleaseFile,
  })
  fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify(extensions))
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
      ...environment,
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
    support,
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

function replaceExtensions(fixture, extensions) {
  fs.writeFileSync(path.join(fixture.support, 'extensions.json'), JSON.stringify(extensions))
}

function capturedSDKEvents(fixture) {
  if (!fs.existsSync(fixture.capture)) return []
  return fs.readFileSync(fixture.capture, 'utf8').trim().split('\n')
    .filter(Boolean).map(JSON.parse)
}

function sendTurn(fixture, id, claim) {
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'send', id, convId: 'conversation-1',
    sessionId: 'fixture-session-before-auth', cwd: path.dirname(fixture.capture),
    permissionMode: 'default', prompt: 'Use the newly authenticated connector.',
    history: [
      { role: 'user', text: 'Earlier question.' },
      { role: 'assistant', text: 'Earlier answer.' },
      { role: 'user', text: 'Use the newly authenticated connector.' },
    ],
    mcpReadinessClaims: [claim],
  })}\n`)
}

function sendOrdinaryTurn(fixture, id, sessionId = null) {
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'send', id, convId: 'conversation-1', sessionId,
    cwd: path.dirname(fixture.capture), permissionMode: 'default',
    prompt: 'Continue without an MCP readiness claim.',
    history: [{ role: 'user', text: 'Continue without an MCP readiness claim.' }],
  })}\n`)
}

test('a provider-owned connector absent from local config proves tools on the exact Claude query', async (t) => {
  const claim = {
    name: 'VICE', changeId: 'connector-generation-1', source: 'providerConnector',
    accountInstanceId, routeIdentity,
  }
  const fixture = await startFixture(t, { extensions: extensionsWithReadiness(claim) })
  sendTurn(fixture, 'connector-proof', claim)

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'connector-proof'
      && (event.type === 'done' || event.type === 'error')),
    'connector turn terminal', fixture,
  )

  assert.deepEqual(terminal, { type: 'done', id: 'connector-proof' })
  const proofIndex = fixture.events.findIndex((event) =>
    event.type === 'mcp_readiness_proof' && event.id === 'connector-proof')
  const sessionIndex = fixture.events.findIndex((event) =>
    event.type === 'session' && event.id === 'connector-proof')
  assert.ok(proofIndex >= 0 && sessionIndex > proofIndex)
  assert.deepEqual(fixture.events[proofIndex], {
    type: 'mcp_readiness_proof', id: 'connector-proof',
    name: 'VICE', changeId: 'connector-generation-1', source: 'providerConnector',
    accountInstanceId, routeIdentity,
    status: 'connected', tools: 1,
  })
  const sdkEvents = fs.readFileSync(fixture.capture, 'utf8').trim().split('\n').map(JSON.parse)
  assert.equal(
    sdkEvents.find((event) => event.kind === 'query').mounted.includes('VICE'),
    false,
    'provider-owned connectors are mounted by Claude rather than copied into local extensions')
  assert.ok(sdkEvents.some((event) => event.kind === 'prompt'))
})

test('a configured same-name server cannot satisfy a provider-owned connector claim', async (t) => {
  const claim = {
    name: 'VICE', changeId: 'provider-connector-generation', source: 'providerConnector',
    accountInstanceId, routeIdentity,
  }
  const fixture = await startFixture(t, { extensions: extensionsWithReadiness(claim, [{
      id: '7f661a72-4885-42ad-bce1-242b6741d88a',
      name: 'VICE', enabled: true, transport: 'stdio', command: '/bin/echo',
    }]) })
  sendTurn(fixture, 'connector-config-collision', claim)

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'connector-config-collision'
      && (event.type === 'done' || event.type === 'error')),
    'provider connector/config collision', fixture,
  )

  assert.equal(terminal.type, 'error')
  assert.match(terminal.message, /provider-owned.*conflicts with a configured server/i)
  assert.equal(fixture.events.some((event) =>
    event.type === 'mcp_readiness_proof' && event.id === 'connector-config-collision'), false)
  assert.equal(fs.existsSync(fixture.capture), false,
    'a configured server must not be queried as evidence for a provider-owned connector')
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
  test(`a Claude readiness claim for the wrong ${identityCase.label} is rejected before the provider query`, async (t) => {
    const fixture = await startFixture(t)
    const id = `wrong-${identityCase.label}-proof`
    sendTurn(fixture, id, {
      name: 'VICE', changeId: `wrong-${identityCase.label}-generation`,
      source: 'providerConnector', accountInstanceId, routeIdentity,
      ...identityCase.override,
    })

    const rejection = await waitFor(
      () => fixture.events.find((event) => event.id === id
        && ['control_error', 'done', 'error'].includes(event.type)),
      `wrong ${identityCase.label} rejection`, fixture,
    )

    assert.equal(rejection.type, 'control_error')
    assert.match(rejection.message, new RegExp(identityCase.label, 'i'))
    assert.equal(fixture.events.some((event) =>
      event.type === 'mcp_readiness_proof' && event.id === id), false)
    assert.equal(fixture.events.some((event) =>
      event.type === 'session' && event.id === id), false)
    assert.equal(fs.existsSync(fixture.capture), false,
      'identity-mismatched readiness must be rejected before constructing a provider query')
  })
}

for (const operation of ['mcp_authorize', 'mcp_clear_auth']) {
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
    test(`${operation} for the wrong Claude ${identityCase.label} is rejected before credential access`, async (t) => {
      const fixture = await startFixture(t)
      const id = `${operation}-wrong-${identityCase.label}`
      fixture.child.stdin.write(`${JSON.stringify({
        type: operation, id, name: 'VICE', attemptId: `${id}-attempt`,
        source: 'providerConnector', accountInstanceId, routeIdentity,
        operation: operation === 'mcp_clear_auth' ? 'clear' : 'authorize',
        ...identityCase.override,
      })}\n`)

      const rejection = await waitFor(
        () => fixture.events.find((event) =>
          event.type === 'mcp_authorize_error' && event.id === id),
        `${operation} wrong ${identityCase.label} rejection`, fixture,
      )
      assert.match(rejection.message, /different provider account or route/i)
      assert.equal(fs.existsSync(fixture.capture), false,
        'an identity mismatch must be rejected before constructing a credential-bearing query')
    })
  }
}

test('a configured claim absent from local config fails before the Claude prompt', async (t) => {
  const claim = {
    name: 'VICE', changeId: 'configured-generation-1', source: 'configured',
    serverId: '7f661a72-4885-42ad-bce1-242b6741d88a',
    accountInstanceId, routeIdentity,
  }
  const fixture = await startFixture(t, { extensions: extensionsWithReadiness(claim) })
  sendTurn(fixture, 'configured-missing', claim)

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'configured-missing'
      && (event.type === 'done' || event.type === 'error')),
    'configured claim failure', fixture,
  )

  assert.equal(terminal.type, 'error')
  assert.match(terminal.message, /absent from this provider configuration/i)
  assert.equal(fixture.events.some((event) =>
    event.type === 'mcp_readiness_proof' && event.id === 'configured-missing'), false)
  assert.equal(fs.existsSync(fixture.capture), false,
    'the provider query and its prompt must not exist when the configured mount is absent')
})

test('a same-name replacement cannot satisfy the removed configured server claim', async (t) => {
  const claim = {
    name: 'VICE', changeId: 'removed-row-generation', source: 'configured',
    serverId: '7f661a72-4885-42ad-bce1-242b6741d88a',
    accountInstanceId, routeIdentity,
  }
  const fixture = await startFixture(t, { extensions: extensionsWithReadiness(claim, [{
      id: 'e65b4b19-4cf3-4f45-b65d-4536bf6bf023',
      name: 'VICE', enabled: true, transport: 'stdio', command: '/bin/echo',
    }]) })
  sendTurn(fixture, 'same-name-replacement', claim)

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'same-name-replacement'
      && (event.type === 'done' || event.type === 'error')),
    'stable identity mismatch', fixture,
  )

  assert.equal(terminal.type, 'error')
  assert.match(terminal.message, /absent from this provider configuration/i)
  assert.equal(fixture.events.some((event) =>
    event.type === 'mcp_readiness_proof' && event.id === 'same-name-replacement'), false)
  assert.equal(fs.existsSync(fixture.capture), false)
})

test('configured Claude auth leaves an active turn intact and gates the next send on fresh tools', async (t) => {
  const controls = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-claude-active-auth-'))
  const authRelease = path.join(controls, 'complete-auth')
  const turnRelease = path.join(controls, 'complete-active-turn')
  t.after(() => fs.rmSync(controls, { recursive: true, force: true }))
  const fixture = await startFixture(t, {
    extensions: {
      mcpServers: [{
        id: configuredServerId,
        name: 'VICE', enabled: true, transport: 'http', url: 'https://mcp.example/vice',
      }],
    },
    oauthReleaseFile: authRelease,
    turnReleaseFile: turnRelease,
  })
  const activeTurnId = 'claude-active-before-mcp-auth'
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'send', id: activeTurnId, convId: 'conversation-active-before-auth',
    sessionId: 'fixture-session-before-auth', cwd: fixture.support,
    permissionMode: 'default', prompt: 'Keep this already-running turn intact.',
    history: [{ role: 'user', text: 'Keep this already-running turn intact.' }],
  })}\n`)
  await waitFor(() => {
    if (!fs.existsSync(fixture.capture)) return false
    return fs.readFileSync(fixture.capture, 'utf8').includes('"kind":"prompt"')
  }, 'active pre-auth Claude prompt', fixture)

  const authorizationId = 'authorize-during-active-claude-turn'
  const changeId = `${authorizationId}-attempt`
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'mcp_authorize', id: authorizationId, name: 'VICE', attemptId: changeId,
    source: 'configured', serverId: configuredServerId,
    accountInstanceId, routeIdentity, operation: 'authorize',
  })}\n`)
  await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_url'
      && event.id === authorizationId),
    'active-turn Claude authorization URL', fixture,
  )
  fs.writeFileSync(authRelease, 'complete')
  const authorization = await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_ok'
      && event.id === authorizationId),
    'active-turn Claude authorization completion', fixture,
  )
  assert.equal(authorization.changeId, changeId)
  // The app persists the exact post-auth obligation before dispatching the next turn. This runtime
  // harness must model that durable publication explicitly; agentd never writes app-owned state.
  replaceExtensions(fixture, configuredExtensionsWithReadiness(changeId))
  assert.equal(fixture.events.some((event) => event.id === activeTurnId
    && ['done', 'error'].includes(event.type)), false,
  'credential publication must not interrupt or replace the already-running Claude query')
  assert.equal(capturedQueryCount(fixture), 1,
    'authentication invalidates only future snapshots; it cannot reconstruct the active query')

  fs.writeFileSync(turnRelease, 'complete')
  assert.deepEqual(await waitFor(
    () => fixture.events.find((event) => event.id === activeTurnId
      && ['done', 'error'].includes(event.type)),
    'active pre-auth Claude turn terminal', fixture,
  ), { type: 'done', id: activeTurnId })

  const nextTurnId = 'first-turn-after-active-claude-auth'
  sendTurn(fixture, nextTurnId, {
    name: 'VICE', changeId, source: 'configured', serverId: configuredServerId,
    accountInstanceId, routeIdentity,
  })
  assert.deepEqual(await waitFor(
    () => fixture.events.find((event) => event.id === nextTurnId
      && ['done', 'error'].includes(event.type)),
    'first post-auth Claude turn terminal', fixture,
  ), { type: 'done', id: nextTurnId })
  assert.deepEqual(fixture.events.find((event) =>
    event.type === 'mcp_readiness_proof' && event.id === nextTurnId), {
    type: 'mcp_readiness_proof', id: nextTurnId,
    name: 'VICE', changeId, source: 'configured', serverId: configuredServerId,
    accountInstanceId, routeIdentity, status: 'connected', tools: 1,
  })
  const queries = fs.readFileSync(fixture.capture, 'utf8').trim().split('\n')
    .filter(Boolean).map(JSON.parse).filter((event) => event.kind === 'query')
  assert.equal(queries.length, 2)
  assert.equal(queries[0].resume, 'fixture-session-before-auth')
  assert.equal(queries[1].resume, null,
    'the first post-auth Claude query must not resume the pre-auth provider session')
})

test('a Claude connected row with zero tools cannot consume the claim or receive the prompt', async (t) => {
  const claim = {
    name: 'VICE', changeId: 'connector-zero-tools', source: 'providerConnector',
    accountInstanceId, routeIdentity,
  }
  const fixture = await startFixture(t, {
    extensions: extensionsWithReadiness(claim), statusTools: [],
    environment: { MECHANICIAN_MCP_PROMOTED_READINESS_TIMEOUT_MS: '700' },
  })
  sendTurn(fixture, 'zero-tool-connector', claim)

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'zero-tool-connector'
      && (event.type === 'done' || event.type === 'error')),
    'zero-tool connector failure', fixture,
  )

  assert.equal(terminal.type, 'error')
  assert.match(terminal.message, /did not finish mounting/i)
  assert.equal(fixture.events.some((event) =>
    event.type === 'mcp_readiness_proof' && event.id === 'zero-tool-connector'), false)
  const sdkEvents = fs.readFileSync(fixture.capture, 'utf8').trim().split('\n').map(JSON.parse)
  assert.equal(sdkEvents.some((event) => event.kind === 'prompt'), false)
})

test('configured Claude readiness survives zero tools and proves the same generation on retry', async (t) => {
  const controls = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-claude-mcp-retry-'))
  const statusToolsFile = path.join(controls, 'status-tools.json')
  fs.writeFileSync(statusToolsFile, '[]')
  t.after(() => fs.rmSync(controls, { recursive: true, force: true }))
  const changeId = 'configured-zero-tools-retry-generation'
  const fixture = await startFixture(t, {
    extensions: configuredExtensionsWithReadiness(changeId),
    statusToolsFile,
    environment: { MECHANICIAN_MCP_PROMOTED_READINESS_TIMEOUT_MS: '700' },
  })
  const claim = {
    name: 'VICE', changeId, source: 'configured', serverId: configuredServerId,
    accountInstanceId, routeIdentity,
  }

  sendTurn(fixture, 'configured-zero-tools-first-gate', claim)
  const first = await waitFor(
    () => fixture.events.find((event) => event.id === 'configured-zero-tools-first-gate'
      && ['done', 'error'].includes(event.type)),
    'configured Claude zero-tool gate', fixture,
  )
  assert.equal(first.type, 'error')
  assert.match(first.message, /did not finish mounting/i)
  assert.equal(fixture.events.some((event) => event.type === 'mcp_readiness_proof'
    && event.id === 'configured-zero-tools-first-gate'), false)
  let sdkEvents = fs.readFileSync(fixture.capture, 'utf8').trim().split('\n').map(JSON.parse)
  assert.equal(sdkEvents.some((event) => event.kind === 'prompt'), false)

  fs.writeFileSync(statusToolsFile, JSON.stringify([{ name: 'search' }]))
  sendTurn(fixture, 'configured-tools-ready-retry', claim)
  const retry = await waitFor(
    () => fixture.events.find((event) => event.id === 'configured-tools-ready-retry'
      && ['done', 'error'].includes(event.type)),
    'configured Claude exact-generation retry', fixture,
  )
  assert.deepEqual(retry, { type: 'done', id: 'configured-tools-ready-retry' })
  assert.deepEqual(fixture.events.find((event) => event.type === 'mcp_readiness_proof'
    && event.id === 'configured-tools-ready-retry'), {
    type: 'mcp_readiness_proof', id: 'configured-tools-ready-retry',
    name: 'VICE', changeId, source: 'configured', serverId: configuredServerId,
    accountInstanceId, routeIdentity, status: 'connected', tools: 1,
  })
  sdkEvents = fs.readFileSync(fixture.capture, 'utf8').trim().split('\n').map(JSON.parse)
  assert.equal(sdkEvents.filter((event) => event.kind === 'query').length, 2)
  assert.equal(sdkEvents.filter((event) => event.kind === 'prompt').length, 1,
    'only the successful retry may deliver the prompt')
})

test('Claude waits through connected zero tools until the same query exposes inventory', async (t) => {
  const controls = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-claude-zero-to-tools-'))
  const statusToolsFile = path.join(controls, 'status-tools.json')
  fs.writeFileSync(statusToolsFile, '[]')
  t.after(() => fs.rmSync(controls, { recursive: true, force: true }))
  const changeId = 'configured-zero-to-positive-same-query'
  const fixture = await startFixture(t, {
    extensions: configuredExtensionsWithReadiness(changeId), statusToolsFile,
    environment: { MECHANICIAN_MCP_PROMOTED_READINESS_TIMEOUT_MS: '2000' },
  })
  sendTurn(fixture, 'configured-zero-to-positive-same-query', {
    name: 'VICE', changeId, source: 'configured', serverId: configuredServerId,
    accountInstanceId, routeIdentity,
  })
  await waitFor(
    () => fixture.events.find((event) =>
      event.id === 'configured-zero-to-positive-same-query'
        && event.type === 'status' && event.status === 'connecting_extensions'),
    'Claude zero-tool readiness wait', fixture,
  )
  await new Promise((resolve) => setTimeout(resolve, 500))
  assert.equal(fixture.events.some((event) =>
    event.id === 'configured-zero-to-positive-same-query'
      && ['done', 'error'].includes(event.type)), false,
  'connected with zero tools remains an initializing state for a promoted post-auth server')
  fs.writeFileSync(statusToolsFile, JSON.stringify([{ name: 'search' }]))

  const terminal = await waitFor(
    () => fixture.events.find((event) =>
      event.id === 'configured-zero-to-positive-same-query'
        && ['done', 'error'].includes(event.type)),
    'Claude same-query tool inventory', fixture,
  )
  assert.deepEqual(terminal, { type: 'done', id: 'configured-zero-to-positive-same-query' })
  assert.equal(capturedQueryCount(fixture), 1)
  assert.equal(capturedSDKEvents(fixture).filter((event) => event.kind === 'prompt').length, 1)
  assert.equal(fixture.events.find((event) => event.type === 'mcp_readiness_proof'
    && event.id === 'configured-zero-to-positive-same-query')?.tools, 1)
})

test('Claude permanent connected-zero inventory times out before prompt delivery', async (t) => {
  const changeId = 'configured-permanent-zero-timeout'
  const fixture = await startFixture(t, {
    extensions: configuredExtensionsWithReadiness(changeId), statusTools: [],
    environment: { MECHANICIAN_MCP_PROMOTED_READINESS_TIMEOUT_MS: '700' },
  })
  const startedAt = Date.now()
  sendTurn(fixture, 'configured-permanent-zero-timeout', {
    name: 'VICE', changeId, source: 'configured', serverId: configuredServerId,
    accountInstanceId, routeIdentity,
  })
  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'configured-permanent-zero-timeout'
      && ['done', 'error'].includes(event.type)),
    'Claude permanent zero-tool timeout', fixture,
  )
  assert.equal(terminal.type, 'error')
  assert.match(terminal.message, /did not finish mounting/i)
  assert.ok(Date.now() - startedAt >= 600, 'the promoted readiness window must actually poll')
  assert.equal(capturedQueryCount(fixture), 1)
  assert.equal(capturedSDKEvents(fixture).some((event) => event.kind === 'prompt'), false)
  assert.equal(fixture.events.some((event) => event.type === 'mcp_readiness_proof'
    && event.id === 'configured-permanent-zero-timeout'), false)
})

test('Claude accepts request generation B over local A only when the durable ledger says B', async (t) => {
  const fixture = await startFixture(t, {
    extensions: configuredExtensionsWithReadiness('cross-daemon-generation-a'),
    statusTools: [],
    environment: { MECHANICIAN_MCP_PROMOTED_READINESS_TIMEOUT_MS: '700' },
  })
  sendTurn(fixture, 'establish-local-generation-a', {
    name: 'VICE', changeId: 'cross-daemon-generation-a', source: 'configured',
    serverId: configuredServerId, accountInstanceId, routeIdentity,
  })
  const first = await waitFor(
    () => fixture.events.find((event) => event.id === 'establish-local-generation-a'
      && (event.type === 'done' || event.type === 'error')),
    'local generation A failure', fixture,
  )
  assert.equal(first.type, 'error')
  assert.match(first.message, /did not finish mounting/i)

  replaceExtensions(fixture, configuredExtensionsWithReadiness('cross-daemon-generation-b'))
  sendTurn(fixture, 'adopt-durable-generation-b', {
    name: 'VICE', changeId: 'cross-daemon-generation-b', source: 'configured',
    serverId: configuredServerId, accountInstanceId, routeIdentity,
  })
  const second = await waitFor(
    () => fixture.events.find((event) => event.id === 'adopt-durable-generation-b'
      && (event.type === 'done' || event.type === 'error')),
    'durable generation B failure', fixture,
  )
  assert.equal(second.type, 'error')
  assert.match(second.message, /did not finish mounting/i,
    'ledger-authoritative B must replace stale local A and reach the provider inventory gate')
  assert.doesNotMatch(second.message, /generation changed/i)
  assert.equal(capturedQueryCount(fixture), 2)
})

test('Claude rejects request generation A when local and durable authorities both say B', async (t) => {
  const fixture = await startFixture(t, {
    extensions: configuredExtensionsWithReadiness('cross-daemon-generation-b'),
    statusTools: [],
    environment: { MECHANICIAN_MCP_PROMOTED_READINESS_TIMEOUT_MS: '700' },
  })
  sendTurn(fixture, 'establish-local-generation-b', {
    name: 'VICE', changeId: 'cross-daemon-generation-b', source: 'configured',
    serverId: configuredServerId, accountInstanceId, routeIdentity,
  })
  const first = await waitFor(
    () => fixture.events.find((event) => event.id === 'establish-local-generation-b'
      && (event.type === 'done' || event.type === 'error')),
    'local generation B failure', fixture,
  )
  assert.equal(first.type, 'error')
  assert.match(first.message, /did not finish mounting/i)

  sendTurn(fixture, 'reject-stale-generation-a', {
    name: 'VICE', changeId: 'cross-daemon-generation-a', source: 'configured',
    serverId: configuredServerId, accountInstanceId, routeIdentity,
  })
  const stale = await waitFor(
    () => fixture.events.find((event) => event.id === 'reject-stale-generation-a'
      && (event.type === 'done' || event.type === 'error')),
    'stale generation A rejection', fixture,
  )
  assert.equal(stale.type, 'error')
  assert.match(stale.message, /generation changed/i)
  assert.equal(capturedQueryCount(fixture), 1,
    'a request contradicted by the durable ledger must fail before another provider query')
})

test('a fresh Claude daemon rejects request A when the durable ledger says B', async (t) => {
  const fixture = await startFixture(t, {
    extensions: configuredExtensionsWithReadiness('fresh-durable-generation-b'),
  })
  sendTurn(fixture, 'fresh-stale-request-a', {
    name: 'VICE', changeId: 'fresh-stale-generation-a', source: 'configured',
    serverId: configuredServerId, accountInstanceId, routeIdentity,
  })

  const stale = await waitFor(
    () => fixture.events.find((event) => event.id === 'fresh-stale-request-a'
      && ['done', 'error'].includes(event.type)),
    'fresh Claude durable-generation rejection', fixture,
  )
  assert.equal(stale.type, 'error')
  assert.match(stale.message, /generation changed/i)
  assert.equal(capturedQueryCount(fixture), 0,
    'a fresh daemon must reject the stale request before constructing its first query')
  assert.equal(fixture.events.some((event) => event.type === 'session'
    && event.id === 'fresh-stale-request-a'), false)
})

test('a fresh Claude daemon rejects request A after a sibling consumed its ledger row', async (t) => {
  const fixture = await startFixture(t, { extensions: {
    mcpServers: [{
      id: configuredServerId,
      name: 'VICE', enabled: true, transport: 'stdio', command: '/bin/echo',
    }],
    pendingMCPReadiness: { byAccess: { anthropic_api: [] } },
  } })
  sendTurn(fixture, 'fresh-consumed-request-a', {
    name: 'VICE', changeId: 'fresh-consumed-generation-a', source: 'configured',
    serverId: configuredServerId, accountInstanceId, routeIdentity,
  })

  const stale = await waitFor(
    () => fixture.events.find((event) => event.id === 'fresh-consumed-request-a'
      && ['done', 'error'].includes(event.type)),
    'fresh Claude consumed-ledger rejection', fixture,
  )
  assert.equal(stale.type, 'error')
  assert.match(stale.message, /generation changed/i)
  assert.equal(capturedQueryCount(fixture), 0)
  assert.equal(fixture.events.some((event) => event.type === 'session'
    && event.id === 'fresh-consumed-request-a'), false)
})

test('Claude revalidates the durable claim after async tool polling before prompt delivery', async (t) => {
  const controls = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-claude-consume-poll-'))
  const statusToolsFile = path.join(controls, 'status-tools.json')
  const statusReleaseFile = path.join(controls, 'release-status')
  fs.writeFileSync(statusToolsFile, JSON.stringify([{ name: 'search' }]))
  t.after(() => fs.rmSync(controls, { recursive: true, force: true }))
  const changeId = 'claude-consumed-during-tool-poll'
  const fixture = await startFixture(t, {
    extensions: configuredExtensionsWithReadiness(changeId),
    statusToolsFile, statusReleaseFile,
  })
  sendTurn(fixture, 'claude-consumed-during-poll', {
    name: 'VICE', changeId, source: 'configured', serverId: configuredServerId,
    accountInstanceId, routeIdentity,
  })
  await waitFor(
    () => capturedQueryCount(fixture) === 1,
    'Claude readiness query before sibling consumption', fixture,
  )

  replaceExtensions(fixture, {
    mcpServers: [{
      id: configuredServerId,
      name: 'VICE', enabled: true, transport: 'stdio', command: '/bin/echo',
    }],
    pendingMCPReadiness: { byAccess: { anthropic_api: [] } },
  })
  fs.writeFileSync(statusReleaseFile, 'release')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'claude-consumed-during-poll'
      && ['done', 'error'].includes(event.type)),
    'Claude async-consumption rejection', fixture,
  )
  assert.equal(terminal.type, 'error')
  assert.match(terminal.message, /generation changed/i)
  assert.equal(capturedSDKEvents(fixture).some((event) => event.kind === 'prompt'), false)
  assert.equal(fixture.events.some((event) => event.type === 'mcp_readiness_proof'
    && event.id === 'claude-consumed-during-poll'), false)
})

test('Claude prunes stale local A after sibling B was durably consumed before an ordinary turn', async (t) => {
  const fixture = await startFixture(t, {
    extensions: configuredExtensionsWithReadiness('consumed-sibling-generation-a'),
    statusTools: [],
    environment: { MECHANICIAN_MCP_PROMOTED_READINESS_TIMEOUT_MS: '700' },
  })
  sendTurn(fixture, 'establish-local-a-before-sibling-consumption', {
    name: 'VICE', changeId: 'consumed-sibling-generation-a', source: 'configured',
    serverId: configuredServerId, accountInstanceId, routeIdentity,
  })
  const failedA = await waitFor(
    () => fixture.events.find((event) => event.id === 'establish-local-a-before-sibling-consumption'
      && ['done', 'error'].includes(event.type)),
    'local A zero-tool failure before sibling consumption', fixture,
  )
  assert.equal(failedA.type, 'error')

  replaceExtensions(fixture, {
    mcpServers: [{
      id: configuredServerId,
      name: 'VICE', enabled: true, transport: 'stdio', command: '/bin/echo',
    }],
    pendingMCPReadiness: { byAccess: { anthropic_api: [] } },
  })
  sendOrdinaryTurn(fixture, 'ordinary-after-sibling-b-consumed', 'fixture-session-after-b')
  const ordinary = await waitFor(
    () => fixture.events.find((event) => event.id === 'ordinary-after-sibling-b-consumed'
      && ['done', 'error'].includes(event.type)),
    'ordinary turn after sibling B consumption', fixture,
  )

  assert.deepEqual(ordinary, { type: 'done', id: 'ordinary-after-sibling-b-consumed' })
  assert.equal(fixture.events.some((event) => event.type === 'mcp_readiness_proof'
    && event.id === 'ordinary-after-sibling-b-consumed'), false)
  assert.equal(capturedQueryCount(fixture), 2,
    'the stale daemon-local A fact must be pruned instead of poisoning a no-claim turn')
})

test('Claude prewarm proceeds after a sibling consumes the same local readiness generation', async (t) => {
  const changeId = 'same-generation-consumed-before-claude-prewarm'
  const fixture = await startFixture(t, {
    extensions: configuredExtensionsWithReadiness(changeId),
    statusTools: [],
    environment: { MECHANICIAN_MCP_PROMOTED_READINESS_TIMEOUT_MS: '700' },
  })
  sendTurn(fixture, 'establish-local-a-before-claude-prewarm', {
    name: 'VICE', changeId, source: 'configured', serverId: configuredServerId,
    accountInstanceId, routeIdentity,
  })
  const failed = await waitFor(
    () => fixture.events.find((event) =>
      event.id === 'establish-local-a-before-claude-prewarm'
        && ['done', 'error'].includes(event.type)),
    'Claude local readiness observation', fixture,
  )
  assert.equal(failed.type, 'error')

  replaceExtensions(fixture, {
    mcpServers: [{
      id: configuredServerId,
      name: 'VICE', enabled: true, transport: 'stdio', command: '/bin/echo',
    }],
    pendingMCPReadiness: { byAccess: { anthropic_api: [] } },
  })
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'prewarm', id: 'claude-prewarm-after-consumption',
    convId: 'conversation-prewarm', sessionId: 'fixture-session-after-consumption',
    cwd: fixture.support, model: 'claude-sonnet-4-5', permissionMode: 'default',
    projectInstructions: '',
  })}\n`)

  await waitFor(
    () => capturedSDKEvents(fixture).some((event) => event.kind === 'prewarm'),
    'Claude prewarm after durable claim consumption', fixture,
  )
  assert.doesNotMatch(fixture.stderr, /prewarm skipped reason=mcp_credential_boundary/)
})

for (const ledgerCase of [
  {
    label: 'missing sidecar',
    install(fixture) { fs.rmSync(path.join(fixture.support, 'extensions.json')) },
    succeeds: true,
  },
  {
    label: 'legacy sidecar without readiness ledger',
    install(fixture) { replaceExtensions(fixture, { mcpServers: [] }) },
    succeeds: true,
  },
  {
    label: 'valid empty readiness lane',
    install(fixture) {
      replaceExtensions(fixture, {
        mcpServers: [], pendingMCPReadiness: { byAccess: { anthropic_api: [] } },
      })
    },
    succeeds: true,
  },
  {
    label: 'malformed readiness ledger',
    install(fixture) {
      replaceExtensions(fixture, { mcpServers: [], pendingMCPReadiness: [] })
    },
    succeeds: false,
  },
  {
    label: 'malformed readiness row',
    install(fixture) {
      replaceExtensions(fixture, {
        mcpServers: [],
        pendingMCPReadiness: { byAccess: { anthropic_api: [{ changeId: 'partial' }] } },
      })
    },
    succeeds: false,
  },
]) {
  test(`Claude ordinary turn treats ${ledgerCase.label} as ${ledgerCase.succeeds ? 'empty' : 'uncertain'}`, async (t) => {
    const fixture = await startFixture(t)
    ledgerCase.install(fixture)
    sendOrdinaryTurn(fixture, `ordinary-${ledgerCase.label.replaceAll(' ', '-')}`)
    const terminal = await waitFor(
      () => fixture.events.find((event) =>
        event.id === `ordinary-${ledgerCase.label.replaceAll(' ', '-')}`
          && ['done', 'error'].includes(event.type)),
      `${ledgerCase.label} ordinary turn`, fixture,
    )
    if (ledgerCase.succeeds) {
      assert.equal(terminal.type, 'done')
      assert.equal(capturedQueryCount(fixture), 1)
    } else {
      assert.equal(terminal.type, 'error')
      assert.match(terminal.message, /could not verify.*credential generation/i)
      assert.equal(capturedQueryCount(fixture), 0)
    }
    assert.equal(fixture.child.exitCode, null, 'ledger parsing must never exit agentd')
  })
}

function capturedQueryCount(fixture) {
  return capturedSDKEvents(fixture).filter((event) => event.kind === 'query').length
}
