import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import {
  AUTHORITY_INBOX_PROTOCOL,
  createAuthorityInboxEnvelope,
  publishAuthorityInboxEnvelope,
  readAuthorityInboxEnvelope,
} from '../src/authority-inbox-envelope.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const ambientd = path.resolve(here, '../src/ambientd.mjs')
const agentdSource = fs.readFileSync(path.resolve(here, '../src/agentd.mjs'), 'utf8')

test('interactive scheduling mutations round-trip through the app-owned definition store', () => {
  assert.match(agentdSource, /type: 'ambient_task_mutation_request'/)
  assert.match(agentdSource, /case 'ambient_task_mutation_response'/)
  assert.doesNotMatch(agentdSource, /function writeTasks\s*\(/)
  assert.match(agentdSource, /AMBIENT_RUNTIME_FILE/)
})

async function waitFor(predicate, description, timeout = 5_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 20))
  }
  assert.fail(`timed out waiting for ${description}`)
}

function readJSON(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')) } catch { return null }
}

function writeJSONAtomic(file, value) {
  const temp = `${file}.${process.pid}.${Math.random().toString(16).slice(2)}.tmp`
  fs.writeFileSync(temp, JSON.stringify(value, null, 2))
  fs.renameSync(temp, file)
}

function writeProject(support, id, cwd = '') {
  const workspaces = path.join(support, 'workspaces')
  fs.mkdirSync(workspaces, { recursive: true })
  fs.writeFileSync(path.join(workspaces, `${id}.json`), JSON.stringify({ id, cwd }, null, 2))
}

function writeFakeSDKLoader(support) {
  const releaseFile = path.join(support, 'release-fake-query')
  const sdkSource = `
    import fs from 'node:fs'
    const pause = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))
    export function createSdkMcpServer(config) { return config }
    export function tool(name, description, schema, handler) {
      return { name, description, schema, handler }
    }
    export async function* query({ options } = {}) {
      const optionsResult = process.env.MECHANICIAN_AMBIENT_TEST_OPTIONS_RESULT
      if (optionsResult) {
        fs.writeFileSync(optionsResult, JSON.stringify({
          settings: options?.settings ?? null,
          strictMcpConfig: options?.strictMcpConfig ?? null,
          plugins: options?.plugins ?? null,
          settingSources: options?.settingSources ?? null,
          mcpServerNames: Object.keys(options?.mcpServers ?? {}),
        }))
      }
      const artifactJSON = process.env.MECHANICIAN_AMBIENT_TEST_ARTIFACT
      if (artifactJSON) {
        const artifactRelease = process.env.MECHANICIAN_AMBIENT_TEST_ARTIFACT_RELEASE
        while (artifactRelease && !fs.existsSync(artifactRelease)) await pause(10)
        const requested = JSON.parse(artifactJSON)
        const requests = Array.isArray(requested) ? requested : [requested]
        const handler = options?.mcpServers?.artifacts?.tools
          ?.find((candidate) => candidate.name === 'CreateOrUpdateArtifact')?.handler
        let observation
        try {
          const results = []
          for (const request of requests) results.push(await handler(request))
          observation = { results }
        } catch (error) {
          observation = { error: String(error?.message || error) }
        }
        const resultFile = process.env.MECHANICIAN_AMBIENT_TEST_ARTIFACT_RESULT
        if (resultFile) fs.writeFileSync(resultFile, JSON.stringify(observation))
        if (observation.error) throw new Error(observation.error)
      }
      // Drive the lane's own canUseTool exactly as the engine would, so the guard is exercised
      // through ambientd rather than reimplemented by the test.
      const probeJSON = process.env.MECHANICIAN_AMBIENT_TEST_PERMISSION_PROBE
      if (probeJSON) {
        const probes = JSON.parse(probeJSON)
        const verdicts = []
        for (const probe of probes) {
          if (typeof options?.canUseTool !== 'function') {
            verdicts.push({ tool: probe.tool, behavior: 'NO_CANUSETOOL' })
            continue
          }
          const decision = await options.canUseTool(probe.tool, probe.input, {})
          verdicts.push({ tool: probe.tool, behavior: decision?.behavior, message: decision?.message })
        }
        fs.writeFileSync(process.env.MECHANICIAN_AMBIENT_TEST_PERMISSION_RESULT,
          JSON.stringify({ verdicts, disallowedTools: options?.disallowedTools ?? null }))
      }
      const releaseFile = process.env.MECHANICIAN_AMBIENT_TEST_RELEASE
      while (!fs.existsSync(releaseFile)) await pause(10)
      yield { type: 'assistant', message: { content: [{ type: 'text', text: 'fixture result' }] } }
      const denialsJSON = process.env.MECHANICIAN_AMBIENT_TEST_PERMISSION_DENIALS
      if (denialsJSON) {
        yield {
          type: 'result',
          result: 'fixture result',
          permission_denials: JSON.parse(denialsJSON),
        }
      }
    }
  `
  const sdkURL = `data:text/javascript;base64,${Buffer.from(sdkSource).toString('base64')}`
  const hooks = path.join(support, 'fake-sdk-hooks.mjs')
  fs.writeFileSync(hooks, `
    const sdkURL = ${JSON.stringify(sdkURL)}
    export async function resolve(specifier, context, nextResolve) {
      if (specifier === '@anthropic-ai/claude-agent-sdk') {
        return { url: sdkURL, shortCircuit: true }
      }
      return nextResolve(specifier, context)
    }
  `)
  const loader = path.join(support, 'fake-sdk-loader.mjs')
  fs.writeFileSync(loader, `
    import { register } from 'node:module'
    register(new URL('./fake-sdk-hooks.mjs', import.meta.url))
  `)
  return { loader, releaseFile }
}

function authorityEnvelopes(support, domain, state = 'pending') {
  const directory = path.join(support, 'authority-inbox', 'v1', state, 'ambientd')
  if (!fs.existsSync(directory)) return []
  return fs.readdirSync(directory)
    .filter((leaf) => leaf.endsWith('.json'))
    .map((leaf) => readAuthorityInboxEnvelope(path.join(directory, leaf)))
    .filter((value) => value.envelope.domain === domain)
}

function ambientHarness(t, prefix = 'mechanician-ambient-') {
  const support = fs.mkdtempSync(path.join(os.tmpdir(), prefix))
  const children = []
  t.after(async () => {
    for (const { child } of children) {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL')
    }
    await Promise.all(children.map(async ({ child }) => {
      if (child.exitCode === null && child.signalCode === null) {
        try { await once(child, 'exit') } catch {}
      }
    }))
    fs.rmSync(support, { recursive: true, force: true })
  })

  return {
    support,
    start({ env = {}, nodeArgs = [] } = {}) {
      const child = spawn(process.execPath, [...nodeArgs, ambientd], {
        env: {
          ...process.env,
          MECHANICIAN_SUPPORT_DIR: support,
          ANTHROPIC_API_KEY: 'test-only-not-a-key',
          ANTHROPIC_AUTH_TOKEN: '',
          CLAUDE_CODE_OAUTH_TOKEN: '',
          ...env,
        },
        stdio: ['ignore', 'ignore', 'pipe'],
      })
      let stderr = ''
      child.stderr.setEncoding('utf8')
      child.stderr.on('data', (chunk) => { stderr += chunk })
      const childRecord = { child, stderr: () => stderr }
      children.push(childRecord)
      return childRecord
    },
  }
}

