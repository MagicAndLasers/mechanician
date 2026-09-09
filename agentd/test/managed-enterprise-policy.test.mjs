import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { createHash } from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const here = path.dirname(fileURLToPath(import.meta.url))
const agentd = path.resolve(here, '../src/agentd.mjs')
const ambientd = path.resolve(here, '../src/ambientd.mjs')
const accountInstanceId = '7fb9c7eb-e57a-4d95-95a8-c241aa56525a'

function managedServerId({ name, transport, url }) {
  const canonicalURL = new URL(url).href
  const digest = createHash('sha256')
    .update(`mechanician-managed-mcp-v1\0${name}\0${transport}\0${canonicalURL}`)
    .digest('hex')
  return `${digest.slice(0, 8)}-${digest.slice(8, 12)}-5${digest.slice(13, 16)}-`
    + `${((parseInt(digest.slice(16, 18), 16) & 0x3f) | 0x80).toString(16)}`
    + `${digest.slice(18, 20)}-${digest.slice(20, 32)}`
}

async function waitFor(predicate, description, timeout = 5_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.fail(`timed out waiting for ${description}`)
}

function observe(child) {
  const events = []
  let stdout = ''
  let stderr = ''
  child.stdout?.setEncoding('utf8')
  child.stderr?.setEncoding('utf8')
  child.stdout?.on('data', (chunk) => {
    stdout += chunk
    const lines = stdout.split('\n')
    stdout = lines.pop() ?? ''
    for (const line of lines) if (line) events.push(JSON.parse(line))
  })
  child.stderr?.on('data', (chunk) => { stderr += chunk })
  return { child, events, stderr: () => stderr }
}

function managedEnvironment(overrides = {}) {
  return {
    ...process.env,
    MECHANICIAN_MANAGED_POLICY: '1',
    MECHANICIAN_MAX_PERMISSION_MODE: 'default',
    MECHANICIAN_ALLOWED_PROVIDER_ACCESSES: 'anthropic_api',
    MECHANICIAN_ALLOW_USER_EXTENSIONS: '0',
    MECHANICIAN_MANAGED_EXTENSION_SERVERS: '[]',
    MECHANICIAN_ALLOW_UNATTENDED_TASKS: '0',
    ...overrides,
  }
}

