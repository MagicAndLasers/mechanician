import assert from 'node:assert/strict'
import { once } from 'node:events'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

import { HELP_EXPERT_TOOL_PROFILE } from '../src/codex-tools.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const agentd = path.resolve(here, '../src/agentd.mjs')

async function waitFor(predicate, description, fixture, timeout = 5_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.fail(`timed out waiting for ${description}\nagentd stderr:\n${fixture.stderr}`)
}

function writeSDKLoader(directory, captureFile) {
  const sdkSource = `
    import fs from 'node:fs'
    const capture = ${JSON.stringify(captureFile)}
    const record = (event) => fs.appendFileSync(capture, event + '\\n')
    const recordOptions = (kind, options) => record(JSON.stringify({
      kind,
      model: options?.model,
      skillOverrides: options?.settings?.skillOverrides,
      settingSources: options?.settingSources,
      systemPrompt: options?.systemPrompt,
      resume: options?.resume,
      permissionMode: options?.permissionMode,
      allowDangerouslySkipPermissions: options?.allowDangerouslySkipPermissions,
      strictMcpConfig: options?.strictMcpConfig,
      disableClaudeAiConnectors: options?.settings?.disableClaudeAiConnectors,
      syncClaudeAiPlugins: options?.settings?.syncClaudeAiPlugins,
      plugins: options?.plugins,
      allowedTools: options?.allowedTools,
      helpTools: options?.mcpServers?.help?.tools?.map((candidate) => candidate?.name),
      hookEvents: Object.keys(options?.hooks || {}).sort(),
    }))

    export function createSdkMcpServer(config) { return config }
    export function tool(name, description, schema, handler) {
      return { name, description, schema, handler }
    }

    function providerQuery(prompt, kind, options) {
      record(kind)
      const stream = (async function* () {
        const input = prompt?.[Symbol.asyncIterator]?.()
        const first = input ? await input.next() : { done: false }
        if (first.done) return
        record(JSON.stringify({ kind: kind + '-prompt', value: first.value }))
        if (process.env.MECHANICIAN_TEST_MANAGED_EXIT_PLAN_PROBE === '1') {
          const decision = await options?.canUseTool?.('ExitPlanMode', {}, {})
          record(JSON.stringify({
            kind: 'exit-plan-probe',
            behavior: decision?.behavior,
            message: decision?.message,
          }))
        }
        if (process.env.MECHANICIAN_TEST_MANAGED_WAIT_PROBE === '1') {
          const waitTool = options?.mcpServers?.waitmode?.tools?.find(
            (candidate) => candidate?.name === 'WaitFor')
          const result = await waitTool?.handler?.({
            note: 'managed wait probe', check: 'exit 0', after: '1s', everySeconds: 10,
          })
          record(JSON.stringify({ kind: 'managed-wait-probe', result }))
        }
        if (process.env.MECHANICIAN_TEST_MANAGED_OPERATE_PROBE === '1') {
          const decision = await options?.canUseTool?.(
            'mcp__help__OperateMechanician', { operation: 'focusComposer' }, {})
          record(JSON.stringify({
            kind: 'managed-operate-probe',
            permissionMode: options?.permissionMode,
            behavior: decision?.behavior,
            message: decision?.message,
          }))
        }
        yield {
          type: 'system', subtype: 'init', session_id: 'fixture-session',
          tools: ['Read'], mcp_servers: [],
        }
        yield {
          type: 'stream_event', session_id: 'fixture-session', uuid: 'fixture-frame',
          event: {
            type: 'content_block_delta', index: 0,
            delta: { type: 'text_delta', text: 'warm response' },
          },
        }
        yield {
          type: 'result', subtype: 'success', session_id: 'fixture-session',
          is_error: false, result: 'warm response', duration_ms: 12, duration_api_ms: 8,
          ttft_ms: 4, time_to_request_ms: 2, time_to_request_from_spawn_ms: 3,
          warm_spare_claimed: kind === 'warm-query', num_turns: 1, stop_reason: null,
          total_cost_usd: 0, usage: {
            input_tokens: 1, output_tokens: 1,
            cache_creation_input_tokens: 0, cache_read_input_tokens: 0,
          },
          modelUsage: {}, permission_denials: [], uuid: 'fixture-result',
        }
      })()
      stream.supportedCommands = async () => []
      return stream
    }

    export function query({ prompt, options }) {
      recordOptions('cold-options', options)
      return providerQuery(prompt, 'cold-query', options)
    }

    export async function startup({ options }) {
      recordOptions('startup-options', options)
      record('startup')
      let claimed = false
      return {
        query(prompt) {
          if (claimed) throw new Error('warm query claimed twice')
          claimed = true
          return providerQuery(prompt, 'warm-query', options)
        },
        close() { record('close') },
      }
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

test('Claude prewarm is exact-config and a resumed instruction edit uses the new append', async (t) => {
  const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-claude-prewarm-'))
  const capture = path.join(support, 'sdk-events.txt')
  const loader = writeSDKLoader(support, capture)
  const child = spawn(process.execPath, ['--import', loader, agentd], {
    env: {
      ...process.env,
      MECHANICIAN_PROVIDER: 'anthropic',
      MECHANICIAN_AUTH: 'apikey',
      MECHANICIAN_CONFIG_DIR: support,
      MECHANICIAN_CWD: support,
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
  const fixture = { events, get stderr() { return stderr } }
  t.after(async () => {
    if (child.exitCode === null) child.kill('SIGKILL')
    if (child.exitCode === null) {
      try { await once(child, 'exit') } catch {}
    }
    fs.rmSync(support, { recursive: true, force: true })
  })

  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready event', fixture)
  child.stdin.write(`${JSON.stringify({
    type: 'prewarm', id: 'prewarm-1', convId: 'conversation-1',
    sessionId: null, cwd: support, permissionMode: 'default',
    model: 'fable', catalogResolvedModel: 'claude-fable-5-1',
    projectInstructions: 'Always run the narrowest relevant test.',
    workspaceInstructionsRevision: 'claude-workspace-revision',
  })}\n`)
  await waitFor(
    () => fs.existsSync(capture) && fs.readFileSync(capture, 'utf8').includes('startup'),
    'SDK startup()', fixture,
  )
  assert.equal(events.some((event) => event.type === 'tool_surface'), false,
    'prewarm must not claim a provider-accepted tool surface')

  child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'turn-1', convId: 'conversation-1',
    sessionId: null, cwd: support, permissionMode: 'default',
    model: 'fable', catalogResolvedModel: 'claude-fable-5-1',
    prompt: 'hello',
    projectInstructions: 'Always run the narrowest relevant test.',
    workspaceInstructionsRevision: 'claude-workspace-revision',
  })}\n`)
  const terminal = await waitFor(
    () => events.find((event) => event.id === 'turn-1'
      && (event.type === 'done' || event.type === 'error')),
    'turn terminal', fixture,
  )

  assert.deepEqual(terminal, { type: 'done', id: 'turn-1' })
  const standardSurface = events.filter((event) => event.type === 'tool_surface'
    && event.id === 'turn-1')
  assert.deepEqual(standardSurface, [{
    type: 'tool_surface', id: 'turn-1', lane: 'claude', toolProfile: 'standard',
    permissionMode: 'default', coverage: 'complete', provenance: 'provider-init',
    adapterRevision: 'mechanician-tool-surface-v1', tools: ['Read'],
  }])
  assert.ok(events.indexOf(standardSurface[0]) < events.findIndex(
    (event) => event.id === 'turn-1' && event.type === 'delta'))
  let sdkEvents = fs.readFileSync(capture, 'utf8').trim().split('\n')
  assert.ok(sdkEvents.includes('warm-query'))
  assert.equal(sdkEvents.includes('cold-query'), false)
  const startupOptions = sdkEvents
    .filter((event) => event.startsWith('{'))
    .map(JSON.parse)
    .find((event) => event.kind === 'startup-options')
  assert.deepEqual(startupOptions.settingSources, [])
  assert.equal(startupOptions.model, 'fable', 'the catalog alias stays on the provider wire')
  assert.equal(startupOptions.skillOverrides, undefined,
    'the resolved Fable 5.1 identity keeps its first-party 1M skill surface')
  assert.equal(startupOptions.systemPrompt.type, 'preset')
  assert.equal(startupOptions.systemPrompt.preset, 'claude_code')
  assert.equal(startupOptions.systemPrompt.excludeDynamicSections, true)
  assert.deepEqual(startupOptions.hookEvents, ['PostCompact', 'PreToolUse'])
  assert.match(
    startupOptions.systemPrompt.append,
    /# Workspace Instructions[\s\S]*Always run the narrowest relevant test\./,
  )
  assert.match(stderr, /phase=warm_query_claimed/)
  assert.match(stderr, /phase=provider_result_metrics .*timeToRequestFromSpawnMs=3/)

  // Completion predicts the next turn by preparing a resumed spare under instruction set A.
  // Sending the same provider session under B must discard that spare, keep the resume id, and
  // create a query whose preset append contains B rather than replaying history into a fresh one.
  await waitFor(() => {
    if (!fs.existsSync(capture)) return false
    const records = fs.readFileSync(capture, 'utf8').trim().split('\n')
      .filter((event) => event.startsWith('{'))
      .map(JSON.parse)
    return records.filter((event) => event.kind === 'startup-options').length >= 2
  }, 'post-turn resumed spare for instruction set A', fixture)
  child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'turn-2', convId: 'conversation-1',
    sessionId: 'fixture-session', cwd: support, permissionMode: 'default',
    model: 'fable', catalogResolvedModel: 'claude-fable-5-1',
    prompt: 'second message',
    history: [
      { role: 'user', text: 'hello' },
      { role: 'assistant', text: 'warm response' },
      { role: 'user', text: 'second message' },
    ],
    replayHistory: false,
    projectInstructions: 'Use the revised workspace convention.',
    workspaceInstructionsRevision: 'claude-workspace-revision-2',
  })}\n`)
  const secondTerminal = await waitFor(
    () => events.find((event) => event.id === 'turn-2'
      && (event.type === 'done' || event.type === 'error')),
    'resumed turn with revised instructions',
    fixture,
  )
  assert.deepEqual(secondTerminal, { type: 'done', id: 'turn-2' })

  sdkEvents = fs.readFileSync(capture, 'utf8').trim().split('\n')
  const records = sdkEvents
    .filter((event) => event.startsWith('{'))
    .map(JSON.parse)
  const revisedOptions = records.find((event) => event.kind === 'cold-options')
  assert.equal(revisedOptions.resume, 'fixture-session')
  assert.match(
    revisedOptions.systemPrompt.append,
    /# Workspace Instructions[\s\S]*Use the revised workspace convention\./,
  )
  assert.doesNotMatch(
    revisedOptions.systemPrompt.append,
    /Always run the narrowest relevant test\./,
  )
  const revisedPrompt = records.find((event) => event.kind === 'cold-query-prompt')
  assert.equal(revisedPrompt.value.message.content[0].text, 'second message')
  assert.match(stderr, /warm query discarded after configuration changed/)
})

// A brand-new conversation is the case that hurt: it has no provider session to resume, so the
// only thing that ever distinguished its spare from the previous conversation's was the
// conversation id — which reaches none of the subprocess options. Keying on it meant opening a new
// conversation always restarted the spin-up (about 15 s on a managed Vertex machine, issue #38).
test('a ready spare serves a different conversation of the same shape', async (t) => {
  const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-claude-prewarm-reuse-'))
  const capture = path.join(support, 'sdk-events.txt')
  const loader = writeSDKLoader(support, capture)
  const child = spawn(process.execPath, ['--import', loader, agentd], {
    env: {
      ...process.env,
      MECHANICIAN_PROVIDER: 'anthropic',
      MECHANICIAN_AUTH: 'apikey',
      MECHANICIAN_CONFIG_DIR: support,
      MECHANICIAN_CWD: support,
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
  const fixture = { events, get stderr() { return stderr } }
  t.after(async () => {
    if (child.exitCode === null) child.kill('SIGKILL')
    if (child.exitCode === null) {
      try { await once(child, 'exit') } catch {}
    }
    fs.rmSync(support, { recursive: true, force: true })
  })

  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready event', fixture)
  child.stdin.write(`${JSON.stringify({
    type: 'prewarm', id: 'prewarm-1', convId: 'conversation-1',
    sessionId: null, cwd: support, permissionMode: 'default',
    projectInstructions: 'Always run the narrowest relevant test.',
    workspaceInstructionsRevision: 'claude-workspace-revision',
  })}\n`)
  await waitFor(
    () => fs.existsSync(capture) && fs.readFileSync(capture, 'utf8').includes('startup'),
    'SDK startup()', fixture,
  )

  // Same workspace, model, instructions, and no session to resume — a different conversation only.
  child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'turn-1', convId: 'conversation-2',
    sessionId: null, cwd: support, permissionMode: 'default',
    prompt: 'hello',
    projectInstructions: 'Always run the narrowest relevant test.',
    workspaceInstructionsRevision: 'claude-workspace-revision',
  })}\n`)
  const terminal = await waitFor(
    () => events.find((event) => event.id === 'turn-1'
      && (event.type === 'done' || event.type === 'error')),
    'turn terminal', fixture,
  )

  assert.deepEqual(terminal, { type: 'done', id: 'turn-1' })
  const sdkEvents = fs.readFileSync(capture, 'utf8').trim().split('\n')
  assert.ok(sdkEvents.includes('warm-query'), 'the ready spare must be claimed')
  assert.equal(sdkEvents.includes('cold-query'), false)
  assert.match(stderr, /phase=warm_query_claimed/)
  // The spin-up is phase-resolved so a slow lane can be attributed without guessing.
  assert.match(stderr, /warm_query phase=subprocess_ready .*spawnMs=/)
})