test('explicit ambient directory keeps SQLite projections away from frozen Legacy sources', async (t) => {
  const harness = ambientHarness(t, 'mechanician-ambient-projection-')
  const legacy = path.join(harness.support, 'ambient')
  const projection = path.join(harness.support, 'ambient-projection')
  fs.mkdirSync(legacy, { recursive: true })
  fs.mkdirSync(projection, { recursive: true })
  const legacyDefinitions = '[{"legacy":"frozen"}]\n'
  fs.writeFileSync(path.join(legacy, 'tasks.json'), legacyDefinitions)
  fs.writeFileSync(path.join(projection, 'tasks.json'), '[]\n')

  const running = harness.start({ env: { MECHANICIAN_AMBIENT_DIR: projection } })
  await waitFor(
    () => readJSON(path.join(projection, 'heartbeat.json')),
    'SQLite ambient projection heartbeat')

  assert.equal(running.child.exitCode, null)
  assert.equal(fs.readFileSync(path.join(legacy, 'tasks.json'), 'utf8'), legacyDefinitions)
  assert.equal(fs.existsSync(path.join(legacy, 'heartbeat.json')), false)
  assert.deepEqual(readJSON(path.join(projection, 'tasks.json')), [])
})

test('ambientd runs from the tenant Vertex route without an Anthropic API key', async (t) => {
  const harness = ambientHarness(t, 'mechanician-ambient-vertex-')
  const routeConfig = path.join(harness.support, 'provider-routes', 'fixture-route', 'claude')
  const adcDirectory = path.join(routeConfig, 'gcloud')
  fs.mkdirSync(adcDirectory, { recursive: true })
  fs.writeFileSync(path.join(adcDirectory, 'application_default_credentials.json'), JSON.stringify({
    type: 'authorized_user',
    client_id: 'installed-public-client',
    client_secret: 'installed-public-secret',
    refresh_token: 'test-only-refresh-token',
  }))

  const running = harness.start({ env: {
    MECHANICIAN_AUTH: 'vertex',
    MECHANICIAN_VERTEX_PROJECT: 'acme-claude-code',
    MECHANICIAN_VERTEX_REGION: 'global',
    MECHANICIAN_CONFIG_DIR: routeConfig,
    ANTHROPIC_API_KEY: '',
  } })
  await waitFor(
    () => readJSON(path.join(harness.support, 'ambient', 'heartbeat.json')),
    'Vertex ambient heartbeat')
  assert.equal(running.child.exitCode, null)
  assert.match(running.stderr(), /ready — 0 task\(s\)/)
})

test('ambientd fails closed when the tenant Vertex ADC file is absent', async (t) => {
  const harness = ambientHarness(t, 'mechanician-ambient-vertex-missing-adc-')
  const running = harness.start({ env: {
    MECHANICIAN_AUTH: 'vertex',
    MECHANICIAN_VERTEX_PROJECT: 'acme-claude-code',
    MECHANICIAN_VERTEX_REGION: 'global',
    ANTHROPIC_API_KEY: '',
  } })
  const [code, signal] = await once(running.child, 'exit')
  assert.equal(signal, null)
  assert.equal(code, 1)
  assert.match(running.stderr(), /no Vertex ADC credential/)
})

for (const mismatch of [
  {
    name: 'an Anthropic API scheduler refuses a task labeled as Vertex',
    taskAccess: 'claude_vertex',
    actualAccess: 'anthropic_api',
    environment: {},
  },
  {
    name: 'a Vertex scheduler refuses a task labeled as Anthropic API',
    taskAccess: 'anthropic_api',
    actualAccess: 'claude_vertex',
    environment: { MECHANICIAN_AUTH: 'vertex' },
  },
]) {
  test(mismatch.name, async (t) => {
    const harness = ambientHarness(t, 'mechanician-ambient-route-mismatch-')
    const { support } = harness
    const ambient = path.join(support, 'ambient')
    const routeEnvironment = { ...mismatch.environment }
    fs.mkdirSync(ambient, { recursive: true })
    if (routeEnvironment.MECHANICIAN_AUTH === 'vertex') {
      const routeConfig = path.join(support, 'provider-routes', 'fixture-route', 'claude')
      const adcDirectory = path.join(routeConfig, 'gcloud')
      fs.mkdirSync(adcDirectory, { recursive: true })
      fs.writeFileSync(
        path.join(adcDirectory, 'application_default_credentials.json'),
        JSON.stringify({ type: 'authorized_user' }))
      Object.assign(routeEnvironment, {
        MECHANICIAN_CONFIG_DIR: routeConfig,
        MECHANICIAN_VERTEX_PROJECT: 'acme-claude-code',
        MECHANICIAN_VERTEX_REGION: 'global',
        ANTHROPIC_API_KEY: '',
      })
    }
    fs.writeFileSync(path.join(ambient, 'tasks.json'), JSON.stringify([{
      id: 'route-mismatch-task', name: 'Route mismatch', prompt: 'must not reach a model',
      enabled: false, workspaceID: null, access: mismatch.taskAccess,
      permissionMode: 'dontAsk', definitionRevision: 'route-mismatch-revision-1',
      runRequestID: 'route-mismatch-request-1',
      trigger: { type: 'time', schedule: { kind: 'daily', hour: 9, minute: 0 } },
    }], null, 2))

    const running = harness.start({ env: {
      ...routeEnvironment,
      MECHANICIAN_MANAGED_POLICY: '1',
      MECHANICIAN_ALLOW_UNATTENDED_TASKS: '1',
      MECHANICIAN_ALLOW_USER_EXTENSIONS: '1',
      // The declared lane is allowed. The regression is that execution used to cross into this
      // process's other, unauthorized route after checking only the task label.
      MECHANICIAN_ALLOWED_PROVIDER_ACCESSES: mismatch.taskAccess,
    } })

    const result = await waitFor(() => {
      const runtime = readJSON(path.join(ambient, 'runtime.json'))?.['route-mismatch-task']
      const runs = readJSON(path.join(ambient, 'runs.json'))
      return runtime?.activeRun === null && runs?.length === 1 ? { runtime, runs } : null
    }, 'provider-route mismatch failure')

    assert.match(result.runtime.lastResult,
      new RegExp(`${mismatch.taskAccess} provider does not match.*${mismatch.actualAccess} route`))
    assert.equal(result.runs[0].ok, false)
    assert.match(result.runs[0].conversationID, /^[0-9A-F-]{36}$/)
    assert.equal(running.child.exitCode, null, running.stderr())
  })
}

test('a legacy task without a provider inherits the scheduler Vertex route', async (t) => {
  const harness = ambientHarness(t, 'mechanician-ambient-legacy-vertex-')
  const { support } = harness
  const ambient = path.join(support, 'ambient')
  const routeConfig = path.join(support, 'provider-routes', 'fixture-route', 'claude')
  const adcDirectory = path.join(routeConfig, 'gcloud')
  fs.mkdirSync(ambient, { recursive: true })
  fs.mkdirSync(adcDirectory, { recursive: true })
  fs.writeFileSync(
    path.join(adcDirectory, 'application_default_credentials.json'),
    JSON.stringify({ type: 'authorized_user' }))
  fs.writeFileSync(path.join(ambient, 'tasks.json'), JSON.stringify([{
    id: 'legacy-vertex-task', name: 'Legacy Vertex', prompt: 'use the configured route',
    enabled: false, workspaceID: null, permissionMode: 'dontAsk',
    definitionRevision: 'legacy-vertex-revision-1', runRequestID: 'legacy-vertex-request-1',
    trigger: { type: 'time', schedule: { kind: 'daily', hour: 9, minute: 0 } },
  }], null, 2))
  const { loader, releaseFile } = writeFakeSDKLoader(support)
  fs.writeFileSync(releaseFile, '')
  const running = harness.start({
    nodeArgs: ['--import', loader],
    env: {
      MECHANICIAN_AUTH: 'vertex',
      MECHANICIAN_CONFIG_DIR: routeConfig,
      MECHANICIAN_VERTEX_PROJECT: 'acme-claude-code',
      MECHANICIAN_VERTEX_REGION: 'global',
      ANTHROPIC_API_KEY: '',
      MECHANICIAN_AMBIENT_TEST_RELEASE: releaseFile,
      MECHANICIAN_MANAGED_POLICY: '1',
      MECHANICIAN_ALLOW_UNATTENDED_TASKS: '1',
      MECHANICIAN_ALLOW_USER_EXTENSIONS: '1',
      MECHANICIAN_ALLOWED_PROVIDER_ACCESSES: 'claude_vertex',
    },
  })

  const result = await waitFor(() => {
    const runtime = readJSON(path.join(ambient, 'runtime.json'))?.['legacy-vertex-task']
    const runs = readJSON(path.join(ambient, 'runs.json'))
    return runtime?.activeRun === null && runs?.length === 1 ? { runtime, runs } : null
  }, 'legacy task on the scheduler Vertex route')

  assert.match(result.runtime.lastResult, /fixture result/)
  assert.equal(result.runs[0].ok, true)
  assert.equal(running.child.exitCode, null, running.stderr())
})