test('agentd refuses a provider route outside the managed allowlist before startup', async () => {
  const child = spawn(process.execPath, [agentd], {
    env: managedEnvironment({
      MECHANICIAN_PROVIDER: 'anthropic',
      MECHANICIAN_AUTH: 'apikey',
      MECHANICIAN_ALLOWED_PROVIDER_ACCESSES: 'openai_api',
      ANTHROPIC_API_KEY: '',
      OPENAI_API_KEY: '',
    }),
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const fixture = observe(child)
  const [code, signal] = await once(child, 'exit')

  assert.equal(signal, null)
  assert.equal(code, 78)
  assert.match(fixture.stderr(), /provider route blocked by managed enterprise policy/)
  assert.deepEqual(fixture.events, [])
})

test('agentd refuses Codex when managed-only extension enforcement cannot be proven', async () => {
  const child = spawn(process.execPath, [agentd], {
    env: managedEnvironment({
      MECHANICIAN_PROVIDER: 'codex',
      MECHANICIAN_AUTH: 'subscription',
      MECHANICIAN_ALLOWED_PROVIDER_ACCESSES: 'codex_subscription',
      ANTHROPIC_API_KEY: '',
      OPENAI_API_KEY: '',
    }),
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const fixture = observe(child)
  const [code, signal] = await once(child, 'exit')

  assert.equal(signal, null)
  assert.equal(code, 78)
  assert.match(fixture.stderr(), /managed-only extension enforcement is unavailable/)
  assert.deepEqual(fixture.events, [])
})

test('managed server names cannot replace a Mechanician built-in MCP server', async (t) => {
  const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-managed-collision-'))
  t.after(() => fs.rmSync(support, { recursive: true, force: true }))
  const child = spawn(process.execPath, [agentd], {
    env: managedEnvironment({
      MECHANICIAN_PROVIDER: 'anthropic',
      MECHANICIAN_AUTH: 'apikey',
      MECHANICIAN_SUPPORT_DIR: support,
      MECHANICIAN_CONFIG_DIR: support,
      MECHANICIAN_ACCOUNT_INSTANCE_ID: accountInstanceId,
      MECHANICIAN_ENABLE_MOCK_PROVIDER: '1',
      MECHANICIAN_MANAGED_EXTENSION_SERVERS: JSON.stringify([{
        name: 'artifacts', transport: 'http', url: 'https://replacement.example.test/mcp',
      }, {
        name: 'provider.access', transport: 'http',
        url: 'https://replacement.example.test/normalized-mcp',
      }, {
        name: 'artifacts__evil', transport: 'http',
        url: 'https://replacement.example.test/prefixed-mcp',
      }, {
        name: 'artifacts_', transport: 'http',
        url: 'https://replacement.example.test/trailing-underscore-mcp',
      }]),
      ANTHROPIC_API_KEY: '',
      OPENAI_API_KEY: '',
    }),
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const fixture = observe(child)
  t.after(async () => {
    if (child.exitCode === null) child.kill('SIGKILL')
    if (child.exitCode === null) {
      try { await once(child, 'exit') } catch {}
    }
  })

  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'agentd ready')
  child.stdin.write(`${JSON.stringify({ type: 'mcp_status', id: 'collision-status' })}\n`)
  const status = await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_status_result'
      && event.id === 'collision-status'),
    'managed collision status',
  )
  assert.deepEqual(status.servers, [],
    'a forged managed snapshot cannot substitute for a built-in server')
})

test('ambientd treats a missing explicit managed scheduling grant as disabled', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-managed-ambient-'))
  const support = path.join(root, 'support-that-must-not-be-created')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const env = managedEnvironment({ MECHANICIAN_SUPPORT_DIR: support })
  delete env.MECHANICIAN_ALLOW_UNATTENDED_TASKS
  const child = spawn(process.execPath, [ambientd], {
    env,
    stdio: ['ignore', 'ignore', 'pipe'],
  })
  const fixture = observe(child)
  const [code, signal] = await once(child, 'exit')

  assert.equal(signal, null)
  assert.equal(code, 0)
  assert.match(fixture.stderr(), /unattended work disabled by managed enterprise policy/)
  assert.equal(fs.existsSync(support), false,
    'the disabled scheduler must exit before creating its support directory or lease')
})

test('managed-only extension mode ignores preserved user servers and rejects installs', async (t) => {
  const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-managed-extensions-'))
  fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({
    mcpServers: [{
      id: '6e6292fd-f07f-4ca4-8566-807cd1281733',
      name: 'preserved-personal-server',
      enabled: true,
      transport: 'http',
      url: 'https://personal.example.test/mcp',
    }],
    plugins: [],
  }))
  const managedServer = {
    name: 'managed-corporate-server',
    transport: 'http',
    url: 'https://corporate.example.test/mcp',
    networkScope: 'public',
  }
  const objectPrototypeNameServer = {
    name: 'toString',
    transport: 'http',
    url: 'https://corporate.example.test/to-string',
    networkScope: 'public',
  }
  const env = managedEnvironment({
    MECHANICIAN_PROVIDER: 'anthropic',
    MECHANICIAN_AUTH: 'apikey',
    MECHANICIAN_SUPPORT_DIR: support,
    MECHANICIAN_CONFIG_DIR: support,
    MECHANICIAN_ACCOUNT_INSTANCE_ID: accountInstanceId,
    MECHANICIAN_ENABLE_MOCK_PROVIDER: '1',
    MECHANICIAN_MANAGED_EXTENSION_SERVERS: JSON.stringify([
      managedServer, objectPrototypeNameServer,
    ]),
    ANTHROPIC_API_KEY: '',
    OPENAI_API_KEY: '',
  })
  delete env.MECHANICIAN_ALLOW_USER_EXTENSIONS
  const child = spawn(process.execPath, [agentd], {
    env,
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const fixture = observe(child)
  t.after(async () => {
    if (child.exitCode === null) child.kill('SIGKILL')
    if (child.exitCode === null) {
      try { await once(child, 'exit') } catch {}
    }
    fs.rmSync(support, { recursive: true, force: true })
  })

  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'agentd ready')
  child.stdin.write(`${JSON.stringify({ type: 'mcp_status', id: 'managed-status' })}\n`)
  const status = await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_status_result'
      && event.id === 'managed-status'),
    'managed MCP status',
  )
  assert.deepEqual(status.servers.map((server) => server.name), [
    'managed-corporate-server', 'toString',
  ],
    'the signed server replaces, rather than merges with, the preserved user configuration')

  child.stdin.write(`${JSON.stringify({
    type: 'mcp_status', id: 'managed-connectors', scope: 'connectors',
  })}\n`)
  const connectors = await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_status_result'
      && event.id === 'managed-connectors'),
    'managed connector suppression',
  )
  assert.deepEqual(connectors.servers, [])
  assert.equal(connectors.reason, 'managed-policy')

  child.stdin.write(`${JSON.stringify({
    type: 'mcp_authorize', id: 'blocked-connector', name: 'Google Drive',
    attemptId: 'managed-connector-attempt', source: 'providerConnector',
    accountInstanceId, routeIdentity: 'anthropic:apikey:builtin', operation: 'authorize',
  })}\n`)
  const blockedConnector = await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_error'
      && event.id === 'blocked-connector'),
    'provider connector authorization rejection',
  )
  assert.match(blockedConnector.message, /connectors are disabled by managed enterprise policy/)

  child.stdin.write(`${JSON.stringify({
    type: 'mcp_authorize', id: 'managed-server-oauth', name: managedServer.name,
    attemptId: 'managed-server-attempt', source: 'configured',
    serverId: managedServerId(managedServer), accountInstanceId,
    routeIdentity: 'anthropic:apikey:builtin', operation: 'authorize',
  })}\n`)
  const managedOAuth = await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_error'
      && event.id === 'managed-server-oauth'),
    'managed server OAuth limitation',
  )
  assert.match(managedOAuth.message, /not available in this release/)

  child.stdin.write(`${JSON.stringify({
    type: 'claude_plugins', id: 'managed-install', action: 'addMarketplace',
    source: 'https://example.test/marketplace.json',
  })}\n`)
  const blocked = await waitFor(
    () => fixture.events.find((event) => event.type === 'claude_plugins_result'
      && event.id === 'managed-install'),
    'managed plugin rejection',
  )
  assert.equal(blocked.ok, false)
  assert.match(blocked.message, /blocked by managed enterprise policy/)
  assert.match(fs.readFileSync(path.join(support, 'extensions.json'), 'utf8'),
    /preserved-personal-server/)
})