// `bypassPermissions` applies at launch on its own, so the picker has always LOOKED right on a
// fresh conversation. The SDK's companion flag is what makes the mode AVAILABLE to the session,
// and availability is what the CLI consults when it restores a mode on resume or is asked to
// switch into one mid-session. Without the flag both of those silently fall back to 'default'
// while the picker still reads "Bypass permissions", which is the failure a user reports as
// "bypass is selected but it keeps asking me". Pin the pairing so the two can never disagree.
test('Full access pairs bypassPermissions with the SDK flag that keeps it available', async (t) => {
  const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-claude-bypass-'))
  const capture = path.join(support, 'sdk-events.txt')
  const loader = writeSDKLoader(support, capture)
  const child = spawn(process.execPath, ['--import', loader, agentd], {
    env: {
      ...process.env,
      MECHANICIAN_PROVIDER: 'anthropic',
      MECHANICIAN_AUTH: 'apikey',
      MECHANICIAN_CONFIG_DIR: support,
      MECHANICIAN_CWD: support,
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
  const fixture = { events, get stderr() { return stderr } }
  t.after(async () => {
    if (child.exitCode === null) child.kill('SIGKILL')
    if (child.exitCode === null) {
      try { await once(child, 'exit') } catch {}
    }
    fs.rmSync(support, { recursive: true, force: true })
  })

  const optionsFor = (mode) => {
    const raw = fs.existsSync(capture) ? fs.readFileSync(capture, 'utf8').trim() : ''
    if (!raw) return null
    for (const line of raw.split('\n')) {
      let parsed
      try { parsed = JSON.parse(line) } catch { continue }
      if (parsed?.permissionMode === mode) return parsed
    }
    return null
  }

  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready event', fixture)

  child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'bypass-turn', prompt: 'run it', cwd: support,
    permissionMode: 'bypassPermissions',
  })}\n`)
  const bypass = await waitFor(
    () => optionsFor('bypassPermissions'), 'bypassPermissions SDK options', fixture)
  assert.equal(bypass.allowDangerouslySkipPermissions, true,
    'Full access must launch the session with bypass AVAILABLE, or the mode is dropped on resume')

  // The negative half matters just as much: the flag is derived from the mode, so no other mode
  // may carry it. A session that merely COULD bypass is a wider session than the user asked for.
  child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'default-turn', prompt: 'run it', cwd: support,
    permissionMode: 'default',
  })}\n`)
  const normal = await waitFor(() => optionsFor('default'), 'default SDK options', fixture)
  assert.equal(normal.allowDangerouslySkipPermissions, undefined,
    'only Full access may make bypass available to the session')
})