test('a pending exact-lane MCP boundary holds a scheduled run before model execution', async (t) => {
  const harness = ambientHarness(t, 'mechanician-ambient-mcp-boundary-')
  const { support } = harness
  const ambient = path.join(support, 'ambient')
  fs.mkdirSync(ambient, { recursive: true })
  const workspaceID = '12345678-9876-4ABC-8DEF-123456789ABC'
  writeProject(support, workspaceID, support)
  fs.writeFileSync(path.join(ambient, 'tasks.json'), JSON.stringify([{
    id: 'mcp-boundary-task', name: 'MCP boundary', prompt: 'must not reach the model',
    enabled: false, workspaceID, permissionMode: 'dontAsk',
    definitionRevision: 'mcp-boundary-revision-1', runRequestID: 'manual-mcp-boundary-1',
    trigger: { type: 'time', schedule: { kind: 'daily', hour: 9, minute: 0 } },
  }], null, 2))
  fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({
    pendingMCPReadiness: {
      byAccess: {
        anthropic_api: [{
          name: 'Private MCP Name', changeId: 'private-generation', source: 'configured',
          serverId: '7F661A72-4885-42AD-BCE1-242B6741D88A',
        }],
      },
    },
    pendingMCPAuthorizations: { byAccess: {} },
  }, null, 2))
  const { loader, releaseFile } = writeFakeSDKLoader(support)
  const running = harness.start({
    nodeArgs: ['--import', loader],
    env: {
      MECHANICIAN_AMBIENT_INPROCESS: '1',
      // The fake query waits forever until this nonexistent file appears. A completed run therefore
      // proves ambientd stopped at the persisted MCP boundary before invoking the model SDK.
      MECHANICIAN_AMBIENT_TEST_RELEASE: releaseFile,
    },
  })

  const result = await waitFor(() => {
    const runtime = readJSON(path.join(ambient, 'runtime.json'))?.['mcp-boundary-task']
    const runs = readJSON(path.join(ambient, 'runs.json'))
    return runtime?.activeRun === null && runs?.length === 1 ? { runtime, runs } : null
  }, 'MCP-gated scheduled result')

  assert.match(result.runtime.lastResult, /fresh tool check/i)
  assert.doesNotMatch(result.runtime.lastResult, /Private MCP Name|private-generation/,
    'the run report must not disclose persisted MCP identities')
  assert.equal(result.runs[0].ok, false)
  assert.equal(running.child.exitCode, null, running.stderr())
  assert.equal(fs.existsSync(releaseFile), false,
    'the model fixture was never released or invoked')
})

test('managed-only scheduled work ignores preserved user MCP readiness', async (t) => {
  const harness = ambientHarness(t, 'mechanician-ambient-managed-mcp-boundary-')
  const { support } = harness
  const ambient = path.join(support, 'ambient')
  fs.mkdirSync(ambient, { recursive: true })
  fs.writeFileSync(path.join(ambient, 'tasks.json'), JSON.stringify([{
    id: 'managed-mcp-task', name: 'Managed MCP task', prompt: 'reach the managed model',
    enabled: false, workspaceID: null, permissionMode: 'dontAsk',
    definitionRevision: 'managed-mcp-revision-1', runRequestID: 'managed-mcp-request-1',
    trigger: { type: 'time', schedule: { kind: 'daily', hour: 9, minute: 0 } },
  }], null, 2))
  fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({
    pendingMCPReadiness: {
      byAccess: {
        anthropic_api: [{
          name: 'Preserved personal server', changeId: 'personal-generation',
          source: 'configured', serverId: '45F37142-F8FD-47EE-8A6C-C442E33783A3',
        }],
      },
    },
    pendingMCPAuthorizations: { byAccess: {} },
  }, null, 2))
  const { loader, releaseFile } = writeFakeSDKLoader(support)
  const optionsResult = path.join(support, 'managed-sdk-options.json')
  fs.writeFileSync(releaseFile, '')
  const running = harness.start({
    nodeArgs: ['--import', loader],
    env: {
      MECHANICIAN_AMBIENT_INPROCESS: '1',
      MECHANICIAN_AMBIENT_TEST_RELEASE: releaseFile,
      MECHANICIAN_AMBIENT_TEST_OPTIONS_RESULT: optionsResult,
      MECHANICIAN_MANAGED_POLICY: '1',
      MECHANICIAN_ALLOW_UNATTENDED_TASKS: '1',
      MECHANICIAN_ALLOW_USER_EXTENSIONS: '0',
    },
  })

  const result = await waitFor(() => {
    const runtime = readJSON(path.join(ambient, 'runtime.json'))?.['managed-mcp-task']
    const runs = readJSON(path.join(ambient, 'runs.json'))
    return runtime?.activeRun === null && runs?.length === 1 ? { runtime, runs } : null
  }, 'managed-only scheduled result')

  assert.match(result.runtime.lastResult, /fixture result/)
  assert.equal(result.runs[0].ok, true)
  assert.doesNotMatch(result.runtime.lastResult, /fresh tool check|Preserved personal server/)
  assert.deepEqual(readJSON(optionsResult), {
    settings: {
      precomputeCompactionEnabled: true,
      enableWorkflows: false,
      disableClaudeAiConnectors: true,
      syncClaudeAiPlugins: false,
    },
    strictMcpConfig: true,
    plugins: [],
    settingSources: [],
    mcpServerNames: ['artifacts'],
  })
  assert.equal(running.child.exitCode, null, running.stderr())
})

test('a persisted Help task is held before an unattended run claim', async (t) => {
  const harness = ambientHarness(t, 'mechanician-ambient-reserved-workspace-')
  const { support } = harness
  const ambient = path.join(support, 'ambient')
  fs.mkdirSync(ambient, { recursive: true })
  const reserved = [
    ['help-task', 'D353F793-FC8A-497C-BF64-BD396EF2F367'],
  ]
  for (const [, workspaceID] of reserved) writeProject(support, workspaceID, support)
  fs.writeFileSync(path.join(ambient, 'tasks.json'), JSON.stringify(
    reserved.map(([id, workspaceID]) => ({
      id, name: id, prompt: 'must remain interactive', enabled: false,
      workspaceID, permissionMode: 'dontAsk', definitionRevision: `${id}-revision-1`,
      runRequestID: `${id}-manual-request-1`,
      trigger: { type: 'time', schedule: { kind: 'daily', hour: 9, minute: 0 } },
    })), null, 2))
  const { loader, releaseFile } = writeFakeSDKLoader(support)
  const running = harness.start({
    nodeArgs: ['--import', loader],
    env: {
      MECHANICIAN_AMBIENT_INPROCESS: '1',
      // If either task crosses the reserved boundary, the fake model waits here after claimRun
      // has exposed the violation in runtime.json.
      MECHANICIAN_AMBIENT_TEST_RELEASE: releaseFile,
    },
  })

  const runtime = await waitFor(() => {
    const value = readJSON(path.join(ambient, 'runtime.json'))
    return reserved.every(([id]) => value?.[id]) ? value : null
  }, 'reserved task runtime reconciliation')

  for (const [id] of reserved) {
    assert.equal(runtime[id].lastRunRequestID, undefined,
      `${id} must not consume its persisted Run now request`)
    assert.equal(runtime[id].activeRun, undefined,
      `${id} must not acquire an unattended run claim`)
  }
  assert.equal(authorityEnvelopes(support, 'conversation').length, 0)
  assert.equal(fs.existsSync(releaseFile), false, 'the model fixture was never invoked')
  assert.equal(running.child.exitCode, null, running.stderr())
})

test('ambientd recovers a durable in-flight claim without replaying or rewriting definitions', async (t) => {
  const harness = ambientHarness(t)
  const { support } = harness
  const dir = path.join(support, 'ambient')
  fs.mkdirSync(dir, { recursive: true })
  const tasksFile = path.join(dir, 'tasks.json')
  const runtimeFile = path.join(dir, 'runtime.json')
  const runsFile = path.join(dir, 'runs.json')
  const definition = [{
    id: 'task-1', name: 'One shot', prompt: 'do something', enabled: true,
    workspaceID: null, cwd: '', permissionMode: 'dontAsk',
    definitionRevision: 'revision-1',
    trigger: { type: 'time', schedule: { kind: 'once', at: '2030-01-01T00:00:00Z' } },
  }]
  fs.writeFileSync(tasksFile, JSON.stringify(definition, null, 2))
  const originalDefinitions = fs.readFileSync(tasksFile, 'utf8')
  fs.writeFileSync(runtimeFile, JSON.stringify({
    'task-1': {
      definitionRevision: 'revision-1', onceCompleted: true,
      activeRun: { id: 'run-1', startedAt: '2026-07-18T12:00:00.000Z', trigger: 'time' },
    },
  }))

  const process = harness.start()
  await waitFor(() => {
    const runtime = readJSON(runtimeFile)
    const runs = readJSON(runsFile)
    return runtime?.['task-1']?.activeRun === null && runs?.length === 1 && { runtime, runs }
  }, 'interrupted-run recovery')

  assert.equal(fs.readFileSync(tasksFile, 'utf8'), originalDefinitions)
  const runtime = readJSON(runtimeFile)['task-1']
  assert.equal(runtime.onceCompleted, true)
  assert.match(runtime.lastResult, /not retried automatically/)
  const [run] = readJSON(runsFile)
  assert.equal(run.ok, false)
  assert.equal(run.conversationID, null)
  assert.equal(fs.statSync(runtimeFile).mode & 0o777, 0o600)
  assert.equal(process.child.exitCode, null, process.stderr())
})

test('startup reconciles an adopted completed result without an interrupted lie or duplicate receipt', async (t) => {
  const harness = ambientHarness(t, 'mechanician-ambient-adopted-recovery-')
  const { support } = harness
  const ambient = path.join(support, 'ambient')
  fs.mkdirSync(ambient, { recursive: true })
  const operationID = '33333333-4444-4555-8666-777777777777'
  const conversationID = 'BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF'
  const completedAt = '2026-08-05T14:00:00.000Z'
  const definition = [{
    id: 'task-completed', name: 'Completed background run', prompt: 'make result', enabled: false,
    workspaceID: null, permissionMode: 'dontAsk', definitionRevision: 'revision-completed',
    trigger: { type: 'time', schedule: { kind: 'once', at: '2030-01-01T00:00:00Z' } },
  }]
  fs.writeFileSync(path.join(ambient, 'tasks.json'), JSON.stringify(definition, null, 2))
  fs.writeFileSync(path.join(ambient, 'runtime.json'), JSON.stringify({
    'task-completed': {
      definitionRevision: 'revision-completed',
      activeRun: { id: operationID, startedAt: '2026-08-05T13:59:00.000Z', trigger: 'time' },
    },
  }, null, 2))
  // Simulate appendRun committing before the daemon dies while clearing runtime. Recovery must
  // replace this same-operation row, not append another row or call the completed work interrupted.
  fs.writeFileSync(path.join(ambient, 'runs.json'), JSON.stringify([{
    operationID, taskId: 'task-completed', at: completedAt, ok: false,
    summary: 'stale fixture row', conversationID: null,
  }], null, 2))
  const envelope = createAuthorityInboxEnvelope({
    operationID,
    subjectID: conversationID,
    producer: { id: 'ambientd', build: '0.24.0-208-authority-inbox-v1' },
    authority: { protocol: AUTHORITY_INBOX_PROTOCOL, observedGeneration: 'legacy-unmarked' },
    domain: 'conversation', kind: 'create', definitionRevision: 'revision-completed',
    createdAt: new Date('2026-08-05T14:00:00Z'),
    payload: {
      id: conversationID, title: 'Completed background run', projectID: null, cwd: support,
      sdkSessionId: null, updatedAt: completedAt, errored: false, artifacts: [], workflowRuns: {},
      messages: [
        { id: 'u', kind: 'user', text: 'make result', observedAt: completedAt,
          toolIsError: false, permDecided: false, permAllowed: false },
        { id: 'a', kind: 'assistant', text: 'real completed result', observedAt: completedAt,
          toolIsError: false, permDecided: false, permAllowed: false },
      ],
    },
  })
  const publication = publishAuthorityInboxEnvelope({ anchorDirectory: support, envelope })
  const adopted = path.join(support, 'authority-inbox', 'v1', 'adopted', 'ambientd')
  fs.mkdirSync(adopted, { recursive: true, mode: 0o700 })
  fs.renameSync(publication.path, path.join(adopted, path.basename(publication.path)))

  const running = harness.start()
  const recovered = await waitFor(() => {
    const runtime = readJSON(path.join(ambient, 'runtime.json'))?.['task-completed']
    const runs = readJSON(path.join(ambient, 'runs.json'))
    return runtime?.activeRun === null && runs?.[0]?.summary === 'real completed result'
      ? { runtime, runs } : null
  }, 'completed result reconciliation')

  assert.equal(recovered.runtime.lastResult, 'real completed result')
  assert.equal(recovered.runtime.lastRun, completedAt)
  assert.equal(recovered.runs.length, 1)
  assert.deepEqual(recovered.runs[0], {
    operationID, taskId: 'task-completed', at: completedAt, ok: true,
    summary: 'real completed result', conversationID,
  })
  assert.doesNotMatch(recovered.runs[0].summary, /Interrupted/)
  assert.equal(running.child.exitCode, null, running.stderr())
})

test('a changed definition revision resets daemon trigger state in runtime.json only', async (t) => {
  const harness = ambientHarness(t, 'mechanician-ambient-revision-')
  const { support } = harness
  const dir = path.join(support, 'ambient')
  fs.mkdirSync(dir, { recursive: true })
  const tasksFile = path.join(dir, 'tasks.json')
  const runtimeFile = path.join(dir, 'runtime.json')
  const definition = [{
    id: 'task-2', name: 'Edited', prompt: 'new instruction', enabled: false,
    workspaceID: null, cwd: '', permissionMode: 'dontAsk',
    definitionRevision: 'new-revision',
    trigger: { type: 'file', path: '/tmp/example' },
  }]
  fs.writeFileSync(tasksFile, JSON.stringify(definition, null, 2))
  const originalDefinitions = fs.readFileSync(tasksFile, 'utf8')
  fs.writeFileSync(runtimeFile, JSON.stringify({
    'task-2': {
      definitionRevision: 'old-revision', nextRun: 123, lastMtime: 456,
      onceCompleted: true, lastRun: '2026-07-17T00:00:00.000Z',
    },
  }))

  harness.start()
  const state = await waitFor(() => {
    const runtime = readJSON(runtimeFile)?.['task-2']
    return runtime?.definitionRevision === 'new-revision' && runtime
  }, 'runtime revision reset')

  assert.equal(state.nextRun, undefined)
  assert.equal(state.lastMtime, undefined)
  assert.equal(state.onceCompleted, undefined)
  assert.equal(state.lastRun, '2026-07-17T00:00:00.000Z')
  assert.equal(fs.readFileSync(tasksFile, 'utf8'), originalDefinitions)
})