async function startManagedPermissionFixture(
  t,
  maximumPermissionMode,
  {
    probeExit = false,
    probeWait = false,
    probeOperate = false,
    allowUnattended = true,
  } = {},
) {
  const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-claude-managed-permission-'))
  const capture = path.join(support, 'sdk-events.txt')
  const loader = writeSDKLoader(support, capture)
  const environment = {
    ...process.env,
    MECHANICIAN_PROVIDER: 'anthropic',
    MECHANICIAN_AUTH: 'apikey',
    MECHANICIAN_CONFIG_DIR: support,
    MECHANICIAN_CWD: support,
    MECHANICIAN_MANAGED_POLICY: '1',
    MECHANICIAN_ALLOWED_PROVIDER_ACCESSES: 'anthropic_api',
    MECHANICIAN_ALLOW_USER_EXTENSIONS: '0',
    MECHANICIAN_MANAGED_EXTENSION_SERVERS: '[]',
    MECHANICIAN_ALLOW_UNATTENDED_TASKS: allowUnattended ? '1' : '0',
    ...(probeExit ? { MECHANICIAN_TEST_MANAGED_EXIT_PLAN_PROBE: '1' } : {}),
    ...(probeWait ? { MECHANICIAN_TEST_MANAGED_WAIT_PROBE: '1' } : {}),
    ...(probeOperate ? { MECHANICIAN_TEST_MANAGED_OPERATE_PROBE: '1' } : {}),
    ANTHROPIC_API_KEY: 'fixture-api-key',
    ANTHROPIC_AUTH_TOKEN: '',
    CLAUDE_CODE_OAUTH_TOKEN: '',
  }
  if (maximumPermissionMode !== undefined) {
    environment.MECHANICIAN_MAX_PERMISSION_MODE = maximumPermissionMode
  } else {
    delete environment.MECHANICIAN_MAX_PERMISSION_MODE
  }
  const child = spawn(process.execPath, ['--import', loader, agentd], {
    env: environment,
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
  const fixture = { events, get stderr() { return stderr } }
  t.after(async () => {
    if (child.exitCode === null) child.kill('SIGKILL')
    if (child.exitCode === null) {
      try { await once(child, 'exit') } catch {}
    }
    fs.rmSync(support, { recursive: true, force: true })
  })

  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready event', fixture)
  return { support, capture, child, events, fixture }
}

function capturedJSON(capture) {
  if (!fs.existsSync(capture)) return []
  return fs.readFileSync(capture, 'utf8').split('\n').flatMap((line) => {
    try { return [JSON.parse(line)] } catch { return [] }
  })
}

test('managed Plan ceiling reaches the provider and cannot be exited mid-turn', async (t) => {
  const { support, capture, child, events, fixture } = await startManagedPermissionFixture(
    t, 'plan', { probeExit: true })
  child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'managed-bypass-turn', prompt: 'run it', cwd: support,
    permissionMode: 'bypassPermissions',
  })}\n`)
  const options = await waitFor(
    () => capturedJSON(capture).find((record) => record.permissionMode === 'plan'),
    'Plan-clamped SDK options', fixture)
  const exitProbe = await waitFor(
    () => capturedJSON(capture).find((record) => record.kind === 'exit-plan-probe'),
    'managed ExitPlanMode denial', fixture)

  assert.equal(options.permissionMode, 'plan')
  assert.equal(options.allowDangerouslySkipPermissions, undefined,
    'the provider process must never receive the wider bypass capability')
  assert.equal(options.strictMcpConfig, true,
    'the signed managed server map must be the complete external MCP configuration')
  assert.equal(options.disableClaudeAiConnectors, true,
    'provider-owned connectors must not auto-mount in managed-only mode')
  assert.equal(options.syncClaudeAiPlugins, false,
    'provider-owned plugins must not sync into a managed-only session')
  assert.deepEqual(options.plugins, [],
    'locally enabled plugins must not enter a managed-only session')
  assert.equal(exitProbe.behavior, 'deny')
  assert.match(exitProbe.message, /required by managed enterprise policy/)
  await waitFor(
    () => events.find((event) => event.type === 'subtraction'
      && event.id === 'managed-bypass-turn'
      && event.reason === 'plan_mode_readonly'
      && event.names?.includes('ExitPlanMode')),
    'managed ExitPlanMode subtraction', fixture)
})

test('an invalid explicit managed permission ceiling fails closed to Plan', async (t) => {
  const { support, capture, child, fixture } = await startManagedPermissionFixture(
    t, 'future-wider-mode')
  child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'managed-invalid-ceiling', prompt: 'run it', cwd: support,
    permissionMode: 'bypassPermissions',
  })}\n`)
  const options = await waitFor(
    () => capturedJSON(capture).find((record) => record.permissionMode === 'plan'),
    'fail-closed Plan SDK options', fixture)
  assert.equal(options.permissionMode, 'plan')
  assert.equal(options.allowDangerouslySkipPermissions, undefined)
})