test('ambientd exits before model execution when a durable run claim cannot be published', async (t) => {
  const harness = ambientHarness(t, 'mechanician-ambient-claim-failure-')
  const { support } = harness
  const dir = path.join(support, 'ambient')
  fs.mkdirSync(dir, { recursive: true })
  const tasksFile = path.join(dir, 'tasks.json')
  const runtimeFile = path.join(dir, 'runtime.json')
  const workspaceID = '99999999-8888-7777-6666-555555555555'
  writeProject(support, workspaceID)
  fs.writeFileSync(tasksFile, JSON.stringify([{
    id: 'claim-failure-task', name: 'Manual task', prompt: 'must not execute', enabled: false,
    workspaceID, cwd: '', permissionMode: 'dontAsk', definitionRevision: 'revision-1',
    runRequestID: 'manual-request-1',
    trigger: { type: 'time', schedule: { kind: 'daily', hour: 9, minute: 0 } },
  }], null, 2))
  // A directory at the runtime destination deterministically makes rename(2) fail after the
  // temporary file was fsynced. The durable claim boundary must fail closed before ensureSdk().
  fs.mkdirSync(runtimeFile)

  const process = harness.start({ env: { MECHANICIAN_AMBIENT_INPROCESS: '1' } })
  await waitFor(
    () => process.child.exitCode !== null || process.child.signalCode !== null,
    'scheduler exit after claim persistence failure')

  assert.notEqual(process.child.exitCode, 0)
  assert.match(process.stderr(), /fatal scheduler error.*tick could not persist its state/is)
  assert.equal(readJSON(path.join(dir, 'runs.json')), null)
  const pending = path.join(support, 'authority-inbox', 'v1', 'pending', 'ambientd')
  assert.equal(fs.existsSync(pending), true)
  assert.deepEqual(fs.readdirSync(pending), [])
  assert.equal(fs.readdirSync(dir).some((name) => name.endsWith('.tmp')), false)
})

test('a standby ambientd takes over the singleton lease after its owner exits', async (t) => {
  const harness = ambientHarness(t, 'mechanician-ambient-singleton-')
  const { support } = harness
  const first = harness.start()
  await waitFor(() => /ready —/.test(first.stderr()), 'first scheduler readiness')

  const second = harness.start()
  await waitFor(
    () => /waiting for scheduler lease held by pid/.test(second.stderr()),
    'second scheduler waiting for lease')
  assert.equal(/ready —/.test(second.stderr()), false)
  assert.equal(readJSON(path.join(support, 'ambient', '.scheduler-lease', 'owner.json'))?.pid,
    first.child.pid)

  first.child.kill('SIGKILL')
  await once(first.child, 'exit')
  await waitFor(
    () => /acquired scheduler lease after handoff/.test(second.stderr()) && /ready —/.test(second.stderr()),
    'standby scheduler lease handoff')

  assert.equal(second.child.exitCode, null, second.stderr())
  assert.equal(readJSON(path.join(support, 'ambient', '.scheduler-lease', 'owner.json'))?.pid,
    second.child.pid)
})

test('completed output publication fails before clearing the durable run claim', async (t) => {
  const harness = ambientHarness(t, 'mechanician-ambient-output-failure-')
  const { support } = harness
  const ambient = path.join(support, 'ambient')
  fs.mkdirSync(ambient, { recursive: true })
  const workspaceID = '77777777-6666-5555-4444-333333333333'
  writeProject(support, workspaceID)
  fs.writeFileSync(path.join(ambient, 'tasks.json'), JSON.stringify([{
    id: 'output-failure-task', name: 'Output failure', prompt: 'finish once', enabled: false,
    workspaceID, permissionMode: 'dontAsk', definitionRevision: 'revision-1',
    runRequestID: 'manual-request-1',
    trigger: { type: 'time', schedule: { kind: 'daily', hour: 9, minute: 0 } },
  }], null, 2))
  const { loader, releaseFile } = writeFakeSDKLoader(support)
  const running = harness.start({
    nodeArgs: ['--import', loader],
    env: {
      MECHANICIAN_AMBIENT_INPROCESS: '1',
      MECHANICIAN_AMBIENT_TEST_RELEASE: releaseFile,
    },
  })
  const runtimeFile = path.join(ambient, 'runtime.json')
  const claim = await waitFor(
    () => readJSON(runtimeFile)?.['output-failure-task']?.activeRun,
    'durable claim before output failure')
  const pending = path.join(support, 'authority-inbox', 'v1', 'pending', 'ambientd')
  fs.chmodSync(pending, 0o755)
  fs.writeFileSync(releaseFile, 'continue')
  await waitFor(
    () => running.child.exitCode !== null || running.child.signalCode !== null,
    'scheduler exit after output publication failure')

  assert.notEqual(running.child.exitCode, 0)
  assert.match(running.stderr(), /fatal scheduler error.*inbox directory is not private/is)
  assert.deepEqual(readJSON(runtimeFile)['output-failure-task'].activeRun, claim,
    'claim must remain durable when result delivery is not durable')
  assert.equal(readJSON(path.join(ambient, 'runs.json')), null)
  assert.deepEqual(fs.readdirSync(pending), [])
  assert.equal(fs.existsSync(path.join(support, 'conversations')), false)
})

test('ambient artifacts publish immutable retained upserts and survive a crash without replay', async (t) => {
  const harness = ambientHarness(t, 'mechanician-ambient-artifact-crash-')
  const { support } = harness
  const ambient = path.join(support, 'ambient')
  fs.mkdirSync(ambient, { recursive: true })
  const workspaceID = '12345678-1234-4567-89AB-123456789ABC'
  writeProject(support, workspaceID, support)
  const legacyDirectory = path.join(support, 'artifacts')
  const legacyArtifact = path.join(
    legacyDirectory, 'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE.json')
  fs.mkdirSync(legacyDirectory)
  fs.writeFileSync(legacyArtifact, JSON.stringify({
    id: 'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE',
    title: 'Daily report', type: 'markdown', source: '# Legacy\n',
    createdAt: '2026-08-01T12:00:00.123Z', updatedAt: '2026-08-01T12:00:00.456Z',
    revisions: 7, favorite: false, origin: 'ambient',
    conversationID: null, conversationTitle: '⏰ Artifact crash',
    workspaceID, cwd: support,
    // Deliberately no taskId: Swift's finite Artifact Codable contract drops that old Node-only
    // member whenever the app re-saves the record.
  }, null, 2))
  const interactiveCollision = path.join(
    legacyDirectory, '99999999-BBBB-4CCC-8DDD-EEEEEEEEEEEE.json')
  fs.writeFileSync(interactiveCollision, JSON.stringify({
    id: '99999999-BBBB-4CCC-8DDD-EEEEEEEEEEEE',
    title: 'Daily report', type: 'markdown', source: '# User owned\n',
    createdAt: '2026-08-02T12:00:00.000Z', updatedAt: '2026-08-02T12:00:00.000Z',
    revisions: 99, favorite: false, origin: 'interactive',
    conversationID: null, conversationTitle: '⏰ Artifact crash',
    workspaceID, cwd: support,
  }, null, 2))
  const unchangedLegacyBytes = fs.readFileSync(legacyArtifact)
  const unchangedInteractiveBytes = fs.readFileSync(interactiveCollision)
  fs.writeFileSync(path.join(ambient, 'tasks.json'), JSON.stringify([{
    id: 'artifact-crash-task', name: 'Artifact crash', prompt: 'make dashboard', enabled: false,
    workspaceID, permissionMode: 'dontAsk', definitionRevision: 'artifact-revision-1',
    runRequestID: 'artifact-request-1',
    trigger: { type: 'time', schedule: { kind: 'daily', hour: 9, minute: 0 } },
  }], null, 2))
  const { loader, releaseFile } = writeFakeSDKLoader(support)
  const resultFile = path.join(support, 'artifact-tool-result.json')
  const requests = [
    { type: 'markdown', title: 'Daily report', source: '# First\n' },
    { type: 'markdown', title: 'Daily report', source: '# Revised\n' },
  ]
  const running = harness.start({
    nodeArgs: ['--import', loader],
    env: {
      MECHANICIAN_AMBIENT_INPROCESS: '1',
      MECHANICIAN_AMBIENT_TEST_RELEASE: releaseFile,
      MECHANICIAN_AMBIENT_TEST_ARTIFACT: JSON.stringify(requests),
      MECHANICIAN_AMBIENT_TEST_ARTIFACT_RESULT: resultFile,
      MECHANICIAN_AMBIENT_TEST_ARTIFACT_CLOCK_MS: '1785924000123',
    },
  })

  const toolResult = await waitFor(
    () => readJSON(resultFile), 'durable artifact tool result')
  assert.equal(toolResult.error, undefined)
  assert.deepEqual(
    toolResult.results.map((result) => result.content[0].text),
    [
      'Artifact "Daily report" saved for delivery to Mechanician.',
      'Artifact "Daily report" saved for delivery to Mechanician.',
    ])
  const envelopes = authorityEnvelopes(support, 'artifact')
    .sort((a, b) => a.payload.artifact.revisions - b.payload.artifact.revisions)
  assert.equal(envelopes.length, 2)
  assert.equal(new Set(envelopes.map((value) => value.envelope.operationID)).size, 2,
    'each same-title update is an immutable operation')
  assert.equal(new Set(envelopes.map((value) => value.envelope.subjectID)).size, 1,
    'same-title updates preserve Artifact identity')
  assert.deepEqual(envelopes.map((value) => value.payload.artifact.revisions), [8, 9])
  assert.deepEqual(
    [...envelopes].sort((a, b) => a.envelope.operationID.localeCompare(b.envelope.operationID))
      .map((value) => value.payload.artifact.revisions),
    [8, 9], 'lexical inbox order preserves sequential upsert lineage')
  const orderedOperationIDs = envelopes.map((value) => value.envelope.operationID).sort()
  assert.deepEqual(
    orderedOperationIDs.map((value) => value.split('-').slice(0, 2)),
    [orderedOperationIDs[0], orderedOperationIDs[0]].map((value) => value.split('-').slice(0, 2)),
    'fixture forces both UUIDv7-style operations into the same millisecond')
  assert.deepEqual(orderedOperationIDs.map((value) => value.split('-')[2]), ['7000', '7001'])
  assert.equal(envelopes[0].payload.artifact.taskId, 'artifact-crash-task')
  assert.equal(envelopes[0].payload.artifact.createdAt, '2026-08-01T12:00:00.123Z')
  assert.equal(envelopes[0].envelope.subjectID, 'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE',
    'same-title interactive Artifacts are not ambient ownership candidates')
  assert.deepEqual(Object.keys(envelopes[0].payload.artifact).sort(), [
    'conversationID', 'conversationTitle', 'createdAt', 'cwd', 'favorite', 'id', 'origin',
    'revisions', 'taskId', 'title', 'type', 'updatedAt', 'workspaceID',
  ], 'a Swift-rewritten Legacy record cannot leak undefined or unknown metadata into the envelope')
  assert.deepEqual(envelopes.map((value) => value.payload.source), [
    { retainedByteID: 'source', encoding: 'utf-8' },
    { retainedByteID: 'source', encoding: 'utf-8' },
  ])
  for (const [index, value] of envelopes.entries()) {
    const [reference] = value.envelope.retainedBytes
    const retained = path.join(
      support, 'authority-inbox', 'v1', reference.relativePath)
    assert.equal(fs.readFileSync(retained, 'utf8'), requests[index].source)
    assert.equal(fs.lstatSync(retained).mode & 0o777, 0o400)
    assert.equal(fs.lstatSync(retained).nlink, 1)
    assert.equal(reference.byteCount, Buffer.byteLength(requests[index].source))
    assert.equal(reference.mediaType, 'text/markdown; charset=utf-8')
  }
  assert.deepEqual(fs.readFileSync(legacyArtifact), unchangedLegacyBytes,
    'ambientd must not mutate Legacy Artifact authority')
  assert.deepEqual(fs.readFileSync(interactiveCollision), unchangedInteractiveBytes)

  // The artifact operations are durable while the provider turn is still open. A hard crash here
  // must not replay the tool or duplicate either immutable upsert on restart.
  const firstRetained = path.join(
    support, 'authority-inbox', 'v1', envelopes[0].envelope.retainedBytes[0].relativePath)
  const strandedAlias = path.join(path.dirname(firstRetained), '.source.dead-process.tmp')
  fs.linkSync(firstRetained, strandedAlias)
  assert.equal(fs.lstatSync(firstRetained).nlink, 2)
  const quarantineState = path.join(support, 'authority-inbox', 'v1', 'quarantine')
  const quarantineProducer = path.join(quarantineState, 'ambientd')
  fs.mkdirSync(quarantineState, { mode: 0o700 })
  fs.mkdirSync(quarantineProducer, { mode: 0o700 })
  const quarantinedEnvelope = path.join(
    quarantineProducer, `${envelopes[0].envelope.operationID}.fixture.json`)
  fs.renameSync(path.join(
    support, 'authority-inbox', 'v1', 'pending', 'ambientd',
    `${envelopes[0].envelope.operationID}.json`), quarantinedEnvelope)
  running.child.kill('SIGKILL')
  await once(running.child, 'exit')
  const restarted = harness.start()
  await waitFor(
    () => readJSON(path.join(ambient, 'runtime.json'))?.['artifact-crash-task']?.activeRun === null,
    'interrupted run recovery after artifact publication')
  assert.equal(
    authorityEnvelopes(support, 'artifact').length
      + authorityEnvelopes(support, 'artifact', 'quarantine').length,
    2)
  assert.equal(fs.existsSync(firstRetained), true,
    'quarantined envelopes retain their immutable source evidence')
  assert.equal(fs.existsSync(strandedAlias), false)
  assert.equal(fs.lstatSync(firstRetained).nlink, 1,
    'startup completes a crash-left retained-byte hard-link publication')
  assert.equal(restarted.child.exitCode, null, restarted.stderr())
})

test('retained artifact failure is reported as failure and publishes no saved operation', async (t) => {
  const harness = ambientHarness(t, 'mechanician-ambient-artifact-retained-failure-')
  const { support } = harness
  const ambient = path.join(support, 'ambient')
  fs.mkdirSync(ambient, { recursive: true })
  const workspaceID = '12345678-1234-4567-89AB-123456789ABC'
  writeProject(support, workspaceID, support)
  fs.writeFileSync(path.join(ambient, 'tasks.json'), JSON.stringify([{
    id: 'artifact-retained-failure', name: 'Artifact failure', prompt: 'make report', enabled: false,
    workspaceID, permissionMode: 'dontAsk', definitionRevision: 'artifact-revision-1',
    runRequestID: 'artifact-request-1',
    trigger: { type: 'time', schedule: { kind: 'daily', hour: 9, minute: 0 } },
  }], null, 2))
  const { loader, releaseFile } = writeFakeSDKLoader(support)
  const artifactRelease = path.join(support, 'release-artifact-tool')
  const resultFile = path.join(support, 'artifact-tool-result.json')
  const running = harness.start({
    nodeArgs: ['--import', loader],
    env: {
      MECHANICIAN_AMBIENT_INPROCESS: '1',
      MECHANICIAN_AMBIENT_TEST_RELEASE: releaseFile,
      MECHANICIAN_AMBIENT_TEST_ARTIFACT_RELEASE: artifactRelease,
      MECHANICIAN_AMBIENT_TEST_ARTIFACT: JSON.stringify({
        type: 'markdown', title: 'Will fail', source: '# Not saved\n',
      }),
      MECHANICIAN_AMBIENT_TEST_ARTIFACT_RESULT: resultFile,
    },
  })
  await waitFor(
    () => readJSON(path.join(ambient, 'runtime.json'))?.['artifact-retained-failure']?.activeRun,
    'durable claim before retained artifact failure')
  const retained = path.join(support, 'authority-inbox', 'v1', 'retained')
  fs.mkdirSync(retained, { recursive: true, mode: 0o700 })
  fs.chmodSync(retained, 0o755)
  fs.writeFileSync(artifactRelease, 'continue')

  const observation = await waitFor(
    () => readJSON(resultFile), 'retained artifact failure result')
  assert.match(observation.error, /retained-byte directory is not private/)
  assert.doesNotMatch(JSON.stringify(observation), /saved for delivery/)
  await waitFor(
    () => readJSON(path.join(ambient, 'runtime.json'))?.['artifact-retained-failure']?.activeRun === null,
    'failed turn Conversation delivery')
  assert.deepEqual(authorityEnvelopes(support, 'artifact'), [])
  assert.equal(fs.existsSync(path.join(support, 'artifacts')), false)
  assert.equal(running.child.exitCode, null, running.stderr())
})