test('an absent managed permission ceiling leaves the requested mode uncapped', async (t) => {
  const { support, capture, child, fixture } = await startManagedPermissionFixture(t, undefined)
  child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'managed-uncapped', prompt: 'run it', cwd: support,
    permissionMode: 'bypassPermissions',
  })}\n`)
  const options = await waitFor(
    () => capturedJSON(capture).find((record) => record.permissionMode === 'bypassPermissions'),
    'uncapped bypass SDK options', fixture)
  assert.equal(options.permissionMode, 'bypassPermissions')
  assert.equal(options.allowDangerouslySkipPermissions, true)
})

test('managed unattended disable rejects Claude WaitFor without arming or authorizing it', async (t) => {
  const { support, capture, child, events, fixture } = await startManagedPermissionFixture(
    t, undefined, { probeWait: true, allowUnattended: false })
  child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'managed-wait-disabled', prompt: 'wait for it', cwd: support,
    permissionMode: 'bypassPermissions',
  })}\n`)

  const probe = await waitFor(
    () => capturedJSON(capture).find((record) => record.kind === 'managed-wait-probe'),
    'managed WaitFor denial', fixture)
  assert.equal(probe.result?.isError, true)
  assert.match(probe.result?.content?.[0]?.text || '', /disabled by managed enterprise policy/)
  assert.equal(events.some((event) => event.type === 'waiting'
    && event.id === 'managed-wait-disabled'), false)
  assert.equal(events.some((event) => event.type === 'permission_request'
    && event.id === 'managed-wait-disabled'), false)
})