test('artifact envelope failure leaves only inert retained bytes and never reports saved', async (t) => {
  const harness = ambientHarness(t, 'mechanician-ambient-artifact-envelope-failure-')
  const { support } = harness
  const ambient = path.join(support, 'ambient')
  fs.mkdirSync(ambient, { recursive: true })
  const workspaceID = '12345678-1234-4567-89AB-123456789ABC'
  writeProject(support, workspaceID, support)
  fs.writeFileSync(path.join(ambient, 'tasks.json'), JSON.stringify([{
    id: 'artifact-envelope-failure', name: 'Envelope failure', prompt: 'make report', enabled: false,
    workspaceID, permissionMode: 'dontAsk', definitionRevision: 'artifact-revision-1',
    runRequestID: 'artifact-request-1',
    trigger: { type: 'time', schedule: { kind: 'daily', hour: 9, minute: 0 } },
  }], null, 2))
  const { loader, releaseFile } = writeFakeSDKLoader(support)
  const artifactRelease = path.join(support, 'release-artifact-tool')
  const resultFile = path.join(support, 'artifact-tool-result.json')
  const running = harness.start({
    nodeArgs: ['--import', loader],
    env: {
      MECHANICIAN_AMBIENT_INPROCESS: '1',
      MECHANICIAN_AMBIENT_TEST_RELEASE: releaseFile,
      MECHANICIAN_AMBIENT_TEST_ARTIFACT_RELEASE: artifactRelease,
      MECHANICIAN_AMBIENT_TEST_ARTIFACT: JSON.stringify({
        type: 'markdown', title: 'Will not publish', source: '# Retained only\n',
      }),
      MECHANICIAN_AMBIENT_TEST_ARTIFACT_RESULT: resultFile,
    },
  })
  const runtimeFile = path.join(ambient, 'runtime.json')
  const claim = await waitFor(
    () => readJSON(runtimeFile)?.['artifact-envelope-failure']?.activeRun,
    'durable claim before artifact envelope failure')
  const pending = path.join(support, 'authority-inbox', 'v1', 'pending', 'ambientd')
  fs.chmodSync(pending, 0o755)
  fs.writeFileSync(artifactRelease, 'continue')

  const observation = await waitFor(
    () => readJSON(resultFile), 'artifact envelope failure result')
  assert.match(observation.error, /inbox directory is not private/)
  assert.doesNotMatch(JSON.stringify(observation), /saved for delivery/)
  await waitFor(
    () => running.child.exitCode !== null || running.child.signalCode !== null,
    'scheduler exit after artifact envelope failure')
  assert.deepEqual(readJSON(runtimeFile)['artifact-envelope-failure'].activeRun, claim)
  assert.deepEqual(authorityEnvelopes(support, 'artifact'), [])
  const retainedRoot = path.join(support, 'authority-inbox', 'v1', 'retained')
  const operationDirectories = fs.readdirSync(retainedRoot)
  assert.equal(operationDirectories.length, 1, 'unreferenced retained bytes are inert crash residue')
  const retainedSource = path.join(retainedRoot, operationDirectories[0], 'source')
  assert.equal(fs.readFileSync(retainedSource, 'utf8'), '# Retained only\n')
  assert.equal(fs.lstatSync(retainedSource).mode & 0o777, 0o400)
  assert.equal(fs.existsSync(path.join(support, 'artifacts')), false)
  fs.chmodSync(pending, 0o700)
  const restarted = harness.start()
  await waitFor(
    () => readJSON(runtimeFile)?.['artifact-envelope-failure']?.activeRun === null,
    'orphan cleanup restart')
  assert.deepEqual(fs.readdirSync(retainedRoot), [],
    'startup collects a strictly valid retained source with no envelope receipt')
  assert.equal(restarted.child.exitCode, null, restarted.stderr())
})

test('a run completing after a definition edit preserves outcomes but not stale trigger baselines', async (t) => {
  const harness = ambientHarness(t, 'mechanician-ambient-live-revision-')
  const { support } = harness
  const dir = path.join(support, 'ambient')
  fs.mkdirSync(dir, { recursive: true })
  const tasksFile = path.join(dir, 'tasks.json')
  const runtimeFile = path.join(dir, 'runtime.json')
  const workspaceID = '12345678-1234-4567-89AB-123456789ABC'
  writeProject(support, workspaceID, support)
  const oldDefinition = {
    id: 'live-revision-task', name: 'Before edit', prompt: 'old instruction', enabled: false,
    workspaceID, cwd: '', permissionMode: 'dontAsk', definitionRevision: 'revision-1',
    runRequestID: 'manual-request-1',
    trigger: { type: 'file', path: '/tmp/old-watch-target' },
  }
  fs.writeFileSync(tasksFile, JSON.stringify([oldDefinition], null, 2))
  fs.writeFileSync(runtimeFile, JSON.stringify({
    [oldDefinition.id]: {
      definitionRevision: 'revision-1', nextRun: 111, lastMtime: 222,
      lastMailId: 'mail-1', onceCompleted: true,
    },
  }, null, 2))
  const { loader, releaseFile } = writeFakeSDKLoader(support)

  const process = harness.start({
    nodeArgs: ['--import', loader],
    env: {
      MECHANICIAN_AMBIENT_INPROCESS: '1',
      MECHANICIAN_AMBIENT_TEST_RELEASE: releaseFile,
    },
  })
  await waitFor(
    () => readJSON(runtimeFile)?.[oldDefinition.id]?.activeRun,
    'durable in-flight run claim')

  const editedDefinition = {
    ...oldDefinition,
    name: 'After edit',
    prompt: 'new instruction',
    definitionRevision: 'revision-2',
    trigger: { type: 'time', schedule: { kind: 'daily', hour: 7, minute: 30 } },
  }
  writeJSONAtomic(tasksFile, [editedDefinition])
  await waitFor(() => /reloaded 1 task/.test(process.stderr()), 'definition reload during run')
  const observationFloor = Date.now()
  fs.writeFileSync(releaseFile, 'continue')

  const state = await waitFor(() => {
    const runtime = readJSON(runtimeFile)?.[oldDefinition.id]
    return runtime?.definitionRevision === 'revision-2'
      && runtime.activeRun === null
      && runtime.lastResult === 'fixture result'
      && runtime
  }, 'cross-revision run completion')

  assert.equal(state.lastRunRequestID, 'manual-request-1')
  assert.equal(state.nextRun, undefined)
  assert.equal(state.lastMtime, undefined)
  assert.equal(state.lastMailId, undefined)
  assert.equal(state.onceCompleted, undefined)
  assert.deepEqual(readJSON(tasksFile), [editedDefinition])

  const delivery = await waitFor(() => {
    const directory = path.join(support, 'authority-inbox', 'v1', 'pending', 'ambientd')
    if (!fs.existsSync(directory)) return null
    const [filename] = fs.readdirSync(directory).filter((name) => name.endsWith('.json'))
    return filename && readAuthorityInboxEnvelope(path.join(directory, filename))
  }, 'scheduled-task result Conversation envelope')
  const conversation = delivery.payload
  assert.equal(delivery.envelope.domain, 'conversation')
  assert.equal(delivery.envelope.kind, 'create')
  assert.equal(delivery.envelope.subjectID, conversation.id)
  assert.equal(delivery.envelope.definitionRevision, 'revision-1')
  assert.equal(delivery.envelope.producer.id, 'ambientd')
  assert.equal(delivery.envelope.authority.observedGeneration, 'legacy-unmarked')
  assert.equal(conversation.projectID, workspaceID)
  assert.equal(conversation.cwd, support,
    'persisted membership uses the canonical Workspace cwd, not the execution fallback')
  assert.equal(fs.existsSync(path.join(support, 'conversations')), false,
    'ambientd must not write Legacy Conversation sidecars')
  assert.deepEqual(conversation.messages.map((message) => message.kind), ['user', 'assistant'])
  for (const message of conversation.messages) {
    assert.equal(typeof message.observedAt, 'string')
    assert.match(message.observedAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/)
    assert.equal(Number.isNaN(Date.parse(message.observedAt)), false)
    assert.ok(Date.parse(message.observedAt) >= observationFloor)
    assert.ok(Date.parse(message.observedAt) <= Date.now())
  }
  assert.equal(process.child.exitCode, null, process.stderr())
})

test('a Trust-all scheduled run still cannot read a credential store (FR-212)', async (t) => {
  // The unattended lane passed no canUseTool at all, so the one surface that runs shell with nobody
  // watching was the one surface with no credential boundary. That boundary is absolute on the
  // interactive lane — it applies in every permission mode, including bypassPermissions — because it
  // was added for an observed live token leak.
  const harness = ambientHarness(t, 'mechanician-ambient-unattended-guard-')
  const { support } = harness
  const ambient = path.join(support, 'ambient')
  fs.mkdirSync(ambient, { recursive: true })
  const workspaceID = '55555555-4444-3333-2222-111111111111'
  writeProject(support, workspaceID)
  fs.writeFileSync(path.join(ambient, 'tasks.json'), JSON.stringify([{
    id: 'guard-task', name: 'Trust all task', prompt: 'do the thing', enabled: false,
    workspaceID, permissionMode: 'bypassPermissions', definitionRevision: 'revision-1',
    runRequestID: 'manual-request-1',
    trigger: { type: 'time', schedule: { kind: 'daily', hour: 9, minute: 0 } },
  }], null, 2))
  const { loader, releaseFile } = writeFakeSDKLoader(support)
  const resultFile = path.join(support, 'permission-verdicts.json')
  const probes = [
    { tool: 'Bash', input: { command: 'cat ~/.claude.json' } },
    { tool: 'Bash', input: { command: 'cat ~/.aws/credentials' } },
    { tool: 'Bash', input: { command: 'ps aux | grep mcp' } },
    { tool: 'Read', input: { file_path: '/Users/alice/.claude.json' } },
    { tool: 'Bash', input: { command: 'npm test' } },
  ]
  const running = harness.start({
    nodeArgs: ['--import', loader],
    env: {
      MECHANICIAN_AMBIENT_INPROCESS: '1',
      MECHANICIAN_AMBIENT_TEST_RELEASE: releaseFile,
      MECHANICIAN_AMBIENT_TEST_PERMISSION_PROBE: JSON.stringify(probes),
      MECHANICIAN_AMBIENT_TEST_PERMISSION_RESULT: resultFile,
    },
  })
  // The child publishes directly to this file. Existence can precede a complete JSON write, so
  // wait for the payload rather than racing its open/write sequence from the parent process.
  const observed = await waitFor(() => readJSON(resultFile), 'complete permission verdicts', 10_000)
  fs.writeFileSync(releaseFile, 'go')

  const byIndex = observed.verdicts
  assert.equal(byIndex.length, probes.length)
  for (const verdict of byIndex.slice(0, 4)) {
    assert.equal(verdict.behavior, 'deny',
      `${verdict.tool} reading a credential store must be denied even on a Trust-all run`)
    assert.match(verdict.message, /cannot be read/i)
  }
  // Trust all still means trust all for ordinary work; this is a data boundary, not a mode.
  assert.equal(byIndex[4].behavior, 'allow')
  // A question nobody can answer would hold the run open until its timeout.
  assert.deepEqual(observed.disallowedTools, ['AskUserQuestion'])
})

test('a scheduled run reports what it reached for and could not have (FR-224)', async (t) => {
  // blockedTools was collected, returned and read by nobody, while its sibling permissionDenials
  // four lines away WAS rendered. On the one lane with no person watching, a silent refusal can
  // only ever be discovered as "my task didn't do the thing".
  const harness = ambientHarness(t, 'mechanician-ambient-withheld-')
  const { support } = harness
  const ambient = path.join(support, 'ambient')
  fs.mkdirSync(ambient, { recursive: true })
  const workspaceID = '33333333-2222-1111-0000-999999999999'
  writeProject(support, workspaceID)
  fs.writeFileSync(path.join(ambient, 'tasks.json'), JSON.stringify([{
    id: 'withheld-task', name: 'Reports what it lost', prompt: 'try things', enabled: false,
    workspaceID, permissionMode: 'bypassPermissions', definitionRevision: 'revision-1',
    runRequestID: 'manual-request-1',
    trigger: { type: 'time', schedule: { kind: 'daily', hour: 9, minute: 0 } },
  }], null, 2))
  const { loader, releaseFile } = writeFakeSDKLoader(support)
  const resultFile = path.join(support, 'permission-verdicts.json')
  const running = harness.start({
    nodeArgs: ['--import', loader],
    env: {
      MECHANICIAN_AMBIENT_INPROCESS: '1',
      MECHANICIAN_AMBIENT_TEST_RELEASE: releaseFile,
      // Our own boundary refuses this one...
      MECHANICIAN_AMBIENT_TEST_PERMISSION_PROBE: JSON.stringify([
        { tool: 'Bash', input: { command: 'cat ~/.claude.json' } },
      ]),
      MECHANICIAN_AMBIENT_TEST_PERMISSION_RESULT: resultFile,
      // ...and the engine reports its own auto-denial on the terminal message.
      MECHANICIAN_AMBIENT_TEST_PERMISSION_DENIALS: JSON.stringify([
        { tool_name: 'WebFetch', tool_use_id: 'x', tool_input: {} },
      ]),
    },
  })
  await waitFor(() => fs.existsSync(resultFile), 'permission verdicts', 10_000)
  fs.writeFileSync(releaseFile, 'go')

  // The report a person reads. `lastResult` is runtime state, not part of the app-owned definition
  // store, so it lands in runtime.json.
  const lastResult = await waitFor(() => {
    const runtime = readJSON(path.join(ambient, 'runtime.json'))
    const entry = runtime && Object.values(runtime).find((value) => value?.lastResult)
    return entry?.lastResult || null
  }, 'a completed run report', 15_000)

  assert.match(lastResult, /Withheld/, 'the run report must name what was refused')
  assert.match(lastResult, /Bash/, 'our own credential-boundary refusal must be named')
  assert.match(lastResult, /WebFetch/, "the engine's own auto-denial must be named")
  assert.match(lastResult, /not available to a scheduled task/)
  // The ordinary output is still there; the note is an addition, not a replacement.
  assert.match(lastResult, /fixture result/)
})