test('managed Plan omits and denies OperateMechanician in the Claude Help override', async (t) => {
  const { support, capture, child, events, fixture } = await startManagedPermissionFixture(
    t, 'plan', { probeOperate: true })
  child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'managed-help-operate-disabled', prompt: 'focus the composer', cwd: support,
    permissionMode: 'bypassPermissions', toolProfile: HELP_EXPERT_TOOL_PROFILE,
  })}\n`)

  const options = await waitFor(
    () => capturedJSON(capture).find((record) => record.helpTools?.includes('ShowMechanician')),
    'managed Claude Help options', fixture)
  const probe = await waitFor(
    () => capturedJSON(capture).find((record) => record.kind === 'managed-operate-probe'),
    'managed Claude OperateMechanician denial', fixture)
  assert.equal(options.permissionMode, 'dontAsk')
  assert.deepEqual(options.helpTools, ['SearchMechanicianHelp', 'ShowMechanician'])
  assert.deepEqual(options.allowedTools, [
    'mcp__help__SearchMechanicianHelp', 'mcp__help__ShowMechanician',
  ])
  assert.equal(probe.behavior, 'deny')
  assert.equal(events.some((event) => event.type === 'operate_mechanician_request'
    && event.id === 'managed-help-operate-disabled'), false)
})

test('a managed default ceiling still blocks requested-Plan OperateMechanician in Claude', async (t) => {
  const { support, capture, child, events, fixture } = await startManagedPermissionFixture(
    t, 'default', { probeOperate: true })

  child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'managed-standard-requested-plan', prompt: 'focus the composer', cwd: support,
    permissionMode: 'plan', toolProfile: 'standard',
  })}\n`)
  const standardOptions = await waitFor(
    () => capturedJSON(capture).find((record) => record.permissionMode === 'plan'
      && record.helpTools?.includes('RecommendMechanicianWorkflow')),
    'requested-Plan standard Claude options', fixture)
  const standardProbe = await waitFor(
    () => capturedJSON(capture).find((record) => record.kind === 'managed-operate-probe'
      && record.permissionMode === 'plan'),
    'requested-Plan standard Claude OperateMechanician denial', fixture)
  assert.deepEqual(standardOptions.helpTools, [
    'SearchMechanicianHelp', 'ShowMechanician', 'RecommendMechanicianWorkflow',
  ])
  assert.equal(standardProbe.behavior, 'deny')
  await waitFor(() => events.find((event) => event.type === 'done'
    && event.id === 'managed-standard-requested-plan'),
  'requested-Plan standard Claude terminal', fixture)

  child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'managed-help-requested-plan', prompt: 'focus the composer', cwd: support,
    permissionMode: 'plan', toolProfile: HELP_EXPERT_TOOL_PROFILE,
  })}\n`)
  const helpOptions = await waitFor(
    () => capturedJSON(capture).find((record) => record.permissionMode === 'dontAsk'
      && record.helpTools?.includes('ShowMechanician')),
    'requested-Plan Claude Help options', fixture)
  const helpProbe = await waitFor(
    () => capturedJSON(capture).find((record) => record.kind === 'managed-operate-probe'
      && record.permissionMode === 'dontAsk'),
    'requested-Plan Claude Help OperateMechanician denial', fixture)
  assert.deepEqual(helpOptions.helpTools, ['SearchMechanicianHelp', 'ShowMechanician'])
  assert.deepEqual(helpOptions.allowedTools, [
    'mcp__help__SearchMechanicianHelp', 'mcp__help__ShowMechanician',
  ])
  assert.equal(helpProbe.behavior, 'deny')
  assert.equal(events.some((event) => event.type === 'operate_mechanician_request'
    && (event.id === 'managed-standard-requested-plan'
      || event.id === 'managed-help-requested-plan')), false)
})
